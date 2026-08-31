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

// Burst-splitting, address-remapping 1:N AXI demux for the Command Processor's
// device-memory master.
//
// WHY THIS EXISTS
//   The cores reach platform memory through VX_axi_adapter, which applies
//   VX_mem_remap so master i owns HBM[i*K : i*K+K-1]. VX_cp_core has its own
//   AXI master and used to be arb'd straight onto m_axi_mem_0 with UNREMAPPED
//   addresses. That is only correct for the flat layout, where the adapter
//   re-inserts the bank index at bit LOG2(BLOCK_SIZE) and the emitted address
//   is the identity of the device address. Under the bank-contiguous layout the
//   CP would write the kernel and the source buffers at identity addresses
//   while the cores read them at the remapped ones -- agreeing only for bank 0.
//   This module puts the CP on the same layout, and routes each beat to the
//   master that owns its bank.
//
//   The reference design (fifusion-vortex@pe-with-int2) solves the same problem
//   by giving its DMA one AXI master per HBM port and remapping inside the DMA
//   engine; its descriptors keep each burst inside one bank. tcu-3.0's CP DMA
//   is a linear memcpy engine with a single master, so the split has to happen
//   here instead.
//
// HOW
//   One AXI beat is DATA_WIDTH/8 bytes, which equals the platform block size,
//   so every beat maps to exactly one bank and therefore one master -- no
//   intra-beat splitting is ever needed. An N-beat input burst becomes N
//   single-beat bursts spread over the masters. This is the same transaction
//   shape VX_axi_adapter already emits for the cores (awlen/arlen = 0).
//
//   Reads keep a FIFO of the issue order so R beats are returned upstream in
//   order with rlast on the last one. Writes drive AW+W per beat and emit one
//   upstream B once every sub-B has drained. One input burst is handled at a
//   time per direction, which is all VX_cp_dma ever has outstanding.
//
//   PORT_BANKS == 0 (flat layout) makes this a pure passthrough to port 0, so
//   the pre-existing behaviour is bit-identical. The condition is PORT_BANKS
//   ALONE, never NUM_PORTS: with one master but PORT_BANKS > 1 the adapter
//   still remaps (bank index packed against the aperture top), so bypassing
//   here would reintroduce exactly the CP/core disagreement this module fixes.
module VX_cp_axi_remap #(
    parameter ADDR_WIDTH      = 48,   // AXI address width, offset-relative
    parameter DATA_WIDTH      = 512,
    parameter ID_WIDTH        = 32,
    parameter NUM_PORTS       = 1,
    parameter PORT_BANKS      = 0,    // HBM banks per master; 0 = flat/bypass
    parameter PORT_ADDR_WIDTH = 34,   // HBM aperture width
    parameter MAX_BURST       = 64    // max beats per input burst
) (
    // The bypass configuration (PORT_BANKS==0) has no sequential logic.
    /* verilator lint_off UNUSEDSIGNAL */
    input wire clk,
    input wire reset,
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- slave: the CP's device master ----
    input  wire                     s_awvalid,
    output wire                     s_awready,
    input  wire [ADDR_WIDTH-1:0]    s_awaddr,
    input  wire [ID_WIDTH-1:0]      s_awid,
    input  wire [7:0]               s_awlen,

    input  wire                     s_wvalid,
    output wire                     s_wready,
    input  wire [DATA_WIDTH-1:0]    s_wdata,
    input  wire [DATA_WIDTH/8-1:0]  s_wstrb,
    /* verilator lint_off UNUSEDSIGNAL */ // split path derives wlast per beat
    input  wire                     s_wlast,
    /* verilator lint_on UNUSEDSIGNAL */

    output wire                     s_bvalid,
    input  wire                     s_bready,
    output wire [ID_WIDTH-1:0]      s_bid,
    output wire [1:0]               s_bresp,

    input  wire                     s_arvalid,
    output wire                     s_arready,
    input  wire [ADDR_WIDTH-1:0]    s_araddr,
    input  wire [ID_WIDTH-1:0]      s_arid,
    input  wire [7:0]               s_arlen,

    output wire                     s_rvalid,
    input  wire                     s_rready,
    output wire [DATA_WIDTH-1:0]    s_rdata,
    output wire                     s_rlast,
    output wire [ID_WIDTH-1:0]      s_rid,
    output wire [1:0]               s_rresp,

    // ---- masters: one per HBM port ----
    output wire                     m_awvalid [NUM_PORTS],
    input  wire                     m_awready [NUM_PORTS],
    output wire [ADDR_WIDTH-1:0]    m_awaddr  [NUM_PORTS],
    output wire [ID_WIDTH-1:0]      m_awid    [NUM_PORTS],
    output wire [7:0]               m_awlen   [NUM_PORTS],

    output wire                     m_wvalid  [NUM_PORTS],
    input  wire                     m_wready  [NUM_PORTS],
    output wire [DATA_WIDTH-1:0]    m_wdata   [NUM_PORTS],
    output wire [DATA_WIDTH/8-1:0]  m_wstrb   [NUM_PORTS],
    output wire                     m_wlast   [NUM_PORTS],

    input  wire                     m_bvalid  [NUM_PORTS],
    output wire                     m_bready  [NUM_PORTS],
    /* verilator lint_off UNUSEDSIGNAL */ // split path counts Bs, ids unused
    input  wire [ID_WIDTH-1:0]      m_bid     [NUM_PORTS],
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [1:0]               m_bresp   [NUM_PORTS],

    output wire                     m_arvalid [NUM_PORTS],
    input  wire                     m_arready [NUM_PORTS],
    output wire [ADDR_WIDTH-1:0]    m_araddr  [NUM_PORTS],
    output wire [ID_WIDTH-1:0]      m_arid    [NUM_PORTS],
    output wire [7:0]               m_arlen   [NUM_PORTS],

    input  wire                     m_rvalid  [NUM_PORTS],
    output wire                     m_rready  [NUM_PORTS],
    input  wire [DATA_WIDTH-1:0]    m_rdata   [NUM_PORTS],
    /* verilator lint_off UNUSEDSIGNAL */ // every sub-burst is a single beat
    input  wire                     m_rlast   [NUM_PORTS],
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_off UNUSEDSIGNAL */ // split path replays the latched arid
    input  wire [ID_WIDTH-1:0]      m_rid     [NUM_PORTS],
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [1:0]               m_rresp   [NUM_PORTS]
);
    localparam int BEAT_BYTES = DATA_WIDTH / 8;
    localparam int BEAT_SHIFT = `CLOG2(BEAT_BYTES);
    localparam int PORT_BITS  = `CLOG2(NUM_PORTS);
    localparam int PORT_SEL_W = `UP(PORT_BITS);
    localparam int BEAT_W     = 9;                  // awlen is 8 bits => <=256

    `STATIC_ASSERT ((PORT_BANKS == 0) || (PORT_ADDR_WIDTH <= ADDR_WIDTH), ("HBM aperture %0d wider than the CP AXI address port %0d", PORT_ADDR_WIDTH, ADDR_WIDTH))

