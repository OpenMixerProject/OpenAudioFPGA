`timescale 1ns/1ps
module tb_identity;
    reg clk=0, sck=0, mosi=0, ss1=1, ss0=1;
    wire miso, oe;
    wire [6:0] held;
    reg [31:0] build_id;
    reg [7:0] rx [0:28];
    wing_fpga dut (.clk_audio(clk), .host_sck(sck), .host_mosi(mosi), .host_miso_in(1'b0),
        .ctrl_cs_n(ss1), .dsp_cs_n(ss0), .host_miso_out(miso), .host_miso_oe(oe),
        .phy_ab_reset_n(held[0]), .phy_b_txen(held[1]), .sync_b_a_de(held[2]), .sync_b_b_de(held[3]),
        .dsp1_reset_n(held[4]), .dsp2_reset_n(held[5]), .dsp4_reset_n(held[6]),
        .a9_no_drive(1'b0), .sync_b_a_observe(1'b0), .sync_b_b_observe(1'b0));
    always #10.172 clk=~clk;
    always @(negedge clk) if (held !== 7'b0) $fatal(1, "isolation outputs not all low");

    task transaction;
        input [7:0] command;
        input [31:0] address;
        input valid;
        input [31:0] expected;
        integer i, j, hit;
        reg [7:0] tx;
        begin
            ss1=0;
            #307;
            if (!oe) $fatal(1, "no MISO OE on SS1");
            for (i=0; i<29; i=i+1) begin
                if (!i) tx=command;
                else if (i<=4) tx=address >> (8*(4-i));
                else tx=8'hff;
                for (j=7; j>=0; j=j-1) begin
                    mosi=tx[j];
                    #250;
                    rx[i][j]=miso;
                    sck=1;
                    #250;
                    sck=0;
                end
            end
            ss1=1;
            #1;
            if (oe !== 0) $fatal(1, "MISO OE lingers after SS1");
            #399;
            hit=0;
            // Same framing rules as the driver's read: FF pad, 01 ACK, BE32.
            for (i=5; i<25 && hit==0; i=i+1) begin
                if (rx[i] !== 8'hff) begin
                    hit=1;
                    if (!valid || rx[i] !== 8'h01 || {rx[i+1],rx[i+2],rx[i+3],rx[i+4]} !== expected)
                        $fatal(1, "bad reply command=%h addr=%h rx=%h %h%h%h%h", command, address,
                            rx[i], rx[i+1],rx[i+2],rx[i+3],rx[i+4]);
                end
            end
            if (valid && !hit) $fatal(1, "missing reply at %h", address);
        end
    endtask

    initial begin
        if (!$value$plusargs("build=%h", build_id)) $fatal(1, "expected +build=<hex>");
        ss1=0;
        #1;
        if (oe !== 0) $fatal(1, "MISO OE during startup inhibit");
        ss1=1;
        #500;
        if (oe !== 0) $fatal(1, "MISO OE while idle");
        ss0=0;
        #1;
        if (oe !== 0) $fatal(1, "MISO OE on SS0");
        ss1=0;
        #1;
        if (oe !== 0) $fatal(1, "MISO OE with both selects asserted");
        ss1=1; ss0=1;
        #500;
        transaction(1, 32'h1800, 1, 32'h57494e47);
        transaction(1, 32'h1804, 1, 32'h00020000);
        transaction(1, 32'h1808, 1, build_id);
        transaction(1, 32'h180c, 1, 0);
        transaction(1, 32'h1810, 1, 1);
        transaction(0, 32'h1808, 0, 0);
        transaction(2, 32'h1808, 0, 0);
        transaction(3, 32'h1808, 0, 0);
        transaction(1, 32'h1814, 0, 0);
        transaction(1, 32'h1801, 0, 0);
        transaction(1, 32'h80001808, 0, 0);
        transaction(1, 32'h1808, 1, build_id);
        $display("PASS: SS1 five registers; MISO OE; held outputs; absent, alias, unaligned, write and burst rejection");
        $finish;
    end
endmodule
