// ro_ring.v — 显式原语环形振荡器 (v3, 2026-10-29)
//   v2 (VHDL 推断的 32 级 LUT 反相链) 实测被综合器整体折叠: 布线后 31 级 chain 网
//   全部悬空, 环退化成 1 个 LUT2 自环 (~2-3GHz), TFF 时钟不可用 -> 板上计数恒 0。
//   根因: 纯推断逻辑 + keep 只能保网名, 保不住"每级一个 LUT"的结构。
//   v3 改为直接实例化 UNISIM LUT1/LUT2 原语并加 DONT_TOUCH, 逐级固定为一个 LUT。
//   环内反相次数 = 1 (gate) + CHAIN (奇数个反相 -> 振荡), CHAIN 偶数时总反相为奇数。
//   周期 ~ 33 x (LUT + 布线) -> 20-45ns -> 原始 22-50MHz, TFF 二分后 11-25MHz,
//   100MHz 采样奈奎斯特安全。

`timescale 1ns / 1ps

(* dont_touch = "true" *)
module ro_ring #(
    parameter integer CHAIN = 32          // 反相级数 (偶数)
)(
    input  wire rstn,                     // 1 = 振荡, 0 = 停振 (ch[0] 锁 1)
    output wire ro_out
);

    (* dont_touch = "true", keep = "true" *) wire [CHAIN:0] ch;

    // ch[0] = ~(ch[CHAIN] & rstn)
    //   rstn=0 -> ch[0]=1 (直流稳态, 不振荡)
    //   rstn=1 -> ch[0]=~ch[CHAIN], 与 32 级反相共 33 次反相 -> 振荡
    LUT2 #(.INIT(4'h7)) u_gate (.O(ch[0]), .I0(ch[CHAIN]), .I1(rstn));

    genvar i;
    generate
        for (i = 0; i < CHAIN; i = i + 1) begin : g_inv
            LUT1 #(.INIT(2'b01)) u_inv (.O(ch[i+1]), .I0(ch[i]));
        end
    endgenerate

    // 二分采样翻转: 异步复位到 0, 停振期间保持
    (* dont_touch = "true" *) reg out_s;
    always @(posedge ch[0] or negedge rstn) begin
        if (!rstn) out_s <= 1'b0;
        else       out_s <= ~out_s;
    end

    assign ro_out = out_s;

endmodule