if (PORT_BANKS == 0) begin : g_bypass

    // Flat layout: the adapter emits identity addresses and every master sees
    // the whole aperture, so the CP needs no remap and no split.
    assign m_awvalid[0] = s_awvalid;
    assign m_awaddr[0]  = s_awaddr;
    assign m_awid[0]    = s_awid;
    assign m_awlen[0]   = s_awlen;
    assign s_awready    = m_awready[0];

    assign m_wvalid[0]  = s_wvalid;
    assign m_wdata[0]   = s_wdata;
    assign m_wstrb[0]   = s_wstrb;
    assign m_wlast[0]   = s_wlast;
    assign s_wready     = m_wready[0];

    assign s_bvalid     = m_bvalid[0];
    assign s_bid        = m_bid[0];
    assign s_bresp      = m_bresp[0];
    assign m_bready[0]  = s_bready;

    assign m_arvalid[0] = s_arvalid;
    assign m_araddr[0]  = s_araddr;
    assign m_arid[0]    = s_arid;
    assign m_arlen[0]   = s_arlen;
    assign s_arready    = m_arready[0];

    assign s_rvalid     = m_rvalid[0];
    assign s_rdata      = m_rdata[0];
    assign s_rlast      = m_rlast[0];
    assign s_rid        = m_rid[0];
    assign s_rresp      = m_rresp[0];
    assign m_rready[0]  = s_rready;

    for (genvar i = 1; i < NUM_PORTS; ++i) begin : g_tie
        assign m_awvalid[i] = 1'b0;
        assign m_awaddr[i]  = '0;
        assign m_awid[i]    = '0;
        assign m_awlen[i]   = '0;
        assign m_wvalid[i]  = 1'b0;
        assign m_wdata[i]   = '0;
        assign m_wstrb[i]   = '0;
        assign m_wlast[i]   = 1'b0;
        assign m_bready[i]  = 1'b0;
        assign m_arvalid[i] = 1'b0;
        assign m_araddr[i]  = '0;
        assign m_arid[i]    = '0;
        assign m_arlen[i]   = '0;
        assign m_rready[i]  = 1'b0;
        `UNUSED_VAR (m_awready[i])
        `UNUSED_VAR (m_wready[i])
        `UNUSED_VAR (m_bvalid[i])
        `UNUSED_VAR (m_bresp[i])
        `UNUSED_VAR (m_arready[i])
        `UNUSED_VAR (m_rvalid[i])
        `UNUSED_VAR (m_rdata[i])
        `UNUSED_VAR (m_rresp[i])
    end

