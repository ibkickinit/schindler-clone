// scaler_passthrough.v — Phase C.0 plumbing verification.
//
// Identity pass-through scaler — 1-cycle AXIS pipeline register, no scaling.
// Sits between v_vid_in_axi4s_0/video_out and axi_vdma_0/S_AXIS_S2MM in the
// Phase B BD. Replaced by the real polyphase scaler_top in Phase C.1+.
//
// Goals for C.0:
//   1. Confirm BD insertion / port naming works without breaking the AXIS chain
//   2. Confirm picture is identical to Phase B output (this is an identity op)
//   3. Establish a single registered AXIS stage so Phase C.1's real scaler
//      starts from a known-clean timing reference
//
// Port-name convention `s_axis_*`/`m_axis_*` lets Vivado auto-detect the
// AXIS interfaces in the BD canvas.

`default_nettype none
`timescale 1ns / 1ps

module scaler_passthrough #(
    parameter integer DATA_WIDTH = 24
) (
    input  wire                    aclk,
    input  wire                    aresetn,

    // AXIS slave (from v_vid_in_axi4s)
    input  wire [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire                    s_axis_tvalid,
    output wire                    s_axis_tready,
    input  wire                    s_axis_tlast,
    input  wire                    s_axis_tuser,

    // AXIS master (to VDMA S2MM)
    output reg  [DATA_WIDTH-1:0]   m_axis_tdata,
    output reg                     m_axis_tvalid,
    input  wire                    m_axis_tready,
    output reg                     m_axis_tlast,
    output reg                     m_axis_tuser
);

    // Simple register stage. Slave-side ready when output stage is empty
    // or about to be drained — standard 1-deep AXIS register without
    // skid (downstream VDMA has its own input FIFO so this is fine).
    assign s_axis_tready = !m_axis_tvalid || m_axis_tready;

    always @(posedge aclk) begin
        if (!aresetn) begin
            m_axis_tdata  <= {DATA_WIDTH{1'b0}};
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tuser  <= 1'b0;
        end else begin
            if (s_axis_tvalid && s_axis_tready) begin
                m_axis_tdata  <= s_axis_tdata;
                m_axis_tlast  <= s_axis_tlast;
                m_axis_tuser  <= s_axis_tuser;
                m_axis_tvalid <= 1'b1;
            end else if (m_axis_tvalid && m_axis_tready) begin
                m_axis_tvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
