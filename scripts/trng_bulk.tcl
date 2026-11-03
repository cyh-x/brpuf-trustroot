# trng_bulk.tcl — TRNG 批量采样 (64 x 256bit = 2KB) 供随机性检验
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_66m.tcl
set bit $root/pr_out/crypto_ax7020.bit
set cab [lindex $argv 0]
connect
targets -set -filter "name =~ \"*Cortex-A9 MPCore #0*\" && jtag_cable_name =~ \"*$cab*\""
catch { rst -processor }; catch { stop }; after 200
uplevel #0 [list source $ps7tcl]; ps7_init; catch { ps7_post_config }
targets -set -filter "name =~ \"*xc7z020*\" && jtag_cable_name =~ \"*$cab*\""
fpga $bit; after 500
targets -set -filter "name =~ \"*JTAG2AXI*\" && jtag_cable_name =~ \"*$cab*\""
proc rd {a} { return [expr {"0x[lindex [mrd -force $a] 1]"}] }
proc wr {a v} { mwr -force $a $v }
wr 0x40020000 0x01
set fh [open $root/logs/trng_bulk.csv w]
set n 0
for {set k 0} {$k < 64} {incr k} {
    set t 0
    while {([rd 0x40020004] & 2) == 0} { after 5; incr t; if {$t > 8000} { puts ">> timeout k=$k"; close $fh; exit 1 } }
    set line ""
    for {set i 0} {$i < 8} {incr i} { append line [format %08X [rd [expr {0x40020010 + $i*4}]]] }
    puts $fh $line
    incr n
    # key_ready 单拍脉冲: 写 bit1=1 (保持 bit0=1 使能) -> 下一拍写回 0x01
    wr 0x40020000 0x03
    wr 0x40020000 0x01
    if {$k % 16 == 0} { puts ">> $n keys" }
}
close $fh
puts ">> TRNG_BULK_DONE $n keys"
exit
