`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/24/2026 11:46:19 AM
// Design Name: 
// Module Name: uart_rx
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


module uart_rx #(
        parameter integer CLKS_PER_BIT = 104
)(
    input logic clk
    ,input logic reset
    
    ,input logic rx
    
    ,output logic [7:0] data
    ,output logic valid
    ,input logic ready
    
    ,output logic framing_error
    ,output logic overrun
);
    localparam integer COUNT_WIDTH =
        (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);
    
    localparam integer HALF_BIT = CLKS_PER_BIT / 2;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_START,
        STATE_DATA,
        STATE_STOP,
        STATE_WAIT_HIGH
    } state_t;

    state_t state;

    logic [COUNT_WIDTH-1:0] tick_count;
    logic [2:0]             bit_index;
    logic [7:0]             shift_r;

    // RX is asynchronous to our FPGA clock.
    // Only rx_sync is used by the state machine.
    (* ASYNC_REG = "TRUE" *) logic rx_meta;
    (* ASYNC_REG = "TRUE" *) logic rx_sync;

    always_ff @(posedge clk) begin
        if (reset) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end
        else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state         <= STATE_IDLE;
            tick_count    <= '0;
            bit_index     <= '0;
            shift_r       <= '0;
            data          <= '0;
            valid         <= 1'b0;
            framing_error <= 1'b0;
            overrun       <= 1'b0;
        end
        else begin
            // Errors are pulses lasting one clock.
            framing_error <= 1'b0;
            overrun       <= 1'b0;

            // Consume the buffered byte.
            if (valid && ready)
                valid <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    tick_count <= '0;
                    bit_index  <= '0;

                    if (!rx_sync)
                        state <= STATE_START;
                end

                STATE_START: begin
                    if (tick_count == HALF_BIT - 1) begin
                        tick_count <= '0;

                        // Confirm start bit at its midpoint.
                        if (!rx_sync)
                            state <= STATE_DATA;
                        else
                            state <= STATE_IDLE;
                    end
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                end

                STATE_DATA: begin
                    if (tick_count == CLKS_PER_BIT - 1) begin
                        tick_count <= '0;

                        // UART sends the least-significant bit first.
                        shift_r[bit_index] <= rx_sync;

                        if (bit_index == 3'd7)
                            state <= STATE_STOP;
                        else
                            bit_index <= bit_index + 1'b1;
                    end
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                end

                STATE_STOP: begin
                    if (tick_count == CLKS_PER_BIT - 1) begin
                        tick_count <= '0;

                        if (rx_sync) begin
                            // Accept if empty, or if the old byte
                            // is being consumed on this same edge.
                            if (!valid || ready) begin
                                data  <= shift_r;
                                valid <= 1'b1;
                            end
                            else begin
                                // Preserve the unread byte;
                                // discard the newly received byte.
                                overrun <= 1'b1;
                            end

                            state <= STATE_IDLE;
                        end
                        else begin
                            framing_error <= 1'b1;
                            state <= STATE_WAIT_HIGH;
                        end
                    end
                    else begin
                        tick_count <= tick_count + 1'b1;
                    end
                end

                STATE_WAIT_HIGH: begin
                    tick_count <= '0;

                    if (rx_sync)
                        state <= STATE_IDLE;
                end

                default: begin
                    state      <= STATE_IDLE;
                    tick_count <= '0;
                    bit_index  <= '0;
                end
            endcase
        end
    end

endmodule