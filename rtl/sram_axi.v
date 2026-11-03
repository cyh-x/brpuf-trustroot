//=============================================================================
// sram_axi.v — 锁存型 SRAM-类 PUF (v7.0, 2026-10-29)
//
//   FPGA 的 BRAM/LUTRAM 上电值由位流决定 (不可用作 SRAM PUF 熵源), 本设计用
//   交叉耦合 NAND 锁存模拟 SRAM 单元的上电竞争 (latch PUF, 文献标准结构):
//     n_a = ~(n_b & en),  n_b = ~(n_a & en)   (各一个 LUT2, INIT 4'h7)
//     en=0 -> 双 1 (强制); en 0->1 释放 -> 两路竞速, 由工艺失配决定收敛到 (1,0)/(0,1)
//   256 个单元硬宏为每单元一个 slice (A6/B6 两个 LUT2)。
//   一次测量 = 强制 -> 释放 -> 稳定 -> 扫描采样 256 位 -> RAM。
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION = 0x0007_0000
//   0x004 RO  CAP     = {8'd0, 8'd1, 8'd0, 16'd256}
//   0x008 RW  CTRL    b0=start b1=soft_rst
//   0x00C RO  STATUS  b0=busy b1=done
//   0x018 RO  MAGIC   {16'h5A5A, run_cnt}
//   0x100+4i RO CELL[i]  bit0 = 单元 i 的收敛值
//=============================================================================
`timescale 1ns / 1ps
`default_nettype none

