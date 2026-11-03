// tb_arb2.v — 双主机仲裁器仿真
`timescale 1ns / 1ps

module tb_arb2;

reg ACLK = 0, ARESETN = 0;
always #5 ACLK = ~ACLK;

reg  [31:0] m0_awaddr = 0; reg m0_awvalid = 0; wire m0_awready;
reg  [31:0] m0_wdata = 0;  reg [3:0] m0_wstrb = 4'hF; reg m0_wvalid = 0; wire m0_wready;
wire [1:0]  m0_bresp; wire m0_bvalid; reg m0_bready = 1;
reg  [31:0] m0_araddr = 0; reg [7:0] m0_arlen = 0; reg m0_arvalid = 0; wire m0_arready;
wire [31:0] m0_rdata; wire [1:0] m0_rresp; wire m0_rlast; wire m0_rvalid; reg m0_rready = 1;

reg  [31:0] m1_awaddr = 0; reg m1_awvalid = 0; wire m1_awready;
reg  [31:0] m1_wdata = 0;  reg [3:0] m1_wstrb = 4'hF; reg m1_wvalid = 0; wire m1_wready;
wire [1:0]  m1_bresp; wire m1_bvalid; reg m1_bready = 1;
reg  [31:0] m1_araddr = 0; reg [7:0] m1_arlen = 0; reg m1_arvalid = 0; wire m1_arready;
wire [31:0] m1_rdata; wire [1:0] m1_rresp; wire m1_rlast; wire m1_rvalid; reg m1_rready = 1;

wire [31:0] o_awaddr; wire o_awvalid; reg o_awready = 0;
wire [31:0] o_wdata; wire [3:0] o_wstrb; wire o_wvalid; reg o_wready = 0;
reg  [1:0]  o_bresp = 0; reg o_bvalid = 0; wire o_bready;
wire [31:0] o_araddr; wire [7:0] o_arlen; wire o_arvalid; reg o_arready = 0;
reg  [31:0] o_rdata = 0; reg [1:0] o_rresp = 0; reg o_rlast = 0; reg o_rvalid = 0; wire o_rready;

axi_lite_arb2 u_arb (
    .ACLK(ACLK), .ARESETN(ARESETN),
    .M0_AWADDR(m0_awaddr), .M0_AWVALID(m0_awvalid), .M0_AWREADY(m0_awready),
    .M0_WDATA(m0_wdata), .M0_WSTRB(m0_wstrb), .M0_WVALID(m0_wvalid), .M0_WREADY(m0_wready),
    .M0_BRESP(m0_bresp), .M0_BVALID(m0_bvalid), .M0_BREADY(m0_bready),
    .M0_ARADDR(m0_araddr), .M0_ARLEN(m0_arlen), .M0_ARVALID(m0_arvalid), .M0_ARREADY(m0_arready),
    .M0_RDATA(m0_rdata), .M0_RRESP(m0_rresp), .M0_RLAST(m0_rlast), .M0_RVALID(m0_rvalid), .M0_RREADY(m0_rready),
    .M1_AWADDR(m1_awaddr), .M1_AWVALID(m1_awvalid), .M1_AWREADY(m1_awready),
    .M1_WDATA(m1_wdata), .M1_WSTRB(m1_wstrb), .M1_WVALID(m1_wvalid), .M1_WREADY(m1_wready),
    .M1_BRESP(m1_bresp), .M1_BVALID(m1_bvalid), .M1_BREADY(m1_bready),
    .M1_ARADDR(m1_araddr), .M1_ARLEN(m1_arlen), .M1_ARVALID(m1_arvalid), .M1_ARREADY(m1_arready),
    .M1_RDATA(m1_rdata), .M1_RRESP(m1_rresp), .M1_RLAST(m1_rlast), .M1_RVALID(m1_rvalid), .M1_RREADY(m1_rready),
    .O_AWADDR(o_awaddr), .O_AWVALID(o_awvalid), .O_AWREADY(o_awready),
    .O_WDATA(o_wdata), .O_WSTRB(o_wstrb), .O_WVALID(o_wvalid), .O_WREADY(o_wready),
    .O_BRESP(o_bresp), .O_BVALID(o_bvalid), .O_BREADY(o_bready),
    .O_ARADDR(o_araddr), .O_ARLEN(o_arlen), .O_ARVALID(o_arvalid), .O_ARREADY(o_arready),
    .O_RDATA(o_rdata), .O_RRESP(o_rresp), .O_RLAST(o_rlast), .O_RVALID(o_rvalid), .O_RREADY(o_rready)
);

integer errors = 0;
reg [31:0] got;

reg [31:0] mem [0:255];

// 简化从机: 写 AW 即完成; 读支持突发
always @(posedge ACLK) begin
    if (!ARESETN) begin
        o_awready <= 0; o_wready <= 0; o_bvalid <= 0;
        o_arready <= 0; o_rvalid <= 0; o_rlast <= 0;
    end else begin
        o_awready <= o_awvalid && !o_awready;
        o_wready  <= o_wvalid && !o_wready;
        if (o_awvalid && o_awready) begin
            o_bvalid <= 1'b1;
            mem[o_awaddr[9:2]] <= o_wdata;
        end else if (o_bvalid && o_bready) o_bvalid <= 1'b0;

        o_arready <= o_arvalid && !o_arvalid;
        if (o_arvalid && o_arready) begin
            o_rvalid <= 1'b1;
            o_rdata  <= mem[o_araddr[9:2]] + 32'h1000;
            o_rlast  <= (o_arlen == 0);
        end else if (o_rvalid && o_rready) begin
            if (o_rlast) o_rvalid <= 1'b0;
            else begin
                o_rdata <= o_rdata + 32'd1;
            end
        end
    end
end

task m0_write(input [31:0] a, input [31:0] d);
begin
    @(posedge ACLK);
    m0_awaddr <= a; m0_awvalid <= 1; m0_wdata <= d; m0_wvalid <= 1;
    while (!(m0_awready && m0_wready)) @(posedge ACLK);
    @(posedge ACLK);
    m0_awvalid <= 0; m0_wvalid <= 0;
    while (!m0_bvalid) @(posedge ACLK);
    @(posedge ACLK);
end
endtask

task m1_write(input [31:0] a, input [31:0] d);
begin
    @(posedge ACLK);
    m1_awaddr <= a; m1_awvalid <= 1; m1_wdata <= d; m1_wvalid <= 1;
    while (!(m1_awready && m1_wready)) @(posedge ACLK);
    @(posedge ACLK);
    m1_awvalid <= 0; m1_wvalid <= 0;
    while (!m1_bvalid) @(posedge ACLK);
    @(posedge ACLK);
end
endtask

task m0_read(input [31:0] a);
begin
    @(posedge ACLK);
    m0_araddr <= a; m0_arlen <= 0; m0_arvalid <= 1;
    while (!m0_arready) @(posedge ACLK);
    @(posedge ACLK);
    m0_arvalid <= 0;
    while (!m0_rvalid) @(posedge ACLK);
    got = m0_rdata;
    while (!m0_rlast) @(posedge ACLK);
    @(posedge ACLK);
end
endtask

task m1_burst_read(input [31:0] a, input [7:0] len);
begin
    @(posedge ACLK);
    m1_araddr <= a; m1_arlen <= len; m1_arvalid <= 1;
    while (!m1_arready) @(posedge ACLK);
    @(posedge ACLK);
    m1_arvalid <= 0;
    while (!m1_rvalid) @(posedge ACLK);
    got = m1_rdata;
    while (!m1_rlast) @(posedge ACLK);
    @(posedge ACLK);
end
endtask

integer i;
initial begin
    repeat (5) @(posedge ACLK);
    ARESETN = 1;
    repeat (3) @(posedge ACLK);

    m0_write(32'h10, 32'hAABBCCDD);
    m0_read(32'h10);
    if (got !== 32'hAABBCCDD + 32'h1000) begin
        errors = errors + 1; $display("[FAIL] S1 m0 rd %h", got);
    end else $display("[OK]   S1: M0 写入读回一致");

    m1_write(32'h20, 32'h11112222);
    m1_burst_read(32'h20, 8'd0);
    if (got !== 32'h11112222 + 32'h1000) begin
        errors = errors + 1; $display("[FAIL] S2 m1 rd %h", got);
    end else $display("[OK]   S2: M1 单拍读正确");

    // 并发: 两主机同时发起写
    fork
        m0_write(32'h30, 32'hDEAD0000);
        m1_write(32'h40, 32'hBEEF0000);
    join
    m0_read(32'h30);
    if (got !== 32'hDEAD0000 + 32'h1000) begin errors = errors + 1; $display("[FAIL] S3a %h", got); end
    m0_read(32'h40);
    if (got !== 32'hBEEF0000 + 32'h1000) begin errors = errors + 1; $display("[FAIL] S3b %h", got); end
    $display("[OK]   S3: 并发写两笔均落地");

    for (i = 0; i < 100; i = i + 1) begin
        if (i % 2) m1_write(32'h100 + (i << 2), 32'hCAFE0000 + i);
        else       m0_write(32'h100 + (i << 2), 32'hCAFE0000 + i);
    end
    for (i = 0; i < 10; i = i + 1) begin
        m0_read(32'h100 + (i << 2));
        if (got !== 32'hCAFE0000 + i + 32'h1000) begin
            errors = errors + 1; $display("[FAIL] S4 i=%0d got=%h", i, got);
        end
    end
    $display("[OK]   S4: 交替 100 笔写 + 校验 10 笔");

    if (errors == 0) $display(">>> ARB2_SIM_PASS");
    else $display(">>> ARB2_SIM_FAIL errors=%0d", errors);
    $finish;
end

endmodule
