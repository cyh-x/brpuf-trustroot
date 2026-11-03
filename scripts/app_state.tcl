# 应用是否在跑: halt 后读 PC
connect
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch { stop }
after 300
puts ">> PC = [lindex [mrd -force 0xE000EDF8 1] 1] (DBGPCSR?)"
# 用核心调试寄存器读 PC
catch { puts ">> r0 = [lindex [mrd -force 0xE000EDF8 1] 1]" }
# 更可靠: 读 OCM 里应用的数据区 (MB 结果区 0x40030000 不可读 via JTAG->GP0... )
# 直接读 OCM 应用的 .data 段 (0x00000204 附近)
puts ">> OCM [lindex [mrd -force 0x00000204 4] 0..3]"
mrd -force 0x00000000 16
con
exit
