Complete the implementation in sources/sram.sv

Add Hamming SECDED (Single-Error Correct, Double-Error Detect) ECC engine into an existing parameterized synchronous SRAM behavioral model. Please follow the instruction to implement this block.
1) For COLS data bits, the number of Hamming parity bits P satisfies by this formula "2^P  >=  COLS + P + 1"
2) Parity Bit Coverage Rule:
Each parity bit Pi covers all bit positions in the codeword where bit i of the position number equals 1:
P_overall: XOR of ALL bits including all parity bits (SECDED extra bit)
3) Syndrome Decoding Table
syndrome[4:0]  overall_parity[5]   Meaning
─────────────────────────────────────────────────────
00000          0                   No error
00000          1                   Overall parity bit flipped — no data fix needed
Non-zero       1                   Single-bit error — syndrome = exact bit position
Non-zero       0                   Double-bit error — uncorrectable, flag fatal

Memory Array Change — Required First Step
Before implementing any ECC logic, the memory array declaration must be widened to store parity bits alongside data.
reg [COLS+`ECC_BITS-1:0]    memory[ROWS-1:0];

Description of each block for ECC logic.
Block 1 — ECC Write Parity Computation (Combinatorial)
Coding Rules:
Use always @(*) with a named block label ecc_write_parity
Declare a local integer b for the loop — do not use module-level i or j
Implementation Step by Step:
Step 1: Initialize wr_parity to zero
Step 2: Loop over all COLS data bits. For each bit b, check which parity bits it contributes to using the coverage rule — if bit i of position (b+1) is 1, XOR data_in_dly[b] into wr_parity[i]
Step 3: Compute the overall SECDED parity bit — XOR of all data bits and all Hamming parity bits computed so far

8. Block 2 — ECC Read Syndrome Computation and Correction (Combinatorial)
Use always @(*) with a named block label ecc_read_correct
Declare a local integer b — do not reuse module-level i or j
Gate entire block with if (ECC_EN)
Blocking assignments throughout
Implementation Step by Step:
Step 1: Extract raw data and stored parity from memory word
Step 2: Initialize all working registers:
Step 3: Recompute syndrome parity bits [4:0] over rd_data_raw using identical coverage rule as write path
Step 4: XOR recomputed parity against stored parity to produce syndrome
Step 5: Compute overall parity check bit — XOR of raw data, stored Hamming parity, and stored overall parity
Step 6: Decode the syndrome and act

Block 3 — ECC Error Registration (Sequential)
Coding Rules:
Trigger on posedge clk_inst or posedge global_reset
Active-high asynchronous reset — clears all error flags and address
Only sample error signals during an active read cycle: chip_select_dly & ~write_dly
Outside of read cycles, clear error flags — do not hold them
Use non-blocking assignments throughout
Update Write Path — Store Parity with Data. The existing write always block must be updated to store {wr_parity, data_tmp} instead of just data_tmp
Update Stage 1 Read Pipeline — Use Corrected Data
The Stage 1 read pipeline register must use data_outi_corrected instead of raw data_outi

The design has a missing write mask expansion block — the enables_expand register is declared but never driven, meaning all write mask logic is completely absent from the design. What already exists in the code — do not modify or redeclare.
A single combinatorial always block sensitive to write_mask that expands the incoming WR_MASK_WIDTH-bit mask into a full COLS-bit per-bit enable vector stored in enables_expand. This block must handle four distinct mask granularity modes selected by the WR_MASK_TYPE parameter.
WR_MASK_TYPE : 0 Mask: No mask Required Logic: Force all bits of enables_expand to 1 — every bit is always writable regardless of write_mask
WR_MASK_TYPE : 1 Mask: Bit-wise Required Logic: Assign write_mask directly to enables_expand — one mask bit controls one data bit
WR_MASK_TYPE : 8 Mask: Byte-wise Required Logic: Each mask bit controls 8 consecutive data bits — replicate each write_mask[i] across 8 bits and shift into the correct byte position using i << 3 
WR_MASK_TYPE : default Mask: N-bit granularity Required Logic: Each mask bit controls WR_MASK_TYPE consecutive data bits — use a nested loop over WR_MASK_WIDTH and WR_MASK_TYPE to OR each mask bit into its correct bit positions 
use only i and j integers already declared

The design has a missing Stage 1 read pipeline register logic — the data_out_int register is declared and exists in the pipeline chain but its conditional assignment logic is completely absent, meaning the first pipeline stage is never driven.
Macro `POR_MEM_DELAY — already defined, must be used on every assignment to data_out_int.
A single clocked always block triggered on posedge clk_inst that conditionally drives data_out_int based on whether the current operation is a write or anything else.

The following sequential block is missing from a parameterized synchronous SRAM behavioral model. Implement it.

 **Block:** `always @ (posedge clk_inst or posedge global_reset)`

 **Reset branch** — active high async reset, clear:
 - `wren_dly[3:0]` → `1'b0`
 - `rden_dly[3:0]` → `1'b0`
 - `chip_select_hold` → `1'b0`
 - `data_out_dly[3:0]` → `{COLS{1'bx}}` — X not 0, consistent with pipeline X injection policy

 **Else branch** — shift register chaining on `clk_inst`:
 - `wren_dly` : shift `wren` through `[0]→[1]→[2]→[3]`
 - `rden_dly` : shift `rden` through `[0]→[1]→[2]→[3]`
 - `chip_select_hold` : sample `chip_select`
 - `data_out_dly` : shift `data_out_int` through `[0]→[1]→[2]→[3]`

 **Constraints:**
 - Non-blocking assignments throughout
 - `data_out_dly` feeds the parameterized `LATENCY` output tap — order of shifting is critical
 - All signals already declared — do not redeclare anything

The design has a missing the final output assignment. A single continuous assignment that connects final output to the correct pipeline stage tap based on the value of LATENCY. 

Impliment Reconstruct the Write Path Always Block

Trigger on the correct clock edge — identify which of the two clocks owns the write path
Gate the entire write operation using all four conditions: chip_select_dly, write_dly, ~global_reset, ~forcex — all must be true simultaneously

Implement a read-modify-write sequence in this exact order using data_tmp as the intermediate register:
Step 1: Read the current word from memory[addr_dly][COLS-1:0] into data_tmp
Step 2: Loop over every bit position from 0 to COLS — use the parameter, not a hardcoded value — and update data_tmp[i] with data_in_dly[i] only if enables_dly[i] is high
Step 3: Write data_tmp back into memory[addr_dly] with freshly computed ECC parity
