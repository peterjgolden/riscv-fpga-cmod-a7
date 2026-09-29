`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 09/24/2026 12:31:28 PM
// Design Name: 
// Module Name: uart_rx_tb
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


`timescale 1ns / 1ps

module uart_rx_tb;

    localparam integer CLKS_PER_BIT = 104;
    localparam realtime CLK_PERIOD = 83.333;

    logic clk   = 0;
    logic reset = 1;
    logic rx    = 1;
    logic ready = 0;

    logic [7:0] data;
    logic valid;
    logic framing_error;
    logic overrun;

    integer framing_count  = 0;
    integer overrun_count  = 0;
    integer received_count = 0;

    logic previous_framing = 0;
    logic previous_overrun = 0;
    logic [7:0] received [0:31];

    always #(CLK_PERIOD / 2.0) clk = ~clk;

    uart_rx #(
        .CLKS_PER_BIT(CLKS_PER_BIT)
    ) dut (
        .clk           (clk),
        .reset         (reset),
        .rx            (rx),
        .data          (data),
        .valid         (valid),
        .ready         (ready),
        .framing_error (framing_error),
        .overrun       (overrun)
    );

    // Capture transfers before the receiver updates its registers.
    // Check error pulses after nonblocking assignments have settled.
    always @(posedge clk) begin
        if (!reset && valid && ready) begin
            if (received_count >= 32)
                $fatal(1, "Scoreboard overflow");

            received[received_count] = data;
            received_count = received_count + 1;
        end

        #1;

        if (!reset) begin
            if ($isunknown({valid, framing_error, overrun}))
                $fatal(1, "Unknown receiver control output");

            if (framing_error && previous_framing)
                $fatal(1, "Framing error exceeded one clock");

            if (overrun && previous_overrun)
                $fatal(1, "Overrun exceeded one clock");

            if (framing_error)
                framing_count = framing_count + 1;

            if (overrun)
                overrun_count = overrun_count + 1;
        end

        previous_framing = framing_error;
        previous_overrun = overrun;
    end

    // Call on a falling edge.
    // Consecutive calls have exactly one stop bit between frames.
    task automatic send_frame(
        input logic [7:0] value,
        input logic       stop_bit
    );
        rx = 0;
        repeat (CLKS_PER_BIT) @(negedge clk);

        for (int i = 0; i < 8; i++) begin
            rx = value[i];
            repeat (CLKS_PER_BIT) @(negedge clk);
        end

        rx = stop_bit;
        repeat (CLKS_PER_BIT) @(negedge clk);
    endtask

    task automatic expect_byte(input logic [7:0] expected);
        if (valid !== 1'b1 || data !== expected)
            $fatal(1,
                "Expected %02h; got valid=%b data=%02h",
                expected, valid, data);
    endtask

    // Assert ready across one rising clock edge.
    task automatic consume_byte;
        ready = 1;
        @(negedge clk);
        ready = 0;

        if (valid !== 1'b0)
            $fatal(1, "valid did not clear after consumption");
    endtask

    task automatic expect_errors(
        input integer expected_framing,
        input integer expected_overrun
    );
        if (framing_count != expected_framing ||
            overrun_count != expected_overrun)
            $fatal(1,
                "Expected framing/overrun=%0d/%0d, got %0d/%0d",
                expected_framing, expected_overrun,
                framing_count, overrun_count);
    endtask

    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        repeat (5) @(negedge clk);

        // TEST 1: Receive A and preserve it until consumed.
        send_frame(8'h41, 1);
        expect_byte(8'h41);

        repeat (20) begin
            @(negedge clk);
            expect_byte(8'h41);
        end

        consume_byte();
        expect_errors(0, 0);
        $display("PASS: A received, retained and consumed");

        // TEST 2: Different bit patterns.
        send_frame(8'h00, 1);
        expect_byte(8'h00);
        consume_byte();

        send_frame(8'hff, 1);
        expect_byte(8'hff);
        consume_byte();

        send_frame(8'h55, 1);
        expect_byte(8'h55);
        consume_byte();

        send_frame(8'haa, 1);
        expect_byte(8'haa);
        consume_byte();

        expect_errors(0, 0);
        $display("PASS: 00, FF, 55 and AA");

        // TEST 3: Buffer full. Preserve A and discard B.
        send_frame(8'h41, 1);
        expect_byte(8'h41);

        send_frame(8'h42, 1);
        expect_byte(8'h41);
        expect_errors(0, 1);

        consume_byte();

        repeat (CLKS_PER_BIT) @(negedge clk);

        if (valid !== 1'b0)
            $fatal(1, "Discarded byte appeared later");

        $display("PASS: Overrun preserves unread byte");

        // TEST 4: Invalid stop bit.
        send_frame(8'h33, 0);

        if (valid !== 1'b0)
            $fatal(1, "Malformed frame was accepted");

        expect_errors(1, 1);
        $display("PASS: Invalid stop bit reports framing error");

        // TEST 5: Remain in WAIT_HIGH while the line stays low.
        repeat (12 * CLKS_PER_BIT) begin
            @(negedge clk);

            if (dut.state !== dut.STATE_WAIT_HIGH)
                $fatal(1, "Receiver left WAIT_HIGH while RX was low");

            if (valid !== 1'b0)
                $fatal(1, "Byte appeared while RX was low");
        end

        // No repeated framing errors while waiting.
        expect_errors(1, 1);

        rx = 1;
        repeat (CLKS_PER_BIT) @(negedge clk);

        send_frame(8'h5a, 1);
        expect_byte(8'h5a);
        consume_byte();

        expect_errors(1, 1);
        $display("PASS: WAIT_HIGH and recovery");

        // TEST 6: Short low glitch, shorter than half a bit.
        rx = 0;
        repeat (CLKS_PER_BIT / 4) @(negedge clk);
        rx = 1;

        repeat (12 * CLKS_PER_BIT) begin
            @(negedge clk);

            if (valid !== 1'b0)
                $fatal(1, "False start produced a byte");
        end

        expect_errors(1, 1);

        send_frame(8'h69, 1);
        expect_byte(8'h69);
        consume_byte();

        expect_errors(1, 1);
        $display("PASS: False start ignored; next frame received");

        // TEST 7: Consecutive frames with an always-ready consumer.
        // Eight bytes were consumed by the preceding tests.
        if (received_count != 8)
            $fatal(1, "Unexpected transfer count before streaming test");

        ready = 1;

        send_frame(8'h12, 1);
        send_frame(8'h34, 1);
        send_frame(8'h56, 1);

        repeat (5) @(negedge clk);
        ready = 0;

        if (received_count != 11 ||
            received[8]  !== 8'h12 ||
            received[9]  !== 8'h34 ||
            received[10] !== 8'h56)
            $fatal(1, "Consecutive-frame data/order/count mismatch");

        if (valid !== 1'b0)
            $fatal(1, "Streaming byte was not consumed");

        expect_errors(1, 1);
        $display("PASS: Consecutive frames received in order");

        $display("ALL TESTS PASSED");
        $finish;
    end

    // Stop a broken test instead of running forever.
    initial begin
        #5_000_000; // 5 milliseconds
        $fatal(1, "Simulation timeout");
    end

endmodule