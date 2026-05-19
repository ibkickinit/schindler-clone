// vsync_timestamp.v — Phase E1 Phase 1 measurement instrument.
//
// One free-running 48-bit counter on s_axi_aclk (100 MHz, FCLK_CLK0). Two
// edge-capture registers latch the counter on rising edges of two async
// vsync inputs (ref_vsync_async, out_vsync_async). Two 32-bit edge counters
// track total edges seen since reset (firmware coherence check).
//
// AXI-Lite slave, read-only register file (writes accepted and discarded
// with OKAY response). Eight 32-bit registers at the slave's base:
//
//   0x00  counter[31:0]
//   0x04  {16'h0, counter[47:32]}
//   0x08  ts_ref[31:0]            (timestamp of last ref-vsync rising edge)
//   0x0C  {16'h0, ts_ref[47:32]}
//   0x10  ts_out[31:0]            (timestamp of last out-vsync rising edge)
//   0x14  {16'h0, ts_out[47:32]}
//   0x18  ts_ref_count            (total ref edges since reset)
//   0x1C  ts_out_count            (total out edges since reset)
//
// Coherence note: 48-bit values are read as two 32-bit transactions, so
// LSB/MSB can straddle a counter update. Firmware reads (ts_ref_count, LSB,
// MSB) and re-reads ts_ref_count; if unchanged, the pair is coherent. For
// the free-running counter, firmware reads MSB→LSB→MSB and accepts if MSB
// matches (LSB-rollover detected). Standard idiom — keeps the slave simple.
//
// CDC: each vsync input gets a 3-FF synchronizer chain (ASYNC_REG=TRUE) and
// a rising-edge detect comparing the last two stages. Capture latency from
// "true edge in source domain" to "counter latched" is ~2 s_axi_aclk cycles
// = 20 ns. Identical for both inputs, so the bias cancels when computing
// ts_out - ts_ref. Residual jitter bounded by 1 aclk tick = 10 ns, which is
// far below the spike's sub-line target (one 720p output line ≈ 13.5 µs).

`default_nettype none
`timescale 1ns / 1ps

module vsync_timestamp #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 12      // 4 KB slave region
)(
    // Measurement clock (must be free-running, stable, NOT the modulated
    // output pixel clock). Use FCLK_CLK0 at 100 MHz.
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn" *)
    input  wire                              s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                              s_axi_aresetn,

    // Asynchronous vsync inputs (any clock domain).
    input  wire                              ref_vsync_async,
    input  wire                              out_vsync_async,

    // AXI4-Lite slave interface (read-only, writes accepted+discarded).
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
    // Free-running counter + edge captures (all in s_axi_aclk domain).
    // -------------------------------------------------------------------------
    reg [47:0] counter;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) counter <= 48'd0;
        else                counter <= counter + 1'b1;
    end

    // 3-FF synchronizer per vsync input. Stages [0]/[1] guard against
    // metastability; stage [2] is for the edge-detect compare.
    (* ASYNC_REG = "TRUE" *) reg [2:0] ref_sync;
    (* ASYNC_REG = "TRUE" *) reg [2:0] out_sync;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            ref_sync <= 3'b0;
            out_sync <= 3'b0;
        end else begin
            ref_sync <= {ref_sync[1:0], ref_vsync_async};
            out_sync <= {out_sync[1:0], out_vsync_async};
        end
    end

    wire ref_rise = ref_sync[1] & ~ref_sync[2];
    wire out_rise = out_sync[1] & ~out_sync[2];

    reg [47:0] ts_ref, ts_out;
    reg [31:0] ts_ref_count, ts_out_count;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            ts_ref       <= 48'd0;
            ts_out       <= 48'd0;
            ts_ref_count <= 32'd0;
            ts_out_count <= 32'd0;
        end else begin
            if (ref_rise) begin
                ts_ref       <= counter;
                ts_ref_count <= ts_ref_count + 1'b1;
            end
            if (out_rise) begin
                ts_out       <= counter;
                ts_out_count <= ts_out_count + 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite slave plumbing (read-only register file).
    //
    // Write channel: accept any AW+W transaction, return OKAY, discard data.
    // Keeps the slave AXI-protocol-compliant without per-register write logic.
    //
    // Read channel: classic two-phase — latch AR address, drive R one cycle
    // later with decoded register data.
    // -------------------------------------------------------------------------
    reg                              axi_awready;
    reg                              axi_wready;
    reg                              axi_bvalid;
    reg                              axi_arready;
    reg                              axi_rvalid;
    reg [C_S_AXI_DATA_WIDTH-1 : 0]   axi_rdata;
    reg [C_S_AXI_ADDR_WIDTH-1 : 0]   axi_araddr;

    assign s_axi_awready = axi_awready;
    assign s_axi_wready  = axi_wready;
    assign s_axi_bresp   = 2'b00;     // OKAY
    assign s_axi_bvalid  = axi_bvalid;
    assign s_axi_arready = axi_arready;
    assign s_axi_rdata   = axi_rdata;
    assign s_axi_rresp   = 2'b00;     // OKAY
    assign s_axi_rvalid  = axi_rvalid;

    // ----- Write channel (no-op) --------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_awready <= 1'b0;
            axi_wready  <= 1'b0;
            axi_bvalid  <= 1'b0;
        end else begin
            // Single-cycle ready when both AW and W are valid and the slave
            // isn't holding a pending response.
            if (~axi_awready && s_axi_awvalid && s_axi_wvalid && ~axi_bvalid) begin
                axi_awready <= 1'b1;
                axi_wready  <= 1'b1;
            end else begin
                axi_awready <= 1'b0;
                axi_wready  <= 1'b0;
            end
            // BVALID asserts the cycle after the handshake, holds until BREADY.
            if (axi_awready && axi_wready) begin
                axi_bvalid <= 1'b1;
            end else if (axi_bvalid && s_axi_bready) begin
                axi_bvalid <= 1'b0;
            end
        end
    end

    // ----- Read channel ------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= {C_S_AXI_DATA_WIDTH{1'b0}};
            axi_araddr  <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (~axi_arready && s_axi_arvalid && ~axi_rvalid) begin
                axi_arready <= 1'b1;
                axi_araddr  <= s_axi_araddr;
            end else begin
                axi_arready <= 1'b0;
            end

            if (axi_arready && s_axi_arvalid && ~axi_rvalid) begin
                axi_rvalid <= 1'b1;
                // Decode the low 5 bits of the latched address (8 regs × 4 B).
                case (s_axi_araddr[4:2])
                    3'h0: axi_rdata <= counter[31:0];
                    3'h1: axi_rdata <= {16'h0, counter[47:32]};
                    3'h2: axi_rdata <= ts_ref[31:0];
                    3'h3: axi_rdata <= {16'h0, ts_ref[47:32]};
                    3'h4: axi_rdata <= ts_out[31:0];
                    3'h5: axi_rdata <= {16'h0, ts_out[47:32]};
                    3'h6: axi_rdata <= ts_ref_count;
                    3'h7: axi_rdata <= ts_out_count;
                    default: axi_rdata <= 32'h0;
                endcase
            end else if (axi_rvalid && s_axi_rready) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

    // Suppress unused-input lint
    wire _unused = &{1'b0, s_axi_awprot, s_axi_arprot, s_axi_wdata, s_axi_wstrb,
                     s_axi_awaddr[C_S_AXI_ADDR_WIDTH-1:0], axi_araddr};

endmodule

`default_nettype wire
