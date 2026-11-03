connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
puts ">> UART1_REF_CTRL (0xF8000154) = [lindex [mrd -force 0xF8000154 1] 1]"
puts ">> UART0_REF_CTRL (0xF8000150) = [lindex [mrd -force 0xF8000150 1] 1]"
puts ">> APER = [lindex [mrd -force 0xF8000120 1] 1]"
puts ">> IOPLL (0xF8000100) = [lindex [mrd -force 0xF8000100 1] 1]"
con
exit
