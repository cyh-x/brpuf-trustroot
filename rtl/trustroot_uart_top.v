//=============================================================================
// trustroot_uart_top.v — 完整信任根顶层 v14: PS 唯一主机, UART 通信
//
//   架构 (仿 vitistest 原始设计):
//     PC ←USB-UART→ PS(A9) 协议栈 ←GP0→ demux → BR-PUF / AES-256 / TRNG
//     (JTAG 仅用于烧位流, 不接 PL AXI 总线 — 消除双主机死锁)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module trustroot_uart_top ();

    wire        sys_clk;
    wire        fclk_rstn;

    // PS M_AXI_GP0 (唯一 PL 主机, AXI3) — 全信号引出
    wire [31:0] gp0_awaddr, gp0_araddr;
    wire [2:0]  gp0_awprot, gp0_arprot, gp0_awsize, gp0_arsize;
    wire [3:0]  gp0_awid, gp0_arid, gp0_wid, gp0_bid, gp0_rid;
    wire [3:0]  gp0_awlen, gp0_arlen, gp0_awcache, gp0_arcache, gp0_awqos, gp0_arqos;
    wire [3:0]  gp0_wstrb;
    wire [31:0] gp0_wdata, gp0_rdata;
    wire [1:0]  gp0_awburst, gp0_arburst, gp0_awlock, gp0_arlock;
    wire [1:0]  gp0_bresp, gp0_rresp;
    wire        gp0_awvalid, gp0_awready, gp0_wvalid, gp0_wready, gp0_wlast;
    wire        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
    wire        gp0_rvalid, gp0_rready, gp0_rlast;

    ps7_0 u_ps (
        .FCLK_CLK0(sys_clk),
        .FCLK_RESET0_N(fclk_rstn),
        .M_AXI_GP0_ACLK(sys_clk),   /* GP0 接口时钟 — v13 以来一直漏接! 浮空靠串扰侥幸工作 */
        .M_AXI_GP0_ARVALID(gp0_arvalid), .M_AXI_GP0_ARREADY(gp0_arready),
        .M_AXI_GP0_ARADDR(gp0_araddr),   .M_AXI_GP0_ARPROT(gp0_arprot),
        .M_AXI_GP0_ARLEN(gp0_arlen),     .M_AXI_GP0_ARSIZE(gp0_arsize), .M_AXI_GP0_ARBURST(gp0_arburst),
        .M_AXI_GP0_ARLOCK(gp0_arlock), .M_AXI_GP0_ARCACHE(gp0_arcache), .M_AXI_GP0_ARQOS(gp0_arqos), .M_AXI_GP0_ARID(gp0_arid),
        .M_AXI_GP0_RVALID(gp0_rvalid), .M_AXI_GP0_RREADY(gp0_rready),
        .M_AXI_GP0_RDATA(gp0_rdata), .M_AXI_GP0_RRESP(gp0_rresp), .M_AXI_GP0_RLAST(gp0_rlast), .M_AXI_GP0_RID(gp0_rid),
        .M_AXI_GP0_AWVALID(gp0_awvalid), .M_AXI_GP0_AWREADY(gp0_awready),
        .M_AXI_GP0_AWADDR(gp0_awaddr),   .M_AXI_GP0_AWPROT(gp0_awprot),
        .M_AXI_GP0_AWLEN(gp0_awlen), .M_AXI_GP0_AWSIZE(gp0_awsize), .M_AXI_GP0_AWBURST(gp0_awburst),
        .M_AXI_GP0_AWLOCK(gp0_awlock), .M_AXI_GP0_AWCACHE(gp0_awcache), .M_AXI_GP0_AWQOS(gp0_awqos), .M_AXI_GP0_AWID(gp0_awid),
        .M_AXI_GP0_WVALID(gp0_wvalid), .M_AXI_GP0_WREADY(gp0_wready),
        .M_AXI_GP0_WDATA(gp0_wdata), .M_AXI_GP0_WSTRB(gp0_wstrb), .M_AXI_GP0_WLAST(gp0_wlast), .M_AXI_GP0_WID(gp0_wid),
        .M_AXI_GP0_BVALID(gp0_bvalid), .M_AXI_GP0_BREADY(gp0_bready),
        .M_AXI_GP0_BRESP(gp0_bresp), .M_AXI_GP0_BID(gp0_bid)
    );


    reg [15:0] por = 16'd0;
    always @(posedge sys_clk) if (por != 16'hFFFF) por <= por + 1'b1;
    wire rst_n = fclk_rstn & por[15];

    // ---- AXI3 -> AXI4-Lite 协议转换 (Xilinx axi_protocol_converter, v15) ----
    // 教训: 手写 demux 的 M 口只有 AXI4-Lite 语义, 而 PS GP0 是 AXI3 -> 读挂起;
    //       vitistest 靠官方 interconnect 自动转协议, 这里用单口转换器达到同等效果
    wire [31:0] lite_awaddr, lite_araddr;
    wire [2:0]  lite_awprot, lite_arprot;
    wire        lite_awvalid, lite_awready, lite_wvalid, lite_wready;
    wire        lite_bvalid, lite_bready, lite_arvalid, lite_arready;
    wire        lite_rvalid, lite_rready;
    wire [31:0] lite_wdata, lite_rdata;
    wire [3:0]  lite_wstrb;
    wire [1:0]  lite_bresp, lite_rresp;

    pc_gp0 u_pc (
        .aclk(sys_clk), .aresetn(rst_n),
        .s_axi_awid(gp0_awid), .s_axi_awaddr(gp0_awaddr), .s_axi_awlen(gp0_awlen),
        .s_axi_awsize(gp0_awsize), .s_axi_awburst(gp0_awburst), .s_axi_awlock(gp0_awlock),
        .s_axi_awcache(gp0_awcache), .s_axi_awprot(gp0_awprot), .s_axi_awqos(gp0_awqos),
        .s_axi_awvalid(gp0_awvalid), .s_axi_awready(gp0_awready),
        .s_axi_wid(gp0_wid), .s_axi_wdata(gp0_wdata), .s_axi_wstrb(gp0_wstrb),
        .s_axi_wlast(gp0_wlast), .s_axi_wvalid(gp0_wvalid), .s_axi_wready(gp0_wready),
        .s_axi_bid(gp0_bid), .s_axi_bresp(gp0_bresp), .s_axi_bvalid(gp0_bvalid), .s_axi_bready(gp0_bready),
        .s_axi_arid(gp0_arid), .s_axi_araddr(gp0_araddr), .s_axi_arlen(gp0_arlen),
        .s_axi_arsize(gp0_arsize), .s_axi_arburst(gp0_arburst), .s_axi_arlock(gp0_arlock),
        .s_axi_arcache(gp0_arcache), .s_axi_arprot(gp0_arprot), .s_axi_arqos(gp0_arqos),
        .s_axi_arvalid(gp0_arvalid), .s_axi_arready(gp0_arready),
        .s_axi_rid(gp0_rid), .s_axi_rdata(gp0_rdata), .s_axi_rresp(gp0_rresp),
        .s_axi_rlast(gp0_rlast), .s_axi_rvalid(gp0_rvalid), .s_axi_rready(gp0_rready),
        .m_axi_awaddr(lite_awaddr), .m_axi_awprot(lite_awprot), .m_axi_awvalid(lite_awvalid), .m_axi_awready(lite_awready),
        .m_axi_wdata(lite_wdata), .m_axi_wstrb(lite_wstrb), .m_axi_wvalid(lite_wvalid), .m_axi_wready(lite_wready),
        .m_axi_bresp(lite_bresp), .m_axi_bvalid(lite_bvalid), .m_axi_bready(lite_bready),
        .m_axi_araddr(lite_araddr), .m_axi_arprot(lite_arprot), .m_axi_arvalid(lite_arvalid), .m_axi_arready(lite_arready),
        .m_axi_rdata(lite_rdata), .m_axi_rresp(lite_rresp), .m_axi_rvalid(lite_rvalid), .m_axi_rready(lite_rready)
    );

    // ---- demux → 三引擎 ----
    wire [12:0] puf_awaddr, puf_araddr;
    wire        puf_awvalid, puf_awready, puf_wvalid, puf_wready;
    wire        puf_bvalid, puf_bready, puf_arvalid, puf_arready;
    wire        puf_rvalid, puf_rready, puf_rlast;
    wire [31:0] puf_wdata, puf_rdata;
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

    wire [7:0]  mb_awaddr, mb_araddr;
    wire        mb_awvalid, mb_awready, mb_wvalid, mb_wready;
    wire        mb_bvalid, mb_bready, mb_arvalid, mb_arready;
    wire        mb_rvalid, mb_rready;
    wire [31:0] mb_wdata, mb_rdata;
    wire [3:0]  mb_wstrb;
    wire [1:0]  mb_bresp, mb_rresp;

    wire spuf_busy, spuf_done;

    axi_lite_demux #(.C_M_ADDR_WIDTH(32)) u_demux (
        .M_ACLK(sys_clk), .M_ARESETN(rst_n),
        .M_AWADDR(lite_awaddr), .M_AWVALID(lite_awvalid), .M_AWREADY(lite_awready),
        .M_WDATA(lite_wdata), .M_WSTRB(lite_wstrb), .M_WVALID(lite_wvalid), .M_WREADY(lite_wready),
        .M_BRESP(lite_bresp), .M_BVALID(lite_bvalid), .M_BREADY(lite_bready),
        .M_ARADDR(lite_araddr), .M_ARLEN(8'd0), .M_ARVALID(lite_arvalid), .M_ARREADY(lite_arready),
        .M_RDATA(lite_rdata), .M_RRESP(lite_rresp), .M_RLAST(), .M_RVALID(lite_rvalid), .M_RREADY(lite_rready),
        .S0_AWADDR(puf_awaddr), .S0_AWVALID(puf_awvalid), .S0_AWREADY(puf_awready),
        .S0_WDATA(puf_wdata), .S0_WSTRB(puf_wstrb), .S0_WVALID(puf_wvalid), .S0_WREADY(puf_wready),
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
        .S2_RDATA(trng_rdata), .S2_RRESP(trng_rresp), .S2_RVALID(trng_rvalid), .S2_RREADY(trng_rready),
        .S3_AWADDR(mb_awaddr), .S3_AWVALID(mb_awvalid), .S3_AWREADY(mb_awready),
        .S3_WDATA(mb_wdata), .S3_WSTRB(mb_wstrb), .S3_WVALID(mb_wvalid), .S3_WREADY(mb_wready),
        .S3_BRESP(mb_bresp), .S3_BVALID(mb_bvalid), .S3_BREADY(mb_bready),
        .S3_ARADDR(mb_araddr), .S3_ARVALID(mb_arvalid), .S3_ARREADY(mb_arready),
        .S3_RDATA(mb_rdata), .S3_RRESP(mb_rresp), .S3_RVALID(mb_rvalid), .S3_RREADY(mb_rready)
    );

    brpuf2_axi #(
        .C_S_AXI_ADDR_WIDTH (13),
        .NCHAL_MAX          (1024)
    ) u_puf (
        .spuf_busy_o(spuf_busy), .spuf_done_o(spuf_done),
        .S_AXI_ACLK(sys_clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(puf_awaddr), .S_AXI_AWPROT(3'b000), .S_AXI_AWVALID(puf_awvalid), .S_AXI_AWREADY(puf_awready),
        .S_AXI_WDATA(puf_wdata), .S_AXI_WSTRB(puf_wstrb), .S_AXI_WVALID(puf_wvalid), .S_AXI_WREADY(puf_wready),
        .S_AXI_BRESP(puf_bresp), .S_AXI_BVALID(puf_bvalid), .S_AXI_BREADY(puf_bready),
        .S_AXI_ARADDR(puf_araddr), .S_AXI_ARLEN(puf_arlen), .S_AXI_ARPROT(3'b000),
        .S_AXI_ARVALID(puf_arvalid), .S_AXI_ARREADY(puf_arready),
        .S_AXI_RDATA(puf_rdata), .S_AXI_RRESP(puf_rresp), .S_AXI_RLAST(puf_rlast),
        .S_AXI_RVALID(puf_rvalid), .S_AXI_RREADY(puf_rready)
    );

    aes256_ip_v1_0 #(.C_S0_AXI_DATA_WIDTH(32), .C_S0_AXI_ADDR_WIDTH(7)) u_aes (
        .s0_axi_aclk(sys_clk), .s0_axi_aresetn(rst_n),
        .s0_axi_awaddr(aes_awaddr), .s0_axi_awprot(3'b000), .s0_axi_awvalid(aes_awvalid), .s0_axi_awready(aes_awready),
        .s0_axi_wdata(aes_wdata), .s0_axi_wstrb(aes_wstrb), .s0_axi_wvalid(aes_wvalid), .s0_axi_wready(aes_wready),
        .s0_axi_bresp(aes_bresp), .s0_axi_bvalid(aes_bvalid), .s0_axi_bready(aes_bready),
        .s0_axi_araddr(aes_araddr), .s0_axi_arprot(3'b000), .s0_axi_arvalid(aes_arvalid), .s0_axi_arready(aes_arready),
        .s0_axi_rdata(aes_rdata), .s0_axi_rresp(aes_rresp), .s0_axi_rvalid(aes_rvalid), .s0_axi_rready(aes_rready)
    );

    trng_v1_0 #(.C_S0_AXI_DATA_WIDTH(32), .C_S0_AXI_ADDR_WIDTH(6)) u_trng (
        .hw_trng_valid_o(), .hw_trng_data_o(), .hw_key_valid_o(), .hw_key_ready_i(1'b0),
        .hw_key_data_o(), .hw_key_index_o(), .hw_busy_o(),
        .s0_axi_aclk(sys_clk), .s0_axi_aresetn(rst_n),
        .s0_axi_awaddr(trng_awaddr), .s0_axi_awprot(3'b000), .s0_axi_awvalid(trng_awvalid), .s0_axi_awready(trng_awready),
        .s0_axi_wdata(trng_wdata), .s0_axi_wstrb(trng_wstrb), .s0_axi_wvalid(trng_wvalid), .s0_axi_wready(trng_wready),
        .s0_axi_bresp(trng_bresp), .s0_axi_bvalid(trng_bvalid), .s0_axi_bready(trng_bready),
        .s0_axi_araddr(trng_araddr), .s0_axi_arprot(3'b000), .s0_axi_arvalid(trng_arvalid), .s0_axi_arready(trng_arready),
        .s0_axi_rdata(trng_rdata), .s0_axi_rresp(trng_rresp), .s0_axi_rvalid(trng_rvalid), .s0_axi_rready(trng_rready)
    );

    mailbox_axi #(.C_S_AXI_ADDR_WIDTH(8)) u_mb (
        .S_AXI_ACLK(sys_clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(mb_awaddr), .S_AXI_AWPROT(3'b000), .S_AXI_AWVALID(mb_awvalid), .S_AXI_AWREADY(mb_awready),
        .S_AXI_WDATA(mb_wdata), .S_AXI_WSTRB(mb_wstrb), .S_AXI_WVALID(mb_wvalid), .S_AXI_WREADY(mb_wready),
        .S_AXI_BRESP(mb_bresp), .S_AXI_BVALID(mb_bvalid), .S_AXI_BREADY(mb_bready),
        .S_AXI_ARADDR(mb_araddr), .S_AXI_ARPROT(3'b000), .S_AXI_ARVALID(mb_arvalid), .S_AXI_ARREADY(mb_arready),
        .S_AXI_RDATA(mb_rdata), .S_AXI_RRESP(mb_rresp), .S_AXI_RLAST(1'b1), .S_AXI_RVALID(mb_rvalid), .S_AXI_RREADY(mb_rready)
    );

endmodule
`default_nettype wire
