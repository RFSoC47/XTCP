// XTCP independent packet builder. Owns a frozen descriptor until publication.
// TCP/ARP use128bit writes; low-rateUDP has a narrow body port. Balanced word
// checksum trees feed registered partial sums; no frame is published early.
module xtcp_jumbo_packet_builder #(
    parameter [47:0] LOCAL_MAC=48'h025100030001,
    parameter [31:0] LOCAL_IP=32'hc0a80a0a,
    parameter [15:0] TCP_PORT=16'd24,RBCP_PORT=16'd4660,
    parameter integer LOCAL_WINDOW_SHIFT=0,
    parameter [15:0] LOCAL_MSS=1460,
    parameter integer FRAME_BITS=11
)(
    input wire clk,rst,flush,
    input wire descriptor_valid,
    output wire descriptor_ready,
    output wire schedule_ready,
    input wire [1:0] descriptor_kind,
    input wire [47:0] descriptor_mac,
    input wire [31:0] descriptor_ip,descriptor_seq,descriptor_ack,descriptor_offset,
    input wire [15:0] descriptor_port,descriptor_window,descriptor_payload,
    input wire [7:0] descriptor_flags,descriptor_tcp_header,
    output reg [17:0] store_read_addr,
    input wire [127:0] store_read_data,
    output wire [8:0] udp_read_addr,
    input wire [7:0] udp_read_data,
    output reg [15:0] write_en,
    output reg [FRAME_BITS-1:0] write_addr,
    output reg [127:0] write_data,
    output reg frame_start,
    output reg [FRAME_BITS-1:0] frame_length,
    input wire frame_busy,
    output reg published,
    output wire [1:0] frame_kind,
    output reg [1:0] published_kind,
    output reg [31:0] cancelled_count
);
    localparam TCP=0,ARP=1,UDP=2;
    localparam B_IDLE=0,B_SETUP=1,B_REQ=2,B_WORD=3,B_UDP=4,B_DRAIN=5,
        B_SUM=6,B_IP=7,B_TCP=8,B_START=9,B_PUBLISH=10,B_LAST_SUM=11;
    reg [3:0] state;
    reg [1:0] kind;
    reg [47:0] dst_mac;
    reg [31:0] dst_ip,seq,ack,stream_offset;
    reg [15:0] dst_port,window_bytes,payload_bytes,ip_length,l4_length;
    reg [7:0] flags,tcp_header;
    // Monotonic per-frame ID aids bounded wire diagnostics; DF remains set.
    reg [15:0] next_ip_id,ip_id;
    reg [6:0] payload_start;
    reg [FRAME_BITS-1:0] index;
    // The held descriptor is the only metadata owner; all function dependencies
    // are explicit inputs so continuous assignments update in simulation and RTL.
    wire [511:0] header;
    reg [127:0] built_word;
    reg [15:0] built_mask;
    wire [FRAME_BITS-1:0] beat_addr={index[FRAME_BITS-1:4],4'b0};
    wire [127:0] header_word=header[index[5:4]*128+:128];
    reg [31:0] sum_ip,sum_l4;
    reg [18:0] partial_l4;
    reg partial_valid,pairs_valid;
    reg [16:0] registered_pair[0:3];
    reg [15:0] checksum_ip;
    assign descriptor_ready=state==B_IDLE && !(flush && descriptor_kind==TCP);
    assign frame_kind=kind;
    // The registered scheduler may fill its descriptor during the final TCP
    // checksum patch. The builder accepts that descriptor only in B_IDLE.
    assign schedule_ready=descriptor_ready || (state==B_SUM && kind==TCP && !flush);
    wire cancel_owned=flush && state!=B_IDLE && kind==TCP;
    assign udp_read_addr=index>=42?index-42:9'd0;

    function automatic [15:0] fold(input [31:0] v);
        reg [16:0] t;
        begin t={1'b0,v[15:0]}+{1'b0,v[31:16]};fold=t[15:0]+t[16];end
    endfunction
    wire [15:0] final_tcp_checksum=~fold(sum_l4);
    // Positions are constant at elaboration in the template-generation loop.
    function automatic [7:0] header_byte(
        input integer pos,
        input [1:0] kind_v,
        input [47:0] dst_mac_v,
        input [31:0] dst_ip_v,seq_v,ack_v,
        input [15:0] ip_id_v,ip_length_v,l4_length_v,dst_port_v,window_bytes_v,
        input [7:0] tcp_header_v,flags_v);
    begin
        header_byte=0;
        if(pos<6) header_byte=dst_mac_v[47-pos*8-:8];
        else if(pos<12) header_byte=LOCAL_MAC[47-(pos-6)*8-:8];
        else if(pos==12) header_byte=8'h08;
        else if(pos==13) header_byte=kind_v==ARP?8'h06:8'h00;
        else if(kind_v==ARP) begin
            case(pos)
                14:header_byte=0;15:header_byte=1;16:header_byte=8'h08;
                17:header_byte=0;18:header_byte=6;19:header_byte=4;
                20:header_byte=0;21:header_byte=2;
                default:begin
                    if(pos<28) header_byte=LOCAL_MAC[47-(pos-22)*8-:8];
                    else if(pos<32) header_byte=LOCAL_IP[31-(pos-28)*8-:8];
                    else if(pos<38) header_byte=dst_mac_v[47-(pos-32)*8-:8];
                    else if(pos<42) header_byte=dst_ip_v[31-(pos-38)*8-:8];
                end
            endcase
        end else if(pos<34) begin
            case(pos)
                14:header_byte=8'h45;16:header_byte=ip_length_v[15:8];17:header_byte=ip_length_v[7:0];
                18:header_byte=ip_id_v[15:8];19:header_byte=ip_id_v[7:0];
                20:header_byte=8'h40;22:header_byte=64;23:header_byte=kind_v==TCP?6:17;
                default:begin
                    if(pos>=26 && pos<30) header_byte=LOCAL_IP[31-(pos-26)*8-:8];
                    else if(pos>=30) header_byte=dst_ip_v[31-(pos-30)*8-:8];
                end
            endcase
        end else if(kind_v==UDP) begin
            case(pos)
                34:header_byte=RBCP_PORT[15:8];35:header_byte=RBCP_PORT[7:0];
                36:header_byte=dst_port_v[15:8];37:header_byte=dst_port_v[7:0];
                38:header_byte=l4_length_v[15:8];39:header_byte=l4_length_v[7:0];
                default:header_byte=0;
            endcase
        end else begin
            case(pos)
                34:header_byte=TCP_PORT[15:8];35:header_byte=TCP_PORT[7:0];
                36:header_byte=dst_port_v[15:8];37:header_byte=dst_port_v[7:0];
                38:header_byte=seq_v[31:24];39:header_byte=seq_v[23:16];
                40:header_byte=seq_v[15:8];41:header_byte=seq_v[7:0];
                42:header_byte=ack_v[31:24];43:header_byte=ack_v[23:16];
                44:header_byte=ack_v[15:8];45:header_byte=ack_v[7:0];
                46:header_byte={tcp_header_v[5:2],4'b0};47:header_byte=flags_v;
                48:header_byte=window_bytes_v[15:8];49:header_byte=window_bytes_v[7:0];
                54:header_byte=2;55:header_byte=4;56:header_byte=LOCAL_MSS[15:8];57:header_byte=LOCAL_MSS[7:0];
                58:header_byte=1;59:header_byte=3;60:header_byte=3;61:header_byte=LOCAL_WINDOW_SHIFT;
                default:header_byte=0;
            endcase
        end
    end
    endfunction

    for(genvar hb=0;hb<64;hb=hb+1) begin: header_template
        assign header[hb*8+:8]=header_byte(hb,kind,dst_mac,dst_ip,seq,ack,ip_id,ip_length,l4_length,dst_port,window_bytes,tcp_header,flags);
    end
    // TCP/ARP B_WORD always starts at a16-byte boundary. Share row decisions;
    // only the boundary row needs the four-bit byte comparison.
    wire [FRAME_BITS-5:0] word_row=index[FRAME_BITS-1:4];
    wire frame_before=word_row<frame_length[FRAME_BITS-1:4];
    wire frame_boundary=word_row==frame_length[FRAME_BITS-1:4];
    wire header_before=index[FRAME_BITS-1:4]<payload_start[6:4];
    wire header_boundary=index[FRAME_BITS-1:4]==payload_start[6:4];
    // Fixed20-byte IPv4 header: ten16-bit words, at most443659 total.
    wire [16:0] ip_length_id={1'b0,ip_length}+{1'b0,ip_id};
    wire [16:0] ip_destination={1'b0,dst_ip[31:16]}+{1'b0,dst_ip[15:0]};
    wire [17:0] ip_variable={1'b0,ip_length_id}+{1'b0,ip_destination};
    localparam [18:0] IP_FIXED=19'h4500+19'h4000+19'h4000+
        {3'b0,LOCAL_IP[31:16]}+{3'b0,LOCAL_IP[15:0]};
    wire [18:0] ip_header_sum={1'b0,ip_variable}+IP_FIXED+(kind==UDP?19'd17:19'd6);

    always @* begin
        built_word=0;built_mask=0;
        if(kind==UDP) begin
            built_mask[index[3:0]]=1;
            built_word[index[3:0]*8+:8]=index<42?header_word[index[3:0]*8+:8]:udp_read_data;
        end else begin
            for(integer b=0;b<16;b=b+1) if(frame_before || (frame_boundary && b<frame_length[3:0])) begin
                built_mask[b]=1;
                built_word[b*8+:8]=(kind==ARP || header_before || (header_boundary && b<payload_start[3:0]))?header_word[b*8+:8]:store_read_data[b*8+:8];
            end
        end
    end
    wire [15:0] l4_word[0:7];
    wire [16:0] l4_pair[0:3];
    wire [17:0] l4_quad[0:1];
    wire [18:0] beat_l4={1'b0,l4_quad[0]}+{1'b0,l4_quad[1]};
    for(genvar w=0;w<8;w=w+1) begin: checksum_words
        // TCP starts at byte34, an even byte boundary in the third16-byte row.
        wire l4_region=word_row>2 || (word_row==2 && w>=1);
        wire l4_hi=kind==TCP && built_mask[2*w] && l4_region;
        wire l4_lo=kind==TCP && built_mask[2*w+1] && l4_region;
        assign l4_word[w]={l4_hi?built_word[(2*w)*8+:8]:8'd0,l4_lo?built_word[(2*w+1)*8+:8]:8'd0};
    end
    for(genvar w=0;w<4;w=w+1) begin: checksum_pairs
        assign l4_pair[w]={1'b0,l4_word[2*w]}+{1'b0,l4_word[2*w+1]};
    end
    for(genvar w=0;w<2;w=w+1) begin: checksum_quads
        assign l4_quad[w]={1'b0,registered_pair[2*w]}+{1'b0,registered_pair[2*w+1]};
    end
    wire [16:0] pseudo_src={1'b0,LOCAL_IP[31:16]}+{1'b0,LOCAL_IP[15:0]};
    wire [16:0] pseudo_dst={1'b0,dst_ip[31:16]}+{1'b0,dst_ip[15:0]};
    wire [17:0] pseudo_addresses={1'b0,pseudo_src}+{1'b0,pseudo_dst};
    always @(posedge clk) begin
        write_en<=0;frame_start<=0;published<=0;pairs_valid<=0;
        // Report publication on the queue's actual acceptance edge. The next
        // descriptor can be scheduled on that edge without changing the owner.
        if(frame_start && kind==TCP && !rst) begin
            if(flush) cancelled_count<=cancelled_count+1'b1;
            else begin published<=1;published_kind<=TCP;end
        end
        partial_valid<=pairs_valid;
        if(pairs_valid) partial_l4<=beat_l4;
        if(partial_valid) begin
            sum_l4<=sum_l4+partial_l4;
        end
        if(rst) begin
            published_kind<=TCP;cancelled_count<=0;
            state<=B_IDLE;write_en<=0;frame_start<=0;published<=0;
            pairs_valid<=0;partial_valid<=0;partial_l4<=0;sum_ip<=0;sum_l4<=0;
            store_read_addr<=0;write_addr<=0;write_data<=0;frame_length<=0;
            next_ip_id<=0;ip_id<=0;kind<=0;dst_mac<=0;dst_ip<=0;seq<=0;ack<=0;stream_offset<=0;
            dst_port<=0;window_bytes<=0;payload_bytes<=0;flags<=0;tcp_header<=20;
            payload_start<=54;ip_length<=0;l4_length<=0;index<=0;checksum_ip<=0;
        end else if(cancel_owned) begin
            // Partial producer bytes are unpublished. The next owner overwrites
            // its entire declared frame; no memory or global ID reset is needed.
            state<=B_IDLE;write_en<=0;frame_start<=0;published<=0;pairs_valid<=0;partial_valid<=0;
            cancelled_count<=cancelled_count+1'b1;
        end else case(state)
            B_IDLE:if(descriptor_valid && descriptor_ready) begin
                kind<=descriptor_kind;dst_mac<=descriptor_mac;
                ip_id<=next_ip_id;if(descriptor_kind!=ARP) next_ip_id<=next_ip_id+1'b1;dst_ip<=descriptor_ip;
                seq<=descriptor_seq;ack<=descriptor_ack;stream_offset<=descriptor_offset;
                dst_port<=descriptor_port;window_bytes<=descriptor_window;payload_bytes<=descriptor_payload;
                flags<=descriptor_flags;tcp_header<=descriptor_tcp_header;
                payload_start<=34+descriptor_tcp_header;
                frame_length<=descriptor_kind==ARP?42:descriptor_kind==UDP?42+descriptor_payload:34+descriptor_tcp_header+descriptor_payload;
                ip_length<=descriptor_kind==UDP?28+descriptor_payload:20+descriptor_tcp_header+descriptor_payload;
                l4_length<=descriptor_kind==UDP?8+descriptor_payload:descriptor_tcp_header+descriptor_payload;
                // The two leading rows have no TCP checksum input or payload.
                // Write them during checksum drain. Row 32 is header-only and
                // hides the synchronous retained-stream read needed by row 48.
                if(descriptor_kind==TCP) begin
                    index<=32;
                    store_read_addr<=descriptor_offset+14-descriptor_tcp_header;
                end
                state<=descriptor_kind==TCP ? B_WORD : B_SETUP;
            end
            B_SETUP:if(!frame_busy) begin
                sum_ip<={13'd0,ip_header_sum};sum_l4<={14'd0,pseudo_addresses}+{16'd0,l4_length}+32'd6;
                if(kind==TCP) state<=B_WORD;
                else begin index<=0;store_read_addr<=stream_offset-payload_start;state<=B_REQ;end
            end
            B_REQ:begin
                store_read_addr<=stream_offset+16-payload_start;
                state<=kind==UDP?B_UDP:B_WORD;
            end
            // A simultaneous publication of the preceding descriptor can fill
            // the two-slot queue. Preserve the new descriptor and its first RAM
            // address until the consumer releases a slot.
            B_WORD:if(!frame_busy) begin
                if(kind==TCP && index==32) begin
                    sum_ip<={13'd0,ip_header_sum};
                    sum_l4<={14'd0,pseudo_addresses}+{16'd0,l4_length}+32'd6;
                end
                write_en<=built_mask;write_addr<=beat_addr;write_data<=built_word;
                for(integer p=0;p<4;p=p+1) registered_pair[p]<=l4_pair[p];
                pairs_valid<=1;
                if(index+16>=frame_length) state<=B_DRAIN;
                else begin index<=index+16;store_read_addr<=stream_offset+index+32-payload_start;end
            end
            B_UDP:begin
                write_en<=built_mask;write_addr<=beat_addr;write_data<=built_word;
                // UDP checksums are disabled by this IPv4 RBCP endpoint.
                if(index+1>=frame_length) state<=B_DRAIN;else index<=index+1'b1;
            end
            B_DRAIN:begin
                // This unused RAM write slot coincides with the registered
                // payload checksum draining after the last original data write.
                if(kind==TCP) begin
                    write_en<=16'hffff;write_addr<=0;write_data<=header[127:0];
                    checksum_ip<=~fold(sum_ip);
                end
                state<=B_LAST_SUM;
            end
            B_LAST_SUM:begin
                if(kind==TCP) begin
                    write_en<=16'hffff;write_addr<=16;write_data<=header[255:128];
                    write_data[71:64]<=checksum_ip[15:8];write_data[79:72]<=checksum_ip[7:0];
                end
                state<=B_SUM;
            end
            B_SUM:begin
                if(kind==TCP) begin
                    // Final checksum and publication reach the slot on the
                    // same edge, before the consumer can issue its first read.
                    write_en<=16'h000c;write_addr<=48;write_data<=0;
                    write_data[23:16]<=final_tcp_checksum[15:8];write_data[31:24]<=final_tcp_checksum[7:0];
                    frame_start<=1;state<=B_IDLE;
                end else begin
                    checksum_ip<=~fold(sum_ip);state<=kind==ARP?B_START:B_IP;
                end
            end
            B_IP:begin
                write_en<=16'h0300;write_addr<=16;write_data<=0;
                write_data[71:64]<=checksum_ip[15:8];write_data[79:72]<=checksum_ip[7:0];state<=B_START;
            end
            B_START:begin frame_start<=1;state<=B_PUBLISH;end
            B_PUBLISH:begin published<=1;published_kind<=kind;state<=B_IDLE;end
            default:state<=B_IDLE;
        endcase
    end
endmodule
