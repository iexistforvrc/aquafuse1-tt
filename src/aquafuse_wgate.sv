`timescale 1ns/1ps
// Write-pulse generator for a word store with NS slots x NC columns: one gated clock per word.
//
// WHY NOT ONE aquafuse_icg PER WORD. An integrated clock gate burns clock-pin energy on every
// cycle whether or not it fires: 242 of them cost ~0.75 mW of GF180 power at 3.3 V, a quarter
// of the whole chip once everything else is gated. This module is the same function with the
// expensive part shared: ONE enable/index latch pair per ARRAY (transparent while clk is low,
// exactly what an ICG's internal latch does), then per word only an AND of clk with the
// decoded, latched index. The AND toggles only on the one word written; the latched index
// cannot change while clk is high, so the gated clock is glitch-free.
//
// gclk[s*NC + c] pulses high during the clk-high phase after a cycle in which en was high and
// (slot, col) == (s, c) -- the same cycle and phase aquafuse_icg gave.
module aquafuse_wgate #(
    parameter int NS = 1,
    parameter int NC = 4,
    parameter int SW = (NS <= 1) ? 1 : $clog2(NS),
    parameter int CW = (NC <= 1) ? 1 : $clog2(NC)
) (
    input  logic                clk,
    input  logic                en,
    input  logic [SW-1:0]       slot,
    input  logic [CW-1:0]       col,
    output logic [NS*NC-1:0]    gclk
);
    wire clk_n = ~clk;
    wire        en_l;
    wire [SW-1:0] slot_l;
    wire [CW-1:0] col_l;
    aquafuse_lat #(.W(1 + SW + CW)) u_idx (.en(clk_n), .d({en, slot, col}), .q({en_l, slot_l, col_l}));

    for (genvar s = 0; s < NS; s++) begin : g_s
        wire sel_s = (slot_l == SW'(s));
        for (genvar c = 0; c < NC; c++) begin : g_c
            assign gclk[s*NC + c] = clk & en_l & sel_s & (col_l == CW'(c));
        end
    end
endmodule
