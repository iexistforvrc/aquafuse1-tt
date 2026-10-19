`timescale 1ns/1ps
// Read port of a flat word store: y = words[sel], as a BALANCED binary tree.
//
// WHY A MODULE. The clock-gated stores are flat vectors (aquafuse_bg_store),
// and their first read port was a loop -- `if (sel == i) y = words[i]` -- which
// yosys builds as a PRIORITY chain: 91 multiplexers deep for the background
// store. At the slow corner that one structure put the part 9.8 ns over its
// 38 ns clock (stream12c_8x4_r5, max_ss_100C_1v60: 5,235 failing endpoints, all
// downstream of a store read). A tree has the same multiplexer count and
// $clog2(N) levels.
//
// The tree is a heap in one flat vector: node n (1 .. NP-1) selects between
// children 2n and 2n+1 on address bit AW-1-floor(log2 n); leaf NP+i is word i,
// zero past N. Flat because this yosys rejects multi-dimensional packed nets.
module aquafuse_sel #(
    parameter int N = 4,      // words
    parameter int W = 8       // bits per word
) (
    input  logic [N*W-1:0]          words,   // word i at words[i*W +: W]
    input  logic [$clog2(N)-1:0]    sel,
    output logic [W-1:0]            y
);
    localparam int AW = (N <= 1) ? 1 : $clog2(N);
    localparam int NP = 1 << AW;

    wire [2*NP*W-1:0] tree;
    assign tree[W-1:0] = '0;                       // node 0 is unused
    for (genvar i = 0; i < NP; i++) begin : g_leaf
        if (i < N) begin : g_w
            assign tree[(NP+i)*W +: W] = words[i*W +: W];
        end else begin : g_z
            assign tree[(NP+i)*W +: W] = '0;
        end
    end
    for (genvar n = 1; n < NP; n++) begin : g_node
        localparam int D = $clog2(n + 1) - 1;      // depth = floor(log2 n)
        assign tree[n*W +: W] = sel[AW-1-D] ? tree[(2*n+1)*W +: W]
                                            : tree[(2*n)*W +: W];
    end
    assign y = tree[W +: W];
endmodule
