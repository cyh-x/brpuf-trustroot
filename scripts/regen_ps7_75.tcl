# regen_ps7_75.tcl — 重新生成 ps7_0 IP (FCLK_CLK0 = 75MHz)
set root [file normalize [file join [file dirname [info script]] ..]]
create_project ip_pr2 $root/pr_out/ip2 -part xc7z020clg400-1 -force
create_ip -name processing_system7 -vendor xilinx.com -library ip -module_name ps7_0
foreach {k v} {
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  75
    CONFIG.PCW_FCLK_CLK0_BUF             TRUE
    CONFIG.PCW_EN_CLK0_PORT              1
    CONFIG.PCW_USE_M_AXI_GP0             0
} {
    if {[catch { set_property -name $k -value $v -objects [get_ips ps7_0] } e]} {
        puts ">> PS7_SET_WARN $k=$v : $e"
    } else { puts ">> PS7_SET_OK   $k=$v" }
}
generate_target all [get_ips ps7_0]
synth_ip [get_ips ps7_0]
close_project
puts ">> PS7_75_DONE"
exit
