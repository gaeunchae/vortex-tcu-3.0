// Copyright 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_platform.vh"

// Flat device byte address -> bank-contiguous HBM byte address.
//
// This is the SINGLE SOURCE OF TRUTH for the layout, shared by every master
// that reaches platform memory:
//   * VX_axi_adapter  — the cores' LSU/cache path
//   * VX_cp_axi_remap — the Command Processor's DMA path
// A master that skips it writes to a different physical location than the
// others read, which is silent: no assert, no compile error, just wrong data.
//
// Layout: NUM_PORTS consecutive BLOCK_SIZE blocks round-robin across the
// NUM_PORTS top-level AXI masters, and each master owns BANKS_PER_PORT
// contiguous HBM banks, so master i can be pinned to HBM[i*K : i*K+K-1].
// Let b = block index, then
//   q        = b / NUM_PORTS                (high part)
//   r        = b % NUM_PORTS                (port index)
//   bank_idx = {r, q[LOCAL_BITS-1:0]}       (BANKS_PER_PORT*r + q%BANKS_PER_PORT)
//   row      = q / BANKS_PER_PORT
// For NUM_BANKS=32, NUM_PORTS=8, BLOCK_SIZE=64 the bank visit order is
//   0,4,8,12,16,20,24,28, 1,5,9,13,17,21,25,29, 2,6,..., 3,7,...
//
// ADDR_W must be the PLATFORM memory address width (the size of the HBM
// aperture), NOT the AXI address width: the bank index is packed against the
// top of the aperture, so using a wider AXI width would push the high ports
// past the end of physical memory. Ported from fifusion-vortex@pe-with-int2
// hw/rtl/core/VX_mem_remap.sv; kept in libs/ because VX_axi_adapter uses it.
module VX_mem_remap #(
    parameter ADDR_W     = 34,   // platform memory address width (byte)
    parameter BLOCK_SIZE = 64,
    parameter NUM_BANKS  = 32,
    parameter NUM_PORTS  = 8
) (
    input  wire [ADDR_W-1:0]        dev_addr,   // flat device byte address
    output wire [ADDR_W-1:0]        hbm_addr,   // bank-contiguous byte address
    output wire [`UP(`CLOG2(NUM_PORTS))-1:0] port_sel
);
    localparam int BLOCK_SHIFT    = `CLOG2(BLOCK_SIZE);
    localparam int BANK_BITS      = `CLOG2(NUM_BANKS);
    localparam int BANKS_PER_PORT = NUM_BANKS / NUM_PORTS;
    localparam int PORT_BITS      = `CLOG2(NUM_PORTS);
    localparam int LOCAL_BITS     = `CLOG2(BANKS_PER_PORT);
    localparam int BANK_SHIFT     = ADDR_W - BANK_BITS;

    `STATIC_ASSERT ((NUM_BANKS % NUM_PORTS) == 0, ("VX_mem_remap: NUM_BANKS (%0d) must be a multiple of NUM_PORTS (%0d)", NUM_BANKS, NUM_PORTS))
    `STATIC_ASSERT (BANK_SHIFT > BLOCK_SHIFT, ("VX_mem_remap: aperture %0d bits too small for %0d banks", ADDR_W, NUM_BANKS))

    wire [ADDR_W-1:0] block_idx   = dev_addr >> BLOCK_SHIFT;
    wire [ADDR_W-1:0] byte_offset = dev_addr & ((ADDR_W'(1) << BLOCK_SHIFT) - 1);

    wire [ADDR_W-1:0] q = (PORT_BITS == 0) ? block_idx : (block_idx >> PORT_BITS);

    if (PORT_BITS == 0) begin : g_single_port
        assign port_sel = '0;
    end else begin : g_multi_port
        assign port_sel = block_idx[PORT_BITS-1:0];
    end

    // bank_idx = {port_sel, q[LOCAL_BITS-1:0]}
    wire [BANK_BITS-1:0] bank_idx;
    if (LOCAL_BITS == 0) begin : g_no_local
        assign bank_idx = BANK_BITS'(port_sel);
    end else begin : g_local
        assign bank_idx = (BANK_BITS'(port_sel) << LOCAL_BITS)
                        | BANK_BITS'(q[LOCAL_BITS-1:0]);
    end

    wire [ADDR_W-1:0] bank_offset = (q >> LOCAL_BITS) << BLOCK_SHIFT;

    assign hbm_addr = (ADDR_W'(bank_idx) << BANK_SHIFT)
                    | bank_offset
                    | byte_offset;

endmodule
