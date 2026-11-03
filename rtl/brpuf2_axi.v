//=============================================================================
// brpuf2_axi.v — 双稳环阵列 Strong PUF (v9.0, 2026-10-30)
//
//   64 环 x 16 级, 每环独占一列 (构建脚本锁定)。挑战 = 22bit:
//     [21:16] 环选择 (0..63), [15:0] 环内图案 (偶 popcount)
//   响应 = 选中环释放后的稳态位。CRP 空间 = 64 x 2^15 = 2^21。
//   RESP 字含 ones 计数 -> 注册期可用表决分歧做近平局筛选。
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION = 0x0009_0000
//   0x004 RO  CAP     = {8'd64, 8'd16, 8'd0, 8'd0} (环数/级数)
//   0x008 RW  CTRL    b0=start_batch b1=soft_rst b2=single
//   0x00C RO  STATUS  b0=busy b1=done
//   0x010 RW  REPETITIONS R
//   0x014 RW  NCHAL
//   0x018 RO  MAGIC
//   0x01C RO  LAST_RAW {16'd0, ones[5:0], unst, vote}
//   0x020 RW  CH_LO   [15:0]=环内图案 [21:16]=环选择 (打包在低 22 位)
//   0x034 WO  CH_PUSH
//   0x100+4i RO RESP[i]
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module brpuf2_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
    parameter integer NRING              = 64,
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
    reg [21:0] ch_word;

    wire       core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0] n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0] thresh = (n_rep + 6'd1) >> 1;

    localparam [3:0] ST_IDLE = 4'd0, ST_RD = 4'd1, ST_RD2 = 4'd2, ST_LD = 4'd3,
                     ST_SET  = 4'd4, ST_REL = 4'd5, ST_SETL = 4'd6, ST_SMP = 4'd7,
                     ST_VOTE = 4'd8, ST_WR   = 4'd9, ST_NEXT = 4'd10, ST_DONE = 4'd11;

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
    // 64 环阵列 + 选择译码 + 输出 mux
    //-------------------------------------------------------------------------
    reg [5:0]  ring_sel;
    reg [15:0] ring_pat;
    reg        ring_go;          // 选中环的释放脉冲 (SET 期间为 0, REL 为 1)
    wire [NRING-1:0] br_bus;

    genvar g;
    generate
        for (g = 0; g < NRING; g = g + 1) begin : g_ring
            br_ring16 u_ring (
                .en     (ring_go && (ring_sel == g[5:0])),
                .ch     (ring_pat),
                .br_out (br_bus[g]));
        end
    endgenerate

    (* dont_touch = "true" *) reg q_s1, q_s2;
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin q_s1 <= 1'b0; q_s2 <= 1'b0; end
        else             begin q_s1 <= br_bus[ring_sel]; q_s2 <= q_s1; end
    end

    //-------------------------------------------------------------------------
    // 挑战 RAM (32b: [21:16] 环号 [15:0] 图案) / 响应 RAM
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [31:0] chmem [0:NCHAL_MAX-1];
    (* ram_style = "block" *) reg [31:0] rpmem [0:NCHAL_MAX-1];

    reg [9:0]  ch_waddr, ch_raddr, rp_waddr, rp_raddr;
    reg [31:0] ch_wdata, ch_rdata_r, rp_wdata, rp_rdata_r;
    reg        ch_we, rp_we;
    always @(posedge S_AXI_ACLK) begin
        if (ch_we) chmem[ch_waddr] <= ch_wdata;
        ch_rdata_r <= chmem[ch_raddr];
    end
    always @(posedge S_AXI_ACLK) begin
        if (rp_we) rpmem[rp_waddr] <= rp_wdata;
        rp_rdata_r <= rpmem[rp_raddr];
    end

    //-------------------------------------------------------------------------
    // FSM: 每挑战 R 次 (复位 2us -> 释放 20us -> 采样)
    //-------------------------------------------------------------------------
    localparam SET_CYC = 16'd200;
    localparam REL_CYC = 16'd2000;

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state <= ST_IDLE; running <= 1'b0; done_flag <= 1'b0; single_mode <= 1'b0;
            ch_idx <= 10'd0; rep_cnt <= 6'd0; ones <= 6'd0; wait_cnt <= 16'd0;
            vote_bit <= 1'b0; unst_bit <= 1'b0; ones_last <= 6'd0;
            rp_we <= 1'b0; rp_waddr <= 10'd0; rp_wdata <= 32'd0;
            batch_cnt <= 16'd0; start_take <= 1'b0; ch_raddr <= 10'd0;
            ring_sel <= 6'd0; ring_pat <= 16'd0; ring_go <= 1'b0;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    ring_go <= 1'b0;
                    if (start_pend) begin
                        start_take <= 1'b1; running <= 1'b1; done_flag <= 1'b0;
                        single_mode <= 1'b0; ch_idx <= 10'd0;
                        batch_cnt <= batch_cnt + 16'd1;
                        ch_raddr <= 10'd0;
                        state <= ST_RD;
                    end else if (single_pend) begin
                        start_take <= 1'b1; running <= 1'b1; done_flag <= 1'b0;
                        single_mode <= 1'b1;
                        ring_sel <= ch_word[21:16];
                        ring_pat <= ch_word[15:0];
                        rep_cnt <= 6'd0; ones <= 6'd0; wait_cnt <= 16'd0;
                        state <= ST_SET;
                    end
                end

                ST_RD: begin
                    ch_raddr <= ch_idx;
                    rep_cnt  <= 6'd0;
                    ones     <= 6'd0;
                    wait_cnt <= 16'd0;
                    state    <= ST_RD2;
                end

                ST_RD2: state <= ST_LD;

                ST_LD: begin
                    ring_sel <= ch_rdata_r[21:16];
                    ring_pat <= ch_rdata_r[15:0];
                    state    <= ST_SET;
                end

                ST_SET: begin
                    ring_go  <= 1'b0;                     // 全环复位 0
                    wait_cnt <= wait_cnt + 16'd1;
                    if (wait_cnt + 16'd1 >= SET_CYC) begin
                        wait_cnt <= 16'd0;
                        ring_go  <= 1'b1;                 // 释放选中环
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
                        ring_go  <= 1'b0;
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
            rep_n <= 6'd0; nchal <= 10'd0; ch_word <= 22'd0;
            ch_we <= 1'b0; ch_waddr <= 10'd0; ch_wdata <= 32'd0;
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
                    13'h008: soft_rst <= S_AXI_WDATA[1];
                    13'h010: rep_n    <= S_AXI_WDATA[5:0];
                    13'h014: nchal    <= S_AXI_WDATA[9:0];
                    13'h020: ch_word  <= S_AXI_WDATA[21:0];
                    13'h034: if (S_AXI_WDATA[0]) begin
                        ch_we    <= 1'b1;
                        ch_waddr <= S_AXI_WDATA[11:2];
                        ch_wdata <= {10'd0, ch_word};
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
            13'h000: rd_mux = 32'h0009_0000;
            13'h004: rd_mux = {8'd64, 8'd16, 8'd0, 8'd0};
            13'h008: rd_mux = {29'd0, single_mode, soft_rst, running};
            13'h00C: rd_mux = {30'd0, done_flag, running};
            13'h010: rd_mux = {26'd0, rep_n};
            13'h014: rd_mux = {22'd0, nchal};
            13'h018: rd_mux = {16'h5A5A, batch_cnt};
            13'h01C: rd_mux = {16'd0, ones_last, unst_bit, vote_bit};
            13'h020: rd_mux = {10'd0, ch_word};
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
