connect
puts ">> A: name-only filter"
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { puts ">> A_FAIL: $e" } else { puts ">> A_OK" }
puts ">> B: with cable filter"
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*" && jtag_cable_name =~ "*210512180081*"}} e2]} { puts ">> B_FAIL: $e2" } else { puts ">> B_OK" }
puts ">> C: which target is set"
if {[catch {set cur [targets -set]} e3]} { puts ">> cur via -set: $cur" } else { puts ">> cur: $cur" }
exit
