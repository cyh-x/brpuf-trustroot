# UART1 CR 寄存器写读回测试 (halt 状态, 无应用干扰)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_v14b.tcl
set cab [lindex $argv 0]
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
puts ">> ps7_init OK, CR = [format 0x%08X [rd 0xE0001000]]  (expect 0x17)"
# 手动覆盖 CR
wr 0xE0001000 0x0000000A
puts ">> 写 0x0A 后 CR = [format 0x%08X [rd 0xE0001000]]  (expect 0x0A)"
# 写 FIFO
wr 0xE0001030 0x41
after 100
puts ">> SR = [format 0x%08X [rd 0xE000102C]]  (TX 后 TXEMPTY 应保持)"
exit
