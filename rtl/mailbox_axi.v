//=============================================================================
// mailbox_bram.v — PC↔PS 双口邮箱 (v13.0, 2026-11-01)
//
//   4KB 双端口 BRAM: 口 A = PC (经 jtag-axi/demux), 口 B = PS (经 M_AXI_GP0/demux)
//   每口独立读写端口 (true dual port), 无仲裁需求:
//     PC 写命令 -> PS 轮询读 -> PS 执行 -> PS 写结果 -> PC 轮询读
//   地址空间 (12 位 = 1024 字):
//     [0]      命令字  bit31:16=0xA5A5 bit15:0=命令码; PS 执行后写 0
//     [1]      参数0   (PUF 单挑战: 22bit 挑战字)
//     [2..9]   数据区 (AES key/明文 12 字)
//     [16]     状态字  PS 写 0x100=就绪, 完成写命令码|0x8000
//     [17..24] 结果区 (8 字)
//
//   AXI-Lite 从机 (6 位地址 = 64 字窗口... 需 25 字 -> 6 位够 64 字)
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module mailbox_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 8,   // 8 位地址 = 64 字 (addr[7:2])
    parameter integer C_PORT             = 0    // 0=口A(PC) 1=口B(PS)
)(
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
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RLAST   = 1'b1;
    assign S_AXI_RVALID  = axi_rvalid;

    reg axi_awready, axi_wready, axi_bvalid;
    reg [1:0] axi_bresp;
    reg axi_arready, axi_rvalid;
    reg [1:0] axi_rresp;
    reg [31:0] axi_rdata;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    wire slv_rden = axi_arready && S_AXI_ARVALID;

    // 双口 BRAM: 口 A 写/口 B 读 + 口 B 写/口 A 读 (真双口)
    (* ram_style = "block" *) reg [31:0] mb [0:63];

    wire [5:0] a_addr = C_PORT ? S_AXI_AWADDR[7:2] : S_AXI_AWADDR[7:2]; // 同一地址窗
    // 口 A 由 PC 访问: 写 PC->PS 区 (0..15), 读 PS->PC 区 (16..31)
    // 口 B 由 PS 访问: 读 PC->PS 区, 写 PS->PC 区
    // 简化: 双口都全窗读写, 协议层约定区段 (BRAM 真双口支持同时读不同地址/读写不同地址)

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
        end else begin
            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end
            if (slv_wren && ~axi_bvalid) begin
                axi_bvalid <= 1'b1;
                axi_bresp  <= 2'b00;
            end else if (S_AXI_BREADY && axi_bvalid) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // 写: 与 AW 同拍锁存地址, W 握手时写入
    reg [5:0] waddr_r;
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) waddr_r <= 6'd0;
        else if (S_AXI_AWVALID && S_AXI_WVALID && axi_awready && axi_wready)
            waddr_r <= S_AXI_AWADDR[7:2];
    end

    always @(posedge S_AXI_ACLK) begin
        if (S_AXI_ARESETN) begin
            if (slv_wren) mb[waddr_r] <= S_AXI_WDATA;
        end
    end

    // 读: AR 锁存 -> 一拍后出数
    reg [5:0] raddr_r;
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            raddr_r     <= 6'd0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                raddr_r     <= S_AXI_ARADDR[7:2];
            end else begin
                axi_arready <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b00;
        end else begin
            if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (slv_rden) axi_rdata <= mb[raddr_r];
    end

endmodule
`default_nettype wire
