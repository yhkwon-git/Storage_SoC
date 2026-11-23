# NVMe firmware and its cost

Step 2-4 gives the NVMe front-end its firmware. The hardware of steps 2-2 and 2-3 fetches commands, moves data by PRP and writes completion entries; the firmware decides what each command does. It answers the admin commands a host driver sends at bring-up, serves Read, Write and Flush on a namespace in SRAM, and gives every other command the status the specification gives it. The step then measures what that division of work costs: firmware clocks per command, queue-depth-1 latency, and IOPS at queue depths 1 to 16. Firmware, testbench and scripts are at commit `491d727`, and every result below was measured there. The RTL did not change in this step.

## Firmware

| File | Role |
| --- | --- |
| `fw/drv/nvme.c` | The command loop: `nvme_init()` and `nvme_service()`, admin and I/O commands, statuses, accounting |
| `fw/app/nvme_app.c` | Serves commands until the host shuts the controller down, then prints commands by kind, bytes, firmware and transfer clocks, and what an APB register access costs |
| `dv/tb/tb_soc.sv` (`+test=nvme_app`) | The host side of the run |

**The loop.** `nvme_service()` sleeps in WFI until the NVMe interrupt (INTC source 3). The interrupt handler takes the controller events and masks the command interrupt, which is a level, so it does not fire again during the drain. The loop then takes every waiting command: it copies the 64-byte entry from the command buffer, returns the slot at once, handles the command and posts its completion. When CMD reads empty, it unmasks the command interrupt and sleeps again. A shutdown (EVENT.SHUTDOWN) ends the loop.

**Controller reset.** The hardware has already dropped the commands, freed the slots and deleted the I/O queues when EVENT.RESET is set. The firmware counts the reset and sets the vendor-specific feature back to its default. It does this before any command taken after the reset, because the drain stops as soon as the interrupt handler has seen one. The ordering matters because the gap can be short. In a trace, the handler read RESET and ENABLE together: by the time it ran, the host had already re-enabled the controller. The next command, and even a shutdown after it, can then fall in the same pass of the loop. An earlier version looked at the shutdown first and, in the run with background traffic, did not count the reset; that can only happen in a pass that finds both pending.

**Admin commands:**

| Command | What the firmware does |
| --- | --- |
| Identify, CNS 1 (controller) | 4 KiB to the host: VID and SSVID 0 (placeholders), serial and model strings, MDTS 5 (128 KiB), CNTLID 1, VER 1.4.0, SQES 64 bytes, CQES 16 bytes, one namespace, no volatile write cache |
| Identify, CNS 0 (namespace 1) | NSZE, NCAP and NUSE 24 blocks, one LBA format of 512 bytes |
| Identify, CNS 2 | The active namespace list: namespace 1 |
| Create I/O Completion / Submission Queue | Checks queue ID, size, contiguity, vector, and that the SQ's CQ exists; writes the queue's IOQ registers |
| Delete I/O Submission / Completion Queue | Clears the queue's enable; a CQ that an SQ still uses is refused |
| Set / Get Features, Number of Queues (FID 7) | 4 submission and 4 completion queues, whatever was asked |
| Set / Get Features, FID 0xC0 (vendor specific) | Transfer overlap on or off (below) |

**I/O commands:** Read, Write and Flush on namespace 1, 24 blocks of 512 bytes at `0x1000_8000`. A Read or a Write gives the PRP engine the command's PRP1 and PRP2, the block's SRAM address and the length. Flush succeeds at once: there is no volatile write cache.

**Statuses:** Invalid Command Opcode, Invalid Field in Command (an unknown CNS or feature, a length the PRP engine refuses), Invalid Namespace, LBA Out of Range, PRP Offset Invalid, Data Transfer Error, and for queue commands Invalid Queue Identifier, Invalid Queue Size, Completion Queue Invalid, Invalid Interrupt Vector and Invalid Queue Deletion. All but Data Transfer Error carry Do Not Retry.

