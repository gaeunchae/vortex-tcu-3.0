// Copyright © 2019-2023
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

// VCS co-simulation testbench — synthesizable-style rewrite.
//
// Architecture:
//   - AXI signals are driven by always_ff @(posedge) blocks with NBA (<=).
//   - DPI calls live in a single initial @(negedge) block that pushes queues
//     and consumes fire/ack flags — the only non-synthesizable part.
//   - AXI memory slave uses generate-for to avoid VCS automatic variable issues.
//   - Ready signals are combinational (assign) based on queue depth + stall.

`timescale 1ns/1ps

`include "vortex_afu.vh"

// Top-level AXI memory masters on the AFU, mirroring VX_afu_wrap.
`ifdef PLATFORM_MERGED_MEMORY_INTERFACE
`define TB_AXI_MEM_PORTS `PLATFORM_MEMORY_MERGED_PORTS
`else
`define TB_AXI_MEM_PORTS `VX_CFG_PLATFORM_MEMORY_NUM_BANKS
`endif

module tb_vcs_xrtsim #(
  parameter C_S_AXI_CTRL_ADDR_WIDTH = 16,
  parameter C_S_AXI_CTRL_DATA_WIDTH = 32,
  parameter C_M_AXI_MEM_ID_WIDTH    = `PLATFORM_MEMORY_ID_WIDTH,
  parameter C_M_AXI_MEM_DATA_WIDTH  = (`VX_CFG_PLATFORM_MEMORY_DATA_SIZE * 8),
  parameter C_M_AXI_MEM_ADDR_WIDTH  = 64,
  parameter C_M_AXI_MEM_NUM_PORTS   = `TB_AXI_MEM_PORTS
);

  localparam int CLK_HALF_PERIOD_NS = 5;
  localparam int DATA_SIZE = `VX_CFG_PLATFORM_MEMORY_DATA_SIZE;
  localparam int NUM_MEM_PORTS = `TB_AXI_MEM_PORTS;
  // The CP's host-memory master rides the same slave logic as the memory
  // masters, in one extra slot. xrt_sim_vcs routes that port to host RAM.
  localparam int HOST_PORT     = NUM_MEM_PORTS;
  localparam int NUM_PORTS     = NUM_MEM_PORTS + 1;

  // Response queue depth limit for backpressure
  localparam int RSP_QUEUE_LIMIT = 16;

  // Packet type constants (must match vcs_protocol.h)
  // Per-access AXI-Lite logging is unbounded: the host polls a status register
  // while the kernel runs, so a hanging test writes lines forever. This filled
  // a 33 GB simv.log before the blackbox log cap existed. Off unless +TB_VERBOSE.
  bit tb_verbose = 0;

  localparam int CMD_REG_WRITE = 8'h01;
  localparam int CMD_REG_READ  = 8'h03;
  localparam int CMD_SHUTDOWN  = 8'h05;
  localparam int RSP_AXI_R    = 8'h20;
  localparam int RSP_AXI_B    = 8'h21;

  // AXI-Lite ctrl FSM states
  localparam int CTRL_IDLE     = 0;
  localparam int CTRL_AW_PHASE = 1;
  localparam int CTRL_W_PHASE  = 2;
  localparam int CTRL_B_PHASE  = 3;
  localparam int CTRL_AR_PHASE = 4;
  localparam int CTRL_R_PHASE  = 5;

  // ---- DPI imports ----
  import "DPI-C" function int socket_server_init(int ctrl_port, int mem_port);
  import "DPI-C" function int socket_server_accept();
  import "DPI-C" function int ctrl_has_command();
  import "DPI-C" function int ctrl_recv_command(output int cmd_type, output int offset, output int value);
  import "DPI-C" function int ctrl_send_ack();
  import "DPI-C" function int ctrl_send_reg_value(int value);
  import "DPI-C" function int mem_send_axi_ar(int port, longint addr, int id, int len);
  import "DPI-C" function int mem_send_axi_aw(int port, longint addr, int id, int len);
  import "DPI-C" function int mem_send_axi_w(input int port, input byte unsigned data_bytes[], input longint strb, input int last, input int data_size);
  import "DPI-C" function int mem_has_response();
  import "DPI-C" function int mem_recv_response(output int rsp_type, output int port, output int id, output byte unsigned data_bytes[], output int last, input int data_size);
  import "DPI-C" function void socket_server_close();

  // ---- Clock & Reset ----
  logic ap_clk;
  logic ap_rst_n;
  always #(CLK_HALF_PERIOD_NS) ap_clk = ~ap_clk;

  // ---- AXI Memory signals (per-port) ----
  logic         m_axi_mem_awvalid [NUM_PORTS];
  logic         m_axi_mem_awready [NUM_PORTS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0]  m_axi_mem_awaddr [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_awid   [NUM_PORTS];
  logic [7:0]   m_axi_mem_awlen   [NUM_PORTS];
  logic         m_axi_mem_wvalid  [NUM_PORTS];
  logic         m_axi_mem_wready  [NUM_PORTS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0]  m_axi_mem_wdata  [NUM_PORTS];
  logic [C_M_AXI_MEM_DATA_WIDTH/8-1:0] m_axi_mem_wstrb [NUM_PORTS];
  logic         m_axi_mem_wlast   [NUM_PORTS];
  logic         m_axi_mem_arvalid [NUM_PORTS];
  logic         m_axi_mem_arready [NUM_PORTS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0]  m_axi_mem_araddr [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_arid   [NUM_PORTS];
  logic [7:0]   m_axi_mem_arlen   [NUM_PORTS];
  logic         m_axi_mem_rvalid  [NUM_PORTS];
  logic         m_axi_mem_rready  [NUM_PORTS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0]  m_axi_mem_rdata  [NUM_PORTS];
  logic         m_axi_mem_rlast   [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_rid    [NUM_PORTS];
  logic [1:0]   m_axi_mem_rresp   [NUM_PORTS];
  logic         m_axi_mem_bvalid  [NUM_PORTS];
  logic         m_axi_mem_bready  [NUM_PORTS];
  logic [1:0]   m_axi_mem_bresp   [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]    m_axi_mem_bid    [NUM_PORTS];

  // ---- AXI-Lite Ctrl signals ----
  logic         s_axi_ctrl_awvalid;
  logic         s_axi_ctrl_awready;
  logic [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_awaddr;
  logic         s_axi_ctrl_wvalid;
  logic         s_axi_ctrl_wready;
  logic [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_ctrl_wdata;
  logic [C_S_AXI_CTRL_DATA_WIDTH/8-1:0] s_axi_ctrl_wstrb;
  logic         s_axi_ctrl_arvalid;
  logic         s_axi_ctrl_arready;
  logic [C_S_AXI_CTRL_ADDR_WIDTH-1:0] s_axi_ctrl_araddr;
  logic         s_axi_ctrl_rvalid;
  logic         s_axi_ctrl_rready;
  logic [C_S_AXI_CTRL_DATA_WIDTH-1:0] s_axi_ctrl_rdata;
  logic [1:0]   s_axi_ctrl_rresp;
  logic         s_axi_ctrl_bvalid;
  logic         s_axi_ctrl_bready;
  logic [1:0]   s_axi_ctrl_bresp;
  logic         interrupt;

  // ---- Response queue entry types ----
  typedef struct {
    logic [C_M_AXI_MEM_ID_WIDTH-1:0]   id;
    logic [C_M_AXI_MEM_DATA_WIDTH-1:0] data;
    logic                               last;
  } r_rsp_t;

  typedef struct {
    logic [C_M_AXI_MEM_ID_WIDTH-1:0] id;
  } b_rsp_t;

  // Per-port response queues (initial pushes, always_ff pops)
  r_rsp_t r_queue[NUM_PORTS][$];
  b_rsp_t b_queue[NUM_PORTS][$];

  // ---- Ctrl command queue entry ----
  typedef struct {
    int cmd_type;
    int offset;
    int value;
  } ctrl_cmd_t;

  ctrl_cmd_t ctrl_cmd_queue[$];

  // ---- DRAM stall Markov model ----
  int dram_req_stall_p_enter;
  int dram_req_stall_p_exit;
  int dram_rsp_stall_p_enter;
  int dram_rsp_stall_p_exit;
  bit req_stalling [NUM_PORTS];
  bit rsp_stalling [NUM_PORTS];

  // ---- Fire flags: set by always_ff (<=), cleared by initial (=) ----
  bit ar_fire_flag [NUM_PORTS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0] ar_fire_addr [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]   ar_fire_id   [NUM_PORTS];
  logic [7:0]                         ar_fire_len  [NUM_PORTS];

  bit aw_fire_flag [NUM_PORTS];
  logic [C_M_AXI_MEM_ADDR_WIDTH-1:0] aw_fire_addr [NUM_PORTS];
  logic [C_M_AXI_MEM_ID_WIDTH-1:0]   aw_fire_id   [NUM_PORTS];
  logic [7:0]                         aw_fire_len  [NUM_PORTS];

  bit w_fire_flag [NUM_PORTS];
  logic [C_M_AXI_MEM_DATA_WIDTH-1:0]   w_fire_data [NUM_PORTS];
  logic [C_M_AXI_MEM_DATA_WIDTH/8-1:0] w_fire_strb [NUM_PORTS];
  logic                                 w_fire_last [NUM_PORTS];

  // ---- Ctrl ack/read_rsp flags: set by always_ff (<=), cleared by initial (=) ----
  bit ctrl_ack_pending;
  bit ctrl_read_rsp_pending;
  int ctrl_read_rsp_value;

  // ---- DUT port connection macro ----
`define TB_AXI_MEM_CONNECT(i) \
    .m_axi_mem_``i``_awvalid(m_axi_mem_awvalid[i]), \
    .m_axi_mem_``i``_awready(m_axi_mem_awready[i]), \
    .m_axi_mem_``i``_awaddr(m_axi_mem_awaddr[i]), \
    .m_axi_mem_``i``_awid(m_axi_mem_awid[i]), \
    .m_axi_mem_``i``_awlen(m_axi_mem_awlen[i]), \
    .m_axi_mem_``i``_wvalid(m_axi_mem_wvalid[i]), \
    .m_axi_mem_``i``_wready(m_axi_mem_wready[i]), \
    .m_axi_mem_``i``_wdata(m_axi_mem_wdata[i]), \
    .m_axi_mem_``i``_wstrb(m_axi_mem_wstrb[i]), \
    .m_axi_mem_``i``_wlast(m_axi_mem_wlast[i]), \
    .m_axi_mem_``i``_arvalid(m_axi_mem_arvalid[i]), \
    .m_axi_mem_``i``_arready(m_axi_mem_arready[i]), \
    .m_axi_mem_``i``_araddr(m_axi_mem_araddr[i]), \
    .m_axi_mem_``i``_arid(m_axi_mem_arid[i]), \
    .m_axi_mem_``i``_arlen(m_axi_mem_arlen[i]), \
    .m_axi_mem_``i``_rvalid(m_axi_mem_rvalid[i]), \
    .m_axi_mem_``i``_rready(m_axi_mem_rready[i]), \
    .m_axi_mem_``i``_rdata(m_axi_mem_rdata[i]), \
    .m_axi_mem_``i``_rlast(m_axi_mem_rlast[i]), \
    .m_axi_mem_``i``_rid(m_axi_mem_rid[i]), \
    .m_axi_mem_``i``_rresp(m_axi_mem_rresp[i]), \
    .m_axi_mem_``i``_bvalid(m_axi_mem_bvalid[i]), \
    .m_axi_mem_``i``_bready(m_axi_mem_bready[i]), \
    .m_axi_mem_``i``_bresp(m_axi_mem_bresp[i]), \
    .m_axi_mem_``i``_bid(m_axi_mem_bid[i])

  // ---- DUT Instantiation ----
`ifdef VCS_POST_IMPL
  ulp_vortex_afu_1_0 dut (
    .ap_clk(ap_clk), .ap_rst_n(ap_rst_n),
    `MP_REPEAT (`TB_AXI_MEM_PORTS, TB_AXI_MEM_CONNECT, MP_COMMA),
    .m_axi_host_awvalid(m_axi_mem_awvalid[HOST_PORT]),
    .m_axi_host_awready(m_axi_mem_awready[HOST_PORT]),
    .m_axi_host_awaddr(m_axi_mem_awaddr[HOST_PORT]),
    .m_axi_host_awid(m_axi_mem_awid[HOST_PORT]),
    .m_axi_host_awlen(m_axi_mem_awlen[HOST_PORT]),
    .m_axi_host_wvalid(m_axi_mem_wvalid[HOST_PORT]),
    .m_axi_host_wready(m_axi_mem_wready[HOST_PORT]),
    .m_axi_host_wdata(m_axi_mem_wdata[HOST_PORT]),
    .m_axi_host_wstrb(m_axi_mem_wstrb[HOST_PORT]),
    .m_axi_host_wlast(m_axi_mem_wlast[HOST_PORT]),
    .m_axi_host_arvalid(m_axi_mem_arvalid[HOST_PORT]),
    .m_axi_host_arready(m_axi_mem_arready[HOST_PORT]),
    .m_axi_host_araddr(m_axi_mem_araddr[HOST_PORT]),
    .m_axi_host_arid(m_axi_mem_arid[HOST_PORT]),
    .m_axi_host_arlen(m_axi_mem_arlen[HOST_PORT]),
    .m_axi_host_rvalid(m_axi_mem_rvalid[HOST_PORT]),
    .m_axi_host_rready(m_axi_mem_rready[HOST_PORT]),
    .m_axi_host_rdata(m_axi_mem_rdata[HOST_PORT]),
    .m_axi_host_rlast(m_axi_mem_rlast[HOST_PORT]),
    .m_axi_host_rid(m_axi_mem_rid[HOST_PORT]),
    .m_axi_host_rresp(m_axi_mem_rresp[HOST_PORT]),
    .m_axi_host_bvalid(m_axi_mem_bvalid[HOST_PORT]),
    .m_axi_host_bready(m_axi_mem_bready[HOST_PORT]),
    .m_axi_host_bresp(m_axi_mem_bresp[HOST_PORT]),
    .m_axi_host_bid(m_axi_mem_bid[HOST_PORT]),
    .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid), .s_axi_ctrl_awready(s_axi_ctrl_awready),
    .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr),
    .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid), .s_axi_ctrl_wready(s_axi_ctrl_wready),
    .s_axi_ctrl_wdata(s_axi_ctrl_wdata), .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb),
    .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid), .s_axi_ctrl_arready(s_axi_ctrl_arready),
    .s_axi_ctrl_araddr(s_axi_ctrl_araddr),
    .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid), .s_axi_ctrl_rready(s_axi_ctrl_rready),
    .s_axi_ctrl_rdata(s_axi_ctrl_rdata), .s_axi_ctrl_rresp(s_axi_ctrl_rresp),
    .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid), .s_axi_ctrl_bready(s_axi_ctrl_bready),
    .s_axi_ctrl_bresp(s_axi_ctrl_bresp), .interrupt(interrupt)
  );
  `ifdef PGSIM_RUNTIME_SDF_ANNOTATE
  parameter string SDF_FILE = "";
  initial begin : annotate_runtime_sdf
    if (SDF_FILE == "") $fatal(1, "[TB] Missing SDF_FILE");
    $display("[TB] Annotating SDF: %0s", SDF_FILE);
    $sdf_annotate(SDF_FILE, dut,,, "MAXIMUM");
  end
  `endif
