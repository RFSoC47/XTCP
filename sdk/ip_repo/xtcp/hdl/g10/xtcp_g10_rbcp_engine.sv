// A request reserves one slot before its optional wide body arrives. Only a
// complete request is executable. Reply ownership ends at builder publication
// or explicit builder cancellation, never merely at descriptor grant.
module xtcp_g10_rbcp_engine(
    input wire clk,rst,
    input wire request_valid,
    output wire request_ready,
    input wire [47:0] request_mac,
    input wire [31:0] request_ip,request_address,
    input wire [15:0] request_port,
    input wire [7:0] request_command,request_id,request_length,
    input wire body_valid,
    input wire [63:0] body_data,
    input wire [3:0] body_bytes,
    input wire request_reject,
    output wire response_valid,
    input wire response_grant,response_published,response_abort,
    output wire [47:0] response_mac,
    output wire [31:0] response_ip,
    output wire [15:0] response_port,
    output wire [8:0] response_length,
    input wire [8:0] response_read_addr,
    output reg [7:0] response_read_data,
    output reg RBCP_ACT,
    output reg [31:0] RBCP_ADDR,
    output reg RBCP_WE,RBCP_RE,
    output reg [7:0] RBCP_WD,
    input wire RBCP_ACK,
    input wire [7:0] RBCP_RD,
    output wire internal_commit,
    output wire internal_write,
    input wire [7:0] internal_read_data,
    output reg [31:0] admitted_count,published_count,aborted_count,rejected_count,
    output wire [1:0] occupied,
    output reg input_contract_error
);
    localparam C_IDLE=0,C_REQUEST=1,C_WAIT=2,C_GAP=3,C_REPLY=4,C_PUBLISH=5;
    reg [2:0] state;
    reg [1:0] producer,consumer,valid_slots;
    wire head=consumer[0],tail=producer[0];
    reg loading,load_slot;
    reg [7:0] load_index;
    reg [47:0] mac[0:1];
    reg [31:0] ip[0:1],address[0:1];
    reg [15:0] port[0:1];
    reg [7:0] command[0:1],id[0:1],length[0:1];
    reg [7:0] bus_index;
    reg [5:0] wait_count;
    reg bus_error;
    assign occupied=producer-consumer;
    assign request_ready=occupied<2 && !loading && !rst;
    wire accept=request_valid && request_ready;
    wire body_ok=loading && body_bytes!=0 && body_bytes<=8 &&
        ({1'b0,load_index}+body_bytes)<={1'b0,length[load_slot]} &&
        (body_bytes==8 || {1'b0,load_index}+body_bytes=={1'b0,length[load_slot]});
    wire body_last=body_valid && body_ok &&
        {1'b0,load_index}+body_bytes=={1'b0,length[load_slot]};
    wire internal_page=RBCP_ADDR[31:8]==24'h000002 || RBCP_ADDR[31:8]==24'h000003;
    wire byte_complete=state==C_WAIT && (internal_page || RBCP_ACK || wait_count==31);
    wire byte_timeout=byte_complete && !internal_page && !RBCP_ACK;
    wire reply_write=byte_complete && (command[head]==8'hc0 || byte_timeout);
    wire [7:0] reply_byte=internal_page?internal_read_data:(RBCP_ACK?RBCP_RD:8'd0);
    wire retire=state==C_PUBLISH && (response_abort || response_published);
    assign internal_commit=state==C_WAIT && internal_page && !rst;
    assign internal_write=command[head]==8'h80;
    assign response_valid=state==C_REPLY && !rst;
    assign response_mac=mac[head];assign response_ip=ip[head];assign response_port=port[head];
    assign response_length=9'd8+{1'b0,length[head]};

    // Each slot has eight 32-byte banks. FILL writes up to eight bytes, EXECUTE
    // updates one reply byte. The same slot cannot own both operations.
    // Builder reads only in PUBLISH; EXECUTE and builder never contend for RAM.
    wire [7:0] read_index=state==C_PUBLISH?response_read_addr[7:0]-8'd8:bus_index;
    wire [7:0] body_read[0:1];
    for(genvar slot=0;slot<2;slot=slot+1) begin: slots
        wire [63:0] q;
        for(genvar lane=0;lane<8;lane=lane+1) begin: banks
            (* ram_style="distributed" *) reg [7:0] mem[0:31];
            always @(posedge clk) begin
                if(!rst && body_valid && body_ok && load_slot==slot && lane<body_bytes)
                    mem[load_index[7:3]]<=body_data[lane*8+:8];
                else if(!rst && reply_write && head==slot && bus_index[2:0]==lane)
                    mem[bus_index[7:3]]<=reply_byte;
            end
            assign q[lane*8+:8]=mem[read_index[7:3]];
        end
        assign body_read[slot]=q[read_index[2:0]*8+:8];
    end
    always @* begin
        response_read_data=0;
        case(response_read_addr)
            0:response_read_data=8'hff;
            1:response_read_data=command[head]|8'h08|{7'd0,bus_error};
            2:response_read_data=id[head];3:response_read_data=length[head];
            4:response_read_data=address[head][31:24];5:response_read_data=address[head][23:16];
            6:response_read_data=address[head][15:8];7:response_read_data=address[head][7:0];
            default:if(response_read_addr<response_length) response_read_data=body_read[head];
        endcase
    end

    // A single validity updater merges publication and retirement. Accepted
    // FILL reservations already advance producer, so credits cannot be reused.
    reg [1:0] next_valid;
    always @* begin
        next_valid=valid_slots;
        if(accept) next_valid[tail]=request_command==8'hc0 || request_length==0;
        if(body_last) next_valid[load_slot]=1;
        if(retire) next_valid[head]=0;
    end
    always @(posedge clk) begin
        RBCP_WE<=0;RBCP_RE<=0;
        if(rst) begin
            state<=C_IDLE;producer<=0;consumer<=0;valid_slots<=0;
            loading<=0;load_slot<=0;load_index<=0;bus_index<=0;wait_count<=0;bus_error<=0;
            RBCP_ACT<=0;RBCP_ADDR<=0;RBCP_WD<=0;
            admitted_count<=0;published_count<=0;aborted_count<=0;rejected_count<=0;input_contract_error<=0;
            for(integer s=0;s<2;s=s+1) begin
                mac[s]<=0;ip[s]<=0;port[s]<=0;address[s]<=0;command[s]<=0;id[s]<=0;length[s]<=0;
            end
        end else begin
            valid_slots<=next_valid;
            if(request_reject) rejected_count<=rejected_count+1'b1;
            if(body_valid && !body_ok) input_contract_error<=1;
            if(accept) begin
                mac[tail]<=request_mac;ip[tail]<=request_ip;port[tail]<=request_port;
                address[tail]<=request_address;command[tail]<=request_command;
                id[tail]<=request_id;length[tail]<=request_length;
                producer<=producer+1'b1;admitted_count<=admitted_count+1'b1;
                if(request_command==8'h80 && request_length!=0) begin
                    loading<=1;load_slot<=tail;load_index<=0;
                end
            end
            if(body_valid && body_ok) begin
                load_index<=load_index+body_bytes;
                if(body_last) loading<=0;
            end
            case(state)
                C_IDLE:if(valid_slots[head] && occupied!=0) begin
                    RBCP_ACT<=1;bus_index<=0;bus_error<=0;
                    state<=length[head]==0?C_REPLY:C_REQUEST;
                end
                C_REQUEST:begin
                    RBCP_ADDR<=address[head]+bus_index;RBCP_WD<=body_read[head];wait_count<=0;
                    if((address[head]+bus_index)>>8!=24'h000002 && (address[head]+bus_index)>>8!=24'h000003) begin
                        RBCP_WE<=command[head]==8'h80;RBCP_RE<=command[head]==8'hc0;
                    end
                    state<=C_WAIT;
                end
                C_WAIT:begin
                    wait_count<=wait_count+1'b1;
                    if(byte_complete) begin
                        if(byte_timeout) bus_error<=1;
                        bus_index<=bus_index+1'b1;state<=C_GAP;
                        if(command[head]==8'hc0 && {1'b0,bus_index}+9'd1<{1'b0,length[head]} &&
                           (RBCP_ADDR[31:8]==24'h000002 ||
                            (RBCP_ADDR[31:8]==24'h000003 && RBCP_ADDR[7:0]!=8'hff))) begin
                            RBCP_ADDR<=RBCP_ADDR+1'b1;wait_count<=0;state<=C_WAIT;
                        end
                    end
                end
                C_GAP:state<=bus_index==length[head]?C_REPLY:C_REQUEST;
                C_REPLY:begin RBCP_ACT<=0;if(response_grant) state<=C_PUBLISH;end
                C_PUBLISH:if(retire) begin
                    consumer<=consumer+1'b1;state<=C_IDLE;
                    if(response_abort) aborted_count<=aborted_count+1'b1;
                    else published_count<=published_count+1'b1;
                end
                default:state<=C_IDLE;
            endcase
        end
    end
endmodule
