`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/21/2026 10:42:59 PM
// Design Name: 
// Module Name: soc_top
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


`include "memory_io.sv"

module soc_top (
    input  logic sysclk,
    input  logic uart_rx_in,
    output logic led,
    output logic uart_tx_out
);

    // Assert reset during the first 32 board-clock cycles after configuration.
    logic [4:0] reset_counter = '0;
    logic reset;

    always_ff @(posedge sysclk) begin
        if (!(&reset_counter)) begin
            reset_counter <= reset_counter + 1'b1;
        end
    end

    assign reset = !(&reset_counter);

    memory_io_req inst_mem_req;
    memory_io_rsp inst_mem_rsp;
    memory_io_req data_mem_req;
    memory_io_rsp data_mem_rsp;

    multicycle cpu (
        .clk          (sysclk),
        .reset        (reset),
        .reset_pc     (32'h0000_0000),
        .inst_mem_req (inst_mem_req),
        .inst_mem_rsp (inst_mem_rsp),
        .data_mem_req (data_mem_req),
        .data_mem_rsp (data_mem_rsp)
    );

    instruction_bram #(
        .MEM_FILE("uart_echo.mem")
    ) imem (
        .clk   (sysclk),
        .reset (reset),
        .req   (inst_mem_req),
        .rsp   (inst_mem_rsp)
    );

    logic        uart_tx_start;
    logic        uart_tx_busy;
    logic [7:0]  uart_tx_data;
    logic        uart_rx_valid;
    logic        uart_rx_ready;
    logic [7:0]  uart_rx_data;

    data_mmio dmem (
        .clk        (sysclk),
        .reset      (reset),
        .req        (data_mem_req),
        .rsp        (data_mem_rsp),
        .led        (led),
        .uart_tx_busy  (uart_tx_busy),
        .uart_tx_data  (uart_tx_data),
        .uart_tx_start (uart_tx_start),
        .uart_rx_data  (uart_rx_data),
        .uart_rx_valid (uart_rx_valid),
        .uart_rx_ready (uart_rx_ready)
    );
    
    logic       rx_framing_error;
    logic       rx_overrun;
    
    uart_rx #(
        .CLKS_PER_BIT(104)
    ) uart_receiver (
        .clk           (sysclk),
        .reset         (reset),
        .rx            (uart_rx_in),
        .data          (uart_rx_data),
        .valid         (uart_rx_valid),
        .ready         (uart_rx_ready),
        .framing_error (rx_framing_error),
        .overrun       (rx_overrun)
    );

    uart_tx #(
        .CLKS_PER_BIT(104)
    ) uart_transmitter (
        .clk   (sysclk),
        .reset (reset),
        .data  (uart_tx_data),
        .start (uart_tx_start),
        .tx    (uart_tx_out),
        .busy  (uart_tx_busy)
    );

endmodule
