`timescale 1ns/1ps
// The temporal head: a K-frame, 3x3 causal convolution over the 4x7 objectness
// maps, then a MAX over cells (DR 0093).
//
// WHY. Motion coherence. A fish translates through adjacent cells on
// consecutive frames; a suspended particle flickers in one frame and is gone.
// On the same recipe this head took held-out A3 from 0.7882 to 0.8086 and dev
// from 0.7547 to 0.8311 -- the largest single step in the investigation -- for
// 756 MACs and two stored maps.
//
// ARITHMETIC, matched by host/aquafuse/stream/chip_stream.py (run_clip):
//   stored map  m[c] = sat_MW(round_shift(obj[c], OBJ_SH))   per cell, per frame
//   out[c]      = T_B + sum_{j,di,dj} T_W[j][di][dj] * m_{lag K-1-j}[c + (di-1, dj-1)]
//                 (zero outside the grid; lag 0 = this frame)
//   logit       = max_c out[c]
// Frames before power-on do not exist, so a missing lag reads the earliest
// frame the head has seen -- the oracle's max(t - lag, 0).
//
// SCHEDULE. One multiplier, 9K taps x 28 cells = 756 cycles at K = 3, started
// once the head has written all 28 cells of the frame. The next frame cannot
// disturb it: its first cell arrives tens of thousands of cycles later.
module aquafuse_temporal_head #(
    parameter int GH     = 4,
    parameter int GW     = 7,
    parameter int K      = 3,
    parameter int IN_W   = 21,          // head logit width
    parameter int MW     = 10,          // stored map width, signed
    parameter int OBJ_SH = 0,
    parameter logic [8*9*K-1:0] T_W = '0, // taps, j-major (j = 0 oldest), di, dj; tap 0 = MSB
    parameter logic signed [31:0] T_B = 32'sd0
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         wr_en,      // a head cell this cycle
    input  logic [$clog2(GH*GW)-1:0]     wr_idx,
    input  logic signed [IN_W-1:0]       wr_val,
    input  logic                         start,      // all cells of the frame written
    output logic                         done,       // one-cycle pulse
    output logic signed [31:0]           logit
);
    localparam int N    = GH * GW;
    localparam int TAPS = 9 * K;
    localparam logic signed [MW-1:0] M_MAX = {1'b0, {(MW-1){1'b1}}};
    localparam logic signed [MW-1:0] M_MIN = {1'b1, {(MW-1){1'b0}}};

    // round_shift (ties away from zero, on the magnitude) then saturate -- the
    // chip's rounding contract, the same as round_sat_relu without the 8-bit
    // clamp and the ReLU
    function automatic logic signed [MW-1:0] narrow(input logic signed [IN_W-1:0] v);
        logic [31:0] mag, rnd;
        logic signed [31:0] r;
        begin
            mag = v[IN_W-1] ? 32'(-$signed(v)) : 32'($signed(v));
            rnd = (OBJ_SH == 0) ? mag : (mag + (32'd1 << (OBJ_SH - 1))) >> OBJ_SH;
            r = v[IN_W-1] ? -$signed(rnd) : $signed(rnd);
            if (r > $signed({{(32-MW){1'b0}}, M_MAX}))      narrow = M_MAX;
            else if (r < $signed({{(32-MW){1'b1}}, M_MIN})) narrow = M_MIN;
            else                                             narrow = r[MW-1:0];
        end
    endfunction

    // A RING OF K SLOTS, written in place: this frame's map goes into slot
    // `wslot`, and lag L is read from slot (wslot - L) mod K. Nothing is ever
    // copied flop to flop -- the first version shifted cur -> p1 -> p2 every
    // frame, and a shift is the most hold-critical structure there is (the
    // shift-register background store drew 12,000 hold buffers and failed
    // detailed placement, stream12c_8x4_r2).
    // FLAT, slot-major: word (slot, cell) is ring[(slot*N + cell)*MW +: MW], one
    // driver per word from the gated block below (see aquafuse_bg_store for why
    // flat: this yosys rejects multi-dimensional packed nets).
    wire  [K*N*MW-1:0] ring;
    logic [1:0]           wslot;         // slot this frame writes, 0..K-1
    logic [1:0]           seen;          // earlier frames held, saturates at K-1

    // ONE CLOCK GATE PER WORD (aquafuse_icg), not a write multiplexer per bit.
    wire signed [MW-1:0] wr_narrow = narrow(wr_val);
    for (genvar s = 0; s < K; s++) begin : g_slot
        for (genvar c = 0; c < N; c++) begin : g_cell
            logic gclk;
            aquafuse_icg u_cg (
                .clk (clk),
                .en  (wr_en && wslot == 2'(s) && wr_idx == ($clog2(N))'(c)),
                .gclk(gclk)
            );
            logic [MW-1:0] word;
            always_ff @(posedge gclk) word <= wr_narrow;
            assign ring[(s*N + c)*MW +: MW] = word;
        end
    end

    // ---- the sequential convolution ------------------------------------------
    typedef enum logic [1:0] {IDLE, RUN, FIN} st_t;
    st_t st;
    logic [$clog2(N)-1:0]    cix;
    logic [$clog2(TAPS)-1:0] tap;
    logic signed [31:0]      acc, best;
    logic                    have_best;

    // the tap's frame, row and column offsets
    wire [$clog2(K)-1:0] j  = ($clog2(K))'(tap / 9);
    wire [3:0]           t9 = 4'(tap % 9);
    wire signed [3:0]    di = $signed({2'b0, t9 / 3}) - 4'sd1;
    wire signed [3:0]    dj = $signed({2'b0, t9 % 3}) - 4'sd1;
    wire [$clog2(GH)-1:0] r0 = ($clog2(GH))'(cix / GW);
    wire [$clog2(GW)-1:0] c0 = ($clog2(GW))'(cix % GW);
    wire signed [5:0] rr = $signed({2'b0, r0}) + 6'(di);
    wire signed [5:0] cc = $signed({2'b0, c0}) + 6'(dj);
    wire inb = (rr >= 0) && (rr < GH) && (cc >= 0) && (cc < GW);
    wire [$clog2(N)-1:0] nidx = inb ? ($clog2(N))'(rr * GW + cc) : '0;
    // lag of this tap; a lag deeper than the frames seen reads the earliest one
    wire [1:0] lag  = 2'(K - 1) - 2'(j);
    wire [1:0] eff  = (lag > seen) ? seen : lag;
    // slot of lag `eff`: wslot - eff, mod K, without a divider
    wire [2:0] sdiff = {1'b0, wslot} + 3'(K) - {1'b0, eff};
    wire [1:0] rslot = (sdiff >= 3'(K)) ? 2'(sdiff - 3'(K)) : 2'(sdiff);
    // the read port, through a balanced tree (aquafuse_sel); slot-major index
    localparam int RW = $clog2(K*N);
    logic [RW-1:0] rd_idx;
    assign rd_idx = RW'(rslot * N + nidx);
    logic [MW-1:0] rd_word;
    aquafuse_sel #(.N(K*N), .W(MW)) u_rd (.words(ring), .sel(rd_idx), .y(rd_word));
    wire signed [MW-1:0] mval = !inb ? '0 : rd_word;
    wire signed [7:0] wv = $signed(T_W[8*(TAPS-1-tap) +: 8]);
    // BOTH operands widened first: inside a cast the product is self-determined,
    // so `32'(wv * mval)` would multiply at 10 bits and overflow before widening
    wire signed [31:0] prod = 32'($signed(wv)) * 32'($signed(mval));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= IDLE; done <= 1'b0; seen <= 2'd0; wslot <= 2'd0;
            cix <= '0; tap <= '0; acc <= '0; best <= '0; have_best <= 1'b0;
            logit <= '0;
        end else begin
            done <= 1'b0;
            case (st)
                IDLE: if (start) begin
                    cix <= '0; tap <= '0; acc <= T_B; have_best <= 1'b0;
                    st <= RUN;
                end
                RUN: begin
                    if (tap == ($clog2(TAPS))'(TAPS - 1)) begin
                        // this cell's last tap lands in the comparison directly
                        if (!have_best || (acc + prod) > best)
                            best <= acc + prod;
                        have_best <= 1'b1;
                        acc <= T_B;
                        tap <= '0;
                        if (cix == ($clog2(N))'(N - 1)) st <= FIN;
                        else cix <= cix + 1'b1;
                    end else begin
                        acc <= acc + prod;
                        tap <= tap + 1'b1;
                    end
                end
                FIN: begin
                    logit <= best;
                    done  <= 1'b1;
                    if (seen != 2'(K - 1)) seen <= seen + 2'd1;
                    // the frame retires: the next one writes the next slot,
                    // which turns this frame into lag 1 without moving a bit
                    wslot <= (wslot == 2'(K - 1)) ? 2'd0 : wslot + 2'd1;
                    st <= IDLE;
                end
                default: st <= IDLE;
            endcase
        end
    end

    // No history shift: retiring a frame is advancing `wslot` (FIN, above). On
    // the first frames a lag deeper than `seen` reads the earliest frame
    // through `eff`, which is the oracle's max(t - lag, 0).
endmodule
