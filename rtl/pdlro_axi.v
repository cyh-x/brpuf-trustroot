//=============================================================================
// pdlro_axi.v — 挑战可编程 RO Strong PUF (v6.0, 2026-10-29)
//
//   单个 pdl_ring (64 级 PDL 环振), 挑战 = 64bit 图案; 响应对 = (图案A, 图案B)
//   的环频比较 (窗口计数 + R 次表决)。挑战空间 2^64 图案, 配对 ~2^127。
//   图案 RAM 1024 x 64b: 配对 i 的 A 在地址 2i, B 在 2i+1。
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION  = 0x0006_0000
//   0x004 RO  CAP      = {8'd0, 8'd64, 8'd1, 8'd0}
//   0x008 RW  CTRL     b0=start_batch b1=soft_rst b2=single
//   0x00C RO  STATUS   b0=busy b1=done
//   0x010 RW  REPETITIONS R
//   0x014 RW  NCHAL    (配对数, 1..512, 写 0 按 1)
//   0x018 RO  MAGIC    {16'h5A5A, batch_cnt}
//   0x01C RO  LAST_RAW {16'd0, diff_log, unst, vote}
//   0x020 RW  CH_LO    图案 [31:0]
//   0x024 RW  CH_HI    图案 [63:32]
//   0x028 RW  WIN_LOG2 (12..24, 默认 20)
//   0x02C RW  STEP     [4:0] (默认 1)
//   0x030 RW  TUNE     [4:0]
//   0x034 WO  CH_PUSH  1: {CH_HI,CH_LO} -> 图案RAM[WDATA[11:2]]
//   0x038 RO  DBG      {any1, any0, 13'd0, cntB[15:0]}
//   0x03C RO  DBG_REF  窗口A参考计数
//   0x100+4i RO RESP[i]
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module pdlro_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
    parameter integer NPAIR_MAX          = 512
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
    reg [1:0]  axi_bresp, axi_rresp;
    reg        axi_arready, axi_rvalid, rlast;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    //-------------------------------------------------------------------------
    reg        soft_rst;
    reg        start_pend, single_pend, start_take;
    reg [5:0]  rep_n;
    reg [9:0]  nchal;
    reg [15:0] batch_cnt;
    reg [31:0] ch_lo, ch_hi;
    reg [4:0]  win_log2, step_val, tune_val;

    wire        core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0]  n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0]  thresh = (n_rep + 6'd1) >> 1;
    wire [4:0]  wl2    = (win_log2 < 5'd12) ? 5'd20 : ((win_log2 > 5'd24) ? 5'd24 : win_log2);
    wire [23:0] win_cycles = 24'd1 << wl2;

    localparam [4:0] ST_IDLE   = 5'd0;
    localparam [4:0] ST_RD_A   = 5'd1;   // 设 A 地址
    localparam [4:0] ST_RD_A2  = 5'd2;   // 等 RAM 输出寄存
    localparam [4:0] ST_LD_A   = 5'd3;   // ring_ch <- A
    localparam [4:0] ST_SET_A  = 5'd4;   // 环频稳定
    localparam [4:0] ST_CLR_A  = 5'd5;   // 清计数
    localparam [4:0] ST_WIN_A  = 5'd6;   // 窗口计数 A
    localparam [4:0] ST_RD_B   = 5'd7;   // 设 B 地址
    localparam [4:0] ST_RD_B2  = 5'd8;
    localparam [4:0] ST_LD_B   = 5'd9;   // ring_ch <- B
    localparam [4:0] ST_SET_B  = 5'd10;
    localparam [4:0] ST_CLR_B  = 5'd11;
    localparam [4:0] ST_WIN_B  = 5'd12;
    localparam [4:0] ST_CMP    = 5'd13;  // 比较并累计表决
    localparam [4:0] ST_VOTE   = 5'd14;
    localparam [4:0] ST_WR_RSP = 5'd15;
    localparam [4:0] ST_NEXT   = 5'd16;
    localparam [4:0] ST_DONE   = 5'd17;

    reg [4:0]  state;
    reg        running, done_flag, single_mode;
    reg [9:0]  ch_idx;
    reg [5:0]  rep_cnt, ones;
    reg [23:0] win_cnt, settle_cnt, cnt_a, ref_cnt;
    reg        vote_bit, unst_bit;
    reg [7:0]  diff_log;
    reg        dbg_any1, dbg_any0;
    reg [15:0] cntb_snap;

    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;

    //-------------------------------------------------------------------------
    // PDL 环振 + 计数
    //-------------------------------------------------------------------------
    reg [63:0] ring_ch;
    wire       ro_raw;

    pdl_ring #(.NSTAGE(64)) u_ring (
        .rstn   (core_rst_n),
        .tune   (tune_val),
        .ch     (ring_ch),
        .step   (step_val),
        .ro_out (ro_raw));

    reg [1:0]  sync;
    reg [23:0] cnt;
    reg        clr_all;
    wire       counting;

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            sync <= 2'b00; cnt <= 24'd0;
        end else begin
            sync <= {sync[0], ro_raw};
            if (clr_all)       cnt <= 24'd0;
            else if (counting) cnt <= cnt + {{(23){1'b0}}, (sync[1] & ~sync[0])};
        end
    end

    //-------------------------------------------------------------------------
    // 图案 RAM (1024 x 64b) / 响应 RAM (512 x 32b)
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [63:0] patmem [0:2*NPAIR_MAX-1];
    (* ram_style = "block" *) reg [31:0] rpmem  [0:NPAIR_MAX-1];

    reg [10:0] pat_waddr, pat_raddr;
    reg [63:0] pat_wdata, pat_rdata_r;
    reg        pat_we;
    always @(posedge S_AXI_ACLK) begin
        if (pat_we) patmem[pat_waddr] <= pat_wdata;
        pat_rdata_r <= patmem[pat_raddr];
    end

    reg [9:0]  rp_waddr, rp_raddr;
    reg [31:0] rp_wdata, rp_rdata_r;
    reg        rp_we;
    always @(posedge S_AXI_ACLK) begin
        if (rp_we) rpmem[rp_waddr] <= rp_wdata;
        rp_rdata_r <= rpmem[rp_raddr];
    end

    //-------------------------------------------------------------------------
    // 采集 FSM
    //-------------------------------------------------------------------------
    localparam SETTLE_CYC = 24'd4096;   // 41us: 挑战切换后环频稳定

    wire [24:0] diff = {1'b0, cnt_a} - {1'b0, cnt};
    wire [23:0] dabs = diff[24] ? (~diff[23:0] + 24'd1) : diff[23:0];
    assign counting = (state == ST_WIN_A) || (state == ST_WIN_B);

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state <= ST_IDLE; running <= 1'b0; done_flag <= 1'b0; single_mode <= 1'b0;
            ch_idx <= 10'd0; rep_cnt <= 6'd0; ones <= 6'd0;
            win_cnt <= 24'd0; settle_cnt <= 24'd0; cnt_a <= 24'd0; ref_cnt <= 24'd0;
            vote_bit <= 1'b0; unst_bit <= 1'b0; diff_log <= 8'd0;
            dbg_any1 <= 1'b0; dbg_any0 <= 1'b0; cntb_snap <= 16'd0;
            rp_we <= 1'b0; rp_waddr <= 10'd0; rp_wdata <= 32'd0;
            batch_cnt <= 16'd0; start_take <= 1'b0; pat_raddr <= 11'd0;
            ring_ch <= 64'd0; clr_all <= 1'b0;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;
            clr_all    <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b0;
                        ch_idx      <= 10'd0;
                        rep_cnt     <= 6'd0;
                        ones        <= 6'd0;
                        batch_cnt   <= batch_cnt + 16'd1;
                        state       <= ST_RD_A;
                    end else if (single_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b1;
                        ring_ch     <= {ch_hi, ch_lo};   // single: A=CH, B=~CH
                        rep_cnt     <= 6'd0;
                        ones        <= 6'd0;
                        settle_cnt  <= 24'd0;
                        dbg_any1    <= 1'b0; dbg_any0 <= 1'b0; ref_cnt <= 24'd0;
                        state       <= ST_SET_A;
                    end
                end

                ST_RD_A: begin                    // 批量: 取图案 A (地址 2*ch_idx)
                    pat_raddr  <= {1'b0, ch_idx, 1'b0};
                    rep_cnt    <= 6'd0;
                    ones       <= 6'd0;
                    settle_cnt <= 24'd0;
                    dbg_any1   <= 1'b0; dbg_any0 <= 1'b0; ref_cnt <= 24'd0;
                    state      <= ST_RD_A2;
                end

                ST_RD_A2: state <= ST_LD_A;       // 等 pat_rdata_r 有效

                ST_LD_A: begin
                    ring_ch <= pat_rdata_r;
                    state   <= ST_SET_A;
                end

                ST_SET_A: begin
                    settle_cnt <= settle_cnt + 24'd1;
                    if (settle_cnt + 24'd1 >= SETTLE_CYC) begin
                        settle_cnt <= 24'd0;
                        state      <= ST_CLR_A;
                    end
                end

                ST_CLR_A: begin
                    clr_all <= 1'b1;
                    win_cnt <= 24'd0;             // 每次窗口必须清零 (win_cnt 教训)
                    state   <= ST_WIN_A;
                end

                ST_WIN_A: begin
                    win_cnt <= win_cnt + 24'd1;
                    ref_cnt <= ref_cnt + 24'd1;
                    if (sync[1]) dbg_any1 <= 1'b1; else dbg_any0 <= 1'b1;
                    if (win_cnt + 24'd1 >= win_cycles) state <= ST_RD_B;
                end

                ST_RD_B: begin                    // 取图案 B (地址 2*ch_idx+1)
                    cnt_a <= cnt;                 // 锁存 A 计数
                    if (single_mode) begin
                        ring_ch <= ~{ch_hi, ch_lo};
                        state   <= ST_SET_B;
                    end else begin
                        pat_raddr <= {1'b0, ch_idx, 1'b1};
                        state     <= ST_RD_B2;
                    end
                end

                ST_RD_B2: state <= ST_LD_B;

                ST_LD_B: begin
                    ring_ch <= pat_rdata_r;
                    state   <= ST_SET_B;
                end

                ST_SET_B: begin
                    settle_cnt <= settle_cnt + 24'd1;
                    if (settle_cnt + 24'd1 >= SETTLE_CYC) begin
                        settle_cnt <= 24'd0;
                        state      <= ST_CLR_B;
                    end
                end

                ST_CLR_B: begin
                    clr_all <= 1'b1;
                    win_cnt <= 24'd0;
                    state   <= ST_WIN_B;
                end

                ST_WIN_B: begin
                    win_cnt <= win_cnt + 24'd1;
                    ref_cnt <= ref_cnt + 24'd1;
                    if (win_cnt + 24'd1 >= win_cycles) state <= ST_CMP;
                end

                ST_CMP: begin
                    ones     <= ones + {5'd0, diff[24]};            // 1 = A 慢于 B
                    // 细分辨率 (v6.1): |Δ|>>3 饱和 8bit -> 分辨率 8 计数 (旧 >>8 的 256 太粗,
                    // 带状筛选需要区分 噪声档(~30) 与 芯片失配档(~100+)
                    diff_log <= (|dabs[23:11]) ? 8'hFF : dabs[10:3];
                    cntb_snap<= cnt[15:0];
                    rep_cnt  <= rep_cnt + 6'd1;
                    if (rep_cnt + 6'd1 >= n_rep) begin
                        state <= ST_VOTE;
                    end else begin
                        // 下一重复: 重新载 A
                        if (single_mode) begin
                            ring_ch <= {ch_hi, ch_lo};
                            settle_cnt <= 24'd0;
                            state   <= ST_SET_A;
                        end else begin
                            pat_raddr  <= {1'b0, ch_idx, 1'b0};
                            state      <= ST_RD_A2;    // 地址已设, 只等一拍再载
                        end
                    end
                end

                ST_VOTE: begin
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
                        ch_idx <= ch_idx + 10'd1;
                        state  <= ST_RD_A;
                    end
                end

                ST_DONE: if (!start_pend && !single_pend) state <= ST_IDLE;

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
            axi_awready <= 1'b0; axi_wready <= 1'b0; axi_bvalid <= 1'b0; axi_bresp <= 2'b00;
            soft_rst <= 1'b0; start_pend <= 1'b0; single_pend <= 1'b0;
            rep_n <= 6'd0; nchal <= 10'd0; ch_lo <= 32'd0; ch_hi <= 32'd0;
            win_log2 <= 5'd20; step_val <= 5'd1; tune_val <= 5'd0;
            pat_we <= 1'b0; pat_waddr <= 11'd0; pat_wdata <= 64'd0;
        end else begin
            pat_we <= 1'b0;

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
                    13'h020: ch_lo     <= S_AXI_WDATA;
                    13'h024: ch_hi     <= S_AXI_WDATA;
                    13'h028: win_log2  <= S_AXI_WDATA[4:0];
                    13'h02C: step_val  <= S_AXI_WDATA[4:0];
                    13'h030: tune_val  <= S_AXI_WDATA[4:0];
                    13'h034: if (S_AXI_WDATA[0]) begin
                        pat_we    <= 1'b1;
                        pat_waddr <= S_AXI_WDATA[11:2];
                        pat_wdata <= {ch_hi, ch_lo};
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
    // AXI-Lite 读处理
    //-------------------------------------------------------------------------
    reg [12:0] araddr_reg;
    reg [7:0]  beat_cnt, arlen_lat;
    reg        rd_active;
    reg [31:0] rd_mux;

    wire ar_in_resp = (S_AXI_ARADDR[12:0] >= 13'h100) && (S_AXI_ARADDR[12:0] <= 13'h10FC);
    wire rr_in_resp = (araddr_reg >= 13'h100) && (araddr_reg <= 13'h10F8);

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0; axi_rvalid <= 1'b0; axi_rresp <= 2'b00;
            araddr_reg <= 13'd0; arlen_lat <= 8'd0; beat_cnt <= 8'd0;
            rd_active <= 1'b0; rlast <= 1'b0; rp_raddr <= 10'd0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                araddr_reg  <= S_AXI_ARADDR[12:0];
                arlen_lat   <= S_AXI_ARLEN;
                beat_cnt    <= 8'd0;
                rd_active   <= 1'b1;
                if (ar_in_resp) rp_raddr <= (S_AXI_ARADDR[12:0] - 13'h100) >> 2;
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
                    axi_rvalid <= 1'b0; rd_active <= 1'b0; rlast <= 1'b0;
                end else begin
                    beat_cnt <= beat_cnt + 8'd1;
                    araddr_reg <= araddr_reg + 13'd4;
                    if (rr_in_resp) rp_raddr <= rp_raddr + 10'd1;
                    axi_rvalid <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        case (araddr_reg)
            13'h000: rd_mux = 32'h0006_0000;                          // VERSION
            13'h004: rd_mux = {8'd0, 8'd64, 8'd1, 8'd0};              // CAP
            13'h008: rd_mux = {29'd0, single_mode, soft_rst, running};
            13'h00C: rd_mux = {30'd0, done_flag, running};
            13'h010: rd_mux = {26'd0, rep_n};
            13'h014: rd_mux = {22'd0, nchal};
            13'h018: rd_mux = {16'h5A5A, batch_cnt};
            13'h01C: rd_mux = {16'd0, diff_log, unst_bit, vote_bit};
            13'h020: rd_mux = ch_lo;
            13'h024: rd_mux = ch_hi;
            13'h028: rd_mux = {27'd0, wl2};
            13'h02C: rd_mux = {27'd0, step_val};
            13'h030: rd_mux = {27'd0, tune_val};
            13'h038: rd_mux = {dbg_any1, dbg_any0, 13'd0, cntb_snap};
            13'h03C: rd_mux = {8'd0, ref_cnt};
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
