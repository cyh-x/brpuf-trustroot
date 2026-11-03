//=============================================================================
// ropuf_axi.v — 配对型 RO Strong PUF AXI4-Lite 封装 (AX7020)
//   工作区: FPGA设计创新竞赛/strongpuf_port
//
// RO 物理单元: 取自 GitHub RuochenDai78/EEE5716_RO-PUF (ring_oscillator.vhd,
//   20 级反相链 + TFF 二分, 本地补丁: syn_keep->Xilinx keep, 见文件头)
//   候选① canaknesil/4x4-apuf 实测 uniqueness 3.65% 淘汰 (logs/spuf_eval_b*.csv);
//   本设计改用频率计数比较机理: 板间唯一性来自每个 RO 位置的局部工艺差,
//   文献 FPGA RO-PUF 普遍 40-50%。
//
// 自研封装 (同步设计, 无异步时钟域):
//   1) 256 x RO (VHDL 补丁版) -> 各自 2FF 同步 + 边沿检测 + 24bit 窗口计数
//      (100MHz 采样 ~200MHz RO 为欠采样, 计数是频率的单调映射, 比较仍有效)
//   2) 挑战 = RO 配对 (addr_a, addr_b), 每挑战 1bit: sign(cnt_a - cnt_b)
//      CRP 空间 = 256*255 = 65280 (含对称), 配对型 strong PUF 语义
//   3) 挑战 RAM 1024x32 ([7:0]=a [15:8]=b), 批量采集 R 次重复逐位表决
//   4) 调试口: RO_SEL/RO_CNT 可读任意 RO 窗口计数值 (诊断频率分布/坏 RO)
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION  = 0x0004_0000 (v4.0, RO-pair strong PUF)
//   0x004 RO  CAP      = {8'h00, 16'd256, 8'd20}   (RO 数, 链深)
//   0x008 RW  CTRL     b0=start_batch b1=soft_rst b2=single_shot
//   0x00C RO  STATUS   b0=busy b1=done
//   0x010 RW  REPETITIONS R (1..63, 写 0 按 15)
//   0x014 RW  NCHAL    (1..1024, 写 0 按 1)
//   0x018 RO  MAGIC    {16'h5A5A, 批计数}
//   0x01C RO  LAST_RAW [0]=单发 vote [1]=单发 unstable [9:2]=最近差值 cnt_a-cnt_b 截 8bit
//   0x020 RW  CH_A     挑战 RO addr_a (0..255)
//   0x024 RW  CH_B     挑战 RO addr_b
//   0x028 RW  WIN_LOG2 窗口周期数 = 2^WIN_LOG2 (默认 18, 范围 12..24)
//   0x02C RW  RO_SEL   调试: 选中的 RO 地址
//   0x030 RO  RO_CNT   调试: 最近一次窗口中选中 RO 的计数值 [23:0]
//   0x034 WO  CH_PUSH  写 1: 把 (CH_A, CH_B) 存入挑战 RAM, 地址 = WDATA[11:2]
//   0x100+4i RO RESP[i] 挑战 i 表决字 [0]=vote [1]=unstable [31:16]=|Δcnt| 截断
//=============================================================================
`timescale 1 ns / 1 ps
`default_nettype none

