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

// DPI-C socket server for VCS testbench.
// Two TCP sockets: ctrl_sock (register commands) and mem_sock (AXI memory events).
// No RAM or memory model here -- just packet relay between TB and App process.

#include "svdpi.h"
#include "vcs_protocol.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>

// Stubs for sim_trace functions (defined in xrt_sim.cpp for Verilator builds)
static bool g_trace_enabled = true;
bool sim_trace_enabled() { return g_trace_enabled; }
void sim_trace_enable(bool enable) { g_trace_enabled = enable; }

static int ctrl_server_fd = -1;
static int ctrl_client_fd = -1;
static int mem_server_fd  = -1;
static int mem_client_fd  = -1;

static int create_listen_socket(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("[DPI] socket");
    return -1;
  }
  int opt = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(port);

  if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    perror("[DPI] bind");
    close(fd);
    return -1;
  }
  if (listen(fd, 1) < 0) {
    perror("[DPI] listen");
    close(fd);
    return -1;
  }
  return fd;
}

static int accept_client(int server_fd) {
  struct sockaddr_in client_addr;
  socklen_t len = sizeof(client_addr);
  int fd = accept(server_fd, (struct sockaddr*)&client_addr, &len);
  if (fd < 0) {
    perror("[DPI] accept");
    return -1;
  }
  // disable Nagle for low latency
  int opt = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
  return fd;
}

// ============================================================
// DPI functions callable from SystemVerilog
// ============================================================

extern "C" {

// Initialize server sockets on ctrl_port and mem_port
int socket_server_init(int ctrl_port, int mem_port) {
  ctrl_server_fd = create_listen_socket(ctrl_port);
  if (ctrl_server_fd < 0)
    return -1;
  printf("[DPI] ctrl socket listening on port %d\n", ctrl_port);

  mem_server_fd = create_listen_socket(mem_port);
  if (mem_server_fd < 0) {
    close(ctrl_server_fd);
    ctrl_server_fd = -1;
    return -1;
  }
  printf("[DPI] mem socket listening on port %d\n", mem_port);
  return 0;
}

// Blocking accept on both sockets (ctrl first, then mem)
int socket_server_accept() {
  printf("[DPI] waiting for ctrl connection...\n");
  ctrl_client_fd = accept_client(ctrl_server_fd);
  if (ctrl_client_fd < 0)
    return -1;
  printf("[DPI] ctrl client connected\n");

  printf("[DPI] waiting for mem connection...\n");
  mem_client_fd = accept_client(mem_server_fd);
  if (mem_client_fd < 0)
    return -1;
  printf("[DPI] mem client connected\n");
  return 0;
}

// ---- ctrl_sock functions ----

// Non-blocking check if a command is available on ctrl_sock
int ctrl_has_command() {
  return sock_has_data(ctrl_client_fd) > 0 ? 1 : 0;
}

// Receive a command packet from ctrl_sock
// Returns: type in *out_type, offset in *out_offset, value in *out_value
int ctrl_recv_command(int* out_type, int* out_offset, int* out_value) {
  VcsPacket pkt;
  if (recv_all(ctrl_client_fd, &pkt, sizeof(pkt)) < 0)
    return -1;
  *out_type   = pkt.type;
  *out_offset = (int)pkt.id;
  *out_value  = (int)pkt.value;
  return 0;
}

// Send REG_WRITE ACK back to App
int ctrl_send_ack() {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type = CMD_REG_WRITE_ACK;
  return send_all(ctrl_client_fd, &pkt, sizeof(pkt));
}

// Send REG_READ response with value
int ctrl_send_reg_value(int value) {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type  = CMD_REG_READ_RESP;
  pkt.value = (uint32_t)value;
  return send_all(ctrl_client_fd, &pkt, sizeof(pkt));
}

// ---- mem_sock functions ----

// Send AXI AR event (read request from DUT) to App
int mem_send_axi_ar(int port, long long addr, int id, int len) {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type    = EVT_AXI_AR;
  pkt.port_id = (uint8_t)port;
  pkt.id      = (uint32_t)id;
  pkt.addr    = (uint64_t)addr;
  pkt.value   = (uint32_t)len;  // arlen
  return send_all(mem_client_fd, &pkt, sizeof(pkt));
}

// Send AXI AW event (write address from DUT) to App
int mem_send_axi_aw(int port, long long addr, int id, int len) {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type    = EVT_AXI_AW;
  pkt.port_id = (uint8_t)port;
  pkt.id      = (uint32_t)id;
  pkt.addr    = (uint64_t)addr;
  pkt.value   = (uint32_t)len;  // awlen
  return send_all(mem_client_fd, &pkt, sizeof(pkt));
}

// Send AXI W event (write data from DUT) to App
// data_bytes: pointer to write data (DATA_SIZE bytes)
// strb: byte-enable mask
// last: wlast flag
int mem_send_axi_w(int port, const svOpenArrayHandle data_bytes,
                   long long strb, int last, int data_size) {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type    = EVT_AXI_W;
  pkt.port_id = (uint8_t)port;
  pkt.size    = (uint32_t)data_size;
  pkt.value   = (uint32_t)last;
  pkt.addr    = (uint64_t)strb;  // reuse addr field for strb

  if (send_all(mem_client_fd, &pkt, sizeof(pkt)) < 0)
    return -1;

  // send data payload
  const uint8_t* dptr = (const uint8_t*)svGetArrayPtr(data_bytes);
  if (send_all(mem_client_fd, dptr, data_size) < 0)
    return -1;

  return 0;
}

// Non-blocking check if a response is available on mem_sock from App
int mem_has_response() {
  return sock_has_data(mem_client_fd) > 0 ? 1 : 0;
}

// Receive AXI response (R or B) from App
// out_type: RSP_AXI_R or RSP_AXI_B
// out_port, out_id, out_last: response fields
// data_bytes: buffer to receive read data (only for RSP_AXI_R)
int mem_recv_response(int* out_type, int* out_port, int* out_id,
                      svOpenArrayHandle data_bytes, int* out_last, int data_size) {
  VcsPacket pkt;
  if (recv_all(mem_client_fd, &pkt, sizeof(pkt)) < 0)
    return -1;

  *out_type = pkt.type;
  *out_port = pkt.port_id;
  *out_id   = pkt.id;
  *out_last = (int)pkt.value;

  if (pkt.type == RSP_AXI_R && pkt.size > 0) {
    uint8_t* dptr = (uint8_t*)svGetArrayPtr(data_bytes);
    if (recv_all(mem_client_fd, dptr, data_size) < 0)
      return -1;
  }

  return 0;
}

// Close all sockets
void socket_server_close() {
  if (ctrl_client_fd >= 0) { close(ctrl_client_fd); ctrl_client_fd = -1; }
  if (mem_client_fd >= 0)  { close(mem_client_fd);  mem_client_fd = -1; }
  if (ctrl_server_fd >= 0) { close(ctrl_server_fd); ctrl_server_fd = -1; }
  if (mem_server_fd >= 0)  { close(mem_server_fd);  mem_server_fd = -1; }
  printf("[DPI] sockets closed\n");
}

} // extern "C"