**Transfer overlap.** With overlap off, a Read or a Write waits for its transfer before the firmware touches the next command. With it on, the firmware takes the next command while the transfer runs. If that command needs a transfer too, it loads the PRP engine's registers for it (the engine takes them at START), waits for the running transfer to end, starts the next one at once, and only then posts the finished command's completion. Commands are still completed in the order they were taken.

**Accounting:** firmware clocks are the clocks spent in the command loop minus the clocks spent spinning on a transfer's end; transfer clocks are the sum of XF_CYCLES.

## The run

The host in `tb_soc` (`+test=nvme_app`) works as a host driver does:
1. Enable the controller with a 16-entry admin queue pair.
2. Identify the controller, namespace 1 and the active namespace list, checking MDTS, SQES, CQES, NN, VER, NSZE and the LBA format. An unknown CNS gets Invalid Field and another namespace Invalid Namespace.
3. Set Features Number of Queues, asking for 8 and getting 4. Get Features returns the same; an unsupported feature gets Invalid Field.
4. Create four I/O queue pairs of 16 entries on vectors 1 to 4. A fifth queue gets Invalid Queue Identifier; deleting a CQ in use gets Invalid Queue Deletion.
5. Write the namespace, then run the read workloads below, first with overlap off, then on. Spread over the four queues, every completion is checked and every byte read is compared with what was written.
6. A Flush, then errors on an I/O queue: LBA Out of Range, Invalid Namespace, Invalid Command Opcode.
7. Delete the submission queues, then the completion queues. A controller reset follows. The admin queue comes back, an Identify after it is served, and Get Features 0xC0 reads overlap off again.
8. Shut the controller down.

Latency is clocks from the doorbell write to the entry seen in host memory. IOPS is commands over the clocks from the first doorbell to the last entry, at 50 MHz. The host model answers reads after 10 to 40 `pclk` clocks, as in every SoC test.

## Results

`make -C dv soc` runs `nvme_app` alone and with background traffic (the host reading and writing its quarter of SRAM through BAR2 throughout). Both pass with 0 errors: 541,324 clocks alone; 815,632 with the background traffic, which made 27,342 requests (5.2 MB) next to the NVMe work.

Latency in clocks, IOPS at 50 MHz:

| Workload | Overlap off | Overlap on | Overlap off, background | Overlap on, background |
| --- | ---: | ---: | ---: | ---: |
| 4 KiB read latency, QD1 | 1,400 (worst 1,406) | 1,386 | 2,268 (worst 2,496) | 2,305 |
| 512 B read latency, QD1 | 895 | | 1,577 | |
| 4 KiB reads, QD1 | 35,709 | 36,059 | 22,040 | 21,689 |
| 4 KiB reads, QD4 | 47,990 | 62,116 | 32,202 | 47,305 |
| 4 KiB reads, QD16 | 48,045 | 62,274 | 32,099 | 47,056 |
| 512 B reads, QD16 | 93,223 | 105,297 | 57,783 | 61,604 |
| 4 KiB writes, QD16 | | 58,402 | | 41,577 |

QD4 and QD16 runs spread the commands round robin over the four I/O queue pairs.

What the firmware reports, over all 557 commands of the run (both modes, admin commands included):

| | Alone | With background traffic |
| --- | ---: | ---: |
| Commands | 557: 30 admin, 472 Read, 51 Write, 1 Flush | same |
| With an error status (all expected by the host) | 8 | 8 |
| Bytes moved by the PRP engine | 1,585,152 | 1,585,152 |
| Completion entries written, MSI-X messages | 557, 557 | 557, 557 |
| Controller resets seen | 1 | 1 |
| Firmware clocks per command, average | 597 | 898 |
| Clocks spinning on a transfer's end, in all | 144,848 | 198,032 |
| Transfer clocks (XF_CYCLES), in all | 251,559 (6.3 bytes per clock) | 350,449 (4.5 bytes per clock) |
| An APB register access from the CPU | read 8 clocks, write 9 | same |

