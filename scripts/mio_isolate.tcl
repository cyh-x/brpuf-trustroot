# MIO 隔离实验: 不加载应用/位流, 只在 PS 上电初始态读 SLCR (确认 DAP 基线正常)
set cab [lindex $argv 0]
connect
set ok 0
for {set i 0} {$i < 5} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system } }
    after 2000
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { stop }; after 300
# 上电初始态读 SLCR (不跑 ps7_init)
puts ">> [0] APER (0xF8000120) = [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> [0] MIO14 mux (0xF8000740) = [lindex [mrd -force 0xF8000740 1] 1]"
puts ">> [0] MIO48 mux (0xF80007C0) = [lindex [mrd -force 0xF80007C0 1] 1]"
puts ">> [0] UART CR (0xE0001000) = [lindex [mrd -force 0xE0001000 1] 1]"
# 逐步写 MIO14/15 复用, 每写一个读回确认 DAP 还活着
puts ">> 写 MIO14 mux = 0x16E0"
mwr -force 0xF8000740 1 0x000016E0
after 100
puts ">>   alive check: [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> 写 MIO15 mux = 0x16E1"
mwr -force 0xF8000744 1 0x000016E1
after 100
puts ">>   alive check: [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> MIO 读写均正常"
exit
