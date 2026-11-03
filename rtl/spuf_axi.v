//=============================================================================
// spuf_axi.v — Strong PUF (4x4 switch-block Arbiter PUF) AXI4-Lite 封装
//   AX7020 移植, 工作区: FPGA设计创新竞赛/strongpuf_port
//
// PUF 核心: GitHub canaknesil/4x4-apuf (MIT, KTH 硕士论文 + IEEE ISMVL 2018)
//   原理: 4 条等长路径穿过 24 级 4x4 开关块(每级 5bit 挑战=4 路径 24 种置换
//   之一), 终点仲裁器做 C(4,2)=6 场两两竞态(谁先到), 输出 6bit mutual_order。
//   挑战 120bit, CRP 空间 2^120, 属 strong PUF。
//   上游 DONT_TOUCH 全套保护; 每级 4 mux 同 slice 垂直堆叠布局由 build 脚本生成。
//
// 本封装 (对上游核心零改动):
//   1) AXI4-Lite 从机 (12bit 地址 = 4KB 空间), 读通道支持 INCR 突发
//   2) 挑战 RAM 1024x128bit: 主机写 CH0-3 + CH_PUSH 入队
//   3) 批量自动采集: NCHAL 个挑战 x R 次重复, 片上逐位多数表决
//      -> 响应 RAM 每挑战 1 word: [5:0]=vote(R 严格多数) [11:6]=不稳定位掩码
//   4) 单发模式: CTRL.b2=1 触发, 挑战取 CH0-3, LAST_RAW 读最近原始竞态
//
// 寄存器 (基址 0x4000_0000):
//   0x000 RO  VERSION   = 0x0003_0000 (v3.0, strong)
//   0x004 RO  CAP       = {8'h00, 8'd24, 16'd120}  (stage_n, challenge bits)
//   0x008 RW  CTRL      b0=start_batch b1=soft_rst b2=single_shot
//   0x00C RO  STATUS    b0=busy b1=done
//   0x010 RW  REPETITIONS  R (1..63, 写 0 按 15 处理, 表决用严格多数)
//   0x014 RW  NCHAL     批内挑战数 (1..1024, 写 0 按 1)
//   0x018 RO  MAGIC     = {16'h5A5A, 批计数}
//   0x01C RO  LAST_RAW  [5:0] 最近原始 mutual_order  [11:6] 单发不稳定掩码
//                        (bit i = 竞态对 i+1, 即 VHDL mutual_order(i+1))
//   0x020-0x02C RW CH0-CH3  128bit 挑战数据 (低 120bit 有效)
//   0x030 WO  CH_PUSH   写 1: 把 CH0-3 存入挑战 RAM, 地址 = WDATA[11:2]
//   0x100+4i RO RESP[i] 挑战 i 表决结果 (i=0..1023, 窗口止于 0x10FC)
//=============================================================================
`timescale 1 ns / 1 ps
`default_nettype none

