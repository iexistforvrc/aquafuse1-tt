`timescale 1ns/1ps
// One integrated clock gate: gclk follows clk on the cycles `en` is high.
//
// WHY. Every stored word in this part was a row of flops each holding behind
// its own 2:1 multiplexer (the write enable). Measured on stream12c at 12-bit
// EMA: 10,927 mux2 against 9,689 flops, about half the die, and the reason the
// 8x4 floorplan was 77% full. A gate per WORD replaces a multiplexer per BIT.
//
// WHY THE CELL AND NOT A LATCH-AND-AND. The September design gated a buffer
// with an inferred latch and an AND; that is not recognised as an integrated
// clock gate, CTS did not balance the gated branch, and paths crossing between
// branches lost hold (-0.099 ns at ff, config_pbwrb12_4x4_pblk2.json). The
// sky130 dlclkp cell carries the liberty clock-gating attribute, so STA checks
// its enable and CTS builds through it.
//
// The behavioural model below is the same function -- the enable is captured
// while clk is low, so a glitch on it can never chop a pulse -- and is what
// the verilator testbench runs. OpenLane defines AQUAFUSE_SKY130_ICG.
module aquafuse_icg (
    input  logic clk,
    input  logic en,
    output logic gclk
);
`ifdef AQUAFUSE_GF180_ICG
    gf180mcu_fd_sc_mcu7t5v0__icgtp_1 u_cg (
        .TE(1'b0), .E(en), .CLK(clk), .Q(gclk)
    );
`elsif AQUAFUSE_SKY130_ICG
    sky130_fd_sc_hd__dlclkp_1 u_cg (.CLK(clk), .GATE(en), .GCLK(gclk));
`else
    logic en_l;
    always_latch begin
        if (!clk) en_l = en;
    end
    assign gclk = clk & en_l;
`endif
endmodule
