# Firmware

Step 1-8 puts a driver layer under the firmware and runs the phase-1 flow as one program, `soc_app`:
- boot and a memory check;
- a DMA copy checked by CRC;
- the CPU and the DMA alone and together;
- a PD_HOST power cycle.

The single-purpose tests of steps 1-4 to 1-7 stay as they were; their images are unchanged. Firmware, drivers and scripts are at commit `fbe4b8a`, and every result below was measured there.

## Layout

| Directory | Contents |
| --- | --- |
| `fw/common/` | Start-up code (`crt0.S`), linker script, console and exit (`lib.c`), register header (`soc.h` over the generated `soc_regs.h`) |
| `fw/tests/` | One test per feature, each with its own trap handler (steps 1-4 to 1-7) |
| `fw/drv/` | Drivers, with one trap handler for all of them |
| `fw/app/` | Programs on the drivers: `soc_app` |
| `fw/images/` | Committed ROM images, so the simulation and CI need no cross compiler |

## Drivers

| Driver | File | What it does |
| --- | --- | --- |
| Interrupts | `drv/irq.c` | One trap handler. The machine timer calls its registered function. An external interrupt claims the lowest pending enabled INTC source and calls that source's function, which clears the source at its block. Any exception prints `mcause`, `mepc` and `mtval` and ends the run |
| Sleep | `drv/irq.c` | `irq_wait(flag)` sleeps in WFI until an interrupt handler sets the flag (below) |
| Timer | `drv/timer.c` | `timer_cycles()` (mtime counts `clk_sys` clocks); `timer_sleep(ticks)` |
| DMA | `drv/dma.c` | Descriptor setup, `dma_start`, `dma_wait` (DONE or ERR interrupt, INTC 1 and 2), and status, error cause and address, descriptors done and CYCLES as a result |
| PMU | `drv/pmu.c` | PD_HOST power-down and power-up ended by the PMU interrupt (INTC 10), chip reset |
| HOST | `drv/pmu.c` | One command to the PD_HOST placeholder and its response |
| CRC-32 | `drv/crc32.c` | Reflected CRC-32 (polynomial `0xEDB88320`) with a 256-entry table built once in SRAM |

**Sleeping without losing an interrupt.** The single-purpose tests wait with `while (!flag) wfi;`. If the interrupt arrives between the test and the WFI, its handler has already run and the core sleeps with nothing left to wake it. That never happened in those tests, but it depends on timing. `irq_wait` tests the flag with `mstatus.MIE` cleared. An interrupt arriving then stays pending, and a pending source enabled in `mie` wakes WFI whatever MIE says. The handler then runs as soon as MIE is set again. Every driver waits this way.

**Sources are levels.** Each handler clears its source at the block: DMA `STATUS`, PMU `PWR_IRQ`. The PMU's source crosses from `clk_aon`, so its handler also waits until INTC PENDING shows the source gone; otherwise the trap would be taken again.

## soc_app

| Phase | What it checks |
| --- | --- |
| Boot | SYS ID, VERSION, PMU RST_CAUSE; PD_HOST on after the automatic power-up |
| Memory check | M2's quarter of SRAM (16 KiB at `0x1000_8000`): each word written with its address and read back, then with the inverse |
| DMA | A 4 KiB pattern copied SRAM to the NAND0 page buffer and back, the second descriptor with FENCE; CRC-32 of source and result equal; DESC_DONE 2 |
| CPU and DMA | CRC-32 of 4 KiB (in the CPU's SRAM half) alone, an 8 KiB DMA copy alone, then the copy started and the CRC run while it goes on; the CRC must be the same |
| PD_HOST | CFG, two ECHO, a power-down and a power-up by interrupt, then STATE (CFG retained, LAST reset) and SEQ (2, retained) |

Size: 3,492 bytes of code and read-only data in the boot ROM, 0 bytes of initialized data. The 5,344 bytes of BSS are mostly the 4 KiB CRC buffer and the 1 KiB CRC table.

### Results

| Measurement | Alone | With `+bg` (M3 traffic in SRAM) |
| --- | --- | --- |
| Memory check, 16 KiB, 4 passes | 139,272 clocks, 0 words wrong | 349,229 clocks, 0 words wrong |
| DMA SRAM, NAND0, SRAM, 2 x 4 KiB | 1,140 DMA cycles, CRC `0x575A_7DC6` both | 1,806 DMA cycles, CRC equal |
| CRC-32 of 4 KiB by the CPU alone | 61,455 clocks | 150,251 clocks |
| 8 KiB DMA copy alone (CPU-measured, from START to the interrupt handled) | 1,394 clocks | 2,786 clocks |
| Both together: CRC finished, copy finished | 62,378 and 62,455 clocks | 153,807 and 154,070 clocks |
| One after the other (sum of the two above) | 62,849 clocks | 153,037 clocks |
| PD_HOST power-down, power-up | 1,784 and 1,888 clocks | 2,252 and 2,152 clocks |
| Interrupts taken | 5 | 5 |
| Clocks the CPU's clock gate removed | 3,554 | 4,985 |
| Exit | 458,790 clocks | 1,082,382 clocks, 168,267 background bursts, 0 errors |

- **CPU and DMA together, alone.** The copy runs entirely inside the CRC. The CRC itself takes 923 clocks (1.5%) longer, because its table and data loads share the SRAM with the copy's bursts. Both finish 394 clocks sooner than one after the other.
- **With background traffic.** M3 also loads the SRAM, so doing both at once is 1,033 clocks slower than one after the other. That is why `soc_app` reports this timing but does not check it.
- **Cost of the CRC.** About 15 clocks per byte. Each byte needs two loads from SRAM, the data byte and the table word, and each is a single 32-bit AXI transfer through the crossbar. Code runs from ROM, so instruction fetches do not compete for the SRAM.

### All SoC firmware at `fbe4b8a`

| Program | Alone | With `+bg` |
| --- | --- | --- |
| `hello` | 712 | 783 |
| `memtest` | 293,459 | 786,420 |
| `irq` | 7,906 | 10,039 |
| `buserr` | 4,919 | 8,156 |
| `perf` | 420,009 | 544,429 |
| `dma` | 385,735 | 642,966 |
| `power` | 10,915 | 12,330 |
| `reset` | 9,770 | (alone only: its chip reset would abandon M3's bursts) |
| `soc_app` | 458,790 | 1,082,382 |

The earlier programs' images and clock counts are the same as at `ca320d4`.

## Findings

- **A timing assertion that was not a functional check.** The first `soc_app` required CPU and DMA together to beat one after the other. That holds on a quiet bus, but the `+bg` run broke it while every result was correct. The program now reports the timing and checks only CRC and status.

## Limits

- One program. There is no scheduler and no host command loop yet; phase 2 adds the NVMe command handling.
- The single-purpose tests keep their own trap handlers and the simple wait loop described above; they are not ported to the drivers, so that their images and clock counts stay comparable across steps.

## How to run

```bash
make -C fw images                 # needs riscv-none-elf-gcc on PATH
make -C dv soc                    # every program alone and with +bg, soc_app included
```
