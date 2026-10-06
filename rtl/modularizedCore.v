`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 10/05/2026 08:04:39 PM
// Design Name: 
// Module Name: modularizedCore
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


// ModularizedCore.sv
// Pipelined 5-stage RV32I Core with each stage modularized.


`ifndef pipelined_core_v
`define pipelined_core_v
`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
`include "riscv32_common.sv"
`include "pipeline_structs.sv"

module fetch_stage(
	input  logic clk,
	input  logic reset,
	input  logic redirect, // branch or jump redirect signal
	input  logic stall, // hold the fetch stage
	input  logic [`word_address_size-1:0] reset_pc,
	input  ext_operand redirect_target, // branch or jump target address
	input  memory_io_rsp inst_mem_rsp,
	output memory_io_req inst_mem_req,
	output fetch_decode_reg fetch_decode // output to the decode stage
);

typedef enum logic [1:0] {
    FETCH_REQUEST,
    FETCH_WAIT,
    FETCH_HOLD
} fetch_state;

fetch_state 		state, next_state;

word 				buffered_instruction_pc;
word_address 		fetch_pc;
instr32    			buffered_instruction_data;
logic 				discard; // Flag to indicate if the fetched instruction should be discarded

always_comb begin
	inst_mem_req = memory_io_no_req; // Default to no request
	inst_mem_req.addr = fetch_pc;
	next_state = state;

	case (state)
		// Revisit FETCH handshake when adding cache or memory delay
		FETCH_REQUEST: begin
			if (!reset && !redirect) begin
				// No branch, jump or reset
				inst_mem_req.valid = 1;
				inst_mem_req.do_read = `whole_word32;

				if (inst_mem_rsp.ready)
				    // Memory accepts request, move to wait for response
					next_state = FETCH_WAIT;
			end
		end
		FETCH_WAIT: begin
			if (inst_mem_rsp.valid) begin
				// Memory has provided a response
				if (discard || redirect) begin
					// If branch or jump occurred this cycle or while waiting, discard the fetched instruction
					next_state = FETCH_REQUEST;
				end
				else if (stall) begin
					// Stall the fetch stage, hold the current state
					next_state = FETCH_HOLD;
				end
				else begin 
					// Decode immediately accepts instruction, move back to request
					next_state = FETCH_REQUEST;
				end
			end
		end
		FETCH_HOLD: begin
			// Hold the current state until the stall is resolved or instruction discarded/ flushed
			if (!stall || redirect)
				next_state = FETCH_REQUEST;
		end
		default: next_state = FETCH_REQUEST;
	endcase
end

word instruction_count /*verilator public*/;
always_ff @(posedge clk) begin
		if (reset) begin
			state 						<= FETCH_REQUEST;
			fetch_pc 					<= reset_pc;
			instruction_count			<= '0;
			buffered_instruction_data 	<= '0;
			buffered_instruction_pc 	<= '0;
			fetch_decode.pc 			<= '0;
			fetch_decode.instruction 	<= 32'h00000013;
			discard 					<= 1'b0;
		end else begin
			state <= next_state;

			if (!stall) begin
				// Default to NOP instruction (0x00000013)
				fetch_decode.pc <= '0;
				fetch_decode.instruction <= 32'h00000013;
			end

			case (state)
				FETCH_WAIT: begin
					if (inst_mem_rsp.valid) begin
						// Outstand request finished don't hold discard
						discard <= 1'b0;

						if (!discard && !redirect) begin
							if (stall) begin
								// Buffer the fetched instruction for later use if stalled
								buffered_instruction_pc 	<= inst_mem_rsp.addr;
								buffered_instruction_data 	<= inst_mem_rsp.data;
							end
							else begin
								// No stall, instruction is passed directly to the decode stage
								fetch_decode.pc 			<= inst_mem_rsp.addr;
								fetch_decode.instruction 	<= inst_mem_rsp.data;
								fetch_pc 					<= fetch_pc + 4;
								instruction_count 			<= instruction_count + 1;
							end
						end
					end else if (redirect) begin
						// Set discard flag to indicate the fetched instruction should be discarded
						// when it is eventually recieved
						discard <= 1;
					end
				end
				FETCH_HOLD: begin
					// Hold state if stall or redirect is active.
					// Otherwise, pass the buffered instruction to the decode stage.
					if (!stall && !redirect) begin
						fetch_decode.pc 			<= buffered_instruction_pc;
						fetch_decode.instruction 	<= buffered_instruction_data;
						fetch_pc 					<= fetch_pc + 4;
						instruction_count 			<= instruction_count + 1;
					end
				end
				FETCH_REQUEST: begin
					// No register updates
				end
				default: begin
					fetch_decode.pc 			<= '0;
					fetch_decode.instruction 	<= 32'h00000013;
					fetch_pc					<= fetch_pc;
					instruction_count 			<= instruction_count;
				end
			endcase

			if (redirect) begin
				// If branch or jump insert NOPs while waiting for new instruction.
				fetch_decode.pc          	<= '0;
				fetch_decode.instruction 	<= 32'h00000013;
				fetch_pc 				 	<= redirect_target[`word_address_size-1:0];
			end
		end
		/*
		if (instruction_count > 130)
		   $stop();
		$display("count = %h", instruction_count);
		if (decode_execute.stall || decode_execute.jump || decode_execute.branch)
				$display("Fetch: PC = %h", fetch_decode.pc);
		  else 
				$display("Fetch: PC = %h", inst_mem_rsp.addr);
		  $display("PC = %h", pc);
		$display("Instruction = %b", fetched_instruction);
		*/
end

endmodule

module decode_stage(
	input  logic clk,
	input  logic reset,
	input  word wbd,
	input  logic execute_ready,
	input  fetch_decode_reg fetch_decode,
	input  memory_writeback_reg memory_writeback,
	input  execute_memory_reg execute_memory,
	output  logic redirect,
	output  logic stall,
	output decode_execute_reg decode_execute,
	output ext_operand redirect_target
);

ext_operand br_addr;
logic signed [`word_size:0] br_data_1, br_data_2;
logic mem_read_n;
logic mem_write_n;
logic mem_to_reg_n;
tag     rs1;
tag     rs2;
word    rd1;
word    rd2;
tag     wbs;
logic   wbv;
word    imm;
funct3  f3;
funct7  f7;
opcode_q op_q;
instr_format format;

logic hazard_stall;
logic uses_rs1;
logic uses_rs2;

word    reg_file[0:31];

always_comb begin
	rs1 = decode_rs1(fetch_decode.instruction);
	rs2 = decode_rs2(fetch_decode.instruction);
	wbs = decode_rd(fetch_decode.instruction);
	f3 = decode_funct3(fetch_decode.instruction);
	op_q = decode_opcode_q(fetch_decode.instruction);
	format = decode_format(op_q);
	imm = decode_imm(fetch_decode.instruction, format);
	wbv = decode_writeback(op_q);
	f7 = decode_funct7(fetch_decode.instruction, format);

	hazard_stall = 1'b0;

	// rs1 used for all but aiupc, jal and lui
	uses_rs1 = (op_q == q_op 	 ||
				op_q == q_op_imm ||
				op_q == q_load   ||
				op_q == q_store  ||
				op_q == q_branch ||
				op_q == q_jalr
				);

	// rs2 used for register operations, stores and conditional branches
	uses_rs2 = (op_q == q_op 	 ||
				op_q == q_store  ||
				op_q == q_branch
				);

	if (decode_execute.mem_read && decode_execute.rd != 0 && ((uses_rs1 && decode_execute.rd == rs1) 
															|| (uses_rs2 && decode_execute.rd == rs2)))
		hazard_stall = 1'b1; // Stall if there is a memory read and the result is needed by the current instruction

	else if ((op_q == q_branch) && decode_execute.reg_write && decode_execute.rd != 0 && ((decode_execute.rd == rs1) 
																					   || (decode_execute.rd == rs2)))
		hazard_stall = 1'b1; // Stall if there is a branch and the result is needed by the current instruction

	else if ((op_q == q_jalr) && decode_execute.reg_write && decode_execute.rd != 0 && (decode_execute.rd == rs1))
		hazard_stall = 1'b1;

	else if (execute_memory.mem_read && execute_memory.rd != 0 && ((uses_rs1 && execute_memory.rd == rs1) 
																|| (uses_rs2 && execute_memory.rd == rs2)))
		hazard_stall = 1'b1; // Stall if there is a memory read in the execute stage and the result is needed by the current instruction

end

always_comb begin
	redirect = 0; // Default to no redirect
	if (op_q == q_branch && !stall && !reset) begin
		case (f3)
			f3_beq: redirect = (br_data_1 == br_data_2);
			f3_bne: redirect = (br_data_1 != br_data_2);
			f3_blt: redirect = (br_data_1 < br_data_2);
			f3_bge: redirect = (br_data_1 >= br_data_2);
			f3_bltu: redirect = { 1'b0, br_data_1[`word_size-1:0] } < { 1'b0, br_data_2[`word_size-1:0] };
			f3_bgeu: redirect = { 1'b0, br_data_1[`word_size-1:0] } >= { 1'b0, br_data_2[`word_size-1:0] };
			default: begin
				//$display("Unimplemnted f3: %x", f3);
				redirect = 0;
			end	
		endcase
	end 
	else if ((op_q == q_jal || op_q == q_jalr) && !stall && !reset)
		redirect = 1;
end


always_ff @(posedge clk) begin
		if (!reset && memory_writeback.reg_write && memory_writeback.rd != 0) begin
			reg_file[memory_writeback.rd] <= wbd;
			//$display("reg = %d, wbd = %h", memory_writeback.rd, wbd);
		end
end

always_comb begin
	br_addr = {imm[31], imm[31:0]} + fetch_decode.pc;
	br_data_1 = {reg_file[rs1][31], reg_file[rs1]};
	br_data_2 = {reg_file[rs2][31], reg_file[rs2]};

	// Branch forwarding logic for rs1 and rs2, execute_memory checked first
	// because it is the most recent write to the register file
	if (rs1 == `tag_size'd0)
		br_data_1 = '0;
	else if (rs1 == execute_memory.rd && execute_memory.reg_write)
		br_data_1 = {execute_memory.exec_result[31], execute_memory.exec_result};
	else if (rs1 == memory_writeback.rd && memory_writeback.reg_write)
		br_data_1 = {wbd[31], wbd};
	
	if (rs2 == `tag_size'd0)
		br_data_2 = '0;
	else if (rs2 == execute_memory.rd && execute_memory.reg_write)
		br_data_2 = {execute_memory.exec_result[31], execute_memory.exec_result};
	else if (rs2 == memory_writeback.rd && memory_writeback.reg_write)
		br_data_2 = {wbd[31], wbd};
end

always_comb begin
	redirect_target = 0;
	if ((op_q == q_jal) || (op_q == q_branch))
		redirect_target = br_addr;
	else if (op_q == q_jalr) begin
		redirect_target = {imm[31], imm[31:0]} + br_data_1;
		// From manual, The indirect jump instruction JALR (jump and link register) uses the I-type encoding.
		// The target address is obtained by adding the sign-extended 12-bit I-immediate to the register rs1,
		// then setting the least-significant bit of the result to zero.
		redirect_target[0] = 1'b0;
	end
end

always_comb begin
	if (op_q == q_store)
			mem_write_n = 1;
	else 
			mem_write_n = 0;
	if (op_q == q_load) begin
			mem_read_n = 1;
			mem_to_reg_n = 1;
	end else begin
			mem_read_n = 0;
			mem_to_reg_n = 0;
	end
end

assign stall = !execute_ready || hazard_stall;

always_ff @(posedge clk) begin
	if (reset) begin
		decode_execute.rs1 <= 0;
		decode_execute.rs2 <= 0;
		decode_execute.rs1_data <= 0;
		decode_execute.rs2_data <= 0;
		decode_execute.imm <= 0;
		decode_execute.rd <= 0;
		decode_execute.f3 <= 0;
		decode_execute.f7 <= 0;
		decode_execute.op_q <= q_op_imm;
		decode_execute.reg_write <= 0;
		decode_execute.mem_write <= 0;
		decode_execute.mem_read <= 0;
		decode_execute.mem_to_reg <= 0;
		decode_execute.pc <= 0;

	end else if (!execute_ready) begin
		// Hold the decode_execute register if the execute stage is not ready
		// Hold the instruction, but preserve operand corrections.
		if (memory_writeback.reg_write &&
			memory_writeback.rd != 0) begin
			
			// writeback doesnt stall so need to update decode_execute if writeback has needed data
			if (decode_execute.rs1 == memory_writeback.rd)
				decode_execute.rs1_data <= wbd;

			if (decode_execute.rs2 == memory_writeback.rd)
				decode_execute.rs2_data <= wbd;
		end
	end else if (hazard_stall) begin
		// Instruction in execute can move to the memory stage but instruction in decode is stalled
		// need to insert a NOP into execute
		decode_execute.rs1 <= 0;
		decode_execute.rs2 <= 0;
		decode_execute.rs1_data <= 0;
		decode_execute.rs2_data <= 0;
		decode_execute.imm <= 0;
		decode_execute.rd <= 0;
		decode_execute.f3 <= 0;
		decode_execute.f7 <= 0;
		decode_execute.op_q <= q_op_imm;
		decode_execute.reg_write <= 0;
		decode_execute.mem_write <= 0;
		decode_execute.mem_read <= 0;
		decode_execute.mem_to_reg <= 0;
		decode_execute.pc <= 0;
	end else begin
		decode_execute.rs1 <= rs1;
		decode_execute.rs2 <= rs2;
		if (rs1 == `tag_size'd0)
			decode_execute.rs1_data <= '0;
		else if (rs1 == memory_writeback.rd && memory_writeback.reg_write)
			decode_execute.rs1_data <= wbd;
		else
			decode_execute.rs1_data <= reg_file[rs1];
		if (rs2 == `tag_size'd0)
			decode_execute.rs2_data <= '0;
		else if (rs2 == memory_writeback.rd && memory_writeback.reg_write)
			decode_execute.rs2_data <= wbd;
		else
			decode_execute.rs2_data <= reg_file[rs2];
		decode_execute.imm <= imm;
		decode_execute.rd <= wbs;
		decode_execute.f3 <= f3;
		decode_execute.f7 <= f7;
		decode_execute.op_q <= op_q;	
		decode_execute.reg_write <= wbv;
		decode_execute.mem_write <= mem_write_n;
		decode_execute.mem_read <= mem_read_n;
		decode_execute.mem_to_reg <= mem_to_reg_n;
		decode_execute.pc <= fetch_decode.pc;
	end
	//$display("Decode: imm = %h, rd = %d, f3 = %d", $signed(imm), wbs, f3);
	//if (decode_execute.stall || decode_execute.jump || decode_execute.branch)
	//    $display("Instr= %b", fetch_decode.instruction);
	//else
	//    $display("Instr= %b", fetched_instruction);
	//$display("f7 = %d, op_q= %d, rw= %d, r1= %d, r2 = %d", f7, op_q, wbv, reg_file[rs1], reg_file[rs2]);
	//$display("br1 = %d, br2 = %d, stall = %d", br_data_1, br_data_2, stall);
	// $display("branch = %d, target = %h", branch_n, br_addr);
	// $display("jump = %d, target = %h", jump_n, jump_target);
end

endmodule

module execute_stage(
	input  logic clk,
	input  logic reset,
	input  decode_execute_reg decode_execute,
	input  logic [1:0] ForwardA,
	input  logic [1:0] ForwardB,
	input  word wbd,
	input  logic memory_ready,
	output logic execute_ready,
	output execute_memory_reg execute_memory
);

assign execute_ready = memory_ready;

ext_operand exec_result_comb;
word alu_rs1, alu_rs2;

always_comb begin
		case (ForwardA)
				2'b00: alu_rs1 = decode_execute.rs1_data;
				2'b01: alu_rs1 = wbd;
				2'b10: alu_rs1 = execute_memory.exec_result;
				default: alu_rs1 = decode_execute.rs1_data;
		endcase
		
		case (ForwardB)
				2'b00: alu_rs2 = decode_execute.rs2_data;
				2'b01: alu_rs2 = wbd;
				2'b10: alu_rs2 = execute_memory.exec_result;
				default: alu_rs2 = decode_execute.rs2_data;
		endcase
		
		if (decode_execute.rs1 == `tag_size'd0)
				alu_rs1 = `word_size'd0;
		if (decode_execute.rs2 == `tag_size'd0)
				alu_rs2 = `word_size'd0;
		
		exec_result_comb = execute(
			cast_to_ext_operand(alu_rs1),
			cast_to_ext_operand(alu_rs2),
			cast_to_ext_operand(decode_execute.imm),
			decode_execute.pc,
			decode_execute.op_q,
			decode_execute.f3,
			decode_execute.f7);
end

always_ff @(posedge clk) begin
	if (reset) begin
		execute_memory.exec_result <= '0;
		execute_memory.rs2_data <= '0;
		execute_memory.rd <= '0;
		execute_memory.reg_write <= '0;
		execute_memory.mem_to_reg <= '0;
		execute_memory.mem_read <= '0;
		execute_memory.mem_write <= '0;
		execute_memory.f3 <= '0;
		execute_memory.rs2 <= '0;
	end else if (execute_ready) begin
		if (decode_execute.op_q == q_jal || decode_execute.op_q == q_jalr)
			execute_memory.exec_result <= decode_execute.pc + 4;
		else
			execute_memory.exec_result <= exec_result_comb[`word_size-1:0];

		execute_memory.rs2 <= decode_execute.rs2;
		execute_memory.rs2_data <= alu_rs2; // Value after execute forwarding
		execute_memory.rd <= decode_execute.rd;
		execute_memory.reg_write <= decode_execute.reg_write;
		execute_memory.mem_to_reg <= decode_execute.mem_to_reg;
		execute_memory.mem_read <= decode_execute.mem_read;
		execute_memory.mem_write <= decode_execute.mem_write;
		execute_memory.f3 <= decode_execute.f3;
		//$display("Execute: alu_result = %h", $signed(exec_result_comb[`word_size-1:0]));
	end

	// Hold execute_memory if not ready
	
end

endmodule

module mem_stage(
	input  logic clk,
	input  logic reset,
	input  execute_memory_reg execute_memory,
	input  memory_io_rsp data_mem_rsp,
	output memory_writeback_reg memory_writeback,
	output memory_io_req data_mem_req,
	output logic memory_ready
);

word write_data;

typedef enum {
	STATE_REQUEST,
	STATE_WAIT
} memory_state_t;

memory_state_t memory_state, memory_state_n;

assign memory_ready = !reset && (!(execute_memory.mem_read || execute_memory.mem_write) || 
					(data_mem_rsp.valid && memory_state == STATE_WAIT));

always_comb begin
		write_data = execute_memory.rs2_data;
		/*
		data_mem_req.valid = false;
		data_mem_req.do_read = {(`word_address_size/8){1'b0}};
		data_mem_req.do_write = {(`word_address_size/8){1'b0}};
		data_mem_req.addr = {(`word_address_size){1'b0}};
		data_mem_req.data = {(`word_size){1'b0}};
		*/
		// This effectively does the above.  The above is there for documentation
		data_mem_req = memory_io_no_req32;
		memory_state_n = memory_state;

		if (!reset && data_mem_rsp.ready && (execute_memory.mem_read || execute_memory.mem_write)
										 && (memory_state == STATE_REQUEST)) begin
			data_mem_req.addr = execute_memory.exec_result;
			memory_state_n = STATE_WAIT;
			if (execute_memory.mem_write) begin
				data_mem_req.valid = true;
				data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory.f3)), execute_memory.exec_result);
				data_mem_req.data = shuffle_store_data(write_data, execute_memory.exec_result);
			end else
			if (execute_memory.mem_read) begin
				data_mem_req.valid = true;
				data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(execute_memory.f3)), execute_memory.exec_result);
			end
		end else if (data_mem_rsp.valid && memory_state == STATE_WAIT) begin
			memory_state_n = STATE_REQUEST;
		end
