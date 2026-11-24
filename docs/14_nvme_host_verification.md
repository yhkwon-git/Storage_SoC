# NVMe host driver model and verification

Step 2-5 verifies the NVMe front-end as a host driver uses it: queues created and deleted with admin commands, many commands outstanding over several queues, full queues on both sides, wrong commands, and controller resets with commands outstanding. It adds:
- a class-based host driver model on the transaction-level host model, run in `tb_soc` against the step 2-4 firmware;
- assertions on the controller's queue state, bound into both NVMe testbenches;
- covergroups that every regression must fill.

Writing the reset cases showed that the controller could not handle a reset while firmware held commands, so the step also adds epochs to the controller (below). RTL, firmware, testbenches and scripts are at commit `c5e2b96`, and every result below was measured there.

## Why the controller needed epochs

A host may clear CC.EN at any time, with commands still outstanding. The hardware dropped what it held: the commands waiting in CMD, the fetches, the transfers between pages, the entries waiting to be written. A command that firmware had already taken was another matter. Firmware could go on with it after the reset had completed, and even after the host had enabled the controller again:
- **start its PRP transfer:** into host buffers the host had freed, or from them into SRAM;
- **post its completion:** into the new admin queue, or into an I/O queue the host had created again, with a CID the host might be using again;
- **return its slot:** while a new command was in it;
- **finish a Create I/O Queue:** creating a queue the host never asked for in the new session.

Firmware cannot avoid this alone. If it reads a status before each action, the reset can complete between the read and the action. Only the hardware can check and act in the same clock.

**Epochs.** The controller counts controller resets in a 4-bit epoch. Firmware receives a command's epoch with the command and writes it back with everything it does for that command. The hardware refuses whatever carries another epoch, or comes while the controller is not on:

| Register | Field | What the hardware does with it |
| --- | --- | --- |
| STATUS | EPOCH | The current epoch: resets since power-on, modulo 16 |
| CMD | EPOCH | The epoch the command was fetched in (always the current one: the reset empties the FIFO) |
| SLOT_FREE | EPOCH | A stale write frees nothing |
| XF_CTRL | EPOCH | A stale START moves nothing and ends at once with ERR, cause 11 |
| CQE_CTRL | EPOCH | A stale post is discarded: CQE_STATUS.STALE, not DROP, and no EVENT.CQE_ERR |
| SQ_CFG, CQ_CFG | EPOCH | An I/O queue is enabled only while its epoch is the current one |
| STALE | CQE, XF | Posts discarded and starts refused, counted |

**Firmware** (`fw/drv/nvme.c`, and `fw/tests/nvme.c` likewise) takes the epoch from CMD and writes it into SLOT_FREE, XF_CTRL, CQE_CTRL and the queue configurations. Two kinds of command also change firmware state: queue creation and deletion, and Set Features. Before touching anything, these compare their epoch with STATUS.EPOCH, with interrupts masked. A stale one changes nothing, and nothing is posted for it.

What remains is the few register accesses between that check and the writes. The host would have to reset the controller, see CSTS.RDY clear, enable it again and get an admin command fetched in that time. That needs several round trips on the link.

**A second fix, found on the way.** While designing the host model, it turned out that firmware posted every I/O completion to the CQ with its SQ's number. That is wrong for any host that maps SQs to other CQs, or shares one CQ between SQs. Firmware now keeps each SQ's CQ from Create I/O Submission Queue.

## The host driver model

`dv/tb/nvme_host_pkg.sv` (class `nvme_host`) sits on the transaction-level host model of step 2-1. It works through BAR0 and host memory only, as a host driver does:
- **Bring-up:** enables the controller with an admin queue pair, then creates I/O queue pairs with admin commands. Any SQ may complete on any CQ, CQs may share a vector, and queues are deleted again.
- **I/O:** Reads, Writes and Flushes of 1 to 24 blocks at any DW offset, with PRP1 alone, PRP1 and PRP2, or a PRP list, rung in batches. Completions are taken by phase tag, and each CQ head doorbell is rung, or held back until the CQ fills.
- **Errors:** unknown opcode, LBA out of range, another namespace, PRP1 not DW aligned, and the admin errors.
- **Data:** a copy of the namespace. Writes fill their buffer with random bytes; a Read is compared byte for byte. A command waits while another one on its blocks could change them.

