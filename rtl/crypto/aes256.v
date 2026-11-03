`timescale 1ns / 1ps

module aes256_sbox (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire       inverse,
    input  wire [7:0] data_in,
    output reg  [7:0] data_out,
    output reg        done
);

    (* rom_style = "block" *) reg [7:0] rom [0:511];
    reg [7:0] rom_data;
    reg       pending;
    integer   i;

    function [7:0] gf_mul(input [7:0] a_in, input [7:0] b_in);
        reg [7:0] a, b, p;
        integer k;
        begin
            a = a_in;
            b = b_in;
            p = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                if (b[0]) p = p ^ a;
                a = {a[6:0], 1'b0} ^ (8'h1b & {8{a[7]}});
                b = {1'b0, b[7:1]};
            end
            gf_mul = p;
        end
    endfunction

    function [7:0] gf_inverse(input [7:0] x);
        reg [7:0] a, r, e;
        integer k;
        begin
            a = x;
            r = 8'h01;
            e = 8'hfe;
            for (k = 0; k < 8; k = k + 1) begin
                if (e[0]) r = gf_mul(r, a);
                a = gf_mul(a, a);
                e = {1'b0, e[7:1]};
            end
            gf_inverse = r;
        end
    endfunction

    function [7:0] forward_value(input [7:0] x);
        reg [7:0] y;
        begin
            y = gf_inverse(x);
            forward_value = y ^ {y[6:0], y[7]} ^ {y[5:0], y[7:6]} ^ {y[4:0], y[7:5]} ^ {y[3:0], y[7:4]} ^ 8'h63;
        end
    endfunction

    function [7:0] inverse_value(input [7:0] x);
        reg [7:0] y;
        begin
            y = {x[6:0], x[7]} ^ {x[4:0], x[7:5]} ^ {x[1:0], x[7:2]} ^ 8'h05;
            inverse_value = gf_inverse(y);
        end
    endfunction

    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            rom[i]       = forward_value(i[7:0]);
            rom[i + 256] = inverse_value(i[7:0]);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rom_data <= 8'h00;
            data_out <= 8'h00;
            pending  <= 1'b0;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start && !pending) begin
                rom_data <= rom[{inverse, data_in}];
                pending  <= 1'b1;
            end else if (pending) begin
                data_out <= rom_data;
                pending  <= 1'b0;
                done     <= 1'b1;
            end
        end
    end

endmodule

module aes256_block (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         key_start,
    input  wire [255:0] key_in,
    output reg          key_ready,
    input  wire         block_start,
    input  wire         encrypt,
    input  wire [127:0] data_in,
    output reg  [127:0] data_out,
    output reg          block_done,
    output reg          busy
);

    reg [7:0]  state_bytes [0:15];
    reg [31:0] key_words [0:59];
    reg [31:0] key_temp;
    reg [5:0]  key_index;
    reg [2:0]  key_sub_index;
    reg [3:0]  byte_index;
    reg [1:0]  column_index;
    reg [3:0]  round_count;
    reg        mode_encrypt;

    reg       sbox_start;
    reg       sbox_inverse;
    reg [7:0] sbox_data_in;
    wire [7:0] sbox_data_out;
    wire       sbox_done;
    integer i;

    aes256_sbox u_sbox (
        .clk(clk),
        .rst_n(rst_n),
        .start(sbox_start),
        .inverse(sbox_inverse),
        .data_in(sbox_data_in),
        .data_out(sbox_data_out),
        .done(sbox_done)
    );

    function [7:0] rcon(input [3:0] index);
        begin
            case (index)
                4'd1: rcon = 8'h01;
                4'd2: rcon = 8'h02;
                4'd3: rcon = 8'h04;
                4'd4: rcon = 8'h08;
                4'd5: rcon = 8'h10;
                4'd6: rcon = 8'h20;
                4'd7: rcon = 8'h40;
                default: rcon = 8'h00;
            endcase
        end
    endfunction

    function [7:0] key_sub_byte(input [31:0] word_in, input [2:0] index, input rotate);
        begin
            if (rotate) begin
                case (index)
                    3'd0: key_sub_byte = word_in[23:16];
                    3'd1: key_sub_byte = word_in[15:8];
                    3'd2: key_sub_byte = word_in[7:0];
                    default: key_sub_byte = word_in[31:24];
                endcase
            end else begin
                case (index)
                    3'd0: key_sub_byte = word_in[31:24];
                    3'd1: key_sub_byte = word_in[23:16];
                    3'd2: key_sub_byte = word_in[15:8];
                    default: key_sub_byte = word_in[7:0];
                endcase
            end
        end
    endfunction

    function [7:0] round_key_byte(input [3:0] round_number, input [3:0] byte_number);
        reg [5:0] address;
        begin
            address = {round_number, 2'b00} + {4'b0000, byte_number[3:2]};
            case (byte_number[1:0])
                2'd0: round_key_byte = key_words[address][31:24];
                2'd1: round_key_byte = key_words[address][23:16];
                2'd2: round_key_byte = key_words[address][15:8];
                default: round_key_byte = key_words[address][7:0];
            endcase
        end
    endfunction

    function [3:0] shift_index(input [3:0] index, input inverse);
        reg [1:0] row, column;
        begin
            row = index[1:0];
            column = index[3:2];
            shift_index = {inverse ? column - row : column + row, row};
        end
    endfunction

    function [7:0] xtime(input [7:0] x);
        begin
            xtime = {x[6:0], 1'b0} ^ (8'h1b & {8{x[7]}});
        end
    endfunction

    function [31:0] mix_column(input [7:0] c0, input [7:0] c1, input [7:0] c2, input [7:0] c3, input inverse);
        reg [7:0] a0, a1, a2, a3, t, u, v;
        begin
            a0 = c0;
            a1 = c1;
            a2 = c2;
            a3 = c3;

            if (inverse) begin
                u = xtime(xtime(c0 ^ c2));
                v = xtime(xtime(c1 ^ c3));
                a0 = c0 ^ u;
                a1 = c1 ^ v;
                a2 = c2 ^ u;
                a3 = c3 ^ v;
            end

            t = a0 ^ a1 ^ a2 ^ a3;
            mix_column = {
                a0 ^ t ^ xtime(a0 ^ a1),
                a1 ^ t ^ xtime(a1 ^ a2),
                a2 ^ t ^ xtime(a2 ^ a3),
                a3 ^ t ^ xtime(a3 ^ a0)
            };
        end
    endfunction

    wire [5:0] column_base = {2'b00, column_index, 2'b00};
    wire [31:0] mix_result = mix_column(
        state_bytes[column_base],
        state_bytes[column_base + 6'd1],
        state_bytes[column_base + 6'd2],
        state_bytes[column_base + 6'd3],
        !mode_encrypt
    );

    localparam [4:0]
        S_IDLE          = 5'd0,
        S_KEY_NEXT      = 5'd1,
        S_KEY_SB_START  = 5'd2,
        S_KEY_SB_WAIT   = 5'd3,
        S_KEY_DONE      = 5'd4,
        S_INITIAL_ARK   = 5'd5,
        S_ENC_SB_START  = 5'd6,
        S_ENC_SB_WAIT   = 5'd7,
        S_ENC_SHIFT     = 5'd8,
        S_ENC_MIX       = 5'd9,
        S_ENC_ARK       = 5'd10,
        S_ENC_FSB_START = 5'd11,
        S_ENC_FSB_WAIT  = 5'd12,
        S_ENC_FSHIFT    = 5'd13,
        S_ENC_FARK      = 5'd14,
        S_DEC_SHIFT     = 5'd15,
        S_DEC_SB_START  = 5'd16,
        S_DEC_SB_WAIT   = 5'd17,
        S_DEC_ARK       = 5'd18,
        S_DEC_MIX       = 5'd19,
        S_DEC_FSHIFT    = 5'd20,
        S_DEC_FSB_START = 5'd21,
        S_DEC_FSB_WAIT  = 5'd22,
        S_DEC_FARK      = 5'd23,
        S_BLOCK_DONE    = 5'd24;

    reg [4:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            data_out <= 128'h0;
            block_done <= 1'b0;
            key_ready <= 1'b0;
            busy <= 1'b0;
            sbox_start <= 1'b0;
            sbox_inverse <= 1'b0;
            sbox_data_in <= 8'h00;
            mode_encrypt <= 1'b1;
            key_temp <= 32'h0;
            key_index <= 6'd8;
            key_sub_index <= 3'd0;
            byte_index <= 4'd0;
            column_index <= 2'd0;
            round_count <= 4'd0;
        end else begin
            block_done <= 1'b0;
            sbox_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (key_start) begin
                        busy <= 1'b1;
                        key_ready <= 1'b0;
                        for (i = 0; i < 8; i = i + 1) key_words[i] <= key_in[(7-i)*32 +: 32];
                        key_index <= 6'd8;
                        key_sub_index <= 3'd0;
                        state <= S_KEY_NEXT;
                    end else if (block_start && key_ready) begin
                        busy <= 1'b1;
                        mode_encrypt <= encrypt;
                        byte_index <= 4'd0;
                        for (i = 0; i < 16; i = i + 1) state_bytes[i] <= data_in[(15-i)*8 +: 8];
                        state <= S_INITIAL_ARK;
                    end
                end

                S_KEY_NEXT: begin
                    if ((key_index[2:0] == 3'd0) || (key_index[2:0] == 3'd4)) begin
                        key_sub_index <= 3'd0;
                        state <= S_KEY_SB_START;
                    end else begin
                        key_words[key_index] <= key_words[key_index-6'd8] ^ key_words[key_index-6'd1];
                        if (key_index == 6'd59) state <= S_KEY_DONE;
                        else key_index <= key_index + 6'd1;
                    end
                end

                S_KEY_SB_START: begin
                    sbox_inverse <= 1'b0;
                    sbox_data_in <= key_sub_byte(key_words[key_index-6'd1], key_sub_index, key_index[2:0] == 3'd0);
                    sbox_start <= 1'b1;
                    state <= S_KEY_SB_WAIT;
                end

                S_KEY_SB_WAIT: begin
                    if (sbox_done) begin
                        case (key_sub_index)
                            3'd0: key_temp[31:24] <= sbox_data_out ^ ((key_index[2:0] == 3'd0) ? rcon(key_index >> 3) : 8'h00);
                            3'd1: key_temp[23:16] <= sbox_data_out;
                            3'd2: key_temp[15:8] <= sbox_data_out;
                            default: begin
                                key_temp[7:0] <= sbox_data_out;
                                key_words[key_index] <= key_words[key_index-6'd8] ^ {key_temp[31:8], sbox_data_out};
                            end
                        endcase

                        if (key_sub_index == 3'd3) begin
                            key_index <= key_index + 6'd1;
                            state <= S_KEY_NEXT;
                        end else begin
                            key_sub_index <= key_sub_index + 3'd1;
                            state <= S_KEY_SB_START;
                        end
                    end
                end

                S_KEY_DONE: begin
                    key_ready <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                S_INITIAL_ARK: begin
                    state_bytes[byte_index] <= state_bytes[byte_index] ^ round_key_byte(mode_encrypt ? 4'd0 : 4'd14, byte_index);
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        if (mode_encrypt) begin
                            round_count <= 4'd1;
                            state <= S_ENC_SB_START;
                        end else begin
                            round_count <= 4'd13;
                            state <= S_DEC_SHIFT;
                        end
                    end else byte_index <= byte_index + 4'd1;
                end

                S_ENC_SB_START, S_ENC_FSB_START: begin
                    sbox_inverse <= 1'b0;
                    sbox_data_in <= state_bytes[byte_index];
                    sbox_start <= 1'b1;
                    state <= (state == S_ENC_SB_START) ? S_ENC_SB_WAIT : S_ENC_FSB_WAIT;
                end

                S_ENC_SB_WAIT, S_ENC_FSB_WAIT: begin
                    if (sbox_done) begin
                        state_bytes[byte_index] <= sbox_data_out;
                        if (byte_index == 4'd15) begin
                            byte_index <= 4'd0;
                            state <= (state == S_ENC_SB_WAIT) ? S_ENC_SHIFT : S_ENC_FSHIFT;
                        end else begin
                            byte_index <= byte_index + 4'd1;
                            state <= (state == S_ENC_SB_WAIT) ? S_ENC_SB_START : S_ENC_FSB_START;
                        end
                    end
                end

                S_ENC_SHIFT, S_ENC_FSHIFT: begin
                    state_bytes[0]<=state_bytes[0]; state_bytes[1]<=state_bytes[5]; state_bytes[2]<=state_bytes[10]; state_bytes[3]<=state_bytes[15];
                    state_bytes[4]<=state_bytes[4]; state_bytes[5]<=state_bytes[9]; state_bytes[6]<=state_bytes[14]; state_bytes[7]<=state_bytes[3];
                    state_bytes[8]<=state_bytes[8]; state_bytes[9]<=state_bytes[13]; state_bytes[10]<=state_bytes[2]; state_bytes[11]<=state_bytes[7];
                    state_bytes[12]<=state_bytes[12]; state_bytes[13]<=state_bytes[1]; state_bytes[14]<=state_bytes[6]; state_bytes[15]<=state_bytes[11];
                    byte_index<=4'd0;
                    if (state==S_ENC_SHIFT) begin
                        column_index<=2'd0;
                        state<=S_ENC_MIX;
                    end else state<=S_ENC_FARK;
                end

                S_DEC_SHIFT, S_DEC_FSHIFT: begin
                    state_bytes[0]<=state_bytes[0]; state_bytes[1]<=state_bytes[13]; state_bytes[2]<=state_bytes[10]; state_bytes[3]<=state_bytes[7];
                    state_bytes[4]<=state_bytes[4]; state_bytes[5]<=state_bytes[1]; state_bytes[6]<=state_bytes[14]; state_bytes[7]<=state_bytes[11];
                    state_bytes[8]<=state_bytes[8]; state_bytes[9]<=state_bytes[5]; state_bytes[10]<=state_bytes[2]; state_bytes[11]<=state_bytes[15];
                    state_bytes[12]<=state_bytes[12]; state_bytes[13]<=state_bytes[9]; state_bytes[14]<=state_bytes[6]; state_bytes[15]<=state_bytes[3];
                    byte_index<=4'd0;
                    state<=(state==S_DEC_SHIFT)?S_DEC_SB_START:S_DEC_FSB_START;
                end

                S_ENC_MIX, S_DEC_MIX: begin
                    state_bytes[column_base] <= mix_result[31:24];
                    state_bytes[column_base+6'd1] <= mix_result[23:16];
                    state_bytes[column_base+6'd2] <= mix_result[15:8];
                    state_bytes[column_base+6'd3] <= mix_result[7:0];

                    if (column_index == 2'd3) begin
                        column_index <= 2'd0;
                        byte_index <= 4'd0;
                        if (state == S_ENC_MIX) state <= S_ENC_ARK;
                        else if (round_count == 4'd1) state <= S_DEC_FSHIFT;
                        else begin
                            round_count <= round_count - 4'd1;
                            state <= S_DEC_SHIFT;
                        end
                    end else column_index <= column_index + 2'd1;
                end

                S_ENC_ARK: begin
                    state_bytes[byte_index] <= state_bytes[byte_index] ^ round_key_byte(round_count, byte_index);
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        if (round_count == 4'd13) state <= S_ENC_FSB_START;
                        else begin
                            round_count <= round_count + 4'd1;
                            state <= S_ENC_SB_START;
                        end
                    end else byte_index <= byte_index + 4'd1;
                end

                S_ENC_FARK: begin
                    state_bytes[byte_index] <= state_bytes[byte_index] ^ round_key_byte(4'd14, byte_index);
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        state <= S_BLOCK_DONE;
                    end else byte_index <= byte_index + 4'd1;
                end

                S_DEC_SB_START, S_DEC_FSB_START: begin
                    sbox_inverse <= 1'b1;
                    sbox_data_in <= state_bytes[byte_index];
                    sbox_start <= 1'b1;
                    state <= (state == S_DEC_SB_START) ? S_DEC_SB_WAIT : S_DEC_FSB_WAIT;
                end

                S_DEC_SB_WAIT, S_DEC_FSB_WAIT: begin
                    if (sbox_done) begin
                        state_bytes[byte_index] <= sbox_data_out;
                        if (byte_index == 4'd15) begin
                            byte_index <= 4'd0;
                            state <= (state == S_DEC_SB_WAIT) ? S_DEC_ARK : S_DEC_FARK;
                        end else begin
                            byte_index <= byte_index + 4'd1;
                            state <= (state == S_DEC_SB_WAIT) ? S_DEC_SB_START : S_DEC_FSB_START;
                        end
                    end
                end

                S_DEC_ARK: begin
                    state_bytes[byte_index] <= state_bytes[byte_index] ^ round_key_byte(round_count, byte_index);
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        column_index <= 2'd0;
                        state <= S_DEC_MIX;
                    end else byte_index <= byte_index + 4'd1;
                end

                S_DEC_FARK: begin
                    state_bytes[byte_index] <= state_bytes[byte_index] ^ round_key_byte(4'd0, byte_index);
                    if (byte_index == 4'd15) begin
                        byte_index <= 4'd0;
                        state <= S_BLOCK_DONE;
                    end else byte_index <= byte_index + 4'd1;
                end

                S_BLOCK_DONE: begin
                    for (i = 0; i < 16; i = i + 1) data_out[(15-i)*8 +: 8] <= state_bytes[i];
                    block_done <= 1'b1;
                    busy <= 1'b0;
                    state <= S_IDLE;
                end

                default: begin
                    busy <= 1'b0;
                    key_ready <= 1'b0;
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

module aes256_ecb_pkcs7 (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    input  wire         encrypt,
    input  wire [255:0] key_in,
    input  wire         in_valid,
    output wire         in_ready,
    input  wire [127:0] in_data,
    input  wire [15:0]  in_keep,
    input  wire         in_last,
    output reg          out_valid,
    input  wire         out_ready,
    output reg  [127:0] out_data,
    output reg  [15:0]  out_keep,
    output reg          out_last,
    output reg          busy,
    output reg          done,
    output reg          padding_error,
    output reg          input_error
);

    localparam [2:0] S_IDLE=3'd0, S_KEY_START=3'd1, S_KEY_WAIT=3'd2, S_INPUT=3'd3, S_BLOCK_START=3'd4, S_BLOCK_WAIT=3'd5, S_OUTPUT=3'd6;

    reg [2:0] state;
    reg [255:0] key_reg;
    reg mode_encrypt;
    reg [127:0] block_data;
    reg input_last;
    reg extra_padding;
    reg core_key_start;
    reg core_block_start;

    wire core_key_ready;
    wire core_block_done;
    wire core_busy;
    wire [127:0] core_data_out;

    function [4:0] keep_count(input [15:0] keep);
        integer i;
        reg zero_seen;
        begin
            keep_count = 5'd0;
            zero_seen = 1'b0;
            for (i = 15; i >= 0; i = i - 1) begin
                if (keep[i]) begin
                    if (zero_seen) keep_count = 5'd31;
                    else keep_count = keep_count + 5'd1;
                end else zero_seen = 1'b1;
            end
        end
    endfunction

    function [127:0] add_padding(input [127:0] data, input [4:0] count);
        integer i;
        reg [7:0] pad;
        begin
            pad = 8'd16 - count;
            add_padding = data;
            for (i = 0; i < 16; i = i + 1) if (i >= count) add_padding[127-i*8 -: 8] = pad;
        end
    endfunction

    function padding_valid(input [127:0] data);
        integer i;
        reg [7:0] pad;
        begin
            pad = data[7:0];
            padding_valid = (pad >= 8'd1) && (pad <= 8'd16);
            for (i = 0; i < 16; i = i + 1) if ((i < pad) && (data[i*8 +: 8] != pad)) padding_valid = 1'b0;
        end
    endfunction

    wire [4:0] byte_count = keep_count(in_keep);
    assign in_ready = state == S_INPUT;

    aes256_block u_block (
        .clk(clk),
        .rst_n(rst_n),
        .key_start(core_key_start),
        .key_in(key_reg),
        .key_ready(core_key_ready),
        .block_start(core_block_start),
        .encrypt(mode_encrypt),
        .data_in(block_data),
        .data_out(core_data_out),
        .block_done(core_block_done),
        .busy(core_busy)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            key_reg <= 256'h0;
            mode_encrypt <= 1'b1;
            block_data <= 128'h0;
            input_last <= 1'b0;
            extra_padding <= 1'b0;
            core_key_start <= 1'b0;
            core_block_start <= 1'b0;
            out_valid <= 1'b0;
            out_data <= 128'h0;
            out_keep <= 16'h0;
            out_last <= 1'b0;
            busy <= 1'b0;
            done <= 1'b0;
            padding_error <= 1'b0;
            input_error <= 1'b0;
        end else begin
            core_key_start <= 1'b0;
            core_block_start <= 1'b0;
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    out_valid <= 1'b0;
                    if (start) begin
                        key_reg <= key_in;
                        mode_encrypt <= encrypt;
                        extra_padding <= 1'b0;
                        padding_error <= 1'b0;
                        input_error <= 1'b0;
                        busy <= 1'b1;
                        state <= S_KEY_START;
                    end
                end

                S_KEY_START: begin
                    if (!core_busy) begin
                        core_key_start <= 1'b1;
                        state <= S_KEY_WAIT;
                    end
                end

                S_KEY_WAIT: if (core_key_ready) state <= S_INPUT;

                S_INPUT: begin
                    if (in_valid) begin
                        input_last <= in_last;
                        if (mode_encrypt) begin
                            if ((byte_count == 5'd31) || (!in_last && byte_count != 5'd16)) begin
                                input_error <= 1'b1;
                                busy <= 1'b0;
                                done <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                block_data <= in_last && byte_count != 5'd16 ? add_padding(in_data, byte_count) : in_data;
                                extra_padding <= in_last && byte_count == 5'd16;
                                state <= S_BLOCK_START;
                            end
                        end else if (byte_count != 5'd16) begin
                            input_error <= 1'b1;
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            block_data <= in_data;
                            extra_padding <= 1'b0;
                            state <= S_BLOCK_START;
                        end
                    end
                end

                S_BLOCK_START: begin
                    if (!core_busy && core_key_ready) begin
                        core_block_start <= 1'b1;
                        state <= S_BLOCK_WAIT;
                    end
                end

                S_BLOCK_WAIT: begin
                    if (core_block_done) begin
                        out_data <= core_data_out;
                        if (mode_encrypt) begin
                            out_keep <= 16'hffff;
                            out_last <= input_last && !extra_padding;
                            out_valid <= 1'b1;
                            state <= S_OUTPUT;
                        end else if (!input_last) begin
                            out_keep <= 16'hffff;
                            out_last <= 1'b0;
                            out_valid <= 1'b1;
                            state <= S_OUTPUT;
                        end else if (padding_valid(core_data_out)) begin
                            out_keep <= 16'hffff << core_data_out[7:0];
                            out_last <= 1'b1;
                            out_valid <= 1'b1;
                            state <= S_OUTPUT;
                        end else begin
                            padding_error <= 1'b1;
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end
                    end
                end

                S_OUTPUT: begin
                    if (out_valid && out_ready) begin
                        out_valid <= 1'b0;
                        if (mode_encrypt && extra_padding) begin
                            block_data <= {16{8'h10}};
                            input_last <= 1'b1;
                            extra_padding <= 1'b0;
                            state <= S_BLOCK_START;
                        end else if (out_last) begin
                            busy <= 1'b0;
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else state <= S_INPUT;
                    end
                end

                default: begin
                    state <= S_IDLE;
                    busy <= 1'b0;
                    out_valid <= 1'b0;
                    input_error <= 1'b1;
                end
            endcase
        end
    end

endmodule
