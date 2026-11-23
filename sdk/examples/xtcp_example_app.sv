// Reference data source, sink, echo ring and byte-wide control peripheral.
// The first TCP payload byte occupies the most significant byte lane.
module xtcp_example_app #(
    parameter integer PROFILE = 0,
    parameter [47:0] LOCAL_MAC = 48'h025100030001,
    parameter [31:0] LOCAL_IP = 32'hC0A80A0A,
    parameter [15:0] TCP_PORT = 16'd24,
    parameter [15:0] RBCP_PORT = 16'd4660,
    parameter integer BYTES = PROFILE == 0 ? 8 : 16,
    parameter integer ADDR_BITS = PROFILE == 0 ? 18 : 19,
    parameter integer COUNT_BITS = PROFILE == 0 ? 4 : 5
)(
    input wire clk, reset,
    input wire [31:0] rbcp_addr,
    input wire rbcp_we, rbcp_re,
    input wire [7:0] rbcp_wd,
    output reg rbcp_ack, output reg [7:0] rbcp_rd,
    input wire established, close_req, tx_afull,
    output wire close_ack,
    output reg [BYTES*8-1:0] tx_data, output reg [COUNT_BITS-1:0] tx_bytes,
    output wire [ADDR_BITS-1:0] rx_size, output reg [ADDR_BITS-1:0] rx_raddr,
    input wire rx_clear_enable, input wire [ADDR_BITS-1:0] rx_waddr,
    input wire [BYTES-1:0] rx_write_enable, input wire [BYTES*8-1:0] rx_write_data,
    input wire [15:0] status_flags
);
    localparam integer SHIFT = $clog2(BYTES);
    localparam integer RATE_LIMIT = PROFILE == 0 ? 100 : 250;
    localparam [31:0] APP_VERSION = 32'h01000010 + PROFILE;
    reg [7:0] mode, rate;
    reg [63:0] length;
    wire echo = mode[6];
    wire source = mode[0] && !echo;
    assign close_ack = close_req;
    assign rx_size = (1 << ADDR_BITS) - 16;

    // A ring entry is released after its bytes have been captured for local use.
    wire [ADDR_BITS-1:0] available = rx_waddr-rx_raddr;
    wire [COUNT_BITS-1:0] row_room = BYTES-rx_raddr[SHIFT-1:0];
    wire [COUNT_BITS-1:0] read_bytes = available < row_room ? available[COUNT_BITS-1:0] : row_room;
    wire clear_ring = rx_clear_enable && !established;
    wire consume = established && !clear_ring && (!echo || !tx_afull) && available!=0;
    reg [SHIFT-1:0] read_offset;
    reg [COUNT_BITS-1:0] echo_count;
    wire [BYTES*8-1:0] read_word;
    for (genvar i=0; i<BYTES; i=i+1) begin : receive_lanes
        (* ram_style="block" *) reg [7:0] memory[0:(1<<(ADDR_BITS-SHIFT))-1];
        reg [7:0] read_data, forward_data;
        reg forward;
        always @(posedge clk) begin
            if (rx_write_enable[i]) memory[rx_waddr[ADDR_BITS-1:SHIFT]] <= rx_write_data[8*i+:8];
            read_data <= memory[rx_raddr[ADDR_BITS-1:SHIFT]];
            forward <= rx_write_enable[i] && rx_waddr[ADDR_BITS-1:SHIFT]==rx_raddr[ADDR_BITS-1:SHIFT];
            forward_data <= rx_write_data[i*8+:8];
        end
        assign read_word[i*8+:8] = forward ? forward_data : read_data;
    end
    always @(posedge clk) begin
        if (reset) begin rx_raddr<=0; echo_count<=0; read_offset<=0; end
        else begin
            echo_count <= consume && echo ? read_bytes : 0;
            read_offset <= rx_raddr[SHIFT-1:0];
            if (clear_ring) rx_raddr <= rx_waddr;
            else if (consume) rx_raddr <= rx_raddr + read_bytes;
        end
    end

    // Bytes 1..255 repeat. The final beat may contain fewer than BYTES bytes.
    reg [63:0] remaining;
    reg [7:0] first_byte;
    wire [COUNT_BITS-1:0] emit_count = remaining < BYTES ? remaining[COUNT_BITS-1:0] : BYTES;
    wire [BYTES*8-1:0] source_word;
    for (genvar j=0; j<BYTES; j=j+1) begin : source_lanes
        wire [8:0] value = {1'b0,first_byte} + j;
        assign source_word[(BYTES-j)*8-1-:8] = value > 255 ? value-255 : value[7:0];
    end
    wire [8:0] next_byte = {1'b0,first_byte} + emit_count;
    reg [15:0] tokens;
    wire [15:0] credit = tokens + ((rate > RATE_LIMIT ? RATE_LIMIT : rate) << SHIFT);
    wire [15:0] cost = emit_count * RATE_LIMIT;
    wire emit = source && !tx_afull && remaining!=0 && credit>=cost;
    wire [15:0] next_tokens = emit ? credit-cost : credit;
    always @(posedge clk) begin
        if (reset || !established) begin
            remaining <= length; first_byte<=1; tokens<=0; tx_bytes<=0; tx_data<=0;
        end else begin
            tx_bytes <= 0;
            if (echo) begin tx_bytes<=echo_count; tx_data<=read_word<<{read_offset,3'b000}; end
            if (emit) begin
                tx_bytes<=emit_count; tx_data<=source_word; remaining<=remaining-emit_count;
                first_byte<=next_byte>255 ? next_byte-255 : next_byte[7:0];
            end
            tokens <= source ? (next_tokens>8192 ? 8192 : next_tokens) : 0;
        end
    end

    // 0x108 snapshots application byte counts and link flags as one transaction.
    // Multibyte control registers and snapshots use network byte order.
    reg [63:0] sent, consumed, stalled, cycles;
    reg [31:0] sessions, snapshot_id;
    reg [15:0] sticky;
    reg previous_established;
    reg [383:0] snapshot;
    wire [143:0] identity = {32'h58544350,LOCAL_MAC,LOCAL_IP,TCP_PORT,RBCP_PORT};
    always @(posedge clk) begin
        if (reset) begin
            mode<=0; rate<=RATE_LIMIT; length<=0; rbcp_ack<=0; rbcp_rd<=0;
            sent<=0; consumed<=0; stalled<=0; cycles<=0; sessions<=0;
            snapshot_id<=0; previous_established<=0; sticky<=0; snapshot<=0;
        end else begin
            cycles<=cycles+1'b1; previous_established<=established; sticky<=sticky|status_flags;
            if (consume) consumed<=consumed+read_bytes;
            if (established) begin
                sent<=sent+tx_bytes;
                if (tx_afull) stalled<=stalled+1'b1;
                if (!previous_established) sessions<=sessions+1'b1;
            end
            rbcp_ack <= (rbcp_we||rbcp_re) && rbcp_addr<32'h200;
            rbcp_rd <= 0;
            if (rbcp_we) begin
                if (rbcp_addr==4 && !established) mode<=rbcp_wd & 8'h41;
                if (rbcp_addr==16 && !established) rate<=rbcp_wd;
                if (rbcp_addr>=24 && rbcp_addr<32 && !established)
                    length[63-rbcp_addr[2:0]*8-:8]<=rbcp_wd;
                if (rbcp_addr==32'h108 && rbcp_wd[0]) begin
                    snapshot_id<=snapshot_id+1'b1;
                    snapshot<={sent,consumed,stalled,cycles,sessions,snapshot_id+32'd1,32'd0,sticky,status_flags};
                end
            end
            if (rbcp_re) begin
                if (rbcp_addr<4) rbcp_rd<=APP_VERSION[31-8*rbcp_addr[1:0]-:8];
                else if (rbcp_addr==4) rbcp_rd<=mode;
                else if (rbcp_addr==16) rbcp_rd<=rate;
                else if (rbcp_addr>=24 && rbcp_addr<32) rbcp_rd<=length[63-8*rbcp_addr[2:0]-:8];
                else if (rbcp_addr>=32'h40 && rbcp_addr<32'h52) rbcp_rd<=identity[143-8*(rbcp_addr-32'h40)-:8];
                else if (rbcp_addr>=32'h100 && rbcp_addr<32'h104) rbcp_rd<=32'h58544350 >> (24-8*rbcp_addr[1:0]);
                else if (rbcp_addr==32'h104) rbcp_rd<=PROFILE;
                else if (rbcp_addr==32'h105) rbcp_rd<={5'd0,echo,source,established};
                else if (rbcp_addr==32'h106) rbcp_rd<=status_flags[15:8];
                else if (rbcp_addr==32'h107) rbcp_rd<=status_flags[7:0];
                else if (rbcp_addr>=32'h110 && rbcp_addr<32'h140)
                    rbcp_rd<=snapshot[383-8*(rbcp_addr[5:0]-6'h10)-:8];
            end
        end
    end
endmodule
