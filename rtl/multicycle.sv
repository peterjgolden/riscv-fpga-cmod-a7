// multicycle.sv
// Working multicycle design.


`ifndef _core_v
`define _core_v
`include "system.sv"
`include "base.sv"
`include "memory_io.sv"
/*

This is a very simple 5 stage multicycle RISC-V 32bit design.

The stages are fetch, decode, execute, memory, writeback

*/

module multicycle(
    input logic       clk
    ,input logic      reset
    ,input logic      [`word_address_size-1:0] reset_pc
    ,output memory_io_req   inst_mem_req
    ,input  memory_io_rsp   inst_mem_rsp
    ,output memory_io_req   data_mem_req
    ,input  memory_io_rsp   data_mem_rsp
    );

`include "riscv32_common.sv"

logic mem_req_sent;

typedef enum {
    stage_fetch
    ,stage_decode
    ,stage_execute
    ,stage_mem
    ,stage_writeback
}   stage;

stage   current_stage;


word_address    pc;

assign inst_mem_req.addr = pc;
assign inst_mem_req.valid = inst_mem_rsp.ready && (stage_fetch == current_stage);
assign inst_mem_req.do_read = (stage_fetch == current_stage) ? 4'b1111 : 0;

instr32    latched_instruction_read;
always_ff @(posedge clk) begin
    if (inst_mem_rsp.valid) begin
        latched_instruction_read <= inst_mem_rsp.data;
    end

end

instr32    fetched_instruction;
assign fetched_instruction = (inst_mem_rsp.valid) ? inst_mem_rsp.data : latched_instruction_read;

/*

  Instruction decode

*/
tag     rs1;
tag     rs2;
word    rd1;
word    rd2;
tag     wbs;
word    wbd;
logic   wbv;
word    reg_file_rd1;
word    reg_file_rd2;
word    imm;
funct3  f3;
funct7  f7;
opcode_q op_q;
instr_format format;
bool     is_memory_op;

word    reg_file[0:31];
integer i;

always_comb begin
    rs1 = decode_rs1(fetched_instruction);
    rs2 = decode_rs2(fetched_instruction);
    wbs = decode_rd(fetched_instruction);
    f3 = decode_funct3(fetched_instruction);
    op_q = decode_opcode_q(fetched_instruction);
    format = decode_format(op_q);
    imm = decode_imm(fetched_instruction, format);
    wbv = decode_writeback(op_q);
    f7 = decode_funct7(fetched_instruction, format);
end
/*
always_ff @(posedge clk) begin
	if (current_stage == stage_decode)
		$display("Decode: alu_op = %b, RS1: %b, RS2: %b, rd: %b, imm: %b", op_q, rs1, rs2, wbs, imm);
end
*/
logic read_reg_valid;
logic write_reg_valid;

always_ff @(posedge clk) begin
    if (reset) begin
        reg_file_rd1 <= '0;
        reg_file_rd2 <= '0;
        
        for (i = 0; i < 32; i = i + 1) begin
            reg_file[i] <= '0;
        end
    end else if (read_reg_valid) begin
        reg_file_rd1 <= reg_file[rs1];
        reg_file_rd2 <= reg_file[rs2];
    end
    else if (write_reg_valid && (wbs != '0))
        reg_file[wbs] <= wbd;
end

logic memory_stage_complete;
always_comb begin
    if (op_q == q_load || op_q == q_store) begin
        if (data_mem_rsp.valid)
            memory_stage_complete = true;
        else
            memory_stage_complete = false;
    end else
        memory_stage_complete = true;
end

always_comb begin
    read_reg_valid = false;
    write_reg_valid = false;
    if (current_stage == stage_decode) begin
        read_reg_valid = true;
    end

    if (memory_stage_complete && current_stage == stage_writeback && wbv) begin
        write_reg_valid = true;
    end
end

/*

 Instruction execute

 */

always_comb begin
    if (rs1 == `tag_size'd0)
        rd1 = `word_size'd0;
    else
        rd1 = reg_file_rd1;        
    if (rs2 == `tag_size'd0)
        rd2 = `word_size'd0;
    else
        rd2 = reg_file_rd2;        
end

ext_operand exec_result_comb;
word next_pc_comb;
always_comb begin
    exec_result_comb = execute(
        cast_to_ext_operand(rd1),
        cast_to_ext_operand(rd2),
        cast_to_ext_operand(imm),
        pc,
        op_q,
        f3,
        f7);
	 if (op_q == q_branch || op_q == q_jal || op_q == q_jalr) begin
		next_pc_comb = exec_result_comb[31:0];
	 end else begin
		next_pc_comb = pc + 4;
	 end
end

word exec_result;
word next_pc;
always_ff @(posedge clk) begin
    if (current_stage == stage_execute) begin
        exec_result <= exec_result_comb[`word_size-1:0];
        next_pc <= next_pc_comb;
		//$display("Execute: alu_result = %d", $signed(exec_result_comb[`word_size-1:0]));
    end
