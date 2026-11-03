# 带多级 DAP 恢复的单会话流程
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf
set cab [lindex $argv 0]
connect
proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }

set ok 0
for {set attempt 0} {$attempt < 6} {incr attempt} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} {
        catch { rst -processor }; catch { stop }; after 300
        uplevel #0 [list source $ps7tcl]
        if {[catch { ps7_init } e]} { puts ">> ps7_init fail: $e"; catch { rst -system }; after 1500; continue }
        catch { ps7_post_config }
        targets -set -filter {name =~ "*xc7z020*"}
        fpga $bit
        after 800
        targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
        catch { rst -processor }
        after 300
        if {![catch { dow -force $elf }]} {
            puts ">> LOADED (attempt $attempt)"
            set ok 1
            break
        }
        puts ">> dow failed, recovering..."
    }
    catch { targets 1 }
    catch { rst -system }
    after 1500
}
if {!$ok} { puts ">> GIVE_UP"; exit 1 }

con
after 1500
catch { stop }
after 100
catch { con }
after 200

# 邮箱测试 (JTAG2AXI 独立目标)
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
