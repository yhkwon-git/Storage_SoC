# Synthesis, timing and CDC

Step 1-9 synthesizes `soc_top` onto Sky130 HD, times it at three corners with multi-clock constraints, and checks every clock-domain crossing in the netlist. Everything here is pre-layout: ideal clocks, no wire parasitics, and SRAM macros as black boxes with assumed timing. RTL and scripts are at commit `7a0d727`, and every number below was measured there.

## Flow

| Step | Script | What it does |
| --- | --- | --- |
| Libraries | `flow/syn/fetch_sky130.sh` | Sky130 HD liberty files from lambdapdk v0.2.9 (`tt_025C_1v80`, `ss_n40C_1v40`, `ff_100C_1v95`) into `build/pdk`, each checked against its SHA-256; not committed |
| Synthesis | `flow/syn/run_syn.sh` | sv2v (`SYNTHESIS`, `SKY130`) turns Ibex's and soc_top's SystemVerilog into Verilog. Yosys then: `synth -flatten`, latches to `dlxtp`, flops mapped with tt, logic mapped by ABC against ss with a drive and load model and a dont-use list |
| Fanout | `flow/syn/buffer_fanout.py` | `buf_8` trees on nets whose load exceeds 90% of the driver's max capacitance at ss, which ABC cannot see (flop outputs) |
| CDC | `flow/cdc/check_cdc.py` | Structural crossing check on the flattened generic netlist |
| STA | `flow/sta/run_sta.sh` | OpenSTA 3.1.0 at the three corners with `syn/sdc/soc_top.sdc` |
| Area | `flow/syn/area_by_block.py` | Standard-cell area by top-level block |

`make -C flow` runs them all. It needs sv2v, Yosys and OpenSTA, which the CI image does not have, so it runs locally.

**What synthesis sees.**
- **Memories.** `mem_array` becomes one SRAM macro per size (`sram_2048x64` ROM, `sram_8192x64` SRAM, two `sram_512x64` page buffers). They are black boxes whose timing comes from `syn/lib/sram_macros.lib`, which `flow/syn/gen_sram_lib.py` writes with assumed numbers: 3.0 ns clock to Q, 0.8 ns setup, 0.2 ns hold, the same at every corner. They are not a characterized SRAM, and their area is not counted.
- **Clock gates.** `clk_gate` maps to the library's integrated clock gate `sky130_fd_sc_hd__dlclkp_1`: the CPU's gate and the PLL model's.
- **Retention shadows.** The 32 `ret_reg` shadow latches map to `dlxtp_1`.
- **Isolation cells.** The four isolation cells are AND-type logic here; the dont-use list keeps ABC from using the library's isolation cells as ordinary gates.

## Constraints

`syn/sdc/soc_top.sdc`:

