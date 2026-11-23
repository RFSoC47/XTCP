module xtcp_g10_tcp_core #(
    parameter [47:0] LOCAL_MAC=48'h025100030001,
    parameter [31:0] LOCAL_IP=32'hc0a80a0a,
    parameter [15:0] TCP_PORT=16'd24, RBCP_PORT=16'd4660,
    parameter integer TICK_CYCLES=156250,
    parameter [31:0] ISN_BASE=32'h52440000,
    parameter integer RX_ADDR_BITS=16,
    parameter integer ACK_POLICY_DEFAULT=1,
    parameter integer REORDER_DEFAULT=1,
    parameter integer RECOVERY_EXIT_DEFAULT=1,
    parameter integer LOSS_GUARD_DEFAULT=4,
    parameter integer REORDER_SLOT_BITS=6,
    parameter integer RX_WINDOW_CAP=(1<<RX_ADDR_BITS)-16,
    parameter [31:0] INITIAL_STREAM_OFFSET=0
)(
    input wire XGMII_CLOCK, RSTs,
    input wire [63:0] XGMII_RXD,
    input wire [7:0] XGMII_RXC,
    output wire [63:0] XGMII_TXD,
    output wire [7:0] XGMII_TXC,
    output wire APP_RESET_OUT,
    output wire RBCP_ACT,
    output wire [31:0] RBCP_ADDR,
    output wire RBCP_WE,RBCP_RE,
    output wire [7:0] RBCP_WD,
    input wire RBCP_ACK,
    input wire [7:0] RBCP_RD,
    input wire USER_SESSION_OPEN_REQ,
    output wire USER_SESSION_ESTABLISHED,USER_SESSION_CLOSE_REQ,
    input wire USER_SESSION_CLOSE_ACK,
    input wire [63:0] USER_TX_D,
    input wire [3:0] USER_TX_B,
    output wire USER_TX_AFULL,
    input wire [RX_ADDR_BITS-1:0] USER_RX_SIZE,USER_RX_RADR,
    output wire USER_RX_CLR_ENB,
    input wire USER_RX_CLR_REQ,
    output reg [RX_ADDR_BITS-1:0] USER_RX_WADR,
    output reg [7:0] USER_RX_WENB,
    output reg [63:0] USER_RX_WDAT
);
    wire clk=XGMII_CLOCK, rst=RSTs;
    assign APP_RESET_OUT=rst;
    wire [63:0] mac_rx_data,mac_tx_data;
    wire [7:0] mac_rx_keep,mac_tx_keep;
    wire mac_rx_valid,mac_rx_last,mac_rx_bad,mac_tx_valid,mac_tx_last,mac_tx_ready;
    wire mac_underflow;
    axis_xgmii_rx_64 mac_rx(.clk(clk),.rst(rst),.xgmii_rxd(XGMII_RXD),.xgmii_rxc(XGMII_RXC),
        .m_axis_tdata(mac_rx_data),.m_axis_tkeep(mac_rx_keep),.m_axis_tvalid(mac_rx_valid),
        .m_axis_tlast(mac_rx_last),.m_axis_tuser(mac_rx_bad),.ptp_ts(96'd0),
        .cfg_rx_enable(1'b1),.start_packet(),.error_bad_frame(),.error_bad_fcs());
    axis_xgmii_tx_64 mac_tx(.clk(clk),.rst(rst),.s_axis_tdata(mac_tx_data),.s_axis_tkeep(mac_tx_keep),
        .s_axis_tvalid(mac_tx_valid),.s_axis_tready(mac_tx_ready),.s_axis_tlast(mac_tx_last),
        .s_axis_tuser(1'b0),.xgmii_txd(XGMII_TXD),.xgmii_txc(XGMII_TXC),.ptp_ts(96'd0),
        .m_axis_ptp_ts(),.m_axis_ptp_ts_tag(),.m_axis_ptp_ts_valid(),.cfg_ifg(8'd12),
        .cfg_tx_enable(1'b1),.start_packet(),.error_underflow(mac_underflow));

    wire rx_available;
    wire [11:0] rx_length;
    reg rx_pop;
    reg [10:0] rx_read_addr;
    localparam BG_IDLE=0,BG_REQUEST=1,BG_COPY=2,BG_COMMIT=3,BG_POP_WAIT=4;
    reg [2:0] bg_state;
    reg [10:0] bg_read_addr;
    reg [15:0] bg_left,bg_total;
    reg [31:0] bg_seq;
    wire bg_active=bg_state!=BG_IDLE;
    wire [4:0] bg_n=bg_left>16?5'd16:bg_left[4:0];
    wire [63:0] rx_word;
    wire [127:0] rx_word128;
    wire [31:0] rx_ip_sum,rx_l4_sum;
    wire [767:0] rx_header;
    wire rx_ip_valid,rx_l4_valid;
    reg packet_ip_valid,packet_l4_valid;
    wire [31:0] rx_frames,rx_bad_frames,rx_dropped;
    reg rx_diagnostic_clear;
    wire [31:0] rx_full_drops,rx_format_drops;
    wire [6:0] rx_queue_used,rx_queue_highwater;
    wire [13:0] rx_words_highwater;
    wire rx_full_start;
    reg [31:0] rx_first_full_context;
    xtcp_g10_frame_rx packets(.clk(clk),.rst(rst),.s_data(mac_rx_data),.s_keep(mac_rx_keep),
        .s_valid(mac_rx_valid),.s_last(mac_rx_last),.s_bad(mac_rx_bad),
        .clear_statistics(rx_diagnostic_clear),.full_drops(rx_full_drops),.format_drops(rx_format_drops),
        .queue_used(rx_queue_used),.queue_highwater(rx_queue_highwater),.words_highwater(rx_words_highwater),.full_start(rx_full_start),
        .available(rx_available),.frame_length(rx_length),.pop(rx_pop),
        .read_addr(bg_active?bg_read_addr:rx_read_addr),.read_data(rx_word),.read_data128(rx_word128),.frame_ip_sum(rx_ip_sum),.frame_l4_sum(rx_l4_sum),.frames(rx_frames),
        .bad_frames(rx_bad_frames),.dropped(rx_dropped),.frame_header(rx_header),
        .frame_ip_valid(rx_ip_valid),.frame_l4_valid(rx_l4_valid));

    wire [15:0] tx_write_en;
    wire tx_start;
    wire [1:0] tx_frame_kind,builder_published_kind;
    wire [31:0] builder_cancelled,queued_tcp_cancelled;
    reg tx_flush;
    wire [10:0] tx_write_addr;
    wire [127:0] tx_write_data;
    wire [11:0] tx_length;
    wire tx_busy,tx_done;
    xtcp_g10_frame_tx transmitter(.clk(clk),.rst(rst),.flush(tx_flush),.write_en(tx_write_en),.write_addr(tx_write_addr),
        .write_data(tx_write_data),.start(tx_start),.length(tx_length),.frame_kind(tx_frame_kind),
        .cancelled_count(queued_tcp_cancelled),.busy(tx_busy),.done(tx_done),
        .m_data(mac_tx_data),.m_keep(mac_tx_keep),.m_valid(mac_tx_valid),
        .m_last(mac_tx_last),.m_ready(mac_tx_ready));

    localparam LISTEN=0,SYN_RCVD=1,ESTABLISHED=2,CLOSE_WAIT=3,LAST_ACK=4;
    reg [2:0] tcp_state;
    assign USER_SESSION_ESTABLISHED=tcp_state>=ESTABLISHED;
    assign USER_SESSION_CLOSE_REQ=tcp_state==CLOSE_WAIT || tcp_state==LAST_ACK;
    assign USER_RX_CLR_ENB=tcp_state==LISTEN || tcp_state==SYN_RCVD;
    wire [31:0] tx_written,tx_overflows;
    reg [31:0] tx_acked;
    localparam [31:0] TX_FLIGHT_CAP=262144-256;
    wire [17:0] store_read_addr;
    wire [127:0] store_word;
    xtcp_g10_tx_store #(.INITIAL_OFFSET(INITIAL_STREAM_OFFSET)) retained(.clk(clk),.clear(rst || tcp_state<ESTABLISHED),
        .enabled(USER_SESSION_ESTABLISHED),.data(USER_TX_D),.bytes(USER_TX_B),
        .acknowledged(tx_acked),.written(tx_written),.afull(USER_TX_AFULL),
        .read_addr(store_read_addr),.read_data(store_word),.overflow_count(tx_overflows));

    function automatic [15:0] fold(input [31:0] value);
        reg [16:0] temp;
        begin temp={1'b0,value[15:0]}+{1'b0,value[31:16]}; fold=temp[15:0]+temp[16]; end
    endfunction
    function automatic seq_lt(input [31:0] a,b); seq_lt=$signed(a-b)<0; endfunction
    function automatic seq_le(input [31:0] a,b); seq_le=$signed(a-b)<=0; endfunction
    function automatic [31:0] min32(input [31:0] a,b); min32=a<b?a:b; endfunction

    reg [31:0] tick_count,ms_now;
    always @(posedge clk) begin
        if(rst) begin tick_count<=0;ms_now<=0;end
        else if(tick_count==TICK_CYCLES-1) begin tick_count<=0;ms_now<=ms_now+1'b1;end
        else tick_count<=tick_count+1'b1;
    end
    wire [31:0] next_isn=ISN_BASE+{ms_now[23:0],8'd0};
    reg [31:0] data_base,snd_una,snd_nxt,rcv_nxt,irs,fin_seq;
    reg [31:0] snd_wl1,snd_wl2;
    reg [47:0] peer_mac;
    reg [31:0] peer_ip;
    reg [15:0] peer_port,peer_window_raw,peer_mss;
    reg [31:0] peer_window;
    reg [3:0] peer_window_shift;
    reg window_scale_enabled;
    reg [31:0] cwnd,ssthresh,ca_credit;
    reg [2:0] dup_acks;
    reg in_recovery,partial_seen;
    reg recovery_exit_policy,burst_active;
    reg reorder_enable;
    reg [7:0] loss_guard_units;
    reg guard_clear_statistics;
    reg [639:0] guard_snapshot;
    reg [255:0] ownership_snapshot;
    // snd_nxt remains the highest sequence ever sent (ACK/retention boundary).
    // A timeout starts a separate replay pass. Only bytes issued in that pass
    // consume its congestion credit; cumulative ACK may legitimately skip ahead
    // when the peer retained old data. No new data precedes replay completion.
    reg rto_active;
    reg [31:0] rto_cursor,rto_replays;
    reg [31:0] burst_budget,recovery_exits,burst_wait_cycles;
    // Exclusive boundary: RFC6582's highest transmitted byte plus one.
    reg [31:0] recover_end;
    // Remember the first validated ACK strictly beyond this recovery boundary.
    // Its sequence number can become arbitrarily old during a long connection.
    reg recovery_boundary_passed;

    reg [3:0] retries;
    reg [15:0] rto_ms,persist_ms;
    reg [31:0] retry_stamp,persist_stamp;
    reg [31:0] srtt8,rttvar4,rtt_start,rtt_end_seq;
    reg rtt_active,rtt_valid;
    reg [7:0] app_quiet;
    reg need_ack,need_syn,need_retx;
    reg ack_coalesce;
    reg ack_policy;
    reg [9:0] ack_delay_count;
    // A full-segment ACK waits for one more segment, at most4us.
    localparam [9:0] ACK_DELAY_CLOCKS=625;
    reg [1:0] ack_segments;
    reg [15:0] last_advertised_window;
    reg [31:0] last_advertised_right;
    // The default ports remain 16 bits. RDX051 selects an actual 256KiB RAM.
    // SYN windows are never scaled. Without peer WS, retain a 65520-byte cap.
    localparam integer LOCAL_WINDOW_SHIFT=RX_ADDR_BITS>16 ? RX_ADDR_BITS-16 : 0;
    wire [3:0] own_window_shift=window_scale_enabled ? LOCAL_WINDOW_SHIFT : 0;
    wire [RX_ADDR_BITS-1:0] rx_occupied=USER_RX_WADR-USER_RX_RADR;
    wire [RX_ADDR_BITS-1:0] rx_free=rx_occupied>=USER_RX_SIZE ? 0 : USER_RX_SIZE-rx_occupied;
    wire [31:0] receive_capacity=window_scale_enabled ? RX_WINDOW_CAP : min32(RX_WINDOW_CAP,65520);
    wire [31:0] receive_window=min32({{(32-RX_ADDR_BITS){1'b0}},rx_free}+delivery_committed_pending,receive_capacity);
    wire [15:0] receive_wire_window=receive_window>>own_window_shift;
    wire [31:0] advertised_bytes={16'd0,receive_wire_window}<<own_window_shift;
    wire [15:0] syn_window=min32(receive_window,65520);
    // Return significant newly available credit even if the old window was
    // positive. Track the right edge so newly ACKed bytes alone do not imply
    // free storage. Threshold follows receiver silly-window avoidance.
    wire [31:0] credit_threshold=(USER_RX_SIZE>>1)<peer_mss ?
        ((USER_RX_SIZE>>1)!=0 ? (USER_RX_SIZE>>1) : 1) : {16'd0,peer_mss};
    wire [31:0] receive_right=rcv_nxt+advertised_bytes;
    wire [31:0] flight=snd_nxt-snd_una;
    wire [31:0] send_limit=min32(peer_window,cwnd);
    wire [31:0] unsent=tx_written-(snd_nxt-data_base);
    wire [15:0] burst_length_limit=burst_active && burst_budget<peer_mss?burst_budget[15:0]:peer_mss;
    wire [31:0] new_length=min32({16'd0,burst_length_limit},min32(unsent,send_limit>flight?send_limit-flight:0));
    wire [31:0] replay_length=min32({16'd0,peer_mss},min32(snd_nxt-snd_una,data_base+tx_written-snd_una));
    wire [31:0] rto_pipe=rto_active ? rto_cursor-snd_una : 0;
    wire [31:0] rto_length=min32({16'd0,peer_mss},
        min32(snd_nxt-rto_cursor,send_limit>rto_pipe?send_limit-rto_pipe:0));
    wire [31:0] rto_first_length=min32(replay_length,peer_window);

    reg [31:0] bad_ip,bad_transport,bad_sequence,bad_ack,retransmits,tx_frames,underflows;
    reg [1919:0] diagnostic_snapshot;
    reg [31:0] rx_old_segments,rx_future_segments,rx_other_segments;
    reg first_bad_valid;
    reg [31:0] first_bad_seq,first_bad_nxt,first_bad_last,first_bad_meta,first_bad_ms,first_bad_id,first_bad_ack;
    reg [31:0] tx_timeout_events,tx_fast_events,tx_partial_events,pure_ack_descriptors,duplicate_ack_descriptors;
    reg last_ack_valid;
    reg [31:0] last_ack_value;
    reg [15:0] last_ack_window;
    reg [31:0] snapshot_id;
    reg [7:0] diagnostic_byte;
    always @* begin
        diagnostic_byte=0;
        case(RBCP_ADDR[7:0])
            0:diagnostic_byte="R";1:diagnostic_byte="D";2:diagnostic_byte="X";3:diagnostic_byte="T";
            4:diagnostic_byte=0;5:diagnostic_byte=11;6:diagnostic_byte=0;7:diagnostic_byte=18;
            9:diagnostic_byte={7'd0,ack_policy};
            11:diagnostic_byte={7'd0,reorder_enable};
            12:diagnostic_byte={7'd0,recovery_exit_policy};
            13:diagnostic_byte=loss_guard_units;
            default:if(RBCP_ADDR[7:0]>=16)
                diagnostic_byte=diagnostic_snapshot[1919-8*(RBCP_ADDR[7:0]-16)-:8];
        endcase
    end

    // Only a validated complete packet may reach the protocol decision states.
    reg [7:0] hdr[0:95];
    wire [7:0] udp_data[0:7];
    wire [7:0] udp_builder_data;
    // Validated 96-byte header already includes the complete eight-byte RBCP
    // header. A read request has no body to transfer through packet RAM.
    for(genvar h=0;h<8;h=h+1) assign udp_data[h]=hdr[42+h];
    reg [11:0] packet_length;
    reg [10:0] index;
    reg [31:0] ip_sum,l4_sum;
    wire [47:0] src_mac={hdr[6],hdr[7],hdr[8],hdr[9],hdr[10],hdr[11]};
    wire [47:0] dst_mac={hdr[0],hdr[1],hdr[2],hdr[3],hdr[4],hdr[5]};
    wire [15:0] eth_type={hdr[12],hdr[13]};
    wire [15:0] ip_length={hdr[16],hdr[17]};
    wire [31:0] src_ip={hdr[26],hdr[27],hdr[28],hdr[29]};
    wire [31:0] dst_ip={hdr[30],hdr[31],hdr[32],hdr[33]};
    wire [15:0] src_port={hdr[34],hdr[35]},dst_port={hdr[36],hdr[37]};
    wire [31:0] seg_seq={hdr[38],hdr[39],hdr[40],hdr[41]};
    wire [31:0] seg_ack={hdr[42],hdr[43],hdr[44],hdr[45]};
    wire [15:0] seg_window={hdr[48],hdr[49]};
    wire [7:0] seg_flags=hdr[47];
    wire [7:0] tcp_header_length={2'd0,hdr[46][7:4],2'd0};
    wire [15:0] payload_length=ip_length-16'd20-tcp_header_length;
    wire [31:0] pseudo_sum={16'd0,src_ip[31:16]}+{16'd0,src_ip[15:0]}+
        {16'd0,LOCAL_IP[31:16]}+{16'd0,LOCAL_IP[15:0]}+hdr[23]+ip_length-20;
    wire tuple_match=src_ip==peer_ip && src_port==peer_port;
    // RFC9293 section3.10.7.4: validate receive-window overlap, then
    // process ACK independently of whether payload can be delivered in order.
    // SYN/RST handling remains above the ordinary established-segment path.
    wire [31:0] seg_span={16'd0,payload_length}+{31'd0,seg_flags[0]};
    wire [31:0] seg_last=seg_seq+seg_span-1'b1;
    wire seg_first_in_window=!seq_lt(seg_seq,rcv_nxt) && seq_lt(seg_seq,rcv_nxt+receive_window);
    wire seg_last_in_window=!seq_lt(seg_last,rcv_nxt) && seq_lt(seg_last,rcv_nxt+receive_window);
    wire segment_acceptable=seg_span==0 ?
        (receive_window==0 ? seg_seq==rcv_nxt : seg_first_in_window) :
        (receive_window!=0 && (seg_first_in_window || seg_last_in_window));
    wire [31:0] skip_bytes=rcv_nxt-seg_seq;
    wire [31:0] following_bytes={16'd0,payload_length}-skip_bytes;
    wire [31:0] accept_bytes=min32(following_bytes,receive_window);
    wire common_tcp=eth_type==16'h0800 && dst_mac==LOCAL_MAC && packet_length>=54 &&
        hdr[14]==8'h45 && ip_length>=40 && ip_length<=1500 && packet_length>=14+ip_length &&
        dst_ip==LOCAL_IP && hdr[22]!=0 && (hdr[20]&8'hbf)==0 && hdr[21]==0 && packet_ip_valid &&
        hdr[23]==6 && dst_port==TCP_PORT && tcp_header_length==20 && packet_l4_valid &&
        (seg_flags&8'h36)==8'h10 && tuple_match && tcp_state==ESTABLISHED &&
        segment_acceptable && !seq_lt(snd_nxt,seg_ack);

    // Classify at the validated protocol decision, unaffected by host capture.
    task automatic sequence_event(input [1:0] category);
        begin
            bad_sequence<=bad_sequence+1'b1;
            if(category==1) rx_old_segments<=rx_old_segments+1'b1;
            else if(category==2) rx_future_segments<=rx_future_segments+1'b1;
            else rx_other_segments<=rx_other_segments+1'b1;
            if(!first_bad_valid) begin
                first_bad_valid<=1;first_bad_seq<=seg_seq;first_bad_nxt<=rcv_nxt;
                first_bad_last<=seg_last;first_bad_meta<={payload_length,seg_flags,5'd0,1'b1,category};
                first_bad_ms<=ms_now;first_bad_id<={16'd0,hdr[18],hdr[19]};first_bad_ack<=seg_ack;
            end
        end
    endtask

    wire [31:0] recovery_threshold=flight/2>peer_mss*2?flight/2:peer_mss*2;
    wire [31:0] ack_advanced=seg_ack-snd_una;
    wire [31:0] partial_deflated=cwnd>ack_advanced?cwnd-ack_advanced:0;
    wire [31:0] partial_window=partial_deflated+(ack_advanced>=peer_mss?{16'd0,peer_mss}:0);
    wire [31:0] flight_after_ack=snd_nxt-seg_ack;
    wire [31:0] burst_refill=min32(TX_FLIGHT_CAP,burst_budget+ack_advanced+peer_mss);

    // A bounded payload cache never increases the advertised application window.
    // Validated future segments process their ACK once, then retain only payload/FIN.
    localparam integer REORDER_SLOTS=1<<REORDER_SLOT_BITS;
    reg [REORDER_SLOTS-1:0] reorder_valid;
    reg [31:0] reorder_seq[0:REORDER_SLOTS-1];
    reg [15:0] reorder_length[0:REORDER_SLOTS-1];
    reg reorder_fin[0:REORDER_SLOTS-1];
    reg [REORDER_SLOT_BITS:0] reorder_count,reorder_scan_steps;
    reg [REORDER_SLOT_BITS-1:0] reorder_alloc,reorder_store_slot,reorder_scan,reorder_checked_slot;
    reg reorder_scan_pending,reorder_checked_valid;
    reg reorder_scan_dirty;
    reg reorder_head_valid,reorder_scan_min_valid;
    reg [31:0] reorder_head_seq,reorder_scan_min_seq;
    reg [31:0] reorder_checked_seq;
    reg [15:0] reorder_checked_length;
    reg reorder_checked_fin;
    reg [31:0] reorder_stored,reorder_full,reorder_replayed,reorder_retired,reorder_highwater;
    reg cache_write_en;
    reg [10:0] cache_write_addr,cache_read_addr;
    reg [127:0] cache_write_data;
    reg [15:0] cache_write_keep;
    wire [63:0] cache_read_data;
    wire copy_to_cache=bg_active; // coherent diagnostic context
    // Delivery owns cache read/application write independently of ingress.
    localparam D_IDLE=0,D_SCAN=1,D_MATCH=2,D_REQ=3,D_COPY=4,D_COMMIT=5;
    reg [2:0] delivery_state;
    reg [15:0] delivery_left,delivery_total;
    reg delivery_fin,delivery_release;
    wire delivery_active=delivery_state!=D_IDLE;
    wire copy_from_cache=delivery_state==D_REQ || delivery_state==D_COPY || delivery_state==D_COMMIT;
    reg [31:0] pending_cache_seq;
    reg [10:0] pending_cache_addr;
    // WADR counts committed writes. The current registered write has not yet
    // landed; do not include it in the temporary unACKed-write compensation.
    wire [31:0] delivery_committed_pending=copy_from_cache ?
        {16'd0,delivery_total}-{16'd0,delivery_left}-(USER_RX_WENB!=0?{28'd0,pending_write_bytes}:32'd0) : 32'd0;
    wire [31:0] future_gap=seg_seq-rcv_nxt;
    wire [31:0] future_room=receive_window>future_gap?receive_window-future_gap:0;
    wire [31:0] future_bytes=min32(payload_length,future_room);
    wire future_fin=seg_flags[0] && future_room>payload_length;
    wire [31:0] cached_end=reorder_checked_seq+reorder_checked_length+reorder_checked_fin;
    wire [31:0] cached_skip=rcv_nxt-reorder_checked_seq;
    wire [31:0] cached_remaining={16'd0,reorder_checked_length}-cached_skip;
    wire [31:0] cached_accept=min32(cached_remaining,receive_window);
    wire cached_accept_fin=reorder_checked_fin && receive_window>cached_remaining;
    xtcp_g10_rx_reorder_mem #(.SLOT_BITS(REORDER_SLOT_BITS),.WRITE_BYTES(16)) reorder_payload(
        .clk(clk),.write_en(cache_write_en),.write_slot(reorder_store_slot),.write_addr(cache_write_addr),
        .write_data(cache_write_data),.write_keep(cache_write_keep),
        .read_slot(reorder_checked_slot),.read_addr(cache_read_addr),.read_data(cache_read_data));

    reg [7:0] option_index,option_end;
    // Only bytes54..93 can contain TCP options. A9-bit next-position check
    // establishes the range invariant before committing an8-bit parser index.
    wire [7:0] option_window[0:39];
    for(genvar ob=0;ob<40;ob=ob+1) begin: tcp_option_bytes
        assign option_window[ob]=hdr[54+ob];
    end
    wire [5:0] option_offset=option_index-8'd54;
    wire [7:0] option_byte0=option_window[option_offset];
    wire [7:0] option_byte1=option_window[option_offset+6'd1];
    wire [7:0] option_byte2=option_window[option_offset+6'd2];
    wire [7:0] option_byte3=option_window[option_offset+6'd3];
    wire [8:0] option_next={1'b0,option_index}+{1'b0,option_byte1};

    reg [15:0] parsed_mss;
    reg parsed_window_scale;
    reg [3:0] parsed_window_shift;
    wire [31:0] segment_window_bytes={16'd0,seg_window} << peer_window_shift;
    reg [15:0] copy_left,copy_total;
    reg copy_fin;

    // Response metadata is frozen before constructing a complete TX frame.
    localparam KIND_TCP=0,KIND_ARP=1,KIND_UDP=2;
    reg [1:0] tx_kind;
    reg [47:0] out_mac;
    reg [31:0] out_ip,out_seq,out_ack;
    reg [15:0] out_port,out_window,out_payload;
    reg [7:0] out_flags,out_tcp_header;
    reg [3:0] pending_write_bytes;
    wire [RX_ADDR_BITS-1:0] effective_wadr=USER_RX_WADR+(USER_RX_WENB!=0?pending_write_bytes:0);
    wire [3:0] copy_room=4'd8-{1'b0,effective_wadr[2:0]};
    wire [15:0] app_copy_left=copy_from_cache?delivery_left:copy_left;
    wire [3:0] copy_n=app_copy_left<copy_room ? app_copy_left[3:0] : copy_room;
    wire [63:0] copy_input=copy_from_cache?cache_read_data:rx_word;
    reg [63:0] copy_word;
    reg [7:0] copy_mask;
    always @* begin
        copy_word=0;copy_mask=0;
        for(integer k=0;k<8;k=k+1) if(k<copy_n) begin
            copy_word[63-(effective_wadr[2:0]+k)*8-:8]=copy_input[k*8+:8];
            copy_mask[7-(effective_wadr[2:0]+k)]=1;
        end
    end
    reg control_request_valid,control_body_valid,control_request_reject;
    reg control_response_grant;
    reg [63:0] control_body_data;
    reg [3:0] control_body_bytes;
    reg [7:0] control_fill_left;
    wire control_request_ready,control_response_valid;
    wire control_internal_commit,control_internal_write;
    wire [47:0] control_response_mac;
    wire [31:0] control_response_ip;
    wire [15:0] control_response_port;
    wire [8:0] control_response_length;
    wire [31:0] control_admitted,control_published,control_aborted,control_rejected;
    wire [1:0] control_occupied;
    wire control_input_error;
    wire [7:0] control_internal_data=RBCP_ADDR[31:8]==24'h000002 ? diagnostic_byte :
        RBCP_ADDR[7:0]<80 ? guard_snapshot[639-8*RBCP_ADDR[7:0]-:8] :
        (RBCP_ADDR[7:0]>=128 && RBCP_ADDR[7:0]<160) ? ownership_snapshot[255-8*(RBCP_ADDR[7:0]-128)-:8] : 8'd0;
    reg control_last_grant;
    reg builder_valid;
    // Builder owns one control slot from grant to publication/cancellation.
    // A second queued transaction has separate metadata and body storage.
    reg udp_body_busy;
    wire builder_ready,builder_published;
    wire [8:0] builder_udp_addr;
    xtcp_g10_packet_builder #(.LOCAL_MAC(LOCAL_MAC),.LOCAL_IP(LOCAL_IP),.TCP_PORT(TCP_PORT),.RBCP_PORT(RBCP_PORT),.LOCAL_WINDOW_SHIFT(LOCAL_WINDOW_SHIFT))
    builder(.clk(clk),.rst(rst),.flush(tx_flush),.descriptor_valid(builder_valid),.descriptor_ready(builder_ready),
        .descriptor_kind(tx_kind),.descriptor_mac(out_mac),.descriptor_ip(out_ip),.descriptor_seq(out_seq),
        .descriptor_ack(out_ack),.descriptor_offset(out_seq-data_base),.descriptor_port(out_port),
        .descriptor_window(out_window),.descriptor_payload(out_payload),.descriptor_flags(out_flags),
        .descriptor_tcp_header(out_tcp_header),.store_read_addr(store_read_addr),.store_read_data(store_word),
        .udp_read_addr(builder_udp_addr),.udp_read_data(udp_builder_data),
        .write_en(tx_write_en),.write_addr(tx_write_addr),.write_data(tx_write_data),
        .frame_start(tx_start),.frame_length(tx_length),.frame_busy(tx_busy),.published(builder_published),
        .frame_kind(tx_frame_kind),.published_kind(builder_published_kind),.cancelled_count(builder_cancelled));

    localparam IDLE=0,R_REQ=1,R_BYTE=2,R_CHECK=3,R_IP=4,R_TCP=5,R_OPTIONS=6,R_DECIDE=7,
        R_ACK=8,R_DATA=9,R_COPY_REQ=10,R_COPY_WRITE=11,R_COPY_ADV=12,R_COPY_END=13,
        RELEASE=14,RELEASE_WAIT=15,R_UDP=16,R_BUS_REQ=17,R_BUS_WAIT=18,R_BUS_GAP=19,
        R_UDP_REPLY=20,T_SETUP=21,R_REORDER_ALLOC=22,R_REORDER_SCAN=23,R_REORDER_MATCH=24,
        R_CONTROL_REQ=25,R_CONTROL_COPY=26,T_WAIT=30;
    reg [5:0] state;
    wire [6:0] rx_reorder_count_low=reorder_count;

    xtcp_g10_rbcp_engine control_engine(.clk(clk),.rst(rst),
        .request_valid(control_request_valid),.request_ready(control_request_ready),
        .request_mac(src_mac),.request_ip(src_ip),.request_port(src_port),
        .request_address({udp_data[4],udp_data[5],udp_data[6],udp_data[7]}),
        .request_command(udp_data[1]),.request_id(udp_data[2]),.request_length(udp_data[3]),
        .body_valid(control_body_valid),.body_data(control_body_data),.body_bytes(control_body_bytes),
        .request_reject(control_request_reject),.response_valid(control_response_valid),
        .response_grant(control_response_grant),.response_published(builder_published && builder_published_kind==KIND_UDP),
        .response_abort(1'b0),
        .response_mac(control_response_mac),.response_ip(control_response_ip),.response_port(control_response_port),
        .response_length(control_response_length),.response_read_addr(builder_udp_addr),.response_read_data(udp_builder_data),
        .RBCP_ACT(RBCP_ACT),.RBCP_ADDR(RBCP_ADDR),.RBCP_WE(RBCP_WE),.RBCP_RE(RBCP_RE),.RBCP_WD(RBCP_WD),
        .RBCP_ACK(RBCP_ACK),.RBCP_RD(RBCP_RD),.internal_commit(control_internal_commit),
        .internal_write(control_internal_write),.internal_read_data(control_internal_data),
        .admitted_count(control_admitted),.published_count(control_published),
        .aborted_count(control_aborted),.rejected_count(control_rejected),.occupied(control_occupied),
        .input_contract_error(control_input_error));

    // Ingress no longer time-shares the cache scan/copy FSM. A single
    // application writer is reserved at delivery start; parser may keep running.
    wire direct_copy_owned=state==R_COPY_REQ || state==R_COPY_WRITE || state==R_COPY_END;
    // Scanning metadata never owns the app write port. At a useful match,
    // the ingress R_DATA decision wins a same-edge direct-copy request.
    wire delivery_start_safe=1'b1;
    wire delivery_waits_for_writer=delivery_state==D_MATCH && reorder_checked_valid &&
        seq_le(reorder_checked_seq,rcv_nxt) && !seq_le(cached_end,rcv_nxt) &&
        (direct_copy_owned || state==R_DATA);

    wire schedule_safe=state==IDLE || state==R_DATA || state==R_COPY_REQ || state==RELEASE || state==RELEASE_WAIT;
    wire pure_ack_safe=state==IDLE || state==RELEASE || state==RELEASE_WAIT;
    wire data_ready=!rto_active && (tcp_state==ESTABLISHED || tcp_state==CLOSE_WAIT) &&
        seq_lt(snd_nxt,data_base+tx_written) && new_length!=0 && (unsent>=peer_mss || app_quiet>=64);
    wire rto_ready=rto_active && (tcp_state==ESTABLISHED || tcp_state==CLOSE_WAIT) &&
        seq_lt(rto_cursor,snd_nxt) && rto_length!=0;
    wire retx_ready=need_retx && (!rto_active || peer_window!=0);
    wire ack_ready=need_ack && pure_ack_safe && (!ack_coalesce || ack_segments>=2 ||
        (ack_policy ? ack_delay_count>=ACK_DELAY_CLOCKS : !rx_available));
    // Wait only a bounded few clocks for the echo application's pipeline so
    // data can carry the ACK; a pure ACK must not wait for a full MSS forever.
    reg [3:0] ack_wait;
    wire echo_pending=(USER_TX_B!=0 || unsent!=0) && app_quiet<8;
    wire send_timeout=tcp_state!=LISTEN && snd_una!=snd_nxt &&
        (peer_window!=0 || tcp_state==SYN_RCVD || tcp_state==LAST_ACK) && (ms_now-retry_stamp)>=rto_ms;
    wire probe_due=(tcp_state==ESTABLISHED || tcp_state==CLOSE_WAIT) &&
        peer_window==0 && tx_written!=tx_acked && (ms_now-persist_stamp)>=persist_ms;
    wire close_ready=tcp_state==CLOSE_WAIT && USER_SESSION_CLOSE_ACK && app_quiet>=64 &&
        tx_written==tx_acked && snd_nxt==snd_una && rx_occupied==0;

    wire guard_pending,guard_ready;
    wire [15:0] guard_age;
    wire [31:0] guard_una,guard_armed,guard_cancelled,guard_confirmed,guard_aborted;
    wire [31:0] guard_max_age,guard_peak_duplicates;
    wire [31:0] guard_first_una,guard_first_nxt,guard_first_cwnd,guard_first_flight;
    wire duplicate_event=state==R_ACK && tcp_state!=SYN_RCVD &&
        seg_ack==snd_una && snd_nxt!=snd_una && payload_length==0 &&
        seg_window==peer_window_raw && seg_window!=0 && !seg_flags[0];
    // A validated zero-window update transfers recovery to the persist path.
    // It must cancel a pending indication before any later safe schedule edge.
    wire guard_eligible=!rto_active && loss_guard_units!=0 && peer_window!=0 && replay_length!=0 &&
        (tcp_state==ESTABLISHED || tcp_state==CLOSE_WAIT);
    wire guard_arm=duplicate_event && !in_recovery && dup_acks==2 &&
        recovery_boundary_passed && guard_eligible;
    wire guard_ack_advance=state==R_ACK && seq_lt(snd_una,seg_ack);
    wire guard_take=guard_ready && guard_pending && snd_una==guard_una &&
        guard_eligible && !in_recovery && !send_timeout && !guard_ack_advance &&
        schedule_safe && builder_ready && !builder_valid && !tx_flush;
    xtcp_g10_loss_guard loss_confirmation(.clk(clk),.rst(rst),
        .clear(!guard_eligible || in_recovery || send_timeout),.clear_statistics(guard_clear_statistics),
        .units(loss_guard_units),.arm(guard_arm),.cancel_ack(guard_ack_advance),.confirm(guard_take),
        .duplicate_event(duplicate_event),.arm_una(snd_una),.arm_nxt(snd_nxt),.arm_cwnd(cwnd),.arm_flight(flight),
        .pending(guard_pending),.ready(guard_ready),.age(guard_age),.pending_una(guard_una),
        .armed_count(guard_armed),.cancelled_count(guard_cancelled),.confirmed_count(guard_confirmed),.aborted_count(guard_aborted),
        .max_age(guard_max_age),.peak_duplicates(guard_peak_duplicates),
        .first_una(guard_first_una),.first_nxt(guard_first_nxt),.first_cwnd(guard_first_cwnd),.first_flight(guard_first_flight));


    // The FSM commits or retires at most one reorder slot on a clock edge.
    // Select the write address once instead of creating independent dynamic
    // vector write ports in each state. Keep LISTEN-clear followed by the
    // selected bit update, matching the former nonblocking-assignment order.
    // Publish only after the last registered memory write can land. Avoid
    // count/valid collisions with retirement; at most one owner commits/edge.
    wire connection_abort=(state==R_DECIDE && tuple_match && seg_flags[2] && seg_seq==rcv_nxt) ||
        (schedule_safe && builder_ready && !builder_valid && !tx_flush && send_timeout &&
         !need_syn && !need_retx && retries==7);
    wire delivery_retire=tcp_state==ESTABLISHED && !connection_abort && !delivery_waits_for_writer &&
        ((delivery_state==D_MATCH && reorder_checked_valid &&
          (seq_le(cached_end,rcv_nxt) || (seq_le(reorder_checked_seq,rcv_nxt) &&
           cached_remaining==0 && reorder_checked_fin && receive_window!=0))) ||
         (delivery_state==D_COMMIT && delivery_release));
    wire bg_commit=bg_state==BG_COMMIT && tcp_state==ESTABLISHED && !connection_abort && !delivery_retire;
    // A negative scan result is valid only if no unseen publication or
    // direct-prefix commit changed the table/sequence during this pass.
    wire scan_restart_required=reorder_scan_dirty || bg_commit || state==R_COPY_END;
    reg reorder_valid_we,reorder_valid_wdata;
    reg [REORDER_SLOT_BITS-1:0] reorder_valid_waddr;
    always @* begin
        reorder_valid_we=0;reorder_valid_wdata=0;
        reorder_valid_waddr=reorder_checked_slot;
        if(bg_commit) begin
            reorder_valid_we=1;reorder_valid_wdata=1;reorder_valid_waddr=reorder_store_slot;
        end else if(delivery_retire) reorder_valid_we=1;
    end
    always @(posedge clk) begin
        if(rst) reorder_valid<=0;
        else begin
            if(tcp_state==LISTEN) reorder_valid<=0;
            if(reorder_valid_we) reorder_valid[reorder_valid_waddr]<=reorder_valid_wdata;
        end
    end

    // Frame memory has its own registered write input: state transitions allow
    // that write to land before a commit/start or a checksum patch is consumed.
    always @(posedge clk) begin
        rx_pop<=0;builder_valid<=0;tx_flush<=0;cache_write_en<=0;guard_clear_statistics<=0;
        rx_diagnostic_clear<=0;
        // Capture protocol context at the first full-queue frame start.
        if(rx_full_start && !rx_first_full_context[31])
            rx_first_full_context<={1'b1,1'b0,state,tcp_state,copy_from_cache,copy_to_cache,
                udp_body_busy,rx_reorder_count_low,rx_queue_used,4'd0};
        if(builder_published && builder_published_kind==KIND_UDP) udp_body_busy<=0;
        USER_RX_WENB<=0;
        control_request_valid<=0;control_body_valid<=0;control_request_reject<=0;control_response_grant<=0;
        if(USER_TX_B!=0) app_quiet<=0;
        else if(app_quiet!=255) app_quiet<=app_quiet+1'b1;
        if(mac_underflow) underflows<=underflows+1'b1;
        if(tx_done) tx_frames<=tx_frames+1'b1;
        if(USER_RX_WENB!=0) USER_RX_WADR<=effective_wadr;
        if(tcp_state==ESTABLISHED && (!ack_policy || !need_ack) && receive_window>=credit_threshold &&
           seq_le(last_advertised_right+credit_threshold,receive_right)) begin
            need_ack<=1;ack_coalesce<=0;
        end
        if(!need_ack) ack_delay_count<=0;
        else if(ack_delay_count!=1023) ack_delay_count<=ack_delay_count+1'b1;
        if(reorder_valid[reorder_alloc]) reorder_alloc<=reorder_alloc+1'b1;
        if(tcp_state==LISTEN) begin
            rto_active<=0;rto_cursor<=0;
            reorder_count<=0;reorder_alloc<=0;
            reorder_scan<=0;reorder_scan_pending<=0;
            reorder_head_valid<=0;
            burst_active<=0;burst_budget<=0;
        end
        if(rst) begin
            rx_diagnostic_clear<=0;rx_first_full_context<=0;
            rto_active<=0;rto_cursor<=0;rto_replays<=0;
            loss_guard_units<=LOSS_GUARD_DEFAULT;guard_clear_statistics<=0;guard_snapshot<=0;ownership_snapshot<=0;
            recovery_exit_policy<=RECOVERY_EXIT_DEFAULT!=0;burst_active<=0;burst_budget<=0;
            recovery_exits<=0;burst_wait_cycles<=0;
            reorder_enable<=REORDER_DEFAULT!=0;reorder_count<=0;reorder_alloc<=0;
            reorder_store_slot<=0;reorder_scan<=0;reorder_checked_slot<=0;reorder_scan_steps<=0;
            reorder_scan_pending<=0;reorder_checked_valid<=0;reorder_checked_seq<=0;reorder_scan_dirty<=0;
            reorder_head_valid<=0;reorder_head_seq<=0;reorder_scan_min_valid<=0;reorder_scan_min_seq<=0;
            reorder_checked_length<=0;reorder_checked_fin<=0;
            reorder_stored<=0;reorder_full<=0;reorder_replayed<=0;reorder_retired<=0;reorder_highwater<=0;
            cache_write_en<=0;cache_write_addr<=0;cache_read_addr<=0;cache_write_data<=0;cache_write_keep<=0;
            bg_state<=BG_IDLE;bg_read_addr<=0;bg_left<=0;bg_total<=0;bg_seq<=0;
            delivery_state<=D_IDLE;delivery_left<=0;delivery_total<=0;delivery_fin<=0;delivery_release<=0;
            pending_cache_seq<=0;pending_cache_addr<=0;
            ack_policy<=ACK_POLICY_DEFAULT!=0;ack_delay_count<=0;
            rx_old_segments<=0;rx_future_segments<=0;rx_other_segments<=0;first_bad_valid<=0;
            first_bad_seq<=0;first_bad_nxt<=0;first_bad_last<=0;first_bad_meta<=0;first_bad_ms<=0;first_bad_id<=0;first_bad_ack<=0;
            tx_timeout_events<=0;tx_fast_events<=0;tx_partial_events<=0;pure_ack_descriptors<=0;duplicate_ack_descriptors<=0;
            last_ack_valid<=0;last_ack_value<=0;last_ack_window<=0;
            state<=IDLE;tcp_state<=LISTEN;
            USER_RX_WADR<=0;USER_RX_WDAT<=0;rx_read_addr<=0;
            builder_valid<=0;udp_body_busy<=0;packet_length<=0;index<=0;
            snd_una<=0;snd_nxt<=0;rcv_nxt<=0;data_base<=0;irs<=0;fin_seq<=0;tx_acked<=INITIAL_STREAM_OFFSET;
            snd_wl1<=0;snd_wl2<=0;peer_mac<=0;peer_ip<=0;peer_port<=0;peer_window<=0;peer_window_raw<=0;peer_mss<=536;
            peer_window_shift<=0;window_scale_enabled<=0;parsed_window_scale<=0;parsed_window_shift<=0;
            cwnd<=536;ssthresh<=TX_FLIGHT_CAP;ca_credit<=0;dup_acks<=0;retries<=0;
            in_recovery<=0;partial_seen<=0;recover_end<=0;
            recovery_boundary_passed<=0;
            rto_ms<=1000;persist_ms<=1000;retry_stamp<=0;persist_stamp<=0;
            srtt8<=0;rttvar4<=0;rtt_start<=0;rtt_end_seq<=0;rtt_active<=0;rtt_valid<=0;
            need_ack<=0;need_syn<=0;need_retx<=0;last_advertised_window<=0;last_advertised_right<=0;app_quiet<=0;
            ack_coalesce<=0;ack_segments<=0;ack_wait<=0;
            bad_ip<=0;bad_transport<=0;bad_sequence<=0;bad_ack<=0;retransmits<=0;
            tx_frames<=0;underflows<=0;diagnostic_snapshot<=0;snapshot_id<=0;
            ip_sum<=0;l4_sum<=0;packet_ip_valid<=0;packet_l4_valid<=0;parsed_mss<=536;option_index<=0;option_end<=0;
            copy_left<=0;copy_total<=0;copy_fin<=0;pending_write_bytes<=0;
            tx_kind<=0;out_mac<=0;out_ip<=0;out_port<=0;out_seq<=0;out_ack<=0;out_flags<=0;
            out_window<=0;out_payload<=0;out_tcp_header<=20;
            control_request_valid<=0;control_body_valid<=0;control_request_reject<=0;control_response_grant<=0;
            control_body_data<=0;control_body_bytes<=0;control_fill_left<=0;control_last_grant<=0;
        end else begin
            if(burst_active && burst_budget==0 && unsent!=0 && tcp_state==ESTABLISHED)
                burst_wait_cycles<=burst_wait_cycles+1'b1;
            if(!need_ack) ack_wait<=0;
            else if(ack_wait!=15) ack_wait<=ack_wait+1'b1;
            // One frozen descriptor at a time, independent of receive copying.
            // R_ACK is excluded so cumulative ACK, recovery and timers have a
            // single ordered owner. Later RX-state assignments take precedence.
            if(schedule_safe && builder_ready && !builder_valid && !tx_flush) begin
                if(send_timeout && !need_syn && !need_retx) begin
                    tx_timeout_events<=tx_timeout_events+1'b1;
                    retry_stamp<=ms_now;retries<=retries+1'b1;rtt_active<=0;
                    rto_ms<=rto_ms>=30000?60000:rto_ms<<1;
                    // Repeated timeout of the same unACKed segment holds the
                    // threshold; an advancing ACK resets retries for a new loss.
                    if(retries==0) ssthresh<=flight/2>peer_mss*2?flight/2:peer_mss*2;
                    cwnd<=peer_mss;ca_credit<=0;dup_acks<=0;
                    in_recovery<=0;partial_seen<=0;recover_end<=snd_nxt;
                    recovery_boundary_passed<=0;
                    rto_active<=(tcp_state==ESTABLISHED || tcp_state==CLOSE_WAIT);
                    rto_cursor<=snd_una;
                    burst_active<=0;burst_budget<=0;
                    if(retries==7) begin
                        tcp_state<=LISTEN;need_ack<=0;need_syn<=0;need_retx<=0;tx_flush<=1;
                    end else if(tcp_state==SYN_RCVD) begin need_syn<=1;retransmits<=retransmits+1'b1;end
                    else need_retx<=1;
                end else if(guard_take) begin
                    // A persistent gap receives the original NewReno response.
                    // Waiting did not increase CWND or bypass the receive window.
                    tx_fast_events<=tx_fast_events+1'b1;
                    need_retx<=1;retry_stamp<=ms_now;rtt_active<=0;
                    recover_end<=snd_nxt;in_recovery<=1;partial_seen<=0;
                    recovery_boundary_passed<=0;
                    burst_active<=0;burst_budget<=0;
                    ssthresh<=recovery_threshold;
                    cwnd<=min32(TX_FLIGHT_CAP,recovery_threshold+peer_mss*3);ca_credit<=0;
                end else if(control_response_valid && (!control_last_grant ||
                    !(need_syn || retx_ready || probe_due || rto_ready || data_ready || ack_ready || close_ready))) begin
                    builder_valid<=1;tx_kind<=KIND_UDP;out_mac<=control_response_mac;
                    out_ip<=control_response_ip;out_port<=control_response_port;
                    out_payload<={7'd0,control_response_length};
                    control_response_grant<=1;udp_body_busy<=1;control_last_grant<=1;
                end else if(need_syn || retx_ready || probe_due || rto_ready || data_ready ||
                   (ack_ready && (!echo_pending || ack_wait>=8)) || close_ready) begin
                    if(!need_syn && !retx_ready && !probe_due && !rto_ready && !data_ready && !close_ready) begin
                        pure_ack_descriptors<=pure_ack_descriptors+1'b1;
                        if(last_ack_valid && last_ack_value==rcv_nxt && last_ack_window==receive_wire_window)
                            duplicate_ack_descriptors<=duplicate_ack_descriptors+1'b1;
                    end
                    last_ack_valid<=1;last_ack_value<=rcv_nxt;last_ack_window<=receive_wire_window;
                    ack_delay_count<=0;
                    control_last_grant<=0;
                    builder_valid<=1;tx_kind<=KIND_TCP;out_mac<=peer_mac;out_ip<=peer_ip;out_port<=peer_port;
                    out_ack<=rcv_nxt;out_window<=receive_wire_window;out_tcp_header<=20;out_payload<=0;
                    out_seq<=snd_nxt;out_flags<=8'h10;last_advertised_window<=receive_wire_window;last_advertised_right<=receive_right;
                    need_ack<=0;ack_coalesce<=0;ack_segments<=0;ack_wait<=0;
                    if(need_syn) begin
                        need_syn<=0;out_seq<=data_base+INITIAL_STREAM_OFFSET-1;out_flags<=8'h12;
                        out_tcp_header<=window_scale_enabled?28:24;
                        out_window<=syn_window;last_advertised_window<=syn_window;
                        last_ack_window<=syn_window;
                        last_advertised_right<=rcv_nxt+{16'd0,syn_window};
                    end else if(retx_ready) begin
                        need_retx<=0;out_seq<=snd_una;out_payload<=replay_length;
                        if(rto_active) begin
                            out_payload<=rto_first_length;
                            if(seq_lt(rto_cursor,snd_una+rto_first_length))
                                rto_cursor<=snd_una+rto_first_length;
                            rto_replays<=rto_replays+1'b1;
                        end
                        if(tcp_state==LAST_ACK && snd_una==fin_seq) begin out_payload<=0;out_flags<=8'h11;end
                        retransmits<=retransmits+1'b1;rtt_active<=0;
                    end else if(probe_due) begin
                        out_seq<=snd_una;out_payload<=1;
                        if(snd_una==snd_nxt) snd_nxt<=snd_nxt+1'b1;
                        persist_stamp<=ms_now;persist_ms<=persist_ms>=30000?60000:persist_ms<<1;rtt_active<=0;
                    end else if(rto_ready) begin
                        out_seq<=rto_cursor;out_payload<=rto_length;
                        rto_cursor<=rto_cursor+rto_length;
                        retransmits<=retransmits+1'b1;rto_replays<=rto_replays+1'b1;rtt_active<=0;
                    end else if(data_ready) begin
                        out_payload<=new_length;snd_nxt<=snd_nxt+new_length;
                        if(burst_active) burst_budget<=burst_budget-new_length;
                        if(snd_nxt==snd_una) begin
                            retry_stamp<=ms_now;rtt_start<=ms_now;rtt_end_seq<=snd_nxt+new_length;rtt_active<=1;
                        end
                    end else if(close_ready) begin
                        tcp_state<=LAST_ACK;fin_seq<=snd_nxt;out_flags<=8'h11;
                        snd_nxt<=snd_nxt+1'b1;retry_stamp<=ms_now;retries<=0;
                    end
                end
            end
                        if(control_internal_commit && RBCP_ADDR[31:8]==24'h000002) begin
                            if(control_internal_write && tcp_state==LISTEN && RBCP_ADDR[7:0]==8'h09) ack_policy<=RBCP_WD[0];
                            if(control_internal_write && tcp_state==LISTEN && RBCP_ADDR[7:0]==8'h0b) reorder_enable<=RBCP_WD[0];
                            if(control_internal_write && tcp_state==LISTEN && RBCP_ADDR[7:0]==8'h0c) recovery_exit_policy<=RBCP_WD[0];
                            if(control_internal_write && tcp_state==LISTEN && RBCP_ADDR[7:0]==8'h0d && RBCP_WD<=32) loss_guard_units<=RBCP_WD;
                            if(control_internal_write && tcp_state==LISTEN && RBCP_ADDR[7:0]==8'h0a && RBCP_WD[0]) begin
                                rx_old_segments<=0;rx_future_segments<=0;rx_other_segments<=0;first_bad_valid<=0;
                                first_bad_seq<=0;first_bad_nxt<=0;first_bad_last<=0;first_bad_meta<=0;first_bad_ms<=0;first_bad_id<=0;first_bad_ack<=0;
                                tx_timeout_events<=0;tx_fast_events<=0;tx_partial_events<=0;pure_ack_descriptors<=0;duplicate_ack_descriptors<=0;
                                last_ack_valid<=0;last_ack_value<=0;last_ack_window<=0;
                                reorder_stored<=0;reorder_full<=0;reorder_replayed<=0;reorder_retired<=0;reorder_highwater<=0;
                                recovery_exits<=0;burst_wait_cycles<=0;
                                rto_replays<=0;
                                guard_clear_statistics<=1;rx_diagnostic_clear<=1;rx_first_full_context<=0;
                            end
                            if(control_internal_write && RBCP_ADDR[7:0]==8'h08 && RBCP_WD[0]) begin
                                snapshot_id<=snapshot_id+1'b1;
                                ownership_snapshot<={32'h41335631,control_admitted,control_published,control_aborted,
                                    control_rejected,builder_cancelled,queued_tcp_cancelled,29'd0,control_input_error,control_occupied};
                                guard_snapshot<={24'd0,loss_guard_units,15'd0,guard_pending,guard_age,
                                    guard_armed,guard_cancelled,guard_confirmed,guard_max_age,
                                    guard_first_una,guard_first_nxt,guard_first_cwnd,guard_first_flight,
                                    guard_peak_duplicates,guard_aborted,
                                    rto_cursor,rto_pipe,rto_replays,31'd0,rto_active,
                                    rx_full_drops,rx_format_drops,{2'd0,rx_words_highwater,9'd0,rx_queue_highwater},rx_first_full_context};
                                diagnostic_snapshot<={rx_frames,rx_bad_frames,rx_dropped,bad_ip,bad_transport,
                                    bad_sequence,bad_ack,retransmits,tx_frames,tx_overflows,snd_una,snd_nxt,
                                    rcv_nxt,tx_written,tx_acked,{5'd0,tcp_state,5'd0,dup_acks,peer_window_raw},
                                    cwnd,{rto_ms,USER_RX_WADR[15:0]},underflows,snapshot_id+1'b1,srtt8,rttvar4,
                                    peer_window,{27'd0,window_scale_enabled,peer_window_shift},flight,TX_FLIGHT_CAP,
                                    {{(32-RX_ADDR_BITS){1'b0}},rx_occupied},receive_window,
                                    {{(32-RX_ADDR_BITS){1'b0}},USER_RX_WADR},{{(32-RX_ADDR_BITS){1'b0}},USER_RX_RADR},
                                    last_advertised_right,{12'd0,own_window_shift,receive_wire_window},
                                    rx_old_segments,rx_future_segments,rx_other_segments,first_bad_seq,first_bad_nxt,first_bad_last,
                                    first_bad_meta,first_bad_ms,tx_timeout_events,tx_fast_events,tx_partial_events,
                                    pure_ack_descriptors,duplicate_ack_descriptors,{31'd0,ack_policy},first_bad_id,first_bad_ack,
                                    reorder_stored,reorder_full,reorder_replayed,reorder_retired,reorder_highwater,
                                    {{(31-REORDER_SLOT_BITS){1'b0}},reorder_count},{31'd0,reorder_enable},
                                    {31'd0,recovery_exit_policy},{31'd0,burst_active},burst_budget,recovery_exits,burst_wait_cycles};
                            end
                        end
            // Independent delivery advances before ingress events. Later
            // validated urgent ACK/close events retain their existing priority.
            if(tcp_state!=ESTABLISHED || connection_abort) begin
                delivery_state<=D_IDLE;
            end else case(delivery_state)
                D_IDLE:if(delivery_start_safe && reorder_enable && reorder_scan_pending && reorder_count!=0 &&
                         (!reorder_head_valid || seq_le(reorder_head_seq,rcv_nxt)) && receive_window!=0) begin
                    reorder_scan_steps<=0;reorder_scan_min_valid<=0;reorder_scan_dirty<=0;delivery_state<=D_SCAN;
                end
                D_SCAN:begin
                    reorder_checked_slot<=reorder_scan;reorder_checked_valid<=reorder_valid[reorder_scan];
                    reorder_checked_seq<=reorder_seq[reorder_scan];reorder_checked_length<=reorder_length[reorder_scan];
                    reorder_checked_fin<=reorder_fin[reorder_scan];delivery_state<=D_MATCH;
                end
                D_MATCH:if(delivery_waits_for_writer) begin
                    // Hold the selected metadata and scan position. Re-evaluate
                    // it against the current committed sequence after grant.
                end else begin
                    reorder_scan<=reorder_scan+1'b1;reorder_scan_steps<=reorder_scan_steps+1'b1;
                    delivery_state<=D_SCAN;
                    // Remember the earliest still-future sequence after a
                    // complete scan, so each missing-prefix packet does not
                    // trigger another whole-table scan before it can help.
                    if(reorder_checked_valid && seq_lt(rcv_nxt,reorder_checked_seq) &&
                       (!reorder_scan_min_valid || seq_lt(reorder_checked_seq,reorder_scan_min_seq))) begin
                        reorder_scan_min_seq<=reorder_checked_seq;reorder_scan_min_valid<=1;
                    end
                    if(reorder_scan_steps==REORDER_SLOTS-1) begin
                        reorder_scan_pending<=scan_restart_required;delivery_state<=D_IDLE;reorder_head_valid<=!scan_restart_required && reorder_scan_min_valid;
                        reorder_head_seq<=reorder_scan_min_seq;
                        if(!scan_restart_required && reorder_checked_valid && seq_lt(rcv_nxt,reorder_checked_seq) &&
                           (!reorder_scan_min_valid || seq_lt(reorder_checked_seq,reorder_scan_min_seq))) begin
                            reorder_head_seq<=reorder_checked_seq;reorder_head_valid<=1;
                        end
                    end
                    if(reorder_checked_valid && seq_le(cached_end,rcv_nxt)) begin
                        reorder_count<=reorder_count-1'b1;
                        reorder_head_valid<=0;
                        reorder_retired<=reorder_retired+1'b1;
                        if(reorder_count==1) begin reorder_scan_pending<=0;delivery_state<=D_IDLE;end
                    end else if(reorder_checked_valid && seq_le(reorder_checked_seq,rcv_nxt)) begin
                        if(cached_remaining==0 && reorder_checked_fin && receive_window!=0) begin
                            rcv_nxt<=rcv_nxt+1'b1;tcp_state<=CLOSE_WAIT;need_ack<=1;ack_coalesce<=0;app_quiet<=0;
                            reorder_count<=reorder_count-1'b1;
                            reorder_head_valid<=0;
                            reorder_replayed<=reorder_replayed+1'b1;reorder_scan_pending<=0;delivery_state<=D_IDLE;
                        end else if(cached_accept!=0) begin
                            delivery_left<=cached_accept;delivery_total<=cached_accept;
                            delivery_fin<=cached_accept_fin && cached_accept==cached_remaining;
                            delivery_release<=cached_accept==cached_remaining && (!reorder_checked_fin || cached_accept_fin);
                            cache_read_addr<=cached_skip;delivery_state<=D_REQ;
                        end else begin reorder_scan<=reorder_checked_slot;reorder_scan_pending<=1;delivery_state<=D_IDLE;end
                    end
                end
                D_REQ:begin cache_read_addr<=cache_read_addr+copy_n;delivery_state<=D_COPY;end
                D_COPY:begin
                    USER_RX_WENB<=copy_mask;USER_RX_WDAT<=copy_word;pending_write_bytes<=copy_n;
                    delivery_left<=delivery_left-copy_n;
                    cache_read_addr<=cache_read_addr+((delivery_left-copy_n)>8?8:(delivery_left-copy_n));
                    if(delivery_left==copy_n) delivery_state<=D_COMMIT;
                end
                D_COMMIT:begin
                    // Last registered application write lands on this edge.
                    rcv_nxt<=rcv_nxt+delivery_total+delivery_fin;need_ack<=1;
                    ack_segments<=ack_segments<2?ack_segments+1'b1:2;
                    ack_coalesce<=delivery_total==peer_mss && !delivery_fin && receive_window>=peer_mss;
                    if(delivery_fin) begin tcp_state<=CLOSE_WAIT;app_quiet<=0;end
                    reorder_scan_pending<=reorder_count!=0;delivery_state<=D_IDLE;
                    if(delivery_release) begin
                        reorder_count<=reorder_count-1'b1;reorder_head_valid<=0;
                        reorder_replayed<=reorder_replayed+1'b1;
                        if(reorder_count==1) reorder_scan_pending<=0;
                    end else reorder_scan<=reorder_checked_slot;
                end
                default:delivery_state<=D_IDLE;
            endcase
            case(state)
                // Ingress and metadata scan run independently. Actual application
                // writes are granted once at the direct/delivery boundary.
                IDLE:if(rx_available && !bg_active) begin
                    packet_length<=rx_length;ip_sum<=rx_ip_sum;l4_sum<=rx_l4_sum;
                    packet_ip_valid<=rx_ip_valid;packet_l4_valid<=rx_l4_valid;
                    for(integer b=0;b<96;b=b+1) hdr[b]<=rx_header[b*8+:8];
                    index<=0;rx_read_addr<=42;if(!ack_policy) ack_coalesce<=0;
                    state<=R_CHECK;
                end
                // Header parsing is common to TCP and UDP. The independent
                // control owner receives only a validated bounded request.
                R_CHECK:begin
                    state<=RELEASE;
                    if(common_tcp) state<=R_ACK;
                    else if(eth_type==16'h0806 && packet_length>=42 &&
                       (dst_mac==LOCAL_MAC || dst_mac==48'hffffffffffff) &&
                       {hdr[14],hdr[15],hdr[16],hdr[17],hdr[18],hdr[19],hdr[20],hdr[21]}==64'h0001080006040001 &&
                       {hdr[38],hdr[39],hdr[40],hdr[41]}==LOCAL_IP &&
                       {hdr[22],hdr[23],hdr[24],hdr[25],hdr[26],hdr[27]}==src_mac) begin
                        tx_kind<=KIND_ARP;out_mac<=src_mac;out_ip<={hdr[28],hdr[29],hdr[30],hdr[31]};
                        out_payload<=0;state<=T_SETUP;rx_pop<=1;
                    end else if(eth_type==16'h0800 && dst_mac==LOCAL_MAC) state<=R_IP;
                end
                R_IP:begin
                    if(packet_length<34 || hdr[14]!=8'h45 || ip_length<20 || ip_length>1500 ||
                       packet_length<14+ip_length || dst_ip!=LOCAL_IP || hdr[22]==0 ||
                       (hdr[20]&8'hbf)!=0 || hdr[21]!=0 || !packet_ip_valid) begin
                        bad_ip<=bad_ip+1'b1;state<=RELEASE;
                    end else if(hdr[23]==6 && ip_length>=40 && dst_port==TCP_PORT) state<=R_TCP;
                    else if(hdr[23]==17 && ip_length>=36 && dst_port==RBCP_PORT) state<=R_UDP;
                    else state<=RELEASE;
                end
                R_TCP:begin
                    if(tcp_header_length<20 || tcp_header_length>60 || ip_length<20+tcp_header_length ||
                       !packet_l4_valid || seg_flags[5]) begin
                        bad_transport<=bad_transport+1'b1;state<=RELEASE;
                    end else begin
                        parsed_mss<=536;parsed_window_scale<=0;parsed_window_shift<=0;
                        option_index<=54;option_end<=34+tcp_header_length;state<=R_OPTIONS;
                    end
                end
                R_OPTIONS:begin
                    if(option_index>=option_end || option_byte0==0) state<=R_DECIDE;
                    else if(option_byte0==1) option_index<=option_index+1'b1;
                    else if(option_index+1>=option_end || option_byte1<2 ||
                            option_next>{1'b0,option_end}) begin
                        bad_transport<=bad_transport+1'b1;state<=RELEASE;
                    end else begin
                        if(option_byte0==2 && option_byte1==4) begin
                            if({option_byte2,option_byte3}==0) begin
                                bad_transport<=bad_transport+1'b1;state<=RELEASE;
                            end else parsed_mss<=min32({16'd0,option_byte2,option_byte3},1460);
                        end
                        // WS is meaningful only in the initial SYN. Non-SYN
                        // options never change the connection's negotiated shift.
                        if(option_byte0==3 && seg_flags[1]) begin
                            if(option_byte1!=3) begin
                                bad_transport<=bad_transport+1'b1;state<=RELEASE;
                            end else begin
                                parsed_window_scale<=1;
                                parsed_window_shift<=option_byte2>14?14:option_byte2[3:0];
                            end
                        end
                        option_index<=option_next[7:0];
                    end
                end
                R_DECIDE:begin
                    state<=RELEASE;
                    if(tcp_state==LISTEN) begin
                        if((seg_flags&8'h17)==8'h02) begin
                            peer_mac<=src_mac;peer_ip<=src_ip;peer_port<=src_port;
                            // SYN's window is unscaled even when WS was offered.
                            peer_window<=seg_window;peer_window_raw<=seg_window;
                            window_scale_enabled<=parsed_window_scale;peer_window_shift<=parsed_window_shift;
                            peer_mss<=parsed_mss;cwnd<=parsed_mss;ssthresh<=TX_FLIGHT_CAP;ca_credit<=0;
                            in_recovery<=0;partial_seen<=0;recover_end<=next_isn+1'b1;
                            recovery_boundary_passed<=0;
                            rto_active<=0;rto_cursor<=next_isn+1'b1;
                            burst_active<=0;burst_budget<=0;
                            irs<=seg_seq;rcv_nxt<=seg_seq+1'b1;data_base<=next_isn+1'b1-INITIAL_STREAM_OFFSET;
                            snd_una<=next_isn;snd_nxt<=next_isn+1'b1;tx_acked<=INITIAL_STREAM_OFFSET;
                            snd_wl1<=seg_seq;snd_wl2<=0;tcp_state<=SYN_RCVD;need_syn<=1;need_ack<=0;need_retx<=0;
                            ack_coalesce<=0;ack_segments<=0;
                            dup_acks<=0;retries<=0;rto_ms<=1000;persist_ms<=1000;persist_stamp<=ms_now;
                            retry_stamp<=ms_now;rtt_start<=ms_now;rtt_end_seq<=next_isn+1'b1;
                            rtt_active<=1;rtt_valid<=0;app_quiet<=0;
                        end
                    end else if(tuple_match) begin
                        if(seg_flags[2]) begin
                            if(seg_seq==rcv_nxt) begin tcp_state<=LISTEN;need_ack<=0;need_syn<=0;need_retx<=0;tx_flush<=1;end
                            else if(!seq_lt(seg_seq,rcv_nxt) && seq_lt(seg_seq,rcv_nxt+receive_window)) begin need_ack<=1;ack_coalesce<=0;end
                        end else if(tcp_state==SYN_RCVD && seg_flags[1] && seg_seq==irs) need_syn<=1;
                        else if(seg_flags[1]) begin need_ack<=1;ack_coalesce<=0;sequence_event(3);end
                        else if(seg_flags[4]) begin
                            if(seq_lt(snd_nxt,seg_ack) || (tcp_state==SYN_RCVD && seg_ack!=snd_nxt)) begin
                                bad_ack<=bad_ack+1'b1;need_ack<=1;ack_coalesce<=0;
                            end else if(!segment_acceptable) begin
                                sequence_event(seg_span!=0 && seq_lt(seg_last,rcv_nxt)?1:3);need_ack<=1;ack_coalesce<=0;
                            end else state<=R_ACK;
                        end
                    end
                end
                R_ACK:begin
                    state<=R_DATA;
                    // RFC9293 window updates also require an ACK in the
                    // currently sent range; an older ACK cannot retract/update it.
                    if(!seq_lt(seg_ack,snd_una) && !seq_lt(snd_nxt,seg_ack) &&
                       !seq_lt(seg_seq,snd_wl1) && (seg_seq!=snd_wl1 || !seq_lt(seg_ack,snd_wl2))) begin
                        peer_window<=segment_window_bytes;peer_window_raw<=seg_window;
                        snd_wl1<=seg_seq;snd_wl2<=seg_ack;
                        if(seg_window!=0) begin
                            persist_ms<=1000;persist_stamp<=ms_now;
                            // A zero-window probe may occupy sequence space
                            // without being accepted by the peer. On reopening,
                            // replay that oldest byte before sending beyond it.
                            // A cumulative ACK that accepts it takes precedence
                            // in the advancement branch below.
                            if(peer_window==0 && snd_una!=snd_nxt && seg_ack==snd_una) begin
                                need_retx<=1;retry_stamp<=ms_now;rtt_active<=0;
                            end
                        end
                    end
                    if(tcp_state==SYN_RCVD) begin
                        tcp_state<=ESTABLISHED;snd_una<=seg_ack;tx_acked<=INITIAL_STREAM_OFFSET;retries<=0;dup_acks<=0;
                    end else if(seq_lt(snd_una,seg_ack)) begin
                        snd_una<=seg_ack;
                        if(seq_lt(recover_end,seg_ack)) recovery_boundary_passed<=1;
                        // Stream counters wrap modulo32bits. Unsigned min(offset,
                        // written) would prematurely free retained bytes at4GiB.
                        tx_acked<=(tcp_state==LAST_ACK && seg_ack==snd_nxt)?tx_written:seg_ack-data_base;
                        retry_stamp<=ms_now;retries<=0;dup_acks<=0;need_retx<=0;
                        if(rto_active) begin
                            // Keep cursor/UNA ordered even for ACKs of packets
                            // retained by the receiver before the timeout.
                            if(seq_lt(rto_cursor,seg_ack)) rto_cursor<=seg_ack;
                            if(seg_ack==snd_nxt) rto_active<=0;
                        end
                        rto_ms<=min32(60000,((srtt8>>3)+rttvar4)>1000 ? (srtt8>>3)+rttvar4 : 1000);
                        if(in_recovery) begin
                            ca_credit<=0;
                            if(seq_lt(seg_ack,recover_end)) begin
                                // A partial cumulative ACK identifies the next
                                // hole. Stay in recovery and replay immediately.
                                need_retx<=1;rtt_active<=0;partial_seen<=1;tx_partial_events<=tx_partial_events+1'b1;
                                cwnd<=min32(TX_FLIGHT_CAP,partial_window<peer_mss?{16'd0,peer_mss}:partial_window);
                                if(partial_seen) retry_stamp<=retry_stamp;
                            end else begin
                                in_recovery<=0;partial_seen<=0;
                                recovery_exits<=recovery_exits+1'b1;
                                if(recovery_exit_policy) begin
                                    // RFC6582 section3.2 option2. Rebuild the ACK
                                    // clock: initially at most2MSS new data, then
                                    // acknowledged bytes plus1MSS per advancing
                                    // ACK, until flight+credit reaches cwnd.
                                    cwnd<=ssthresh;burst_budget<=peer_mss*2;
                                    burst_active<=flight_after_ack+peer_mss*2<ssthresh;
                                end else begin
                                    cwnd<=min32(ssthresh,(flight_after_ack>peer_mss?flight_after_ack:{16'd0,peer_mss})+peer_mss);
                                    burst_active<=0;burst_budget<=0;
                                end
                            end
                        end else if(cwnd<ssthresh) cwnd<=min32(TX_FLIGHT_CAP,cwnd+min32(seg_ack-snd_una,peer_mss));
                        else if(ca_credit+(seg_ack-snd_una)>=cwnd) begin
                            cwnd<=min32(TX_FLIGHT_CAP,cwnd+peer_mss);ca_credit<=0;
                        end else ca_credit<=ca_credit+(seg_ack-snd_una);
                        if(!in_recovery && burst_active) begin
                            if(flight_after_ack+burst_refill>=cwnd) begin burst_active<=0;burst_budget<=0;end
                            else burst_budget<=burst_refill;
                        end
                        if(tcp_state==LAST_ACK && seg_ack==snd_nxt) begin tcp_state<=LISTEN;state<=RELEASE;need_ack<=0;end
                    end else if(seg_ack==snd_una && snd_nxt!=snd_una && payload_length==0 &&
                                seg_window==peer_window_raw && seg_window!=0 && !seg_flags[0]) begin
                        if(dup_acks<3) dup_acks<=dup_acks+1'b1;
                        if(in_recovery) begin
                            cwnd<=min32(TX_FLIGHT_CAP,cwnd+peer_mss);
                        end else if(!rto_active && dup_acks==2 && recovery_boundary_passed && !guard_eligible) begin
                            tx_fast_events<=tx_fast_events+1'b1;
                            need_retx<=1;retry_stamp<=ms_now;rtt_active<=0;
                            recover_end<=snd_nxt;in_recovery<=1;partial_seen<=0;
                            recovery_boundary_passed<=0;
                            burst_active<=0;burst_budget<=0;
                            ssthresh<=recovery_threshold;
                            cwnd<=min32(TX_FLIGHT_CAP,recovery_threshold+peer_mss*3);ca_credit<=0;
                        end
                    end
                    if(rtt_active && seq_le(rtt_end_seq,seg_ack)) begin
                        rtt_active<=0;rtt_valid<=1;
                        if(!rtt_valid) begin srtt8<=(ms_now-rtt_start+1)*8;rttvar4<=(ms_now-rtt_start+1)*2;end
                        else begin
                            srtt8<=srtt8-(srtt8>>3)+(ms_now-rtt_start+1);
                            rttvar4<=rttvar4-(rttvar4>>2)+
                                ((srtt8>>3)>(ms_now-rtt_start+1) ? (srtt8>>3)-(ms_now-rtt_start+1) : (ms_now-rtt_start+1)-(srtt8>>3));
                        end
                    end
                end
                R_DATA:begin
                    state<=RELEASE;
                    if(tcp_state==ESTABLISHED) begin
                        if(seq_lt(rcv_nxt,seg_seq)) begin
                            // ACK was processed once. Retain validated future
                            // payload when enabled, while requesting the gap.
                            if(payload_length!=0 || seg_flags[0]) begin
                                need_ack<=1;ack_coalesce<=0;sequence_event(2);
                                if(reorder_enable && (future_bytes!=0 || future_fin)) begin
                                    pending_cache_seq<=seg_seq;pending_cache_addr<=34+tcp_header_length;
                                    copy_left<=future_bytes;copy_total<=future_bytes;copy_fin<=future_fin;
                                    state<=R_REORDER_ALLOC;
                                end
                            end
                        end else if(copy_from_cache && (payload_length!=0 || seg_flags[0])) begin
                            // A cached segment already owns the app writer. Keep
                            // this validated overlap/prefix in the same bounded
                            // cache; delivery re-evaluates its actual sequence.
                            need_ack<=1;ack_coalesce<=0;
                            if(accept_bytes!=0 || (following_bytes==0 && seg_flags[0] && receive_window!=0)) begin
                                pending_cache_seq<=rcv_nxt;
                                pending_cache_addr<=34+tcp_header_length+skip_bytes;
                                copy_left<=accept_bytes;copy_total<=accept_bytes;
                                copy_fin<=seg_flags[0] && accept_bytes==following_bytes && receive_window>following_bytes;
                                state<=R_REORDER_ALLOC;
                            end
                        end else if(following_bytes!=0) begin
                            need_ack<=1;ack_coalesce<=0;
                            if(accept_bytes!=0) begin

                                copy_left<=accept_bytes;copy_total<=accept_bytes;
                                copy_fin<=seg_flags[0] && accept_bytes==following_bytes;
                                rx_read_addr<=34+tcp_header_length+skip_bytes;state<=R_COPY_REQ;
                            end
                        end else if(seg_flags[0]) begin
                            rcv_nxt<=rcv_nxt+1'b1;tcp_state<=CLOSE_WAIT;need_ack<=1;ack_coalesce<=0;app_quiet<=0;
                        end
                    end else if(payload_length!=0 || seg_flags[0]) begin need_ack<=1;ack_coalesce<=0;end
                end
                R_REORDER_ALLOC:begin
                    if(reorder_count==REORDER_SLOTS) begin
                        reorder_full<=reorder_full+1'b1;state<=RELEASE;
                    end else if(!reorder_valid[reorder_alloc]) begin
                        reorder_store_slot<=reorder_alloc;reorder_alloc<=reorder_alloc+1'b1;
                        reorder_seq[reorder_alloc]<=pending_cache_seq;reorder_length[reorder_alloc]<=copy_total;
                        reorder_fin[reorder_alloc]<=copy_fin;
                        bg_read_addr<=pending_cache_addr;bg_left<=copy_total;
                        bg_total<=copy_total;bg_seq<=pending_cache_seq;
                        bg_state<=copy_total==0?BG_COMMIT:BG_REQUEST;
                        // This frame stays owned until BG_COMMIT publishes and
                        // pops it. Independent delivery can concurrently read the cache.
                        state<=IDLE;
                    end
                end
                R_COPY_REQ:begin
                    rx_read_addr<=rx_read_addr+copy_n;
                    state<=R_COPY_WRITE;
                end
                R_COPY_WRITE:begin
                    USER_RX_WENB<=copy_mask;USER_RX_WDAT<=copy_word;pending_write_bytes<=copy_n;
                    copy_left<=copy_left-copy_n;
                    rx_read_addr<=rx_read_addr+((copy_left-copy_n)>8?8:(copy_left-copy_n));
                    if(copy_left==copy_n) state<=R_COPY_END;
                end
                R_COPY_END:begin
                    rcv_nxt<=rcv_nxt+copy_total+copy_fin;need_ack<=1;
                    ack_segments<=ack_segments<2?ack_segments+1'b1:2;
                    ack_coalesce<=copy_total==peer_mss && !copy_fin && receive_window>=peer_mss;
                    if(copy_fin) begin tcp_state<=CLOSE_WAIT;app_quiet<=0;end
                    reorder_scan_pending<=reorder_count!=0;
                    state<=RELEASE;
                end
                RELEASE:begin rx_pop<=1;state<=RELEASE_WAIT;end
                RELEASE_WAIT:state<=IDLE;
                R_UDP:begin
                    if({hdr[38],hdr[39]}!=ip_length-20 || ip_length>291 ||
                       ({hdr[40],hdr[41]}!=0 && !packet_l4_valid) ||
                       udp_data[0]!=8'hff || (udp_data[1]!=8'h80 && udp_data[1]!=8'hc0) ||
                       (udp_data[1]==8'h80 ? ip_length!=36+udp_data[3] : ip_length!=36)) begin
                        bad_transport<=bad_transport+1'b1;state<=RELEASE;
                    end else if(!control_request_ready) begin
                        control_request_reject<=1;state<=RELEASE;
                    end else begin
                        control_request_valid<=1;state<=RELEASE;
                        if(udp_data[1]==8'h80 && udp_data[3]!=0) begin
                            control_fill_left<=udp_data[3];rx_read_addr<=50;state<=R_CONTROL_REQ;
                        end
                    end
                end
                R_CONTROL_REQ:begin rx_read_addr<=rx_read_addr+8;state<=R_CONTROL_COPY;end
                R_CONTROL_COPY:begin
                    control_body_valid<=1;control_body_data<=rx_word;
                    control_body_bytes<=control_fill_left>8?4'd8:control_fill_left[3:0];
                    control_fill_left<=control_fill_left>8?control_fill_left-8:0;
                    rx_read_addr<=rx_read_addr+8;
                    if(control_fill_left<=8) state<=RELEASE;
                end
                T_SETUP:if(builder_ready && !builder_valid && !tx_flush) begin
                    builder_valid<=1;state<=T_WAIT;
                    control_last_grant<=0;
                end
                // ARP descriptor is latched; independent control work proceeds.
                T_WAIT:state<=IDLE;
                default:state<=IDLE;
            endcase
            // Background writer has the ingress read port and OOO write port;
            // prefix replay has the OOO read port and application write port.
            // No main-wire parse/pop may overlap the background owner's frame.
            if(bg_active && tcp_state!=ESTABLISHED && bg_state!=BG_POP_WAIT) begin
                rx_pop<=1;bg_state<=BG_POP_WAIT;cache_write_en<=0;
            end else case(bg_state)
                BG_REQUEST:begin bg_read_addr<=bg_read_addr+bg_n;bg_state<=BG_COPY;end
                BG_COPY:begin
                    cache_write_en<=1;cache_write_addr<=bg_total-bg_left;
                    cache_write_data<=rx_word128;cache_write_keep<=16'hffff>>(16-bg_n);
                    bg_left<=bg_left-bg_n;
                    bg_read_addr<=bg_read_addr+min32(bg_left-bg_n,16);
                    if(bg_left==bg_n) bg_state<=BG_COMMIT;
                end
                BG_COMMIT:if(bg_commit) begin
                    reorder_count<=reorder_count+1'b1;reorder_stored<=reorder_stored+1'b1;
                    reorder_scan_pending<=1;
                    // A newly published entry may invalidate a concurrent
                    // completed scan's earliest-sequence hint. Force recheck.
                    reorder_head_valid<=0;
                    if(reorder_count+1>reorder_highwater) reorder_highwater<=reorder_count+1'b1;
                    rx_pop<=1;bg_state<=BG_POP_WAIT;
                end
                BG_POP_WAIT:bg_state<=BG_IDLE;
                default:begin end
            endcase
            // Dirty persists until a new pass starts. This is a coalescing
            // invalidation bit, not a wrapping generation counter; no update
            // can be lost while a long scan waits for the app writer.
            if((delivery_state==D_SCAN || delivery_state==D_MATCH) &&
               (bg_commit || state==R_COPY_END)) reorder_scan_dirty<=1;
        end
    end
endmodule
