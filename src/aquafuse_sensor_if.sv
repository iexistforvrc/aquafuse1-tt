`timescale 1ns/1ps
// Sensor front end: raster pixels in, validated frames out.
//
// WHO SUPPLIES THE CLOCK. The sensor does. Image sensors are free-running
// masters (PCLK/VSYNC/HSYNC) and cannot be back-pressured, so the chip cannot
// be the timing master without a FIFO it has no room for. PCLK is therefore an
// ASYNCHRONOUS INPUT, double-synchronised and edge-detected in the chip domain.
// That is safe here by a wide margin and not by luck: 54x96 at 15 fps is
// 77,760 pixel/s against a 26.3 MHz core, so the core oversamples PCLK by
// ~338x, far past the 2x an edge detector needs.
//
// WHAT HAPPENS ON OVERRUN. The frame is DROPPED, whole. Not truncated, not
// patched, not partially processed. A streaming classifier fed a frame with a
// hole in it returns a perfectly well-formed score for pixels that were never
// captured, and nothing downstream can tell that from a real answer -- the same
// failure class as the ROM-mode schedule bugs and the reason plan item 3.5
// exists. `frame_valid` is the contract: it is asserted at frame end ONLY if
// exactly H*W pixels arrived with no overrun. The sequencer must gate its
// result on it.
//
// HOW A FRAME STARTS AND ENDS. VSYNC rising starts it and zeroes the counters.
// The frame ends on VSYNC falling. A frame whose pixel count is not exactly
// H*W is a short or long frame and is marked invalid, which catches a sensor
// misconfigured to a different resolution -- a failure that would otherwise
// look like a merely inaccurate model.
//
// MINIMUM VERTICAL BLANKING, 9 CORE CLOCKS between VSYNC fall and the next
// VSYNC rise. This block does not enforce it and cannot: it is a property of
// the classifier downstream, which needs 8 cycles after frame_end and is
// aborted by the next frame_start. Below 9 clocks frames are scored and then
// silently discarded -- measured, 12 driven frames yielding 1 result with no
// error raised. Stated here because this is the file a sensor integrator reads.
//
// IN_CH is a parameter: the sensor supplies IN_CH bytes per pixel. At IN_CH=1
// this is one appearance byte and no temporal channels, which is the
// configuration measured to need no per-pixel EMA state at all.
//
// PRE-FREEZE, NON-MANUFACTURING. Not D3/D4/D5 exit evidence; decision 0009.
module aquafuse_sensor_if #(
    parameter int IMG_H = 54,
    parameter int IMG_W = 96,
    parameter int IN_CH = 1
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // asynchronous sensor side
    input  logic                     s_pclk,
    input  logic                     s_vsync,
    input  logic [8*IN_CH-1:0]       s_data,

    // chip side, in the core clock domain
    input  logic                     core_ready,
    output logic                     pix_valid,
    output logic [8*IN_CH-1:0]       pix_data,
    output logic [$clog2(IMG_H)-1:0] pix_row,
    output logic [$clog2(IMG_W)-1:0] pix_col,

    output logic                     frame_start,
    output logic                     frame_end,
    output logic                     frame_valid,   // qualifies frame_end
    // TWO overrun bits, because one could not answer the question anyone asks.
    //   overrun_sticky -- set on the first overrun, cleared only by reset. It
    //     says "this chip has overrun at some point since power-on", which is
    //     the right thing for a latching fault lamp and the wrong thing for
    //     everything else: after one overrun it can never again describe the
    //     CURRENT frame, so a host cannot tell a recovered sensor from a
    //     permanently broken one.
    //   overrun_frame -- set on an overrun in THIS frame, cleared at every
    //     frame start. This is the bit a host polls, and it is what makes the
    //     recovery path observable at all.
    // Reported as a defect on 6 Sep with only the sticky bit in the design;
    // fixed by adding the per-frame bit rather than by changing the sticky
    // one's meaning, because tb_stream12_overrun asserts the sticky contract
    // deliberately and that assertion is correct.
    output logic                     overrun_sticky,
    output logic                     overrun_frame,
    // High between VSYNC rise and fall. Exported so the top can hold a config
    // load until a frame boundary; a load applied mid-frame would change the
    // stem's shift after the stem had run and before the classifier did.
    output logic                     in_frame
);

    localparam int PIXELS = IMG_H * IMG_W;

    // ---- clock-domain crossing -------------------------------------------
    /* verilator lint_off SYNCASYNCNET */
    logic [2:0] pclk_sync, vsync_sync;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pclk_sync  <= 3'b000;
            vsync_sync <= 3'b000;
        end else begin
            pclk_sync  <= {pclk_sync[1:0],  s_pclk};
            vsync_sync <= {vsync_sync[1:0], s_vsync};
        end
    end
    /* verilator lint_on SYNCASYNCNET */

    wire pclk_rise  = ( pclk_sync[1] & ~pclk_sync[2]);
    wire vsync_rise = (vsync_sync[1] & ~vsync_sync[2]);
    wire vsync_fall = (~vsync_sync[1] & vsync_sync[2]);

    // ---- counters and framing --------------------------------------------
    // Row and column are carried INCREMENTALLY, not derived as count/IMG_W and
    // count%IMG_W. IMG_W is 96, not a power of two, so those would infer a
    // divider and a modulo unit on a die whose whole free budget is a few
    // thousand flops.
    logic [$clog2(PIXELS+1)-1:0] count;
    logic [$clog2(IMG_H)-1:0]    row_q;
    logic [$clog2(IMG_W)-1:0]    col_q;
    logic                        bad;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0; row_q <= '0; col_q <= '0;
            in_frame <= 1'b0; bad <= 1'b0;
            overrun_sticky <= 1'b0; overrun_frame <= 1'b0;
            pix_valid <= 1'b0; pix_data <= '0;
            pix_row <= '0; pix_col <= '0;
            frame_start <= 1'b0; frame_end <= 1'b0; frame_valid <= 1'b0;
        end else begin
            frame_start <= 1'b0;
            frame_end   <= 1'b0;
            pix_valid   <= 1'b0;

            if (vsync_rise) begin
                count <= '0; row_q <= '0; col_q <= '0;
                in_frame <= 1'b1; bad <= 1'b0;
                overrun_frame <= 1'b0;
                frame_start <= 1'b1;
            end else if (vsync_fall && in_frame) begin
                in_frame    <= 1'b0;
                frame_end   <= 1'b1;
                frame_valid <= (count == PIXELS[$clog2(PIXELS+1)-1:0]) && !bad;
            end else if (in_frame && pclk_rise) begin
                if (!core_ready || count == PIXELS[$clog2(PIXELS+1)-1:0]) begin
                    // Overrun, or more pixels than the configured resolution.
                    bad            <= 1'b1;
                    overrun_sticky <= 1'b1;
                    overrun_frame  <= 1'b1;
                end else begin
                    pix_valid <= 1'b1;
                    pix_data  <= s_data;
                    pix_row   <= row_q;
                    pix_col   <= col_q;
                    count     <= count + 1'b1;
                    if (col_q == IMG_W-1) begin
                        col_q <= '0;
                        row_q <= row_q + 1'b1;
                    end else begin
                        col_q <= col_q + 1'b1;
                    end
                end
            end
        end
    end

endmodule
