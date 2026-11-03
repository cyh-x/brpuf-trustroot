# ps_e2e.tcl - two-stage: start (load+run PS app) / test (mailbox via JTAG2AXI)
set root [file normalize [file join [file dirname [info script]] ..]]
set stage [lindex $argv 1]
set cab [lindex $argv 0]
set ps7tcl $root/pr_out/ps7_init_gp0.tcl
set bit $root/pr_out/trustroot_ax7020.bit
set elf $root/ps_app/ps_app.elf

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force $a 1 $v }

if {$stage eq "start"} {
    connect
    set ok 0
    for {set i 0} {$i < 5} {incr i} {
        if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
        if {![catch {targets 1}]} { catch { rst -system } }
        after 1800
    }
    if {!$ok} { puts ">> DAP_DEAD"; exit 1 }
    catch { stop }; after 200
    uplevel #0 [list source $ps7tcl]
    catch { ps7_init }
    catch { ps7_post_config }
    catch { rst -processor }          ;# ps7_init 之后的核复位 (dow 前必需, DDR 配置保留)
    after 300
    puts ">> ps7_init + core reset done"
    targets -set -filter {name =~ "*xc7z020*"}
    fpga $bit
    after 800
    targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
    catch { stop }
    dow -force $elf
    puts ">> LOADED"
    con
    after 1500
    # 单会话内: 短暂 halt 查 PC, 再 con, 然后直接测邮箱 (JTAG2AXI 是独立 TCF 目标)
    catch { stop }
    puts ">> [PCCHK] PC=[expr {[catch {format 0x%08X $pc} e] ? "n/a" : [format 0x%08X $pc]}]"
    catch { con }
    after 200
    targets -set -filter {name =~ "*JTAG2AXI*"}
    set MB 0x40030000
    puts ">> [T0] MB16 = [format 0x%08X [rd [expr {$MB+64}]]]  (expect 0x00000100)"
    puts ">> [T1] PING"
    wr $MB 0xA5A50001
    after 400
    puts ">>   rsp: [format 0x%08X [rd [expr {$MB+68}]]] [format 0x%08X [rd [expr {$MB+72}]]] PUF=[format 0x%08X [rd [expr {$MB+76}]]] st=[format 0x%08X [rd [expr {$MB+64}]]] cmd=[format 0x%08X [rd $MB]]"
    puts ">> [T2] TRNG (cmd=3)"
    wr $MB 0xA5A50003
    after 1500
    puts ">>   key: [format 0x%08X [rd [expr {$MB+68}]]] [format 0x%08X [rd [expr {$MB+72}]]] [format 0x%08X [rd [expr {$MB+76}]]] [format 0x%08X [rd [expr {$MB+80}]]]"
    puts ">> [T3] PUF ver (cmd=5)"
    wr $MB 0xA5A50005
    after 400
    puts ">>   ver = [format 0x%08X [rd [expr {$MB+68}]]]  (expect 0x00090000)"
    puts ">> [T4] PUF single (cmd=4, chal=0x12345)"
    wr $MB 0xA5A50004
    wr [expr {$MB+4}] 0x12345
    after 800
    puts ">>   puf = [format 0x%08X [rd [expr {$MB+68}]]]  ver=[format 0x%08X [rd [expr {$MB+72}]]]"
    exit
}

connect
targets -set -filter {name =~ "*JTAG2AXI*"}
set MB 0x40030000
puts ">> [T0] MB16 = [format 0x%08X [rd [expr {$MB+64}]]]  (expect 0x00000100)"
puts ">> [T1] PING"
wr $MB 0xA5A50001
after 400
puts ">>   rsp: [format 0x%08X [rd [expr {$MB+68}]]] [format 0x%08X [rd [expr {$MB+72}]]] PUF=[format 0x%08X [rd [expr {$MB+76}]]] st=[format 0x%08X [rd [expr {$MB+64}]]] cmd=[format 0x%08X [rd $MB]]"
puts ">> [T2] TRNG (cmd=3)"
wr $MB 0xA5A50003
after 1500
puts ">>   key: [format 0x%08X [rd [expr {$MB+68}]]] [format 0x%08X [rd [expr {$MB+72}]]] [format 0x%08X [rd [expr {$MB+76}]]] [format 0x%08X [rd [expr {$MB+80}]]]"
puts ">> [T3] PUF ver (cmd=5)"
wr $MB 0xA5A50005
after 400
puts ">>   ver = [format 0x%08X [rd [expr {$MB+68}]]]  (expect 0x00090000)"
puts ">> [T4] PUF single (cmd=4, chal=0x12345)"
wr $MB 0xA5A50004
wr [expr {$MB+4}] 0x12345
after 800
puts ">>   puf = [format 0x%08X [rd [expr {$MB+68}]]]  ver=[format 0x%08X [rd [expr {$MB+72}]]]"
exit
