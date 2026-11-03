# 不写命令, 只读所有邮箱字 (确认 BRAM 可读且 PS 是否在写任何东西)
set cab [lindex $argv 0]
connect
targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
foreach i {0 1 2 16 17 18 19} {
    puts ">> MB\[$i\] = [lindex [mrd -force [expr {$MB+4*$i}] 1] 1]"
}
# 试试写一个不触发 PS 轮询的位置 (MB[30] = 结果区外)
mwr -force [expr {$MB+120}] 1 0x55AA55AA
puts ">> MB[30] write-read = [lindex [mrd -force [expr {$MB+120}] 1] 1] (expect 55AA55AA)"
exit
