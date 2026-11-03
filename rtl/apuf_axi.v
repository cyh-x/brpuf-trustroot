//=============================================================================
// apuf_axi.v — PDL 仲裁 PUF (v5.0, 2026-10-29)
//
// 方法移植自 Majzoobi et al. 2014 "Automated Design...of Arbiter-based PUF on
// FPGA using Programmable Delay Lines":
//   * 每级 = LUT6 配成反相器 (O=~I0), I1..I5 作可编程延迟控制 —— 不同控制值在
//     LUT 内部经过不同物理路径, 延迟步进亚皮秒级 (PDL);
//   * 交换开关在"延迟域"实现: 挑战位 ch[i] 让上链取 step 档、下链取 0 档
//     (或反之), 上下路径物理上完全平行, 不存在交叉布线 (4x4-apuf 3.65% 的死因);
//   * 首级 tune LUT (控制字 TUNE_T/TUNE_B) 用于调谐消除布线系统偏置;
//   * 66 级反相 (1 tune + 64 ch + 1 定极性) -> 偶数次反相, 链尾与链头同相;
//   * 仲裁 = FDCE: 上链尾接 D, 下链尾接 C —— 下链边沿先到则采到上链电平。
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION  = 0x0005_0000
//   0x004 RO  CAP      = {8'd1, 8'd64, 8'd5, 8'd0} (实例/级数/步进位宽/保留)
//   0x008 RW  CTRL     b0=start_batch b1=soft_rst b2=single
//   0x00C RO  STATUS   b0=busy b1=done
//   0x010 RW  REPETITIONS R (1..63, 写 0 按 15)
//   0x014 RW  NCHAL    (1..1024, 写 0 按 1)
//   0x018 RO  MAGIC    {16'h5A5A, batch_cnt}
//   0x01C RO  LAST_RAW {16'd0, ones[5:0], unst, vote}  ones=R 次中1的个数(裕量诊断)
//   0x020 RW  CH_LO    挑战 [31:0]  (级 0..31)
//   0x024 RW  CH_HI    挑战 [63:32] (级 32..63)
//   0x028 RW  STEP     [4:0] PDL 步进档 (默认 1)
//   0x02C RW  TUNE_T   [4:0] 上链 tune 档
//   0x030 RW  TUNE_B   [4:0] 下链 tune 档
//   0x034 WO  CH_PUSH  1: {CH_HI,CH_LO} -> 挑战RAM[WDATA[11:2]]
//   0x100+4i RO RESP[i] 同 LAST_RAW 格式
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module apuf_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
    parameter integer NSTAGE             = 64,
    parameter integer NCHAL_MAX          = 1024
)(
    output wire        spuf_busy_o,
    output wire        spuf_done_o,
    input  wire        S_AXI_ACLK,
    input  wire        S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]  S_AXI_AWPROT,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [7:0]  S_AXI_ARLEN,
    input  wire [2:0]  S_AXI_ARPROT,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RLAST,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY
);

    localparam integer CHW = 2 * NSTAGE;   // 128? no: NSTAGE=64 -> 64bit 挑战

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = rd_mux;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RLAST   = rlast;
    assign S_AXI_RVALID  = axi_rvalid;

    reg        axi_awready, axi_wready, axi_bvalid;
    reg [1:0]  axi_bresp;
    reg        axi_arready, axi_rvalid, axi_rresp_unused;
    reg [1:0]  axi_rresp;
    reg        rlast;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    //-------------------------------------------------------------------------
    // 用户寄存器
    //-------------------------------------------------------------------------
    reg        soft_rst;
    reg        start_pend, single_pend, start_take;
    reg [5:0]  rep_n;
    reg [9:0]  nchal;
    reg [15:0] batch_cnt;
    reg [63:0] ch_lohi;      // {CH_HI, CH_LO}
    reg [4:0]  step_val, tune_t, tune_b;

    wire        core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0]  n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0]  thresh = (n_rep + 6'd1) >> 1;

    localparam ST_IDLE   = 4'd0;
    localparam ST_RD_WAIT= 4'd1;
    localparam ST_LOAD   = 4'd2;
    localparam ST_SETTLE = 4'd3;
    localparam ST_CLR    = 4'd4;
    localparam ST_LAUNCH = 4'd5;
    localparam ST_WAIT1  = 4'd6;
    localparam ST_RELEASE= 4'd7;
    localparam ST_WAIT2  = 4'd8;
    localparam ST_VOTE   = 4'd9;
    localparam ST_WR_RSP = 4'd10;
    localparam ST_NEXT   = 4'd11;
    localparam ST_DONE   = 4'd12;

    reg [3:0]  state;
    reg        running, done_flag, single_mode;
    reg [9:0]  ch_idx, ch_raddr;
    reg [5:0]  rep_cnt, ones;
    reg [9:0]  wait_cnt;
    reg        vote_bit, unst_bit;
    reg [5:0]  ones_last;

    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;

    //-------------------------------------------------------------------------
    // PDL 双链 (显式 LUT6 原语 + DONT_TOUCH; 同 slice 上下对由构建脚本锁定)
    //   t[0]=launch -> u_tt(tune) -> t[1] -> 64 x u_ts -> t[65] -> u_tf -> t[66]
    //-------------------------------------------------------------------------
    wire launch;
    (* dont_touch = "true", keep = "true" *) wire [66:0] t, b;

    assign t[0] = launch;
    assign b[0] = launch;

    LUT6 #(.INIT(64'h5555555555555555)) u_tt (
        .O(t[1]), .I0(t[0]), .I1(tune_t[0]), .I2(tune_t[1]),
        .I3(tune_t[2]), .I4(tune_t[3]), .I5(tune_t[4]));
    LUT6 #(.INIT(64'h5555555555555555)) u_bt (
        .O(b[1]), .I0(b[0]), .I1(tune_b[0]), .I2(tune_b[1]),
        .I3(tune_b[2]), .I4(tune_b[3]), .I5(tune_b[4]));

    genvar gi;
    generate
        for (gi = 0; gi < NSTAGE; gi = gi + 1) begin : g_stage
            wire [4:0] ct = ch_lohi[gi]     ? step_val : 5'd0;
            wire [4:0] cb = ch_lohi[gi]     ? 5'd0     : step_val;
            LUT6 #(.INIT(64'h5555555555555555)) u_ts (
                .O(t[gi+2]), .I0(t[gi+1]), .I1(ct[0]), .I2(ct[1]),
                .I3(ct[2]), .I4(ct[3]), .I5(ct[4]));
            LUT6 #(.INIT(64'h5555555555555555)) u_bs (
                .O(b[gi+2]), .I0(b[gi+1]), .I1(cb[0]), .I2(cb[1]),
                .I3(cb[2]), .I4(cb[3]), .I5(cb[4]));
        end
    endgenerate

    // 定极性收尾级 (66 次反相 -> 偶): 控制恒 0
    LUT6 #(.INIT(64'h5555555555555555)) u_tf (
        .O(t[66]), .I0(t[65]), .I1(1'b0), .I2(1'b0), .I3(1'b0), .I4(1'b0), .I5(1'b0));
    LUT6 #(.INIT(64'h5555555555555555)) u_bf (
        .O(b[66]), .I0(b[65]), .I1(1'b0), .I2(1'b0), .I3(1'b0), .I4(1'b0), .I5(1'b0));

    // 启动 FF 与仲裁 FF (显式原语, 布局锁定)
    reg  launch_d;
    (* dont_touch = "true" *) wire arb_q_raw;
    reg  arb_clr;

    FDRE #(.INIT(1'b0)) u_launch (
        .Q(launch), .D(launch_d), .C(S_AXI_ACLK), .CE(1'b1), .R(1'b0));
    FDCE #(.INIT(1'b0)) u_arb (
        .Q(arb_q_raw), .D(t[66]), .C(b[66]), .CLR(arb_clr), .CE(1'b1));

    // 仲裁 Q 两级同步采样
    (* dont_touch = "true" *) reg q_s1, q_s2;
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin q_s1 <= 1'b0; q_s2 <= 1'b0; end
        else             begin q_s1 <= arb_q_raw; q_s2 <= q_s1; end
    end

    //-------------------------------------------------------------------------
    // 挑战 RAM / 响应 RAM
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [63:0] chmem [0:NCHAL_MAX-1];
    (* ram_style = "block" *) reg [31:0] rpmem [0:NCHAL_MAX-1];

    reg [9:0]  ch_waddr, rp_waddr, rp_raddr;
    reg [63:0] ch_wdata, ch_rdata_r;
    reg        ch_we;
    always @(posedge S_AXI_ACLK) begin
        if (ch_we) chmem[ch_waddr] <= ch_wdata;
        ch_rdata_r <= chmem[ch_raddr];
    end

    reg [31:0] rp_wdata, rp_rdata_r;
    reg        rp_we;
    always @(posedge S_AXI_ACLK) begin
        if (rp_we) rpmem[rp_waddr] <= rp_wdata;
        rp_rdata_r <= rpmem[rp_raddr];
    end

    //-------------------------------------------------------------------------
    // 采集 FSM: 每挑战 R 次重复, 每次 = 清仲裁 -> 发射边沿 -> 等待 -> 采 Q -> 释放
    //-------------------------------------------------------------------------
    localparam WAIT_LAUNCH = 10'd400;   // 4us > 66 级链传播 (~100ns) 充裕
    localparam WAIT_REL    = 10'd400;

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state <= ST_IDLE; running <= 1'b0; done_flag <= 1'b0; single_mode <= 1'b0;
            ch_idx <= 10'd0; ch_raddr <= 10'd0; rep_cnt <= 6'd0; ones <= 6'd0;
            wait_cnt <= 10'd0; vote_bit <= 1'b0; unst_bit <= 1'b0; ones_last <= 6'd0;
            rp_we <= 1'b0; rp_waddr <= 10'd0; rp_wdata <= 32'd0;
            batch_cnt <= 16'd0; start_take <= 1'b0;
            launch_d <= 1'b0; arb_clr <= 1'b1;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    launch_d <= 1'b0;
                    arb_clr  <= 1'b1;
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
                    rep_cnt <= 6'd0;
                    ones    <= 6'd0;
                    wait_cnt<= 10'd0;
                    state   <= ST_SETTLE;
                end

                ST_SETTLE: begin
                    // 挑战控制位稳定 (大扇出网络)
                    launch_d <= 1'b0;
                    arb_clr  <= 1'b1;
                    if (wait_cnt + 10'd1 >= 10'd16) begin
                        wait_cnt <= 10'd0;
                        state    <= ST_CLR;
                    end else wait_cnt <= wait_cnt + 10'd1;
                end

                ST_CLR: begin
                    // 仲裁 FF 已异步清零, 链头保持 0
                    arb_clr  <= 1'b1;
                    launch_d <= 1'b0;
                    state    <= ST_LAUNCH;
                end

                ST_LAUNCH: begin
                    arb_clr  <= 1'b0;
                    launch_d <= 1'b1;
                    wait_cnt <= 10'd0;
                    state    <= ST_WAIT1;
                end

                ST_WAIT1: begin
                    if (wait_cnt + 10'd1 >= WAIT_LAUNCH) begin
                        ones     <= ones + {5'd0, q_s2};
                        wait_cnt <= 10'd0;
                        state    <= ST_RELEASE;
                    end else wait_cnt <= wait_cnt + 10'd1;
                end

                ST_RELEASE: begin
                    launch_d <= 1'b0;
                    arb_clr  <= 1'b1;
                    state    <= ST_WAIT2;
                end

                ST_WAIT2: begin
                    if (wait_cnt + 10'd1 >= WAIT_REL) begin
                        wait_cnt <= 10'd0;
                        rep_cnt  <= rep_cnt + 6'd1;
                        state    <= (rep_cnt + 6'd1 >= n_rep) ? ST_VOTE : ST_CLR;
                    end else wait_cnt <= wait_cnt + 10'd1;
                end

                ST_VOTE: begin
                    vote_bit  <= (ones >= thresh);
                    unst_bit  <= (ones != 6'd0) && (ones != n_rep);
                    ones_last <= ones;
                    state     <= ST_WR_RSP;
                end

                ST_WR_RSP: begin
                    rp_we    <= 1'b1;
                    rp_waddr <= ch_idx;
                    rp_wdata <= {16'd0, ones_last, unst_bit, vote_bit};
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
                    if (!start_pend && !single_pend) state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    wire [9:0] n_ch = (nchal == 10'd0) ? 10'd1 : nchal;

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
            ch_lohi     <= 64'd0;
            step_val    <= 5'd1;
            tune_t      <= 5'd0;
            tune_b      <= 5'd0;
            ch_we       <= 1'b0;
            ch_waddr    <= 10'd0;
            ch_wdata    <= 64'd0;
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
                    13'h020: ch_lohi[31:0]  <= S_AXI_WDATA[31:0];
                    13'h024: ch_lohi[63:32] <= S_AXI_WDATA[31:0];
                    13'h028: step_val  <= S_AXI_WDATA[4:0];
                    13'h02C: tune_t    <= S_AXI_WDATA[4:0];
                    13'h030: tune_b    <= S_AXI_WDATA[4:0];
                    13'h034: if (S_AXI_WDATA[0]) begin
                        ch_we    <= 1'b1;
                        ch_waddr <= S_AXI_WDATA[11:2];
                        ch_wdata <= ch_lohi;
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
    // AXI-Lite 读处理 (INCR 突发, 与 ropuf_axi 相同节拍)
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
            13'h000: rd_mux = 32'h0005_0000;                          // VERSION
            13'h004: rd_mux = {8'd1, 8'd64, 8'd5, 8'd0};              // CAP
            13'h008: rd_mux = {29'd0, single_mode, soft_rst, running};// CTRL
            13'h00C: rd_mux = {30'd0, done_flag, running};            // STATUS
            13'h010: rd_mux = {26'd0, rep_n};
            13'h014: rd_mux = {22'd0, nchal};
            13'h018: rd_mux = {16'h5A5A, batch_cnt};                  // MAGIC
            13'h01C: rd_mux = {16'd0, ones_last, unst_bit, vote_bit}; // LAST_RAW
            13'h020: rd_mux = ch_lohi[31:0];
            13'h024: rd_mux = ch_lohi[63:32];
            13'h028: rd_mux = {27'd0, step_val};
            13'h02C: rd_mux = {27'd0, tune_t};
            13'h030: rd_mux = {27'd0, tune_b};
            default: begin
                if ((araddr_reg >= 13'h100) && (araddr_reg <= 13'h10FC))
                    rd_mux = rp_rdata_r;
                else
                    rd_mux = 32'h0000_0000;
            end
        endcase
    end

endmodule
`default_nettype wire
