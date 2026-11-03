# UART 时钟门控修复测试
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_v14b.tcl
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }
connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    if {![catch {targets 1}]} { catch { rst -system }; after 500; catch { rst -system } }
    after 2500
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]
if {[catch { ps7_init } e]} { puts ">> PS7_FAIL $e"; exit 1 }

puts ">> APER_CLK_CTRL 初值 = [format 0x%08X [rd 0xF8000120]]"
puts ">> SLCR unlock"
wr 0xF8000008 0x0000767B
after 10
# 开 UART0(bit18) + UART1(bit17)? 按旧值对照: 
# vitistest 是 US+, 不能参考。直接开 bit18/bit17
wr 0xF8000120 [expr {[rd 0xF8000120] | 0x00060000}]
puts ">> 开门控后 = [format 0x%08X [rd 0xF8000120]]"
# 此时 CR 应可写
wr 0xE0001000 0x0000000A
puts ">> CR = [format 0x%08X [rd 0xE0001000]]  (expect 0x0A)"
# 发 'A'
wr 0xE0001030 0x41
puts ">> SR = [format 0x%08X [rd 0xE000102C]]"
exit
