# UART1 硬件状态调试 (独立脚本, 定义在文件头)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_v14b.tcl
set bit $root/pr_out/trustroot_uart.bit
set elf $root/ps_app/ps_uart_app.elf
set cab [lindex $argv 0]

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }

connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    puts ">> recovering round $i"
    if {![catch {targets 1}]} { catch { rst -system }; after 500; catch { rst -system } }
    after 2500
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]
if {[catch { ps7_init } e]} { puts ">> PS7_FAIL $e"; exit 1 }
catch { ps7_post_config }
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 800
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { rst -processor }; after 300
dow -force $elf
puts ">> loaded"
catch { stop }

puts ">> UART1 SR   = [format 0x%08X [rd 0xE000102C]]"
puts ">> UART1 CR   = [format 0x%08X [rd 0xE0001000]]"
puts ">> UART1 MR   = [format 0x%08X [rd 0xE0001004]]"
puts ">> UART1 BAUD = [format 0x%08X [rd 0xE0001018]]"
puts ">> MIO14 mux  = [format 0x%08X [rd 0xF8000740]]  (expect 0x16E0 for RX)"
puts ">> MIO15 mux  = [format 0x%08X [rd 0xF8000744]]  (expect 0x16E1 for TX)"
puts ">> 强制 CR=0x0A (TXEN|RXEN)"
wr 0xE0001000 0x0000000A
after 10
puts ">> CR now = [format 0x%08X [rd 0xE0001000]]"
puts ">> 写 'A' 进 FIFO"
wr 0xE0001030 0x41
after 5

# 手动往 FIFO 写 'A' 并 con 跑 1 秒, 让 PC COM5 收到
mwr -force 0xE0001030 1 0x41
con
after 1000
catch { stop }
exit