end

always_ff @(posedge clk) begin
	if (reset)
		memory_state <= STATE_REQUEST;
	else 
		memory_state <= memory_state_n;
end

always_ff @(posedge clk) begin
	if (reset) begin
		memory_writeback.read_data <= '0;
		memory_writeback.alu_result <= '0;
		memory_writeback.rd <= '0;
		memory_writeback.reg_write <= '0;
		memory_writeback.mem_to_reg <= '0;
		memory_writeback.f3 <= '0;
	end else if (memory_ready) begin
		memory_writeback.read_data <= data_mem_rsp.data;
		memory_writeback.alu_result <= execute_memory.exec_result;
		memory_writeback.rd <= execute_memory.rd;
		memory_writeback.reg_write <= execute_memory.reg_write;
		memory_writeback.mem_to_reg <= execute_memory.mem_to_reg;
		memory_writeback.f3 <= execute_memory.f3;
	end else begin
		memory_writeback.read_data <= '0;
		memory_writeback.alu_result <= '0;
		memory_writeback.rd <= '0;
		memory_writeback.reg_write <= '0;
		memory_writeback.mem_to_reg <= '0;
		memory_writeback.f3 <= '0;
	// if (execute_memory.mem_write&& data_mem_rsp.ready)
		// $display("write_data = %h", write_data);
	// $display("Memory: alu_result = %h, rd = %d", $signed(execute_memory.exec_result), execute_memory.rd);
	// $display("wr = %d, read = %d", execute_memory.reg_write, $signed(data_mem_rsp.data));
	end
