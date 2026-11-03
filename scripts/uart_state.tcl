connect
targets -set -filter {name =~ "*JTAG2AXI*"}
if {[catch {targets -set -filter {name =~ "*JTAG2AXI*"}}]} { puts ">> no JTAG2AXI"; exit }
# JTAG2AXI 只能访问 PL, 不能读 PS UART。改用: 停 A9 读
exit
