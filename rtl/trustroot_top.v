//=============================================================================
// trustroot_top.v — 完整信任根顶层 (v12.0, 2026-10-31)
//
// 架构: 无仲裁器双通路
//   (A) PS M_AXI_GP0 (唯一 PL 主机) -> axi_lite_demux -> BR-PUF / AES-256 / TRNG
//   (B) JTAG-AXI -> PS S_AXI_GP0 -> DDR   (PC 与 PS 通过 DDR 邮箱通信, 不占 PL 逻辑)
//
//   PC 侧: mwr 0x0010_0000 <cmd> 写 DDR 命令块; mrd 轮询结果块
//   PS 侧: 裸机应用轮询 DDR 命令块, 调 PL 三引擎, 写回结果块
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module trustroot_top ();

    // ---- PS7 ----
    wire        sys_clk;          // FCLK_CLK0 (66.67MHz)
    wire        fclk_rstn;
    // M_AXI_GP0 (PS 作为主机, 访问 PL)
    wire [31:0] gp0_awaddr;  wire [2:0] gp0_awprot;
    wire        gp0_awvalid, gp0_awready;
    wire [31:0] gp0_wdata;   wire [3:0] gp0_wstrb;
    wire        gp0_wvalid, gp0_wready;
    wire [1:0]  gp0_bresp;   wire gp0_bvalid, gp0_bready;
    wire [31:0] gp0_araddr;  wire [2:0] gp0_arprot;
    wire        gp0_arvalid, gp0_arready;
    wire [31:0] gp0_rdata;   wire [1:0] gp0_rresp;
    wire        gp0_rvalid, gp0_rready;
    wire [3:0]  gp0_awlen_dummy;  // AXI3 额外信号 (未用)

    // S_AXI_GP0 (JTAG 作为主机, 访问 PS/DDR)
    wire [31:0] s0_awaddr;  wire [2:0] s0_awprot;
    wire        s0_awvalid, s0_awready;
    wire [31:0] s0_wdata;   wire [3:0] s0_wstrb;
    wire        s0_wvalid, s0_wready;
    wire [1:0]  s0_bresp;   wire s0_bvalid, s0_bready;
    wire [31:0] s0_araddr;  wire [2:0] s0_arprot;
    wire        s0_arvalid, s0_arready;
    wire [31:0] s0_rdata;   wire [1:0] s0_rresp;
    wire        s0_rvalid, s0_rready;

    ps7_0 u_ps (
        .FCLK_CLK0(sys_clk),
        .FCLK_RESET0_N(fclk_rstn),
        // --- M_AXI_GP0 ---
        .M_AXI_GP0_ARVALID(gp0_arvalid), .M_AXI_GP0_ARREADY(gp0_arready),
        .M_AXI_GP0_ARADDR(gp0_araddr),   .M_AXI_GP0_ARPROT(gp0_arprot),
        .M_AXI_GP0_ARLEN(),              .M_AXI_GP0_ARSIZE(), .M_AXI_GP0_ARBURST(),
        .M_AXI_GP0_ARLOCK(), .M_AXI_GP0_ARCACHE(), .M_AXI_GP0_ARQOS(), .M_AXI_GP0_ARID(),
        .M_AXI_GP0_RVALID(gp0_rvalid), .M_AXI_GP0_RREADY(gp0_rready),
        .M_AXI_GP0_RDATA(gp0_rdata), .M_AXI_GP0_RRESP(gp0_rresp), .M_AXI_GP0_RLAST(), .M_AXI_GP0_RID(),
        .M_AXI_GP0_AWVALID(gp0_awvalid), .M_AXI_GP0_AWREADY(gp0_awready),
        .M_AXI_GP0_AWADDR(gp0_awaddr), .M_AXI_GP0_AWPROT(gp0_awprot),
        .M_AXI_GP0_AWLEN(), .M_AXI_GP0_AWSIZE(), .M_AXI_GP0_AWBURST(),
        .M_AXI_GP0_AWLOCK(), .M_AXI_GP0_AWCACHE(), .M_AXI_GP0_AWQOS(), .M_AXI_GP0_AWID(),
        .M_AXI_GP0_WVALID(gp0_wvalid), .M_AXI_GP0_WREADY(gp0_wready),
        .M_AXI_GP0_WDATA(gp0_wdata), .M_AXI_GP0_WSTRB(gp0_wstrb), .M_AXI_GP0_WLAST(), .M_AXI_GP0_WID(),
        .M_AXI_GP0_BVALID(gp0_bvalid), .M_AXI_GP0_BREADY(gp0_bready),
        .M_AXI_GP0_BRESP(gp0_bresp), .M_AXI_GP0_BID(),
        // --- S_AXI_GP0 (JTAG 主机 -> DDR) ---
        .S_AXI_GP0_ACLK(sys_clk),
        .S_AXI_GP0_ARVALID(s0_arvalid), .S_AXI_GP0_ARREADY(s0_arready),
        .S_AXI_GP0_ARADDR(s0_araddr), .S_AXI_GP0_ARPROT(s0_arprot),
        .S_AXI_GP0_ARLEN(j_arlen[3:0]), .S_AXI_GP0_ARSIZE(3'b010), .S_AXI_GP0_ARBURST(2'b01),
        .S_AXI_GP0_ARLOCK(2'b00), .S_AXI_GP0_ARCACHE(4'b0000), .S_AXI_GP0_ARQOS(4'b0000), .S_AXI_GP0_ARID(6'd0),
        .S_AXI_GP0_RVALID(s0_rvalid), .S_AXI_GP0_RREADY(s0_rready),
        .S_AXI_GP0_RDATA(s0_rdata), .S_AXI_GP0_RRESP(s0_rresp), .S_AXI_GP0_RLAST(s0_rlast), .S_AXI_GP0_RID(),
        .S_AXI_GP0_AWVALID(s0_awvalid), .S_AXI_GP0_AWREADY(s0_awready),
        .S_AXI_GP0_AWADDR(s0_awaddr), .S_AXI_GP0_AWPROT(s0_awprot),
        .S_AXI_GP0_AWLEN(j_awlen[3:0]), .S_AXI_GP0_AWSIZE(3'b010), .S_AXI_GP0_AWBURST(2'b01),
        .S_AXI_GP0_AWLOCK(2'b00), .S_AXI_GP0_AWCACHE(4'b0000), .S_AXI_GP0_AWQOS(4'b0000), .S_AXI_GP0_AWID(6'd0),
        .S_AXI_GP0_WVALID(s0_wvalid), .S_AXI_GP0_WREADY(s0_wready),
        .S_AXI_GP0_WDATA(s0_wdata), .S_AXI_GP0_WSTRB(s0_wstrb), .S_AXI_GP0_WLAST(j_wlast), .S_AXI_GP0_WID(6'd0),
        .S_AXI_GP0_BVALID(s0_bvalid), .S_AXI_GP0_BREADY(s0_bready),
        .S_AXI_GP0_BRESP(s0_bresp), .S_AXI_GP0_BID()
    );

    // ---- 复位: PS 侧 FCLK_RESET0_N + POR ----
    reg [15:0] por = 16'd0;
    always @(posedge sys_clk) if (por != 16'hFFFF) por <= por + 1'b1;
    wire rst_n = fclk_rstn & por[15];

    // ---- JTAG-AXI -> S_AXI_GP0 (PC 访问 DDR) ----
    wire [31:0] j_awaddr, j_wdata, j_araddr, j_rdata;
    wire [3:0]  j_wstrb;
    wire [7:0]  j_arlen;
    wire [7:0]  j_awlen;
    wire        j_wlast;
    wire        s0_rlast;
    wire        j_awvalid, j_awready, j_wvalid, j_wready;
    wire [1:0]  j_bresp, j_rresp;
    wire        j_bvalid, j_bready, j_arvalid, j_arready;
    wire        j_rvalid, j_rready, j_rlast;

    jtag_axi u_jtag (
        .aclk(sys_clk), .aresetn(rst_n),
        .m_axi_awid(), .m_axi_awaddr(j_awaddr), .m_axi_awlen(j_awlen), .m_axi_awsize(), .m_axi_awburst(),
        .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(), .m_axi_awqos(),
        .m_axi_awvalid(j_awvalid), .m_axi_awready(j_awready),
        .m_axi_wdata(j_wdata), .m_axi_wstrb(j_wstrb), .m_axi_wlast(j_wlast), .m_axi_wvalid(j_wvalid), .m_axi_wready(j_wready),
        .m_axi_bid(1'b0), .m_axi_bresp(j_bresp), .m_axi_bvalid(j_bvalid), .m_axi_bready(j_bready),
        .m_axi_arid(), .m_axi_araddr(j_araddr), .m_axi_arlen(j_arlen), .m_axi_arsize(), .m_axi_arburst(),
        .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(), .m_axi_arqos(),
        .m_axi_arvalid(j_arvalid), .m_axi_arready(j_arready),
        .m_axi_rid(1'b0), .m_axi_rdata(j_rdata), .m_axi_rresp(j_rresp), .m_axi_rlast(s0_rlast),
        .m_axi_rvalid(j_rvalid), .m_axi_rready(j_rready)
    );

    // AXI4 (JTAG) -> AXI3 (S_AXI_GP0): 直连, 仅丢弃 AXI4 独有信号
    assign j_awready = s0_awready;
    assign s0_awvalid = j_awvalid;
    // 写地址补偿: PS S_AXI_GP0 写通道实测落在 +4 处 (写 B 读 B+4 得值),
    // 读通道已正确。DDR 区间 (<0x4000_0000) 写地址前移 4 字节 (2026-10-31)
    assign s0_awaddr  = (j_awaddr < 32'h4000_0000) ? (j_awaddr - 32'd4) : j_awaddr;
    assign s0_awprot  = 3'b000;
    assign j_wready   = s0_wready;
    assign s0_wvalid  = j_wvalid;
    assign s0_wdata   = j_wdata;
    assign s0_wstrb   = j_wstrb;
    assign s0_bready  = j_bready;
    assign j_bvalid   = s0_bvalid;
    assign j_bresp    = s0_bresp;
    assign j_arready  = s0_arready;
    assign s0_arvalid = j_arvalid;
    // DDR 读补偿: PS S_AXI_GP0 读通道实测存在 +4 偏移 (读 A 返回到 A+4 的数据),
    // 写通道正常。在 DDR 区间 (<0x4000_0000) 读地址前移 4 字节补偿 (2026-10-31)
    assign s0_araddr  = (j_araddr < 32'h4000_0000) ? (j_araddr - 32'd4) : j_araddr;
    assign s0_arprot  = 3'b000;
    assign s0_rready  = j_rready;
    assign j_rvalid   = s0_rvalid;
    assign j_rdata    = s0_rdata;
    assign j_rresp    = s0_rresp;
    assign j_rlast    = s0_rlast;

    // ---- PS GP0 -> demux -> 三引擎 ----
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
        .M_AWADDR(gp0_awaddr), .M_AWVALID(gp0_awvalid), .M_AWREADY(gp0_awready),
        .M_WDATA(gp0_wdata), .M_WSTRB(gp0_wstrb), .M_WVALID(gp0_wvalid), .M_WREADY(gp0_wready),
        .M_BRESP(gp0_bresp), .M_BVALID(gp0_bvalid), .M_BREADY(gp0_bready),
        .M_ARADDR(gp0_araddr), .M_ARLEN(8'd0), .M_ARVALID(gp0_arvalid), .M_ARREADY(gp0_arready),
        .M_RDATA(gp0_rdata), .M_RRESP(gp0_rresp), .M_RLAST(), .M_RVALID(gp0_rvalid), .M_RREADY(gp0_rready),
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

    // ---- 邮箱 (PC 经 GP0 或 PS 都可访问; PS 应用轮询执行) ----
    mailbox_axi #(.C_S_AXI_ADDR_WIDTH(8)) u_mb (
        .S_AXI_ACLK(sys_clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(mb_awaddr), .S_AXI_AWPROT(3'b000), .S_AXI_AWVALID(mb_awvalid), .S_AXI_AWREADY(mb_awready),
        .S_AXI_WDATA(mb_wdata), .S_AXI_WSTRB(mb_wstrb), .S_AXI_WVALID(mb_wvalid), .S_AXI_WREADY(mb_wready),
        .S_AXI_BRESP(mb_bresp), .S_AXI_BVALID(mb_bvalid), .S_AXI_BREADY(mb_bready),
        .S_AXI_ARADDR(mb_araddr), .S_AXI_ARPROT(3'b000), .S_AXI_ARVALID(mb_arvalid), .S_AXI_ARREADY(mb_arready),
        .S_AXI_RDATA(mb_rdata), .S_AXI_RRESP(mb_rresp), .S_AXI_RLAST(1'b1), .S_AXI_RVALID(mb_rvalid), .S_AXI_RREADY(mb_rready)
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

endmodule
`default_nettype wire
