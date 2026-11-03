set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf
set cab [lindex $argv 0]

proc sel_ok {pat cab} {
    return [expr {![catch {targets -set -filter "name =~ \"$pat\" && jtag_cable_name =~ \"*$cab*\""}]}]
}

connect
# 1) 恢复 DAP: 反复 system reset 直到 A9 可见
set ok 0
for {set i 0} {$i < 4} {incr i} {
    if {[sel_ok "*Cortex-A9 MPCore #0*" $cab]} { set ok 1; break }
    catch {targets -set -filter {name =~ "*DAP*"}}
    catch {rst -system}
    after 1200
}
if {!$ok} {
    puts ">> DAP_UNRECOVERED"
    foreach t [targets] { puts ">>  [string trim $t]" }
    exit 1
}
puts ">> A9 visible"
catch { rst -processor }; catch { stop }; after 300
uplevel #0 [list source $ps7tcl]
catch { ps7_init }
catch { ps7_post_config }
puts ">> PS7 init done"
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit
after 800
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { stop }
puts ">> downloading app..."
if {[catch {dow -force $elf} e]} { puts ">> DOW_FAIL: $e"; exit 1 }
puts ">> app downloaded, running"
con
after 2000
if {[catch {stop} e2]} { puts ">> (still running - good)" } else { puts ">> PC=[format 0x%08X $pc]" }
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
set MB 0x1F000000
puts ">> RSP[0] status = [format 0x%08X [rd [expr {$MB+16}]]] (expect 0x00000100)"
wr [expr {$MB+0}] 0xA5A50001
after 20
wr [expr {$MB+0}] 0xA5A50001
wr [expr {$MB+4}] 1
after 500
puts ">> PING: [format 0x%08X [rd [expr {$MB+16}]]] [format 0x%08X [rd [expr {$MB+20}]]] PUF_VER=[format 0x%08X [rd [expr {$MB+24}]]] AES_ST=[format 0x%08X [rd [expr {$MB+28}]]] TRNG_ST=[format 0x%08X [rd [expr {$MB+32}]]]"
puts ">> MB[0] after = [format 0x%08X [rd $MB]]"
exit
