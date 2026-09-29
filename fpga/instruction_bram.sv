`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/21/2026 10:12:04 PM
// Design Name: 
// Module Name: instruction_bram
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


`include "../imports/RISCVCPU-1/system.sv"
`include "../imports/RISCVCPU-1/memory_io.sv"

module instruction_bram #(
    parameter integer ADDR_BITS = 10,
    parameter MEM_FILE = "led_test.mem"
) (
    input  logic         clk,
    input  logic         reset,
    input  memory_io_req req,
    output memory_io_rsp rsp
);

    localparam integer DEPTH = (1 << ADDR_BITS);

    (* ram_style = "block" *)
    logic [31:0] mem [0:DEPTH-1];

    logic                              pending_r;
    logic [`word_address_size-1:0]     addr_r;
    logic [31:0]                       data_r;

    initial begin
        $readmemh(MEM_FILE, mem);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            pending_r <= 1'b0;
            addr_r    <= '0;
            data_r    <= '0;
        end
        else if (!pending_r && req.valid && is_any_byte(req.do_read)) begin
            addr_r    <= req.addr;
            data_r    <= mem[req.addr[ADDR_BITS+1:2]];
            pending_r <= 1'b1;
        end
        else if (pending_r) begin
            pending_r <= 1'b0;
        end
    end

    always_comb begin
        rsp       = memory_io_no_rsp;
        rsp.ready = !pending_r;
        rsp.valid = pending_r;
        rsp.addr  = addr_r;
        rsp.data  = data_r;
    end

endmodule