// allocation/commit/release; consumers read committed slots, never a written word.
// Two interleaved64-bit banks supply both words needed by any unaligned8B read.
// Eight9-bit byte lanes match native URAM byte enables; padding is zero.
module xtcp_jumbo_rx_reorder_mem #(
    parameter integer SLOT_BITS=8,
    parameter integer WRITE_BYTES=8
)(
    input wire clk,
    input wire write_en,
    input wire [SLOT_BITS-1:0] write_slot,read_slot,
    input wire [10:0] write_addr,read_addr,
    input wire [8*WRITE_BYTES-1:0] write_data,
    input wire [WRITE_BYTES-1:0] write_keep,
    output wire [63:0] read_data
);
    localparam integer BANK_ADDR_BITS=SLOT_BITS+7;
    localparam integer BANK_WORDS=1<<BANK_ADDR_BITS;
    wire [9*WRITE_BYTES-1:0] packed_write;
    wire [63:0] even_data,odd_data;
    // Carry wraps inside the2KiB slot; never select the next owner's slot.
    wire [6:0] next_even=read_addr[10:4]+read_addr[3];
    reg [3:0] read_offset;
    always @(posedge clk) read_offset<=read_addr[3:0];
    for(genvar b=0;b<WRITE_BYTES;b=b+1) begin: byte_pack
        assign packed_write[b*9+:9]={1'b0,write_data[b*8+:8]};
    end
    for(genvar bank=0;bank<2;bank=bank+1) begin: banks
        wire [BANK_ADDR_BITS-1:0] read_index={read_slot,bank==0?next_even:read_addr[10:4]};
        wire [71:0] q;
        wire bank_enable;
        wire [7:0] bank_keep;
        wire [71:0] bank_write;
        if(WRITE_BYTES==16) begin: wide_write
            // Wide core writes are 16-byte aligned; each bank has its own mask.
            assign bank_enable=write_en;
            assign bank_keep=write_keep[bank*8+:8];
            assign bank_write=packed_write[bank*72+:72];
        end else begin: compatible_write
            assign bank_enable=write_en && write_addr[3]==bank;
            assign bank_keep=write_keep;
            assign bank_write=packed_write;
        end
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(BANK_ADDR_BITS),.ADDR_WIDTH_B(BANK_ADDR_BITS),
            .AUTO_SLEEP_TIME(0),.BYTE_WRITE_WIDTH_A(9),.CLOCKING_MODE("common_clock"),
            .ECC_MODE("no_ecc"),.MEMORY_INIT_FILE("none"),.MEMORY_INIT_PARAM("0"),
            .MEMORY_OPTIMIZATION("true"),.MEMORY_PRIMITIVE("ultra"),.MEMORY_SIZE(BANK_WORDS*72),
            .MESSAGE_CONTROL(0),.READ_DATA_WIDTH_B(72),.READ_LATENCY_B(1),
            .READ_RESET_VALUE_B("0"),.RST_MODE_B("SYNC"),.SIM_ASSERT_CHK(1),
            .USE_EMBEDDED_CONSTRAINT(0),.USE_MEM_INIT(0),.WAKEUP_TIME("disable_sleep"),
            .WRITE_DATA_WIDTH_A(72),.WRITE_MODE_B("read_first")
        ) storage(
            .clka(clk),.clkb(clk),.ena(bank_enable),.enb(1'b1),
            .wea(bank_keep),.addra({write_slot,write_addr[10:4]}),.addrb(read_index),
            .dina(bank_write),.doutb(q),.regceb(1'b1),.rstb(1'b0),.sleep(1'b0),
            .injectdbiterra(1'b0),.injectsbiterra(1'b0),.dbiterrb(),.sbiterrb());
        for(genvar b=0;b<8;b=b+1) begin: byte_unpack
            if(bank==0) assign even_data[b*8+:8]=q[b*9+:8];
            else assign odd_data[b*8+:8]=q[b*9+:8];
        end
    end
    wire [127:0] ordered=read_offset[3]?{even_data,odd_data}:{odd_data,even_data};
    assign read_data=ordered >> {read_offset[2:0],3'b000};
endmodule

// Two adjacent 16-byte rows deliver an arbitrary 16-byte window each clock.
// Each bank has half of the rows in every slot. Address carry wraps within
// the current slot, including for a read crossing its last row.
module xtcp_jumbo_rx_reorder_mem128 #(
    parameter integer SLOT_BITS=6,
    parameter integer OFFSET_BITS=11
)(
    input wire clk, write_en,
    input wire [SLOT_BITS-1:0] write_slot,read_slot,
    input wire [OFFSET_BITS-1:0] write_addr,read_addr,
    input wire [127:0] write_data,
    input wire [15:0] write_keep,
    output wire [127:0] read_data
);
    localparam integer BANK_ADDR_BITS=SLOT_BITS+OFFSET_BITS-5;
    localparam integer BANK_WORDS=1<<BANK_ADDR_BITS;
    wire [143:0] packed_write;
    wire [127:0] row_data[0:1];
    wire [OFFSET_BITS-6:0] next_even=read_addr[OFFSET_BITS-1:5]+read_addr[4];
    reg [4:0] read_offset;
    always @(posedge clk) read_offset<=read_addr[4:0];
    for(genvar lane=0;lane<16;lane=lane+1) begin: pack_data
        assign packed_write[lane*9+:9]={1'b0,write_data[lane*8+:8]};
    end
    for(genvar bank=0;bank<2;bank=bank+1) begin: row_bank
        wire [BANK_ADDR_BITS-1:0] read_index={read_slot,bank==0?next_even:read_addr[OFFSET_BITS-1:5]};
        wire [143:0] raw_row;
        xpm_memory_sdpram #(
            .ADDR_WIDTH_A(BANK_ADDR_BITS),.ADDR_WIDTH_B(BANK_ADDR_BITS),
            .AUTO_SLEEP_TIME(0),.BYTE_WRITE_WIDTH_A(9),.CLOCKING_MODE("common_clock"),
            .ECC_MODE("no_ecc"),.MEMORY_INIT_FILE("none"),.MEMORY_INIT_PARAM("0"),
            .MEMORY_OPTIMIZATION("true"),.MEMORY_PRIMITIVE("ultra"),.MEMORY_SIZE(BANK_WORDS*144),
            .MESSAGE_CONTROL(0),.READ_DATA_WIDTH_B(144),.READ_LATENCY_B(1),.READ_RESET_VALUE_B("0"),
            .RST_MODE_B("SYNC"),.SIM_ASSERT_CHK(1),.USE_EMBEDDED_CONSTRAINT(0),
            .USE_MEM_INIT(0),.WAKEUP_TIME("disable_sleep"),.WRITE_DATA_WIDTH_A(144),.WRITE_MODE_B("read_first")
        ) storage (
            .clka(clk),.clkb(clk),.ena(write_en && write_addr[4]==bank),.enb(1'b1),.wea(write_keep),
            .addra({write_slot,write_addr[OFFSET_BITS-1:5]}),.addrb(read_index),.dina(packed_write),.doutb(raw_row),
            .regceb(1'b1),.rstb(1'b0),.sleep(1'b0),.injectdbiterra(1'b0),.injectsbiterra(1'b0),.dbiterrb(),.sbiterrb()
        );
        for(genvar lane=0;lane<16;lane=lane+1) begin: unpack_data
            assign row_data[bank][lane*8+:8]=raw_row[lane*9+:8];
        end
    end
    wire [255:0] ordered=read_offset[4]?{row_data[0],row_data[1]}:{row_data[1],row_data[0]};
    assign read_data=ordered >> {read_offset[3:0],3'b000};
endmodule
