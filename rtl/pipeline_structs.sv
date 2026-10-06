// pipeline_structs.sv
`ifndef _pipeline_structs_v
`define _pipeline_structs_v

typedef struct packed {
	logic [`word_address_size-1:0] pc;
	instr32 instruction;
}	fetch_decode_reg;

typedef struct packed {
	word_address pc;
	tag rs1;
	tag rs2;
	word rs1_data;
	word rs2_data;
	word imm;
	tag rd;
	funct3  f3;
	funct7  f7;
	opcode_q op_q;
	logic reg_write;
	logic mem_write;
	logic mem_read;
	logic mem_to_reg;
}	decode_execute_reg;

typedef struct packed {
	word exec_result;
	word rs2_data;
	tag rs2;
	tag rd;
	logic reg_write;
	logic mem_write;
	logic mem_read;
	logic mem_to_reg;
	funct3  f3;
} execute_memory_reg;

typedef struct packed {
	word read_data;
	word alu_result;
	tag rd;
	logic reg_write;
	logic mem_to_reg;
	funct3  f3;
	logic valid;
} memory_writeback_reg;

`endif
