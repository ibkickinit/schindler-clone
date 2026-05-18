// axis_mux_2to1.v — Runtime-selectable AXIS source mux.
//
// Routes either s0 or s1 to the master output based on `sel_async`.
// Used for the TPG injection: sel=0 picks HDMI-derived stream (s0),
// sel=1 picks TPG-generated stream (s1).
//
// The UN-selected source sees its tready always 0 (it pauses; that's fine
// for the TPG since it's free-running but back-pressured, and the HDMI
// source naturally pauses if v_vid_in_axi4s is back-pressured).
//
// Pure combinational mux. CDC on `sel_async` is internal — actual switching
// is reset-domain-clean because of the synchronizer.

`default_nettype none
`timescale 1ns / 1ps

module axis_mux_2to1 (
    input  wire        aclk,
    input  wire        aresetn,

    input  wire        sel_async,    // 0 -> s0 selected; 1 -> s1 selected

    // Slave 0
    input  wire [23:0] s0_tdata,
    input  wire        s0_tvalid,
    output wire        s0_tready,
    input  wire        s0_tlast,
    input  wire        s0_tuser,

    // Slave 1
    input  wire [23:0] s1_tdata,
    input  wire        s1_tvalid,
    output wire        s1_tready,
    input  wire        s1_tlast,
    input  wire        s1_tuser,

    // Master
    output wire [23:0] m_tdata,
    output wire        m_tvalid,
    input  wire        m_tready,
    output wire        m_tlast,
    output wire        m_tuser
);
    // CDC 2-FF on sel
    (* ASYNC_REG = "TRUE" *) reg sel_q1, sel_q2;
    always @(posedge aclk) begin
        if (!aresetn) begin
            sel_q1 <= 1'b0; sel_q2 <= 1'b0;
        end else begin
            sel_q1 <= sel_async; sel_q2 <= sel_q1;
        end
    end

    // Selected source -> master
    assign m_tdata  = sel_q2 ? s1_tdata  : s0_tdata;
    assign m_tvalid = sel_q2 ? s1_tvalid : s0_tvalid;
    assign m_tlast  = sel_q2 ? s1_tlast  : s0_tlast;
    assign m_tuser  = sel_q2 ? s1_tuser  : s0_tuser;

    // Only the selected source sees real tready
    assign s0_tready = sel_q2 ? 1'b0 : m_tready;
    assign s1_tready = sel_q2 ? m_tready : 1'b0;
endmodule

`default_nettype wire
