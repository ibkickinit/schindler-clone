// tpg_input.v — Built-in test pattern generator at input timing.
//
// Generates AXIS pixel stream synthesizing a video source. Inserted via a
// runtime mux UPSTREAM of the scaler so all downstream processing (scaler,
// VDMA, color pipeline, mackin blender, output encoders) sees a synthetic
// known-good source. No HDMI input needed for any testing.
//
// "Built-in ImagePro" — UART/GPIO selects:
//   - Pattern (0..7): bars, solid, gradient, crosshatch, dot, counter, sweep, wedge
//   - Motion enable
//   - Effective frame rate (1..255 Hz divisor over native 60 Hz)
//   - Solid color (for pattern 1)
//
// Output: AXIS 24-bit, R-B-G byte order (matches pipeline convention).
// tlast asserts on the last active pixel of each line (column = frame_w-1).
// tuser asserts on the first active pixel of each frame (row=0, col=0).
//
// Timing: free-running at aclk rate. Total cycles per frame = frame_w * frame_h
// (no blanking — pure active video). At 148.5 MHz with 1920x1080 = 2073600
// pixels/frame -> ~71.6 Hz. The frame_rate_div input slows this by repeating
// frames internally (motion held constant), so the apparent rate is
// 71.6/frame_rate_div Hz. For "60 Hz feel" with downstream VTC sync, the
// downstream pipeline will retime via VDMA.
//
// (Strictly: this TPG is not vsync-locked to any external timing. It just
// runs as fast as aclk allows. The pipeline's VDMA + VTC handle rate
// matching to the output side.)

`default_nettype none
`timescale 1ns / 1ps

