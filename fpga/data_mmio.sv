`include "../imports/RISCVCPU-1/system.sv"
`include "../imports/RISCVCPU-1/memory_io.sv"

module data_mmio #(
    parameter logic [31:0] LED_ADDR = 32'h4000_0000,
    parameter logic [31:0] UART_TX_ADDR = 32'h4000_0004,
    parameter logic [31:0] UART_STATUS_ADDR = 32'h4000_0008, // bit 0 = TX busy, bit 1 = RX valid
    parameter logic [31:0] UART_RX_ADDR = 32'h4000_000C,
    parameter integer RAM_WORDS = 1024
) (
    input  logic         clk,
    input  logic         reset,
    input  memory_io_req req,
    output memory_io_rsp rsp,
    output logic         led,
    
    input logic          uart_tx_busy,
    output logic [7:0]   uart_tx_data,
    output logic         uart_tx_start,
    
    input logic [7:0]    uart_rx_data,
    input logic          uart_rx_valid,
    output logic         uart_rx_ready
);
    
    // 1,024 words × 4 bytes = 4 KiB of data memory.
    (* ram_style = "block" *) logic [31:0] ram [0:RAM_WORDS-1];
    
    logic                          pending_r;
    logic [`word_address_size-1:0] addr_r;
    logic [31:0]                   data_r;

    always_ff @(posedge clk) begin
        if (reset) begin
            pending_r     <= 1'b0;
            addr_r        <= '0;
            data_r        <= '0;
            led           <= 1'b0;
            uart_tx_data  <= '0;
            uart_tx_start <= 1'b0;
            uart_rx_ready <= 1'b0;
        end
        else begin
            uart_tx_start <= 1'b0;
            uart_rx_ready <= 1'b0;
            
            if (!pending_r && req.valid
                 && (is_any_byte(req.do_read) || is_any_byte(req.do_write))) begin
                addr_r <= req.addr;
                data_r <= 32'b0;
    
                if (req.addr == LED_ADDR) begin
                    if (is_any_byte(req.do_write)) begin
                        led <= req.data[0];
                    end
    
                    data_r <= {31'b0, led};
                end
                else if (req.addr == UART_TX_ADDR) begin
                    if (req.do_write[0] && !uart_tx_busy && !uart_tx_start) begin
                        uart_tx_data <= req.data[7:0];
                        uart_tx_start <= 1'b1;
                    end
                end
                else if (req.addr == UART_STATUS_ADDR) begin
                    if (is_any_byte(req.do_read))
                        data_r <= {30'b0, uart_rx_valid, (uart_tx_busy | uart_tx_start)};
                end
                else if (req.addr == UART_RX_ADDR) begin
                    if (req.do_read[0] && uart_rx_valid) begin
                        data_r <= {24'b0, uart_rx_data};
                        uart_rx_ready <= 1'b1;
                    end
                end
                
                // Ordinary RAM: addresses 0x0000_0000 through 0x0000_0FFF
                else if (req.addr[31:12] == '0) begin
                    if (req.do_write[0])
                        ram[req.addr[11:2]][7:0]   <= req.data[7:0];
                    if (req.do_write[1])
                        ram[req.addr[11:2]][15:8]  <= req.data[15:8];
                    if (req.do_write[2])
                        ram[req.addr[11:2]][23:16] <= req.data[23:16];
                    if (req.do_write[3])
                        ram[req.addr[11:2]][31:24] <= req.data[31:24];
    
                    if (is_any_byte(req.do_read))
                        data_r <= ram[req.addr[11:2]];
                    else
                        data_r <= 32'b0;
                end
    
                // Unmapped addresses read as zero and ignore writes.
                pending_r <= 1'b1;
            end
            else if (pending_r) begin
                pending_r <= 1'b0;
            end
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