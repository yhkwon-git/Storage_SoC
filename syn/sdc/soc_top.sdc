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

# The host link's packed TLP pins (step 2-1; the link layer and PHY replace
# them from step 2-6) are synchronous to pclk: 30% of its period on each
# side. Until step 1-9 M3 was a chip port here; it is internal now.
set host_in  [get_ports {host_rx_valid host_rx_data* host_rx_sop host_rx_eop host_rx_ehalf host_tx_ready}]
set host_out [get_ports {host_rx_ready host_tx_valid host_tx_data* host_tx_sop host_tx_eop host_tx_ehalf}]
set_input_delay  4.8 -clock pclk $host_in
set_output_delay 4.8 -clock pclk $host_out
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 -pin X $host_in

# Simulation console and exit, the lock-up flag and the power switch control
# are not timed against a clock.
set_false_path -to [get_ports {console_valid console_char* exit_valid exit_code* cpu_double_fault host_pwr_en}]

set_load 0.01 [all_outputs]