| Item | Value |
| --- | --- |
| Clocks | `clk_sys` 20 ns, `clk_nand` 20 ns, `pclk` 16 ns (at `pclk_in`, through the PLL model's clock gate), `clk_aon` 1000 ns; ideal, 0.25 ns setup and 0.10 ns hold uncertainty, 0.15 ns transition |
| Crossings | For every pair of clocks, a max delay of the destination's period and no hold check. No asynchronous clock groups, which would override the max delays (docs/01, section 9). The CDC check below shows every crossing ends where such a bound is the right check |
| Asynchronous inputs | `por_n`, `host_pwr_ack`, `host_wake`: false path, each is synchronized inside |
| M3 port | 6 ns (30%) input and output delay against `clk_sys` |
| Not timed | Console, exit, lock-up flag, power-switch enable |

**Reset trees.** One reset synchronizer drives about 2,900 reset pins, and without a reset tree its transition is hundreds of nanoseconds. So recovery and removal are left to post-layout: `flow/sta/sta.tcl` sets a false path to all 4,074 asynchronous reset and set pins. Those nets drive nothing else, so the data paths are unaffected. This OpenSTA build accepts `set_ideal_network` but does not apply it.

## Results

**Size.** 40,432 cells and 472,680 µm² of standard cells at `7a0d727`, SRAM macros not counted. That includes 76 fanout buffers, 9,842 flops, 32 latches and 2 clock gates.

| Block | Cells | Area (µm²) | Share |
| --- | --- | --- | --- |
| DMA | 10,383 | 198,716 | 42.0% |
| CPU (Ibex RV32IMC, clock gate) | 14,535 | 121,972 | 25.8% |
| PMU, APB crossing, PD_HOST, host FIFOs | 2,338 | 34,945 | 7.4% |
| AXI4 crossbar | 3,644 | 33,506 | 7.1% |
| Memory controllers (macros not counted) | 3,682 | 33,114 | 7.0% |
| TIMER | 1,101 | 10,110 | 2.1% |
| AXI-to-APB bridge | 868 | 6,764 | 1.4% |
| SYS, INTC | 645 | 8,439 | 1.8% |
| CPU port adapters | 105 | 954 | 0.2% |
| Fanout buffers | 76 | 1,141 | 0.2% |
| Top-level glue | 3,052 | 22,985 | 4.9% |

- **The DMA is the largest block.** Its read and write FIFOs (32 beats each, 4,352 bits) are flops; a register-file macro would remove most of that area.
- **The TIMER is large for what it does.** Its 64-bit comparator and counter account for its size.

**Timing at `7a0d727`.**

| Corner | Setup WNS | Setup TNS | Hold WNS | Worst setup by clock |
| --- | --- | --- | --- | --- |
| `tt_025C_1v80` | +0.290 ns | 0 | +0.106 ns | clk_sys +0.290, pclk +12.32, clk_aon +996.5 |
| `ff_100C_1v95` | +5.083 ns | 0 | −0.023 ns (TNS −0.344) | clk_sys +5.08, pclk +13.68 |
| `ss_n40C_1v40` | −49.055 ns | −154,778 ns | +1.039 ns | clk_sys −49.06, pclk −0.019, clk_aon +986.1 |

- **tt.** Every path meets 50 MHz for `clk_sys` and 62.5 MHz for `pclk`. Register to register, the worst slack is +3.99 ns; the +0.290 ns worst path ends at an M3 output port with its assumed 6 ns external budget.
- **ff.** Setup meets everywhere. Hold misses by up to 23 ps on a few paths into the SRAM macros' input pins, against the macros' assumed 0.2 ns hold. This is the kind of miss hold buffers fix during layout.
- **ss (1.40 V, −40 °C).** Not met: the docs/01 sign-off rule (setup at ss) fails. The worst path at `7a0d727` arrives at 65.7 ns against 19.75 ns:
  - It starts in Ibex's ID/EX stage, where the load or store address is computed: 20.5 ns in the CPU.
  - It crosses the crossbar's address decode and the round-robin arbiters, where one master's request decides another master's ready: 36.2 ns in the crossbar.
  - It ends in the DMA's AW issue logic and its write-tag FIFO: 7.8 ns in the DMA.

  Both masters react to ready in the same cycle, so the path chains three blocks. In an earlier run of the same RTL, Ibex's own branch-to-fetch-address path was the worst, at 63.9 ns with 57.8 ns inside the CPU. Cells at this corner are about 3.4 times slower than at tt. `pclk` misses by 19 ps. At ss, `clk_sys` would run at about 14.5 MHz.

**What would close ss**, none of it done in this step:
- register slices between the masters and the crossbar (`axi_channel_reg_slice` exists from step 1-2). They cut both chains at one more clock per access;
- Ibex's writeback stage or branch-target ALU for the CPU's own path;
- or a less extreme slow corner. lambdapdk v0.2.9 has no `ss_100C_1v60`.

The reported clock count of every firmware test assumes 50 MHz, so timing is closed at tt and the gap at ss is reported here.

**Run to run.** ABC's mapping changes a little between runs: an earlier run of the same RTL gave tt −0.026 ns and ss pclk +0.40 ns. The table is the run at `7a0d727`.

## CDC check

`flow/cdc/check_cdc.py` reads the flattened generic netlist Yosys writes during synthesis. Each flop is put in the domain of the clock port its clock pin traces back to, through the clock gates. The combinational cone of every flop input is traced back to flops, latches, SRAM outputs and ports. An input fed from another domain, or from an asynchronous port, is a crossing, and it must be one of four kinds:

| Kind | Rule | Count at `7a0d727` |
| --- | --- | --- |
| SYNC | First stage of a `cdc_sync_2ff`, fed by a single register with no logic in between | 26 bits |
| HANDSHAKE | Request or response register of `apb_cdc`, held stable by the handshake | 80 |
| FIFO | A `cdc_async_fifo` memory word, read after its Gray pointer was synchronized | 400 |
| CONTROL | PMU `iso_en` or `save`, which change only while PD_HOST's outputs are idle | 560 (528 flop inputs, 32 latch enables) |

At `7a0d727`: 9,842 flops, 32 latches and 4 SRAM macros checked, every crossing one of these kinds, PASS. Asynchronous reset and set pins are not data inputs and are not checked; every reset reaches its flops through a `rst_sync`.

**What the check found.** `host_if`'s idle flag was a combinational decode of its 5-bit command counter (`pending == 0`), feeding the PMU's synchronizer. While the counter changes several bits at once, the decode can glitch high. The synchronizer can capture the glitch, and the PMU would then accept a power-down with commands outstanding. Simulation cannot show this, because it has no gate delays. The flag is now a flop, set from the counter's next value, so it changes on the same clock as before. Every SoC firmware test still gives the same clock counts.

## Since step 1-9

The numbers above are those of `7a0d727`. Step 2-1 (`4a8e515`, [10_transaction_layer.md](10_transaction_layer.md)) changed the flow:
- **Constraints.** M3 is internal (the transaction layer); the host link's TLP pins have 4.8 ns (30% of `pclk`) input and output delay against `pclk`.
- **CDC check.** `PORT_DOMAIN` puts those pins in the `pclk` domain; every other port stays in `clk_sys`.
- **Fanout buffering.** `buffer_fanout.py` writes an escaped name with brackets in it (from an unpacked array) with its terminating space.
- **Register slice.** Its data registers moved out of its reset process; in it, synthesis turned the reset net into a data input.

Step 2-2 ([11_nvme_queues.md](11_nvme_queues.md)) added to the flow:
- **STA summary.** `summary_<corner>.txt` also gives the worst setup slack of the paths that start in the transaction layer (`u_pwr.u_host_if.u_tl`) and in the NVMe controller (`u_pwr.u_host_if.u_nvme`).
- **Area by block.** The NVMe controller is a block of its own.

The results after step 2-1 are in docs/10, and those after step 2-2 in docs/11.

## Limits

- **Pre-layout only.**
  - No placement, clock or reset trees, or wires.
  - Recovery and removal are not checked.
  - Hold is fixed in layout.
- **Assumed SRAM timing and no SRAM area.**
- **The CDC check's allowed kinds are name patterns** for these blocks (synchronizer, crossing, FIFO, PMU outputs); a new crossing structure needs its own rule. It checks structure, not the protocol around it; the power testbench and the FIFO tests cover the protocols.
- **Local only.** The flow does not run in CI.

## How to run

```bash
make -C flow                      # libraries, synthesis, CDC check, STA, area
make -C flow sta                  # STA again on the existing netlist
```

Reports: `build/syn/stat.txt`, `build/sta/summary_<corner>.txt`, `build/sta/setup_paths_<corner>.rpt`, `build/sta/hold_paths_<corner>.rpt`, `build/sta/check_setup_<corner>.rpt`.
