# ps_repro13.tcl — v13 基线复现 (完全复刻今晨跑通的 ps_e2e 流程)
#   目的: 断电重启后, 先验证 "JTAG 附着 + ps7_init_gp0 + v13 位流 + v13 elf" 这条已被证实
#   的链路在当前模式下仍然跑通。若跑通 => 模式没问题, 问题在 v14 变更; 若失败 => 模式/板级问题。
#   同时打印模式探测器: PC (0xFFFFFF28=BootROM 等待=JTAG 模式; 其他=SD 卡里有 FSBL 在跑)。
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit    $root/pr_out/trustroot_ax7020.bit
set elf    $root/ps_app/ps_app.elf

proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    return 0xDEADBEEF
}

connect
set ok 0
for {set i 0} {$i < 5} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    catch {targets 1; rst}
    after 2500
}
if {!$ok} { puts ">> DAP_UNRECOVERED"; exit 1 }
puts ">> TARGET_OK"
catch { stop }; after 200
set pcv [pcget]
puts ">> MODE_PROBE PC = [format 0x%08X $pcv]  (0xFFFFFF28=BootROM/JTAG模式; DDR或UBOOT地址=SD模式有卡)"

uplevel #0 [list source $ps7tcl]
catch { ps7_init }
catch { ps7_post_config }
catch { rst -processor }
after 300
puts ">> ps7_init + core reset done"

targets -set -filter {name =~ "*xc7z020*"}
fpga $bit
after 800
puts ">> FPGA_LOADED"

targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
dow -force $elf
puts ">> LOADED"
con
after 1500
catch { stop }
puts ">> PC_after_run = [format 0x%08X [pcget]]"
catch { con }
after 200

# T0: 应用启动时在邮箱写入状态字 0x100 (JTAG2AXI 是独立目标)
targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
puts ">> [T0] MB16 = [format 0x%08X [expr {"0x[lindex [mrd -force [expr {$MB+64}] 1] 1]"}]]  (expect 0x00000100 => v13 基线跑通)"
puts ">> [T1] PING rsp: 先写 0xA5A50001"
mwr -force $MB 1 0xA5A50001
after 400
puts ">>   st=[format 0x%08X [expr {"0x[lindex [mrd -force [expr {$MB+64}] 1] 1]"}]] puf=[format 0x%08X [expr {"0x[lindex [mrd -force [expr {$MB+76}] 1] 1]"}]]"
puts ">> BASELINE_DONE"
exit
