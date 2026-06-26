`timescale 1ns/1ns

`define POR_HLD_DELAY  #0.1
`define POR_MEM_DELAY  #0.2

module sram (
                data_out,
                addr,
                data_in,
                chip_select,
                write_enable,
                write_mask,
                clk,
                clk_inst,
                global_reset
                );

parameter ROWS          = 1024,
          ADDR_WIDTH    = 14,
          COLS          = 8,
          WR_MASK_TYPE  = 0,
          WR_MASK_WIDTH = 1,
          LATENCY       = 2,
          MBIST_CHECKER_EN = 1;

// ----------------------------------------------------------------
// Port Declarations
// ----------------------------------------------------------------
input  [ADDR_WIDTH-1:0]    addr;
input  [COLS-1:0]          data_in;         
input                      chip_select;
input                      write_enable;
input  [WR_MASK_WIDTH-1:0] write_mask;
input                      clk;             // Write clock
input                      clk_inst;        // Read / pipeline clock
input                      global_reset;    // Asynchronous active-high reset

output [COLS-1:0]          data_out;

// ----------------------------------------------------------------
// Internal Memory Array
// ----------------------------------------------------------------
reg    [COLS-1:0]          memory[ROWS-1:0];

// ----------------------------------------------------------------
// Wire & Register Declarations
// ----------------------------------------------------------------
wire   [COLS-1:0]          data_out;
wire   [COLS-1:0]          data_outi;
reg    [COLS-1:0]          data_tmp;

integer                    i;
integer                    j;

wire   [ADDR_WIDTH-1:0]    addr_dly;
wire   [COLS-1:0]          data_in_dly;
wire                       chip_select_dly;
reg    [COLS-1:0]          enables_expand;
wire   [COLS-1:0]          enables_dly;
wire                       write_dly;

wire                       forcex;

// ----------------------------------------------------------------
// Delayed Signal Assignments
// ----------------------------------------------------------------
assign `POR_HLD_DELAY addr_dly        = addr;
assign `POR_HLD_DELAY data_in_dly     = data_in;
assign `POR_HLD_DELAY chip_select_dly = chip_select;
assign `POR_HLD_DELAY write_dly       = write_enable;

assign forcex = 1'b0;

assign `POR_HLD_DELAY enables_dly = enables_expand;

// ----------------------------------------------------------------
// Read Path — Combinatorial Memory Read
// data_outi reflects memory contents at addr_dly immediately
// ----------------------------------------------------------------
assign data_outi = memory[addr_dly];

// ----------------------------------------------------------------
// Read Enable / Write Enable Qualifiers
// ----------------------------------------------------------------
wire rden;
wire wren;

assign rden = chip_select_dly & ~write_dly;
assign wren = chip_select_dly &  write_dly;

// ----------------------------------------------------------------
// Read Path — Stage 1 Register (clk_inst)
// ----------------------------------------------------------------
reg [COLS-1:0] data_out_int;

// ----------------------------------------------------------------
// Read/Write Enable Pipeline Shift Registers + data_out_dly
// ----------------------------------------------------------------
reg [3:0]      wren_dly;
reg [3:0]      rden_dly;
reg [COLS-1:0] data_out_dly[3:0];      // 4-stage output pipeline

reg                  chip_select_hold;
reg [ADDR_WIDTH-1:0] addr_hold;
reg [COLS-1:0]       data_in_hold;

always @ (posedge clk_inst or posedge global_reset)
    begin
        if (global_reset == 1'b1) begin
            // Reset enable pipelines
            wren_dly[0] <= 1'b0;
            wren_dly[1] <= 1'b0;
            wren_dly[2] <= 1'b0;
            wren_dly[3] <= 1'b0;

            rden_dly[0] <= 1'b0;
            rden_dly[1] <= 1'b0;
            rden_dly[2] <= 1'b0;
            rden_dly[3] <= 1'b0;

            chip_select_hold <= 1'b0;

            data_out_dly[0] <= {COLS{1'b0}};
            data_out_dly[1] <= {COLS{1'b0}};
            data_out_dly[2] <= {COLS{1'b0}};
            data_out_dly[3] <= {COLS{1'b0}};
        end
        else begin
            wren_dly[0] <= wren;
            wren_dly[1] <= wren_dly[0];
            wren_dly[2] <= wren_dly[1];
            wren_dly[3] <= wren_dly[2];

            rden_dly[0] <= rden;
            rden_dly[1] <= rden_dly[0];
            rden_dly[2] <= rden_dly[1];
            rden_dly[3] <= rden_dly[2];

            chip_select_hold <= chip_select;

            data_out_dly[0] <= data_out_int;
            data_out_dly[1] <= data_out_dly[0];
            data_out_dly[2] <= data_out_dly[1];
            data_out_dly[3] <= data_out_dly[2];
        end
    end

// implement write block and forcex block
endmodule

