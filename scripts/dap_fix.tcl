connect
targets 1
catch { rst -system }
after 2000
# JTAG 频率降到最低 250kHz 以稳定 DAP
catch { jtag frequency 250000 }
after 500
targets 1
catch { rst -system }
after 2000
puts ">> list:"
foreach t [targets] { puts ">>L [string trim $t]" }
exit
