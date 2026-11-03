connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
after 200
# 读 OCM 里应用的字符串 "Trust Root" 应在 rodata (约 0x00000204+)
puts ">> OCM 0x100-0x120:"
mrd -force 0x00000100 8
# PC 状态
puts ">> halted, app state:"
# UART1 CR 状态
puts ">> CR = [lindex [mrd -force 0xE0001000 1] 1]"
con
exit
