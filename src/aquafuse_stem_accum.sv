`timescale 1ns/1ps
// Stem accumulator: a 4x4 stride-4 convolution computed as pixels arrive.
//
// WHY IT EXISTS. A 4x4 window spans four input rows, so the obvious streaming
// implementation buffers three input rows -- 96 x IN_CH bytes each, 864 B at
// IN_CH=3 -- which alone exceeds the whole line-buffer budget. Instead each
// pixel's contribution is accumulated into the output position it belongs to
// the moment it arrives, and only the OUTPUT row of partial sums is held:
// OUT_W x COUT accumulators, 300 B at 25x4x24-bit. Nothing upstream is stored.
//
// This works because stride == kernel: with padding = kernel/2 = 2 every input
// row and column maps to EXACTLY ONE output row and column, so no accumulator
// is ever needed for two windows at once. Mapping, for stride 4, pad 2:
//     or = (r + 2) >> 2      kr = r - 4*or + 2
//     oc = (c + 2) >> 2      kc = c - 4*oc + 2
// Rows 0..1 land in output row 0 (the first window is truncated by padding),
// rows 2..5 in output row 1, and so on. Verified against PresenceNet geometry:
// 54x96 in -> 14x25 out for gq54.
//
// IN_CH is a parameter and the module is correct for 1, 2 or 3 channels. That
// is deliberate: whether the chip can compute its own temporal channels is an
// open architecture question, and this block must not prejudge it.
//
// One input channel is consumed per cycle, COUT multipliers wide, so a pixel
// costs IN_CH cycles. At 54x96x3 that is 15,552 cycles per frame against
// 1.75M available at 26.3 MHz and 15 fps -- the stem is nowhere near the
// binding constraint.
//
// PRE-FREEZE, NON-MANUFACTURING. Not D3/D4/D5 exit evidence; decision 0009.
module aquafuse_stem_accum #(
    parameter int OUT_W  = 25,   // output columns
    parameter int COUT   = 4,    // stem output channels
    parameter int ACC_W  = 24
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // one (position, channel) product set per cycle
    input  logic                        mac_en,
    input  logic [$clog2(OUT_W)-1:0]    mac_col,     // target output column
    input  logic signed [7:0]           mac_act,     // activation byte
    input  logic signed [8*COUT-1:0]    mac_wgt,     // COUT weights, lane 0 = MSB

    // TWO clears, and the distinction is the whole of RTL-8.
    //   bank_clear -- wipe every column. Frame start only.
    //   col_clear  -- wipe ONE column, the one being read this cycle.
    // A single bank-wide clear at the end of the row flush was the defect: the
    // sensor keeps streaming throughout the 13-cycle flush, so pixels of the
    // NEXT stem row are MACed in and then wiped. Clearing each column as it is
    // read cannot lose them, because a pixel's column is always read before
    // that pixel can arrive -- pixel c of the next row lands at core clock
    // ~4*(c+1) after the flush starts while its column is read at flush cycle
    // (c+PAD)/STRIDE, which is smaller for every c at any pixel rate down to
    // one pixel per clock.
    input  logic                        bank_clear,
    input  logic                        col_clear,
    input  logic [$clog2(OUT_W)-1:0]    clear_col,

    // requantised readout of one column
    input  logic [$clog2(OUT_W)-1:0]    rd_col,
    // One shift per output channel, lane 0 = MSB -- see aquafuse_conv_stage
    // for why per-channel and why it costs no multiplexer.
    input  logic [5*COUT-1:0]           rd_shift,
    input  logic                        rd_relu,
    // STREAM12C (DR 0093). The background the part subtracts, and the folded
    // batch-norm bias it adds, both in ACCUMULATOR units and both applied
    // before the requantisation -- d = acc - background + bias -- because the
    // model was trained on stem(frame - EMA(frame)) + bias, and by linearity
    // that is exactly stem(frame) - EMA(stem(frame)) + bias. Lane 0 = MSB.
    input  logic [32*COUT-1:0]          rd_sub,
    input  logic [32*COUT-1:0]          rd_bias,
    // the raw accumulator of the column being read, for the EMA update
    output logic [32*COUT-1:0]          rd_acc,
    output logic [8*COUT-1:0]           rd_byte      // lane 0 = MSB
);

`include "aquafuse_round.svh"

    // flat view for the one-hot read ports (aquafuse_sel), GF180 area
    wire [OUT_W*COUT*ACC_W-1:0] acc_flat;
    wire [COUT*ACC_W-1:0] rd_mac_word, rd_out_word;
    aquafuse_sel #(.N(OUT_W), .W(COUT*ACC_W)) u_rd_mac (.words(acc_flat), .sel(mac_col), .y(rd_mac_word));
    aquafuse_sel #(.N(OUT_W), .W(COUT*ACC_W)) u_rd_out (.words(acc_flat), .sel(rd_col),  .y(rd_out_word));

    // A SIGNED zero, and it has to be spelled out. `{ACC_W{1'b0}}` and a bare
    // `'0` are UNSIGNED, and a ternary with one unsigned operand makes the
    // whole expression unsigned -- which silently reinterprets a negative
    // accumulator as a large positive one. Written the unsigned way this module
    // saturated every channel of stem row 0 to 0x7f. Measured, twice.
    localparam logic signed [ACC_W-1:0] ACC_ZERO = '0;

    // ONE ADDER SET, shared, with the column select in the ENABLE rather than
    // in the data path. This is the third formulation of this block and the
    // first that is both correct and affordable; the other two are recorded
    // because each failed in a different way and neither failure was visible
    // from the source.
    //
    //   1. Two variable-indexed non-blocking writes to the same unpacked array
    //      in one always block -- `if (col_clear) acc[clear_col][l] <= 0;` then
    //      `if (mac_en) acc[mac_col][l] <= ...`. iverilog accepts it, warns
    //      about nothing, and simulates something else: written that way this
    //      module saturated every channel of stem row 0, a row in which no
    //      clear can fire.
    //   2. A loop over all OUT_W columns with the wipe and the product folded
    //      into each column's data path. Simulates correctly and costs +5,882
    //      CELLS -- measured, 37,180 -> 43,062 with no extra flops -- because
    //      an adder per accumulator is 52 adders where the design needs COUT.
    //      That is what pushed the die past GRT-0118.
    //
    // So: read the target column through a mux, add ONCE, and write back
    // through a decoded enable. Per column there is then only a comparator and
    // a clear, which is what the original `acc[mac_col][l] <= acc[mac_col][l] +
    // product` synthesised to before RTL-8 was fixed.
    //
    // A MAC and this column's clear can fall on the same cycle. The MAC WINS,
    // starting a fresh sum from zero: the readout is combinational off the
    // pre-clear value so the row being flushed is unaffected, and the arriving
    // pixel belongs to the NEXT row and is the only copy of itself. Priority
    // the other way -- clear beats MAC, which is what `else if` gives -- is
    // exactly how RTL-8 discarded pixels.
    wire clear_this = col_clear && (clear_col == mac_col);

    logic signed [ACC_W-1:0] acc_rd   [COUT-1:0];
    logic signed [ACC_W-1:0] acc_next [COUT-1:0];
    for (genvar l = 0; l < COUT; l++) begin : g_acc
        assign acc_rd[l] = $signed(rd_mac_word[l*ACC_W +: ACC_W]);
        assign acc_next[l] = (clear_this ? ACC_ZERO : acc_rd[l])
            + ACC_W'($signed(mac_act) * $signed(mac_wgt[8*(COUT-1-l) +: 8]));
    end

    // ONE CLOCK GATE PER COLUMN (GF180 area; was a 3-way enable on every bit).
    // The column is clocked when anything writes it, and then takes acc_next if the
    // MAC hits it (and no bank_clear), else zero -- the same priority as before:
    // bank_clear, then MAC, then column clear.
    for (genvar p = 0; p < OUT_W; p++) begin : g_col
        wire sel_mac = mac_en && (mac_col == ($clog2(OUT_W))'(p));
        wire en_p    = bank_clear || sel_mac || (col_clear && (clear_col == ($clog2(OUT_W))'(p)));
        wire gclk;
        aquafuse_icg u_cg (.clk(clk), .en(en_p), .gclk(gclk));
        for (genvar l = 0; l < COUT; l++) begin : g_lane
            logic signed [ACC_W-1:0] r;
            always_ff @(posedge gclk or negedge rst_n) begin
                if (!rst_n)                     r <= ACC_ZERO;
                else if (bank_clear || !sel_mac) r <= ACC_ZERO;
                else                            r <= acc_next[l];
            end
            assign acc_flat[(p*COUT + l)*ACC_W +: ACC_W] = r;
        end
    end

    // Readout is split so the column select is a CONTINUOUS assign and the
    // requantisation is a per-lane assign. Doing the variable index inside an
    // always_comb makes iverilog fall back to "sensitive to all bits", which
    // it warns about and which is a needless simulation hazard in the one
    // block whose arithmetic must match the golden model exactly.
    logic signed [ACC_W-1:0] acc_sel [COUT-1:0];
    logic signed [31:0]      acc_x   [COUT-1:0];
    logic signed [31:0]      d_x     [COUT-1:0];
    for (genvar l = 0; l < COUT; l++) begin : g_sel
        assign acc_sel[l] = $signed(rd_out_word[l*ACC_W +: ACC_W]);
        assign acc_x[l]   = {{(32-ACC_W){acc_sel[l][ACC_W-1]}}, acc_sel[l]};
        assign rd_acc[32*(COUT-1-l) +: 32] = acc_x[l];
        // 32 bits throughout: |acc| < 2**20 and the background and bias are of
        // the same order, so the sum cannot reach the sign bit.
        assign d_x[l] = acc_x[l] - $signed(rd_sub[32*(COUT-1-l) +: 32])
                                 + $signed(rd_bias[32*(COUT-1-l) +: 32]);
        assign rd_byte[8*(COUT-1-l) +: 8] =
            round_sat_relu(d_x[l], rd_shift[5*(COUT-1-l) +: 5], rd_relu);
    end

endmodule
