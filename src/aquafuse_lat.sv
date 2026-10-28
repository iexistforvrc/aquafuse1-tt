`timescale 1ns/1ps
// W transparent-high latches sharing one enable. q follows d while en is high
// and holds when it falls. The GF180 flow has no latch map for Yosys (it stops
// with "Unmapped Yosys instances"), so the cell is instantiated, as the clock
// gate is (aquafuse_icg). The behavioural branch is the same function.
module aquafuse_lat #(
    parameter int W = 1
) (
    input  logic         en,
    input  logic [W-1:0] d,
    output logic [W-1:0] q
);
`ifdef AQUAFUSE_GF180_ICG
    for (genvar i = 0; i < W; i++) begin : g_bit
        gf180mcu_fd_sc_mcu7t5v0__latq_1 u_l (.E(en), .D(d[i]), .Q(q[i]));
    end
`else
    always_latch if (en) q = d;
`endif
endmodule
