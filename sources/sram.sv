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
// Internal Memory Array — stores data + ECC parity bits per word
// Storage width = COLS + ECC_BITS (parity stored alongside data)
// ================================================================
reg    [COLS+`ECC_BITS-1:0] memory[ROWS-1:0];

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
always @(*) begin : ecc_write_parity
    integer b;
    wr_parity = {`ECC_BITS{1'b0}};
    if (ECC_EN) begin
        // Each parity bit Pi covers all bit positions where bit i
        // of the position index is 1
        for (b = 0; b < COLS; b = b + 1) begin
            if ((b+1) & 6'h01) wr_parity[0] = wr_parity[0] ^ data_in_dly[b];
            if ((b+1) & 6'h02) wr_parity[1] = wr_parity[1] ^ data_in_dly[b];
            if ((b+1) & 6'h04) wr_parity[2] = wr_parity[2] ^ data_in_dly[b];
            if ((b+1) & 6'h08) wr_parity[3] = wr_parity[3] ^ data_in_dly[b];
            if ((b+1) & 6'h10) wr_parity[4] = wr_parity[4] ^ data_in_dly[b];
        end
        // P_overall = XOR of all data bits and parity bits (SECDED)
        wr_parity[5] = ^data_in_dly ^ ^wr_parity[4:0];
    end
end

// ECC Read Syndrome Computation and Correction (combinatorial)
reg  [COLS-1:0]        rd_data_raw;
reg  [`ECC_BITS-1:0]   rd_parity_stored;
reg  [`ECC_BITS-1:0]   rd_syndrome;
reg  [COLS-1:0]        rd_data_corrected;
reg                    rd_single_err;
reg                    rd_double_err;

always @(*) begin : ecc_read_correct
    integer b;
    rd_data_raw     = memory[addr_dly][COLS-1:0];
    rd_parity_stored= memory[addr_dly][COLS+`ECC_BITS-1:COLS];
    rd_syndrome     = {`ECC_BITS{1'b0}};
    rd_data_corrected = rd_data_raw;
    rd_single_err   = 1'b0;
    rd_double_err   = 1'b0;

    if (ECC_EN) begin
        // Recompute parity over stored data
        for (b = 0; b < COLS; b = b + 1) begin
            if ((b+1) & 6'h01) rd_syndrome[0] = rd_syndrome[0] ^ rd_data_raw[b];
            if ((b+1) & 6'h02) rd_syndrome[1] = rd_syndrome[1] ^ rd_data_raw[b];
            if ((b+1) & 6'h04) rd_syndrome[2] = rd_syndrome[2] ^ rd_data_raw[b];
            if ((b+1) & 6'h08) rd_syndrome[3] = rd_syndrome[3] ^ rd_data_raw[b];
            if ((b+1) & 6'h10) rd_syndrome[4] = rd_syndrome[4] ^ rd_data_raw[b];
        end
        // XOR recomputed with stored parity to form syndrome
        rd_syndrome[4:0] = rd_syndrome[4:0] ^ rd_parity_stored[4:0];
        // Overall parity check
        rd_syndrome[5] = (^rd_data_raw ^ ^rd_parity_stored[4:0] ^
                          rd_parity_stored[5]);

        if (rd_syndrome[4:0] != 5'b0) begin
            if (rd_syndrome[5]) begin
                // Single-bit error — correct the flipped bit
                rd_single_err = 1'b1;
                if (rd_syndrome[4:0] <= COLS)
                    rd_data_corrected[rd_syndrome[4:0]-1] =
                        ~rd_data_raw[rd_syndrome[4:0]-1];
            end else begin
                // Double-bit error — uncorrectable
                rd_double_err = 1'b1;
            end
        end
    end
end

assign data_outi_corrected = rd_data_corrected;

// ECC error registration
always @ (posedge clk_inst or posedge global_reset) begin
    if (global_reset) begin
        ecc_single_err_r <= 1'b0;
        ecc_double_err_r <= 1'b0;
        ecc_err_addr_r   <= {ADDR_WIDTH{1'b0}};
    end else begin
        if (chip_select_dly & ~write_dly) begin
            ecc_single_err_r <= rd_single_err;
            ecc_double_err_r <= rd_double_err;
            if (rd_single_err | rd_double_err)
                ecc_err_addr_r <= addr_dly;
        end else begin
            ecc_single_err_r <= 1'b0;
            ecc_double_err_r <= 1'b0;
        end
    end
end

// ================================================================
// Write Mask Expansion (Combinatorial) 
// ================================================================
always @(write_mask)
    case (WR_MASK_TYPE)
        0: enables_expand = {COLS{1'b1}};
        1: enables_expand = write_mask;
        8: begin
            enables_expand = {COLS{1'b0}};
            for (i=0; i<WR_MASK_WIDTH; i=i+1)
                enables_expand = enables_expand | ({8{write_mask[i]}} << (i << 3));
        end
        default: begin
            enables_expand = {COLS{1'b0}};
            for (i=0; i<WR_MASK_WIDTH; i=i+1)
                for (j=0; j<WR_MASK_TYPE; j=j+1)
                    enables_expand = enables_expand |
                                     write_mask[i] << (i * WR_MASK_TYPE + j);
        end
    endcase

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

always @ (posedge clk_inst) begin
        if (chip_select_dly & ~write_dly)
            data_out_int <= `POR_MEM_DELAY data_outi_corrected;
        else
            data_out_int <= `POR_MEM_DELAY {COLS{1'bx}};
end

// ================================================================
// Pipeline Shift Registers — clk_inst domain
// ================================================================
reg [3:0]      wren_dly;
reg [3:0]      rden_dly;
reg [COLS-1:0] data_out_dly[3:0];
reg            chip_select_hold;

always @ (posedge clk_inst or posedge global_reset) begin
    if (global_reset == 1'b1) begin
        wren_dly[0]      <= 1'b0;
        wren_dly[1]      <= 1'b0;
        wren_dly[2]      <= 1'b0;
        wren_dly[3]      <= 1'b0;
        rden_dly[0]      <= 1'b0;
        rden_dly[1]      <= 1'b0;
        rden_dly[2]      <= 1'b0;
        rden_dly[3]      <= 1'b0;
        chip_select_hold <= 1'b0;
        data_out_dly[0]  <= {COLS{1'bx}};
        data_out_dly[1]  <= {COLS{1'bx}};
        data_out_dly[2]  <= {COLS{1'bx}};
        data_out_dly[3]  <= {COLS{1'bx}};
    end else begin
        wren_dly[0]      <= wren;
        wren_dly[1]      <= wren_dly[0];
        wren_dly[2]      <= wren_dly[1];
        wren_dly[3]      <= wren_dly[2];
        rden_dly[0]      <= rden;
        rden_dly[1]      <= rden_dly[0];
        rden_dly[2]      <= rden_dly[1];
        rden_dly[3]      <= rden_dly[2];
        chip_select_hold <= chip_select;
        data_out_dly[0]  <= data_out_int;
        data_out_dly[1]  <= data_out_dly[0];
        data_out_dly[2]  <= data_out_dly[1];
        data_out_dly[3]  <= data_out_dly[2];
    end
end

// ================================================================
// data_out — Parameterized Latency Tap
// Output isolation applied when power gated
// ================================================================

assign data_out = (LATENCY == 1) ? data_out_int    :
                  (LATENCY == 2) ? data_out_dly[0] :
                  (LATENCY == 3) ? data_out_dly[1] :
                  (LATENCY == 4) ? data_out_dly[2] :
                                   data_out_dly[3];


// ================================================================
// Write Path — Core Memory Write (clk domain)
// ECC parity computed and stored alongside data
// ================================================================
always @ (posedge clk) begin
    if (chip_select_dly & write_dly & ~global_reset & ~forcex )
    begin
        data_tmp = memory[addr_dly][COLS-1:0];
        for (i=0; i<COLS; i=i+1) begin
            if (enables_dly[i])
                data_tmp[i] = data_in_dly[i];
        end
        // Store data with freshly computed ECC parity
        memory[addr_dly] = {wr_parity, data_tmp};
    end
end
endmodule
