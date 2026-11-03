// pdl_ring.v — 挑战可编程环形振荡器 (v6, 2026-10-29)
//   仲裁 PUF 的边沿竞速版在 7 系列上被证实不可行 (上下链系统偏差 3-5ns >> PDL
//   信号 ~10ps, 交替 BEL 无法抵消), 本模块保留 Majzoobi PDL 挑战机制但改为
//   频率测量: 环 = 1 个使能门 LUT2 + 64 个 LUT6 反相器级 (共 65 次反相, 奇数).
//   每级 LUT6 的 I1..I5 = 挑战位选择 0 或 STEP 档 -> 挑战图案决定环频.
//   TFF 二分输出供 100MHz 采样计数.
`timescale 1ns / 1ps

module pdl_ring #(
    parameter integer NSTAGE = 64
)(
    input  wire        rstn,      // 1=振荡, 0=停振 (锁 1)
    input  wire [4:0]  tune,      // 首级调谐档
    input  wire [63:0] ch,        // 每级挑战位
    input  wire [4:0]  step,      // 挑战位=1 时的延迟档
    output wire        ro_out
);

    (* dont_touch = "true", keep = "true" *) wire [NSTAGE:0] n;

    // 使能门: n[0] = ~(n[64] & rstn); rstn=0 -> 锁 1 停振
    LUT2 #(.INIT(4'h7)) u_gate (.O(n[0]), .I0(n[NSTAGE]), .I1(rstn));

    // 首级 (tune 控制)
    LUT6 #(.INIT(64'h5555555555555555)) u_tn (
        .O(n[1]), .I0(n[0]), .I1(tune[0]), .I2(tune[1]),
        .I3(tune[2]), .I4(tune[3]), .I5(tune[4]));

    genvar i;
    generate
        for (i = 0; i < NSTAGE - 1; i = i + 1) begin : g_stage
            wire [4:0] ct = ch[i] ? step : 5'd0;
            LUT6 #(.INIT(64'h5555555555555555)) u_ps (
                .O(n[i+2]), .I0(n[i+1]), .I1(ct[0]), .I2(ct[1]),
                .I3(ct[2]), .I4(ct[3]), .I5(ct[4]));
        end
    endgenerate

    // 二分采样
    (* dont_touch = "true" *) reg out_s;
    always @(posedge n[0] or negedge rstn) begin
        if (!rstn) out_s <= 1'b0;
        else       out_s <= ~out_s;
    end
    assign ro_out = out_s;

endmodule
