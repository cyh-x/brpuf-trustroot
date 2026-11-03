set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]; ps7_init; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
puts ">> DDR 通路测试 (JTAG -> S_AXI_GP0 -> DDR)"
wr 0x00100000 0xDEADBEEF
wr 0x00100004 0x12345678
wr 0x00100008 0xCAFEBABE
after 20
puts ">> [format 0x%08X [rd 0x00100000]] [format 0x%08X [rd 0x00100004]] [format 0x%08X [rd 0x00100008]]"
puts ">> 期望 DEADBEEF 12345678 CAFEBABE"
exit
