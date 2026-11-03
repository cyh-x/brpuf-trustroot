# ps_boot2.tcl — v2 启动流程: 先清 DAP + 核复位关 cache, 再 ps7_init(DDR) → 位流 → dow → con
#   关键: 在 CPU 处于 BootROM(MMU/cache 开) 时做调试器内存访问会触发
#         "Cannot flush CPU cache -> APB AP transaction error" 把 DAP 打死。
#         所以任何 DDR 访问前必须先 rst -processor。
set root [file normalize [file join [file dirname [info script]] ..]]
set ps7tcl $root/pr_out/ps7_init_uartfix.tcl
set bit    $root/pr_out/trustroot_uart.bit
set elf    $root/ps_app/ps_uart_app.elf
set BEACON 0x001FF000

proc rd {a} { return [expr {"0x[lindex [mrd -force $a 1] 1]"}] }
proc pcget {} {
    if {![catch {set v [lindex [rrd pc] 1]}]} { return [expr {"0x$v"}] }
    return 0xDEADBEEF
}

connect
# --- 0. 清 DAP sticky (若有) ---
if {[catch {targets 1; rst} e]} { puts ">> dap rst: $e" } else { puts ">> dap rst sent" }
after 2000
if {[catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} { puts ">> SEL_FAIL $e"; exit 1 }
puts ">> TARGET_OK"

# --- 1. 核复位: 关 MMU/cache, 停住 ---
catch { rst -processor }; after 400
catch { stop }; after 200
puts ">> DIAG PC_after_core_rst = [format 0x%08X [pcget]]"

# --- 2. ps7_init (含 DDR) ---
uplevel #0 [list source $ps7tcl]
foreach p {ps7_pll_init_data_3_0 ps7_clock_init_data_3_0 ps7_ddr_init_data_3_0 ps7_mio_init_data_3_0 ps7_peripherals_init_data_3_0} {
    if {[catch {$p} e]} { puts ">> $p FAIL: $e"; exit 1 }
    puts ">> $p OK"
}

# --- 3. DDR 读写验证 ---
if {[catch {
    mwr -force 0x00100000 1 0x12345678
    set v [rd 0x00100000]
    puts ">> DIAG DDR rw = 0x[format %08X $v]"
    if {$v != 0x12345678} { puts ">> DDR_BROKEN"; exit 1 }
} e]} { puts ">> DDR access error: $e"; exit 1 }
puts ">> DDR_OK"

# --- 4. 位流 + level shifter ---
targets -set -filter {name =~ "*xc7z020*"}
fpga $bit; after 1000
puts ">> FPGA_LOADED"
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
if {[catch { ps7_post_config } e]} { puts ">> post_config: $e" } else { puts ">> ps7_post_config OK" }

# --- 5. 加载应用 ---
catch { rst -processor }; after 400
catch { stop }; after 200
if {[catch {dow -force $elf} e]} { puts ">> DOW_FAIL $e"; exit 1 }
puts ">> DIAG after dow PC = [format 0x%08X [pcget]] (expect 0x00100020)"
set w0 [rd 0x00100000]
puts ">> DIAG DDR[0x100000] = 0x[format %08X $w0] (向量表第 0 条应为 0xEA??????)"

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
