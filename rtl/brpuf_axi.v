//=============================================================================
// brpuf_axi.v — 双稳环 Strong PUF (v8.0, 2026-10-30)
//
//   BR-PUF (Chen et al. 2011): 挑战 = 64bit 环配置 (偶反转数), 响应 = 环稳态位。
//   每挑战 R 次重复: 强制 -> 释放 -> 稳定 -> 采样 -> 表决。
//   RESP 字含 ones 计数 => 注册期可用表决分歧做近平局筛选 (免额外探测器)。
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION = 0x0008_0000
//   0x004 RO  CAP     = {8'd0, 8'd64, 8'd1, 8'd0} (级数/环数)
//   0x008 RW  CTRL    b0=start_batch b1=soft_rst b2=single
//   0x00C RO  STATUS  b0=busy b1=done
//   0x010 RW  REPETITIONS R (1..63, 0->15)
//   0x014 RW  NCHAL   (1..1024, 0->1)
//   0x018 RO  MAGIC   {16'h5A5A, batch_cnt}
//   0x01C RO  LAST_RAW {16'd0, ones[5:0], unst, vote}
//   0x020 RW  CH_LO   挑战 [31:0]
//   0x024 RW  CH_HI   挑战 [63:32]
//   0x034 WO  CH_PUSH 1: {CH_HI,CH_LO} -> 挑战RAM[WDATA[11:2]]
//   0x100+4i RO RESP[i] 同 LAST_RAW 格式
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module brpuf_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
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

    reg        soft_rst;
    reg        start_pend, single_pend, start_take;
    reg [5:0]  rep_n;
    reg [9:0]  nchal;
    reg [15:0] batch_cnt;
    reg [31:0] ch_lo, ch_hi;

    wire       core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0] n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0] thresh = (n_rep + 6'd1) >> 1;

    localparam [3:0] ST_IDLE  = 4'd0;
    localparam [3:0] ST_RD    = 4'd1;   // 设挑战 RAM 地址
    localparam [3:0] ST_RD2   = 4'd2;   // 等 RAM 输出
    localparam [3:0] ST_LD    = 4'd3;   // ring_ch <- 挑战
    localparam [3:0] ST_SET   = 4'd4;   // en=0 强制
    localparam [3:0] ST_REL   = 4'd5;   // en=1 释放
    localparam [3:0] ST_SETL  = 4'd6;   // 稳定等待
    localparam [3:0] ST_SMP   = 4'd7;   // 采样累加
    localparam [3:0] ST_VOTE  = 4'd8;
    localparam [3:0] ST_WR    = 4'd9;
    localparam [3:0] ST_NEXT  = 4'd10;
    localparam [3:0] ST_DONE  = 4'd11;

    reg [3:0]  state;
    reg        running, done_flag, single_mode;
    reg [9:0]  ch_idx;
    reg [5:0]  rep_cnt, ones;
    reg [15:0] wait_cnt;
    reg        vote_bit, unst_bit;
    reg [5:0]  ones_last;

    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;

    //-------------------------------------------------------------------------
    // 双稳环 + 采样同步
    //-------------------------------------------------------------------------
    reg [63:0] ring_ch;
    reg        ring_en;
    wire       br_raw;

    br_ring #(.NSTAGE(64)) u_ring (
        .en     (ring_en),
        .ch     (ring_ch),
        .br_out (br_raw));

    (* dont_touch = "true" *) reg q_s1, q_s2;
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin q_s1 <= 1'b0; q_s2 <= 1'b0; end
        else             begin q_s1 <= br_raw; q_s2 <= q_s1; end
    end

    //-------------------------------------------------------------------------
    // 挑战 RAM / 响应 RAM
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [63:0] patmem [0:NCHAL_MAX-1];
    (* ram_style = "block" *) reg [31:0] rpmem  [0:NCHAL_MAX-1];

    reg [9:0]  pat_waddr, pat_raddr;
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
    // FSM: 每挑战 R 次 (强制 2us -> 释放 20us -> 采样)
    //-------------------------------------------------------------------------
    localparam SET_CYC  = 16'd200;    // 2us 强制传播
    localparam REL_CYC  = 16'd2000;   // 20us 稳定

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state <= ST_IDLE; running <= 1'b0; done_flag <= 1'b0; single_mode <= 1'b0;
            ch_idx <= 10'd0; rep_cnt <= 6'd0; ones <= 6'd0; wait_cnt <= 16'd0;
            vote_bit <= 1'b0; unst_bit <= 1'b0; ones_last <= 6'd0;
            rp_we <= 1'b0; rp_waddr <= 10'd0; rp_wdata <= 32'd0;
            batch_cnt <= 16'd0; start_take <= 1'b0; pat_raddr <= 10'd0;
            ring_ch <= 64'd0; ring_en <= 1'b0;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    ring_en <= 1'b0;
                    if (start_pend) begin
                        start_take <= 1'b1; running <= 1'b1; done_flag <= 1'b0;
                        single_mode <= 1'b0; ch_idx <= 10'd0;
                        batch_cnt <= batch_cnt + 16'd1;
                        pat_raddr <= 10'd0;
                        state <= ST_RD;
                    end else if (single_pend) begin
                        start_take <= 1'b1; running <= 1'b1; done_flag <= 1'b0;
                        single_mode <= 1'b1;
                        ring_ch <= {ch_hi, ch_lo};
                        rep_cnt <= 6'd0; ones <= 6'd0; wait_cnt <= 16'd0;
                        state <= ST_SET;
                    end
                end

                ST_RD: begin
                    pat_raddr <= ch_idx;
                    rep_cnt   <= 6'd0;
                    ones      <= 6'd0;
                    wait_cnt  <= 16'd0;
                    state     <= ST_RD2;
                end

                ST_RD2: state <= ST_LD;

                ST_LD: begin
                    ring_ch <= pat_rdata_r;
                    state   <= ST_SET;
                end

                ST_SET: begin
                    ring_en  <= 1'b0;
                    wait_cnt <= wait_cnt + 16'd1;
                    if (wait_cnt + 16'd1 >= SET_CYC) begin
                        wait_cnt <= 16'd0;
                        ring_en  <= 1'b1;
                        state    <= ST_REL;
                    end
                end

                ST_REL: begin
                    if (wait_cnt + 16'd1 >= REL_CYC) begin
                        wait_cnt <= 16'd0;
                        state    <= ST_SMP;
                    end else wait_cnt <= wait_cnt + 16'd1;
                end

                ST_SMP: begin
                    ones    <= ones + {5'd0, q_s2};
                    rep_cnt <= rep_cnt + 6'd1;
                    if (rep_cnt + 6'd1 >= n_rep) state <= ST_VOTE;
                    else begin
                        wait_cnt <= 16'd0;
                        ring_en  <= 1'b0;
                        state    <= ST_SET;
                    end
                end

                ST_VOTE: begin
                    vote_bit  <= (ones >= thresh);
                    unst_bit  <= (ones != 6'd0) && (ones != n_rep);
                    ones_last <= ones;
                    state     <= ST_WR;
                end

                ST_WR: begin
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
                        ch_idx <= ch_idx + 10'd1;
                        state  <= ST_RD;
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
            pat_we <= 1'b0; pat_waddr <= 10'd0; pat_wdata <= 64'd0;
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
                    13'h008: soft_rst <= S_AXI_WDATA[1];
                    13'h010: rep_n    <= S_AXI_WDATA[5:0];
                    13'h014: nchal    <= S_AXI_WDATA[9:0];
                    13'h020: ch_lo    <= S_AXI_WDATA;
                    13'h024: ch_hi    <= S_AXI_WDATA;
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
            13'h000: rd_mux = 32'h0008_0000;                          // VERSION
            13'h004: rd_mux = {8'd0, 8'd64, 8'd1, 8'd0};              // CAP
            13'h008: rd_mux = {29'd0, single_mode, soft_rst, running};
            13'h00C: rd_mux = {30'd0, done_flag, running};
            13'h010: rd_mux = {26'd0, rep_n};
            13'h014: rd_mux = {22'd0, nchal};
            13'h018: rd_mux = {16'h5A5A, batch_cnt};
            13'h01C: rd_mux = {16'd0, ones_last, unst_bit, vote_bit};
            13'h020: rd_mux = ch_lo;
            13'h024: rd_mux = ch_hi;
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
