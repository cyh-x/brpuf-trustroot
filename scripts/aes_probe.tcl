set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_66m.tcl
set bit $root/pr_out/crypto_ax7020.bit
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
# 1. AES 密钥寄存器写读回 (slv_reg0 可回读)
puts ">> AES key[0] 初始 = [format 0x%08X [rd 0x40010000]]"
wr 0x40010000 0xDEADBEEF
puts ">> 写 0xDEADBEEF 后回读 = [format 0x%08X [rd 0x40010000]]"
wr 0x4001001C 0xCAFEBABE
puts ">> key[7] 写读回 = [format 0x%08X [rd 0x4001001C]]"
# 2. TRNG 对照 (CTRL 可回读)
puts ">> TRNG CTRL 回读 = [format 0x%08X [rd 0x40020000]]"
wr 0x40020000 0x00000001
puts ">> TRNG CTRL 写1后 = [format 0x%08X [rd 0x40020000]]"
# 3. PUF 对照
wr 0x40000020 0x12345678
puts ">> PUF CH_LO 写读回 = [format 0x%08X [rd 0x40000020]]"
# 4. AES 32 位读 STATUS 之外的已知状态演变
puts ">> AES STATUS 循环 10 次读:"
for {set i 0} {$i < 10} {incr i} { puts -nonewline ">> [format 0x%08X [rd 0x40010034]] " }
puts ""
exit
