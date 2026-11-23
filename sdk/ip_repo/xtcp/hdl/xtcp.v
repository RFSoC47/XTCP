// XTCP IPv4 endpoint. Network identity and the line profile are elaboration-time parameters.
// APP_CLK is the transport and user clock. For 10G connect both clock/reset pairs to the same domain.
module xtcp #(
    parameter integer PROFILE = 0,
    parameter [47:0] LOCAL_MAC = 48'h025100030001,
    parameter [31:0] LOCAL_IP = 32'hC0A80A0A,
    parameter [15:0] TCP_PORT = 16'd24,
    parameter [15:0] RBCP_PORT = 16'd4660
)(
    input  wire APP_CLK,
    input  wire APP_RST,
    input  wire LINE_CLK,
    input  wire LINE_RST,
    input  wire [63:0] XGMII_RXD,
    input  wire [7:0] XGMII_RXC,
    output wire [63:0] XGMII_TXD,
    output wire [7:0] XGMII_TXC,
    output wire APP_RESET_OUT,
    output wire RBCP_ACT,
    output wire [31:0] RBCP_ADDR,
    output wire RBCP_WE,
    output wire RBCP_RE,
    output wire [7:0] RBCP_WD,
    input  wire RBCP_ACK,
    input  wire [7:0] RBCP_RD,
    output wire USER_SESSION_ESTABLISHED,
    output wire USER_SESSION_CLOSE_REQ,
    input  wire USER_SESSION_CLOSE_ACK,
    input  wire [(PROFILE==0 ? 63 : 127):0] USER_TX_D,
    input  wire [(PROFILE==0 ? 3 : 4):0] USER_TX_B,
    output wire USER_TX_AFULL,
    input  wire [(PROFILE==0 ? 17 : 18):0] USER_RX_SIZE,
    input  wire [(PROFILE==0 ? 17 : 18):0] USER_RX_RADR,
    output wire USER_RX_CLR_ENB,
    output wire [(PROFILE==0 ? 17 : 18):0] USER_RX_WADR,
    output wire [(PROFILE==0 ? 7 : 15):0] USER_RX_WENB,
    output wire [(PROFILE==0 ? 63 : 127):0] USER_RX_WDAT
);
    generate
        if (PROFILE == 0) begin : g10
            xtcp_g10_tcp_core #(
                .LOCAL_MAC(LOCAL_MAC),
                .LOCAL_IP(LOCAL_IP),
                .TCP_PORT(TCP_PORT),
                .RBCP_PORT(RBCP_PORT),
                .RX_ADDR_BITS(18),
                .LOSS_GUARD_DEFAULT(16)
            ) engine (
                .XGMII_CLOCK(APP_CLK),
                .RSTs(APP_RST),
                .XGMII_RXD(XGMII_RXD),
                .XGMII_RXC(XGMII_RXC),
                .XGMII_TXD(XGMII_TXD),
                .XGMII_TXC(XGMII_TXC),
                .APP_RESET_OUT(APP_RESET_OUT),
                .RBCP_ACT(RBCP_ACT),
                .RBCP_ADDR(RBCP_ADDR),
                .RBCP_WE(RBCP_WE),
                .RBCP_RE(RBCP_RE),
                .RBCP_WD(RBCP_WD),
                .RBCP_ACK(RBCP_ACK),
                .RBCP_RD(RBCP_RD),
                .USER_SESSION_ESTABLISHED(USER_SESSION_ESTABLISHED),
                .USER_SESSION_CLOSE_REQ(USER_SESSION_CLOSE_REQ),
                .USER_SESSION_CLOSE_ACK(USER_SESSION_CLOSE_ACK),
                .USER_TX_D(USER_TX_D),
                .USER_TX_B(USER_TX_B),
                .USER_TX_AFULL(USER_TX_AFULL),
                .USER_RX_SIZE(USER_RX_SIZE),
                .USER_RX_RADR(USER_RX_RADR),
                .USER_RX_CLR_ENB(USER_RX_CLR_ENB),
                .USER_RX_WADR(USER_RX_WADR),
                .USER_RX_WENB(USER_RX_WENB),
                .USER_RX_WDAT(USER_RX_WDAT),
                .USER_SESSION_OPEN_REQ(1'b0),
                .USER_RX_CLR_REQ(1'b0)
            );
        end else if (PROFILE == 1) begin : g25
            xtcp_g25_tcp_core #(
                .LOCAL_MAC(LOCAL_MAC),
                .LOCAL_IP(LOCAL_IP),
                .TCP_PORT(TCP_PORT),
                .RBCP_PORT(RBCP_PORT),
                .RX_ADDR_BITS(19),
                .LOSS_GUARD_DEFAULT(16),
                .CLOCK_HZ(195312500),
                .CORE_REVISION(8'd14)
            ) engine (
                .XGMII_CLOCK(APP_CLK),
                .RSTs(APP_RST),
                .LINE_CLOCK(LINE_CLK),
                .LINE_RST(LINE_RST),
                .XGMII_RXD(XGMII_RXD),
                .XGMII_RXC(XGMII_RXC),
                .XGMII_TXD(XGMII_TXD),
                .XGMII_TXC(XGMII_TXC),
                .APP_RESET_OUT(APP_RESET_OUT),
                .RBCP_ACT(RBCP_ACT),
                .RBCP_ADDR(RBCP_ADDR),
                .RBCP_WE(RBCP_WE),
                .RBCP_RE(RBCP_RE),
                .RBCP_WD(RBCP_WD),
                .RBCP_ACK(RBCP_ACK),
                .RBCP_RD(RBCP_RD),
                .USER_SESSION_ESTABLISHED(USER_SESSION_ESTABLISHED),
                .USER_SESSION_CLOSE_REQ(USER_SESSION_CLOSE_REQ),
                .USER_SESSION_CLOSE_ACK(USER_SESSION_CLOSE_ACK),
                .USER_TX_D(USER_TX_D),
                .USER_TX_B(USER_TX_B),
                .USER_TX_AFULL(USER_TX_AFULL),
                .USER_RX_SIZE(USER_RX_SIZE),
                .USER_RX_RADR(USER_RX_RADR),
                .USER_RX_CLR_ENB(USER_RX_CLR_ENB),
                .USER_RX_WADR(USER_RX_WADR),
                .USER_RX_WENB(USER_RX_WENB),
                .USER_RX_WDAT(USER_RX_WDAT),
                .USER_SESSION_OPEN_REQ(1'b0),
                .USER_RX_CLR_REQ(1'b0)
            );
        end else if (PROFILE == 2) begin : jumbo
            xtcp_jumbo_tcp_core #(
                .LOCAL_MAC(LOCAL_MAC),
                .LOCAL_IP(LOCAL_IP),
                .TCP_PORT(TCP_PORT),
                .RBCP_PORT(RBCP_PORT),
                .RX_ADDR_BITS(19),
                .LOSS_GUARD_DEFAULT(16),
                .CLOCK_HZ(195312500),
                .CORE_REVISION(8'd18)
            ) engine (
                .XGMII_CLOCK(APP_CLK),
                .RSTs(APP_RST),
                .LINE_CLOCK(LINE_CLK),
                .LINE_RST(LINE_RST),
                .XGMII_RXD(XGMII_RXD),
                .XGMII_RXC(XGMII_RXC),
                .XGMII_TXD(XGMII_TXD),
                .XGMII_TXC(XGMII_TXC),
                .APP_RESET_OUT(APP_RESET_OUT),
                .RBCP_ACT(RBCP_ACT),
                .RBCP_ADDR(RBCP_ADDR),
                .RBCP_WE(RBCP_WE),
                .RBCP_RE(RBCP_RE),
                .RBCP_WD(RBCP_WD),
                .RBCP_ACK(RBCP_ACK),
                .RBCP_RD(RBCP_RD),
                .USER_SESSION_ESTABLISHED(USER_SESSION_ESTABLISHED),
                .USER_SESSION_CLOSE_REQ(USER_SESSION_CLOSE_REQ),
                .USER_SESSION_CLOSE_ACK(USER_SESSION_CLOSE_ACK),
                .USER_TX_D(USER_TX_D),
                .USER_TX_B(USER_TX_B),
                .USER_TX_AFULL(USER_TX_AFULL),
                .USER_RX_SIZE(USER_RX_SIZE),
                .USER_RX_RADR(USER_RX_RADR),
                .USER_RX_CLR_ENB(USER_RX_CLR_ENB),
                .USER_RX_WADR(USER_RX_WADR),
                .USER_RX_WENB(USER_RX_WENB),
                .USER_RX_WDAT(USER_RX_WDAT),
                .USER_SESSION_OPEN_REQ(1'b0),
                .USER_RX_CLR_REQ(1'b0)
            );
        end
    endgenerate
    // synthesis translate_off
    initial begin
        if (PROFILE < 0 || PROFILE > 2) $error("Unsupported XTCP profile");
        if (LOCAL_MAC[40] || LOCAL_MAC == 0) $error("XTCP requires a nonzero unicast MAC");
    end
    // synthesis translate_on
endmodule
