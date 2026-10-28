`timescale 1ns/1ps
// The part's background at BLOCK resolution: one EMA entry per b x b block of
// stem cells and lane, instead of one per cell (DR 0093). The area option.
//
// WHY. The full-resolution store is 364 entries and fits only the 8x4 die,
// $559 over the ceiling. At b = 2 it is 112 entries, at b = 4 it is 32. The
// model is trained on exactly this operator (TinyDetectorCompact.stem_map with
// bg_block = b), so the part still computes its model -- a coarser one.
//
// ARITHMETIC, matched by host/aquafuse/stream/chip_stream.py (_block_mean):
//     sum  = sum of the block's accumulators this frame
//     mean = sum >>> DIV_SH        b == 2: the block's own count (4, 2 or 1)
//                                  b >= 3: b*b for every block, zero-padded
//     tgt  = sat_W(mean >>> Q)
//     every cell subtracts  cur << Q,  cur = seeded ? mem[block] : tgt_seed
//     at the block's LAST cell:  mem[block] <= sat_W(cur + ((3*(tgt-cur)+8) >>> 4))
//
// TIMING. Cells arrive row-major, one per flush cycle. A block's sum is built
// in `psum`, one register set per block COLUMN of the current block row, and is
// complete at the block's last cell, which is also the last cell to subtract
// the old background -- so the update lands after every cell of the block has
// used the value from before this frame, as the training data's EMA does.
//
// SEEDING. The first frame cannot seed from tgt before the block is complete,
// so for frame 0 every cell subtracts its OWN accumulator: the difference is
// zero, which is what the training data's frame 0 is (background = frame 0).
// The block entry is then written with tgt at its last cell.
module aquafuse_bg_block #(
    parameter int S_OH  = 7,
    parameter int S_OW  = 13,
    parameter int B     = 2,
    parameter int COUT  = 4,
    parameter int W     = 16,
    parameter int Q     = 4
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         rd_en,      // the stem flush cycle
    input  logic [$clog2(S_OH)-1:0]      row,
    input  logic [$clog2(S_OW)-1:0]      col,
    input  logic [32*COUT-1:0]           acc_in,     // lane 0 = MSB
    output logic [32*COUT-1:0]           sub_out     // background << Q, lane 0 = MSB
);
    localparam int BH = (S_OH + B - 1) / B;
    localparam int BW = (S_OW + B - 1) / B;
    localparam int NB = BH * BW;
    localparam logic signed [W-1:0] W_MAX = {1'b0, {(W-1){1'b1}}};
    localparam logic signed [W-1:0] W_MIN = {1'b1, {(W-1){1'b0}}};

    function automatic logic signed [W-1:0] sat_w(input logic signed [31:0] v);
        if (v > $signed({{(32-W){1'b0}}, W_MAX}))      sat_w = W_MAX;
        else if (v < $signed({{(32-W){1'b1}}, W_MIN})) sat_w = W_MIN;
        else                                            sat_w = v[W-1:0];
    endfunction

    // which block, and is this its first / last cell
    wire [$clog2(BH+1)-1:0] br = ($clog2(BH+1))'(row / B);
    wire [$clog2(BW+1)-1:0] bc = ($clog2(BW+1))'(col / B);
    wire [$clog2(NB)-1:0]   bidx = ($clog2(NB))'(br) * ($clog2(NB))'(BW)
                                 + ($clog2(NB))'(bc);
    wire first_cell = (row % B == 0) && (col % B == 0);
    wire last_row   = (row % B == B - 1) || (row == S_OH - 1);
    wire last_col   = (col % B == B - 1) || (col == S_OW - 1);
    wire last_cell  = last_row && last_col;
    // the block's divisor as a shift: its own (power-of-two) count at b == 2,
    // b*b otherwise -- see the header
    wire [2:0] rows_in = (B == 2) ? (((br + 1) * B > S_OH) ? 3'd1 : 3'd2) : 3'($clog2(B));
    wire [2:0] cols_in = (B == 2) ? (((bc + 1) * B > S_OW) ? 3'd1 : 3'd2) : 3'($clog2(B));
    wire [4:0] div_sh  = (B == 2) ? (5'(rows_in) - 5'd1) + (5'(cols_in) - 5'd1)
                                  : 5'(2 * $clog2(B));

    logic [W*COUT-1:0]   mem  [NB-1:0];
    logic [32*COUT-1:0]  psum [BW-1:0];
    logic                seeded;

    logic [W*COUT-1:0]   upd_word;
    logic [32*COUT-1:0]  psum_next;
    for (genvar l = 0; l < COUT; l++) begin : g_lane
        logic signed [31:0] acc, sum, mean, diff;
        logic signed [W-1:0] tgt, cur, upd;
        assign acc  = $signed(acc_in[32*(COUT-1-l) +: 32]);
        assign sum  = (first_cell ? 32'sd0 : $signed(psum[bc][32*(COUT-1-l) +: 32])) + acc;
        assign psum_next[32*(COUT-1-l) +: 32] = sum;
        assign mean = sum >>> div_sh;
        assign tgt  = sat_w(mean >>> Q);
        assign cur  = seeded ? $signed(mem[bidx][W*(COUT-1-l) +: W]) : tgt;
        assign diff = 32'(3) * (32'($signed(tgt)) - 32'($signed(cur))) + 32'sd8;
        assign upd  = sat_w(32'($signed(cur)) + (diff >>> 4));
        assign upd_word[W*(COUT-1-l) +: W] = upd;
        // frame 0 subtracts the cell's own accumulator: difference zero
        assign sub_out[32*(COUT-1-l) +: 32] =
            seeded ? (32'($signed(mem[bidx][W*(COUT-1-l) +: W])) <<< Q) : acc;
    end

    always_ff @(posedge clk) begin
        if (rd_en) begin
            psum[bc] <= psum_next;
            if (last_cell) mem[bidx] <= upd_word;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            seeded <= 1'b0;
        else if (rd_en && row == S_OH - 1 && col == S_OW - 1)
            seeded <= 1'b1;
    end
endmodule