`else
  VX_afu_wrap #(
    .C_S_AXI_CTRL_ADDR_WIDTH(C_S_AXI_CTRL_ADDR_WIDTH),
    .C_S_AXI_CTRL_DATA_WIDTH(C_S_AXI_CTRL_DATA_WIDTH),
    .C_M_AXI_MEM_ID_WIDTH(C_M_AXI_MEM_ID_WIDTH),
    .C_M_AXI_MEM_DATA_WIDTH(C_M_AXI_MEM_DATA_WIDTH),
    .C_M_AXI_MEM_ADDR_WIDTH(C_M_AXI_MEM_ADDR_WIDTH)
  ) dut (
    .clk(ap_clk), .reset(~ap_rst_n),
    `MP_REPEAT (`TB_AXI_MEM_PORTS, TB_AXI_MEM_CONNECT, MP_COMMA),
    .m_axi_host_awvalid(m_axi_mem_awvalid[HOST_PORT]),
    .m_axi_host_awready(m_axi_mem_awready[HOST_PORT]),
    .m_axi_host_awaddr(m_axi_mem_awaddr[HOST_PORT]),
    .m_axi_host_awid(m_axi_mem_awid[HOST_PORT]),
    .m_axi_host_awlen(m_axi_mem_awlen[HOST_PORT]),
    .m_axi_host_wvalid(m_axi_mem_wvalid[HOST_PORT]),
    .m_axi_host_wready(m_axi_mem_wready[HOST_PORT]),
    .m_axi_host_wdata(m_axi_mem_wdata[HOST_PORT]),
    .m_axi_host_wstrb(m_axi_mem_wstrb[HOST_PORT]),
    .m_axi_host_wlast(m_axi_mem_wlast[HOST_PORT]),
    .m_axi_host_arvalid(m_axi_mem_arvalid[HOST_PORT]),
    .m_axi_host_arready(m_axi_mem_arready[HOST_PORT]),
    .m_axi_host_araddr(m_axi_mem_araddr[HOST_PORT]),
    .m_axi_host_arid(m_axi_mem_arid[HOST_PORT]),
    .m_axi_host_arlen(m_axi_mem_arlen[HOST_PORT]),
    .m_axi_host_rvalid(m_axi_mem_rvalid[HOST_PORT]),
    .m_axi_host_rready(m_axi_mem_rready[HOST_PORT]),
    .m_axi_host_rdata(m_axi_mem_rdata[HOST_PORT]),
    .m_axi_host_rlast(m_axi_mem_rlast[HOST_PORT]),
    .m_axi_host_rid(m_axi_mem_rid[HOST_PORT]),
    .m_axi_host_rresp(m_axi_mem_rresp[HOST_PORT]),
    .m_axi_host_bvalid(m_axi_mem_bvalid[HOST_PORT]),
    .m_axi_host_bready(m_axi_mem_bready[HOST_PORT]),
    .m_axi_host_bresp(m_axi_mem_bresp[HOST_PORT]),
    .m_axi_host_bid(m_axi_mem_bid[HOST_PORT]),
    .s_axi_ctrl_awvalid(s_axi_ctrl_awvalid), .s_axi_ctrl_awready(s_axi_ctrl_awready),
    .s_axi_ctrl_awaddr(s_axi_ctrl_awaddr),
    .s_axi_ctrl_wvalid(s_axi_ctrl_wvalid), .s_axi_ctrl_wready(s_axi_ctrl_wready),
    .s_axi_ctrl_wdata(s_axi_ctrl_wdata), .s_axi_ctrl_wstrb(s_axi_ctrl_wstrb),
    .s_axi_ctrl_arvalid(s_axi_ctrl_arvalid), .s_axi_ctrl_arready(s_axi_ctrl_arready),
    .s_axi_ctrl_araddr(s_axi_ctrl_araddr),
    .s_axi_ctrl_rvalid(s_axi_ctrl_rvalid), .s_axi_ctrl_rready(s_axi_ctrl_rready),
    .s_axi_ctrl_rdata(s_axi_ctrl_rdata), .s_axi_ctrl_rresp(s_axi_ctrl_rresp),
    .s_axi_ctrl_bvalid(s_axi_ctrl_bvalid), .s_axi_ctrl_bready(s_axi_ctrl_bready),
    .s_axi_ctrl_bresp(s_axi_ctrl_bresp), .interrupt(interrupt)
  );
`endif

`ifdef FSDB_DUMP
  initial begin : fsdb_dump
    string fsdb_file;
    if (!$value$plusargs("fsdb_file=%s", fsdb_file)) fsdb_file = "vcs_cosim.fsdb";
    $fsdbDumpfile(fsdb_file);
    $fsdbDumpvars(0, tb_vcs_xrtsim, "+all");
    $display("[TB] FSDB dump enabled: %0s", fsdb_file);
  end
`endif

  // ---- Markov stall helper ----
  function automatic bit markov_step(bit state, int p_enter, int p_exit);
    int roll;
    roll = $urandom_range(99, 0);
    if (state == 0)
      return (roll < p_enter) ? 1 : 0;
    else
      return (roll < p_exit) ? 0 : 1;
  endfunction

  // ---- Working buffers for DPI ----
  byte unsigned w_data_buf [DATA_SIZE];
  byte unsigned r_data_buf [DATA_SIZE];

  // ---- Ctrl FSM state ----
  int ctrl_state;
  int ctrl_cmd_offset_r; // latched offset for read response display

  // ================================================================
  // AXI-Lite Ctrl Master FSM — posedge registered
  // (uses `always` instead of `always_ff` because ctrl_ack_pending etc.
  //  are also cleared by the initial/negedge DPI block)
  // ================================================================
  always @(posedge ap_clk) begin
    if (!ap_rst_n) begin
      s_axi_ctrl_awvalid <= 0;
      s_axi_ctrl_awaddr  <= '0;
      s_axi_ctrl_wvalid  <= 0;
      s_axi_ctrl_wdata   <= '0;
      s_axi_ctrl_wstrb   <= '0;
      s_axi_ctrl_bready  <= 0;
      s_axi_ctrl_arvalid <= 0;
      s_axi_ctrl_araddr  <= '0;
      s_axi_ctrl_rready  <= 0;
      ctrl_state         <= CTRL_IDLE;
      ctrl_ack_pending      <= 0;
      ctrl_read_rsp_pending <= 0;
      ctrl_read_rsp_value   <= 0;
      ctrl_cmd_offset_r     <= 0;
    end else begin
      case (ctrl_state)
        CTRL_IDLE: begin
          if (ctrl_cmd_queue.size() > 0) begin
            automatic ctrl_cmd_t cmd = ctrl_cmd_queue.pop_front();
            if (cmd.cmd_type == CMD_REG_WRITE) begin
              if (tb_verbose) $display("[TB] REG_WRITE: offset=0x%02x value=0x%08x", cmd.offset, cmd.value);
              s_axi_ctrl_awaddr  <= cmd.offset[C_S_AXI_CTRL_ADDR_WIDTH-1:0];
              s_axi_ctrl_awvalid <= 1;
              s_axi_ctrl_wdata   <= cmd.value;
              s_axi_ctrl_wstrb   <= '1;
              s_axi_ctrl_wvalid  <= 1;
              ctrl_cmd_offset_r  <= cmd.offset;
              ctrl_state         <= CTRL_AW_PHASE;
            end else if (cmd.cmd_type == CMD_REG_READ) begin
              s_axi_ctrl_araddr  <= cmd.offset[C_S_AXI_CTRL_ADDR_WIDTH-1:0];
              s_axi_ctrl_arvalid <= 1;
              ctrl_cmd_offset_r  <= cmd.offset;
              ctrl_state         <= CTRL_AR_PHASE;
            end
            // CMD_SHUTDOWN handled by initial block before pushing
          end
        end

        CTRL_AW_PHASE: begin
          // Wait for both AW and W handshakes; they can fire in any order
          if (s_axi_ctrl_awvalid && s_axi_ctrl_awready)
            s_axi_ctrl_awvalid <= 0;
          if (s_axi_ctrl_wvalid && s_axi_ctrl_wready)
            s_axi_ctrl_wvalid <= 0;
          // Transition when both done (considering this cycle's fires)
          if ((!s_axi_ctrl_awvalid || s_axi_ctrl_awready) &&
              (!s_axi_ctrl_wvalid  || s_axi_ctrl_wready)) begin
            s_axi_ctrl_awvalid <= 0;
            s_axi_ctrl_wvalid  <= 0;
            s_axi_ctrl_bready  <= 1;
            ctrl_state         <= CTRL_B_PHASE;
          end
        end

        CTRL_W_PHASE: begin
          // Not used in current flow (AW+W asserted together),
          // but kept for future sequential AW->W if needed
          if (s_axi_ctrl_wvalid && s_axi_ctrl_wready) begin
            s_axi_ctrl_wvalid <= 0;
            s_axi_ctrl_bready <= 1;
            ctrl_state        <= CTRL_B_PHASE;
          end
        end

        CTRL_B_PHASE: begin
          if (s_axi_ctrl_bvalid && s_axi_ctrl_bready) begin
            s_axi_ctrl_bready  <= 0;
            ctrl_ack_pending   <= 1;
            ctrl_state         <= CTRL_IDLE;
          end
        end

        CTRL_AR_PHASE: begin
          if (s_axi_ctrl_arvalid && s_axi_ctrl_arready) begin
            s_axi_ctrl_arvalid <= 0;
            s_axi_ctrl_rready  <= 1;
            ctrl_state         <= CTRL_R_PHASE;
          end
        end

        CTRL_R_PHASE: begin
          if (s_axi_ctrl_rvalid && s_axi_ctrl_rready) begin
            s_axi_ctrl_rready     <= 0;
            ctrl_read_rsp_pending <= 1;
            ctrl_read_rsp_value   <= s_axi_ctrl_rdata;
            if (tb_verbose) $display("[TB] REG_READ: offset=0x%02x value=0x%08x",
                     ctrl_cmd_offset_r, s_axi_ctrl_rdata);
            ctrl_state            <= CTRL_IDLE;
          end
        end

        default: ctrl_state <= CTRL_IDLE;
      endcase
    end
  end

  // ================================================================
  // AXI Memory Slave — generate for (per-port)
  // ================================================================
  generate
    for (genvar gi = 0; gi < NUM_PORTS; gi++) begin : mem_port

      // ---- Ready signals (always_comb — queue.size() requires procedural context) ----
      always_comb begin
        m_axi_mem_arready[gi] = !req_stalling[gi]
                              && (r_queue[gi].size() < RSP_QUEUE_LIMIT);
        m_axi_mem_awready[gi] = !req_stalling[gi]
                              && (b_queue[gi].size() < RSP_QUEUE_LIMIT);
        m_axi_mem_wready[gi]  = !req_stalling[gi]
                              && (b_queue[gi].size() < RSP_QUEUE_LIMIT);
      end

      // ---- Response driver (R channel) ----
      always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
          m_axi_mem_rvalid[gi] <= 0;
          m_axi_mem_rdata[gi]  <= '0;
          m_axi_mem_rid[gi]    <= '0;
          m_axi_mem_rlast[gi]  <= 0;
          m_axi_mem_rresp[gi]  <= 2'b00;
        end else begin
          // Deassert on handshake
          if (m_axi_mem_rvalid[gi] && m_axi_mem_rready[gi])
            m_axi_mem_rvalid[gi] <= 0;
          // Drive next response (last NBA wins → zero-bubble back-to-back)
          if ((!m_axi_mem_rvalid[gi] || (m_axi_mem_rvalid[gi] && m_axi_mem_rready[gi]))
              && !rsp_stalling[gi] && r_queue[gi].size() > 0) begin
            automatic r_rsp_t entry = r_queue[gi].pop_front();
            m_axi_mem_rvalid[gi] <= 1;
            m_axi_mem_rid[gi]    <= entry.id;
            m_axi_mem_rdata[gi]  <= entry.data;
            m_axi_mem_rlast[gi]  <= entry.last;
            m_axi_mem_rresp[gi]  <= 2'b00;
          `ifdef DEBUG_AXI
            $display("[TB] R-DRV: port=%0d id=%0d last=%0d t=%0t",
                     gi, entry.id, entry.last, $time);
          `endif
          end
        end
      end

      // ---- Response driver (B channel) ----
      always_ff @(posedge ap_clk) begin
        if (!ap_rst_n) begin
          m_axi_mem_bvalid[gi] <= 0;
          m_axi_mem_bid[gi]    <= '0;
          m_axi_mem_bresp[gi]  <= 2'b00;
        end else begin
          if (m_axi_mem_bvalid[gi] && m_axi_mem_bready[gi])
            m_axi_mem_bvalid[gi] <= 0;
          if ((!m_axi_mem_bvalid[gi] || (m_axi_mem_bvalid[gi] && m_axi_mem_bready[gi]))
              && !rsp_stalling[gi] && b_queue[gi].size() > 0) begin
            automatic b_rsp_t entry = b_queue[gi].pop_front();
            m_axi_mem_bvalid[gi] <= 1;
            m_axi_mem_bid[gi]    <= entry.id;
            m_axi_mem_bresp[gi]  <= 2'b00;
          `ifdef DEBUG_AXI
            $display("[TB] B-DRV: port=%0d id=%0d t=%0t", gi, entry.id, $time);
          `endif
          end
        end
      end

      // ---- Request capture (fire flags) ----
      // (uses `always` — flags cleared by initial/negedge DPI block)
      always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
          ar_fire_flag[gi] <= 0;
          aw_fire_flag[gi] <= 0;
          w_fire_flag[gi]  <= 0;
        end else begin
          if (m_axi_mem_arvalid[gi] && m_axi_mem_arready[gi]) begin
            ar_fire_flag[gi] <= 1;
            ar_fire_addr[gi] <= m_axi_mem_araddr[gi];
            ar_fire_id[gi]   <= m_axi_mem_arid[gi];
            ar_fire_len[gi]  <= m_axi_mem_arlen[gi];
          end
          if (m_axi_mem_awvalid[gi] && m_axi_mem_awready[gi]) begin
            aw_fire_flag[gi] <= 1;
            aw_fire_addr[gi] <= m_axi_mem_awaddr[gi];
            aw_fire_id[gi]   <= m_axi_mem_awid[gi];
            aw_fire_len[gi]  <= m_axi_mem_awlen[gi];
          end
          if (m_axi_mem_wvalid[gi] && m_axi_mem_wready[gi]) begin
            w_fire_flag[gi] <= 1;
            w_fire_data[gi] <= m_axi_mem_wdata[gi];
            w_fire_strb[gi] <= m_axi_mem_wstrb[gi];
            w_fire_last[gi] <= m_axi_mem_wlast[gi];
          end
        end
      end

      // ---- Markov stall (per-port) ----
      // (uses `always` — stall state also initialized by initial block)
      always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
          req_stalling[gi] <= 0;
          rsp_stalling[gi] <= 0;
        end else begin
          req_stalling[gi] <= markov_step(req_stalling[gi],
                                          dram_req_stall_p_enter, dram_req_stall_p_exit);
          rsp_stalling[gi] <= markov_step(rsp_stalling[gi],
                                          dram_rsp_stall_p_enter, dram_rsp_stall_p_exit);
        end
      end

    end // for gi
  endgenerate

  // ================================================================
  // DPI Polling Block — initial forever @(negedge)
  // The only non-synthesizable block.
  // ================================================================
  initial begin : dpi_block
    int socket_port;
    int ret;
    int rsp_type, rsp_port, rsp_id, rsp_last;
    int cmd_type, cmd_offset, cmd_value;

    if (!$value$plusargs("SOCKET_PORT=%d", socket_port)) socket_port = 9999;
    $display("[TB] Starting VCS co-simulation testbench");
    $display("[TB] Socket port: ctrl=%0d, mem=%0d", socket_port, socket_port + 1);
    tb_verbose = $test$plusargs("TB_VERBOSE");

    // Read DRAM stall parameters
    if (!$value$plusargs("DRAM_REQ_STALL_P_ENTER_PCT=%d", dram_req_stall_p_enter))
      dram_req_stall_p_enter = 0;
    if (!$value$plusargs("DRAM_REQ_STALL_P_EXIT_PCT=%d", dram_req_stall_p_exit))
      dram_req_stall_p_exit = 50;
    if (!$value$plusargs("DRAM_RSP_STALL_P_ENTER_PCT=%d", dram_rsp_stall_p_enter))
      dram_rsp_stall_p_enter = 0;
    if (!$value$plusargs("DRAM_RSP_STALL_P_EXIT_PCT=%d", dram_rsp_stall_p_exit))
      dram_rsp_stall_p_exit = 50;
    $display("[TB] DRAM stall config: req_enter=%0d%% req_exit=%0d%% rsp_enter=%0d%% rsp_exit=%0d%%",
             dram_req_stall_p_enter, dram_req_stall_p_exit,
             dram_rsp_stall_p_enter, dram_rsp_stall_p_exit);

    // Initialize clock and reset
    ap_clk   = 0;
    ap_rst_n = 0;

    // Initialize fire flags
    for (int i = 0; i < NUM_PORTS; i++) begin
      ar_fire_flag[i] = 0;
      aw_fire_flag[i] = 0;
      w_fire_flag[i]  = 0;
    end
    ctrl_ack_pending      = 0;
    ctrl_read_rsp_pending = 0;

    // Socket init
    ret = socket_server_init(socket_port, socket_port + 1);
    if (ret != 0) begin $fatal(1, "[TB] Failed to init socket server"); end
    ret = socket_server_accept();
    if (ret != 0) begin $fatal(1, "[TB] Failed to accept connections"); end

    // Reset sequence
    repeat (20) @(negedge ap_clk);
    ap_rst_n = 1;
    repeat (20) @(negedge ap_clk);

    $display("[TB] Reset done, entering command loop");

    // ==== Main negedge loop ====
    forever begin
      @(negedge ap_clk);

      // ---- 1. Poll ctrl commands → push to ctrl_cmd_queue ----
      while (ctrl_has_command()) begin
        ret = ctrl_recv_command(cmd_type, cmd_offset, cmd_value);
        if (ret != 0) break;
        if (cmd_type == CMD_SHUTDOWN) begin
          $display("[TB] Received SHUTDOWN command");
          socket_server_close();
          $finish;
        end
        begin
          ctrl_cmd_t enq;
          enq.cmd_type = cmd_type;
          enq.offset   = cmd_offset;
          enq.value    = cmd_value;
          ctrl_cmd_queue.push_back(enq);
        end
      end

      // ---- 2. Poll mem responses → push to r_queue / b_queue ----
      while (mem_has_response()) begin
        ret = mem_recv_response(rsp_type, rsp_port, rsp_id, r_data_buf, rsp_last, DATA_SIZE);
        if (ret != 0) break;
        if (rsp_type == RSP_AXI_R) begin
          r_rsp_t enq;
          enq.id   = rsp_id;
          enq.last = rsp_last;
          for (int i = 0; i < DATA_SIZE; i++)
            enq.data[i*8 +: 8] = r_data_buf[i];
          r_queue[rsp_port].push_back(enq);
        `ifdef DEBUG_AXI
          $display("[TB] R-ENQ: port=%0d id=%0d last=%0d qlen=%0d t=%0t",
                   rsp_port, rsp_id, rsp_last, r_queue[rsp_port].size(), $time);
        `endif
        end else if (rsp_type == RSP_AXI_B) begin
          b_rsp_t enq;
          enq.id = rsp_id;
          b_queue[rsp_port].push_back(enq);
        `ifdef DEBUG_AXI
          $display("[TB] B-ENQ: port=%0d id=%0d qlen=%0d t=%0t",
                   rsp_port, rsp_id, b_queue[rsp_port].size(), $time);
        `endif
        end
      end

      // ---- 3. Consume fire flags → DPI send ----
      for (int i = 0; i < NUM_PORTS; i++) begin
        if (ar_fire_flag[i]) begin
        `ifdef DEBUG_AXI
          $display("[TB] AR: port=%0d addr=0x%016x id=%0d len=%0d t=%0t",
                   i, ar_fire_addr[i], ar_fire_id[i], ar_fire_len[i], $time);
        `endif
          ret = mem_send_axi_ar(i, ar_fire_addr[i], ar_fire_id[i], ar_fire_len[i]);
          ar_fire_flag[i] = 0;
        end
        if (aw_fire_flag[i]) begin
        `ifdef DEBUG_AXI
          $display("[TB] AW: port=%0d addr=0x%016x id=%0d len=%0d t=%0t",
                   i, aw_fire_addr[i], aw_fire_id[i], aw_fire_len[i], $time);
        `endif
          ret = mem_send_axi_aw(i, aw_fire_addr[i], aw_fire_id[i], aw_fire_len[i]);
          aw_fire_flag[i] = 0;
        end
        if (w_fire_flag[i]) begin
          for (int j = 0; j < DATA_SIZE; j++)
            w_data_buf[j] = w_fire_data[i][j*8 +: 8];
          ret = mem_send_axi_w(i, w_data_buf, w_fire_strb[i], w_fire_last[i], DATA_SIZE);
          w_fire_flag[i] = 0;
        end
      end

      // ---- 4. Consume ctrl ack/read_rsp flags → DPI send ----
      if (ctrl_ack_pending) begin
        ret = ctrl_send_ack();
        ctrl_ack_pending = 0;
      end
      if (ctrl_read_rsp_pending) begin
        ret = ctrl_send_reg_value(ctrl_read_rsp_value);
        ctrl_read_rsp_pending = 0;
      end

    end // forever
  end // dpi_block

endmodule
