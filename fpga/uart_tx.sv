`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/23/2026 08:13:10 PM
// Design Name: 
// Module Name: uart_tx
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module uart_tx #(
        parameter integer CLKS_PER_BIT = 104
)(
    input logic clk
    ,input logic reset
    
    ,input logic [7:0] data
    ,input logic start
    
    ,output logic tx
    ,output logic busy
);
    
    localparam integer COUNT_WIDTH =
        (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);
    
    typedef enum logic [1:0] {
        STATE_IDLE
        ,STATE_START
        ,STATE_DATA
        ,STATE_STOP
    } state_t;
    
    state_t state;
    
    logic [7:0] data_r;
    logic [2:0] data_index;
    logic [COUNT_WIDTH-1:0] tick_count;
    
    always_comb begin
        tx = 1'b1;
        busy = 1'b1;
        
        case (state)
            STATE_IDLE: busy = 1'b0;
            STATE_START: tx = 1'b0;
            STATE_DATA: tx = data_r[data_index];
            STATE_STOP: tx = 1'b1;
            default: begin
                tx = 1'b1;
                busy = 1'b1;
            end
        endcase
     end
     
     always_ff @(posedge clk) begin
        if (reset) begin
            state <= STATE_IDLE;
            tick_count <= '0;
            data_index <= '0;
            data_r <= '0;
        end
        else begin
            case (state)
                STATE_IDLE: begin
                    tick_count <= '0;
                    data_index <= '0;
                    
                    if (start) begin
                        data_r <= data;
                        state <= STATE_START;
                    end
                 end
                 
                 STATE_START: begin
                    if (tick_count == CLKS_PER_BIT - 1) begin
                        tick_count <= '0;
                        state <= STATE_DATA;
                    end
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                 end
                 
                 STATE_DATA: begin
                    if (tick_count == CLKS_PER_BIT - 1) begin
                        tick_count <= '0;
                        
                        if (data_index == 3'd7) begin
                            state <= STATE_STOP;
                        end
                        else begin
                            data_index <= data_index + 1'b1;
                        end
                    end
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                 end
                 
                 STATE_STOP: begin
                    if (tick_count == CLKS_PER_BIT - 1) begin
                        tick_count <= '0;
                        state <= STATE_IDLE;
                    end 
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                 end
                 
                 default: begin
                    state <= STATE_IDLE;
                    tick_count <= '0;
                    data_index <= '0;
                 end
                 
              endcase
          end
       end
          
 endmodule
