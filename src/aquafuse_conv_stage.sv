`timescale 1ns/1ps
// One streaming 3x3 convolution stage: raster in, raster out.
//
// Holds three input rows and emits an output row as soon as the last input row
// that feeds it has arrived. Both gq54 block layers are instances of this
// (3x3, stride 2, pad 1), so the sequencer is two of these chained rather than
// a bespoke FSM per layer.
//
// WHY THREE ROWS IS ENOUGH AT STRIDE 2, which is the part worth checking
// rather than assuming. Output row `orow` needs input rows 2*orow-1 ..
// 2*orow+1. The next output row needs 2*orow+1 .. 2*orow+3, so exactly one row
// is shared. Writing input row r into slot (r mod 3) means rows 2*orow+2 and
// 2*orow+3 land in the slots vacated by 2*orow-1 and 2*orow, because they
// differ by exactly 3 and 3. So the three slots always hold precisely the rows
// the next output row needs, and no row is ever overwritten while required.
//
// THAT ARGUMENT IS STRIDE-2 ONLY, and this module was stride-2 only with it.
// Measured 24 Sep on the DR 0070 stage-2 geometry (4x7x6), two ways:
//
//   stride 2, polite tb      PASS      stride 2, real producer cadence  PASS
//   stride 1, polite tb      FAIL 42   stride 1, real producer cadence  FAIL 65
//
// Two independent defects, both now fixed here:
//
//   1. EMIT TRIGGER. `(r_sig-1) % STRIDE == 0` is ALWAYS true at STRIDE=1, so
//      the stage fired on input row 0 with orow = -1, which wraps to OUT_H-1
//      and emits the bottom row first. Stride 2 escapes only because
//      -1 % 2 != 0. The trigger is now a row-count comparison against the
//      input row each output row actually needs, which is the same statement
//      for both strides instead of a modulo that happens to work for one.
//
//   2. SLOT COUNT. At stride 1 consecutive output rows share TWO rows, not
//      one, and row 3 collides with row 0 in a mod-3 store. ROWS is now IN_H
//      at stride 1, so no row is overwritten within a frame at all.
//
// The second defect is the one that would have survived review: it needs the
// producer to keep streaming, and tb_conv_stage waits on `busy` between rows
// while tt_um_aquafuse_stream12_prefreeze drives s1_busy/s2_busy into nothing.
// See the T_GAP mode in the testbench.
//
// Rows above the top and below the bottom read as ZERO, which is the padding.
// They are not stored; `row_in_range` suppresses the read.
//
// THE FAILURE THIS IS BUILT AGAINST. A stage that drops a row, re-reads one,
// or emits an output row one input row early computes a valid convolution of
// the wrong pixels, and every arithmetic self-check still passes. That is the
// same class as the two ROM-mode schedule bugs and is why tb_conv_stage scores
// against an independently generated reference rather than against a second
// copy of this module's own addressing.
//
// PRE-FREEZE, NON-MANUFACTURING. Not D3/D4/D5 exit evidence; decision 0009.
module aquafuse_conv_stage #(
    parameter int IN_H   = 14,
    parameter int IN_W   = 25,
    parameter int IN_CH  = 4,
    parameter int OUT_CH = 8,
    parameter int STRIDE = 2,
    parameter int ACC_W  = 24
) (
    input  logic                        clk,
    input  logic                        rst_n,

    input  logic                        in_valid,
    input  logic [$clog2(IN_H)-1:0]     in_row,
    input  logic [$clog2(IN_W)-1:0]     in_col,
    input  logic [8*IN_CH-1:0]          in_data,

    // weights: one (kr,kc,ci) tap for all OUT_CH lanes, supplied by the caller
    output logic [3:0]                  w_tap,      // kr*3+kc
    output logic [$clog2(IN_CH)-1:0]    w_ci,
    input  logic [8*OUT_CH-1:0]         w_data,     // lane 0 = MSB

    // ONE REQUANTISATION SHIFT PER OUTPUT CHANNEL, lane 0 = MSB, matching the
    // lane order of w_data and out_data. A single per-LAYER shift measures
    // A2 = 0.8743; per-channel measures 0.8905 and clears the 0.89 bar, and
    // the cost is config width only. `l` below is a compile-time constant of
    // the unrolled EMIT loop, so each lane selects a CONSTANT slice and no
    // multiplexer is added -- the barrel shifter inside round_sat_relu was
    // already variable.
    input  logic [5*OUT_CH-1:0]         cfg_shift,
    input  logic                        cfg_relu,
    // STREAM12C (DR 0093): the folded batch-norm bias, per output channel, in
    // this stage's accumulator units, lane 0 = MSB. Each output's accumulator
    // STARTS at it instead of at zero -- the same trick CLS_OFFSET already plays
    // on the head -- so the bias costs a reset value, not an adder. Without it
    // the part computes a network the model never was (DR 0091: -5 points).
    input  logic [32*OUT_CH-1:0]        cfg_bias,

    output logic                        out_valid,
    // Sized from the INPUT dims: OUT_H/OUT_W are localparams computed from the
    // parameters and are not visible in the port list. OUT < IN always, so the
    // input widths are sufficient and this avoids a parameter-ordering hazard.
    output logic [$clog2(IN_H)-1:0]     out_row,
    output logic [$clog2(IN_W)-1:0]     out_col,
    output logic [8*OUT_CH-1:0]         out_data,
    output logic                        busy
);
`include "aquafuse_round.svh"

    localparam int PAD    = 1;
    localparam int OUT_H  = (IN_H + 2*PAD - 3)/STRIDE + 1;
    localparam int OUT_W  = (IN_W + 2*PAD - 3)/STRIDE + 1;
    localparam int TAPS   = 9 * IN_CH;

    // ---- row store ---------------------------------------------------------
    // Three slots at stride 2 (see the header). At stride 1 the store holds the
    // WHOLE input frame, so a row can never be overwritten while still needed
    // no matter how far behind the sequencer falls -- which matters because
    // nothing upstream reads `busy`. For the DR 0070 stage 2 that is IN_H = 4
    // rows against 3, i.e. +1 row of IN_W*8*IN_CH = 336 flops.
    localparam int ROWS  = (STRIDE == 1) ? IN_H : 3;
    localparam int SLW   = (ROWS <= 1) ? 1 : $clog2(ROWS);

    // FLAT, slot-major: word (slot, col) is rowmem[(slot*IN_W + col)*WB +: WB],
    // one driver per word from the gated block below (see aquafuse_bg_store
    // for why flat: this yosys rejects multi-dimensional packed nets).
    // 7 bits stored per activation (GF180 area): both stages are fed post-ReLU bytes, 0..127,
    // so bit 7 is always 0 and is neither stored nor read.
    localparam int WB = 7 * IN_CH;
    wire  [ROWS*IN_W*WB-1:0] rowmem;
    logic [SLW-1:0] wr_slot;
    // WIDEN BEFORE THE MODULUS. ROWS can equal IN_H, and slicing it to
    // $clog2(IN_H) bits truncates 4 to 0 -- a modulo by zero that writes every
    // row to slot x and fails all 168 outputs identically.
    localparam int MW = $clog2(IN_H+1);
    assign wr_slot = SLW'(MW'(in_row) % MW'(ROWS));

    // ONE CLOCK GATE PER WORD (aquafuse_icg), not a write multiplexer per bit:
    // the row store is most of this stage's flops (see aquafuse_bg_store).
    // Latch storage (GF180 area, see aquafuse_bg_store): fed from a register so the
    // latch, transparent in the high phase after the edge, holds this cycle's data.
    logic [WB-1:0] in_q;
    wire [WB-1:0] in7;
    for (genvar ch = 0; ch < IN_CH; ch++) begin : g_pack
        assign in7[7*ch +: 7] = in_data[8*ch +: 7];
    end
    always_ff @(posedge clk) in_q <= in7;
    for (genvar s = 0; s < ROWS; s++) begin : g_slot
        for (genvar c = 0; c < IN_W; c++) begin : g_col
            logic gclk;
            aquafuse_icg u_cg (
                .clk (clk),
                .en  (in_valid && wr_slot == SLW'(s) && in_col == ($clog2(IN_W))'(c)),
                .gclk(gclk)
            );
            logic [WB-1:0] word;
            aquafuse_lat #(.W(WB)) u_lat (.en(gclk), .d(in_q), .q(word));
            assign rowmem[(s*IN_W + c)*WB +: WB] = word;
        end
    end

    // ---- emit trigger -----------------------------------------------------
    // Output row orow is ready once input row STRIDE*orow+1 has landed (or the
    // final input row, for the bottom edge).
    logic last_of_row;
    assign last_of_row = in_valid && (in_col == IN_W-1);

    // Output row `orow` reads input rows orow*STRIDE-1 .. orow*STRIDE+1, so it
    // is complete once input row min(orow*STRIDE+1, IN_H-1) has landed -- the
    // min is the bottom-edge case, where the row below is padding. Stated as a
    // count of landed rows this is one expression for both strides; the modulo
    // it replaces silently degenerated at STRIDE=1.
    logic [$clog2(IN_H+1)-1:0] rows_landed;   // input rows fully received
    logic [$clog2(OUT_H+1)-1:0] orow_ptr;     // next output row to produce
    logic frame_restart;
    assign frame_restart = in_valid && (in_row == 0) && (in_col == 0);

    logic [$clog2(IN_H+1)-1:0] need_row, rows_eff;
    logic ready_now;
    always_comb begin
        need_row  = ($clog2(IN_H+1))'(orow_ptr * STRIDE + 1);
        if (need_row > ($clog2(IN_H+1))'(IN_H-1))
            need_row = ($clog2(IN_H+1))'(IN_H-1);
        // rows_eff COUNTS THE BEAT IN FLIGHT. `rows_landed` only updates at the
        // end of the cycle that completes a row, so testing it alone raises
        // `busy` one cycle later than the old trigger did, and a consumer that
        // samples busy right after the last beat sees an idle stage. The old
        // expression got this for free by including `last_of_row`.
        rows_eff  = last_of_row ? (($clog2(IN_H+1))'(in_row) + 1'b1)
                                : rows_landed;
        ready_now = (orow_ptr < ($clog2(OUT_H+1))'(OUT_H)) &&
                    (rows_eff > need_row);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rows_landed <= '0;
        end else if (frame_restart) begin
            // A new frame's row 0 is arriving; anything counted is stale.
            rows_landed <= '0;
        end else if (last_of_row) begin
            rows_landed <= ($clog2(IN_H+1))'(in_row) + 1'b1;
        end
    end

    // ---- sequencer over one output row ------------------------------------
    typedef enum logic [1:0] {IDLE, MAC, EMIT} state_t;
    state_t st;

    logic [$clog2(IN_H)-1:0] orow_q;
    logic [$clog2(IN_W)-1:0] ocol_q;
    logic [$clog2(TAPS+1)-1:0] tap_q;
    logic signed [ACC_W-1:0]  acc [OUT_CH-1:0];
    logic signed [ACC_W-1:0]  bias_seed [OUT_CH-1:0];
    for (genvar l = 0; l < OUT_CH; l++) begin : g_bias
        assign bias_seed[l] = ACC_W'($signed(cfg_bias[32*(OUT_CH-1-l) +: 32]));
    end

    // window address for the current tap
    logic [3:0] kk;
    logic [1:0] kr, kc;
    assign kk = tap_q / IN_CH[$clog2(TAPS+1)-1:0];
    assign kr = kk / 3;
    assign kc = kk % 3;
    assign w_tap = kk;
    assign w_ci  = tap_q % IN_CH[$clog2(TAPS+1)-1:0];

    logic signed [$clog2(IN_H)+2:0] ir;
    logic signed [$clog2(IN_W)+2:0] ic;
    logic in_range;
    logic [SLW-1:0] rd_slot;
    logic [$clog2(IN_W)-1:0] ic_idx;
    logic signed [7:0] act;

    always_comb begin
        ir       = $signed({1'b0, orow_q}) * STRIDE - PAD + $signed({1'b0, kr});
        ic       = $signed({1'b0, ocol_q}) * STRIDE - PAD + $signed({1'b0, kc});
        in_range = (ir >= 0) && (ir < IN_H) && (ic >= 0) && (ic < IN_W);
        // SAME MODULUS AS wr_slot. Hardcoding 3 here while the write used ROWS
        // reads a row the producer never wrote to that slot -- a valid
        // convolution of the wrong pixels, which is this module's named hazard.
        // `ir` is SIGNED and reaches -1 at the top pad, so it is left in its own
        // signed context rather than cast to MW bits, where -1 becomes 15 and
        // aliases onto a real slot. `in_range` gates the result either way, but
        // the guard should not be the only thing standing between a pad read
        // and a live row.
        rd_slot  = in_range ? SLW'(ir % ROWS) : SLW'(0);
        ic_idx   = in_range ? ic[$clog2(IN_W)-1:0] : '0;
    end

    // The read port, through a balanced tree (aquafuse_sel). The word index is
    // slot-major; in range it is < ROWS*IN_W, and out of range rd_slot and
    // ic_idx are both 0.
    localparam int RW = $clog2(ROWS*IN_W);
    logic [RW-1:0] rd_idx;
    assign rd_idx = RW'(rd_slot * IN_W + ic_idx);
    logic [WB-1:0] win_raw;
    aquafuse_sel #(.N(ROWS*IN_W), .W(WB)) u_rd (.words(rowmem), .sel(rd_idx), .y(win_raw));
    wire [8*IN_CH-1:0] win_word;
    for (genvar ch = 0; ch < IN_CH; ch++) begin : g_unpack
        assign win_word[8*ch +: 8] = {1'b0, in_range ? win_raw[7*ch +: 7] : 7'd0};
    end
    assign act = $signed(win_word[8*(IN_CH-1-w_ci) +: 8]);

    // lane sequencing: shared multiplier in MAC, shared requantiser in EMIT
    localparam int LW = (OUT_CH <= 1) ? 1 : $clog2(OUT_CH);
    logic [LW-1:0] lane_q;
    logic signed [7:0] w_lane;
    logic signed [ACC_W-1:0] acc_lane;
    logic signed [15:0] prod16;
    logic signed [ACC_W-1:0] mac_prod;
    logic [7:0] emit_byte;
    always_comb begin
        w_lane   = '0;
        acc_lane = '0;
        for (int l = 0; l < OUT_CH; l++)
            if (lane_q == LW'(l)) begin
                w_lane   = $signed(w_data[8*(OUT_CH-1-l) +: 8]);
                acc_lane = acc[l];
            end
        prod16    = $signed(act) * w_lane;          // 16-bit context: the full 8x8 product
        mac_prod  = ACC_W'(prod16);                 // sign-extends
        emit_byte = round_sat_relu({{(24-ACC_W){acc_lane[ACC_W-1]}}, acc_lane},
                                   cfg_shift[5*(OUT_CH-1-lane_q) +: 5], cfg_relu);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; orow_q <= '0; ocol_q <= '0; tap_q <= '0; lane_q <= '0;
            orow_ptr <= '0;
            out_valid <= 1'b0; busy <= 1'b0;
            for (int l = 0; l < OUT_CH; l++) acc[l] <= '0;
        end else begin
            out_valid <= 1'b0;
            case (st)
                IDLE: begin
                    busy <= 1'b0;
                    if (ready_now) begin
                        // The row to produce is the pointer, not a function of
                        // whichever input row happened to trigger. That coupling
                        // is what produced orow = -1 at STRIDE=1.
                        orow_q   <= ($clog2(IN_H))'(orow_ptr);
                        orow_ptr <= orow_ptr + 1'b1;
                        ocol_q <= '0; tap_q <= '0; busy <= 1'b1;
                        for (int l = 0; l < OUT_CH; l++) acc[l] <= bias_seed[l];
                        st <= MAC;
                    end
                end
                MAC: begin
                    // ONE MULTIPLIER, OUT_CH CYCLES PER TAP (GF180 area). Lane `lane_q`
                    // takes this tap; each lane still sums its taps in the same order,
                    // so the result is bit-identical. The clock is stopped between
                    // frames and a frame has far more cycles than this needs.
                    for (int l = 0; l < OUT_CH; l++)
                        if (lane_q == LW'(l)) acc[l] <= acc[l] + mac_prod;
                    if (lane_q == LW'(OUT_CH-1)) begin
                        lane_q <= '0;
                        if (tap_q == TAPS-1) st <= EMIT;
                        else                 tap_q <= tap_q + 1'b1;
                    end else lane_q <= lane_q + 1'b1;
                end
                EMIT: begin
                    // One requantiser, one lane per cycle; out_valid rises with the
                    // last lane so the consumer sees the whole word at once.
                    for (int l = 0; l < OUT_CH; l++)
                        if (lane_q == LW'(l))
                            out_data[8*(OUT_CH-1-l) +: 8] <= emit_byte;
                    if (lane_q == LW'(OUT_CH-1)) begin
                        lane_q    <= '0;
                        out_valid <= 1'b1;
                        out_row   <= orow_q;
                        out_col   <= ocol_q;
                        for (int l = 0; l < OUT_CH; l++) acc[l] <= bias_seed[l];
                        tap_q <= '0;
                        if (ocol_q == OUT_W-1) st <= IDLE;
                        else begin ocol_q <= ocol_q + 1'b1; st <= MAC; end
                    end else lane_q <= lane_q + 1'b1;
                end
                default: st <= IDLE;
            endcase
            // AFTER the case so it takes priority over IDLE's increment: a new
            // frame's row 0 arriving retires the previous frame's pointer, and
            // the two can coincide because `ready_now` reads the pre-clear
            // `rows_landed`. The stage is idle between frames by a wide margin
            // -- the sensor streams IMG_H*IMG_W pixels before stage 1 can emit
            // again -- but the ordering is stated rather than assumed.
            if (frame_restart) orow_ptr <= '0;
        end
    end

endmodule
