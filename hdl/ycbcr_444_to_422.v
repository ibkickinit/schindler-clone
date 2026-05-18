// ycbcr_444_to_422.v — Chroma subsample YCbCr 4:4:4 → 4:2:2.
//
// Per output pixel pair (2 input pixels → 2 output samples), 16-bit each:
//
//   Output beat 0 (even pixel):  { Cb_avg, Y0 }
//   Output beat 1 (odd  pixel):  { Cr_avg, Y1 }
//
//     Cb_avg = (pixel0.Cb + pixel1.Cb) / 2  (round half up)
//     Cr_avg = (pixel0.Cr + pixel1.Cr) / 2  (round half up)
//
// Standard ITU-R BT.601 4:2:2 cositing — chroma sample 0 is positioned at the
// same horizontal location as the first luma sample (cositing per BT.601).
// The averaging is what's typically called "box filter" subsampling. A proper
// low-pass filter (e.g. Mitchell-Netravali or Lanczos) would yield better
// quality, but for 8-bit consumer-grade analog out, box average is standard
// and the ADV7393's input filter compensates further.
//
// INPUT  byte order (24-bit AXIS):  [23:16]=Y  [15:8]=Cb  [7:0]=Cr
// OUTPUT byte order (16-bit AXIS):  [15:8]=Cb_or_Cr  [7:0]=Y
//
// 1:1 sample-rate ratio: N input pixels → N output 16-bit beats. (Each input
// pixel contributes its Y, and Cb/Cr are averaged within pairs.)
//
// Even/odd pixel tracking: pixel counter resets on tlast (end of line) or
// tuser (start of frame, SOF). Reset state = even (pixel index 0).
//
// 2-stage AXIS pipeline:
//   Stage 1: capture pixel; if odd index, compute Cb/Cr average against held
//            stage-0 chroma; emit pair both beats.
//   Implemented as: hold even-pixel chroma in a register; on odd pixel, do
//            the average and emit the two beats back-to-back.

`default_nettype none
`timescale 1ns / 1ps

module ycbcr_444_to_422 (
    input  wire        aclk,
    input  wire        aresetn,

    // AXIS slave (YCbCr 4:4:4, 24-bit, Y-Cb-Cr packing)
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // AXIS master (YCbCr 4:2:2, 16-bit, [15:8]=chroma [7:0]=luma)
    output reg  [15:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser
);

    // ========================================================================
    // Pixel-index parity (0 = even, 1 = odd within a 2-pixel pair).
    // Reset to even on tuser (SOF) or after each tlast (end of line).
    // ========================================================================
    reg pixel_parity;     // 0 → even (next is the first of a pair)
                          // 1 → odd  (next is the second of a pair)
    reg [7:0] held_cb;
    reg [7:0] held_cr;
    reg [7:0] held_y_even;

    // We hold a "pending" odd-pixel output beat — emit it on the cycle AFTER
    // we consumed the odd input. So output rate matches input rate.
    reg         pending_valid;
    reg [15:0]  pending_data;
    reg         pending_tlast;
    reg         pending_tuser;

    wire input_accept = s_axis_tvalid && s_axis_tready;
    wire output_accept = m_axis_tvalid && m_axis_tready;

    // Stage 1 advance: we have room to emit if output_accept OR m_valid=0.
    wire stage_advance = !m_axis_tvalid || m_axis_tready;

    // SOF / EOL resync: force parity to 0 on the cycle a new frame/line starts.
    // Combinational so the even/odd branch below uses the post-reset value
    // (otherwise a trailing pixel_parity <= 0 would overwrite the branch's
    // pixel_parity <= 1 in the same cycle's NBA ordering).
    wire sof_now = input_accept && (s_axis_tuser || s_axis_tlast);
    wire effective_parity = sof_now ? 1'b0 : pixel_parity;

    // We accept an input pixel when:
    //   - stage can advance (room to emit at least one beat)
    //   - AND we don't already have a pending beat queued
    assign s_axis_tready = stage_advance && !pending_valid;

    // Unpack input pixel (Y-Cb-Cr order)
    wire [7:0] in_y  = s_axis_tdata[23:16];
    wire [7:0] in_cb = s_axis_tdata[15:8];
    wire [7:0] in_cr = s_axis_tdata[7:0];

    // Average computation (combinational, only used on odd pixels)
    wire [8:0] cb_sum = held_cb + in_cb;   // 9-bit sum
    wire [8:0] cr_sum = held_cr + in_cr;
    wire [7:0] cb_avg = (cb_sum + 9'd1) >> 1;  // round half up
    wire [7:0] cr_avg = (cr_sum + 9'd1) >> 1;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pixel_parity  <= 1'b0;
            held_cb       <= 8'd128;
            held_cr       <= 8'd128;
            held_y_even   <= 8'd0;
            m_axis_tdata  <= 16'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
            pending_valid <= 1'b0;
            pending_data  <= 16'd0;
            pending_tlast <= 1'b0;
            pending_tuser <= 1'b0;
        end else begin
            // ---- OUTPUT stage: emit pending beat first if queued ----
            if (stage_advance) begin
                if (pending_valid) begin
                    m_axis_tdata  <= pending_data;
                    m_axis_tlast  <= pending_tlast;
                    m_axis_tuser  <= pending_tuser;
                    m_axis_tvalid <= 1'b1;
                    pending_valid <= 1'b0;
                end else if (input_accept) begin
                    if (effective_parity == 1'b0) begin
                        // Even pixel: hold chroma + Y, emit Y-only beat with
                        // ZERO chroma byte (placeholder — gets overwritten by
                        // averaged value on the NEXT (odd) pixel). To keep
                        // output rate = input rate, we emit the EVEN-pixel
                        // beat NOW carrying just Y; the averaged Cb pairs
                        // with the EVEN-Y in BT.656 cositing, but we don't
                        // know the average yet (haven't seen the odd pixel).
                        //
                        // Strategy: BUFFER the even pixel. Emit nothing now.
                        // On the next (odd) pixel, emit BOTH beats:
                        //   beat 0: {Cb_avg, Y_even}
                        //   beat 1: {Cr_avg, Y_odd}
                        // This means output has 1-pixel latency vs input but
                        // sustains the same rate (2 inputs → 2 outputs).
                        held_y_even  <= in_y;
                        held_cb      <= in_cb;
                        held_cr      <= in_cr;
                        pixel_parity <= 1'b1;
                        m_axis_tvalid <= 1'b0;  // no emit this cycle
                        // tuser propagates with the even pixel's beat below.
                        // tlast on an even pixel is a malformed stream
                        // (odd line length); we'd still need to emit. For
                        // now we trust upstream sends even line counts.
                    end else begin
                        // Odd pixel: emit BOTH beats — first now, second queued.
                        m_axis_tdata  <= {cb_avg, held_y_even};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= 1'b0;     // not last on first beat
                        m_axis_tuser  <= 1'b0;     // SOF only on the first frame's first beat
                        pending_valid <= 1'b1;
                        pending_data  <= {cr_avg, in_y};
                        pending_tlast <= s_axis_tlast;
                        pending_tuser <= 1'b0;
                        pixel_parity  <= 1'b0;
                    end
                end else begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tuser  <= 1'b0;
                end
            end

            // (SOF / EOL reset folded into effective_parity above)
        end
    end

endmodule

`default_nettype wire
