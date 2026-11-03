// br_ring16.v — 16 级双稳环单元 (v9.0, 2026-10-30)
//   v8 教训: 单个 64 级环钉在一列 -> 布线剖面跨芯片逐位相同 -> 收敛方向被写死
//   (双板 inter-HD 仅 0.78%)。v9 改为 64 环 x 16 级阵列, 每环独占一列:
//   各环布线偏置不同, 部分环自然处于近平局 -> 跨芯片翻转 (SRAM 单元同机理)。
//   每级 LUT3: en=0 -> O=0 (全复位); en=1 -> O = I_prev XOR C_i
//   16 位挑战 popcount 为偶 -> 双稳; 为奇 -> 振荡 (挑战端约束)。
`timescale 1ns / 1ps

module br_ring16 (
    input  wire        en,        // 1=该环被选中并释放; 0=复位保持 0
    input  wire [15:0] ch,        // 环内挑战 (偶 popcount)
    output wire        br_out
);

    (* dont_touch = "true", keep = "true" *) wire [15:0] n;

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_stage
            wire prev = (i == 0) ? n[15] : n[i-1];
            LUT3 #(.INIT(8'h60)) u_ps (.O(n[i]), .I0(prev), .I1(ch[i]), .I2(en));
        end
    endgenerate

    assign br_out = n[0];

endmodule
