//=============================================================================
// pdlro_eval_top.v — 挑战可编程 RO Strong PUF 评估顶层 (AX7020, xc7z020clg400-1)
//   PS7 (FCLK_CLK0=100MHz) -> pdlro_axi (v6.0) -> jtag_axi (0x4000_0000)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module pdlro_eval_top ();
    wire sys_clk;
    ps7_0 u_ps (
        .FCLK_CLK0(sys_clk)
    );

    reg [15:0] por = 16'd0;
    always @(posedge sys_clk) if (por != 16'hFFFF) por <= por + 1'b1;
    wire rst_sys = ~por[15];

    wire [31:0] awaddr, wdata, araddr, rdata;
    wire        awvalid, awready, wvalid, wready, bvalid;
    wire        bready;
    wire        rready;
    wire [7:0]  arlen;
    wire        rlast;
    wire [1:0]  bresp, rresp;
    wire        arvalid, arready, rvalid;
    wire        spuf_busy, spuf_done;

    pdlro_axi #(
        .C_S_AXI_ADDR_WIDTH (13),
        .NPAIR_MAX          (512)
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