Every completion is checked:
- **CID:** outstanding, and not abandoned by a reset;
- **SQID and CQ:** the SQID is the command's SQ, and the CQ is the one that SQ was created with;
- **status:** the one the command calls for;
- **SQ head:** inside the queue, moving forward, not past the tail, and past this command;
- **DW0, and the data of a Read.**

**A controller reset with commands outstanding.** The host clears CC.EN and waits for CSTS.RDY to clear. Entries written by then are completions like any other. Every other command is abandoned:
- its blocks become unknown if it was a Write, until written again;
- a Read's buffer is filled with a poison byte, checked one epoch later and at the end;
- its CID must never complete.

At most one MSI-X message may go missing per reset: the one that waited for the link when the reset came. After the shutdown at the end there must be exactly one per entry.

## The test: `+test=nvme_rand`

`tb_soc` runs the host model against the step 2-4 firmware (`fw/images/nvme_app.hex`) in epochs, each starting with an enable, Identify, Get Features Number of Queues, and Set Features of the transfer overlap, on or off at random:

| Epoch | Queues | What happens |
| --- | --- | --- |
| 0 | Admin queue of 4 entries; four I/O pairs of 4 entries, one CQ per SQ, a vector each | The namespace written; queue errors before the fourth pair is created (Completion Queue Invalid, Invalid Queue Size, Invalid Interrupt Vector, Invalid Queue Deletion, Invalid Field, and Invalid Queue Identifier for an existing CQ, a queue that does not exist and SQ 5); large transfers one at a time; each CQ's head held back while Flushes go to its SQ until the controller waits for room; random I/O at up to 12 outstanding; a reset with 4 to 15 outstanding while an entry is being written |
| 1 | Four pairs of 32-entry SQs and 64-entry CQs, in any of the layouts below | Random I/O at up to 40 outstanding; a reset with 16 or more outstanding during a data transfer |
| 2 to 4 | 2 to 4 pairs of 2 to 32 entries; one CQ per SQ, one CQ for all SQs, or one vector for all CQs | Random I/O; then a reset with 1 to 3 outstanding during a fetch; the queues deleted and a reset with nothing outstanding; every CQ held back and a reset with commands waiting for firmware in CMD |
| last | as 2 to 4 | Random I/O; everything completed, the queues deleted, a shutdown |

Random I/O is 44% Read, 40% Write, 5% Flush and 11% commands that must fail. Most transfers are 1 to 8 blocks, and some are 9 to 24, with the data at offset 0 or at a random DW offset. Doorbells are rung in batches, and now and then a CQ head is held back.

## Assertions

`dv/sva/nvme_checker.sv` holds 13 assertions, five of them repeated for each of the five queues. `dv/sva/nvme_bind.sv` binds it into every `nvme_ctrl`, in `tb_nvme` and `tb_soc`:

| Rule | Assertion |
| --- | --- |
| Pointers | An enabled queue's head and tail stay below its size |
| Fetch | A fetch reads only a queue with an entry between head and tail; an SQ head moves by one, or to 0 |
| Entries | An entry is written only with room in its CQ; a CQ tail moves by one only when an entry has been written, or to 0; the phase tag flips only where the tail goes back to 0 |
| Slots | Commands waiting in CMD never outnumber the slots in use |
| Epoch | The epoch moves only by one, and only as a controller reset completes |
| Controller off | No fetch, transfer or entry write; no transfer starts and no entry is posted unless the controller is on |
| MSI-X | A CQ's MSI-X request follows the write of an entry |

The rules across clocks are checked at each clock edge against values kept from the clock before. In Verilator 5.052, `$past` of an element of an array port does not compile, and `$past` of a wire copy of it disagreed with the same check made at the clock edge.

**The slot assertion found a bug.** At a controller reset, the slots were freed and the epoch moved in the clock the reset completed, but the command FIFO emptied a clock later. For that clock, CMD offered commands from before the reset with the new epoch, which a firmware read could have taken as current. The FIFO now empties in the same clock.

## Coverage