module sram_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,
    parameter integer NCELL              = 256
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
    assign S_AXI_RLAST   = rlast;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    reg        axi_awready, axi_wready, axi_bvalid;
    reg [1:0]  axi_bresp, axi_rresp;
    reg        axi_arready, axi_rvalid, rlast;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    reg        soft_rst;
    reg        start_pend, start_take;
    reg [15:0] run_cnt;
    wire       core_rst_n = S_AXI_ARESETN & (~soft_rst);

    localparam ST_IDLE  = 3'd0;
    localparam ST_FORCE = 3'd1;
    localparam ST_REL   = 3'd2;
    localparam ST_SETL  = 3'd3;
    localparam ST_SCAN  = 3'd4;
    localparam ST_DONE  = 3'd5;

    reg [2:0]  state;
    reg        running, done_flag;
    reg        cell_en;          // 全局使能 (0=强制双1)
    reg [7:0]  cell_sel;
    reg [15:0] wait_cnt;
    reg        bit_s1, bit_s2;

    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;

    //-------------------------------------------------------------------------
    // 256 x 锁存单元 (显式 LUT2 原语 + DONT_TOUCH)
    //-------------------------------------------------------------------------
    (* dont_touch = "true", keep = "true" *) wire [NCELL-1:0] na, nb;

    genvar g;
    generate
        for (g = 0; g < NCELL; g = g + 1) begin : g_cell
            LUT2 #(.INIT(4'h7)) u_la (.O(na[g]), .I0(nb[g]), .I1(cell_en));
            LUT2 #(.INIT(4'h7)) u_lb (.O(nb[g]), .I0(na[g]), .I1(cell_en));
        end
    endgenerate

    // 扫描读出: 选择单元 -> 2FF 同步
    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin bit_s1 <= 1'b0; bit_s2 <= 1'b0; end
        else             begin bit_s1 <= na[cell_sel]; bit_s2 <= bit_s1; end
    end

    // 单元值 RAM (256 x 32b)
    (* ram_style = "block" *) reg [31:0] cellmem [0:NCELL-1];
    reg [7:0]  cm_waddr;
    reg [31:0] cm_wdata;
    reg        cm_we;
    reg [7:0]  cm_raddr;
    reg [31:0] cm_rdata_r;
    always @(posedge S_AXI_ACLK) begin
        if (cm_we) cellmem[cm_waddr] <= cm_wdata;
        cm_rdata_r <= cellmem[cm_raddr];
    end

    //-------------------------------------------------------------------------
    // FSM: 强制(1us) -> 释放+稳定(20us) -> 扫描 256 单元入 RAM
    //-------------------------------------------------------------------------
    localparam FORCE_CYC = 16'd100;
    localparam SETL_CYC  = 16'd2000;

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state <= ST_IDLE; running <= 1'b0; done_flag <= 1'b0;
            cell_en <= 1'b0; cell_sel <= 8'd0; wait_cnt <= 16'd0;
            cm_we <= 1'b0; cm_waddr <= 8'd0; cm_wdata <= 32'd0;
            run_cnt <= 16'd0; start_take <= 1'b0; cm_raddr <= 8'd0;
        end else begin
            start_take <= 1'b0;
            cm_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    cell_en <= 1'b0;
                    if (start_pend) begin
                        start_take <= 1'b1;
                        running    <= 1'b1;
                        done_flag  <= 1'b0;
                        run_cnt    <= run_cnt + 16'd1;
                        wait_cnt   <= 16'd0;
                        state      <= ST_FORCE;
                    end
                end

                ST_FORCE: begin
                    cell_en <= 1'b0;
                    if (wait_cnt + 16'd1 >= FORCE_CYC) begin
                        wait_cnt <= 16'd0;
                        cell_en  <= 1'b1;
                        state    <= ST_REL;
                    end else wait_cnt <= wait_cnt + 16'd1;
                end

                ST_REL: begin
                    if (wait_cnt + 16'd1 >= SETL_CYC) begin
                        wait_cnt  <= 16'd0;
                        cell_sel  <= 8'd0;
                        state     <= ST_SETL;
                    end else wait_cnt <= wait_cnt + 16'd1;
                end

                ST_SETL: begin
                    // cell_sel 已稳定一拍, 等 bit 同步
                    state <= ST_SCAN;
                end

                ST_SCAN: begin
                    // 每单元 3 拍: 稳定 -> 采样写 RAM -> 下一单元
                    cm_we   <= 1'b1;
                    cm_waddr<= cell_sel;
                    cm_wdata<= {31'd0, bit_s2};
                    if (cell_sel == 8'd255) begin
                        running   <= 1'b0;
                        done_flag <= 1'b1;
                        state     <= ST_DONE;
                    end else begin
                        cell_sel <= cell_sel + 8'd1;
                        state    <= ST_SETL;
                    end
                end

                ST_DONE: if (!start_pend) state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // AXI-Lite 写处理
    //-------------------------------------------------------------------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0; axi_wready <= 1'b0; axi_bvalid <= 1'b0; axi_bresp <= 2'b00;
            soft_rst <= 1'b0; start_pend <= 1'b0;
        end else begin
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
                    default: ;
                endcase
                if ((S_AXI_AWADDR[12:0] == 13'h008) && S_AXI_WDATA[0] && !running) begin
                    start_pend <= 1'b1;
                end
            end else if (start_take) begin
                start_pend <= 1'b0;
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
    // AXI-Lite 读处理 (INCR)
    //-------------------------------------------------------------------------
    reg [12:0] araddr_reg;
    reg [7:0]  beat_cnt, arlen_lat;
    reg        rd_active;
    reg [31:0] rd_mux;

    wire ar_in_cell = (S_AXI_ARADDR[12:0] >= 13'h100) && (S_AXI_ARADDR[12:0] <= 13'h4FC);
    wire rr_in_cell = (araddr_reg >= 13'h100) && (araddr_reg <= 13'h4F8);

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0; axi_rvalid <= 1'b0; axi_rresp <= 2'b00;
            araddr_reg <= 13'd0; arlen_lat <= 8'd0; beat_cnt <= 8'd0;
            rd_active <= 1'b0; cm_raddr <= 8'd0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                araddr_reg  <= S_AXI_ARADDR[12:0];
                arlen_lat   <= S_AXI_ARLEN;
                beat_cnt    <= 8'd0;
                rd_active   <= 1'b1;
                if (ar_in_cell) cm_raddr <= (S_AXI_ARADDR[12:0] - 13'h100) >> 2;
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
                    axi_rvalid <= 1'b0;
                    rd_active  <= 1'b0;
                    rlast      <= 1'b0;
                end else begin
                    beat_cnt   <= beat_cnt + 8'd1;
                    araddr_reg <= araddr_reg + 13'd4;
                    if (rr_in_cell) cm_raddr <= cm_raddr + 8'd1;
                    axi_rvalid <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        case (araddr_reg)
            13'h000: rd_mux = 32'h0007_0000;
            13'h004: rd_mux = {8'd0, 8'd1, 8'd0, 16'd256};
            13'h008: rd_mux = {30'd0, soft_rst, running};
            13'h00C: rd_mux = {30'd0, done_flag, running};
            13'h018: rd_mux = {16'h5A5A, run_cnt};
            default: begin
                if ((araddr_reg >= 13'h100) && (araddr_reg <= 13'h4FC))
                    rd_mux = cm_rdata_r;
                else
                    rd_mux = 32'h0000_0000;
            end
        endcase
    end

endmodule
`default_nettype wire
