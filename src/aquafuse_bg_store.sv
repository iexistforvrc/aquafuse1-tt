`timescale 1ns/1ps
// The part's background: an EMA of the STEM ACCUMULATOR, one entry per stem
// output position and lane (DR 0093).
//
// WHY THE ACCUMULATOR AND NOT THE FRAME. The model is trained on frame minus a
// causal EMA background. Holding that background at sensor resolution is 5,184
// bytes, which no die this project can buy holds. The stem is a bias-free
// linear map, so stem(frame - EMA(frame)) == stem(frame) - EMA(stem(frame)):
// the background can be kept AFTER the stem, at 7x13x4 = 364 entries. That is
// what this block stores, and why the part now computes its model instead of
// running the model's weights on the raw byte (DR 0091).
//
// ARITHMETIC, matched bit for bit by host/aquafuse/stream/chip_stream.py:
//     tgt = sat_W(acc >>> Q)                      floor, as a shifter does
//     cur = seeded ? mem[addr] : tgt              the first pass seeds
//     sub = cur <<< Q                             what the readout subtracts
//     mem[addr] <= sat_W(cur + ((3*(tgt - cur) + 8) >>> 4))
// alpha = 1 - 3/16 = 0.8125: a shift-add, where the 0.80 the model was first
// trained at would need a multiplier. The +8 rounds the update, which halves
// the dead zone in which a small change never moves the background.
//
// READ-BEFORE-WRITE in one cycle: the readout subtracts the background as it
// stood BEFORE this frame, and the same edge writes the updated one -- strictly
// causal, as the training data's EMA is (motion_pair_chip differences before
// it updates). Each entry is read exactly once per frame, by the stem flush.
//
// SEEDING. Until every entry has been written once, the background read is the
// entry's own target, so the first frame differences to (almost) zero exactly
// as the training data's frame 0 does.
module aquafuse_bg_store #(
    parameter int ENTRIES = 91,      // stem output positions, 7 x 13
    parameter int COUT    = 4,
    parameter int W       = 16,      // stored width, signed, saturating
    parameter int Q       = 4        // stored LSB = 2**Q accumulator units
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       rd_en,          // the stem flush cycle
    input  logic [$clog2(ENTRIES)-1:0] addr,
    input  logic [32*COUT-1:0]         acc_in,         // raw accumulators, lane 0 = MSB
    output logic [32*COUT-1:0]         sub_out         // background << Q, lane 0 = MSB
);
    localparam logic signed [W-1:0] W_MAX = {1'b0, {(W-1){1'b1}}};
    localparam logic signed [W-1:0] W_MIN = {1'b1, {(W-1){1'b0}}};

    function automatic logic signed [W-1:0] sat_w(input logic signed [31:0] v);
        if (v > $signed({{(32-W){1'b0}}, W_MAX}))      sat_w = W_MAX;
        else if (v < $signed({{(32-W){1'b1}}, W_MIN})) sat_w = W_MIN;
        else                                            sat_w = v[W-1:0];
    endfunction

    // FLAT, entry-major: entry e is mem[e*WD +: WD], one driver per entry from
    // the clock-gated block below. Flat because this yosys rejects a packed
    // net of more than one dimension, and an unpacked array cannot be driven
    // per element from separate gated processes.
    localparam int WD = W * COUT;
    wire  [ENTRIES*WD-1:0] mem;
    logic              seeded;

    // the read port: the entry at `addr`, through a balanced tree (aquafuse_sel;
    // a loop of `if (addr == i)` is a 91-deep priority chain, r5)
    logic [WD-1:0] rd_word;
    aquafuse_sel #(.N(ENTRIES), .W(WD)) u_rd (.words(mem), .sel(addr), .y(rd_word));

    logic signed [W-1:0]  cur [COUT-1:0];
    logic signed [W-1:0]  upd [COUT-1:0];
    logic [W*COUT-1:0]    upd_word;
    for (genvar l = 0; l < COUT; l++) begin : g_lane
        logic signed [31:0] acc;
        logic signed [W-1:0] tgt;
        logic signed [31:0] diff;
        assign acc  = $signed(acc_in[32*(COUT-1-l) +: 32]);
        assign tgt  = sat_w(acc >>> Q);
        assign cur[l] = seeded ? $signed(rd_word[W*(COUT-1-l) +: W]) : tgt;
        assign diff = 32'(3) * (32'($signed(tgt)) - 32'($signed(cur[l]))) + 32'sd8;
        assign upd[l] = sat_w(32'($signed(cur[l])) + (diff >>> 4));
        assign upd_word[W*(COUT-1-l) +: W] = upd[l];
        assign sub_out[32*(COUT-1-l) +: 32] = 32'($signed(cur[l])) <<< Q;
    end

    // TWO PROCESSES. The store has no reset -- the first pass seeds it -- and
    // writing it from the same process as an async-reset flag invites a
    // synthesiser to gate the write enable with the reset or to try resetting
    // 1,456 bits it does not need to.
    //
    // ONE CLOCK GATE PER ENTRY (aquafuse_icg). Written as `if (rd_en)
    // mem[addr] <= ...` every one of the ENTRIES*W*COUT bits held behind its own
    // multiplexer; this module was 153,441 um2, the largest in the part. Each
    // entry is written once per frame, so its flops need a clock on that one
    // cycle and on no other.
    logic [WD-1:0] upd_q;
    always_ff @(posedge clk) upd_q <= upd_word;
    for (genvar e = 0; e < ENTRIES; e++) begin : g_ent
        logic gclk;
        aquafuse_icg u_cg (
            .clk (clk),
            .en  (rd_en && addr == ($clog2(ENTRIES))'(e)),
            .gclk(gclk)
        );
        // GF180 AREA: a level-sensitive latch is ~30% smaller than a flop. It is
        // transparent while gclk is high, so it must be fed from a register, not
        // from upd_word: upd_word reads this very latch, which would be a loop.
        // upd_q takes upd_word at the edge that opens the latch, so the latch
        // ends the high phase holding exactly what the flop version captured.
        // Each entry is read once per frame and never on the cycle it opens.
        logic [WD-1:0] word;
        aquafuse_lat #(.W(WD)) u_lat (.en(gclk), .d(upd_q), .q(word));
        assign mem[e*WD +: WD] = word;
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            seeded <= 1'b0;
        else if (rd_en && addr == ($clog2(ENTRIES))'(ENTRIES - 1))
            seeded <= 1'b1;
    end
endmodule
