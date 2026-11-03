//=============================================================================
// spuf_eval_top.v — Strong PUF (4x4 APUF) 评估顶层 (ALINX AX7020, xc7z020clg400-1)
//
// 结构 (复用 ax7020_port 已验证骨架):
//   PS7 (FCLK_CLK0=100MHz 内部走线) -> spuf_axi (strong PUF + AXI4-Lite 12bit)
//   -> jtag_axi (xsdb JTAG2AXI, 基址 0x4000_0000, 免 Vitis)
//
// xsdb 用法:
//   mrd 0x40000000 -> VERSION 0x0003_0000
//   写挑战: mwr 0x40000020..0x4000002C (CH0-3), mwr 0x40000030 (addr<<2|1) 入队
//   mwr 0x40000010 R ; mwr 0x40000014 N ; mwr 0x40000008 1 -> 批采集
//   轮询 mrd 0x4000000C -> bit1 done ; mrd 0x40000100+4i -> 表决响应
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module spuf_eval_top ();
    // ---- PS7: 唯一时钟来源 (ps7_init 配好后 FCLK_CLK0=100MHz) ----
    wire sys_clk;
    ps7_0 u_ps (
        .FCLK_CLK0(sys_clk)
    );

    // ---- POR ----
    reg [15:0] por = 16'd0;
    always @(posedge sys_clk) if (por != 16'hFFFF) por <= por + 1'b1;
    wire rst_sys = ~por[15];

    // ---- AXI 互连 ----
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire        awvalid, awready, wvalid, wready, bvalid;
    wire        bready;   // jtag_axi 内部自驱动输出, 接从机握手 (悬空=读全0事故)
    wire        rready;
    wire [7:0]  arlen;
    wire        rlast;
    wire [1:0]  bresp, rresp;
    wire        arvalid, arready, rvalid;
    wire        spuf_busy, spuf_done;

    spuf_axi #(
        .C_S_AXI_ADDR_WIDTH (13),
        .STAGE_N            (24),
        .NCHAL_MAX          (1024),
        .SETTLE_CYCLES(8)
    ) u_spuf (
        .spuf_busy_o   (spuf_busy),
        .spuf_done_o   (spuf_done),
        .S_AXI_ACLK   (sys_clk),
        .S_AXI_ARESETN(~rst_sys),
        .S_AXI_AWADDR (awaddr[12:0]),
        .S_AXI_AWPROT (3'b000),
        .S_AXI_AWVALID(awvalid),
        .S_AXI_AWREADY(awready),
        .S_AXI_WDATA  (wdata),
        .S_AXI_WSTRB  (4'b1111),
        .S_AXI_WVALID (wvalid),
        .S_AXI_WREADY (wready),
        .S_AXI_BRESP  (bresp),
        .S_AXI_BVALID (bvalid),
        .S_AXI_BREADY (bready),
        .S_AXI_ARADDR (araddr[12:0]),
        .S_AXI_ARLEN  (arlen),
        .S_AXI_ARPROT (3'b000),
        .S_AXI_ARVALID(arvalid),
        .S_AXI_ARREADY(arready),
        .S_AXI_RDATA  (rdata),
        .S_AXI_RRESP  (rresp),
        .S_AXI_RLAST  (rlast),
        .S_AXI_RVALID (rvalid),
        .S_AXI_RREADY (rready)
    );

    // ---- jtag_axi (端口表与官方 stub 一致; 未用输入接常量防裁剪) ----
    jtag_axi u_jtag (
        .aclk(sys_clk), .aresetn(~rst_sys),
        .m_axi_awid(), .m_axi_awaddr(awaddr), .m_axi_awlen(), .m_axi_awsize(), .m_axi_awburst(),
        .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(), .m_axi_wlast(), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(1'b0), .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(), .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(), .m_axi_arburst(),
        .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(1'b0), .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

endmodule
`default_nettype wire
