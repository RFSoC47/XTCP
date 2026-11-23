// XTCP retained stream: 8 B/cycle producer, unaligned 16 B/cycle RAM reader.
// Release ONLY by cumulative TCP ACK. Input MSB is first; read LSB is first.
// Each bank is simple dual-port synchronous RAM; read latency is one clock.
module xtcp_g25_tx_store #(
    parameter ADDR_BITS=18,
    parameter [31:0] INITIAL_OFFSET=0
)(
    input wire clk,clear,enabled,
    input wire [127:0] data,
    input wire [4:0] bytes,
    input wire [31:0] acknowledged,
    output reg [31:0] written,
    output wire afull,
    input wire [ADDR_BITS-1:0] read_addr,
    output wire [127:0] read_data,
    output reg [31:0] overflow_count
);
    localparam CAPACITY=1<<ADDR_BITS;
    wire [31:0] occupied=written-acknowledged;
    wire accept=enabled && !clear && bytes!=0 && bytes<=16 && occupied+bytes<=CAPACITY;
    assign afull=!enabled || clear || occupied>=CAPACITY-256;
    wire [127:0] read_word;
    reg [3:0] read_lane;
    for(genvar b=0;b<16;b=b+1) begin: lanes
        (* ram_style="block" *) reg [7:0] mem[0:CAPACITY/16-1];
        wire [3:0] input_lane=b-written[3:0];
        wire [ADDR_BITS-1:0] location=written[ADDR_BITS-1:0]+input_lane;
        wire [3:0] read_offset=b-read_addr[3:0];
        wire [ADDR_BITS-1:0] read_location=read_addr+read_offset;
        reg [7:0] q;
        always @(posedge clk) begin
            if(accept && input_lane<bytes)
                mem[location[ADDR_BITS-1:4]]<=data[127-input_lane*8-:8];
            q<=mem[read_location[ADDR_BITS-1:4]];
        end
        assign read_word[b*8+:8]=q;
        wire [3:0] rotated_lane=read_lane+b;
        assign read_data[b*8+:8]=read_word[rotated_lane*8+:8];
    end
    always @(posedge clk) begin
        read_lane<=read_addr[3:0];
        if(clear) begin written<=INITIAL_OFFSET; end
        else if(accept) written<=written+bytes;
        if(clear) overflow_count<=0;
        else if(enabled && bytes!=0 && !accept) overflow_count<=overflow_count+1'b1;
    end
endmodule
