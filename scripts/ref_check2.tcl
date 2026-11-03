connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
puts ">> UART1_REF = [lindex [mrd -force 0xF8000154 1] 1]"
puts ">> UART1_CR  = [lindex [mrd -force 0xE0001000 1] 1]"
puts ">> UART1_SR  = [lindex [mrd -force 0xE000102C 1] 1]"
con
exit
