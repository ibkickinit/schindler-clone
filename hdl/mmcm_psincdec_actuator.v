// mmcm_psincdec_actuator.v — Phase E1 Phase 4 MMCM phase-shift rate actuator.
//
// AXI-Lite-controlled fine-phase-shift driver for clk_wiz_pixclk_out's MMCM.
// A signed 32-bit `phase_step` register drives a Bresenham-style accumulator:
// every aclk cycle the accumulator grows by |phase_step|; on accumulator
// overflow the module asserts PSEN for one cycle (gated by PSDONE), with
// PSINCDEC = sign(phase_step). The cumulative phase walk produced by the
// stream of PSEN pulses appears at the MMCM output as a rate offset, range
// roughly ±100–500 ppm depending on MMCM PSDONE latency.
//
// This avoids the brief output disruption that full DRP / clk_wiz AXI-Lite
// reconfig would cause on every nudge; psincdec is the canonical glitch-free
// fine-tune mechanism for MMCM (see memory `xilinx_mmcm_psincdec_tracking`).
//
// Calibration is left to firmware / Phase 5 — the AXI register accepts an
// abstract "step" value, and Phase 5's plant sweep characterizes the
// step-to-ppm gain empirically.
//
// AXI-Lite slave register map (read-write):
//   0x00  phase_step     signed 32-bit. 0 = no phase shifting (idle).
//                          Positive = output advances (faster).
//                          Negative = output retards (slower).
//   0x04  status          bit 0: psdone (live, OK to write 0x00 anytime)
//                          bit 1: pulse_in_flight
//                          bits 31..16: 16-bit count of pulses emitted since reset
//
// CDC: PSEN/PSINCDEC/PSDONE all live in the aclk domain (s_axi_aclk =
// MMCM PSCLK = FCLK_CLK0). No synchronizer needed on this side.

`default_nettype none
`timescale 1ns / 1ps

module mmcm_psincdec_actuator #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 12       // 4 KB slave region
)(
    // Measurement clock — must equal the MMCM's PSCLK (here FCLK_CLK0 100 MHz).
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                              s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                              s_axi_aresetn,

    // Phase-shift handshake with the MMCM (same clock domain).
    output wire                              psen,
    output wire                              psincdec,
    input  wire                              psdone,

    // AXI4-Lite slave (full RW).
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]   s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2 : 0]                      s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                              s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                              s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [C_S_AXI_DATA_WIDTH-1 : 0]   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [C_S_AXI_DATA_WIDTH/8-1 : 0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                              s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                              s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1 : 0]                      s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                              s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                              s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1 : 0]   s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2 : 0]                      s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                              s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                              s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [C_S_AXI_DATA_WIDTH-1 : 0]   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1 : 0]                      s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                              s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                              s_axi_rready
);

    // -------------------------------------------------------------------------
    // Control register and Bresenham accumulator.
    // -------------------------------------------------------------------------
    reg signed [31:0] phase_step;           // CSR — written by PS
    reg        [31:0] accumulator;          // Bresenham phase accumulator
    reg               psen_pulse;           // 1-cycle PSEN strobe
    reg               psincdec_q;           // direction latched at pulse time
    reg               pulse_in_flight;      // waiting for PSDONE
    reg        [15:0] pulse_count;          // for visibility

    wire [31:0] step_abs = phase_step[31] ? (~phase_step + 32'd1) : phase_step;
    wire [32:0] accum_next = {1'b0, accumulator} + {1'b0, step_abs};
    wire        accum_carry = accum_next[32];

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            accumulator     <= 32'd0;
            psen_pulse      <= 1'b0;
            psincdec_q      <= 1'b0;
            pulse_in_flight <= 1'b0;
            pulse_count     <= 16'd0;
        end else begin
            // PSEN is a 1-cycle strobe. After the strobe, hold off until PSDONE.
            if (psen_pulse) begin
                psen_pulse      <= 1'b0;
                pulse_in_flight <= 1'b1;
            end else if (pulse_in_flight) begin
                // Wait for MMCM to report done before allowing the next pulse.
                if (psdone) begin
                    pulse_in_flight <= 1'b0;
                end
            end else if (step_abs != 32'd0) begin
                // Idle: keep accumulating. On overflow, emit a strobe.
                accumulator <= accum_next[31:0];
                if (accum_carry) begin
                    psen_pulse  <= 1'b1;
                    psincdec_q  <= ~phase_step[31];   // sign(phase_step): 0=dec, 1=inc
                    pulse_count <= pulse_count + 16'd1;
                end
            end
            // step_abs == 0 → idle, accumulator frozen, no pulses.
        end
    end

    assign psen     = psen_pulse;
    assign psincdec = psincdec_q;

    wire [31:0] status_word = {pulse_count, 14'd0, pulse_in_flight, psdone};

    // -------------------------------------------------------------------------
    // AXI4-Lite slave plumbing (RW on phase_step, RO on status).
    // -------------------------------------------------------------------------
    reg                              axi_awready;
    reg                              axi_wready;
    reg                              axi_bvalid;
    reg                              axi_arready;
    reg                              axi_rvalid;
    reg [C_S_AXI_DATA_WIDTH-1 : 0]   axi_rdata;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0]   axi_awaddr_q;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = 2'b00;
    assign s_axi_rvalid  = axi_rvalid;

    // ----- Write channel ----------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_awready  <= 1'b0;
            axi_wready   <= 1'b0;
            axi_bvalid   <= 1'b0;
            axi_awaddr_q <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            phase_step   <= 32'sd0;
        end else begin
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid && ~axi_bvalid) begin
                axi_awready  <= 1'b1;
                axi_wready   <= 1'b1;
                axi_awaddr_q <= s_axi_awaddr;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end
            if (axi_awready && axi_wready) begin
                axi_bvalid <= 1'b1;
                // Decode address: only 0x00 (phase_step) is writeable.
                if (axi_awaddr_q[4:2] == 3'h0) begin
                    phase_step <= $signed(s_axi_wdata);
                    // Reset accumulator so the rate change starts cleanly.
                    // (Done implicitly in the accumulator block on next cycle:
                    // step_abs changes, accumulator continues from current
                    // value — adequate for fine-tuning use case.)
                end
            end else if (axi_bvalid && s_axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // ----- Read channel -----------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end else begin
            if (~axi_arready && s_axi_arvalid && ~axi_rvalid) begin
                axi_arready <= 1'b1;
            end else begin
                axi_arready <= 1'b0;
            end
            if (axi_arready && s_axi_arvalid && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                case (s_axi_araddr[4:2])
                    3'h0: axi_rdata <= $unsigned(phase_step);
                    3'h1: axi_rdata <= status_word;
                    default: axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && s_axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // Suppress unused-input lint
    wire _unused = &{1'b0, s_axi_awprot, s_axi_arprot, s_axi_wstrb,
                     s_axi_awaddr[C_S_AXI_ADDR_WIDTH-1:5],
                     s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:5]};

endmodule

`default_nettype wire