module spuf_axi #(
    parameter integer C_S_AXI_ADDR_WIDTH = 13,     // 8KB: 响应窗口 1024 字需 0x100..0x10FC
    parameter integer STAGE_N            = 24,
    parameter integer NCHAL_MAX          = 1024,
    parameter integer SETTLE_CYCLES       = 8       // 脉冲后等待拍数 (80ns >> 24 级组合路径)
) (
    output wire                                  spuf_busy_o,
    output wire                                  spuf_done_o,

    input  wire                                  S_AXI_ACLK,
    input  wire                                  S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       S_AXI_AWADDR,
    input  wire [2 : 0]                          S_AXI_AWPROT,
    input  wire                                  S_AXI_AWVALID,
    output wire                                  S_AXI_AWREADY,
    input  wire [31 : 0]                         S_AXI_WDATA,
    input  wire [3 : 0]                          S_AXI_WSTRB,
    input  wire                                  S_AXI_WVALID,
    output wire                                  S_AXI_WREADY,
    output wire [1 : 0]                          S_AXI_BRESP,
    output wire                                  S_AXI_BVALID,
    input  wire                                  S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]       S_AXI_ARADDR,
    input  wire [7 : 0]                          S_AXI_ARLEN,
    input  wire [2 : 0]                          S_AXI_ARPROT,
    input  wire                                  S_AXI_ARVALID,
    output wire                                  S_AXI_ARREADY,
    output wire [31 : 0]                         S_AXI_RDATA,
    output wire [1 : 0]                          S_AXI_RRESP,
    output wire                                  S_AXI_RLAST,
    output wire                                  S_AXI_RVALID,
    input  wire                                  S_AXI_RREADY
);

    localparam integer CH_W = 5 * STAGE_N;          // 120

    //-------------------------------------------------------------------------
    // AXI4-Lite 握手 (已验证骨架, 含 INCR 突发读)
    //-------------------------------------------------------------------------
    reg axi_awready, axi_wready, axi_arready, axi_rvalid, axi_bvalid;
    reg [1:0]  axi_bresp, axi_rresp;
    reg        rlast;
    wire [31:0] axi_rdata;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;
    assign S_AXI_RLAST   = rlast;

    wire slv_wren = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    //-------------------------------------------------------------------------
    // 用户寄存器
    //-------------------------------------------------------------------------
    reg        soft_rst;
    reg        start_pend;      // 批采集请求 (锁存, FSM 消费)
    reg        single_pend;     // 单发请求 (锁存)
    reg        start_take;      // FSM -> AXI 块握手脉冲 (start_pend 单一驱动防线)
    reg [5:0]  rep_n;           // R
    reg [9:0]  nchal;           // 批内挑战数
    reg [15:0] batch_cnt;
    reg [31:0] ch_word0, ch_word1, ch_word2, ch_word3;

    wire        core_rst_n = S_AXI_ARESETN & (~soft_rst);
    wire [5:0]  n_rep  = (rep_n == 6'd0) ? 6'd15 : rep_n;
    wire [5:0]  thresh = (n_rep + 6'd1) >> 1;      // (R+1)/2 严格多数
    wire [127:0] ch_single = {ch_word3, ch_word2, ch_word1, ch_word0};

    //-------------------------------------------------------------------------
    // PUF 核心 (VHDL, 上游原样): canaknesil/4x4-apuf
    //   VHDL 端口 (1 to 4)/(1 to 6) 在 Verilog 侧用 [4:1]/[6:1] 对齐
    //-------------------------------------------------------------------------
    // [XOR-APUF 2026-10-29] 4 实例异或 (文献标准 strong PUF 架构):
    //   单实例布局系统差压倒工艺差 (实测 uniqueness 3.65%); 4 个实例分放 4 列,
    //   挑战相位错开 30bit(=6 级), 响应 6bit 异或 -> 各实例系统差方向独立随机,
    //   异或后系统性分量大幅抵消, 剩余为工艺差+噪声 (k-XOR 让板间 HD 趋向 50%)
    wire [4:1]     apuf_paths_x;
    wire [CH_W-1:0] ch_rot1, ch_rot2, ch_rot3;
    wire [6:1]     mo0, mo1, mo2, mo3;
    wire [6:1]     apuf_mo;
    reg            apuf_pulse;
    reg [CH_W-1:0] ch_reg;

    assign apuf_paths_x[1] = apuf_pulse;
    assign apuf_paths_x[2] = apuf_pulse;
    assign apuf_paths_x[3] = apuf_pulse;
    assign apuf_paths_x[4] = apuf_pulse;
    // 挑战旋转 30k bit: 每 5bit 一级, 30bit = 6 级错位 -> 4 实例等效独立挑战
    assign ch_rot1 = (ch_reg << 30) | (ch_reg >> (CH_W - 30));
    assign ch_rot2 = (ch_reg << 60) | (ch_reg >> (CH_W - 60));
    assign ch_rot3 = (ch_reg << 90) | (ch_reg >> (CH_W - 90));

    APUF_Mutual_Order #(.stage_n(STAGE_N)) u_apuf0 (
        .paths(apuf_paths_x), .challenge(ch_reg),  .response_mutual_order(mo0));
    APUF_Mutual_Order #(.stage_n(STAGE_N)) u_apuf1 (
        .paths(apuf_paths_x), .challenge(ch_rot1), .response_mutual_order(mo1));
    APUF_Mutual_Order #(.stage_n(STAGE_N)) u_apuf2 (
        .paths(apuf_paths_x), .challenge(ch_rot2), .response_mutual_order(mo2));
    APUF_Mutual_Order #(.stage_n(STAGE_N)) u_apuf3 (
        .paths(apuf_paths_x), .challenge(ch_rot3), .response_mutual_order(mo3));

    assign apuf_mo = mo0 ^ mo1 ^ mo2 ^ mo3;

    //-------------------------------------------------------------------------
    // 采集 FSM
    //   PULSE 1 拍 -> SETTLE 8 拍 (80ns >> 24 级组合路径) -> CAPTURE;
    //   竞态 FF 由路径脉冲直接驱动时钟 (上游设计), 一旦判决即保持, 晚采安全。
    //-------------------------------------------------------------------------
    localparam ST_IDLE   = 4'd0;
    localparam ST_RD_WAIT= 4'd1;   // 挑战 RAM 读延迟
    localparam ST_LOAD   = 4'd2;   // 装载挑战 + 清计票
    localparam ST_PULSE  = 4'd3;
    localparam ST_SETTLE = 4'd4;
    localparam ST_CAPT   = 4'd5;
    localparam ST_VOTE   = 4'd6;
    localparam ST_WR_RSP = 4'd7;
    localparam ST_NEXT   = 4'd8;
    localparam ST_DONE   = 4'd9;

    reg [3:0]  state;
    reg        running, done_flag, single_mode;
    reg [9:0]  ch_idx;
    reg [5:0]  rep_cnt;
    reg [7:0]  settle_cnt;
    wire [9:0] n_ch = (nchal == 10'd0) ? 10'd1 : nchal;

    //-------------------------------------------------------------------------
    // 6 场竞态逐位计票 + 表决 (generate 展开, 每 bit 一个驱动块)
    //-------------------------------------------------------------------------
    reg [6:1] vote_bits, unst_bits, last_raw, last_mask;
    wire clr_ones = (state == ST_LOAD);
    wire inc_ones = (state == ST_CAPT);
    wire vote_we  = (state == ST_VOTE);

    genvar gi;
    generate
        for (gi = 1; gi <= 6; gi = gi + 1) begin : g_race
            reg [5:0] ones;
            always @(posedge S_AXI_ACLK) begin
                if (!core_rst_n)       ones <= 6'd0;
                else if (clr_ones)     ones <= 6'd0;
                else if (inc_ones)     ones <= ones + {5'd0, apuf_mo[gi]};
            end
            always @(posedge S_AXI_ACLK) begin
                if (vote_we) begin
                    vote_bits[gi] <= (ones >= thresh);
                    unst_bits[gi] <= (ones != 6'd0) && (ones != n_rep);
                    last_raw[gi]  <= apuf_mo[gi];
                    last_mask[gi] <= (ones != 6'd0) && (ones != n_rep);
                end
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // 挑战 RAM (A口单写源=AXI) / 响应 RAM (A口单写源=FSM)
    //-------------------------------------------------------------------------
    (* ram_style = "block" *) reg [127:0] chmem [0:NCHAL_MAX-1];
    (* ram_style = "block" *) reg [31:0]  rpmem [0:NCHAL_MAX-1];

    reg  [9:0]  ch_waddr;
    reg  [127:0] ch_wdata;
    reg         ch_we;
    reg  [9:0]  ch_raddr;
    reg  [127:0] ch_rdata_r;
    always @(posedge S_AXI_ACLK) begin
        if (ch_we) chmem[ch_waddr] <= ch_wdata;
        ch_rdata_r <= chmem[ch_raddr];
    end

    reg  [9:0]  rp_waddr;
    reg  [31:0] rp_wdata;
    reg         rp_we;
    reg  [9:0]  rp_raddr;
    reg  [31:0] rp_rdata_r;
    always @(posedge S_AXI_ACLK) begin
        if (rp_we) rpmem[rp_waddr] <= rp_wdata;
        rp_rdata_r <= rpmem[rp_raddr];
    end


    assign spuf_busy_o = running;
    assign spuf_done_o = done_flag;

    always @(posedge S_AXI_ACLK) begin
        if (!core_rst_n) begin
            state       <= ST_IDLE;
            apuf_pulse  <= 1'b0;
            ch_reg      <= {CH_W{1'b0}};
            ch_idx      <= 10'd0;
            rep_cnt     <= 6'd0;
            settle_cnt  <= 8'd0;
            running     <= 1'b0;
            done_flag   <= 1'b0;
            single_mode <= 1'b0;
            ch_raddr    <= 10'd0;
            rp_we       <= 1'b0;
            rp_waddr    <= 10'd0;
            rp_wdata    <= 32'd0;
            batch_cnt   <= 16'd0;
            start_take  <= 1'b0;
        end else begin
            start_take <= 1'b0;
            rp_we      <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b0;
                        ch_idx      <= 10'd0;
                        batch_cnt   <= batch_cnt + 16'd1;
                        ch_raddr    <= 10'd0;
                        state       <= ST_RD_WAIT;
                    end else if (single_pend) begin
                        start_take  <= 1'b1;
                        running     <= 1'b1;
                        done_flag   <= 1'b0;
                        single_mode <= 1'b1;
                        state       <= ST_LOAD;
                    end
                end

                ST_RD_WAIT: state <= ST_LOAD;

                ST_LOAD: begin
                    ch_reg  <= single_mode ? ch_single[CH_W-1:0] : ch_rdata_r[CH_W-1:0];
                    rep_cnt <= 6'd0;
                    state   <= ST_PULSE;
                end

                ST_PULSE: begin
                    apuf_pulse <= 1'b1;
                    settle_cnt <= 8'd0;
                    state      <= ST_SETTLE;
                end

                ST_SETTLE: begin
                    apuf_pulse <= 1'b0;
                    settle_cnt <= settle_cnt + 8'd1;
                    if (settle_cnt >= SETTLE_CYCLES)
                        state <= ST_CAPT;
                end

                ST_CAPT: begin
                    rep_cnt <= rep_cnt + 6'd1;
                    state   <= (rep_cnt + 6'd1 >= n_rep) ? ST_VOTE : ST_PULSE;
                end

                ST_VOTE: begin
                    // vote_bits/unst_bits/last_raw/last_mask 在 g_race generate 内锁存
                    state <= ST_WR_RSP;
                end

                ST_WR_RSP: begin
                    rp_we    <= 1'b1;
                    rp_waddr <= ch_idx;
                    rp_wdata <= {20'd0, unst_bits, vote_bits};
                    state    <= ST_NEXT;
                end

                ST_NEXT: begin
                    if (single_mode || (ch_idx + 10'd1 >= n_ch)) begin
                        running   <= 1'b0;
                        done_flag <= 1'b1;
                        state     <= ST_DONE;
                    end else begin
                        ch_idx   <= ch_idx + 10'd1;
                        ch_raddr <= ch_idx + 10'd1;
                        state    <= ST_RD_WAIT;
                    end
                end

                ST_DONE: begin
                    if (start_pend || single_pend) begin
                        done_flag <= 1'b0;
                        state     <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // AXI-Lite 写处理 (start_pend/single_pend/chmem 写端口唯一驱动点)
    //-------------------------------------------------------------------------
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
            axi_bresp   <= 2'b00;
            soft_rst    <= 1'b0;
            start_pend  <= 1'b0;
            single_pend <= 1'b0;
            rep_n       <= 6'd0;
            nchal       <= 10'd0;
            ch_word0 <= 32'd0; ch_word1 <= 32'd0;
            ch_word2 <= 32'd0; ch_word3 <= 32'd0;
            ch_we    <= 1'b0;
            ch_waddr <= 10'd0;
            ch_wdata <= 128'd0;
        end else begin
            ch_we <= 1'b0;

            if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end

            if (slv_wren) begin
                case (S_AXI_AWADDR[12:0])
                    12'h008: soft_rst <= S_AXI_WDATA[1];
                    12'h010: rep_n    <= S_AXI_WDATA[5:0];
                    12'h014: nchal    <= S_AXI_WDATA[9:0];
                    12'h020: ch_word0 <= S_AXI_WDATA;
                    12'h024: ch_word1 <= S_AXI_WDATA;
                    12'h028: ch_word2 <= S_AXI_WDATA;
                    12'h02C: ch_word3 <= S_AXI_WDATA;
                    12'h030: if (S_AXI_WDATA[0]) begin
                        ch_we    <= 1'b1;
                        ch_waddr <= S_AXI_WDATA[11:2];
                        ch_wdata <= {ch_word3, ch_word2, ch_word1, ch_word0};
                    end
                    default: ;
                endcase
            end

            // start/single 置位优先于 FSM 消费清零 (同拍竞争保留新请求)
            if (slv_wren && (S_AXI_AWADDR[12:0] == 12'h008) && !running) begin
                if (S_AXI_WDATA[2])      single_pend <= 1'b1;
                else if (S_AXI_WDATA[0]) start_pend  <= 1'b1;
            end else if (start_take) begin
                start_pend  <= 1'b0;
                single_pend <= 1'b0;
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
    // AXI-Lite 读处理 (支持 INCR 突发: 每拍地址+4, 末拍 rlast)
    //   响应窗口 0x100..0x10FC -> BRAM; 其余走寄存器 mux
    //-------------------------------------------------------------------------
    reg [12:0] araddr_reg;
    reg [7:0]  beat_cnt;
    reg [7:0]  arlen_lat;
    reg        rd_active;
    reg [31:0] rd_mux;

    wire ar_in_resp = (S_AXI_ARADDR[12:0] >= 13'h100) && (S_AXI_ARADDR[12:0] <= 13'h10FC);
    wire rr_in_resp = (araddr_reg >= 13'h100) && (araddr_reg <= 13'h10F8);

    // 节拍间隔协议: 每拍 rvalid 拉低 1 拍, 保证 BRAM (1 拍读延迟) 数据新鲜,
    // 不依赖主机的突发节奏 (jtag_axi 背靠背行为未证实, 不赌)
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rresp   <= 2'b00;
            araddr_reg  <= 13'd0;
            arlen_lat   <= 8'd0;
            beat_cnt    <= 8'd0;
            rd_active   <= 1'b0;
            rlast       <= 1'b0;
            rp_raddr    <= 10'd0;
        end else begin
            if (~axi_arready && S_AXI_ARVALID) begin
                axi_arready <= 1'b1;
                araddr_reg  <= S_AXI_ARADDR[12:0];
                arlen_lat   <= S_AXI_ARLEN;
                beat_cnt    <= 8'd0;
                rd_active   <= 1'b1;
                if (ar_in_resp)
                    rp_raddr <= (S_AXI_ARADDR[12:0] - 13'h100) >> 2;
            end else begin
                axi_arready <= 1'b0;
            end

            // rvalid 拉高: 仅在读事务进行中且非 AR 接受拍 (BRAM 预读需 1 拍)
            if (!axi_arready && rd_active && !axi_rvalid) begin
                axi_rvalid <= 1'b1;
                axi_rresp  <= 2'b00;
                rlast      <= (beat_cnt == arlen_lat);
            end

            // 节拍被接受
            if (axi_rvalid && S_AXI_RREADY) begin
                if (beat_cnt == arlen_lat) begin
                    axi_rvalid <= 1'b0;
                    rd_active  <= 1'b0;
                    rlast      <= 1'b0;
                end else begin
                    beat_cnt   <= beat_cnt + 8'd1;
                    araddr_reg <= araddr_reg + 13'd4;
                    if (rr_in_resp)
                        rp_raddr <= rp_raddr + 10'd1;
                    axi_rvalid <= 1'b0;   // 1 拍间隔: 新地址的 BRAM 读数
                end
            end
        end
    end

    // 读数据多路选择器
    always @(*) begin
        case (araddr_reg)
            12'h000: rd_mux = 32'h0003_0000;                       // VERSION (v3.0 strong)
            12'h004: rd_mux = {8'h00, 8'd24, 16'd120};             // CAP: stage_n, ch bits
            12'h008: rd_mux = {29'd0, single_mode, soft_rst, running}; // CTRL 回读
            12'h00C: rd_mux = {30'd0, done_flag, running};         // STATUS
            12'h010: rd_mux = {26'd0, rep_n};                      // REPETITIONS
            12'h014: rd_mux = {22'd0, nchal};                      // NCHAL
            12'h018: rd_mux = {16'h5A5A, batch_cnt};               // MAGIC
            12'h01C: rd_mux = {20'd0, last_mask, last_raw};        // LAST_RAW
            12'h020: rd_mux = ch_word0;
            12'h024: rd_mux = ch_word1;
            12'h028: rd_mux = ch_word2;
            12'h02C: rd_mux = ch_word3;
            default: begin
                if ((araddr_reg >= 13'h100) && (araddr_reg <= 13'h10FC))
                    rd_mux = rp_rdata_r;                            // 响应窗口
                else
                    rd_mux = 32'h0000_0000;
            end
        endcase
    end

    assign axi_rdata = rd_mux;

endmodule
`default_nettype wire
