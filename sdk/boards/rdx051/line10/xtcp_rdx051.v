// RDX051 near-USB port, lane 0. Connect an Ethernet peer with matching rate and FEC.
module xtcp_rdx051 #(
    parameter integer PROFILE = 0,
    parameter [47:0] LOCAL_MAC = 48'h025100030011 + PROFILE,
    parameter [31:0] LOCAL_IP = 32'hC0A80A0B + PROFILE,
    parameter [15:0] TCP_PORT = 16'd24,
    parameter [15:0] RBCP_PORT = 16'd4660
)(
    input wire gt_refclk_p, gt_refclk_n,
    input wire gt_rxp, gt_rxn,
    output wire gt_txp, gt_txn,
    output wire [1:0] qsfp_reset_n, qsfp_lpmode, qsfp_modsel_n,
    input wire [1:0] qsfp_present_n, qsfp_int_n,
    inout wire [1:0] qsfp_scl, qsfp_sda,
    output wire [1:0] ddr_reset_n
);
    localparam integer PORT_ID = 0;
    wire dclk, xgmii_clk, rx_status_clk;
    wire [7:0] rxc, txc;
    wire [63:0] rxd, txd;
    wire user_rx_reset, user_tx_reset, powergood;
    wire block_lock, rx_status, hi_ber, rx_fault, tx_fault;
    wire sys_reset, line_reset;
    reg [24:0] startup_count = 25'd0;
    reg [31:0] reference_ticks = 32'd0;
    always @(posedge dclk) begin
        reference_ticks <= reference_ticks + 1'b1;
        if (!startup_count[24]) startup_count <= startup_count + 1'b1;
    end
    assign sys_reset = !startup_count[24]; // 107 ms at 156.25 MHz.
    wire app_reset_request = sys_reset | user_tx_reset;
    (* ASYNC_REG = "TRUE" *) reg [3:0] reset_sync = 4'hf;
    always @(posedge xgmii_clk or posedge app_reset_request)
        if (app_reset_request) reset_sync <= 4'hf;
        else reset_sync <= {reset_sync[2:0], 1'b0};
    assign line_reset = reset_sync[3];

    assign qsfp_reset_n = PORT_ID == 0 ? {1'b1, !sys_reset} : {!sys_reset, 1'b1};
    assign qsfp_lpmode = PORT_ID == 0 ? 2'b10 : 2'b01;
    assign qsfp_modsel_n = PORT_ID == 0 ? 2'b10 : 2'b01;
    assign qsfp_scl = 2'bzz;
    assign qsfp_sda = 2'bzz;
    assign ddr_reset_n = 2'b00;

    rdx_phy phy (
        .gt_rxp_in_0(gt_rxp), .gt_rxn_in_0(gt_rxn),
        .gt_txp_out_0(gt_txp), .gt_txn_out_0(gt_txn),
        .gt_refclk_p(gt_refclk_p), .gt_refclk_n(gt_refclk_n),
        .gt_refclk_out(dclk), .dclk(dclk), .sys_reset(sys_reset),
        .tx_mii_clk_0(xgmii_clk), .rx_core_clk_0(xgmii_clk),
        .txoutclksel_in_0(3'b101), .rxoutclksel_in_0(3'b101),
        .gtwiz_reset_tx_datapath_0(sys_reset), .gtwiz_reset_rx_datapath_0(sys_reset),
        .rxrecclkout_0(), .rx_clk_out_0(rx_status_clk), .gtpowergood_out_0(powergood),
        .rx_reset_0(sys_reset), .tx_reset_0(sys_reset),
        .user_rx_reset_0(user_rx_reset), .user_tx_reset_0(user_tx_reset),
        .rx_mii_d_0(rxd), .rx_mii_c_0(rxc), .tx_mii_d_0(txd), .tx_mii_c_0(txc),
        .ctl_rx_test_pattern_0(1'b0), .ctl_rx_data_pattern_select_0(1'b0),
        .ctl_rx_test_pattern_enable_0(1'b0), .ctl_rx_prbs31_test_pattern_enable_0(1'b0),
        .stat_rx_framing_err_0(), .stat_rx_framing_err_valid_0(),
        .stat_rx_local_fault_0(rx_fault), .stat_rx_block_lock_0(block_lock),
        .stat_rx_valid_ctrl_code_0(), .stat_rx_status_0(rx_status), .stat_rx_hi_ber_0(hi_ber),
        .stat_rx_bad_code_0(), .stat_rx_bad_code_valid_0(), .stat_rx_error_0(),
        .stat_rx_error_valid_0(), .stat_rx_fifo_error_0(), .stat_tx_local_fault_0(tx_fault),
        .ctl_tx_test_pattern_0(1'b0), .ctl_tx_test_pattern_enable_0(1'b0),
        .ctl_tx_test_pattern_select_0(1'b0), .ctl_tx_data_pattern_select_0(1'b0),
        .ctl_tx_test_pattern_seed_a_0(58'd0), .ctl_tx_test_pattern_seed_b_0(58'd0),
        .ctl_tx_prbs31_test_pattern_enable_0(1'b0), .gt_loopback_in_0(3'b000),
        .qpllreset_in_0(sys_reset), .ctl_rx_wdt_disable_0(1'b0)
    );
    wire app_reset, established, close_req, close_ack, tx_afull;
    wire [31:0] rbcp_addr;
    wire rbcp_we, rbcp_re, rbcp_ack;
    wire [7:0] rbcp_wd, rbcp_rd;
    wire [63:0] tx_data, rx_write_data;
    wire [3:0] tx_bytes;
    localparam integer RX_ADDR_BITS=18;
    wire [RX_ADDR_BITS-1:0] rx_size, rx_raddr, rx_waddr;
    wire [7:0] rx_write_enable;
    wire rx_clear_enable;
`ifdef XTCP_BD
    xtcp_design tcp (
`elsif XTCP_CATALOG
    xtcp_customized tcp (
`else
    xtcp #(.PROFILE(PROFILE), .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
           .TCP_PORT(TCP_PORT), .RBCP_PORT(RBCP_PORT)) tcp (
`endif
        .APP_CLK(xgmii_clk), .APP_RST(line_reset), .LINE_CLK(xgmii_clk), .LINE_RST(line_reset),
        .XGMII_RXC(rxc), .XGMII_RXD(rxd), .XGMII_TXC(txc), .XGMII_TXD(txd),
        .APP_RESET_OUT(app_reset), .RBCP_ACT(), .RBCP_ADDR(rbcp_addr),
        .RBCP_WE(rbcp_we), .RBCP_WD(rbcp_wd), .RBCP_RE(rbcp_re),
        .RBCP_ACK(rbcp_ack), .RBCP_RD(rbcp_rd),
        .USER_SESSION_ESTABLISHED(established), .USER_SESSION_CLOSE_REQ(close_req),
        .USER_SESSION_CLOSE_ACK(close_ack), .USER_TX_D(tx_data), .USER_TX_B(tx_bytes),
        .USER_TX_AFULL(tx_afull), .USER_RX_SIZE(rx_size), .USER_RX_CLR_ENB(rx_clear_enable),
        .USER_RX_RADR(rx_raddr), .USER_RX_WADR(rx_waddr),
        .USER_RX_WENB(rx_write_enable), .USER_RX_WDAT(rx_write_data)
    );
    // PG210: RX status belongs to rx_clk_out, TX status to tx_mii_clk.
    // Register each source before crossing: stat_rx_status can be combinational.
    reg [3:0] rx_levels = 0;
    reg tx_fault_level = 0;
    always @(posedge rx_status_clk)
        rx_levels <= {rx_fault, hi_ber, rx_status, block_lock};
    always @(posedge xgmii_clk)
        tx_fault_level <= tx_fault;
    // user_rx_reset is already synchronized by the wrapper to rx_core_clk
    // (xgmii_clk here), NOT rx_clk_out. user_tx_reset includes the asynchronous
    // startup reset; sample it only through the level synchronizers below.
    // Only independent level flags cross here; no packet counter crosses clocks.
    wire [15:0] raw_flags = {2'b00, qsfp_int_n, qsfp_present_n, sys_reset,
        line_reset, user_tx_reset, user_rx_reset, powergood,
        tx_fault_level, rx_levels};
    (* ASYNC_REG = "TRUE" *) reg [15:0] flag_meta = 0, flag_sync = 0;
    always @(posedge xgmii_clk) begin flag_meta <= raw_flags; flag_sync <= flag_meta; end
    xtcp_example_app #(.PROFILE(PROFILE), .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
           .TCP_PORT(TCP_PORT), .RBCP_PORT(RBCP_PORT)) application (
        .clk(xgmii_clk), .reset(app_reset), .rbcp_addr(rbcp_addr),
        .rbcp_we(rbcp_we), .rbcp_re(rbcp_re), .rbcp_wd(rbcp_wd),
        .rbcp_ack(rbcp_ack), .rbcp_rd(rbcp_rd), .established(established),
        .close_req(close_req), .tx_afull(tx_afull), .close_ack(close_ack),
        .tx_data(tx_data), .tx_bytes(tx_bytes), .rx_size(rx_size), .rx_raddr(rx_raddr),
        .rx_clear_enable(rx_clear_enable),
        .rx_waddr(rx_waddr), .rx_write_enable(rx_write_enable), .rx_write_data(rx_write_data),
        .status_flags(flag_sync)
    );
    reg app_heartbeat = 0;
    reg [23:0] app_ticks = 0;
    // The independent core decodes its session state combinationally. Register
    // this observation in the source clock before the VIO-domain synchronizer.
    reg established_level = 0;
    always @(posedge xgmii_clk) begin
        established_level <= established;
        app_ticks <= app_ticks + 1'b1;
        if (&app_ticks) app_heartbeat <= !app_heartbeat;
    end
    (* ASYNC_REG = "TRUE" *) reg [18:0] debug_meta = 0, debug_sync = 0;
    always @(posedge dclk) begin
        // Register the line reset once in the free-running debug domain.
        debug_meta <= {app_heartbeat, established_level, 1'b0, raw_flags};
        debug_sync <= debug_meta;
    end
    wire [31:0] debug_word = {reference_ticks[31:24], 4'd0, (PORT_ID != 0),
        debug_sync[18:17], debug_sync[8], debug_sync[15:0]};
    rdx_status_vio status_probe (.clk(dclk), .probe_in0(debug_word));
endmodule
