# soc_top timing constraints (docs/01, section 9; docs/09_timing.md).
# Pre-layout: ideal clocks with a budget for the clock tree to come.

# ---------------------------------------------------------------------------
# Clocks. pclk_in is the PHY PLL's output frequency; the PLL model gates it
# through a dlclkp cell, and the gated clock keeps the name pclk. The CPU's
# gated clock is clk_sys through a dlclkp cell.
# ---------------------------------------------------------------------------
create_clock -name clk_sys  -period 20.0   [get_ports clk_sys]
create_clock -name clk_nand -period 20.0   [get_ports clk_nand]
create_clock -name pclk     -period 16.0   [get_ports pclk_in]
create_clock -name clk_aon  -period 1000.0 [get_ports clk_aon]

set_clock_uncertainty -setup 0.25 [all_clocks]
set_clock_uncertainty -hold  0.10 [all_clocks]
set_clock_transition  0.15        [all_clocks]

# ---------------------------------------------------------------------------
# Crossings. Every path between two of these clocks ends at a synchronizer's
# first flop or at a register that a request/acknowledge handshake holds
# stable (flow/cdc/check_cdc.py checks this on the netlist). A max delay of
# the destination's period bounds the skew between the bits of a Gray
# pointer or a handshake word; hold is not checked across them. There are no
# asynchronous clock groups, which would override these max delays.
# ---------------------------------------------------------------------------
set clocks {clk_sys clk_nand pclk clk_aon}
set period(clk_sys)  20.0
set period(clk_nand) 20.0
set period(pclk)     16.0
set period(clk_aon)  1000.0
foreach a $clocks {
  foreach b $clocks {
    if {$a ne $b} {
      set_max_delay $period($b) -from [get_clocks $a] -to [get_clocks $b]
      set_false_path -hold -from [get_clocks $a] -to [get_clocks $b]
    }
  }
}

# ---------------------------------------------------------------------------
# Inputs and outputs
# ---------------------------------------------------------------------------
# Asynchronous inputs, each synchronized inside: power-on reset, the power
# switch's acknowledge, the wake pin.
set_false_path -from [get_ports {por_n host_pwr_ack host_wake}]

# The M3 AXI port is a chip port until phase 2 puts the transaction layer
# behind it: 30% of the clk_sys period on each side.
set ext_in  [get_ports {ext_awid* ext_awaddr* ext_awlen* ext_awsize* ext_awburst* ext_awprot*
                        ext_awcache* ext_awqos* ext_awvalid ext_wdata* ext_wstrb* ext_wlast
                        ext_wvalid ext_bready ext_arid* ext_araddr* ext_arlen* ext_arsize*
                        ext_arburst* ext_arprot* ext_arcache* ext_arqos* ext_arvalid ext_rready}]
set ext_out [get_ports {ext_awready ext_wready ext_bid* ext_bresp* ext_bvalid ext_arready
                        ext_rid* ext_rdata* ext_rresp* ext_rlast ext_rvalid}]
set_input_delay  6.0 -clock clk_sys $ext_in
set_output_delay 6.0 -clock clk_sys $ext_out
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X $ext_in

# Simulation console and exit, the lock-up flag and the power switch control
# are not timed against a clock.
set_false_path -to [get_ports {console_valid console_char* exit_valid exit_code* cpu_double_fault host_pwr_en}]

set_load 0.01 [all_outputs]