- **Overlap** raises 4 KiB reads at QD16 by 30% (48,045 to 62,274 IOPS) and 512-byte reads by 13%. At QD1 it changes nothing, since there is never a second command to overlap with.
- **Queue depth 4** already gives what queue depth 16 gives (62,116 against 62,274 IOPS for 4 KiB with overlap): beyond four outstanding commands, the bus master is the limit, not the queue.
- **One MSI-X message per completion:** 557 of each.

## What limits it

- **Firmware, about 475 clocks per I/O command.** With overlap on and 512-byte reads, 105,297 IOPS is 475 clocks per command. The bus master's share of such a command is far less:
  - the 64-byte fetch, 40 clocks (step 2-2);
  - the transfer, about 115 clocks: at QD1 a 4 KiB read takes 505 clocks longer than a 512-byte one, for 3,584 more bytes;
  - the completion entry, 17 clocks from the post (step 2-3).

  So 475 clocks is the firmware's own rate. A register access costs the CPU 8 clocks to read and 9 to write, and an overlapped Read makes about 18 of them, about 155 clocks in all:
  - 6 reads: CMD, the transfer status, its clock count, CQE_STATUS, and two timer reads for the accounting;
  - 12 writes: SLOT_FREE, six PRP engine registers, START, the status clear and three completion registers.

  Copying the 64-byte entry from the command buffer, the checks and the loop take the rest.
- **The bus master, about 800 clocks per 4 KiB command.** With overlap on and 4 KiB reads, 62,274 IOPS is 803 clocks per command, and the firmware's 475 hide behind it. The transaction layer's bus master runs one transfer at a time, and it carries every command's 64-byte fetch, its 4 KiB of data (about 620 clocks at the 6.6 bytes per clock of step 2-3) and its completion entry one after another. Without overlap, the firmware's work adds to the transfer: 1,041 clocks per command at QD16.
- **Queue depth 1, 1,400 clocks per 4 KiB read.** Nothing overlaps: the doorbell, the fetch, the interrupt and the firmware, the transfer, the completion entry and its MSI-X message happen one after another.
- **With background traffic,** the host link, the bus master's path to SRAM and the CPU's SRAM accesses are shared, and the figures drop by a quarter (4 KiB reads at QD16 with overlap) to two fifths (512-byte reads at QD16 with overlap).

The split of work holds up: no command waits for the firmware to move data, compute a PRP list or build an entry. The next gains are in the hardware:
- more than one bus-master transfer in flight, or fetches that bypass a running data transfer;
- PRP pages merged into one bus-master transfer when contiguous.

On the firmware side, the register accesses could become one descriptor in SRAM per command.

## Found on the way

- **A controller reset that went uncounted.** With background traffic, the firmware served the reset correctly but reported 0 resets, because it looked at the shutdown before the reset (above). The reset is now taken first, both before and after each drain, and the drain stops at one.
- **A driver linked into every application.** Adding `nvme.c` to the common driver list put its code and its 4 KiB Identify buffer into `soc_app` too, which made the image larger and the start-up longer. A driver that only one application uses is now listed for that application (`DRV_nvme_app` in `fw/Makefile`), and `soc_app`'s image is the same as before the step.
- **Waiting for every transfer** before taking the next command left the bus master idle while the firmware completed one command and took the next. The overlap mode is the measured answer: +30% for 4 KiB reads at QD16.

## Limits

- **SRAM namespace** of 24 blocks (12 KiB), the room left beside the command buffer and the background-traffic area; NAND comes with phase 3.
- **One namespace**, one LBA format of 512 bytes, no metadata, no protection information.
- **Admin commands missing**: Get Log Page, Abort, Asynchronous Event Request, firmware commands, Format NVM. They get Invalid Command Opcode.
- **Deleting a submission queue** does not abort the commands it still holds; a host deletes it when they have completed, as this one does.
- **A controller reset with commands outstanding:** the firmware finishes the command it holds, and the hardware drops that completion and reports it as EVENT.CQE_ERR. A host here resets only after its commands have completed.
- **Features:** only Number of Queues and the vendor-specific overlap.

## How to run

```bash
make -C fw images                 # firmware images, including nvme_app (needs riscv-none-elf-gcc)
make -C dv soc                    # all firmware tests, nvme_app alone and with background traffic
```
