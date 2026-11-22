// SPDX-License-Identifier: GPL-3.0-only
`timescale 1ns/1ps
// Build with Verilator --binary --timing against the generated gateware/openaudio_soc.v.
// Run with +build=<eight hex digits from the B-only manifest>.
module tb_ss1;
    reg clk = 0, sck = 0, cs_n = 1, mosi = 0;
    wire miso;
    wire [3:0] reset_release;
    always #10 clk = ~clk;
    openaudio_soc dut (.clk_sys(clk), .spibone_clk(sck), .spibone_cs_n(cs_n),
        .spibone_mosi(mosi), .spibone_miso(miso), .wing_status(32'h1),
        .wing_reset_release(reset_release));

    task byte_io(input [7:0] data, output reg [7:0] got);
        integer bit_index;
        begin
            for (bit_index = 7; bit_index >= 0; bit_index = bit_index - 1) begin
                mosi = data[bit_index];
                #250; sck = 1; got[bit_index] = miso;
                #250; sck = 0;
            end
        end
    endtask

    task header(input [7:0] command, input [31:0] address);
        reg [7:0] ignored;
        begin
            cs_n = 0;
            byte_io(command, ignored);
            byte_io(address[31:24], ignored); byte_io(address[23:16], ignored);
            byte_io(address[15:8], ignored); byte_io(address[7:0], ignored);
        end
    endtask

    task response(input [7:0] expected);
        integer i;
        reg [7:0] got;
        begin
            got = 8'hff;
            for (i = 0; i < 16 && got == 8'hff; i = i + 1) byte_io(8'h00, got);
            if (got !== expected) $fatal(1, "SPIBone response: %h not %h", got, expected);
        end
    endtask

    task read_word(input [31:0] address, input [31:0] expected);
        reg [31:0] got;
        begin
            header(8'h01, address);
            response(8'h01);
            byte_io(0, got[31:24]); byte_io(0, got[23:16]);
            byte_io(0, got[15:8]); byte_io(0, got[7:0]);
            cs_n = 1; #500;
            if (got !== expected) $fatal(1, "CSR %h: %h not %h", address, got, expected);
        end
    endtask

    reg [7:0] ignored;
    reg [31:0] build_id;
    initial begin
        if (!$value$plusargs("build=%h", build_id)) $fatal(1, "Expected +build=<build ID>");
        #1000;
        if (reset_release !== 0) $fatal(1, "DSP reset release must power up low");
        read_word(32'h1800, 32'h57494e47);
        read_word(32'h1804, 32'h00020000);
        read_word(32'h1808, build_id);
        read_word(32'h180c, 32'h0000000f);
        read_word(32'h1810, 32'h00000001);
        header(8'h00, 32'h1814);
        byte_io(0, ignored); byte_io(0, ignored); byte_io(0, ignored); byte_io(8'h0f, ignored);
        response(8'h00);
        cs_n = 1; #500;
        if (reset_release !== 4'b1011) $fatal(1, "DSP3 reset must stay masked");
        $display("SS1: WING identity, READY and reset mask passed");
        $finish;
    end
endmodule
