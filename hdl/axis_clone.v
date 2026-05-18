// axis_clone.v — Replicate one AXIS stream into two identical outputs.
//
// Pure combinational fan-out with combined back-pressure: the source AXIS is
// only accepted when BOTH downstream consumers are ready. Each downstream
// only sees tvalid when the OTHER is also ready (so neither gets a "live"
// pixel that the other can't accept).
//
// Used by Mackin blender placeholder wiring: a single MM2S stream is cloned
// into the blender's s_curr and s_prev inputs. When curr == prev, diff == 0,
// the blender output equals curr regardless of alpha — a logical no-op,
// useful for verifying the module is structurally in the pipeline before
// a second MM2S source is added.
//
// 24-bit AXIS, tlast + tuser propagated.

`default_nettype none
`timescale 1ns / 1ps

module axis_clone (
    // Unused clock/reset — purely for BD clock-domain association on the
    // AXIS interfaces. Combinational fan-out; no FF inside this module.
    input  wire        aclk,
    input  wire        aresetn,

    // Slave (source)
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // Master 1
    output wire [23:0] m1_axis_tdata,
    output wire        m1_axis_tvalid,
    input  wire        m1_axis_tready,
    output wire        m1_axis_tlast,
    output wire        m1_axis_tuser,

    // Master 2
    output wire [23:0] m2_axis_tdata,
    output wire        m2_axis_tvalid,
    input  wire        m2_axis_tready,
    output wire        m2_axis_tlast,
    output wire        m2_axis_tuser
);

    // Source is consumed when both masters are ready
    assign s_axis_tready  = m1_axis_tready && m2_axis_tready;

    // Each master is valid only when source is valid AND the other master is ready
    assign m1_axis_tvalid = s_axis_tvalid && m2_axis_tready;
    assign m2_axis_tvalid = s_axis_tvalid && m1_axis_tready;

    // Data/last/user fan out identically
    assign m1_axis_tdata  = s_axis_tdata;
    assign m1_axis_tlast  = s_axis_tlast;
    assign m1_axis_tuser  = s_axis_tuser;

    assign m2_axis_tdata  = s_axis_tdata;
    assign m2_axis_tlast  = s_axis_tlast;
    assign m2_axis_tuser  = s_axis_tuser;

endmodule

`default_nettype wire
