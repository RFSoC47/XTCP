// Experimental bounded confirmation after the third valid duplicate ACK.
// This module never changes CWND, sequence state or retransmission ownership.
// Core supplies validated events and consumes ready only at a safe scheduler edge.
module xtcp_jumbo_loss_guard #(
    parameter integer CLOCKS_PER_UNIT=625,
    parameter integer UNIT_QUARTER_CYCLES=4*CLOCKS_PER_UNIT
)(
    input wire clk,rst,clear,clear_statistics,
    input wire [7:0] units,
    input wire arm,cancel_ack,confirm,duplicate_event,
    input wire [31:0] arm_una,arm_nxt,arm_cwnd,arm_flight,
    output reg pending,
    output wire ready,
    output reg [15:0] age,
    output reg [31:0] pending_una,
    output reg [31:0] armed_count,cancelled_count,confirmed_count,aborted_count,
    output reg [31:0] max_age,peak_duplicates,
    output reg [31:0] first_una,first_nxt,first_cwnd,first_flight
);
    // units are 4 us, rounded up once at the requested deadline.
    wire [23:0] scaled_deadline=units*UNIT_QUARTER_CYCLES+3;
    wire [15:0] deadline=scaled_deadline[17:2];
    reg [15:0] duplicates;
    assign ready=pending && units!=0 && age>=deadline;
    always @(posedge clk) begin
        if(rst || clear_statistics) begin
            pending<=0;age<=0;pending_una<=0;duplicates<=0;
            armed_count<=0;cancelled_count<=0;confirmed_count<=0;aborted_count<=0;
            max_age<=0;peak_duplicates<=0;
            first_una<=0;first_nxt<=0;first_cwnd<=0;first_flight<=0;
        end else begin
            if(pending) begin
                if(age!=16'hffff) age<=age+1'b1;
                if({16'd0,age}>max_age) max_age<={16'd0,age};
                if(duplicate_event && duplicates!=16'hffff) begin
                    duplicates<=duplicates+1'b1;
                    // Include the final duplicate even when cancel/clear below
                    // relinquishes the indication on this same clock edge.
                    if({16'd0,duplicates}+32'd1>peak_duplicates)
                        peak_duplicates<={16'd0,duplicates}+32'd1;
                end else if({16'd0,duplicates}>peak_duplicates) peak_duplicates<={16'd0,duplicates};
            end
            // Cancel wins over expiry/confirmation when an ACK fills the gap.
            if(clear || units==0) begin
                if(pending) aborted_count<=aborted_count+1'b1;
                pending<=0;age<=0;duplicates<=0;
            end else if(cancel_ack) begin
                if(pending) cancelled_count<=cancelled_count+1'b1;
                pending<=0;age<=0;duplicates<=0;
            end else if(confirm && ready) begin
                confirmed_count<=confirmed_count+1'b1;
                pending<=0;age<=0;duplicates<=0;
            end else if(arm && !pending) begin
                pending<=1;age<=0;duplicates<=3;pending_una<=arm_una;
                armed_count<=armed_count+1'b1;
                if(armed_count==0) begin
                    first_una<=arm_una;first_nxt<=arm_nxt;first_cwnd<=arm_cwnd;first_flight<=arm_flight;
                end
            end
        end
    end
endmodule
