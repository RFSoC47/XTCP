// Single 25GMII line clock. Complete-frame FIFOs join the 64-bit MAC to the
// 128-bit transport clock. RX cannot stop the wire; on overflow a whole frame drops.
module xtcp_g25_wide_mac_bridge(
    input wire line_clk,line_rst,core_clk,core_rst,
    input wire [63:0] rxd,input wire [7:0] rxc,output wire [63:0] txd,output wire [7:0] txc,
    output wire [127:0] rx_data,output wire [15:0] rx_keep,output wire rx_valid,rx_last,rx_bad,
    input wire [127:0] tx_data,input wire [15:0] tx_keep,input wire tx_valid,tx_last,output wire tx_ready,
    output wire rx_overflow_event,output wire tx_underflow_event
);
    wire [63:0] rx64,tx64;
    wire [7:0] rk64,tk64;
    wire rv,rl,rb,tv,tl,tr,underflow_line;
    axis_xgmii_rx_64 mac_rx(.clk(line_clk),.rst(line_rst),.xgmii_rxd(rxd),.xgmii_rxc(rxc),
        .m_axis_tdata(rx64),.m_axis_tkeep(rk64),.m_axis_tvalid(rv),.m_axis_tlast(rl),.m_axis_tuser(rb),
        .ptp_ts(96'd0),.cfg_rx_enable(1'b1),.start_packet(),.error_bad_frame(),.error_bad_fcs());
    axis_xgmii_tx_64 mac_tx(.clk(line_clk),.rst(line_rst),.s_axis_tdata(tx64),.s_axis_tkeep(tk64),
        .s_axis_tvalid(tv),.s_axis_tready(tr),.s_axis_tlast(tl),.s_axis_tuser(1'b0),
        .xgmii_txd(txd),.xgmii_txc(txc),.ptp_ts(96'd0),.m_axis_ptp_ts(),.m_axis_ptp_ts_tag(),
        .m_axis_ptp_ts_valid(),.cfg_ifg(8'd12),.cfg_tx_enable(1'b1),.start_packet(),.error_underflow(underflow_line));
    axis_async_fifo_adapter #(.DEPTH(8192),.S_DATA_WIDTH(64),.M_DATA_WIDTH(128),
        .FRAME_FIFO(1),.DROP_OVERSIZE_FRAME(1),.DROP_BAD_FRAME(0),.DROP_WHEN_FULL(1),.RAM_PIPELINE(2))
    receive_fifo(.s_clk(line_clk),.s_rst(line_rst),.s_axis_tdata(rx64),.s_axis_tkeep(rk64),.s_axis_tvalid(rv),
        .s_axis_tready(),.s_axis_tlast(rl),.s_axis_tid(8'd0),.s_axis_tdest(8'd0),.s_axis_tuser(rb),
        .m_clk(core_clk),.m_rst(core_rst),.m_axis_tdata(rx_data),.m_axis_tkeep(rx_keep),.m_axis_tvalid(rx_valid),
        .m_axis_tready(1'b1),.m_axis_tlast(rx_last),.m_axis_tuser(rx_bad),.s_pause_req(1'b0),.m_pause_req(1'b0),
        .m_status_overflow(rx_overflow_event));
    axis_async_fifo_adapter #(.DEPTH(4096),.S_DATA_WIDTH(128),.M_DATA_WIDTH(64),
        .FRAME_FIFO(1),.DROP_OVERSIZE_FRAME(1),.DROP_BAD_FRAME(0),.DROP_WHEN_FULL(0),.RAM_PIPELINE(2))
    transmit_fifo(.s_clk(core_clk),.s_rst(core_rst),.s_axis_tdata(tx_data),.s_axis_tkeep(tx_keep),.s_axis_tvalid(tx_valid),
        .s_axis_tready(tx_ready),.s_axis_tlast(tx_last),.s_axis_tid(8'd0),.s_axis_tdest(8'd0),.s_axis_tuser(1'b0),
        .m_clk(line_clk),.m_rst(line_rst),.m_axis_tdata(tx64),.m_axis_tkeep(tk64),.m_axis_tvalid(tv),.m_axis_tready(tr),
        .m_axis_tlast(tl),.s_pause_req(1'b0),.m_pause_req(1'b0));
    xpm_cdc_pulse #(.DEST_SYNC_FF(3),.INIT_SYNC_FF(0),.REG_OUTPUT(1),.RST_USED(1),.SIM_ASSERT_CHK(1))
    underflow_cross(.src_clk(line_clk),.src_rst(line_rst),.src_pulse(underflow_line),
        .dest_clk(core_clk),.dest_rst(core_rst),.dest_pulse(tx_underflow_event));
endmodule
