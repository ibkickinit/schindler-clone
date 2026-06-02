// pg_linefetch.v — present-geometry line fetch + double buffer (read-engine-B, M3).
//
// Encapsulates the "real memory" part of the read-engine: fetch a master line
// from DDR and serve its pixels by column, with a 2-line ping-pong buffer so
// the next source row prefetches while the current one is being read out.
//
// Contract with the compositor (pg_compose, M4):
//   - The compositor must keep the engine AT MOST ONE ROW AHEAD: prefetch the
//     next source row (pf_req/pf_row) only once the current row is the serving
//     row. With 2 buffers this guarantees the fill target is never the buffer
//     being read. (At frame start the compositor prefetches rows 0 and 1 during
//     vblank before any read — both buffers fill, neither is being read yet.)
//   - rd_row/rd_col query the resident line; rd_data is registered (1-cycle).
//   - rd_resident tells the compositor the queried row is present (else stall).
//
// DDR side is a DataMover-style command/stream interface: pulse fetch_req with
// {addr,len}; the fetch unit streams len pixels back on fetch_pvalid, asserting
// fetch_last on the final pixel. In HW this drives a Xilinx AXI DataMover (MM2S)
// + a 64b→24b unpacker; in sim a behavioral model serves from a frame array.

`default_nettype none
`timescale 1ns / 1ps

module pg_linefetch #(
    parameter integer LINE_W = 1280,   // master line width (pixels)
    parameter integer STRIDE = 3840    // master line stride (bytes) = LINE_W*3
) (
    input  wire        clk,
    input  wire        rstn,

    input  wire [31:0] frame_base_addr,  // base of the frame slot in DDR

    // prefetch request (compositor → engine): ensure src row pf_row is resident
    input  wire        pf_req,
    input  wire [11:0] pf_row,

    // pixel read (compositor → engine)
    input  wire [11:0] rd_row,
    input  wire [11:0] rd_col,
    output reg  [23:0] rd_data,        // registered (valid 1 cycle after rd_col)
    output reg         rd_resident,    // combinational: rd_row present & valid

    // DDR fetch (DataMover-style)
    output reg         fetch_req,
    output reg [31:0]  fetch_addr,
    output reg [11:0]  fetch_len,
    input  wire        fetch_pvalid,
    input  wire [23:0] fetch_pdata,
    input  wire        fetch_last,

    output wire        busy           // debug: fetch in progress
);
    reg [23:0] buf0 [0:LINE_W-1];
    reg [23:0] buf1 [0:LINE_W-1];
    reg [11:0] tag0, tag1;
    reg        val0, val1;
    reg        fill_sel;     // which buffer the NEXT fetch fills (ping-pong)

    localparam S_IDLE = 1'b0, S_FILL = 1'b1;
    reg        state;
    reg [11:0] fill_idx;
    reg        fill_buf;     // buffer being filled by the in-progress fetch
    assign busy = (state == S_FILL);

    wire have_row = ((pf_row == tag0) && val0) || ((pf_row == tag1) && val1);

    // registered read: pick the buffer whose tag matches rd_row
    always @(posedge clk) begin
        if (rd_row == tag0) rd_data <= buf0[rd_col];
        else                rd_data <= buf1[rd_col];
    end
    always @* rd_resident = ((rd_row == tag0) && val0) || ((rd_row == tag1) && val1);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; fetch_req <= 1'b0;
            fill_sel <= 1'b0; fill_buf <= 1'b0; fill_idx <= 12'd0;
            val0 <= 1'b0; val1 <= 1'b0;
            tag0 <= 12'hFFF; tag1 <= 12'hFFE;   // impossible rows → never falsely resident
            fetch_addr <= 32'd0; fetch_len <= 12'd0;
        end else begin
            fetch_req <= 1'b0;
            case (state)
                S_IDLE:
                    if (pf_req && !have_row) begin
                        fill_buf   <= fill_sel;
                        if (fill_sel == 1'b0) begin tag0 <= pf_row; val0 <= 1'b0; end
                        else                  begin tag1 <= pf_row; val1 <= 1'b0; end
                        fetch_addr <= frame_base_addr + pf_row * STRIDE;
                        fetch_len  <= LINE_W[11:0];
                        fetch_req  <= 1'b1;
                        fill_idx   <= 12'd0;
                        state      <= S_FILL;
                    end
                S_FILL:
                    if (fetch_pvalid) begin
                        if (fill_buf == 1'b0) buf0[fill_idx] <= fetch_pdata;
                        else                  buf1[fill_idx] <= fetch_pdata;
                        fill_idx <= fill_idx + 12'd1;
                        if (fetch_last) begin
                            if (fill_buf == 1'b0) val0 <= 1'b1; else val1 <= 1'b1;
                            fill_sel <= ~fill_sel;
                            state    <= S_IDLE;
                        end
                    end
            endcase
        end
    end
endmodule

`default_nettype wire