end else begin : g_split

    // ---- inputs gathered into packed vectors first (VCS forbids using a
    // ---- signal before its declaration; see the CP AXI ID bug this tree
    // ---- already had in VX_afu_wrap).
    wire [NUM_PORTS-1:0] b_valid_v;
    for (genvar i = 0; i < NUM_PORTS; ++i) begin : g_bvalid
        assign b_valid_v[i] = m_bvalid[i];
    end

    // Lowest-index master with a pending B response. One B per cycle is plenty:
    // they are only counted, never forwarded beat-by-beat.
    logic [PORT_SEL_W-1:0] b_port_c;
    logic                  b_any_c;
    always @(*) begin
        b_port_c = '0;
        b_any_c  = 1'b0;
        for (int unsigned i = NUM_PORTS; i > 0; --i) begin
            if (b_valid_v[i-1]) begin
                b_port_c = PORT_SEL_W'(i-1);
                b_any_c  = 1'b1;
            end
        end
    end
    wire [PORT_SEL_W-1:0] b_port = b_port_c;
    wire                  b_any  = b_any_c;

    // ================= write path =================
    localparam W_IDLE = 2'd0, W_XFER = 2'd1, W_DRAIN = 2'd2;

    reg [1:0]              wstate;
    reg [ADDR_WIDTH-1:0]   w_base;
    reg [ID_WIDTH-1:0]     w_id;
    reg [7:0]              w_len;
    reg [BEAT_W-1:0]       w_beat;
    reg [BEAT_W-1:0]       w_bpend;
    reg                    aw_done_r, w_done_r;
    reg [1:0]              w_resp_r;

    wire [ADDR_WIDTH-1:0]      w_dev_addr = w_base + (ADDR_WIDTH'(w_beat) << BEAT_SHIFT);
    wire [PORT_ADDR_WIDTH-1:0] w_hbm_addr;
    wire [PORT_SEL_W-1:0]      w_port;

    // Address bits above the HBM aperture are dropped by the remap, which
    // would silently land the access on another bank's data.
    if (ADDR_WIDTH > PORT_ADDR_WIDTH) begin : g_w_aperture
        /* verilator lint_off UNUSEDSIGNAL */
        wire [ADDR_WIDTH-PORT_ADDR_WIDTH-1:0] w_addr_hi = w_dev_addr[ADDR_WIDTH-1:PORT_ADDR_WIDTH];
        /* verilator lint_on UNUSEDSIGNAL */
        `RUNTIME_ASSERT ((wstate != W_XFER) || (w_addr_hi == 0), ("%t: *** VX_cp_axi_remap: CP address 0x%0h past the %0d-bit HBM aperture", $time, w_dev_addr, PORT_ADDR_WIDTH))
    end

    VX_mem_remap #(
        .ADDR_W     (PORT_ADDR_WIDTH),
        .BLOCK_SIZE (BEAT_BYTES),
        .NUM_BANKS  (NUM_PORTS * PORT_BANKS),
        .NUM_PORTS  (NUM_PORTS)
    ) wr_remap (
        .dev_addr (PORT_ADDR_WIDTH'(w_dev_addr)),
        .hbm_addr (w_hbm_addr),
        .port_sel (w_port)
    );

    wire w_active = (wstate == W_XFER);
    wire aw_fire  = w_active && s_wvalid && ~aw_done_r && m_awready[w_port];
    wire w_fire   = w_active && s_wvalid && ~w_done_r  && m_wready[w_port];
    // The beat retires only once BOTH AW and W have handshaken; until then the
    // CP holds the data because s_wready stays low.
    wire w_beat_done = w_active && s_wvalid
                    && (aw_done_r || m_awready[w_port])
                    && (w_done_r  || m_wready[w_port]);

    wire b_fire = b_any && (w_bpend != 0);

    always @(posedge clk) begin
        if (reset) begin
            wstate    <= W_IDLE;
            w_beat    <= '0;
            w_bpend   <= '0;
            aw_done_r <= 1'b0;
            w_done_r  <= 1'b0;
            w_resp_r  <= 2'b00;
            w_base    <= '0;
            w_id      <= '0;
            w_len     <= '0;
        end else begin
            if (b_fire) begin
                w_resp_r <= w_resp_r | m_bresp[b_port];
            end
            case (wstate)
            W_IDLE: begin
                if (s_awvalid) begin
                    w_base    <= s_awaddr;
                    w_id      <= s_awid;
                    w_len     <= s_awlen;
                    w_beat    <= '0;
                    w_bpend   <= '0;
                    aw_done_r <= 1'b0;
                    w_done_r  <= 1'b0;
                    w_resp_r  <= 2'b00;
                    wstate    <= W_XFER;
                end
            end
            W_XFER: begin
                if (w_beat_done) begin
                    aw_done_r <= 1'b0;
                    w_done_r  <= 1'b0;
                    w_beat    <= w_beat + BEAT_W'(1);
                    if (w_beat == BEAT_W'(w_len)) begin
                        wstate <= W_DRAIN;
                    end
                end else begin
                    if (aw_fire) aw_done_r <= 1'b1;
                    if (w_fire)  w_done_r  <= 1'b1;
                end
                w_bpend <= w_bpend + (aw_fire ? BEAT_W'(1) : BEAT_W'(0))
                                   - (b_fire  ? BEAT_W'(1) : BEAT_W'(0));
            end
            default: begin // W_DRAIN
                w_bpend <= w_bpend - (b_fire ? BEAT_W'(1) : BEAT_W'(0));
                if ((w_bpend == 0) && s_bready) begin
                    wstate <= W_IDLE;
                end
            end
            endcase
        end
    end

    assign s_awready = (wstate == W_IDLE);
    assign s_wready  = w_beat_done;
    assign s_bvalid  = (wstate == W_DRAIN) && (w_bpend == 0);
    assign s_bid     = w_id;
    assign s_bresp   = w_resp_r;

    // ================= read path =================
    localparam R_IDLE = 2'd0, R_ISSUE = 2'd1, R_DRAIN = 2'd2;
    localparam int ORD_IDX_W = `CLOG2(MAX_BURST);

    reg [1:0]            rstate;
    reg [ADDR_WIDTH-1:0] r_base;
    reg [ID_WIDTH-1:0]   r_id;
    reg [7:0]            r_len;
    reg [BEAT_W-1:0]     r_issue;
    reg [BEAT_W-1:0]     r_rsp;

    // Issue-order FIFO: which master each pending R beat must come from, so
    // beats are returned upstream in order with rlast on the last one.
    reg [PORT_SEL_W-1:0] ord_q [MAX_BURST];
    reg [BEAT_W-1:0]     ord_wr, ord_rd;
    wire                 ord_empty = (ord_wr == ord_rd);
    wire [PORT_SEL_W-1:0] ord_head = ord_q[ord_rd[ORD_IDX_W-1:0]];

    wire [ADDR_WIDTH-1:0]      r_dev_addr = r_base + (ADDR_WIDTH'(r_issue) << BEAT_SHIFT);
    wire [PORT_ADDR_WIDTH-1:0] r_hbm_addr;
    wire [PORT_SEL_W-1:0]      r_port;

    // Address bits above the HBM aperture are dropped by the remap, which
    // would silently land the access on another bank's data.
    if (ADDR_WIDTH > PORT_ADDR_WIDTH) begin : g_r_aperture
        /* verilator lint_off UNUSEDSIGNAL */
        wire [ADDR_WIDTH-PORT_ADDR_WIDTH-1:0] r_addr_hi = r_dev_addr[ADDR_WIDTH-1:PORT_ADDR_WIDTH];
        /* verilator lint_on UNUSEDSIGNAL */
        `RUNTIME_ASSERT ((rstate != R_ISSUE) || (r_addr_hi == 0), ("%t: *** VX_cp_axi_remap: CP address 0x%0h past the %0d-bit HBM aperture", $time, r_dev_addr, PORT_ADDR_WIDTH))
    end

    VX_mem_remap #(
        .ADDR_W     (PORT_ADDR_WIDTH),
        .BLOCK_SIZE (BEAT_BYTES),
        .NUM_BANKS  (NUM_PORTS * PORT_BANKS),
        .NUM_PORTS  (NUM_PORTS)
    ) rd_remap (
        .dev_addr (PORT_ADDR_WIDTH'(r_dev_addr)),
        .hbm_addr (r_hbm_addr),
        .port_sel (r_port)
    );

    wire ar_issue = (rstate == R_ISSUE);
    wire ar_fire  = ar_issue && m_arready[r_port];
    // Responses drain in R_ISSUE too: a master whose R queue is full would
    // otherwise hold arready low forever and deadlock the issue loop.
    wire r_fire   = s_rvalid && s_rready;

    always @(posedge clk) begin
        if (reset) begin
            rstate  <= R_IDLE;
            r_issue <= '0;
            r_rsp   <= '0;
            ord_wr  <= '0;
            ord_rd  <= '0;
            r_base  <= '0;
            r_id    <= '0;
            r_len   <= '0;
        end else begin
            if (ar_fire) begin
                ord_q[ord_wr[ORD_IDX_W-1:0]] <= r_port;
                ord_wr  <= ord_wr + BEAT_W'(1);
                r_issue <= r_issue + BEAT_W'(1);
            end
            if (r_fire) begin
                ord_rd <= ord_rd + BEAT_W'(1);
                r_rsp  <= r_rsp + BEAT_W'(1);
            end
            case (rstate)
            R_IDLE: begin
                if (s_arvalid) begin
                    r_base  <= s_araddr;
                    r_id    <= s_arid;
                    r_len   <= s_arlen;
                    r_issue <= '0;
                    r_rsp   <= '0;
                    rstate  <= R_ISSUE;
                end
            end
            R_ISSUE: begin
                if (ar_fire && (r_issue == BEAT_W'(r_len))) begin
                    rstate <= R_DRAIN;
                end
            end
            default: begin // R_DRAIN
                if (r_fire && (r_rsp == BEAT_W'(r_len))) begin
                    rstate <= R_IDLE;
                end
            end
            endcase
        end
    end

    assign s_arready = (rstate == R_IDLE);
    assign s_rvalid  = ~ord_empty && m_rvalid[ord_head];
    assign s_rdata   = m_rdata[ord_head];
    assign s_rresp   = m_rresp[ord_head];
    assign s_rid     = r_id;
    assign s_rlast   = (r_rsp == BEAT_W'(r_len));

    // ================= per-port output fanout =================
    for (genvar i = 0; i < NUM_PORTS; ++i) begin : g_port
        assign m_awvalid[i] = w_active && s_wvalid && ~aw_done_r && (w_port == PORT_SEL_W'(i));
        assign m_awaddr[i]  = ADDR_WIDTH'(w_hbm_addr);
        assign m_awid[i]    = w_id;
        assign m_awlen[i]   = 8'd0;

        assign m_wvalid[i]  = w_active && s_wvalid && ~w_done_r && (w_port == PORT_SEL_W'(i));
        assign m_wdata[i]   = s_wdata;
        assign m_wstrb[i]   = s_wstrb;
        assign m_wlast[i]   = 1'b1;

        assign m_bready[i]  = (w_bpend != 0) && (b_port == PORT_SEL_W'(i));

        assign m_arvalid[i] = ar_issue && (r_port == PORT_SEL_W'(i));
        assign m_araddr[i]  = ADDR_WIDTH'(r_hbm_addr);
        assign m_arid[i]    = r_id;
        assign m_arlen[i]   = 8'd0;

        assign m_rready[i]  = ~ord_empty && (ord_head == PORT_SEL_W'(i)) && s_rready;

    end

    `RUNTIME_ASSERT (~s_awvalid || (s_awlen < MAX_BURST), ("%t: *** VX_cp_axi_remap: write burst of %0d beats exceeds MAX_BURST=%0d", $time, s_awlen + 1, MAX_BURST))
    `RUNTIME_ASSERT (~s_arvalid || (s_arlen < MAX_BURST), ("%t: *** VX_cp_axi_remap: read burst of %0d beats exceeds MAX_BURST=%0d", $time, s_arlen + 1, MAX_BURST))

end

endmodule