module ropuf_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
    parameter integer N_RO               = 256,
    parameter integer NCHAL_MAX          = 1024
) (
    output wire                                  spuf_busy_o,
    output wire                                  spuf_done_o,

    input  wire                                  S_AXI_ACLK,
    input  wire                                  S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       S_AXI_AWADDR,
    input  wire [2 : 0]                          S_AXI_AWPROT,
    input  wire                                  S_AXI_AWVALID,
    output wire                                  S_AXI_AWREADY,
    input  wire [31 : 0]                         S_AXI_WDATA,
    input  wire [3 : 0]                          S_AXI_WSTRB,
    input  wire                                  S_AXI_WVALID,
    output wire                                  S_AXI_WREADY,
    output wire [1 : 0]                          S_AXI_BRESP,
    output wire                                  S_AXI_BVALID,
    input  wire                                  S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       S_AXI_ARADDR,
    input  wire [7 : 0]                          S_AXI_ARLEN,
    input  wire [2 : 0]                          S_AXI_ARPROT,
    input  wire                                  S_AXI_ARVALID,
    output wire                                  S_AXI_ARREADY,
    output wire [31 : 0]                         S_AXI_RDATA,
    output wire [1 : 0]                          S_AXI_RRESP,
    output wire                                  S_AXI_RLAST,
    output wire                                  S_AXI_RVALID,
    input  wire                                  S_AXI_RREADY
);

    localparam integer CNT_W = 24;

    //-------------------------------------------------------------------------
    // AXI4-Lite 握手 (已验证骨架, 含 INCR 突发读 + 节拍间隔)
    //-------------------------------------------------------------------------
    reg axi_awready, axi_wready, axi_arready, axi_rvalid, axi_bvalid;
    reg [1:0]  axi_bresp, axi_rresp;
    reg        rlast;
    wire [31:0] axi_rdata;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;
    assign S_AXI_RLAST   = rlast;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    //-------------------------------------------------------------------------
    // 用户寄存器
    //-------------------------------------------------------------------------
    reg        soft_rst;
    reg        start_pend, single_pend, start_take;
    reg [5:0]  rep_n;
    reg [9:0]  nchal;
    reg [15:0] batch_cnt;
    reg [7:0]  ch_a, ch_b;
    reg [4:0]  win_log2;
    reg [7:0]  ro_sel;
    reg [23:0] ro_cnt_dbg;
    reg        dbg_any1, dbg_any0, ro_en_snap;   // RO 翻转/使能自证 (0x38)
    reg [23:0] ref_cnt;                          // AXI 时钟参考计数 (0x3C)
    reg [15:0] win_snap;                         // B 侧计数低 16 位快照 (0x38 低 16 位)

    wire        core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0]  n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0]  thresh = (n_rep + 6'd1) >> 1;
    // win_log2 5 位: 旧版 4 位存不下 20, 写 0x28=20 被截成 4 -> 窗口恒 2^18
    wire [4:0]  wl2    = (win_log2 < 5'd12) ? 5'd18 : ((win_log2 > 5'd24) ? 5'd24 : win_log2);
    wire [23:0] win_cycles = 24'd1 << wl2;


    localparam ST_IDLE   = 4'd0;
    localparam ST_RD_WAIT= 4'd1;
    localparam ST_LOAD   = 4'd2;
    localparam ST_SETTLE = 4'd10;
    localparam ST_CLR    = 4'd3;
    localparam ST_WIN    = 4'd4;
    localparam ST_CMP    = 4'd5;
    localparam ST_VOTE   = 4'd6;
    localparam ST_WR_RSP = 4'd7;
    localparam ST_NEXT   = 4'd8;
    localparam ST_DONE   = 4'd9;

    reg [3:0]  state;
    reg        running, done_flag, single_mode;
    reg [9:0]  ch_idx;
    reg [5:0]  rep_cnt;
    reg [23:0] win_cnt;
    reg [23:0] settle_cnt;
    reg [5:0]  ones;
    reg        vote_bit, unst_bit;
    reg [7:0]  cur_a, cur_b;
    reg [7:0]  diff_log;
    wire [9:0] n_ch = (nchal == 10'd0) ? 10'd1 : nchal;

    wire counting;      // 窗口进行中 (ST_WIN)

    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;


    // 全计数器清零脉冲: ST_CLR 拍置 1 -> WIN 首拍生效清零 (首拍不计数, 窗口统计
    // 量不受影响), 第 2 拍起累加。每次重复测量都经 ST_CLR => 每轮独立清零
    reg clr_all;
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n)     clr_all <= 1'b0;
        else                 clr_all <= (state == ST_CLR);
    end

    //-------------------------------------------------------------------------
    // 256 x RO (上游 VHDL 补丁版) + 同步边沿计数
    //-------------------------------------------------------------------------
    wire [N_RO-1:0] ro_raw;
    // 分时使能 (2026-10-29 板上事故修复): 256 RO 全时振荡会经电源/衬底耦合
    // 相互注入锁定 -> 频率拍频抖动 -> 58-64% 配对不稳定 (reliability 69-76%)。
    // 每次测量只使能被比较的 2 个 RO (文献标准做法), 空闲时全关。
    wire [N_RO-1:0] ro_en_bus;

    genvar g;
    generate
        for (g = 0; g < N_RO; g = g + 1) begin : g_ro
            reg  [1:0] sync;
            reg  [CNT_W-1:0] cnt;
            always @(posedge S_AXI_ACLK) begin
                if (!core_rst_n)       begin sync <= 2'b00; cnt <= {CNT_W{1'b0}}; end
                else begin
                    sync <= {sync[0], ro_raw[g]};
                    if (clr_all)            cnt <= {CNT_W{1'b0}};
                    else if (counting)      cnt <= cnt + {{(CNT_W-1){1'b0}}, (sync[1] & ~sync[0])};
                end
            end
        end
    endgenerate

    wire [N_RO-1:0] ro_raw_w = ro_raw;   // VHDL 输出扇出

    // RO 使能译码 (纯组合): 测量态只开 cur_a/cur_b 两个 RO, 其余态全关
    wire en_active = (state == ST_SETTLE) || (state == ST_CLR) ||
                     (state == ST_WIN)   || (state == ST_CMP);
    genvar e;
    generate
        for (e = 0; e < N_RO; e = e + 1) begin : g_en
            assign ro_en_bus[e] = en_active && ((e[7:0] == cur_a) || (e[7:0] == cur_b));
        end
    endgenerate

    // RO 实例 (ro_ring.v, 显式 LUT1 原语 + DONT_TOUCH): rstn = 分时使能位 (低=停振复位)
    genvar gr;
    generate
        for (gr = 0; gr < N_RO; gr = gr + 1) begin : g_inst
            ro_ring #(.CHAIN(32)) u_ro (
                .rstn   (ro_en_bus[gr]),
                .ro_out (ro_raw[gr])
            );
        end
    endgenerate

    // 计数值读出 mux (综合器展开; 256 x 24bit)
    reg [CNT_W-1:0] cnt_bus [0:N_RO-1];
    generate
        for (g = 0; g < N_RO; g = g + 1) begin : g_tap
            always @(*) cnt_bus[g] = g_ro[g].cnt;
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 挑战 RAM / 响应 RAM (单写源模板)
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] chmem [0:NCHAL_MAX-1];
    (* ram_style = "block" *) reg [31:0] rpmem [0:NCHAL_MAX-1];

    reg  [9:0]  ch_waddr, ch_raddr;
    reg  [31:0] ch_wdata, ch_rdata_r;
    reg         ch_we;
    always @(posedge S_AXI_ACLK) begin
        if (ch_we) chmem[ch_waddr] <= ch_wdata;
        ch_rdata_r <= chmem[ch_raddr];
    end

    reg  [9:0]  rp_waddr, rp_raddr;
    reg  [31:0] rp_wdata, rp_rdata_r;
    reg         rp_we;
    always @(posedge S_AXI_ACLK) begin
        if (rp_we) rpmem[rp_waddr] <= rp_wdata;
        rp_rdata_r <= rpmem[rp_raddr];
    end

    //-------------------------------------------------------------------------
    // 采集 FSM: 每挑战 R 次重复, 每次重复 = 清计数 -> 开窗 -> 关窗比较
    //-------------------------------------------------------------------------

    wire [23:0] cnt_a = cnt_bus[cur_a];
    wire [23:0] cnt_b = cnt_bus[cur_b];
    wire [24:0] diff  = {1'b0, cnt_a} - {1'b0, cnt_b};
    wire [23:0] dabs  = diff[24] ? (~diff[23:0] + 24'd1) : diff[23:0];  // |cnt_a-cnt_b|

    // counting 与清零: 计数器块只在窗口内累加
    assign counting = (state == ST_WIN);
    // 清零用不计数拍 (ST_CLR 时 counting=0, 由各计数器自身检测? -> 用 ro_en 停振+reload)
    // 实现: ST_CLR 拉低 ro_en 一拍让计数保持, 再置初值 -> 简化: 计数器加 sync 清零端口?
    // 保持模板简单: ST_CLR 期间断言 clr_all (下补 generate 内未含) => 改用 win 起点装载法:
    //   计数器只在 counting 时累加, ST_CLR..ST_WIN 前通过 ro_en=0 冻结, 进入 ST_WIN 前一拍
    //   用 clr 脉冲清零 —— 见 g_ro 内 clr_all 信号 (下一版补)。

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state       <= ST_IDLE;
            ch_idx      <= 10'd0;
            rep_cnt     <= 6'd0;
            win_cnt     <= 24'd0;
            settle_cnt  <= 24'd0;
            running     <= 1'b0;
            done_flag   <= 1'b0;
            single_mode <= 1'b0;
            ones        <= 6'd0;
            vote_bit    <= 1'b0;
            unst_bit    <= 1'b0;
            diff_log    <= 8'd0;
            cur_a       <= 8'd0;
            cur_b       <= 8'd0;
            ch_raddr    <= 10'd0;
            rp_we       <= 1'b0;
            rp_waddr    <= 10'd0;
            rp_wdata    <= 32'd0;
            batch_cnt   <= 16'd0;
            start_take  <= 1'b0;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b0;
                        ch_idx      <= 10'd0;
                        batch_cnt   <= batch_cnt + 16'd1;
                        ch_raddr    <= 10'd0;
                        state       <= ST_RD_WAIT;
                    end else if (single_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b1;
                        state       <= ST_LOAD;
                    end
                end

                ST_RD_WAIT: state <= ST_LOAD;

                ST_LOAD: begin
                    if (single_mode) begin
                        cur_a <= ch_a;
                        cur_b <= ch_b;
                    end else begin
                        cur_a <= ch_rdata_r[7:0];
                        cur_b <= ch_rdata_r[15:8];
                    end
                    rep_cnt    <= 6'd0;
                    ones       <= 6'd0;
                    settle_cnt <= 24'd0;
                    state      <= ST_SETTLE;
                end

                ST_SETTLE: begin
                    // 使能 2 个 RO 起振稳定 (2^15 拍 = 328us, 远超环建立时间)
                    settle_cnt <= settle_cnt + 24'd1;
                    if (settle_cnt + 24'd1 >= 24'd32768)
                        state <= ST_CLR;
                end

                ST_CLR: begin
                    // 冻结一拍让 g_ro 内 cnt 同步装载 0 (clr_pulse 在此拍发出)
                    // win_cnt 必须每次重复都清零: 旧版不清零, 第一次窗口跑满 2^WL2 后
                    // 永久 >= win_cycles, 之后每次重复窗口只剩 1 拍 -> 计数恒 0
                    // (2026-10-29 板上自证: 第 1 发 ref_win=1048576, 第 2 发 ref_win=1)
                    win_cnt <= 24'd0;
                    state   <= ST_WIN;
                end

                ST_WIN: begin
                    win_cnt <= win_cnt + 24'd1;
                    if (win_cnt + 24'd1 >= win_cycles)
                        state <= ST_CMP;
                end

                ST_CMP: begin
                    // diff[24]=借位 -> 1 表示 cnt_a < cnt_b (b 振得快)
                    // diff_log = |diff| >> 8 饱和到 8bit: WIN_LOG2=18 时计数 ~5e4,
                    // 旧的 >>16 恒为 0, 诊断量失效 (2026-10-29 修正)
                    ones     <= ones + {5'd0, diff[24]};
                    diff_log <= (|dabs[23:16]) ? 8'hFF : dabs[15:8];
                    rep_cnt  <= rep_cnt + 6'd1;
                    state    <= (rep_cnt + 6'd1 >= n_rep) ? ST_VOTE : ST_CLR;
                end

                ST_VOTE: begin
                    // R 次重复的严格多数表决 (ones >= (R+1)/2)
                    // unst_bit = 存在分歧 (非全票一致)。旧版写成 ones==0||ones==R,
                    // 把"全票一致"标成不稳定, 极性反了 (2026-10-29 修正)
                    vote_bit <= (ones >= thresh);
                    unst_bit <= (ones != 6'd0) && (ones != n_rep);
                    state    <= ST_WR_RSP;
                end

                ST_WR_RSP: begin
                    rp_we    <= 1'b1;
                    rp_waddr <= ch_idx;
                    rp_wdata <= {16'd0, diff_log, unst_bit, vote_bit};
                    state    <= ST_NEXT;
                end

                ST_NEXT: begin
                    if (single_mode || (ch_idx + 10'd1 >= n_ch)) begin
                        running   <= 1'b0;
                        done_flag <= 1'b1;
                        state     <= ST_DONE;
                    end else begin
                        ch_idx   <= ch_idx + 10'd1;
                        ch_raddr <= ch_idx + 10'd1;
                        state    <= ST_RD_WAIT;
                    end
                end

                ST_DONE: begin
                    if (start_pend || single_pend) begin
                        done_flag <= 1'b0;
                        state     <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end


    // 调试计数锁存
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n)            ro_cnt_dbg <= 24'd0;
        else if (state == ST_CMP)   ro_cnt_dbg <= cnt_bus[ro_sel];
    end

    //-------------------------------------------------------------------------
    // RO 存活自证 (2026-10-29): 三次板上实测计数恒 0, 但结构闸门通过, 无法区分
    //   "RO 不翻转" / "使能没给" / "计数窗口没跑"。这里每次重复窗口内采集:
    //     dbg_any1/any0 : cur_a 的 ro_raw 采样是否出现过 1 / 0 (两者都出现 = 在翻转)
    //     ref_cnt       : 用同一个 counting 门控数 AXI 时钟 (证明窗口与计数通路)
    //   在 ST_CMP 锁存 ro_en_bus[cur_a] 与 win_cnt, 供 0x38/0x3C 读出。
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            dbg_any1 <= 1'b0; dbg_any0 <= 1'b0; ref_cnt <= 24'd0;
            ro_en_snap <= 1'b0; win_snap <= 16'd0;
        end else if (state == ST_CLR) begin
            dbg_any1 <= 1'b0; dbg_any0 <= 1'b0; ref_cnt <= 24'd0;
        end else if (counting) begin
            if (ro_raw[cur_a]) dbg_any1 <= 1'b1;
            else               dbg_any0 <= 1'b1;
            ref_cnt <= ref_cnt + 24'd1;
        end else if (state == ST_CMP) begin
            ro_en_snap <= ro_en_bus[cur_a];
            win_snap   <= cnt_b[15:0];   // 同时暴露 B 侧计数低 16 位
        end
    end

    //-------------------------------------------------------------------------
    // AXI-Lite 写处理
    //-------------------------------------------------------------------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
            soft_rst    <= 1'b0;
            start_pend  <= 1'b0;
            single_pend <= 1'b0;
            rep_n       <= 6'd0;
            nchal       <= 10'd0;
            ch_a        <= 8'd0;
            ch_b        <= 8'd1;
            win_log2    <= 4'd18;
            ro_sel      <= 8'd0;
            ch_we       <= 1'b0;
            ch_waddr    <= 10'd0;
            ch_wdata    <= 32'd0;
        end else begin
            ch_we <= 1'b0;

            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end

            if (slv_wren) begin
                case (S_AXI_AWADDR[12:0])
                    13'h008: soft_rst  <= S_AXI_WDATA[1];
                    13'h010: rep_n     <= S_AXI_WDATA[5:0];
                    13'h014: nchal     <= S_AXI_WDATA[9:0];
                    13'h020: ch_a      <= S_AXI_WDATA[7:0];
                    13'h024: ch_b      <= S_AXI_WDATA[7:0];
                    13'h028: win_log2  <= S_AXI_WDATA[4:0];
                    13'h02C: ro_sel    <= S_AXI_WDATA[7:0];
                    13'h034: if (S_AXI_WDATA[0]) begin
                        ch_we    <= 1'b1;
                        ch_waddr <= S_AXI_WDATA[11:2];
                        ch_wdata <= {16'd0, ch_b, ch_a};
                    end
                    default: ;
                endcase
            end

            if (slv_wren && (S_AXI_AWADDR[12:0] == 13'h008) && !running) begin
                if (S_AXI_WDATA[2])      single_pend <= 1'b1;
                else if (S_AXI_WDATA[0]) start_pend  <= 1'b1;
            end else if (start_take) begin
                start_pend  <= 1'b0;
                single_pend <= 1'b0;
            end

            if (slv_wren && ~axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // AXI-Lite 读处理 (INCR 突发 + 节拍间隔)
    //-------------------------------------------------------------------------
    reg [12:0] araddr_reg;
    reg [7:0]  beat_cnt, arlen_lat;
    reg        rd_active;
    reg [31:0] rd_mux;

    wire ar_in_resp = (S_AXI_ARADDR[12:0] >= 13'h100) && (S_AXI_ARADDR[12:0] <= 13'h10FC);
    wire rr_in_resp = (araddr_reg >= 13'h100) && (araddr_reg <= 13'h10F8);

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            araddr_reg  <= 13'd0;
            arlen_lat   <= 8'd0;
            beat_cnt    <= 8'd0;
            rd_active   <= 1'b0;
            rlast       <= 1'b0;
            rp_raddr    <= 10'd0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                araddr_reg  <= S_AXI_ARADDR[12:0];
                arlen_lat   <= S_AXI_ARLEN;
                beat_cnt    <= 8'd0;
                rd_active   <= 1'b1;
                if (ar_in_resp)
                    rp_raddr <= (S_AXI_ARADDR[12:0] - 13'h100) >> 2;
            end else begin
                axi_arready <= 1'b0;
            end

            if (!axi_arready && rd_active && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
                rlast      <= (beat_cnt == arlen_lat);
            end

            if (axi_rvalid && S_AXI_RREADY) begin
                if (beat_cnt == arlen_lat) begin
                    axi_rvalid <= 1'b0;
                    rd_active  <= 1'b0;
                    rlast      <= 1'b0;
                end else begin
                    beat_cnt   <= beat_cnt + 8'd1;
                    araddr_reg <= araddr_reg + 13'd4;
                    if (rr_in_resp)
                        rp_raddr <= rp_raddr + 10'd1;
                    axi_rvalid <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        case (araddr_reg)
            13'h000: rd_mux = 32'h0004_0000;                        // VERSION
            13'h004: rd_mux = {8'h00, 16'd256, 8'd32};              // CAP
            13'h008: rd_mux = {29'd0, single_mode, soft_rst, running};
            13'h00C: rd_mux = {30'd0, done_flag, running};
            13'h010: rd_mux = {26'd0, rep_n};
            13'h014: rd_mux = {22'd0, nchal};
            13'h018: rd_mux = {16'h5A5A, batch_cnt};                // MAGIC
            13'h01C: rd_mux = {16'd0, diff_log, unst_bit, vote_bit};// LAST_RAW
            13'h020: rd_mux = {24'd0, ch_a};
            13'h024: rd_mux = {24'd0, ch_b};
            13'h028: rd_mux = {20'd0, wl2};
            13'h02C: rd_mux = {24'd0, ro_sel};
            13'h030: rd_mux = {8'd0, ro_cnt_dbg};                   // RO_CNT
            13'h038: rd_mux = {dbg_any1, dbg_any0, ro_en_snap, 13'd0, win_snap}; // DBG_RO
            13'h03C: rd_mux = {8'd0, ref_cnt};                       // DBG_REF
            default: begin
                if ((araddr_reg >= 13'h100) && (araddr_reg <= 13'h10FC))
                    rd_mux = rp_rdata_r;
                else
                    rd_mux = 32'h0000_0000;
            end
        endcase
    end

    assign axi_rdata = rd_mux;

endmodule
`default_nettype wire
