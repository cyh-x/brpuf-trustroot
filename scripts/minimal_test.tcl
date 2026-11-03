connect
set ok 0
for {set i 0} {$i < 8} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9*"}}]} { set ok 1; break }
    catch { targets 1 }
    catch { rst -system }
    after 2000
}
if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
catch { stop }; after 300
set root [file normalize [file join [file dirname [info script]] ..]]
uplevel #0 [list source $root/pr_out/ps7_init_gp0.tcl]
catch { ps7_init }
puts ">> ps7_init done"
# 只做读, 不写
puts ">> APER = [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> UART CR = [lindex [mrd -force 0xE0001000 1] 1]"
# 尝试一个 mask_write (和 ps7_init 内部一样的方式)
if {[catch { mask_write 0xF8000120 0xFFFFFFFF 0x1F006200 } e]} {
    puts ">> mask_write FAIL: $e"
} else {
    puts ">> mask_write OK, APER = [lindex [mrd -force 0xF8000120 1] 1]"
}
exit
