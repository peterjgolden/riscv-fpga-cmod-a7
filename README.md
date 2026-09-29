# RV32I RISC-V CPU on the Digilent Cmod A7

A multicycle RV32I RISC-V CPU system implemented in SystemVerilog for the Digilent Cmod A7-35T FPGA.

## Overview

This project ports a multicycle RV32I processor to a Xilinx Artix-7 FPGA and builds a small memory-mapped system around it.

The current implementation uses the Cmod A7's 12 MHz onboard oscillator directly and includes:

- Multicycle RV32I processor
- Instruction memory implemented with FPGA block RAM
- 4 KiB data RAM
- Memory-mapped LED output
- Memory-mapped UART transmitter, receiver, and status registers
- Small RV32I program stored in instruction memory that polls UART status and echoes received characters
- UART receiver with asynchronous-input synchronization, framing-error detection, and overrun handling