`tb_soc` has 13 covergroups with 81 bins in all:
- **Commands:** kind and SQ, reads and writes on each SQ, PRP layout, size class, outstanding commands, admin commands and admin errors.
- **Queues:** SQ wraps, SQ full, CQ wraps, CQ heads held back, and the controller waiting for room in each CQ.
- **Resets:** outstanding commands, the controller's state and commands waiting in CMD, each sampled as CC.EN clears.
- **Layout and mode:** queue layout, and Reads and Writes with transfer overlap off and on.

`dv/run_soc.sh` merges the coverage of the `nvme_rand` runs and fails unless every bin is hit. `tb_nvme` has 6 more bins for the epoch cases (101 in all), which `+test=stale` hits on its own.

## Results

`make -C dv nvme`, `make -C dv nvme-mut`, `make -C dv soc`, `make -C dv ral` and `make -C flow`, all at `c5e2b96`.

### `nvme_rand` against the firmware

| Run | Commands | Of them Read, Write, Flush, admin | Completed (with the error status they called for) | Abandoned by 5 resets | Bytes read and compared | Stale starts refused, posts discarded | Clocks |
| --- | ---: | --- | --- | ---: | ---: | --- | ---: |
| Seed 1 | 1,342 | 766, 120, 134, 82 | 1,260 (231) | 82 | 1,709,568 | 3, 1 | 895,260 |
| Seed 1, background traffic | 1,338 | 735, 140, 141, 82 | 1,257 (231) | 81 | 1,473,536 | 2, 2 | 1,363,395 |
| Seed 2 | 1,338 | 773, 126, 134, 78 | 1,256 (226) | 82 | 1,805,312 | 1, 2 | 942,168 |
| Seed 3 | 1,340 | 768, 149, 149, 80 | 1,255 (187) | 85 | 1,653,760 | 2, 4 | 866,245 |

The commands not counted as Read, Write, Flush or admin are the ones that must fail. In all four runs:
- **0 errors.** Every CID, SQID, status, SQ head and byte read was as expected.
- **No completion and no buffer write for any of the 330 abandoned commands.** The 250 poisoned buffers of abandoned Reads were checked and still held the poison.
- **One MSI-X message per entry:** none was lost at the 20 resets.
- **All 81 bins hit.** With the CI setting (seed 1, 400 commands, alone and with background traffic) all 81 are hit too.
- **The epochs at work.** The hardware refused 8 transfer starts and discarded 9 completion posts that the firmware made for commands fetched before a reset.

The firmware saw a command was stale only when its start came back with cause 11. The discarded posts were for commands it could not tell were stale, such as a Flush, or a transfer that the reset had ended with cause 10.

**Step 2-4's workload at this commit** (`nvme_app`, alone), against `491d727`:

| | `491d727` | `c5e2b96` |
| --- | ---: | ---: |
| 4 KiB read latency at QD1 (clocks) | 1,400 | 1,419 |
| 4 KiB reads at QD16 (IOPS) | 48,045 | 46,990 |
| 4 KiB reads at QD16, overlap on (IOPS) | 62,274 | 60,928 |
| 512 B reads at QD16, overlap on (IOPS) | 105,297 | 98,701 |

The epochs cost the firmware about 32 clocks per command: 507 clocks per 512-byte read where it was firmware-bound, against 475. The extra work is extracting the epoch, writing it into three registers, and looking up each SQ's CQ.

### `tb_nvme`

- **Directed and random runs.** 13 directed tests (`stale` is new) and 10 random seeds pass with the assertions bound, and none fired.
  - The random queue test (2,000 commands a seed): 20,000 submitted, 15,481 fetched and checked, 47 controller resets (24 after a shutdown).
  - The random I/O test (300 commands a seed): 2,281 completion entries checked (2,170 good, 111 with the error status the command called for), 13.3 MB moved to the host and 12.6 MB from it, 30 controller resets.
- **Covergroups:** 101 of 101 bins.
- **RTL coverage of `rtl/host/nvme/`:** line 97 of 108, branch 168 of 174, toggle 54.0%.
- **Throughput (`perf`), within 0.3% of `569ad05`:**
  - 40.1 clocks per command fetched;
  - PRP transfers of 4 KiB in 615 clocks from SRAM to the host (615 at `569ad05`) and 712 the other way (714);
  - 128 KiB in 19,839 and 23,346 clocks (19,836 and 23,291);
  - an entry in host memory 17 clocks after its post.
