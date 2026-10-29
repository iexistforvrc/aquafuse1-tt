// Shared requantisation for the AquaFuse streaming front end.
//
// An INCLUDE rather than a SystemVerilog package: yosys's Verilog frontend
// rejects `import pkg::*` in a module header ("syntax error, unexpected
// TOK_IMPORT"), and this RTL has to synthesise through the project's own yosys
// flow, not only through iverilog and verilator. Caught by synthesising it.
//
// The sequence MUST match host/aquafuse/pbwrb/runtime.py `_round_shift` and
// model/aquafuse_pbw_golden.py exactly: ties away from zero, applied to the
// MAGNITUDE, then saturate to int8, then optional ReLU. An arithmetic right
// shift is a DIFFERENT function on negative values, and using one here would
// give a design that is self-consistent and wrong.
    // acc -> int8, rounding ties away from zero on the magnitude.
    function automatic logic signed [7:0] round_sat_relu
        // 24-BIT DATAPATH (GF180 area; was 32). Every caller's value is below 2^21 in
        // magnitude (scripts/vps/acc_bounds.py: accumulators <= 20 bits; stem d_x < 2^20)
        // and every shift is a constant <= 10, so nothing is lost; the oracle test is bit-exact.
        (input logic signed [23:0] acc,
         input logic [4:0]         shift,
         input logic               relu);
        logic [23:0] mag;
        logic [23:0] rnd;
        logic signed [23:0] val;
        begin
            mag = acc[23] ? (~acc + 24'd1) : acc;
            if (shift == 5'd0) begin
                rnd = mag;
            end else begin
                rnd = (mag + (24'd1 << (shift - 5'd1))) >> shift;
            end
            val = acc[23] ? -$signed(rnd) : $signed(rnd);
            if (val >  24'sd127) val =  24'sd127;
            if (val < -24'sd128) val = -24'sd128;
            if (relu && val < 0)  val = 24'sd0;
            round_sat_relu = val[7:0];
        end
    endfunction

