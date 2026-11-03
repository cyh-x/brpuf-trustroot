connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
after 200
puts ">> PC state"
puts ">> UART1 CR = [format 0x%08X [lindex [mrd -force 0xE0001000 1] 1]]"
puts ">> UART1 SR = [format 0x%08X [lindex [mrd -force 0xE000102C 1] 1]]  (bit4=TXFULL bit1=RXEMPTY)"
puts ">> UART1 FIFO = [lindex [mrd -force 0xE0001030 1] 1]"
con
exit
