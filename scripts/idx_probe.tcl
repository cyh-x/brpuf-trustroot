connect
puts ">> targets:"
set i 0
foreach t [targets] {
    puts ">>  [$i] [string trim $t]"
    incr i
}
exit
