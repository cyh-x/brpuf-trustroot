connect
# 不经 hw_server 的目标抽象, 直接对 1 号线缆做原始 JTAG 扫描
if {[catch {jtag sequence 1000 1000 0 -ir 6 0x01 -dr 32 0xFFFFFFFF state SHIFT_DR} e]} {
    puts ">> SEQ_ERR: $e"
} else { puts ">> seq ok" }
foreach c [jtag targets] { puts ">> C [string trim $c]" }
exit