end

endmodule


module writeback_stage(
	input  logic clk,
	input  logic reset,
	input  memory_writeback_reg memory_writeback,
	output word wbd
);

always_comb begin
		if (memory_writeback.mem_to_reg)
			wbd = subset_load_data(
							shuffle_load_data(memory_writeback.read_data, memory_writeback.alu_result),
							cast_to_memory_op(memory_writeback.f3));
		else
			wbd = memory_writeback.alu_result;

end

endmodule


module core(
	input  logic clk,
	input  logic reset,
	input  logic [`word_address_size-1:0] reset_pc,
	output memory_io_req inst_mem_req,
	input  memory_io_rsp inst_mem_rsp,
	output memory_io_req data_mem_req,
	input  memory_io_rsp data_mem_rsp
);

	logic [`word_address_size-1:0] pc;
	word wbd;
	ext_operand redirect_target;
	
	// Control signals
	logic stall, redirect, execute_ready, memory_ready;
	logic [1:0] ForwardA, ForwardB;
	
	// Inter-stage registers
	fetch_decode_reg fetch_decode;
	decode_execute_reg decode_execute;
	execute_memory_reg execute_memory;
	memory_writeback_reg memory_writeback;


	// Operand forwarding logic
	always_comb begin
		ForwardA = 2'b00;
		ForwardB = 2'b00;
		if (execute_memory.reg_write && execute_memory.rd != 0 && execute_memory.rd == decode_execute.rs1)
			ForwardA = 2'b10;
		else if (memory_writeback.reg_write && memory_writeback.rd != 0 && memory_writeback.rd == decode_execute.rs1)
			ForwardA = 2'b01;
		if (execute_memory.reg_write && execute_memory.rd != 0 && execute_memory.rd == decode_execute.rs2)
			ForwardB = 2'b10;
		else if (memory_writeback.reg_write && memory_writeback.rd != 0 && memory_writeback.rd == decode_execute.rs2)
			ForwardB = 2'b01;
	end

	// Module instances

	fetch_stage fetch_i (
		.clk             (clk),
		.reset           (reset),
		.redirect        (redirect),
		.stall           (stall),
		.reset_pc        (reset_pc),
		.redirect_target (redirect_target),
		.inst_mem_rsp    (inst_mem_rsp),
		.inst_mem_req    (inst_mem_req),
		.fetch_decode    (fetch_decode)
	);

	decode_stage decode_i (
		.clk              (clk),
		.reset            (reset),
		.wbd              (wbd),
		.execute_ready    (execute_ready),
		.fetch_decode     (fetch_decode),
		.memory_writeback (memory_writeback),
		.execute_memory   (execute_memory),
		.redirect         (redirect),
		.stall            (stall),
		.decode_execute   (decode_execute),
		.redirect_target  (redirect_target)
	);

	execute_stage execute_i (
		.clk             (clk),
		.reset           (reset),
		.decode_execute  (decode_execute),
		.ForwardA        (ForwardA),
		.ForwardB        (ForwardB),
		.wbd             (wbd),
		.memory_ready    (memory_ready),
		.execute_ready   (execute_ready),
		.execute_memory  (execute_memory)
	);

	mem_stage mem_i (
		.clk              (clk),
		.reset            (reset),
		.execute_memory   (execute_memory),
		.data_mem_rsp     (data_mem_rsp),
		.memory_writeback (memory_writeback),
		.data_mem_req     (data_mem_req),
		.memory_ready     (memory_ready)
	);

	writeback_stage writeback_i (
		.clk              (clk),
		.reset            (reset),
		.memory_writeback (memory_writeback),
		.wbd              (wbd)
	);

endmodule
`endif

