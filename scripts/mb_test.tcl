# 只碰 JTAG2AXI 做邮箱读写 (假设 PS 应用已在跑)
set cab [lindex $argv 0]
connect
catch { jtag frequency 1000000 }
targets -set -filter {name =~ "*JTAG2AXI*"}
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }
set MB 0x40030000
puts ">> (T0) MB16 = [format 0x%08X [rd [expr {$MB+64}]]]"
wr $MB 0xA5A50001
after 500
puts ">> (T1) PING: [format 0x%08X [rd [expr {$MB+68}]]] st=[format 0x%08X [rd [expr {$MB+64}]]]"
wr $MB 0xA5A50005
after 500
puts ">> (T3) PUF ver: [format 0x%08X [rd [expr {$MB+68}]]]"
exit