end

/*

  Stage and mem

 */

always_comb begin
    /*
    data_mem_req.valid = false;
    data_mem_req.do_read = {(`word_address_size/8){1'b0}};
    data_mem_req.do_write = {(`word_address_size/8){1'b0}};
    data_mem_req.addr = {(`word_address_size){1'b0}};
    data_mem_req.data = {(`word_size){1'b0}};
    */
    // This effectively does the above.  The above is there for documentation
    data_mem_req = memory_io_no_req32;

    if (data_mem_rsp.ready && current_stage == stage_mem && (op_q == q_store || op_q == q_load)) begin
        data_mem_req.addr = exec_result[`word_address_size - 1:0];
        if (op_q == q_store) begin
            data_mem_req.valid = true;
            data_mem_req.do_write = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
            data_mem_req.data = shuffle_store_data(rd2, exec_result);
        end else
        if (op_q == q_load) begin
            data_mem_req.valid = true;
            data_mem_req.do_read = shuffle_store_mask(memory_mask(cast_to_memory_op(f3)), exec_result);
        end
    end
end

word load_result;
always_ff @(posedge clk) begin
    if (data_mem_rsp.valid)
        load_result <= data_mem_rsp.data;
end

always_comb begin
    if (op_q == q_load)
        wbd = subset_load_data(
                    shuffle_load_data(data_mem_rsp.valid ? data_mem_rsp.data : load_result, exec_result),
                    cast_to_memory_op(f3));
    else if (op_q == q_jal || op_q == q_jalr)
	     wbd = pc + 4;
	 else
        wbd = exec_result;

end

word instruction_count /*verilator public*/;
always_ff @(posedge clk) begin
    if (reset) begin
        pc <= reset_pc;
        instruction_count <= 0;
    end else begin
        if (current_stage == stage_writeback) begin
            pc <= next_pc;
            instruction_count <= instruction_count + 1;
        end
    end

    //if (instruction_count > 10000)
    //    $finish;
end

/*

 Stage control

 */
always_ff @(posedge clk) begin
    if (reset)
        current_stage <= stage_fetch;
    else begin
        case (current_stage)
            stage_fetch:
                if (inst_mem_rsp.valid) begin
                    current_stage <= stage_decode;
				end
            stage_decode:
                current_stage <= stage_execute;
            stage_execute:
                current_stage <= stage_mem;
            stage_mem: begin
				//$display("STAGE: MEMORY");
                current_stage <= stage_writeback;
			end
            stage_writeback:
                if (memory_stage_complete)
                    current_stage <= stage_fetch;
            default:
                current_stage <= stage_fetch;
        endcase
    end
    
    /*
    if (current_stage == stage_fetch || (current_stage == stage_mem && !memory_stage_complete)) begin
        $display("\n");
        $display("Instruction Count: %d", instruction_count);
        $display("Current Pipeline Stages: PC = %h", pc);
        $display("Fetch: PC = %h, Instruction: %h", pc, fetched_instruction);
        $display("ra: %h   s0: %h  s1: %h  a0: %h", reg_file[1], reg_file[8], reg_file[9], reg_file[10]);
        $display("a2: %h   a3: %h  a4: %h  a5: %h", reg_file[12], reg_file[13], reg_file[14], reg_file[15]); 
        $display("s5: %h   s6: %h  sp: %h", reg_file[21], reg_file[22], reg_file[2]);     
        $display("Memory req sent : %b", mem_req_sent);
        $display("WBD: %h", wbd);
        $display("exec_result_comb: %h", exec_result_comb);
        $display("Data mem rsp: %h", data_mem_rsp.data);
    end
    */
    
end

always_ff @(posedge clk) begin
    if (reset) begin
        mem_req_sent <= 0;
    end else begin
        if (data_mem_req.valid && !mem_req_sent) begin
            mem_req_sent <= 1;
        end else if (data_mem_rsp.valid) begin
            mem_req_sent <= 0;
        end
    end
end

endmodule
`endif