- **Mutation check** (`make -C dv nvme-mut`): 33 of 33 caught, step 2-3's 27 and 6 new ones for the epochs.
  - **The epoch mutants**, all caught by `stale`: a start with a stale epoch taken; a start taken with the controller off; a stale post written; a stale SLOT_FREE freeing a slot in use; a queue created with a stale epoch enabled; the epoch never changing.
  - **Caught first by an assertion: 8 mutants.** An SQ head that does not wrap, a slot that stays free, a doorbell beyond the queue size taken, a reset that leaves commands in CMD, an entry written into a full CQ, a CQ tail that does not wrap, a start with the controller off, and a stale SLOT_FREE taken.

### UVM register tests

On xsim, with the regenerated model:
- 64 behavior and decode checks, 0 failures, in 12,134 APB transfers;
- the bit bash covers 125 registers, STALE added;
- UVM_ERROR 0;
- `ral-mut`: 4 of 4 mutants caught.

### Synthesis, timing and CDC

`make -C flow`, pre-layout as in [09_timing.md](09_timing.md).

**Area.** 115,783 cells and 1,508,048 µm² of standard cells, SRAM macros not counted. That is 3,148 µm² (0.2%) more than at `569ad05`.

| NVMe controller block | Area (µm²) | `569ad05` |
| --- | ---: | ---: |
| Buffer (16 words of flops) | 35,990 | 36,107 |
| PRP engine | 22,570 | 23,120 |
| Completion poster | 9,772 | 9,138 |
| Registers, queues, fetch, requesters, epochs | 87,531 | 84,506 |
| In all | 155,863 (10.3%) | 152,870 (10.1%) |

The split is by instance name and approximate (`flow/syn/area_by_block.py`).

**Timing:**

| Corner | Setup WNS | Hold WNS | Worst setup by origin |
| --- | --- | --- | --- |
| `tt_025C_1v80` | +4.040 ns | +0.099 ns | CPU +4.04; transaction layer +6.73; NVMe controller +7.78; `pclk` +7.78 |
| `ff_100C_1v95` | +8.936 ns | −0.029 ns (TNS −0.372, SRAM input pins) | NVMe controller +12.64 |
| `ss_n40C_1v40` | −49.780 ns | +1.019 ns | CPU −49.8; transaction layer −36.6; NVMe controller −34.5; `pclk` −3.03 |

The NVMe controller's worst path is still the one from step 2-3: from the poster's FIFO read pointer to the entry's host address. Nothing on that path changed. Its slack at ss moved from −42.4 to −34.5 ns because Yosys and ABC map the flattened design as a whole.

**CDC check.** 33,945 flops, 32 latches and 4 SRAM macros, with the same crossings as before: 49 synchronizer bits, 80 handshake registers, 8,927 FIFO words and 2,725 PMU controls. PASS.

## Limits

- **The epoch is 4 bits.** A command held across 16 resets would look current again. Firmware handles a command in microseconds, and 16 resets take a host at least 16 register round trips each way.
- **The window that remains** for queue commands and Set Features (above).
- **One MSI-X message may go missing at a reset**, the one waiting for the link when it came. The entry it belongs to is in host memory, and the host model takes it.
- **Not exercised:** Abort; deleting an SQ with commands outstanding (the host model completes them first); a shutdown with commands outstanding; more than 4 I/O queue pairs.
- **24 blocks of namespace** limit how many Writes can be outstanding at once, since a Write waits for every command on its blocks.

## How to run

```bash
make -C dv nvme                   # tb_nvme: directed tests (stale included), random seeds, assertions, 101 bins
make -C dv nvme-mut               # [MUT] 33 of 33 mutants caught
make -C dv soc                    # every firmware test, then nvme_rand: NVME_RAND_SEEDS seeds of NVME_RAND_N commands, 81 bins
make -C dv ral                    # UVM register tests on xsim (WSL calls Windows)
```
