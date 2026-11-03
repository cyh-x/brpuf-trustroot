// jtag_axi_stub.v — jtag_axi 黑盒声明 (端口表与官方 pr_out/ip_pr.gen/.../jtag_axi_stub.v 完全一致)
// 用途: (1) xvlog 语法检查; (2) Stage B 非项目综合保留空盒,
//       随后 read_checkpoint -cell u_jtag <jtag_axi.dcp> 注入 IP 实现。
// 注意: 端口必须齐备, 缺端口会导致 opt_design 报 Opt 31-67 (IP 内部 LUT 输入被裁剪)。
`timescale 1ns / 1ps
(* black_box *)
module jtag_axi (
    // clock / reset
    input  wire        aclk,
    input  wire        aresetn,
    // write address channel
    output wire [0:0]  m_axi_awid,
    output wire [31:0] m_axi_awaddr,
    output wire [7:0]  m_axi_awlen,
    output wire [2:0]  m_axi_awsize,
    output wire [1:0]  m_axi_awburst,
    output wire        m_axi_awlock,
    output wire [3:0]  m_axi_awcache,
    output wire [2:0]  m_axi_awprot,
    output wire [3:0]  m_axi_awqos,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    // write data channel
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wlast,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    // write response channel
    input  wire [0:0]  m_axi_bid,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,
    // read address channel
    output wire [0:0]  m_axi_arid,
    output wire [31:0] m_axi_araddr,
    output wire [7:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire        m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire [3:0]  m_axi_arqos,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    // read data channel
    input  wire [0:0]  m_axi_rid,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);
    // 黑盒: 内容由 read_checkpoint -cell 注入, 此处留空
endmodule
