// ----------------------------------------------------------------
// Macro definitions
// Define POR_HLD_DELAY and POR_MEM_DELAY as empty for zero-delay
// simulation. Replace with timing values (e.g. #0.1) for
// annotated simulation. Kept empty for synthesis compatibility.
// ----------------------------------------------------------------
`ifndef POR_HLD_DELAY
   `define POR_HLD_DELAY 0.1
`endif

`ifndef POR_MEM_DELAY
   `define POR_MEM_DELAY 0.1
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
always @(write_mask)
    case (WR_MASK_TYPE)
        0: enables_expand = {COLS{1'b1}};

        1: enables_expand = write_mask;

        8:
        begin
            enables_expand = {COLS{1'b0}};
            for (i=0; i<WR_MASK_WIDTH; i=i+1)
                enables_expand = enables_expand | ({8{write_mask[i]}} << (i << 3));
        end

        default:
        begin
            enables_expand = {COLS{1'b0}};
            for (i=0; i<WR_MASK_WIDTH; i=i+1)
            begin
                for (j=0; j<WR_MASK_TYPE; j=j+1)
                    enables_expand = enables_expand | write_mask[i] << (i * WR_MASK_TYPE + j);
            end
        end
    endcase

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

always @ (posedge clk_inst) begin
    if (chip_select_dly & ~write_dly)      
        data_out_int <= `POR_MEM_DELAY data_outi;
    else
        data_out_int <= `POR_MEM_DELAY {COLS{1'bx}};
end

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

            // Reset enable pipelines to 0
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

            // Shift write enable pipeline
            wren_dly[0]      <= wren;
            wren_dly[1]      <= wren_dly[0];
            wren_dly[2]      <= wren_dly[1];
            wren_dly[3]      <= wren_dly[2];

            // Shift read enable pipeline
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

// ----------------------------------------------------------------
// Selects the correct pipeline stage based on LATENCY parameter.
// Default (LATENCY > 4) safely falls through to deepest stage.
// ----------------------------------------------------------------
assign data_out = (LATENCY == 1) ? data_out_int    :
                  (LATENCY == 2) ? data_out_dly[0] :
                  (LATENCY == 3) ? data_out_dly[1] :
                  (LATENCY == 4) ? data_out_dly[2] :
                                   data_out_dly[3];

// ----------------------------------------------------------------
// Implements read-modify-write using data_tmp:
//   Step 1: Read existing word from memory[addr_dly] into data_tmp
//   Step 2: Overwrite only bits where enables_dly[i] is high
//   Step 3: Write data_tmp back to memory[addr_dly]
//
// Blocking assignments are intentional — the three steps have
// strict sequential data dependency within one time step.
// Non-blocking would break the read-modify-write chain.
//
// Gating:
//   chip_select_dly — memory must be selected
//   write_dly       — must be a write operation
//   ~global_reset   — no write during reset
//   ~forcex         — no write during X flood
// ----------------------------------------------------------------
always @ (posedge clk) begin
    if (chip_select_dly & write_dly & ~global_reset & ~forcex)
    begin
        data_tmp = memory[addr_dly];             // Step 1: read current word
        for (i=0; i<COLS; i=i+1)
        begin
            if (enables_dly[i])
                data_tmp[i] = data_in_dly[i];    // Step 2: apply masked bits
        end
        memory[addr_dly] = data_tmp;             // Step 3: write back
    end
end

// ----------------------------------------------------------------
// When forcex is asserted, floods entire memory array with X.
//
// Design intent:
//   Forces X propagation through the read pipeline to expose
//   uninitialized or don't-care memory read behavior in simulation.
//   Any downstream logic reading an uninitialized address will
//   immediately show X — making the bug visible and not hidden
//   behind a false 0 or random value.
//
// Synthesizability:
//   NOT synthesizable — purely a behavioral simulation construct.
//   forcex is permanently tied to 1'b0 above, so synthesis tools
//   will evaluate the condition as always false and optimize away
//   this entire block. It will never appear in gate-level netlist.
// ----------------------------------------------------------------
always @(forcex)
    if (forcex)
    begin
        for (i=0; i<COLS; i=i+1)
        begin
            data_tmp[i] = 1'bx;         // Fill data_tmp with X
        end

        for (i=0; i<ROWS; i=i+1)
        begin
            memory[i] = data_tmp;       // Flood every memory row with X
        end
    end

endmodule

