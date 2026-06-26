// ================================================================

// ----------------------------------------------------------------
// Macro definitions
// Define POR_HLD_DELAY and POR_MEM_DELAY as empty for zero-delay
// simulation. Replace with timing values (e.g. #0.1) for
// annotated simulation. Kept empty for synthesis compatibility.
// ----------------------------------------------------------------
`ifndef POR_HLD_DELAY
   `define POR_HLD_DELAY #0.1
`endif

`ifndef POR_MEM_DELAY
   `define POR_MEM_DELAY #0.1
`endif

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

parameter ROWS           = 1024,
          ADDR_WIDTH     = 14,
          COLS           = 8,
          WR_MASK_TYPE   = 0,
          WR_MASK_WIDTH  = 1,
          LATENCY        = 2,
          MBIST_CHECKER_EN = 1;

// ----------------------------------------------------------------
// Port Declarations
// ----------------------------------------------------------------
input  [ADDR_WIDTH-1:0]    addr;
input  [COLS-1:0]          data_in;        
input                      chip_select;
input                      write_enable;
input  [WR_MASK_WIDTH-1:0] write_mask;
input                      clk;              // Write clock domain
input                      clk_inst;         // Read / pipeline clock domain
input                      global_reset;     // Asynchronous active-high reset

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
// POR_HLD_DELAY annotates hold-time delays for simulation.
// Expands to nothing for synthesis and zero-delay simulation.
// ----------------------------------------------------------------
assign `POR_HLD_DELAY addr_dly        = addr;
assign `POR_HLD_DELAY data_in_dly     = data_in;
assign `POR_HLD_DELAY chip_select_dly = chip_select;
assign `POR_HLD_DELAY write_dly       = write_enable;

// forcex tied to 0 — synthesis optimizes ForceX block away entirely
assign forcex = 1'b0;

// ----------------------------------------------------------------
// Write Mask Expansion (Combinatorial)
// Expands WR_MASK_WIDTH-bit mask into full COLS-bit enable vector.
//
// WR_MASK_TYPE cases:
//   0       = No mask     — all bits always writable
//   1       = Bit-wise    — 1 mask bit controls 1 data bit
//   8       = Byte-wise   — 1 mask bit controls 8 data bits
//   default = N-bit gran  — 1 mask bit controls WR_MASK_TYPE bits
// ----------------------------------------------------------------

assign `POR_HLD_DELAY enables_dly = enables_expand;

// ----------------------------------------------------------------
// Read Path — Combinatorial Memory Read
// data_outi immediately reflects memory[addr_dly] — no register
// ----------------------------------------------------------------
assign data_outi = memory[addr_dly];

// ----------------------------------------------------------------
// Read / Write Enable Qualifiers
// rden = active read  : chip_select=1, write_enable=0
// wren = active write : chip_select=1, write_enable=1
// ----------------------------------------------------------------
wire rden;
wire wren;

assign rden = chip_select_dly & ~write_dly;
assign wren = chip_select_dly &  write_dly;

// ----------------------------------------------------------------
// Read Path — Stage 1 Pipeline Register (clk_inst domain)
//
// Cycle behavior:
//   READ  (chip_select=1, write_enable=0) → capture data_outi
//   WRITE (chip_select=1, write_enable=1) → inject {COLS{1'bx}}
//   IDLE  (chip_select=0)                 → inject {COLS{1'bx}}
//
// X injection on non-read cycles is intentional — propagates
// through downstream pipeline stages and exposes any incorrect
// read timing as visible X on data_out in simulation.
// ----------------------------------------------------------------
reg [COLS-1:0] data_out_int;


// ----------------------------------------------------------------
// Pipeline Shift Registers — clk_inst domain
//
// wren_dly / rden_dly : 4-stage enable pipelines
// data_out_dly        : 4-stage data output pipeline
//
// Pipeline depth selectable via LATENCY parameter:
//   LATENCY=1 → data_out_int       (Stage 1)
//   LATENCY=2 → data_out_dly[0]   (Stage 2)
//   LATENCY=3 → data_out_dly[1]   (Stage 3)
//   LATENCY=4 → data_out_dly[2]   (Stage 4)
//   LATENCY=5 → data_out_dly[3]   (Stage 5)
//
// ----------------------------------------------------------------
reg [3:0]      wren_dly;
reg [3:0]      rden_dly;
reg [COLS-1:0] data_out_dly[3:0];

reg            chip_select_hold;    // Reserved — not currently used

always @ (posedge clk_inst or posedge global_reset)
    begin
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

        end
        else begin

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
endmodule
