//=============================================================================
// axi_lite_arb2.v — 双主机 AXI 仲裁器 (PS GP0 优先, JTAG 空闲时可用) v11
//
//   事务粒度仲裁: 从 AW/AR 接受起锁定主机, 直到 B/R(含RLAST) 完成。
//   两主机同抢时 M0 (PS) 优先 —— PS 轮询读极短, JTAG 等一拍无感。
//   传递 ARLEN/RLAST, 支持读突发 (jtag_axi mrd INCR 依赖此)。
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module axi_lite_arb2 (
    input  wire         ACLK,
    input  wire         ARESETN,
    // ---- M0: PS GP0 (优先) ----
    input  wire [31:0]  M0_AWADDR,  input wire M0_AWVALID, output wire M0_AWREADY,
    input  wire [31:0]  M0_WDATA,   input wire [3:0] M0_WSTRB, input wire M0_WVALID, output wire M0_WREADY,
    output wire [1:0]   M0_BRESP,   output wire M0_BVALID, input wire M0_BREADY,
    input  wire [31:0]  M0_ARADDR,  input wire [7:0] M0_ARLEN, input wire M0_ARVALID, output wire M0_ARREADY,
    output wire [31:0]  M0_RDATA,   output wire [1:0] M0_RRESP, output wire M0_RLAST, output wire M0_RVALID, input wire M0_RREADY,
    // ---- M1: JTAG-AXI ----
    input  wire [31:0]  M1_AWADDR,  input wire M1_AWVALID, output wire M1_AWREADY,
    input  wire [31:0]  M1_WDATA,   input wire [3:0] M1_WSTRB, input wire M1_WVALID, output wire M1_WREADY,
    output wire [1:0]   M1_BRESP,   output wire M1_BVALID, input wire M1_BREADY,
    input  wire [31:0]  M1_ARADDR,  input wire [7:0] M1_ARLEN, input wire M1_ARVALID, output wire M1_ARREADY,
    output wire [31:0]  M1_RDATA,   output wire [1:0] M1_RRESP, output wire M1_RLAST, output wire M1_RVALID, input wire M1_RREADY,
    // ---- 输出主机侧 (至 demux) ----
    output reg  [31:0]  O_AWADDR,   output reg  O_AWVALID, input wire O_AWREADY,
    output reg  [31:0]  O_WDATA,    output reg  [3:0] O_WSTRB, output reg  O_WVALID, input wire O_WREADY,
    input  wire [1:0]   O_BRESP,    input wire O_BVALID, output wire O_BREADY,
    output reg  [31:0]  O_ARADDR,   output reg  [7:0] O_ARLEN, output reg  O_ARVALID, input wire O_ARREADY,
    input  wire [31:0]  O_RDATA,    input wire [1:0] O_RRESP, input wire O_RLAST, input wire O_RVALID, output wire O_RREADY
);

    // grant: 0=M0, 1=M1, 2=idle
    reg [1:0] w_grant = 2'd2;
    reg [1:0] r_grant = 2'd2;

    wire w_busy = (w_grant != 2'd2);
    wire r_busy = (r_grant != 2'd2);

    // 写通道仲裁: 无锁时 M0 有请求给 M0, 否则 M1
    wire [1:0] w_pick = (!w_busy && M0_AWVALID) ? 2'd0 : (!w_busy && M1_AWVALID) ? 2'd1 : 2'd2;
    wire [1:0] r_pick = (!r_busy && M0_ARVALID) ? 2'd0 : (!r_busy && M1_ARVALID) ? 2'd1 : 2'd2;

    always @(posedge ACLK) begin
        if (!ARESETN) begin
            w_grant <= 2'd2;
            r_grant <= 2'd2;
        end else begin
            if (!w_busy && w_pick != 2'd2)            w_grant <= w_pick;   // AW 接受 (O_AWREADY 见下)
            else if (w_busy && O_BVALID && O_BREADY)  w_grant <= 2'd2;     // B 完成
            if (!r_busy && r_pick != 2'd2)            r_grant <= r_pick;
            else if (r_busy && O_RVALID && O_RREADY && O_RLAST) r_grant <= 2'd2;
        end
    end

    // AW 有效窗: 未锁且被选中 -> 转发; 已锁且是 grant 主机 -> 转发
    wire m0_aw_active = (!w_busy && w_pick == 2'd0) || (w_grant == 2'd0);
    wire m1_aw_active = (!w_busy && w_pick == 2'd1) || (w_grant == 2'd1);
    assign M0_AWREADY = m0_aw_active && O_AWREADY;
    assign M1_AWREADY = m1_aw_active && O_AWREADY;

    always @(*) begin
        O_AWVALID = 1'b0; O_AWADDR = 32'd0;
        if (m0_aw_active && M0_AWVALID) begin O_AWVALID = 1'b1; O_AWADDR = M0_AWADDR; end
        else if (m1_aw_active && M1_AWVALID) begin O_AWVALID = 1'b1; O_AWADDR = M1_AWADDR; end
    end

    // W: 跟随写 grant (锁存后), 或未锁时跟随被选中主机的 AW (W 可与 AW 同拍)
    wire m0_w_active = (w_grant == 2'd0) || (!w_busy && w_pick == 2'd0 && M0_AWVALID);
    wire m1_w_active = (w_grant == 2'd1) || (!w_busy && w_pick == 2'd1 && M1_AWVALID);
    assign M0_WREADY = m0_w_active && O_WREADY;
    assign M1_WREADY = m1_w_active && O_WREADY;
    always @(*) begin
        O_WVALID = 1'b0; O_WDATA = 32'd0; O_WSTRB = 4'd0;
        if (m0_w_active && M0_WVALID) begin O_WVALID = 1'b1; O_WDATA = M0_WDATA; O_WSTRB = M0_WSTRB; end
        else if (m1_w_active && M1_WVALID) begin O_WVALID = 1'b1; O_WDATA = M1_WDATA; O_WSTRB = M1_WSTRB; end
    end

    // B: 回给锁存的主机
    assign M0_BVALID = O_BVALID && (w_grant == 2'd0);
    assign M1_BVALID = O_BVALID && (w_grant == 2'd1);
    assign M0_BRESP  = O_BRESP;
    assign M1_BRESP  = O_BRESP;
    assign O_BREADY  = (w_grant == 2'd0) ? M0_BREADY : (w_grant == 2'd1) ? M1_BREADY : 1'b0;

    // AR
    wire m0_ar_active = (!r_busy && r_pick == 2'd0) || (r_grant == 2'd0);
    wire m1_ar_active = (!r_busy && r_pick == 2'd1) || (r_grant == 2'd1);
    assign M0_ARREADY = m0_ar_active && O_ARREADY;
    assign M1_ARREADY = m1_ar_active && O_ARREADY;
    always @(*) begin
        O_ARVALID = 1'b0; O_ARADDR = 32'd0; O_ARLEN = 8'd0;
        if (m0_ar_active && M0_ARVALID) begin O_ARVALID = 1'b1; O_ARADDR = M0_ARADDR; O_ARLEN = M0_ARLEN; end
        else if (m1_ar_active && M1_ARVALID) begin O_ARVALID = 1'b1; O_ARADDR = M1_ARADDR; O_ARLEN = M1_ARLEN; end
    end

    // R: 回给锁存的主机
    assign M0_RVALID = O_RVALID && (r_grant == 2'd0);
    assign M1_RVALID = O_RVALID && (r_grant == 2'd1);
    assign M0_RDATA  = O_RDATA;
    assign M1_RDATA  = O_RDATA;
    assign M0_RRESP  = O_RRESP;  assign M1_RRESP = O_RRESP;
    assign M0_RLAST  = O_RLAST;  assign M1_RLAST = O_RLAST;
    assign O_RREADY  = (r_grant == 2'd0) ? M0_RREADY : (r_grant == 2'd1) ? M1_RREADY : 1'b0;

endmodule
`default_nettype wire
