//=============================================================================
// axi_lite_demux.v — AXI-Lite 一主三从桥 (v11.0, 2026-10-31)
//
//   v10 教训: AW/W 直接透传 -> 两通道到达顺序无保证, 写数据错位到相邻地址
//   (板上实测: 写入值落到前一/后一地址)。改为 store-and-forward:
//     AW 有效即锁存地址, W 有效即锁存数据, 两者齐备才向从机同时发起。
//   地址译码: [17:16] => 0=PUF 1=AES 2=TRNG (64KB 间隔)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module axi_lite_demux #(
    parameter integer C_M_ADDR_WIDTH = 32
)(
    input  wire                          M_ACLK,
    input  wire                          M_ARESETN,
    // ---- 主机侧 ----
    input  wire [C_M_ADDR_WIDTH-1:0]     M_AWADDR,
    input  wire                          M_AWVALID,
    output wire                          M_AWREADY,
    input  wire [31:0]                   M_WDATA,
    input  wire [3:0]                    M_WSTRB,
    input  wire                          M_WVALID,
    output wire                          M_WREADY,
    output wire [1:0]                    M_BRESP,
    output wire                          M_BVALID,
    input  wire                          M_BREADY,
    input  wire [C_M_ADDR_WIDTH-1:0]     M_ARADDR,
    input  wire [7:0]                    M_ARLEN,
    input  wire                          M_ARVALID,
    output wire                          M_ARREADY,
    output wire [31:0]                   M_RDATA,
    output wire [1:0]                    M_RRESP,
    output wire                          M_RLAST,
    output wire                          M_RVALID,
    input  wire                          M_RREADY,
    // ---- S0: BR-PUF (13 位) ----
    output wire [12:0] S0_AWADDR, output wire S0_AWVALID, input wire S0_AWREADY,
    output wire [31:0] S0_WDATA,  output wire [3:0] S0_WSTRB, output wire S0_WVALID, input wire S0_WREADY,
    input  wire [1:0]  S0_BRESP,  input  wire S0_BVALID, output wire S0_BREADY,
    output wire [12:0] S0_ARADDR, output wire [7:0] S0_ARLEN, output wire S0_ARVALID, input wire S0_ARREADY,
    input  wire [31:0] S0_RDATA,  input wire [1:0] S0_RRESP, input wire S0_RLAST, input wire S0_RVALID, output wire S0_RREADY,
    // ---- S1: AES (7 位) ----
    output wire [6:0]  S1_AWADDR, output wire S1_AWVALID, input wire S1_AWREADY,
    output wire [31:0] S1_WDATA,  output wire [3:0] S1_WSTRB, output wire S1_WVALID, input wire S1_WREADY,
    input  wire [1:0]  S1_BRESP,  input  wire S1_BVALID, output wire S1_BREADY,
    output wire [6:0]  S1_ARADDR, output wire S1_ARVALID, input wire S1_ARREADY,
    input  wire [31:0] S1_RDATA,  input wire [1:0] S1_RRESP, input wire S1_RVALID, output wire S1_RREADY,
    // ---- S2: TRNG (6 位) ----
    output wire [5:0]  S2_AWADDR, output wire S2_AWVALID, input wire S2_AWREADY,
    output wire [31:0] S2_WDATA,  output wire [3:0] S2_WSTRB, output wire S2_WVALID, input wire S2_WREADY,
    input  wire [1:0]  S2_BRESP,  input  wire S2_BVALID, output wire S2_BREADY,
    output wire [5:0]  S2_ARADDR, output wire S2_ARVALID, input wire S2_ARREADY,
    input  wire [31:0] S2_RDATA,  input wire [1:0] S2_RRESP, input wire S2_RVALID, output wire S2_RREADY,
    // ---- S3: MAILBOX (8 位, 64 字窗口) ----
    output wire [7:0]  S3_AWADDR, output wire S3_AWVALID, input wire S3_AWREADY,
    output wire [31:0] S3_WDATA,  output wire [3:0] S3_WSTRB, output wire S3_WVALID, input wire S3_WREADY,
    input  wire [1:0]  S3_BRESP,  input  wire S3_BVALID, output wire S3_BREADY,
    output wire [7:0]  S3_ARADDR, output wire S3_ARVALID, input wire S3_ARREADY,
    input  wire [31:0] S3_RDATA,  input wire [1:0] S3_RRESP, input wire S3_RVALID, output wire S3_RREADY
);

    // ---------------- 写侧: 双 pending + 三态 (v11.2) ----------------
    //   v11.1 教训: AW 与 W 可分拍到达; 只锁 AW 就发起会用上一笔的旧数据
    //   -> 写值整体位移一格 (板上实测 AA000001 出现在 0x200000)。
    //   必须 aw_pend && w_pend 齐备才进入 ISSUE。
    localparam [1:0] WS_IDLE = 2'd0, WS_ISSUE = 2'd1, WS_WAITB = 2'd2;
    reg [1:0]  wstate;
    reg        aw_pend, w_pend;
    reg [31:0] aw_addr_r, w_data_r;
    reg [3:0]  w_strb_r;
    reg [1:0]  w_tgt_r;

    assign M_AWREADY = (wstate == WS_IDLE) && !aw_pend;
    assign M_WREADY  = (wstate == WS_IDLE) && !w_pend;

    wire [1:0] aw_tgt_now = M_AWADDR[17:16];   // 0..3 全部有效 (PUF/AES/TRNG/MAILBOX)

    always @(posedge M_ACLK) begin
        if (!M_ARESETN) begin
            wstate <= WS_IDLE; aw_pend <= 0; w_pend <= 0; w_tgt_r <= 2'd3;
        end else begin
            case (wstate)
                WS_IDLE: begin
                    if (M_AWVALID && M_AWREADY) begin
                        aw_addr_r <= M_AWADDR;
                        w_tgt_r   <= aw_tgt_now;
                        aw_pend   <= 1'b1;
                    end
                    if (M_WVALID && M_WREADY) begin
                        w_data_r <= M_WDATA;
                        w_strb_r <= M_WSTRB;
                        w_pend   <= 1'b1;
                    end
                    // 两笔齐备 (含同拍到达) 才发起
                    if ((aw_pend || (M_AWVALID && M_AWREADY)) &&
                        (w_pend  || (M_WVALID  && M_WREADY)) &&
                        ((aw_pend ? (w_tgt_r <= 2'd2) : (aw_tgt_now <= 2'd2))))
                        wstate <= WS_ISSUE;
                end
                WS_ISSUE: begin
                    if ((S0_AWVALID && S0_AWREADY && S0_WVALID && S0_WREADY && w_tgt_r == 2'd0) ||
                        (S1_AWVALID && S1_AWREADY && S1_WVALID && S1_WREADY && w_tgt_r == 2'd1) ||
                        (S2_AWVALID && S2_AWREADY && S2_WVALID && S2_WREADY && w_tgt_r == 2'd2) ||
                        (S3_AWVALID && S3_AWREADY && S3_WVALID && S3_WREADY && w_tgt_r == 2'd3)) begin
                        aw_pend <= 1'b0;
                        w_pend  <= 1'b0;
                        wstate  <= WS_WAITB;
                    end
                end
                WS_WAITB: begin
                    if (M_BVALID && M_BREADY) wstate <= WS_IDLE;
                end
                default: wstate <= WS_IDLE;
            endcase
        end
    end

    assign S0_AWVALID = (wstate == WS_ISSUE) && (w_tgt_r == 2'd0);
    assign S1_AWVALID = (wstate == WS_ISSUE) && (w_tgt_r == 2'd1);
    assign S2_AWVALID = (wstate == WS_ISSUE) && (w_tgt_r == 2'd2);
    assign S3_AWVALID = (wstate == WS_ISSUE) && (w_tgt_r == 2'd3);
    assign S0_WVALID  = (wstate == WS_ISSUE) && (w_tgt_r == 2'd0);
    assign S1_WVALID  = (wstate == WS_ISSUE) && (w_tgt_r == 2'd1);
    assign S2_WVALID  = (wstate == WS_ISSUE) && (w_tgt_r == 2'd2);
    assign S3_WVALID  = (wstate == WS_ISSUE) && (w_tgt_r == 2'd3);

    assign S0_AWADDR = aw_addr_r[12:0];
    assign S1_AWADDR = aw_addr_r[6:0];
    assign S2_AWADDR = aw_addr_r[5:0];
    assign S3_AWADDR = aw_addr_r[7:0];
    assign S0_WDATA  = w_data_r;
    assign S1_WDATA  = w_data_r;
    assign S2_WDATA  = w_data_r;
    assign S3_WDATA  = w_data_r;
    assign S0_WSTRB  = w_strb_r;
    assign S1_WSTRB  = w_strb_r;
    assign S2_WSTRB  = w_strb_r;

    assign M_BVALID = (w_tgt_r == 2'd0) ? S0_BVALID : (w_tgt_r == 2'd1) ? S1_BVALID : (w_tgt_r == 2'd2) ? S2_BVALID : S3_BVALID;
    assign M_BRESP  = (w_tgt_r == 2'd0) ? S0_BRESP  : (w_tgt_r == 2'd1) ? S1_BRESP  : (w_tgt_r == 2'd2) ? S2_BRESP  : S3_BRESP;
    assign S0_BREADY = M_BREADY && (wstate == WS_WAITB) && (w_tgt_r == 2'd0);
    assign S1_BREADY = M_BREADY && (wstate == WS_WAITB) && (w_tgt_r == 2'd1);
    assign S2_BREADY = M_BREADY && (wstate == WS_WAITB) && (w_tgt_r == 2'd2);
    assign S3_BREADY = M_BREADY && (wstate == WS_WAITB) && (w_tgt_r == 2'd3);

    // ---------------- 读侧: 锁存 AR 后发起 ----------------
    reg        ar_pend, r_go;
    reg [31:0] ar_addr_r;
    reg [7:0]  ar_len_r;
    reg [1:0]  r_tgt_r;

    assign M_ARREADY = !ar_pend && !r_go;

    always @(posedge M_ACLK) begin
        if (!M_ARESETN) begin
            ar_pend <= 0; r_go <= 0; r_tgt_r <= 2'd3;
        end else begin
            if (M_ARVALID && M_ARREADY) begin
                ar_addr_r <= M_ARADDR;
                ar_len_r  <= M_ARLEN;
                r_tgt_r   <= M_ARADDR[17:16];
                ar_pend   <= 1'b1;
            end
            if (ar_pend && !r_go) r_go <= 1'b1;
            if (r_go && M_RVALID && M_RREADY && M_RLAST) begin
                r_go    <= 1'b0;
                ar_pend <= 1'b0;
            end
        end
    end

    assign S0_ARVALID = r_go && (r_tgt_r == 2'd0);
    assign S1_ARVALID = r_go && (r_tgt_r == 2'd1);
    assign S2_ARVALID = r_go && (r_tgt_r == 2'd2);
    assign S3_ARVALID = r_go && (r_tgt_r == 2'd3);
    assign S0_ARADDR  = ar_addr_r[12:0];
    assign S1_ARADDR  = ar_addr_r[6:0];
    assign S2_ARADDR  = ar_addr_r[5:0];
    assign S3_ARADDR  = ar_addr_r[7:0];
    assign S0_ARLEN   = ar_len_r;

    assign M_RVALID = (r_tgt_r == 2'd0) ? S0_RVALID : (r_tgt_r == 2'd1) ? S1_RVALID : (r_tgt_r == 2'd2) ? S2_RVALID : S3_RVALID;
    assign M_RDATA  = (r_tgt_r == 2'd0) ? S0_RDATA  : (r_tgt_r == 2'd1) ? S1_RDATA  : (r_tgt_r == 2'd2) ? S2_RDATA  : S3_RDATA;
    assign M_RRESP  = (r_tgt_r == 2'd0) ? S0_RRESP  : (r_tgt_r == 2'd1) ? S1_RRESP  : (r_tgt_r == 2'd2) ? S2_RRESP  : S3_RRESP;
    assign M_RLAST  = (r_tgt_r == 2'd0) ? S0_RLAST  : 1'b1;
    assign S0_RREADY = M_RREADY && (r_tgt_r == 2'd0);
    assign S1_RREADY = M_RREADY && (r_tgt_r == 2'd1);
    assign S2_RREADY = M_RREADY && (r_tgt_r == 2'd2);
    assign S3_RREADY = M_RREADY && (r_tgt_r == 2'd3);

endmodule
`default_nettype wire
