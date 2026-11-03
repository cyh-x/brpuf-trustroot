// br_ring.v — 双稳环 PUF (BR-PUF, v8.1, 2026-10-30)
//   结构: Chen/Csaba/Lugli/Schlichtmann/Rührmair "The Bistable Ring PUF" (DATE 2011)
//     64 级环, 每级: O = en ? (I_prev XOR C_i) : 1'b0
//       en=0 -> 所有节点被压到 0 (统一复位态, 通常与环方程矛盾 => 亚稳)
//       en=1 -> 环闭合, 由各级失配决定收敛到两个稳定态之一 => 响应对
//     挑战位为 1 的级是反相器, 为 0 是缓冲器。总反转数必须为偶 (否则振荡不收敛)。
//   关键修正 (v8.1): v8.0 只强制首级 n[0]=1, 而该状态恰是环的不动点, 释放后环不动
//     => 所有挑战响应恒 1 (板上实测 16/16 全 1)。改为全节点统一复位 0 才有竞争。
//   7 系列 FPGA 已知痛点: 布线规则性导致系统性偏置。对策: 硬宏单列 + 逐级交替 BEL。
`timescale 1ns / 1ps

module br_ring #(
    parameter integer NSTAGE = 64
)(
    input  wire        en,        // 0=全节点复位为 0, 1=环闭合 (双稳竞争)
    input  wire [63:0] ch,        // 每级挑战位 (popcount 必须为偶数)
    output wire        br_out     // 环稳态位 (采样 n[0])
);

    (* dont_touch = "true", keep = "true" *) wire [NSTAGE-1:0] n;

    // 每级 LUT3: I0 = 前一级, I1 = 挑战位, I2 = en
    //   en=0 -> O=0 ; en=1 -> O = I0 XOR I1
    //   真值表 (I2 I1 I0): 000->0 001->0 010->0 011->0 100->0 101->1 110->1 111->0
    //   INIT[7:0] = 0110_0000 = 0x60
    genvar i;
    generate
        for (i = 0; i < NSTAGE; i = i + 1) begin : g_stage
            wire prev = (i == 0) ? n[NSTAGE-1] : n[i-1];
            LUT3 #(.INIT(8'h60)) u_ps (.O(n[i]), .I0(prev), .I1(ch[i]), .I2(en));
        end
    endgenerate

    assign br_out = n[0];

endmodule
