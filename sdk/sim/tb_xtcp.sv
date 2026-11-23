`timescale 1ns/1ps
// Independent Ethernet peer exercises only the public XGMII and application ports.
module tb_xtcp #(parameter integer PROFILE=0);
    localparam integer B=PROFILE==0?8:16;
    localparam [47:0] LOCAL_MAC=48'h025100030011+PROFILE, FPGA_MAC=LOCAL_MAC, HOST_MAC=48'h025100030020;
    localparam [31:0] LOCAL_IP=32'hC0A80A0B+PROFILE, FPGA_IP=LOCAL_IP, HOST_IP=32'hc0a80a14;
    localparam [15:0] TCP_PORT=23010+PROFILE,RBCP_PORT=4610+PROFILE;
    reg clk=0,slow_clk=0,rst=1;
    always #(PROFILE==0 ? 3.2 : 1.28) clk=~clk;
    always #2.56 slow_clk=~slow_clk;
    wire engine_clk=PROFILE==0 ? clk : slow_clk;
    reg [63:0] host_d=64'h0707070707070707; reg [7:0] host_c=8'hff;
    wire [63:0] fpga_d;wire [7:0] fpga_c;
    wire app_reset, established, close_req, close_ack, tx_afull;
    wire [31:0] rbcp_addr;
    wire rbcp_we, rbcp_re, rbcp_ack;
    wire [7:0] rbcp_wd, rbcp_rd;
    wire [B*8-1:0] tx_data, rx_write_data;
    wire [$clog2(B):0] tx_bytes;
    localparam integer RX_ADDR_BITS=PROFILE==0?18:19;
    wire [RX_ADDR_BITS-1:0] rx_size, rx_raddr, rx_waddr;
    wire [B-1:0] rx_write_enable;
    wire rx_clear_enable;
    xtcp #(.PROFILE(PROFILE), .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
           .TCP_PORT(TCP_PORT), .RBCP_PORT(RBCP_PORT)) endpoint (
        .APP_CLK(engine_clk), .APP_RST(rst), .LINE_CLK(clk), .LINE_RST(rst),
        .XGMII_RXC(host_c), .XGMII_RXD(host_d), .XGMII_TXC(fpga_c), .XGMII_TXD(fpga_d),
        .APP_RESET_OUT(app_reset), .RBCP_ACT(), .RBCP_ADDR(rbcp_addr),
        .RBCP_WE(rbcp_we), .RBCP_WD(rbcp_wd), .RBCP_RE(rbcp_re),
        .RBCP_ACK(rbcp_ack), .RBCP_RD(rbcp_rd),
        .USER_SESSION_ESTABLISHED(established), .USER_SESSION_CLOSE_REQ(close_req),
        .USER_SESSION_CLOSE_ACK(close_ack), .USER_TX_D(tx_data), .USER_TX_B(tx_bytes),
        .USER_TX_AFULL(tx_afull), .USER_RX_SIZE(rx_size), .USER_RX_CLR_ENB(rx_clear_enable),
        .USER_RX_RADR(rx_raddr), .USER_RX_WADR(rx_waddr),
        .USER_RX_WENB(rx_write_enable), .USER_RX_WDAT(rx_write_data)
    );
    xtcp_example_app #(.PROFILE(PROFILE), .LOCAL_MAC(LOCAL_MAC), .LOCAL_IP(LOCAL_IP),
           .TCP_PORT(TCP_PORT), .RBCP_PORT(RBCP_PORT)) application (
        .clk(engine_clk), .reset(app_reset), .rbcp_addr(rbcp_addr),
        .rbcp_we(rbcp_we), .rbcp_re(rbcp_re), .rbcp_wd(rbcp_wd),
        .rbcp_ack(rbcp_ack), .rbcp_rd(rbcp_rd), .established(established),
        .close_req(close_req), .tx_afull(tx_afull), .close_ack(close_ack),
        .tx_data(tx_data), .tx_bytes(tx_bytes), .rx_size(rx_size), .rx_raddr(rx_raddr),
        .rx_clear_enable(rx_clear_enable),
        .rx_waddr(rx_waddr), .rx_write_enable(rx_write_enable), .rx_write_data(rx_write_data),
        .status_flags(16'h0023)
    );
    localparam integer HOST_FRAME_BYTES=PROFILE==2 ? 9232 : 2048;
    integer host_mss=PROFILE==2?8960:1460, max_tx_data=0;
    byte unsigned p[0:HOST_FRAME_BYTES-1],r[0:HOST_FRAME_BYTES-1],captured[0:HOST_FRAME_BYTES-1];
    localparam integer HOST_QUEUE_DEPTH=16;
    integer host_queue_highwater=0;
    byte unsigned queue_mem[0:HOST_QUEUE_DEPTH-1][0:HOST_FRAME_BYTES-1];
    integer queue_length[0:HOST_QUEUE_DEPTH-1];
    integer producer=0,consumer=0,cap_length=0,skip=0;
    integer capture_file,events_file,cycles=0,highwater=0,afull_cycles=0;
    bit capturing=0;
    reg [31:0] crc_calc;
    integer rlen,rpayload,rheader;
    reg [31:0] rseq,rack,pc_seq,fp_seq,first_fp_seq,old_pc_seq;
    reg [7:0] rflags;
    reg [15:0] host_port=40001,host_window=8192;
    bit host_ws=0,ack_ws_option=0,bad_ws_length=0;
    reg [7:0] host_shift=0;
    reg [7:0] rb_id=0;
    reg [63:0] rb_value;
    integer exp_tx=0,exp_rx=0,sessions=0;
    integer shuffle_batches=0;
    function automatic [31:0] crc_step(input [31:0] c,input [7:0] b);
        reg [31:0] v;
        begin v=c^b;for(integer n=0;n<8;n=n+1) v=v[0]?(v>>1)^32'hedb88320:v>>1;crc_step=v;end
    endfunction
    function automatic [7:0] pattern(input integer offset);pattern=offset%255+1;endfunction
    function automatic [15:0] p_checksum(input integer start,input integer count,input integer seed);
        reg [31:0] acc;
        begin
            acc=seed;
            for(integer k=0;k<count;k=k+2) acc=acc+(p[start+k]<<8)+(k+1<count?p[start+k+1]:0);
            while(acc>>16) acc=(acc&65535)+(acc>>16);
            p_checksum=~acc;
        end
    endfunction
    always @(posedge clk) cycles<=cycles+1;
    always @(negedge clk) begin
        for(integer lane=0;lane<8;lane=lane+1) begin
            if(fpga_c[lane] && fpga_d[lane*8+:8]==8'hfb) begin
                if(capturing) $fatal(1,"Nested XGMII start");
                capturing=1;skip=7;cap_length=0;
            end else if(capturing && skip!=0) begin
                if(fpga_c[lane] || fpga_d[lane*8+:8]!=(skip==1?8'hd5:8'h55)) $fatal(1,"Bad preamble");
                skip=skip-1;
            end else if(capturing && fpga_c[lane]) begin
                if(fpga_d[lane*8+:8]!=8'hfd || cap_length<64 || cap_length>(PROFILE==2 ? 9018 : 1518)) $fatal(1,"Bad TX termination/length %d",cap_length);
                crc_calc=32'hffffffff;
                for(integer k=0;k<cap_length-4;k=k+1) crc_calc=crc_step(crc_calc,captured[k]);
                crc_calc=~crc_calc;
                for(integer k=0;k<4;k=k+1)
                    if(captured[cap_length-4+k]!==crc_calc[k*8+:8]) $fatal(1,"Bad FPGA Ethernet FCS");
                if(producer-consumer>=HOST_QUEUE_DEPTH) $fatal(1,"Host RX queue overflow");
                if(producer-consumer+1>host_queue_highwater)host_queue_highwater=producer-consumer+1;
                queue_length[producer%HOST_QUEUE_DEPTH]=cap_length-4;
                for(integer k=0;k<cap_length-4;k=k+1) queue_mem[producer%HOST_QUEUE_DEPTH][k]=captured[k];
                producer=producer+1;
                $fwrite(capture_file,"%0d OUT ",cycles);
                for(integer k=0;k<cap_length;k=k+1) $fwrite(capture_file,"%02x",captured[k]);
                $fwrite(capture_file,"\n");
                capturing=0;
            end else if(capturing) begin
                if(cap_length>=HOST_FRAME_BYTES) $fatal(1,"Oversized TX");
                captured[cap_length]=fpga_d[lane*8+:8];cap_length=cap_length+1;
            end
        end
    end
    task automatic put16(input integer a,input [15:0] v);p[a]=v[15:8];p[a+1]=v[7:0];endtask
    task automatic put32(input integer a,input [31:0] v);
        p[a]=v[31:24];p[a+1]=v[23:16];p[a+2]=v[15:8];p[a+3]=v[7:0];
    endtask
    task automatic ethernet(input [15:0] etype);
        for(integer k=0;k<128;k=k+1) p[k]=0;
        for(integer k=0;k<6;k=k+1) begin p[k]=FPGA_MAC[47-k*8-:8];p[6+k]=HOST_MAC[47-k*8-:8];end
        put16(12,etype);
    endtask
    task automatic ip(input [7:0] proto,input integer l4len);
        ethernet(16'h0800);p[14]=8'h45;put16(16,20+l4len);p[20]=8'h40;p[22]=64;p[23]=proto;
        put32(26,HOST_IP);put32(30,FPGA_IP);put16(24,p_checksum(14,20,0));
    endtask
    task automatic send_frame(input integer length,input bit bad_fcs);
        integer n,pos;reg [31:0] c;reg [63:0] word;reg [7:0] control;
        n=length<60?60:length;c=32'hffffffff;
        for(integer k=0;k<n;k=k+1) c=crc_step(c,p[k]);c=~c;
        if(bad_fcs) c=c^1;
        for(integer k=0;k<4;k=k+1) p[n+k]=c[k*8+:8];
        $fwrite(capture_file,"%0d IN ",cycles);
        for(integer k=0;k<n+4;k=k+1) $fwrite(capture_file,"%02x",p[k]);$fwrite(capture_file,"\n");
        @(negedge clk);host_d=64'hd5555555555555fb;host_c=8'h01;
        pos=0;
        while(pos<n+5) begin
            word=64'h0707070707070707;control=8'hff;
            for(integer k=0;k<8;k=k+1) begin
                if(pos+k<n+4) begin word[k*8+:8]=p[pos+k];control[k]=0;end
                else if(pos+k==n+4) word[k*8+:8]=8'hfd;
            end
            @(negedge clk);host_d=word;host_c=control;pos=pos+8;
        end
        @(negedge clk);host_d=64'h0707070707070707;host_c=8'hff;
        repeat(1) @(negedge clk);
    endtask
    task automatic next_frame;
        integer deadline;
        deadline=cycles+120000;
        while(producer==consumer && cycles<deadline) @(posedge clk);
        if(producer==consumer) $fatal(1,"No Ethernet response");
        rlen=queue_length[consumer%HOST_QUEUE_DEPTH];
        for(integer k=0;k<rlen;k=k+1) r[k]=queue_mem[consumer%HOST_QUEUE_DEPTH][k];
        consumer=consumer+1;
    endtask
    task automatic next_tcp;
        bit found;
        found=0;
        while(!found) begin
            next_frame();found=r[12]==8'h08 && r[13]==0 && r[23]==6;
        end
        rseq={r[38],r[39],r[40],r[41]};rack={r[42],r[43],r[44],r[45]};rflags=r[47];
        rheader=(r[46]>>4)*4;rpayload={r[16],r[17]}-20-rheader;
        begin : verify_outgoing_checksums
            integer tcp_size,ip_sum,tcp_sum;
            tcp_size=rheader+rpayload;ip_sum=0;
            for(integer k=14;k<34;k=k+2) ip_sum+={r[k],r[k+1]};
            tcp_sum=6+tcp_size;
            for(integer k=26;k<34;k=k+2) tcp_sum+={r[k],r[k+1]};
            for(integer k=0;k<tcp_size;k=k+2)
                tcp_sum+={r[34+k],k+1<tcp_size?r[35+k]:8'd0};
            while(ip_sum>65535)ip_sum=(ip_sum&65535)+(ip_sum>>16);
            while(tcp_sum>65535)tcp_sum=(tcp_sum&65535)+(tcp_sum>>16);
            if(ip_sum!=65535 || tcp_sum!=65535)
                $fatal(1,"Independent outgoing IPv4/TCP checksum, payload=%0d",rpayload);
        end
        if(rflags[2]) $fatal(1,"Unexpected FPGA RST");
    endtask
    task automatic tcp(input [31:0] seq,ack,input [7:0] flags,input [15:0] window,
                       input integer n,offset,corrupt);
        integer h,seed;
        h=flags[1]?(host_ws?28:24):(ack_ws_option?24:20);
        ip(6,h+n);put16(34,host_port);put16(36,TCP_PORT);put32(38,seq);put32(42,ack);
        p[46]=(h/4)<<4;p[47]=flags;put16(48,window);
        if(flags[1]) begin p[54]=2;p[55]=4;put16(56,host_mss);end
        if(flags[1] && host_ws) begin p[58]=1;p[59]=3;p[60]=bad_ws_length?2:3;p[61]=host_shift;end
        if(!flags[1] && ack_ws_option) begin p[54]=1;p[55]=3;p[56]=3;p[57]=20;end

        for(integer k=0;k<n;k=k+1) p[34+h+k]=pattern(offset+k);
        seed=HOST_IP[31:16]+HOST_IP[15:0]+FPGA_IP[31:16]+FPGA_IP[15:0]+6+h+n;
        put16(50,p_checksum(34,h+n,seed));
        if(corrupt==2) p[24]=p[24]^1;
        if(corrupt==3) p[50]=p[50]^1;
        send_frame(34+h+n,corrupt==1);
    endtask
    task automatic rbcp(input bit wr,input [31:0] address,input integer n,input [63:0] value);
        integer data_len;bit found;
        rb_id=rb_id+1;data_len=wr?n:0;ip(17,16+data_len);
        put16(34,40000);put16(36,RBCP_PORT);put16(38,16+data_len);
        p[42]=8'hff;p[43]=wr?8'h80:8'hc0;p[44]=rb_id;p[45]=n;put32(46,address);
        for(integer k=0;k<data_len;k=k+1) p[50+k]=value[8*(n-k)-1-:8];
        send_frame(50+data_len,0);
        found=0;
        while(!found) begin next_frame();found=r[23]==17 && r[44]==rb_id;end
        if(r[43]!=(wr?8'h88:8'hc8) || r[45]!=n || {r[46],r[47],r[48],r[49]}!=address)
            $fatal(1,"RBCP response address=%h command=%h len=%d",address,r[43],r[45]);
        rb_value=0;for(integer k=0;k<n;k=k+1) rb_value=(rb_value<<8)|r[50+k];
        if(wr && rb_value!=value) $fatal(1,"RBCP write reply mismatch %h %h",rb_value,value);
    endtask
    task automatic check_payload(input integer offset);
        for(integer k=0;k<rpayload;k=k+1)
            if(r[34+rheader+k]!==pattern(offset+k))
                $fatal(1,"Payload mismatch seq=%h at=%d got=%h expected=%h",rseq,offset+k,r[34+rheader+k],pattern(offset+k));
    endtask
    task automatic receive_data(input integer count,offset);
        integer got;
        got=0;
        while(got<count) begin
            next_tcp();
            if(rpayload!=0) begin
                if(rseq!=fp_seq || got+rpayload>count) $fatal(1,"Unexpected segment seq=%h expected=%h len=%d remaining=%d",rseq,fp_seq,rpayload,count-got);
                if(rpayload>max_tx_data) max_tx_data=rpayload;
                check_payload(offset+got);got=got+rpayload;fp_seq=fp_seq+rpayload;
                tcp(pc_seq,fp_seq,8'h10,host_window,0,0,0);
            end
        end
        exp_tx=exp_tx+count;
    endtask
    task automatic echo(input integer n,offset);
        tcp(pc_seq,fp_seq,8'h18,host_window,n,offset,0);pc_seq=pc_seq+n;
        receive_data(n,offset);exp_rx=exp_rx+n;
    endtask
    task automatic disconnect_peer;
        bit got_fin;
        tcp(pc_seq,fp_seq,8'h11,host_window,0,0,0);pc_seq=pc_seq+1;got_fin=0;
        while(!got_fin) begin
            next_tcp();
            if(rpayload!=0) $fatal(1,"Unexpected data during close");
            if(rflags[0]) begin
                if(rseq!=fp_seq || rack!=pc_seq) $fatal(1,"FIN sequence mismatch");
                fp_seq=fp_seq+1;tcp(pc_seq,fp_seq,8'h10,host_window,0,0,0);got_fin=1;
            end
        end
        repeat(300) @(posedge clk);
        if(established) $fatal(1,"Session failed to close");host_port=host_port+1;
    endtask

    initial begin
        capture_file=$fopen("xtcp_frames.txt","w");
        if(!capture_file) $fatal(1,"Could not open wire evidence");
        repeat(60) @(posedge engine_clk); rst=0; repeat(100) @(posedge engine_clk);
        rbcp(0,32'h44,6,0); if(rb_value!=LOCAL_MAC) $fatal(1,"Mismatch in MAC register");
        rbcp(0,32'h4A,4,0); if(rb_value!=LOCAL_IP) $fatal(1,"Mismatch in IPv4 register");
        rbcp(0,32'h4E,4,0); if(rb_value!={TCP_PORT,RBCP_PORT}) $fatal(1,"Mismatch in port registers");
        rbcp(1,4,1,64'h40); rbcp(0,4,1,0); if(rb_value!=64'h40) $fatal(1,"Echo mode");
        pc_seq=32'habcdfff0;tcp(pc_seq,0,8'h02,host_window,0,0,0);next_tcp();
        if(rflags!=8'h12 || rack!=pc_seq+1 || rpayload!=0 || {r[34],r[35]}!=TCP_PORT) $fatal(1,"SYN-ACK");
        for(integer i=0;i<6;i++) if(r[6+i]!=LOCAL_MAC[47-i*8-:8]) $fatal(1,"Wire source MAC");
        if({r[26],r[27],r[28],r[29]}!=LOCAL_IP) $fatal(1,"Wire source IPv4");
        fp_seq=rseq+1;pc_seq=pc_seq+1;tcp(pc_seq,fp_seq,8'h10,host_window,0,0,0);
        repeat(250) @(posedge clk);
        if(!established) $fatal(1,"Handshake");
        echo(1,0);echo(17,1);echo(1460,18);if(PROFILE==2) echo(8960,1478);
        disconnect_peer();$fclose(capture_file);
        $display("XTCP_WIRE_PASS profile=%0d MAC=%h IPv4=%h tx=%0d rx=%0d frames=%0d",PROFILE,LOCAL_MAC,LOCAL_IP,exp_tx,exp_rx,producer);
        $finish;
    end
    initial begin #3000000;$fatal(1,"Simulation watchdog");end
endmodule
