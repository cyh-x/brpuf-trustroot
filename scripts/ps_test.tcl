set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf
set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -system }; after 800
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]; ps7_init; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 500
# 下载并启动 PS 应用
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; after 300
puts ">> PS ready, downloading app"
dow -force $elf
puts ">> APP downloaded"
con
after 1500
catch { stop }
puts ">> PC=$pc  (expect 0x00100020 附近 = 主循环内)"
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
set MB 0x1F000000
puts ">> 读 RSP 区初始 status: [format 0x%08X [rd [expr {$MB+16}]]]  (expect 0x00000100)"
# 发 PING (cmd=1); 首笔写两遍 (上电首写丢失)
wr [expr {$MB+0}] 0xA5A50001
wr [expr {$MB+0}] 0xA5A50001
wr [expr {$MB+4}] 1
after 300
set s0 [rd [expr {$MB+16}]]
set s1 [rd [expr {$MB+20}]]
set s2 [rd [expr {$MB+24}]]
set s3 [rd [expr {$MB+28}]]
set s4 [rd [expr {$MB+32}]]
puts ">> PING RSP: [format 0x%08X $s0] [format 0x%08X $s1] PUF_VER=[format 0x%08X $s2] AES_ST=[format 0x%08X $s3] TRNG_ST=[format 0x%08X $s4]"
puts ">> CMD cleared? MB[0]=[format 0x%08X [rd $MB]] (expect 0)"
exit
