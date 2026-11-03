connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch {rst -processor} e]} { puts ">> RST_WARN: $e" } else { puts ">> processor reset OK" }
catch { stop }
after 300
if {[catch {mrd -force 0xF8007080} r]} { puts ">> MRD_FAIL: $r" } else { puts ">> SLCR = $r (MMU off, physical access OK)" }
exit
