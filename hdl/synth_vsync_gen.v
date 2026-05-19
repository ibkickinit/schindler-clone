// synth_vsync_gen.v — Phase E1 Phase 2 synthetic reference.
//
// Integer-divider on a stable PS-derived clock that produces a 50%-duty-cycle
// square wave at nominal 50 Hz. Used as `ref_vsync_async` into the Phase 1
// vsync_timestamp instrument until real reference hardware (HDMI vsync,
// Si5351, analog reference recovery) is wired into the reference mux in
// later phases.
//
// FCLK_CLK1 was requested at 150 MHz in the BD config; the Zynq IO-PLL at
// 1000 MHz can only produce 1000/N MHz for integer N, and 150 MHz isn't on
// that grid. Closest achievable is 1000/7 = 142.857 MHz, which is what the
// PS PLL actually delivers. Verified empirically in the first Phase 2 build:
// with DIVISOR=2,500,000, the period was a perfectly-stable 1,750,000 ticks
// = 17.5 ms = 57.143 Hz, exactly what FCLK_CLK1=142.857 MHz / 2.5M predicts.
//
// We chose DIVISOR=2,857,143 to target ~50 Hz instead — to match the output
// vsync (720p50 default at d71c994), so Phase 4–6's MMCM phase loop has a
// ref-vs-output rate gap well inside its ±500 ppm pull range. Effective ref
// rate = 142.857 MHz / 2,857,143 = 49.999999... Hz, sub-ppm offset from a
// perfect 50 Hz.
//
// Per ground-up plan §4 Phase 2 footnote: this synthetic reference and the
// pixel-clock MMCM both descend from the TE0720's onboard ~33.333 MHz
// PS_REF_CLK crystal. They are rationally related at zero ppm drift; the
// "drift" Phase 3 measures is the constant offset between two stable but
// not-identically-rated signals. The loop topology validates the same way
// regardless of the magnitude.
//
// Why a level signal (50% duty) rather than a 1-cycle pulse: the 100 MHz
// sampling domain on the consumer side samples every 10 ns. A 1-cycle
// FCLK_CLK1 pulse (~7 ns wide) is shorter than the sampling interval and
// risks being missed entirely. A 50% duty signal has each transition
// guaranteed-visible to the 2-FF synchronizer.

`default_nettype none
`timescale 1ns / 1ps

module synth_vsync_gen #(
    parameter integer DIVISOR = 2_857_143  // FCLK_CLK1 (142.857 MHz) / 50 Hz
)(
    input  wire clk,        // FCLK_CLK1, 150 MHz
    input  wire aresetn,    // active-low reset, sync to clk
    output wire vsync_out   // 50% duty square wave at clk / DIVISOR
);
    localparam integer CNT_W = $clog2(DIVISOR);
    localparam integer HALF  = DIVISOR / 2;

    reg [CNT_W-1:0] counter;
    reg             vsync;

    always @(posedge clk) begin
        if (!aresetn) begin
            counter <= {CNT_W{1'b0}};
            vsync   <= 1'b0;
        end else begin
            // Free-running counter modulo DIVISOR.
            if (counter == DIVISOR - 1)
                counter <= {CNT_W{1'b0}};
            else
                counter <= counter + 1'b1;

            // High for the first half of the period, low for the second.
            vsync <= (counter < HALF);
        end
    end

    assign vsync_out = vsync;

endmodule

`default_nettype wire
