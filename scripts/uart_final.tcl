# UART 时钟修复 + 端到端测试 (在 ps7_init 之后执行)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_uart_ocm.elf
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
catch { rst -processor }
after 500
catch { stop }
after 500
# 确认 halt 成功再继续
if {[catch {mrd -force 0xF8000120 1} halt_test]} {
    puts ">> halt 后无法读 SLCR: $halt_test"
    # 再试一次
    catch { stop }; after 1000
    if {[catch {mrd -force 0xF8000120 1} halt_test2]} { puts ">> 仍无法读: $halt_test2"; exit 1 }
}
puts ">> CPU halted, SLCR readable"
uplevel #0 [list source $ps7tcl]
# 只跑 PLL/clock/peripherals, 跳过 DDR init (SD 启动残留导致 DDR init 会挂)
if {[catch { ps7_pll_init_data_3_0 } e]} { puts ">> PLL fail $e"; exit 1 }
puts ">> PLL OK"
if {[catch { ps7_clock_init_data_3_0 } e]} { puts ">> CLK fail $e"; exit 1 }
puts ">> CLK OK"
if {[catch { ps7_peripherals_init_data_3_0 } e]} { puts ">> PERIPH fail $e"; exit 1 }
puts ">> PERIPH OK"
puts ">> ps7_init done"

# --- UART 时钟门控修复 (在 ps7_init 之后) ---
# SLCR 解锁 + UART 时钟门控 (用 mask_write 避免总线超时)
mask_write 0xF8000008 0xFFFFFFFF 0x0000767B
after 5
set aper [rd 0xF8000120]
puts ">> APER before = [format 0x%08X $aper]"
mask_write 0xF8000120 0xFFFFFFFF [expr {$aper | 0x00060000}]
after 5
puts ">> APER after  = [format 0x%08X [rd 0xF8000120]]"
# UART1 寄存器配置
mask_write 0xE0001018 0x0000FFFF 0x00000037
mask_write 0xE0001004 0x00000FFF 0x00000020
mask_write 0xE0001000 0x000001FF 0x0000000A
after 5
puts ">> CR = [format 0x%08X [rd 0xE0001000]]  (expect 0x0A)"

# 加载应用并运行
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 800
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { rst -processor }; after 300
dow -force $elf
puts ">> APP loaded"
con
puts ">> APP running - check COM5"
exit
