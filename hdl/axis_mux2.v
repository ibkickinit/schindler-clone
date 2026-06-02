// axis_mux2.v — 2:1 AXI-Stream mux (24-bit pixel), runtime select.
//
// Route-B integration: selects which producer feeds the color stack →
// axis_to_vid_io.  sel=0 → s0 (VDMA MM2S, proven full-size passthrough,
// the default at boot → zero regression). sel=1 → s1 (pg_read_engine_top,
// runtime geometry). The unselected input is back-pressured (tready=0).
//
// Single clock domain (output pixel clock). sel is a slow GPIO bit; it
// should only be toggled between frames (firmware does so during vblank).

`default_nettype none
`timescale 1ns / 1ps

module axis_mux2 (
    input  wire        clk,
    input  wire        sel,            // 0 = s0, 1 = s1 (from AXI GPIO, async)

    input  wire [23:0] s0_tdata,
    input  wire        s0_tvalid,
    output wire        s0_tready,

    input  wire [23:0] s1_tdata,
    input  wire        s1_tvalid,
    output wire        s1_tready,

    output wire [23:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready
);
    // sel arrives from a slow GPIO in the FCLK_CLK0 domain; synchronize into the
    // pixel-clock domain before it fans out to the 24-bit data mux (else it is a
    // CDC path into the whole color datapath → huge negative slack). Firmware
    // toggles sel only between frames, so a 2-FF sync is sufficient. XDC
    // false-paths sel_q1_reg/D.
    (* ASYNC_REG = "TRUE" *) reg sel_q1, sel_q2;
    always @(posedge clk) begin sel_q1 <= sel; sel_q2 <= sel_q1; end

    assign m_tdata   = sel_q2 ? s1_tdata  : s0_tdata;
    assign m_tvalid  = sel_q2 ? s1_tvalid : s0_tvalid;
    // DRAIN BOTH inputs (do NOT back-pressure the unselected one). If the idle
    // input is back-pressured, the VDMA MM2S slave parks → S2MM (Dynamic Master)
    // skips the parked slots → only ~2 ring slots rotate, the rest freeze, and
    // any independent reader (the read-engine) lands on the frozen slots. Keeping
    // both consumers advancing at the output rate keeps S2MM's 5-slot rotation
    // clean. The unselected input's data is simply discarded.
    assign s0_tready = m_tready;
    assign s1_tready = m_tready;
endmodule

`default_nettype wire
