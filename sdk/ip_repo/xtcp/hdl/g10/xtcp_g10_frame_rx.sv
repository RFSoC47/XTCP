// XTCP packed complete-frame queue; no side effect before MAC FCS/length acceptance.
// Checksums accumulate during ingress, excluding Ethernet padding.
// Unaligned 8-byte consumer reads have one clock of synchronous RAM latency.
module xtcp_g10_frame_rx #(
    parameter SLOT_BITS=6,
    parameter DATA_WORD_BITS=13
)(
    input wire clk, rst, clear_statistics,
    input wire [63:0] s_data,
    input wire [7:0] s_keep,
    input wire s_valid, s_last, s_bad,
    output wire available,
    output wire [11:0] frame_length,
    input wire pop,
    input wire [10:0] read_addr,
    output wire [63:0] read_data,
    output wire [127:0] read_data128,
    output wire [31:0] frame_ip_sum,frame_l4_sum,
    output wire [767:0] frame_header,
    output wire frame_ip_valid,frame_l4_valid,
    output reg [31:0] frames, bad_frames, dropped,
    output reg [31:0] full_drops,format_drops,
    output wire [SLOT_BITS:0] queue_used,
    output reg [SLOT_BITS:0] queue_highwater,
    output reg [DATA_WORD_BITS:0] words_highwater,
    output wire full_start
);
    localparam SLOTS=1<<SLOT_BITS;
    localparam DATA_WORDS=1<<DATA_WORD_BITS;
    // Descriptor count and byte storage are independent ownership resources.
    // Only complete accepted frames publish a descriptor. Rejected partial
    // frames roll back their uncommitted tail allocation.
    reg [DATA_WORD_BITS:0] data_producer,data_consumer,frame_start_word;
    reg [DATA_WORD_BITS-1:0] starts[0:SLOTS-1];
    reg [8:0] words[0:SLOTS-1];
    reg [SLOT_BITS:0] producer, consumer, visible_producer;
    reg [8:0] word_index;
    reg active, discard, discard_full;
    reg [11:0] lengths [0:SLOTS-1];
    reg [31:0] ip_sums[0:SLOTS-1],l4_sums[0:SLOTS-1];
    reg ip_valid[0:SLOTS-1],l4_valid[0:SLOTS-1];
    reg [31:0] ip_acc,l4_acc;
    reg [15:0] ingress_ip_length;
    reg [31:0] ingress_src,ingress_dst,pseudo_seed;
    reg [7:0] ingress_protocol;
    wire [15:0] ip_limit=16'd14+ingress_ip_length;
    // Four 16-bit words, two balanced levels instead of eight serial adds.
    wire [15:0] ip_word[0:3],l4_word[0:3];
    wire [16:0] ip_pair[0:1],l4_pair[0:1];
    wire [17:0] beat_ip={1'b0,ip_pair[0]}+{1'b0,ip_pair[1]};
    wire [17:0] beat_l4={1'b0,l4_pair[0]}+{1'b0,l4_pair[1]};
    for(genvar w=0;w<4;w=w+1) begin: checksum_words
        wire ih=s_keep[2*w] && word_index*8+2*w>=14 && word_index*8+2*w<34;
        wire il=s_keep[2*w+1] && word_index*8+2*w+1>=14 && word_index*8+2*w+1<34;
        wire lh=s_keep[2*w] && word_index*8+2*w>=34 && word_index*8+2*w<ip_limit;
        wire ll=s_keep[2*w+1] && word_index*8+2*w+1>=34 && word_index*8+2*w+1<ip_limit;
        assign ip_word[w]={ih?s_data[16*w+:8]:8'd0,il?s_data[16*w+8+:8]:8'd0};
        assign l4_word[w]={lh?s_data[16*w+:8]:8'd0,ll?s_data[16*w+8+:8]:8'd0};
    end
    for(genvar w=0;w<2;w=w+1) begin: checksum_pairs
        assign ip_pair[w]={1'b0,ip_word[2*w]}+{1'b0,ip_word[2*w+1]};
        assign l4_pair[w]={1'b0,l4_word[2*w]}+{1'b0,l4_word[2*w+1]};
    end
    wire [16:0] pseudo_src={1'b0,ingress_src[31:16]}+{1'b0,ingress_src[15:0]};
    wire [16:0] pseudo_dst={1'b0,ingress_dst[31:16]}+{1'b0,ingress_dst[15:0]};
    wire [17:0] pseudo_addresses={1'b0,pseudo_src}+{1'b0,pseudo_dst};
    function automatic [15:0] fold(input [31:0] v);
        reg [16:0] t;
        begin t={1'b0,v[15:0]}+{1'b0,v[31:16]};fold=t[15:0]+t[16];end
    endfunction
    reg [1:0] commit_valid;
    reg [SLOT_BITS-1:0] commit_slot0,commit_slot1;
    reg [31:0] final_ip0,final_ip1,final_l40,final_l41,final_pseudo;
    // Preserve modulo pointer width BEFORE comparison with integer SLOTS.
    // A widened subtraction becomes negative across pointer wrap and misses full.
    wire [SLOT_BITS:0] occupancy=producer-consumer;
    wire descriptor_full=occupancy==SLOTS;
    wire [DATA_WORD_BITS:0] used_words=data_producer-data_consumer;
    wire data_full=used_words==DATA_WORDS;
    wire full=descriptor_full || data_full;
    assign queue_used=occupancy;
    assign full_start=s_valid && !(active && discard) && ((!active && descriptor_full) || data_full);
    wire accept_word=s_valid && !(active ? discard : descriptor_full) && !data_full && word_index<256;
    wire [DATA_WORD_BITS-1:0] write_index=data_producer[DATA_WORD_BITS-1:0];
    wire [127:0] read_word;
    wire [DATA_WORD_BITS+2:0] read_byte_address={starts[consumer[SLOT_BITS-1:0]],3'b0}+read_addr;
    reg [3:0] read_lane;
    integer count;
    reg keep_ok;
    always @* begin
        count=0;
        for (integer k=0;k<8;k=k+1) count=count+s_keep[k];
        keep_ok=(s_keep!=0) && (({1'b0,s_keep}+9'd1 & {1'b0,s_keep})==0);
    end
    // Sixteen byte banks provide an unaligned 16-byte read per clock.
    // Ingress still writes one 8-byte beat. Same total DATA_WORDS*8 bytes.
    for(genvar b=0;b<16;b=b+1) begin: lanes
        (* ram_style="block" *) reg [7:0] mem [0:DATA_WORDS/2-1];
        wire [3:0] lane_offset=b-read_byte_address[3:0];
        wire [DATA_WORD_BITS+2:0] location=read_byte_address+lane_offset;
        wire [DATA_WORD_BITS-2:0] read_index=location[DATA_WORD_BITS+2:4];
        reg [7:0] q;
        always @(posedge clk) begin
            if(accept_word && write_index[0]==(b/8) && s_keep[b%8])
                mem[write_index[DATA_WORD_BITS-1:1]]<=s_data[(b%8)*8+:8];
            q<=mem[read_index];
        end
        assign read_word[b*8+:8]=q;
        wire [3:0] rotated_lane=read_lane+b;
        assign read_data128[b*8+:8]=read_word[rotated_lane*8+:8];
    end
    assign read_data=read_data128[63:0];
    always @(posedge clk) read_lane<=read_byte_address[3:0];
    // Header writes target an uncommitted slot. The consumer cannot observe a
    // bad/partial frame; full-queue writes are suppressed just like payload RAM.
    for(genvar h=0;h<12;h=h+1) begin: headers
        (* ram_style="distributed" *) reg [63:0] mem[0:SLOTS-1];
        always @(posedge clk) if(accept_word && word_index==h)
            mem[producer[SLOT_BITS-1:0]]<=s_data;
        assign frame_header[h*64+:64]=mem[consumer[SLOT_BITS-1:0]];
    end
    assign available=visible_producer!=consumer;
    assign frame_length=lengths[consumer[SLOT_BITS-1:0]];
    assign frame_ip_sum=ip_sums[consumer[SLOT_BITS-1:0]];
    assign frame_l4_sum=l4_sums[consumer[SLOT_BITS-1:0]];
    assign frame_ip_valid=ip_valid[consumer[SLOT_BITS-1:0]];
    assign frame_l4_valid=l4_valid[consumer[SLOT_BITS-1:0]];
    always @(posedge clk) begin
        if(rst) begin
            producer<=0;consumer<=0;visible_producer<=0;word_index<=0;active<=0;discard<=0;
            frames<=0;bad_frames<=0;dropped<=0;full_drops<=0;format_drops<=0;queue_highwater<=0;discard_full<=0;
            data_producer<=0;data_consumer<=0;frame_start_word<=0;words_highwater<=0;
            ip_acc<=0;l4_acc<=0;ingress_ip_length<=0;
            ingress_src<=0;ingress_dst<=0;ingress_protocol<=0;pseudo_seed<=0;
            commit_valid<=0;commit_slot0<=0;commit_slot1<=0;
            final_ip0<=0;final_ip1<=0;final_l40<=0;final_l41<=0;final_pseudo<=0;
        end else begin
            if(occupancy>queue_highwater) queue_highwater<=occupancy;
            if(used_words>words_highwater) words_highwater<=used_words;
            commit_valid<={commit_valid[0],1'b0};
            if(commit_valid[0]) begin
                final_ip1<=final_ip0;final_l41<=final_l40+final_pseudo;commit_slot1<=commit_slot0;
            end
            if(commit_valid[1]) begin
                ip_valid[commit_slot1]<=fold(final_ip1)==16'hffff;
                l4_valid[commit_slot1]<=fold(final_l41)==16'hffff;
                visible_producer<=visible_producer+1'b1;
            end
            if(pop && available) begin
                consumer<=consumer+1'b1;
                data_consumer<=data_consumer+words[consumer[SLOT_BITS-1:0]];
            end
            if(s_valid) begin
                if(!active) begin
                    active<=1;discard<=full;discard_full<=full;ingress_ip_length<=0;frame_start_word<=data_producer;
                end
                if(accept_word) data_producer<=data_producer+1'b1;
                if(data_full && !(active ? discard : descriptor_full)) begin discard<=1;discard_full<=1;end
                if(word_index==2) begin
                    ingress_ip_length<={s_data[7:0],s_data[15:8]};ingress_protocol<=s_data[63:56];
                end
                if(word_index==3) begin
                    ingress_src<={s_data[23:16],s_data[31:24],s_data[39:32],s_data[47:40]};
                    ingress_dst[31:16]<={s_data[55:48],s_data[63:56]};
                end
                if(word_index==4) ingress_dst[15:0]<={s_data[7:0],s_data[15:8]};
                if(word_index==5) pseudo_seed<={14'd0,pseudo_addresses}+{16'd0,ingress_ip_length}-32'd20+{24'd0,ingress_protocol};
                ip_acc<=(active?ip_acc:0)+beat_ip;
                l4_acc<=(active?l4_acc:0)+beat_l4;
                if(!keep_ok || (!s_last && s_keep!=8'hff) || word_index>=255)
                    discard<=1;
                word_index<=word_index+1'b1;
                if(s_last) begin
                    active<=0;word_index<=0;discard<=0;
                    if(s_bad) begin
                        bad_frames<=bad_frames+1'b1;
                        data_producer<=active?frame_start_word:data_producer;
                    end
                    else if((active ? discard : descriptor_full) || data_full || !keep_ok || word_index>=255 ||
                            (word_index*8+count)>1514 || (word_index*8+count)<14)
                        begin
                            dropped<=dropped+1'b1;
                            if(data_full || (active ? discard_full : descriptor_full)) full_drops<=full_drops+1'b1;
                            else format_drops<=format_drops+1'b1;
                            data_producer<=active?frame_start_word:data_producer;
                        end
                    else begin
                        lengths[producer[SLOT_BITS-1:0]]<=word_index*8+count;
                        starts[producer[SLOT_BITS-1:0]]<=active?frame_start_word[DATA_WORD_BITS-1:0]:data_producer[DATA_WORD_BITS-1:0];
                        words[producer[SLOT_BITS-1:0]]<=word_index+1'b1;
                        ip_sums[producer[SLOT_BITS-1:0]]<=(active?ip_acc:0)+beat_ip;
                        l4_sums[producer[SLOT_BITS-1:0]]<=(active?l4_acc:0)+beat_l4;
                        final_ip0<=(active?ip_acc:0)+beat_ip;
                        final_l40<=(active?l4_acc:0)+beat_l4;final_pseudo<=pseudo_seed;
                        commit_slot0<=producer[SLOT_BITS-1:0];commit_valid[0]<=1;
                        producer<=producer+1'b1;frames<=frames+1'b1;
                    end
                end
            end
            // Explicit idle-only host command clears diagnostics, not ownership
            // or the original lifetime frame/error counters.
            if(clear_statistics) begin full_drops<=0;format_drops<=0;queue_highwater<=occupancy;words_highwater<=used_words;end
        end
    end
endmodule
