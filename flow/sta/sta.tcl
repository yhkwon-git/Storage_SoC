# OpenSTA script for one corner (flow/sta/run_sta.sh sets the variables):
#   lib     the Sky130 HD liberty file of the corner
#   macros  syn/lib/sram_macros.lib
#   netlist build/syn/soc_top.nl.v
#   sdc     syn/sdc/soc_top.sdc
#   corner  name used in the output
#   out     report directory

read_liberty $lib
read_liberty $macros
read_verilog $netlist
link_design soc_top
read_sdc $sdc

# Reset trees are built like clock trees during layout. Before layout, one
# reset synchronizer drives thousands of reset pins with no buffers, so
# recovery and removal are left to post-layout timing: no check ends at an
# asynchronous reset or set pin here. These nets drive nothing else, so the
# data paths are unaffected. (This OpenSTA build ignores set_ideal_network.)
set rst_pins [get_pins -hierarchical {*/RESET_B */SET_B}]
set_false_path -to $rst_pins
puts "reset and set pins left to post-layout timing: [llength $rst_pins]"

report_checks -path_delay max -group_path_count 3 -fields {slew cap fanout} -digits 3 > $out/setup_paths_$corner.rpt
report_checks -path_delay min -group_path_count 3 -digits 3 > $out/hold_paths_$corner.rpt
check_setup -verbose > $out/check_setup_$corner.rpt

# OpenSTA's internal unit is the second; the summary is in ns.
proc ns {s} { return [format %.3f [expr {$s * 1e9}]] }
set fh [open $out/summary_$corner.txt w]
puts $fh "corner $corner"
puts $fh "setup_wns [ns [sta::worst_slack_cmd max]]"
puts $fh "setup_tns [ns [sta::total_negative_slack_cmd max]]"
puts $fh "hold_wns [ns [sta::worst_slack_cmd min]]"
puts $fh "hold_tns [ns [sta::total_negative_slack_cmd min]]"
foreach clk {clk_sys clk_nand pclk clk_aon} {
  set p [lindex [find_timing_paths -path_delay max -group_path_count 1 -to [get_clocks $clk]] 0]
  if {$p ne ""} { puts $fh "setup_slack_$clk [ns [$p slack]]" }
  set p [lindex [find_timing_paths -path_delay min -group_path_count 1 -to [get_clocks $clk]] 0]
  if {$p ne ""} { puts $fh "hold_slack_$clk [ns [$p slack]]" }
}
# Worst setup slack of the paths that start in each top-level block, and in
# the transaction layer and the NVMe controller inside u_pwr.
foreach blk {u_cpu u_xbar u_dma u_ibus u_dbus u_apb u_sys u_intc u_timer g_mem u_pwr
             u_pwr.u_host_if.u_tl u_pwr.u_host_if.u_nvme} {
  set cells [get_cells -quiet "${blk}*"]
  if {[llength $cells] == 0} { continue }
  set p [lindex [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack -from $cells] 0]
  if {$p ne ""} { puts $fh "from_$blk [ns [$p slack]]" }
}
# Worst setup slack of register-to-register paths in clk_sys (output ports excluded).
set p [lindex [find_timing_paths -path_delay max -group_path_count 1 -sort_by_slack -to [all_registers -data_pins]] 0]
if {$p ne ""} { puts $fh "reg2reg [ns [$p slack]]" }
close $fh
exit
