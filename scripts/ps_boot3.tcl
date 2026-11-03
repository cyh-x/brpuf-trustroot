# ps_boot3.tcl — v3 启动流程 (关键修正: -bypass-cache-sync)
#   板上 BootROM 已开 MMU/cache, 调试器默认的内存访问要先刷 D-cache,
#   而刷 cache 需让核执行代码 -> 核在 reset/halt 态时该操作超时 ->
#   "Cannot flush CPU cache -> APB AP transaction error -> DAP sticky".
#   解法: 所有调试器内存写 (mwr/dow) 加 -bypass-cache-sync。
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit    $root/pr_out/trustroot_uart.bit
set elf    $root/ps_app/ps_uart_app.elf
set BEACON 0x001FF000

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc wr {a v} { mwr -force -bypass-cache-sync $a 1 $v }
proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    return 0xDEADBEEF
}

connect
# --- 0. 清 DAP sticky ---
if {[catch {targets 1; rst} e]} { puts ">> dap rst: $e" } else { puts ">> dap rst sent" }
after 2000
set ok 0
for {set i 0} {$i < 4} {incr i} {
    if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} { set ok 1; break }
    catch {targets 1; rst}; after 2000
}
if {!$ok} { puts ">> SEL_FAIL"; exit 1 }
puts ">> TARGET_OK"

# --- 1. 核复位 ---
catch { rst -processor }; after 400
catch { stop }; after 200
puts ">> DIAG PC_core_rst = [format 0x%08X [pcget]]"

# --- 2. ps7_init (含 DDR) ---
uplevel #0 [list source $ps7tcl]
foreach p {ps7_pll_init_data_3_0 ps7_clock_init_data_3_0 ps7_ddr_init_data_3_0 ps7_mio_init_data_3_0 ps7_peripherals_init_data_3_0} {
    if {[catch {$p} e]} { puts ">> $p FAIL: $e"; exit 1 }
    puts ">> $p OK"
}

# --- 3. DDR 读写验证 (bypass cache sync) ---
if {[catch {
    wr 0x00100000 0x12345678
    set v [rd 0x00100000]
    puts ">> DIAG DDR rw = 0x[format %08X $v]"
    if {$v != 0x12345678} { puts ">> DDR_BROKEN"; exit 1 }
} e]} { puts ">> DDR access error: $e"; exit 1 }
puts ">> DDR_OK"

# --- 4. 位流 ---
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 1000
puts ">> FPGA_LOADED"
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch { ps7_post_config } e]} { puts ">> post_config: $e" } else { puts ">> ps7_post_config OK" }

# --- 5. 加载应用 ---
catch { rst -processor }; after 400
catch { stop }; after 200
if {[catch {dow -force -bypass-cache-sync $elf} e]} { puts ">> DOW_FAIL $e"; exit 1 }
puts ">> DIAG after dow PC = [format 0x%08X [pcget]] (expect 0x00100020)"
puts ">> DIAG DDR@0x100000 = 0x[format %08X [rd 0x00100000]] (应为 0xEAxxxxxx 向量表)"

# --- 6. 运行 ---
con
after 2000
catch { stop }; after 200
puts ">> RUN PC = [format 0x%08X [pcget]]"
catch { puts ">> RUN beacon=[format 0x%08X [rd $BEACON]] hb=[format 0x%08X [rd [expr {$BEACON+4}]]] pufver=[format 0x%08X [rd [expr {$BEACON+24}]]]" }
catch { puts ">> RUN UART cr=0x[format %08X [rd 0xE0001000]] mr=0x[format %08X [rd 0xE0001004]] baud=0x[format %08X [rd 0xE0001018]] sr=0x[format %08X [rd 0xE000102C]]" }
catch { con }
puts ">> RUNNING"
exit
