// XTCP two-slot complete-frame queue: 128-bit masked builder, 64-bit MAC.
// Producer owns an unpublished slot until start; checksum patches must land
// before publication. Consumer releases only on the final AXI handshake.
// Prefetch of the next slot at that handshake avoids inter-frame bubbles.
// VALID/DATA/KEEP/LAST stay stable while the MAC is not ready.
module xtcp_jumbo_frame_tx #(parameter SLOT_BITS=1, parameter integer FRAME_BITS=11)(
    input wire clk,rst,flush,
    input wire [15:0] write_en,
    input wire [FRAME_BITS-1:0] write_addr,
    input wire [127:0] write_data,
    input wire start,
    input wire [FRAME_BITS-1:0] length,
    input wire [1:0] frame_kind, // immutable owner of the producer slot; TCP=0
    output reg [31:0] cancelled_count,
    output wire busy,
    output reg done,
    output wire [127:0] m_data,
    output reg [15:0] m_keep,
    output reg m_valid,m_last,
    input wire m_ready
);
    localparam integer ROW_BITS=FRAME_BITS-4;
    localparam SLOTS=1<<SLOT_BITS;
    reg [SLOT_BITS:0] producer,consumer;
    reg [FRAME_BITS-1:0] lengths[0:SLOTS-1];
    reg [1:0] kinds[0:SLOTS-1];
    reg [SLOTS-1:0] cancelled;
    reg [ROW_BITS-1:0] next_word;
    wire finish=m_valid && m_ready && m_last;
    wire [SLOT_BITS:0] occupancy=producer-consumer;
    assign busy=occupancy==SLOTS;
    // flush is a TCP-only barrier. Never rewind producer across retained
    // UDP/ARP slots. Exposed means VALID was asserted, even if READY was low.
    wire [SLOT_BITS:0] read_owner=consumer+(finish?1'b1:1'b0);
    wire selected_cancelled=cancelled[read_owner[SLOT_BITS-1:0]] ||
        (flush && kinds[read_owner[SLOT_BITS-1:0]]==0);
    wire can_read=(!m_valid || m_ready) && (finish ? occupancy>1 : occupancy!=0) &&
        ((!finish && next_word!=0) || !selected_cancelled);
    wire skip_head=occupancy!=0 && !m_valid && next_word==0 && selected_cancelled;
    wire accept_publication=start && !busy && !(flush && frame_kind==0);
    wire [ROW_BITS-1:0] selected_word=finish?'0:next_word;
    wire [FRAME_BITS:0] next_byte={1'b0,selected_word,4'b0}+16;
    wire [FRAME_BITS-1:0] selected_length=lengths[read_owner[SLOT_BITS-1:0]];
    wire [SLOT_BITS+ROW_BITS-1:0] rd_index={read_owner[SLOT_BITS-1:0],selected_word};
    wire [SLOT_BITS+ROW_BITS-1:0] wr_index={producer[SLOT_BITS-1:0],write_addr[FRAME_BITS-1:4]};
    wire [127:0] qword;
    // simple dual-port memory. The 9th bit is padding, never user data/ECC.
    // Latency and gated read-output hold are identical to the prior lanes.
    wire [143:0] packed_write,packed_read;
    for(genvar b=0;b<16;b=b+1) begin: byte_lanes
        assign packed_write[b*9+:9]={1'b0,write_data[b*8+:8]};
        assign qword[b*8+:8]=packed_read[b*9+:8];
    end
    xpm_memory_sdpram #(
        .ADDR_WIDTH_A(SLOT_BITS+ROW_BITS),.ADDR_WIDTH_B(SLOT_BITS+ROW_BITS),
        .AUTO_SLEEP_TIME(0),.BYTE_WRITE_WIDTH_A(9),.CLOCKING_MODE("common_clock"),
        .ECC_MODE("no_ecc"),.MEMORY_INIT_FILE("none"),.MEMORY_INIT_PARAM("0"),
        .MEMORY_OPTIMIZATION("true"),.MEMORY_PRIMITIVE("block"),.MEMORY_SIZE(SLOTS*(1<<ROW_BITS)*144),
        .MESSAGE_CONTROL(0),.READ_DATA_WIDTH_B(144),.READ_LATENCY_B(1),
        .READ_RESET_VALUE_B("0"),.RST_MODE_B("SYNC"),.SIM_ASSERT_CHK(1),
        .USE_EMBEDDED_CONSTRAINT(0),.USE_MEM_INIT(0),.WAKEUP_TIME("disable_sleep"),
        .WRITE_DATA_WIDTH_A(144),.WRITE_MODE_B("read_first")
    ) storage(
        .clka(clk),.clkb(clk),.ena(!busy && !(flush && frame_kind==0)),.enb(can_read),
        .wea(write_en),.addra(wr_index),.addrb(rd_index),
        .dina(packed_write),.doutb(packed_read),.regceb(1'b1),.rstb(1'b0),.sleep(1'b0),
        .injectdbiterra(1'b0),.injectsbiterra(1'b0),.dbiterrb(),.sbiterrb());
    assign m_data=qword;
    always @(posedge clk) begin
        done<=0;
        if(rst) begin
            producer<=0;consumer<=0;next_word<=0;
            m_valid<=0;m_keep<=0;m_last<=0;cancelled<=0;cancelled_count<=0;
            for(integer i=0;i<SLOTS;i=i+1) kinds[i]<=0;
        end else begin
            if(flush) for(integer i=0;i<SLOTS;i=i+1) if(kinds[i]==0) cancelled[i]<=1;
            // Allocation wins over old slot marks, including same-edge flush.
            if(accept_publication) begin
                lengths[producer[SLOT_BITS-1:0]]<=length;producer<=producer+1'b1;
                kinds[producer[SLOT_BITS-1:0]]<=frame_kind;cancelled[producer[SLOT_BITS-1:0]]<=0;
            end
            if(skip_head) begin
                consumer<=consumer+1'b1;cancelled_count<=cancelled_count+1'b1;
            end
            if(finish) begin
                consumer<=consumer+1'b1;next_word<=0;m_valid<=0;m_last<=0;done<=1;
            end
            if(can_read) begin
                next_word<=selected_word+1'b1;
                m_valid<=1;m_last<=next_byte>=selected_length;
                m_keep<=next_byte<=selected_length ? 16'hffff : (16'hffff>>(16-selected_length[3:0]));
            end
        end
    end
endmodule
