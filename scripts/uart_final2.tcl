# MIO48/49 版 + UART 时钟门控修复 + 加载应用 + 验证 CR
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uart.tcl
set bit $root/pr_out/trustroot_uart.bit
set elf $root/ps_app/ps_uart_app.elf
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
catch { ps7_post_config }

# --- UART 时钟门控修复 ---
puts ">> APER before = [lindex [mrd -force 0xF8000120 1] 1]"
mask_write 0xF8000008 0xFFFFFFFF 0x0000767B
mask_write 0xF8000120 0xFFFFFFFF 0x1F006200
after 5
puts ">> APER after  = [lindex [mrd -force 0xF8000120 1] 1]"
mask_write 0xE0001018 0x0000FFFF 0x0000007C
mask_write 0xE0001004 0x00000FFF 0x00000020
mask_write 0xE0001000 0x000001FF 0x0000000A
after 5
puts ">> CR = [lindex [mrd -force 0xE0001000 1] 1]  (expect 0000000A)"
# MIO48/49 mux 检查
puts ">> MIO48 mux (0xF80007C0) = [format 0x%08X [rd 0xF80007C0]]  (expect 0x16E1 TX)"
puts ">> MIO49 mux (0xF80007C4) = [format 0x%08X [rd 0xF80007C4]]  (expect 0x16E0 RX)"

targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 800
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { rst -processor }; after 300
dow -force $elf
puts ">> APP loaded"
con
puts ">> APP running - check COM4"
exit
