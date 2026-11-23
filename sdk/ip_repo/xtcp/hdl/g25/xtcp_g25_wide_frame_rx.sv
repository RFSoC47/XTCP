// AXIS little-endian Ethernet bytes. One 128-bit ingress word per core clock.
module xtcp_g25_wide_frame_rx #(parameter SLOT_BITS=6, parameter DATA_WORD_BITS=12)(
    input wire clk,rst,clear_statistics,
    input wire [127:0] s_data,input wire [15:0] s_keep,input wire s_valid,s_last,s_bad,
    output wire available,output wire [11:0] frame_length,input wire pop,input wire [10:0] read_addr,
    output wire [63:0] read_data,output wire [127:0] read_data128,
    output wire [31:0] frame_ip_sum,frame_l4_sum,output wire [767:0] frame_header,
    output wire frame_ip_valid,frame_l4_valid,
    output reg [31:0] frames,bad_frames,dropped,full_drops,format_drops,
    output wire [SLOT_BITS:0] queue_used,output reg [SLOT_BITS:0] queue_highwater,
    output reg [DATA_WORD_BITS:0] words_highwater,output wire full_start
);
    localparam SLOTS=1<<SLOT_BITS, DEPTH=1<<DATA_WORD_BITS;
    reg [SLOT_BITS:0] wr_desc,rd_desc,visible;
    reg [DATA_WORD_BITS:0] wr_data,rd_data,frame_base;
    reg [DATA_WORD_BITS-1:0] bases[0:SLOTS-1];
    reg [7:0] lengths_words[0:SLOTS-1];
    reg [11:0] lengths[0:SLOTS-1];
    reg [31:0] ip_sums[0:SLOTS-1],l4_sums[0:SLOTS-1];
    reg ip_good[0:SLOTS-1],l4_good[0:SLOTS-1];
    reg active,aborted,full_abort;
    reg [7:0] index16;
    wire [DATA_WORD_BITS:0] used=wr_data-rd_data;
    assign queue_used=wr_desc-rd_desc;
    wire no_desc=queue_used==SLOTS, no_data=used==DEPTH;
    wire accept=s_valid && !(active?aborted:no_desc) && !no_data && index16<95;
    assign full_start=s_valid && !(active && aborted) && ((!active && no_desc)||no_data);
    function automatic [4:0] byte_count(input [15:0] mask);
        // Legal AXIS keep is a contiguous low prefix; priority encode its last byte.
        byte_count=0;
        for(integer i=0;i<16;i=i+1) if(mask[i]) byte_count=i+1;
    endfunction
    wire keep_ok=s_keep!=0 && (s_keep&(s_keep+16'd1))==0;
    wire [12:0] total_bytes={1'b0,index16,4'b0}+byte_count(s_keep);
    wire publish=accept && s_last && !s_bad && keep_ok && total_bytes>=14 && total_bytes<=1514;
    wire [SLOT_BITS-1:0] head=rd_desc[SLOT_BITS-1:0],tail=wr_desc[SLOT_BITS-1:0];
    assign available=visible!=rd_desc;
    assign frame_length=lengths[head];
    assign frame_ip_sum=ip_sums[head]; assign frame_l4_sum=l4_sums[head];
    assign frame_ip_valid=ip_good[head];assign frame_l4_valid=l4_good[head];
    // Aligned writes; any unaligned 16-byte read can touch two adjacent rows.
    wire [DATA_WORD_BITS-1:0] read_base=bases[head]+read_addr[10:4];
    wire [DATA_WORD_BITS-1:0] next_base=read_base+1'b1;
    reg [3:0] read_lane;
    wire [127:0] bank_data;
    for(genvar b=0;b<16;b=b+1) begin: bytes
        (* ram_style="block" *) reg [7:0] mem[0:DEPTH-1];
        reg [7:0] q;
        always @(posedge clk) begin
            if(accept && s_keep[b]) mem[wr_data[DATA_WORD_BITS-1:0]]<=s_data[8*b+:8];
            q<=mem[b<read_addr[3:0]?next_base:read_base];
        end
        assign bank_data[b*8+:8]=q;
        wire [3:0] lane=read_lane+b;
        assign read_data128[b*8+:8]=bank_data[lane*8+:8];
    end
    always @(posedge clk) read_lane<=read_addr[3:0];
    assign read_data=read_data128[63:0];
    for(genvar h=0;h<6;h=h+1) begin: hdr
        (* ram_style="distributed" *) reg [127:0] mem[0:SLOTS-1];
        always @(posedge clk) if(accept && index16==h) mem[tail]<=s_data;
        assign frame_header[h*128+:128]=mem[head];
    end
    always @(posedge clk) begin
        if(rst) begin
            wr_desc<=0;rd_desc<=0;wr_data<=0;rd_data<=0;frame_base<=0;
            active<=0;aborted<=0;full_abort<=0;index16<=0;
            frames<=0;bad_frames<=0;dropped<=0;full_drops<=0;format_drops<=0;
            queue_highwater<=0;words_highwater<=0;
        end else begin
            if(queue_used>queue_highwater) queue_highwater<=queue_used;
            if(used>words_highwater) words_highwater<=used;
            if(pop && available) begin rd_desc<=rd_desc+1'b1;rd_data<=rd_data+lengths_words[head];end
            if(s_valid) begin
                if(!active) begin frame_base<=wr_data;aborted<=no_desc||no_data;full_abort<=no_desc||no_data;end
                if(no_data) begin aborted<=1;full_abort<=1;end
                if(!keep_ok || (!s_last && !(&s_keep)) || index16>=94) aborted<=1;
                if(accept) wr_data<=wr_data+1'b1;
                active<=!s_last;
                if(s_last) begin
                    index16<=0;aborted<=0;full_abort<=0;
                    if(publish) begin
                        bases[tail]<=active?frame_base[DATA_WORD_BITS-1:0]:wr_data[DATA_WORD_BITS-1:0];
                        lengths[tail]<=total_bytes[11:0];lengths_words[tail]<=index16+1'b1;
                        wr_desc<=wr_desc+1'b1;frames<=frames+1'b1;
                    end else begin
                        wr_data<=active?frame_base:wr_data;
                        if(s_bad) bad_frames<=bad_frames+1'b1;
                        else begin
                            dropped<=dropped+1'b1;
                            if(no_data || (active?full_abort:no_desc)) full_drops<=full_drops+1'b1;
                            else format_drops<=format_drops+1'b1;
                        end
                    end
                end else if(index16!=8'hff) index16<=index16+1'b1;
            end
            if(clear_statistics) begin full_drops<=0;format_drops<=0;queue_highwater<=queue_used;words_highwater<=used;end
        end
    end

    // Header bytes 14..33 are IPv4. Transport checksum stops at the end of the IP
    // datagram, so Ethernet padding and an odd trailing byte are handled separately.
    reg [16:0] ip_end;
    reg [15:0] ip_length,src0,src1,dst0,dst1;
    reg [7:0] proto;
    always @(posedge clk) if(s_valid) begin
        if(index16==1) begin
            ip_length<={s_data[7:0],s_data[15:8]};
            ip_end<={1'b0,s_data[7:0],s_data[15:8]}+17'd14;
            proto<=s_data[63:56];
            src0<={s_data[87:80],s_data[95:88]};src1<={s_data[103:96],s_data[111:104]};
            dst0<={s_data[119:112],s_data[127:120]};
        end
        if(index16==2) dst1<={s_data[7:0],s_data[15:8]};
    end
    wire [16:0] pseudo_src={1'b0,src0}+src1;
    wire [16:0] pseudo_dst={1'b0,dst0}+dst1;
    wire [17:0] pseudo_length={2'd0,ip_length}+{10'd0,proto}-18'd20;
    wire [17:0] pseudo_addresses={1'b0,pseudo_src}+pseudo_dst;
    reg [18:0] pseudo0;
    wire same_end=index16==ip_end[16:4];
    wire before_end=index16<ip_end[16:4];
    reg [15:0] ipword[0:7],l4word[0:7];
    for(genvar j=0;j<8;j=j+1) begin:sums
        wire in_ip=(index16==0 && j==7)||index16==1||(index16==2 && j==0);
        wire l4=(index16>2)||(index16==2 && j>=1);
        wire hi=l4 && s_keep[2*j] && (before_end||(same_end && 2*j<ip_end[3:0]));
        wire lo=l4 && s_keep[2*j+1] && (before_end||(same_end && 2*j+1<ip_end[3:0]));
        always @(posedge clk) begin
            ipword[j]<={in_ip&&s_keep[j*2]?s_data[16*j+:8]:8'd0,in_ip&&s_keep[2*j+1]?s_data[16*j+8+:8]:8'd0};
            l4word[j]<={hi?s_data[16*j+:8]:8'd0,lo?s_data[16*j+8+:8]:8'd0};
        end
    end
    reg [16:0] ip_pair[0:3],l4_pair[0:3];
    for(genvar j=0;j<4;j=j+1) always @(posedge clk) begin
        ip_pair[j]<={1'b0,ipword[2*j]}+ipword[2*j+1];
        l4_pair[j]<={1'b0,l4word[2*j]}+l4word[2*j+1];
    end
    reg [17:0] ip_half[0:1],l4_half[0:1];
    for(genvar j=0;j<2;j=j+1) always @(posedge clk) begin
        ip_half[j]<={1'b0,ip_pair[2*j]}+ip_pair[2*j+1];
        l4_half[j]<={1'b0,l4_pair[2*j]}+l4_pair[2*j+1];
    end
    reg [18:0] ip_beat,l4_beat;
    reg [3:0] v,first,last_commit;
    reg [SLOT_BITS-1:0] tags[0:3];
    reg [18:0] pseudo1,pseudo2,pseudo3;
    reg [31:0] ip_acc,l4_acc,final_ip,final_l4;
    reg [18:0] final_pseudo;
    reg commit0,commit1;
    reg [SLOT_BITS-1:0] slot0,slot1;
    reg [31:0] ip_q,l4_q;
    function automatic [15:0] fold(input [31:0] x);
        reg [16:0] sum;
        begin sum={1'b0,x[31:16]}+x[15:0];fold=sum[15:0]+sum[16];end
    endfunction
    always @(posedge clk) begin
        ip_beat<={1'b0,ip_half[0]}+ip_half[1];l4_beat<={1'b0,l4_half[0]}+l4_half[1];
        // MAC supplies at least a padded 60-byte Ethernet frame; dst1 is present before its last beat.
        pseudo0<={1'b0,pseudo_addresses}+pseudo_length;
        pseudo1<=pseudo0;pseudo2<=pseudo1;pseudo3<=pseudo2;
        tags[0]<=tail;for(integer j=1;j<4;j=j+1) tags[j]<=tags[j-1];
        if(rst) begin
            v<=0;first<=0;last_commit<=0;commit0<=0;commit1<=0;visible<=0;ip_acc<=0;l4_acc<=0;
        end else begin
            v<={v[2:0],s_valid};first<={first[2:0],!active};
            last_commit<={last_commit[2:0],publish};
            if(v[3]) begin
                ip_acc<=(first[3]?32'd0:ip_acc)+ip_beat;
                l4_acc<=(first[3]?32'd0:l4_acc)+l4_beat;
            end
            commit0<=last_commit[3];commit1<=commit0;
            if(last_commit[3]) begin
                slot0<=tags[3];final_ip<=(first[3]?32'd0:ip_acc)+ip_beat;
                final_l4<=(first[3]?32'd0:l4_acc)+l4_beat;final_pseudo<=pseudo3;
            end
            if(commit0) begin slot1<=slot0;ip_q<=final_ip;l4_q<=final_l4+final_pseudo;
                ip_sums[slot0]<=final_ip;l4_sums[slot0]<=final_l4;end
            if(commit1) begin ip_good[slot1]<=fold(ip_q)==16'hffff;l4_good[slot1]<=fold(l4_q)==16'hffff;visible<=visible+1'b1;end
        end
    end
endmodule