module tpg_input #(
    parameter integer FRAME_W = 1920,
    parameter integer FRAME_H = 1080
) (
    input  wire        aclk,
    input  wire        aresetn,

    // Control inputs (async, GPIO-fed; CDC handled internally)
    input  wire [2:0]  pattern_sel_async,    // 0..7 pattern enum
    input  wire        motion_en_async,
    input  wire [7:0]  frame_rate_div_async, // 1=full speed, N=1/N speed
    input  wire [23:0] solid_color_async,    // R-B-G for pattern 1

    // AXIS master
    output reg  [23:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    input  wire        m_axis_tready,
    output reg         m_axis_tlast,
    output reg         m_axis_tuser
);

    // ====================================================================
    // CDC: 2-FF synchronizers on control inputs
    // ====================================================================
    (* ASYNC_REG = "TRUE" *) reg [2:0]  pattern_sel_q1, pattern_sel_q2;
    (* ASYNC_REG = "TRUE" *) reg        motion_en_q1, motion_en_q2;
    (* ASYNC_REG = "TRUE" *) reg [7:0]  frate_q1, frate_q2;
    (* ASYNC_REG = "TRUE" *) reg [23:0] solid_q1, solid_q2;

    always @(posedge aclk) begin
        if (!aresetn) begin
            pattern_sel_q1 <= 3'd0; pattern_sel_q2 <= 3'd0;
            motion_en_q1   <= 1'b0; motion_en_q2   <= 1'b0;
            frate_q1       <= 8'd1; frate_q2       <= 8'd1;
            solid_q1       <= 24'h808080;  solid_q2 <= 24'h808080;
        end else begin
            pattern_sel_q1 <= pattern_sel_async;  pattern_sel_q2 <= pattern_sel_q1;
            motion_en_q1   <= motion_en_async;    motion_en_q2   <= motion_en_q1;
            frate_q1       <= frame_rate_div_async; frate_q2     <= frate_q1;
            solid_q1       <= solid_color_async;  solid_q2       <= solid_q1;
        end
    end

    // ====================================================================
    // Pixel + line + frame counters
    // ====================================================================
    reg [11:0] col;   // 0..FRAME_W-1
    reg [11:0] row;   // 0..FRAME_H-1
    reg [31:0] frame_count_native;   // every output frame
    reg [31:0] frame_count_logical;  // increments every frate_div native frames
    reg [7:0]  frame_rate_phase;     // mod-frate counter

    wire end_of_frame = (col == FRAME_W-1) && (row == FRAME_H-1);
    wire end_of_line  = (col == FRAME_W-1);

    wire pixel_accept = m_axis_tready;  // tvalid always 1 below

    always @(posedge aclk) begin
        if (!aresetn) begin
            col <= 12'd0;
            row <= 12'd0;
            frame_count_native  <= 32'd0;
            frame_count_logical <= 32'd0;
            frame_rate_phase    <= 8'd0;
        end else if (pixel_accept) begin
            if (end_of_frame) begin
                col <= 12'd0;
                row <= 12'd0;
                frame_count_native <= frame_count_native + 32'd1;
                // Logical frame tick happens every frate_div native frames.
                // frame_count_logical is what motion logic uses.
                if (frame_rate_phase + 1 >= frate_q2) begin
                    frame_rate_phase    <= 8'd0;
                    frame_count_logical <= frame_count_logical + 32'd1;
                end else begin
                    frame_rate_phase <= frame_rate_phase + 8'd1;
                end
            end else if (end_of_line) begin
                col <= 12'd0;
                row <= row + 12'd1;
            end else begin
                col <= col + 12'd1;
            end
        end
    end

    // ====================================================================
    // Bouncing dot state (pattern 4)
    // ====================================================================
    // Dot is 64x64, bounces edge-to-edge. Position updates per LOGICAL
    // frame when motion_en is 1.
    reg [11:0] dot_x;
    reg [11:0] dot_y;
    reg        dot_dx;   // 0=right, 1=left
    reg        dot_dy;   // 0=down, 1=up
    parameter integer DOT_SIZE = 64;
    parameter integer DOT_SPEED = 8;   // pixels per logical frame

    // Detect logical-frame tick (rising edge on frame_count_logical[0])
    reg [31:0] frame_logical_prev;
    wire logical_tick = (frame_count_logical != frame_logical_prev);

    always @(posedge aclk) begin
        if (!aresetn) begin
            dot_x <= 12'd400;
            dot_y <= 12'd300;
            dot_dx <= 1'b0;
            dot_dy <= 1'b0;
            frame_logical_prev <= 32'd0;
        end else begin
            frame_logical_prev <= frame_count_logical;
            if (motion_en_q2 && logical_tick) begin
                // X movement
                if (dot_dx == 1'b0) begin
                    if (dot_x + DOT_SIZE + DOT_SPEED >= FRAME_W) begin
                        dot_dx <= 1'b1;
                    end else begin
                        dot_x <= dot_x + DOT_SPEED;
                    end
                end else begin
                    if (dot_x <= DOT_SPEED) begin
                        dot_dx <= 1'b0;
                    end else begin
                        dot_x <= dot_x - DOT_SPEED;
                    end
                end
                // Y movement
                if (dot_dy == 1'b0) begin
                    if (dot_y + DOT_SIZE + DOT_SPEED >= FRAME_H) begin
                        dot_dy <= 1'b1;
                    end else begin
                        dot_y <= dot_y + DOT_SPEED;
                    end
                end else begin
                    if (dot_y <= DOT_SPEED) begin
                        dot_dy <= 1'b0;
                    end else begin
                        dot_y <= dot_y - DOT_SPEED;
                    end
                end
            end
        end
    end

    // ====================================================================
    // Sweep bar state (pattern 6) — vertical line scrolls horizontally
    // ====================================================================
    reg [11:0] sweep_x;
    parameter integer SWEEP_SPEED = 16;
    always @(posedge aclk) begin
        if (!aresetn) begin
            sweep_x <= 12'd0;
        end else if (motion_en_q2 && logical_tick) begin
            if (sweep_x + SWEEP_SPEED >= FRAME_W) sweep_x <= 12'd0;
            else                                  sweep_x <= sweep_x + SWEEP_SPEED;
        end
    end

    // ====================================================================
    // Pattern generation (combinational, per pixel)
    // ====================================================================
    // Output is 24-bit R-B-G packed:  {R, B, G}

    // ---- Pattern 0: SMPTE 75% bars ----
    // 7 vertical bars, equal width (FRAME_W / 7 each). Colors at 75%:
    //   white (191,191,191), yellow (191,191,0), cyan (0,191,191),
    //   green (0,191,0), magenta (191,0,191), red (191,0,0), blue (0,0,191)
    wire [11:0] bar_w = FRAME_W / 7;
    wire [2:0]  bar_idx = (col < bar_w*1) ? 3'd0 :
                          (col < bar_w*2) ? 3'd1 :
                          (col < bar_w*3) ? 3'd2 :
                          (col < bar_w*4) ? 3'd3 :
                          (col < bar_w*5) ? 3'd4 :
                          (col < bar_w*6) ? 3'd5 : 3'd6;
    reg [7:0] bars_r, bars_g, bars_b;
    always @(*) begin
        case (bar_idx)
            3'd0: begin bars_r=8'd191; bars_g=8'd191; bars_b=8'd191; end // white
            3'd1: begin bars_r=8'd191; bars_g=8'd191; bars_b=8'd0;   end // yellow
            3'd2: begin bars_r=8'd0;   bars_g=8'd191; bars_b=8'd191; end // cyan
            3'd3: begin bars_r=8'd0;   bars_g=8'd191; bars_b=8'd0;   end // green
            3'd4: begin bars_r=8'd191; bars_g=8'd0;   bars_b=8'd191; end // magenta
            3'd5: begin bars_r=8'd191; bars_g=8'd0;   bars_b=8'd0;   end // red
            default: begin bars_r=8'd0;bars_g=8'd0;   bars_b=8'd191; end // blue
        endcase
    end

    // ---- Pattern 1: solid color ----
    wire [7:0] solid_r = solid_q2[23:16];
    wire [7:0] solid_b = solid_q2[15:8];
    wire [7:0] solid_g = solid_q2[7:0];

    // ---- Pattern 2: horizontal gradient (col → 0..255) ----
    wire [7:0] hgrad = col[10:3];   // col / 8 -> 0..(FRAME_W/8-1), clip to 8-bit

    // ---- Pattern 3: vertical gradient (row → 0..255) ----
    wire [7:0] vgrad = row[10:3];

    // ---- Pattern 4: bouncing dot (white on black background) ----
    wire in_dot = (col >= dot_x) && (col < dot_x + DOT_SIZE) &&
                  (row >= dot_y) && (row < dot_y + DOT_SIZE);

    // ---- Pattern 5: crosshatch grid (white lines every 64 px, on black) ----
    wire in_xhatch = (col[5:0] == 6'd0) || (row[5:0] == 6'd0);

    // ---- Pattern 6: sweep bar (vertical white line moves horizontally) ----
    wire in_sweep = (col >= sweep_x) && (col < sweep_x + 12'd8);

    // ---- Pattern 7: frame counter overlay on bars background ----
    // 8 digits, each 32x48 px, displayed top-left (rows 0..47, cols 0..255).
    // Each digit = 4 bits of frame_count_logical[31:0] modulo 10 — for simplicity
    // just show each NIBBLE of the hex counter rendered as a coarse 5-segment.
    // (Approximate: doesn't aim for clean numerals — just visibly changing
    // bit-pattern blocks.)
    wire in_counter_area = (row < 12'd48) && (col < 12'd256);
    wire [2:0] digit_idx_x = col[7:5];   // 8 columns of digits, 32px each
    wire [3:0] nibble = (digit_idx_x == 3'd0) ? frame_count_logical[31:28] :
                        (digit_idx_x == 3'd1) ? frame_count_logical[27:24] :
                        (digit_idx_x == 3'd2) ? frame_count_logical[23:20] :
                        (digit_idx_x == 3'd3) ? frame_count_logical[19:16] :
                        (digit_idx_x == 3'd4) ? frame_count_logical[15:12] :
                        (digit_idx_x == 3'd5) ? frame_count_logical[11:8]  :
                        (digit_idx_x == 3'd6) ? frame_count_logical[7:4]   :
                                                frame_count_logical[3:0];
    // 4x4 sub-block within a 32x48 digit cell (use col[4:3] for x, row[5:4] for y)
    wire [1:0] sub_x = col[4:3];
    wire [1:0] sub_y = row[5:4];
    // Render nibble bit by sub_y row: top row = bit 3, then 2, 1, 0 in subsequent rows.
    wire bit_lit = (sub_y == 2'd0) ? nibble[3] :
                   (sub_y == 2'd1) ? nibble[2] :
                   (sub_y == 2'd2) ? nibble[1] : nibble[0];
    wire counter_pixel_on = in_counter_area && bit_lit && (sub_x != 2'd3);

    // ====================================================================
    // Final pixel mux based on pattern_sel_q2
    // ====================================================================
    reg [7:0] pix_r, pix_g, pix_b;
    always @(*) begin
        case (pattern_sel_q2)
            3'd0: begin // SMPTE bars
                pix_r = bars_r; pix_g = bars_g; pix_b = bars_b;
            end
            3'd1: begin // solid color
                pix_r = solid_r; pix_g = solid_g; pix_b = solid_b;
            end
            3'd2: begin // h gradient (luma ramp)
                pix_r = hgrad; pix_g = hgrad; pix_b = hgrad;
            end
            3'd3: begin // v gradient
                pix_r = vgrad; pix_g = vgrad; pix_b = vgrad;
            end
            3'd4: begin // bouncing dot
                pix_r = in_dot ? 8'd255 : 8'd0;
                pix_g = in_dot ? 8'd255 : 8'd0;
                pix_b = in_dot ? 8'd255 : 8'd0;
            end
            3'd5: begin // crosshatch
                pix_r = in_xhatch ? 8'd255 : 8'd0;
                pix_g = in_xhatch ? 8'd255 : 8'd0;
                pix_b = in_xhatch ? 8'd255 : 8'd0;
            end
            3'd6: begin // sweep bar
                pix_r = in_sweep ? 8'd255 : 8'd32;  // dim background
                pix_g = in_sweep ? 8'd255 : 8'd32;
                pix_b = in_sweep ? 8'd255 : 8'd32;
            end
            3'd7: begin // frame counter overlay on bars background
                if (counter_pixel_on) begin
                    pix_r = 8'd255; pix_g = 8'd255; pix_b = 8'd0; // yellow
                end else begin
                    pix_r = bars_r; pix_g = bars_g; pix_b = bars_b;
                end
            end
        endcase
    end

    // ====================================================================
    // AXIS output register
    // ====================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= 24'd0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            // Always valid (free-running); downstream tready throttles
            m_axis_tvalid <= 1'b1;
            // R-B-G byte order to match Schindler pipeline convention
            m_axis_tdata  <= {pix_r, pix_b, pix_g};
            m_axis_tlast  <= end_of_line;
            m_axis_tuser  <= (col == 12'd0) && (row == 12'd0);
        end
    end

endmodule

`default_nettype wire
