`default_nettype none

// AquaFuse-1 inside the wafer.space pad ring. The part keeps its Tiny Tapeout
// interface (tt_um_aquafuse_stream12c), unchanged, so the RTL that was verified
// against the oracle is the RTL that is built:
//   bidir[ 7: 0]  ui_in   (pad as input,  ie=1 oe=0)
//   bidir[15: 8]  uio     (pad driven by the part's own uio_oe)
//   bidir[23:16]  uo_out  (pad as output, oe=1)
// Remaining bidir pads are parked as high-impedance inputs with the input buffer off.
module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif

    input  wire clk,
    input  wire rst_n,

    input  wire [NUM_INPUT_PADS-1:0] input_in,
    output wire [NUM_INPUT_PADS-1:0] input_pu,
    output wire [NUM_INPUT_PADS-1:0] input_pd,

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,

    inout  wire [NUM_ANALOG_PADS-1:0] analog
);
    assign input_pu = '0;
    assign input_pd = '0;
    assign bidir_pu = '0;
    assign bidir_pd = '0;
    assign bidir_cs = '0;          // CMOS input buffer
    assign bidir_sl = '1;          // slow slew: the part's pins run at kHz-MHz

    wire [7:0] uo_out, uio_out, uio_oe;

    tt_um_aquafuse_stream12c u_part (
        .ui_in  (bidir_in[7:0]),
        .uo_out (uo_out),
        .uio_in (bidir_in[15:8]),
        .uio_out(uio_out),
        .uio_oe (uio_oe),
        .ena    (1'b1),
        .clk    (clk),
        .rst_n  (rst_n)
    );

    // pads 0..23 carry the part; the rest are parked
    assign bidir_out[7:0]   = 8'h00;
    assign bidir_oe[7:0]    = 8'h00;
    assign bidir_ie[7:0]    = 8'hFF;
    assign bidir_out[15:8]  = uio_out;
    assign bidir_oe[15:8]   = uio_oe;
    assign bidir_ie[15:8]   = 8'hFF;
    assign bidir_out[23:16] = uo_out;
    assign bidir_oe[23:16]  = 8'hFF;
    assign bidir_ie[23:16]  = 8'h00;
    if (NUM_BIDIR_PADS > 24) begin : g_park
        assign bidir_out[NUM_BIDIR_PADS-1:24] = '0;
        assign bidir_oe[NUM_BIDIR_PADS-1:24]  = '0;
        assign bidir_ie[NUM_BIDIR_PADS-1:24]  = '0;
    end

    wire _unused = &{1'b0, input_in, bidir_in[NUM_BIDIR_PADS-1:16]};
endmodule
