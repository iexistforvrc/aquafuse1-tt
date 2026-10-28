`timescale 1ns/1ps
// The part's background as a SHIFT REGISTER rather than an addressed memory
// (DR 0093). Same arithmetic as aquafuse_bg_store.
//
// WHY. Synthesised, stream12c with the addressed store came to 475,517 um2 --
// 90% of the 6x4 die. The stem flush visits the 91 positions in the SAME order
// every frame, so no address is ever needed: the entry being read is always
// the head, and its update always goes to the tail. No decoder, no read mux.
//
// WHAT IT SAVED, MEASURED: 462,287 um2 against 475,517 -- 2.8%, not the halving
// estimated before synthesis.
//
// AND WHY IT IS NOT USED. It could not be placed: hardening run r2 drew more
// than 12,000 hold-fix buffers after clock-tree synthesis -- q[i] <= q[i+1] is
// ~5,400 flop-to-flop paths with no logic between them -- and detailed
// placement failed (DPL-0036). The top selects aquafuse_bg_store (BG_FIFO = 0).
// Kept so the measurement and the failure stay reproducible.
//
// ARITHMETIC: identical to aquafuse_bg_store, entry by entry, so the oracle
// (host/aquafuse/stream/chip_stream.py) and the testbench are unchanged.
//
// ALIGNMENT, the one thing an addressed store gets for free. If a frame is cut
// short -- a dropped sensor frame, an overrun -- fewer than ENTRIES flushes
// happen and the head no longer holds position 0 when the next frame starts.
// So the block counts its own position and, at frame start, ROTATES itself back
// to position 0 during blanking: at most ENTRIES-1 cycles, against thousands
// before the first flush of the frame. Entries a short frame did not update
// keep their old background, which is what the addressed store does too.
// `resynced` is sticky and goes to the host as a diagnostic.
module aquafuse_bg_fifo #(
    parameter int ENTRIES = 91,
    parameter int COUT    = 4,
    parameter int W       = 15,
    parameter int Q       = 4
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  frame_start,
    input  logic                  rd_en,          // the stem flush cycle
    input  logic [32*COUT-1:0]    acc_in,         // lane 0 = MSB
    output logic [32*COUT-1:0]    sub_out,        // background << Q, lane 0 = MSB
    output logic                  resynced        // sticky: a rotation happened
);
    localparam int PW = $clog2(ENTRIES);
    localparam logic signed [W-1:0] W_MAX = {1'b0, {(W-1){1'b1}}};
    localparam logic signed [W-1:0] W_MIN = {1'b1, {(W-1){1'b0}}};

    function automatic logic signed [W-1:0] sat_w(input logic signed [31:0] v);
        if (v > $signed({{(32-W){1'b0}}, W_MAX}))      sat_w = W_MAX;
        else if (v < $signed({{(32-W){1'b1}}, W_MIN})) sat_w = W_MIN;
        else                                            sat_w = v[W-1:0];
    endfunction

    logic [W*COUT-1:0] q [ENTRIES-1:0];
    logic [PW-1:0]     pos;          // position the head holds
    logic              seeded, rotating;

    logic [W*COUT-1:0] upd_word;
    for (genvar l = 0; l < COUT; l++) begin : g_lane
        logic signed [31:0] acc, diff;
        logic signed [W-1:0] tgt, cur;
        assign acc  = $signed(acc_in[32*(COUT-1-l) +: 32]);
        assign tgt  = sat_w(acc >>> Q);
        assign cur  = seeded ? $signed(q[0][W*(COUT-1-l) +: W]) : tgt;
        assign diff = 32'(3) * (32'($signed(tgt)) - 32'($signed(cur))) + 32'sd8;
        assign upd_word[W*(COUT-1-l) +: W] = sat_w(32'($signed(cur)) + (diff >>> 4));
        assign sub_out[32*(COUT-1-l) +: 32] = 32'($signed(cur)) <<< Q;
    end

    wire shift = rd_en || rotating;
    always_ff @(posedge clk) begin
        if (shift) begin
            for (int i = 0; i < ENTRIES - 1; i++) q[i] <= q[i + 1];
            q[ENTRIES - 1] <= rd_en ? upd_word : q[0];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pos <= '0; seeded <= 1'b0; rotating <= 1'b0; resynced <= 1'b0;
        end else begin
            if (shift)
                pos <= (pos == PW'(ENTRIES - 1)) ? '0 : pos + 1'b1;
            if (rd_en && pos == PW'(ENTRIES - 1))
                seeded <= 1'b1;
            if (frame_start && pos != '0) begin
                rotating <= 1'b1;
                resynced <= 1'b1;
            end else if (rotating && pos == PW'(ENTRIES - 1)) begin
                rotating <= 1'b0;                 // this shift lands on 0
            end
        end
    end
endmodule
