# Common blocks

Step 1-2 brings in the blocks this SoC shares with the earlier AXI_PCIe_Subsystem repository (commit `b64e36a`). Two are taken unchanged and one is rewritten. Measurements below were taken with the testbenches at commit `8ce1fac`.

## What was taken

| Block | File here | Origin in AXI_PCIe_Subsystem `b64e36a` | Change |
| --- | --- | --- | --- |
| `cdc_sync_2ff` | `rtl/common/cdc_sync_2ff.sv` | `rtl/cdc_async_fifo.sv` | None. The module body is byte-identical; only the file header is new |
| `axi_channel_reg_slice` | `rtl/axi/axi_channel_reg_slice.sv` | `rtl/axi_register_slice.sv` | None at `8ce1fac`: the module body, monitors included, is byte-identical; only the file header is new. In step 2-1 the payload registers moved out of the reset process, because synthesis made the reset net a data input there ([10_transaction_layer.md](10_transaction_layer.md)) |
| `cdc_async_fifo` | `rtl/common/cdc_async_fifo.sv` | `rtl/cdc_async_fifo.sv` | Rewritten with the same name and ports |

Not taken in this step:

| Block | Reason |
| --- | --- |
| `axi_register_slice`, the AXI4-Lite five-channel wrapper | The AXI4 wrapper comes with the crossbar in step 1-3 and uses the same channel leaf |
| `axi_crossbar`, AXI4-Lite 2 x 2 | Replaced by the 4 x 5 AXI4 crossbar in step 1-3 |
| `outstanding_queue`, `pcie_to_axi_bridge` | Belong to the host interface, phase 2 |

## Why the FIFO was rewritten

The `b64e36a` FIFO was built to read a 16-entry memory within an 8 ns read clock at the slow Sky130 corner. Its read side is a tree of 2:1 multiplexers, one level per `rd_clk`, with a tag that has to match the read pointer before `rd_empty` falls. That fits the clock, but each pop has to wait for the new address to pass all `ADDR_W` levels, and every new write pointer flushes the tree.

The same testbench (`dv/tb/tb_cdc_async_fifo.sv`) ran both FIFOs at six clock pairs, with random traffic (70% push and 70% pop per clock) and full-rate traffic (100% / 100%), 20,000 words per run. The bound is the lower of what the writer offers and what the reader takes, in words per `rd_clk`.

| `wr_clk` / `rd_clk` | Traffic | Bound | This repository: words per `rd_clk` | `b64e36a`: words per `rd_clk` |
| --- | --- | --- | --- | --- |
| 10 / 8 ns | random | 0.560 | 0.564 (100.7%) | 0.139 (24.8%) |
| 10 / 8 ns | full rate | 0.800 | 0.800 (100.0%) | 0.171 (21.4%) |
| 16 / 20 ns | random | 0.700 | 0.707 (101.0%) | 0.140 (20.0%) |
| 16 / 20 ns | full rate | 1.000 | 1.000 (100.0%) | 0.150 (15.0%) |
| 20 / 16 ns | random | 0.560 | 0.564 (100.7%) | 0.139 (24.8%) |
| 20 / 16 ns | full rate | 0.800 | 0.800 (100.0%) | 0.171 (21.4%) |
| 20 / 20 ns, `rd_clk` 3 ns later | random | 0.700 | 0.685 (97.9%) | 0.143 (20.5%) |
| 20 / 20 ns, `rd_clk` 3 ns later | full rate | 1.000 | 1.000 (100.0%) | 0.182 (18.2%) |
| 40 / 10 ns | random | 0.175 | 0.175 (100.1%) | 0.119 (68.3%) |
| 40 / 10 ns | full rate | 0.250 | 0.250 (100.0%) | 0.125 (50.0%) |
| 10 / 40 ns | random | 0.700 | 0.706 (100.9%) | 0.115 (16.4%) |
| 10 / 40 ns | full rate | 1.000 | 1.000 (100.0%) | 0.125 (12.5%) |

- **Data integrity.** Both FIFOs returned every word in order in all 12 runs: 0 data errors, and never more than 16 words held.
- **`b64e36a` throughput.** It moved one word per 5.5 to 8.7 read clocks (0.115 to 0.182 words per `rd_clk`), so it sat full (16 of 16) in every run. Random runs can land slightly above 100% because the bound uses the expected rates, not the drawn ones.
- **Clocks here.** Storage_SoC's crossings run at 16 to 20 ns. A 16:1 read multiplexer fits there, so the new FIFO uses one and keeps a word per clock. The STA in step 1-9 confirms the fit at the slow corner.

## The FIFO in this repository

| Item | Behavior |
| --- | --- |
| Interface | First-word fall-through: `rd_data` is the oldest word while `rd_empty` is low, and `rd_en` pops it |
| Throughput | One word per clock on each side |
| Write | Memory is written on the same `wr_clk` edge that advances the write pointer, so a word is in memory before its pointer can reach the read side, whatever the clock ratio |
| Flags | `wr_full` and `rd_empty` are registered and conservative. The writer sees a pop two `wr_clk` edges late, and the reader sees a push two `rd_clk` edges late |
| Read | `rd_data` is a `DEPTH`:1 multiplexer on the binary read pointer |
| Reset | `wr_rst_n` and `rd_rst_n` are asserted together and each released synchronously to its own clock |

Timing constraints for step 1-9 (the intended bound is the smaller of the two clock periods):

- `set_max_delay` from `wr_gray` to `u_sync_wr_to_rd/stage1`, and from `rd_gray` to `u_sync_rd_to_wr/stage1`
- `set_max_delay` from the memory flops (`wr_clk`) to the `rd_clk` logic that uses `rd_data`
- no false path on these crossings, so the max-delay constraints stay in force

## Register slice

`dv/tb/tb_axi_channel_reg_slice.sv` at commit `8ce1fac`:

| Check | Result |
| --- | --- |
| Random VALID (60%) and READY (60%), 5,000 beats | All beats in order; VALID and payload held until accepted, on both sides |
| VALID and READY held high, 1,000 beats | 1.000 beat per clock, 1 clock of latency |
| Downstream stall of k clocks while VALID stays high, k = 1 to 6 | Upstream blocked for exactly k clocks every time |

`s_ready` is the inverse of the skid flop, so it has no combinational path from `m_ready`.

## How to run

```bash
make -C dv            # lint, FIFO at six clock pairs, register slice
make -C dv fifo       # FIFO only; MIN_EFF sets the full-rate threshold (default 95%)
```

To measure the `b64e36a` FIFO with the same testbench:

```bash
git clone https://github.com/yhkwon-git/AXI_PCIe_Subsystem /tmp/aps
git -C /tmp/aps checkout b64e36a
FIFO_SRC=/tmp/aps/rtl/cdc_async_fifo.sv MIN_EFF=0 bash dv/run_fifo.sh
```
