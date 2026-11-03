connect
puts ">> raw:"
foreach t [targets] { puts ">>T [string trim $t]" }
if {![catch {targets -set -filter {name =~ "*Cortex-A9*"}}]} {
    catch { stop }
    puts ">> A9 selected OK"
    if {![catch {mrd -force 0xE0001000 1} v]} { puts ">> UART CR = $v" }
    if {![catch {mrd -force 0xF8000120 1} v2]} { puts ">> APER = $v2" }
} else {
    puts ">> A9 not visible"
}
exit
