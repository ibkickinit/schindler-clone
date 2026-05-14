// phase_b_top.v — top-level wrapper around the BD + the polyphase scaler.
//
// The Phase B BD couldn't directly hold the polyphase scaler as a BD
// module-reference cell — Vivado's OOC synth flow leaves the cell as a
// black box at impl_1's link_design step (DRC INBB-3) when the module
// has sub-modules (scaler_h / scaler_v / scaler_coeffs_*). Workaround:
// expose the AXIS path as external BD ports and instantiate scaler_top
// here, between the BD's video_out and S2MM input. All other BD ports
// pass through unchanged.

`default_nettype none
`timescale 1ns / 1ps

module phase_b_top (
    inout  wire [14:0] DDR_addr,
    inout  wire [ 2:0] DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [ 3:0] DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [ 3:0] DDR_dqs_n,
    inout  wire [ 3:0] DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,
    input  wire        btn_rst,
    inout  wire        hdmi_rx_ddc_scl_io,
    inout  wire        hdmi_rx_ddc_sda_io,
    output wire        hdmi_rx_hpd,
    input  wire        hdmi_rx_tmds_clk_n,
    input  wire        hdmi_rx_tmds_clk_p,
    input  wire [ 2:0] hdmi_rx_tmds_data_n,
    input  wire [ 2:0] hdmi_rx_tmds_data_p,
    input  wire        hdmi_tx_hpd,
    output wire        hdmi_tx_tmds_clk_n,
    output wire        hdmi_tx_tmds_clk_p,
    output wire [ 2:0] hdmi_tx_tmds_data_n,
    output wire [ 2:0] hdmi_tx_tmds_data_p,
    output wire [ 3:0] leds,
    input  wire        sys_clk
);
    // Scaler interconnect — exposed from BD, processed by scaler_top.
    wire        pixel_clk;
    wire        pixel_rstn;
    wire [23:0] m_to_scaler_tdata;
    wire        m_to_scaler_tvalid;
    wire        m_to_scaler_tready;
    wire        m_to_scaler_tlast;
    wire        m_to_scaler_tuser;
    wire [23:0] s_from_scaler_tdata;
    wire        s_from_scaler_tvalid;
    wire        s_from_scaler_tready;
    wire        s_from_scaler_tlast;
    wire        s_from_scaler_tuser;

    phase_b_bd_wrapper bd_inst (
        .DDR_addr            (DDR_addr),
        .DDR_ba              (DDR_ba),
        .DDR_cas_n           (DDR_cas_n),
        .DDR_ck_n            (DDR_ck_n),
        .DDR_ck_p            (DDR_ck_p),
        .DDR_cke             (DDR_cke),
        .DDR_cs_n            (DDR_cs_n),
        .DDR_dm              (DDR_dm),
        .DDR_dq              (DDR_dq),
        .DDR_dqs_n           (DDR_dqs_n),
        .DDR_dqs_p           (DDR_dqs_p),
        .DDR_odt             (DDR_odt),
        .DDR_ras_n           (DDR_ras_n),
        .DDR_reset_n         (DDR_reset_n),
        .DDR_we_n            (DDR_we_n),
        .FIXED_IO_ddr_vrn    (FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp    (FIXED_IO_ddr_vrp),
        .FIXED_IO_mio        (FIXED_IO_mio),
        .FIXED_IO_ps_clk     (FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb    (FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb   (FIXED_IO_ps_srstb),
        .btn_rst             (btn_rst),
        .hdmi_rx_ddc_scl_io  (hdmi_rx_ddc_scl_io),
        .hdmi_rx_ddc_sda_io  (hdmi_rx_ddc_sda_io),
        .hdmi_rx_hpd         (hdmi_rx_hpd),
        .hdmi_rx_tmds_clk_n  (hdmi_rx_tmds_clk_n),
        .hdmi_rx_tmds_clk_p  (hdmi_rx_tmds_clk_p),
        .hdmi_rx_tmds_data_n (hdmi_rx_tmds_data_n),
        .hdmi_rx_tmds_data_p (hdmi_rx_tmds_data_p),
        .hdmi_tx_hpd         (hdmi_tx_hpd),
        .hdmi_tx_tmds_clk_n  (hdmi_tx_tmds_clk_n),
        .hdmi_tx_tmds_clk_p  (hdmi_tx_tmds_clk_p),
        .hdmi_tx_tmds_data_n (hdmi_tx_tmds_data_n),
        .hdmi_tx_tmds_data_p (hdmi_tx_tmds_data_p),
        .leds                (leds),
        .sys_clk             (sys_clk),
        // Scaler-side external ports (BD outputs the un-scaled AXIS; takes
        // the scaled AXIS back; pixel_clk and pixel_rstn are PixelClk_in
        // domain signals exposed for the scaler):
        .pixel_clk_out                       (pixel_clk),
        .pixel_rstn_out                      (pixel_rstn),
        .m_video_to_scaler_tdata             (m_to_scaler_tdata),
        .m_video_to_scaler_tvalid            (m_to_scaler_tvalid),
        .m_video_to_scaler_tready            (m_to_scaler_tready),
        .m_video_to_scaler_tlast             (m_to_scaler_tlast),
        .m_video_to_scaler_tuser             (m_to_scaler_tuser),
        .scaled_from_scaler_tdata            (s_from_scaler_tdata),
        .scaled_from_scaler_tvalid           (s_from_scaler_tvalid),
        .scaled_from_scaler_tready           (s_from_scaler_tready),
        .scaled_from_scaler_tlast            (s_from_scaler_tlast),
        .scaled_from_scaler_tuser            (s_from_scaler_tuser)
    );

    scaler_top scaler_inst (
        .aclk          (pixel_clk),
        .aresetn       (pixel_rstn),
        .s_axis_tdata  (m_to_scaler_tdata),
        .s_axis_tvalid (m_to_scaler_tvalid),
        .s_axis_tready (m_to_scaler_tready),
        .s_axis_tlast  (m_to_scaler_tlast),
        .s_axis_tuser  (m_to_scaler_tuser),
        .m_axis_tdata  (s_from_scaler_tdata),
        .m_axis_tvalid (s_from_scaler_tvalid),
        .m_axis_tready (s_from_scaler_tready),
        .m_axis_tlast  (s_from_scaler_tlast),
        .m_axis_tuser  (s_from_scaler_tuser)
    );
endmodule

`default_nettype wire
