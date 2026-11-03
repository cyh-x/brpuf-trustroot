//=============================================================================
// crypto_eval_top.v — 集成信任根顶层: BR-PUF + AES-256 + TRNG (v10.0)
//   PS7 (FCLK 100MHz) -> jtag_axi -> axi_lite_demux -> 三从机
//     0x4000_0000  BR-PUF (brpuf2_axi, 13位)
//     0x4001_0000  AES-256 (aes256_ip, 7位)
//     0x4002_0000  TRNG (trng, 6位)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module crypto_eval_top ();
    wire sys_clk;
    ps7_0 u_ps (
        .FCLK_CLK0(sys_clk)
    );

    reg [15:0] por = 16'd0;
    always @(posedge sys_clk) if (por != 16'hFFFF) por <= por + 1'b1;
    wire rst_sys = ~por[15];

    // ---- 主机: jtag_axi ----
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire        awvalid, awready, wvalid, wready, bvalid, bready, rready;
    wire [7:0]  arlen;
    wire        rlast;
    wire [1:0]  bresp, rresp;
    wire        arvalid, arready, rvalid;

    // ---- 从机通道 ----
    wire [12:0] puf_awaddr, puf_araddr;
    wire        puf_awvalid, puf_awready, puf_wvalid, puf_wready;
    wire        puf_bvalid, puf_bready, puf_arvalid, puf_arready;
    wire        puf_rvalid, puf_rready, puf_rlast;
    wire [31:0] puf_wdata_x, puf_rdata;
    wire [3:0]  puf_wstrb;
    wire [1:0]  puf_bresp, puf_rresp;
    wire [7:0]  puf_arlen;

    wire [6:0]  aes_awaddr, aes_araddr;
    wire        aes_awvalid, aes_awready, aes_wvalid, aes_wready;
    wire        aes_bvalid, aes_bready, aes_arvalid, aes_arready;
    wire        aes_rvalid, aes_rready;
    wire [31:0] aes_wdata, aes_rdata;
    wire [3:0]  aes_wstrb;
    wire [1:0]  aes_bresp, aes_rresp;

    wire [5:0]  trng_awaddr, trng_araddr;
    wire        trng_awvalid, trng_awready, trng_wvalid, trng_wready;
    wire        trng_bvalid, trng_bready, trng_arvalid, trng_arready;
    wire        trng_rvalid, trng_rready;
    wire [31:0] trng_wdata, trng_rdata;
    wire [3:0]  trng_wstrb;
    wire [1:0]  trng_bresp, trng_rresp;

    wire spuf_busy, spuf_done;

    axi_lite_demux #(.C_M_ADDR_WIDTH(32)) u_demux (
        .M_ACLK(sys_clk), .M_ARESETN(~rst_sys),
        .M_AWADDR(awaddr), .M_AWVALID(awvalid), .M_AWREADY(awready),
        .M_WDATA(wdata), .M_WSTRB(4'b1111), .M_WVALID(wvalid), .M_WREADY(wready),
        .M_BRESP(bresp), .M_BVALID(bvalid), .M_BREADY(bready),
        .M_ARADDR(araddr), .M_ARLEN(arlen), .M_ARVALID(arvalid), .M_ARREADY(arready),
        .M_RDATA(rdata), .M_RRESP(rresp), .M_RLAST(rlast), .M_RVALID(rvalid), .M_RREADY(rready),
        .S0_AWADDR(puf_awaddr), .S0_AWVALID(puf_awvalid), .S0_AWREADY(puf_awready),
        .S0_WDATA(puf_wdata_x), .S0_WSTRB(puf_wstrb), .S0_WVALID(puf_wvalid), .S0_WREADY(puf_wready),
        .S0_BRESP(puf_bresp), .S0_BVALID(puf_bvalid), .S0_BREADY(puf_bready),
        .S0_ARADDR(puf_araddr), .S0_ARLEN(puf_arlen), .S0_ARVALID(puf_arvalid), .S0_ARREADY(puf_arready),
        .S0_RDATA(puf_rdata), .S0_RRESP(puf_rresp), .S0_RLAST(puf_rlast), .S0_RVALID(puf_rvalid), .S0_RREADY(puf_rready),
        .S1_AWADDR(aes_awaddr), .S1_AWVALID(aes_awvalid), .S1_AWREADY(aes_awready),
        .S1_WDATA(aes_wdata), .S1_WSTRB(aes_wstrb), .S1_WVALID(aes_wvalid), .S1_WREADY(aes_wready),
        .S1_BRESP(aes_bresp), .S1_BVALID(aes_bvalid), .S1_BREADY(aes_bready),
        .S1_ARADDR(aes_araddr), .S1_ARVALID(aes_arvalid), .S1_ARREADY(aes_arready),
        .S1_RDATA(aes_rdata), .S1_RRESP(aes_rresp), .S1_RVALID(aes_rvalid), .S1_RREADY(aes_rready),
        .S2_AWADDR(trng_awaddr), .S2_AWVALID(trng_awvalid), .S2_AWREADY(trng_awready),
        .S2_WDATA(trng_wdata), .S2_WSTRB(trng_wstrb), .S2_WVALID(trng_wvalid), .S2_WREADY(trng_wready),
        .S2_BRESP(trng_bresp), .S2_BVALID(trng_bvalid), .S2_BREADY(trng_bready),
        .S2_ARADDR(trng_araddr), .S2_ARVALID(trng_arvalid), .S2_ARREADY(trng_arready),
        .S2_RDATA(trng_rdata), .S2_RRESP(trng_rresp), .S2_RVALID(trng_rvalid), .S2_RREADY(trng_rready)
    );

    brpuf2_axi #(
        .C_S_AXI_ADDR_WIDTH (13),
        .NCHAL_MAX          (1024)
    ) u_puf (
        .spuf_busy_o   (spuf_busy),
        .spuf_done_o   (spuf_done),
        .S_AXI_ACLK   (sys_clk),
        .S_AXI_ARESETN(~rst_sys),
        .S_AXI_AWADDR (puf_awaddr),
        .S_AXI_AWPROT (3'b000),
        .S_AXI_AWVALID(puf_awvalid),
        .S_AXI_AWREADY(puf_awready),
        .S_AXI_WDATA  (puf_wdata_x),
        .S_AXI_WSTRB  (puf_wstrb),
        .S_AXI_WVALID (puf_wvalid),
        .S_AXI_WREADY (puf_wready),
        .S_AXI_BRESP  (puf_bresp),
        .S_AXI_BVALID (puf_bvalid),
        .S_AXI_BREADY (puf_bready),
        .S_AXI_ARADDR (puf_araddr),
        .S_AXI_ARLEN  (puf_arlen),
        .S_AXI_ARPROT (3'b000),
        .S_AXI_ARVALID(puf_arvalid),
        .S_AXI_ARREADY(puf_arready),
        .S_AXI_RDATA  (puf_rdata),
        .S_AXI_RRESP  (puf_rresp),
        .S_AXI_RLAST  (puf_rlast),
        .S_AXI_RVALID (puf_rvalid),
        .S_AXI_RREADY (puf_rready)
    );

    aes256_ip_v1_0 #(
        .C_S0_AXI_DATA_WIDTH(32),
        .C_S0_AXI_ADDR_WIDTH(7)
    ) u_aes (
        .s0_axi_aclk   (sys_clk),
        .s0_axi_aresetn(~rst_sys),
        .s0_axi_awaddr (aes_awaddr),
        .s0_axi_awprot (3'b000),
        .s0_axi_awvalid(aes_awvalid),
        .s0_axi_awready(aes_awready),
        .s0_axi_wdata  (aes_wdata),
        .s0_axi_wstrb  (aes_wstrb),
        .s0_axi_wvalid (aes_wvalid),
        .s0_axi_wready (aes_wready),
        .s0_axi_bresp  (aes_bresp),
        .s0_axi_bvalid (aes_bvalid),
        .s0_axi_bready (aes_bready),
        .s0_axi_araddr (aes_araddr),
        .s0_axi_arprot (3'b000),
        .s0_axi_arvalid(aes_arvalid),
        .s0_axi_arready(aes_arready),
        .s0_axi_rdata  (aes_rdata),
        .s0_axi_rresp  (aes_rresp),
        .s0_axi_rvalid (aes_rvalid),
        .s0_axi_rready (aes_rready)
    );

    trng_v1_0 #(
        .C_S0_AXI_DATA_WIDTH(32),
        .C_S0_AXI_ADDR_WIDTH(6)
    ) u_trng (
        .hw_trng_valid_o(),
        .hw_trng_data_o (),
        .hw_key_valid_o (),
        .hw_key_ready_i (1'b0),
        .hw_key_data_o  (),
        .hw_key_index_o (),
        .hw_busy_o      (),
        .s0_axi_aclk   (sys_clk),
        .s0_axi_aresetn(~rst_sys),
        .s0_axi_awaddr (trng_awaddr),
        .s0_axi_awprot (3'b000),
        .s0_axi_awvalid(trng_awvalid),
        .s0_axi_awready(trng_awready),
        .s0_axi_wdata  (trng_wdata),
        .s0_axi_wstrb  (trng_wstrb),
        .s0_axi_wvalid (trng_wvalid),
        .s0_axi_wready (trng_wready),
        .s0_axi_bresp  (trng_bresp),
        .s0_axi_bvalid (trng_bvalid),
        .s0_axi_bready (trng_bready),
        .s0_axi_araddr (trng_araddr),
        .s0_axi_arprot (3'b000),
        .s0_axi_arvalid(trng_arvalid),
        .s0_axi_arready(trng_arready),
        .s0_axi_rdata  (trng_rdata),
        .s0_axi_rresp  (trng_rresp),
        .s0_axi_rvalid (trng_rvalid),
        .s0_axi_rready (trng_rready)
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
