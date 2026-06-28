`timescale 1ns/1ps

`ifndef POR_HLD_DELAY
   `define POR_HLD_DELAY #0.1
`endif

`ifndef POR_MEM_DELAY
   `define POR_MEM_DELAY #0.1  
`endif

`define ECC_BITS  6    // valid for COLS=8; adjust for wider data

module sram (
    data_out,
    addr,
    data_in,
    chip_select,
    write_enable,
    write_mask,
    clk,
    clk_inst,
    global_reset,

    ecc_single_err,         // single-bit error detected and corrected
    ecc_double_err,         // double-bit error detected (uncorrectable)
    ecc_err_addr            // address where ECC error was detected
);

parameter ROWS            = 1024,
          ADDR_WIDTH      = 14,
          COLS            = 8,
          WR_MASK_TYPE    = 0,
          WR_MASK_WIDTH   = 1,
          LATENCY         = 2,
          MBIST_CHECKER_EN = 1,
          ECC_EN          = 1,       // 1=enable ECC, 0=bypass
          DUAL_PORT_EN    = 1,       // 1=enable port B
          POWER_GATE_EN   = 1;       // 1=enable power gating FSM

// ================================================================
// Port Declarations
// ================================================================
input  [ADDR_WIDTH-1:0]    addr;
input  [COLS-1:0]          data_in;
input                      chip_select;
input                      write_enable;
input  [WR_MASK_WIDTH-1:0] write_mask;
input                      clk;
input                      clk_inst;
input                      global_reset;

output [COLS-1:0]          data_out;

// ECC
output                     ecc_single_err;
output                     ecc_double_err;
output [ADDR_WIDTH-1:0]    ecc_err_addr;

// ================================================================
// Wire & Register Declarations
// ================================================================
wire   [COLS-1:0]           data_out;
wire   [COLS-1:0]           data_outi;
wire   [COLS-1:0]           data_outi_corrected;  // ECC-corrected read data
reg    [COLS-1:0]           data_tmp;

integer                     i;
integer                     j;

wire   [ADDR_WIDTH-1:0]     addr_dly;
wire   [COLS-1:0]           data_in_dly;
wire                        chip_select_dly;
reg    [COLS-1:0]           enables_expand;
wire   [COLS-1:0]           enables_dly;
wire                        write_dly;
wire                        forcex;

assign `POR_HLD_DELAY addr_dly        = addr;
assign `POR_HLD_DELAY data_in_dly     = data_in;
assign `POR_HLD_DELAY chip_select_dly = chip_select;
assign `POR_HLD_DELAY write_dly       = write_enable;
assign forcex = 1'b0;

// ================================================================
// FEATURE 1: ECC — Hamming SECDED
// ================================================================
// Architecture:
//   WRITE path: compute ECC parity over data_in, store
//               [COLS+ECC_BITS-1:0] = {parity, data} in memory
//   READ  path: recompute syndrome over stored word, detect
//               and correct single-bit errors, flag double-bit errors
//
// Syndrome computation:
//   syndrome = recomputed_parity XOR stored_parity
//   syndrome == 0            → no error
//   syndrome is power-of-2   → parity bit error (no data correction needed)
//   syndrome != 0, not pow2  → data bit error → flip bit at syndrome position
//   overall parity check     → distinguishes single vs double error
//
// ECC parity bit positions (1-indexed Hamming):
//   P1  covers bits: 1,3,5,7,9,11,...
//   P2  covers bits: 2,3,6,7,10,11,...
//   P4  covers bits: 4,5,6,7,12,13,...
//   P8  covers bits: 8,9,10,11,12,13,...
//   P16 covers bits: 16,17,...
//   P32 covers bits: 32,33,...
//   P_overall: XOR of all bits (SECDED extra parity bit)
// ================================================================

reg  [`ECC_BITS-1:0]    ecc_parity_wr;     // parity computed on write
reg  [`ECC_BITS-1:0]    ecc_parity_rd;     // parity recomputed on read
reg  [`ECC_BITS-1:0]    ecc_syndrome;      // syndrome = rd XOR stored
reg  [COLS-1:0]         ecc_corrected;     // corrected data word
reg                     ecc_single_err_r;
reg                     ecc_double_err_r;
reg  [ADDR_WIDTH-1:0]   ecc_err_addr_r;

assign ecc_single_err = ecc_single_err_r;
assign ecc_double_err = ecc_double_err_r;
assign ecc_err_addr   = ecc_err_addr_r;

// Raw data word read from memory (lower COLS bits only)
assign data_outi = memory[addr_dly][COLS-1:0];

// ECC Write Parity Computation (combinatorial)
// Computes Hamming parity bits over data_in_dly before write
reg [`ECC_BITS-1:0] wr_parity;

// ECC Read Syndrome Computation and Correction (combinatorial)
reg  [COLS-1:0]        rd_data_raw;
reg  [`ECC_BITS-1:0]   rd_parity_stored;
reg  [`ECC_BITS-1:0]   rd_syndrome;
reg  [COLS-1:0]        rd_data_corrected;
reg                    rd_single_err;
reg                    rd_double_err;

assign data_outi_corrected = rd_data_corrected;

// ================================================================
// Write Mask Expansion (Combinatorial) 
// ================================================================
assign `POR_HLD_DELAY enables_dly = enables_expand;

// ================================================================
// Read Enable / Write Enable Qualifiers
// ================================================================
wire rden;
wire wren;

assign rden = chip_select_dly & ~write_dly;
assign wren = chip_select_dly &  write_dly;

// ================================================================
// Read Path Stage 1 — uses ECC-corrected data
// Blocked during MBIST (MBIST owns memory bus)
// Isolated during power gate sleep/retention
// ================================================================
reg [COLS-1:0] data_out_int;

// ================================================================
// Pipeline Shift Registers — clk_inst domain
// ================================================================
reg [3:0]      wren_dly;
reg [3:0]      rden_dly;
reg [COLS-1:0] data_out_dly[3:0];
reg            chip_select_hold;

// ================================================================
// data_out — Parameterized Latency Tap
// Output isolation applied when power gated
// ================================================================


// ================================================================
// Write Path — Core Memory Write (clk domain)
// ECC parity computed and stored alongside data
// ================================================================
endmodule
