# 序号选择 + 多级恢复 + ps7_init + fpga + dow + con + 邮箱测试 (单会话)
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf
set cab [lindex $argv 0]
connect
# 恢复: 降 JTAG 频率 (DAP sticky error 常因高频 JTAG)
catch { jtag frequency 1000000 }
after 200
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }

set ok 0
for {set attempt 0} {$attempt < 6} {incr attempt} {
    # A9 通常在 targets 列表第 3 组 (APU->ARM#0); 用 catch 逐个试
    # 一次列出全部目标, 找 A9 所在组的编号
    set sel -1
    if {[catch {set listout [targets]} eL]} { puts ">> targets fail: $eL"; catch { targets 1 }; catch { rst -system }; after 800; continue }
    foreach ln [split $listout "
"] {
        set ln [string trim $ln]
        if {[string match "*Cortex-A9 MPCore #0*" $ln]} {
            regexp {^(\d+)} $ln -> sel
            break
        }
    }
    puts ">> scan: sel=$sel"; if {$sel < 0} { puts ">> FULL LIST:"; foreach ln2 [split $listout "
"] { puts ">>L [string trim $ln2]" } }
        if {$sel < 0} {
        catch { targets 1 }
        catch { rst -system }
        after 1800
        continue
    }
    targets $sel
    catch { rst -processor }; catch { stop }; after 300
    if {[catch { uplevel #0 [list source $ps7tcl] } e0]} { puts ">> tcl src fail"; incr attempt; continue }
    if {[catch { ps7_init } e1]} { puts ">> ps7_init fail (attempt $attempt): $e1"; catch { targets 1 }; catch { rst -system }; after 800; catch { rst -system }; after 800; continue }
    catch { ps7_post_config }
    # fpga: xc7z020 是最后一个组, 序号 = sel+? 用 filter (xc7z020 无 A9 依赖)
    if {[catch { targets -set -filter {name =~ "*xc7z020*"} } e2]} { puts ">> fpga target fail"; continue }
    fpga $bit
    after 800
    targets $sel
    catch { rst -processor }
    after 300
    if {![catch { dow -force $elf }]} {
        puts ">> LOADED (attempt $attempt)"
        set ok 1
        break
    }
    puts ">> dow fail, recovering"
    catch { targets 1 }
    catch { rst -system }
    after 800
    catch { rst -system }
    after 800
}
if {!$ok} { puts ">> GIVE_UP"; exit 1 }

con
after 1500
catch { stop }
after 100
catch { con }
after 200

targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
puts ">> (T0) MB16 = [format 0x%08X [rd [expr {$MB+64}]]]  (expect 0x00000100)"
wr $MB 0xA5A50001
after 400
puts ">> (T1) PING: [format 0x%08X [rd [expr {$MB+68}]]] st=[format 0x%08X [rd [expr {$MB+64}]]] cmd=[format 0x%08X [rd $MB]]"
wr $MB 0xA5A50003
after 1500
puts ">> (T2) TRNG: [format 0x%08X [rd [expr {$MB+68}]]] [format 0x%08X [rd [expr {$MB+72}]]] [format 0x%08X [rd [expr {$MB+76}]]]"
wr $MB 0xA5A50005
after 400
puts ">> (T3) PUF ver: [format 0x%08X [rd [expr {$MB+68}]]]"
wr $MB 0xA5A50004
wr [expr {$MB+4}] 0x12345
after 800
puts ">> (T4) PUF chal: [format 0x%08X [rd [expr {$MB+68}]]]"
exit
