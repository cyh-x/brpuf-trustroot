connect
targets 1
catch { rst -system }
after 2000
puts ">> after rst -system:"
foreach t [targets] { puts ">>  [string trim $t]" }
exit
