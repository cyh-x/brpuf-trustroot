connect
foreach t [targets] {
    set nm [string trim $t]
    set c ""
    catch { set c [targets -target-properties [targets $nm] -name jtag_cable_name] }
    puts ">>  [$nm] cable_prop=$c"
}
puts ">> --- via filter ---"
foreach t [targets -filter {jtag_cable_name =~ "*"} ] { puts ">>  F: [string trim $t]" }
exit
