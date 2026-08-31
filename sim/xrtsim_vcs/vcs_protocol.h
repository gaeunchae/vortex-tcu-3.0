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

#pragma once

#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>

// Packet types for ctrl_sock (App main thread <-> VCS)
enum VcsCtrlType : uint8_t {
  CMD_REG_WRITE     = 0x01,
  CMD_REG_WRITE_ACK = 0x02,
  CMD_REG_READ      = 0x03,
  CMD_REG_READ_RESP = 0x04,
  CMD_SHUTDOWN      = 0x05
};

// Packet types for mem_sock (App sim thread <-> VCS)
enum VcsMemType : uint8_t {
  EVT_AXI_AR  = 0x10,  // DUT read request
  EVT_AXI_AW  = 0x11,  // DUT write address
  EVT_AXI_W   = 0x12,  // DUT write data+strb
  RSP_AXI_R   = 0x20,  // read response (App -> VCS)
  RSP_AXI_B   = 0x21   // write response (App -> VCS)
};

// Common packet header (24 bytes)
struct VcsPacket {
  uint8_t  type;        // VcsCtrlType or VcsMemType
  uint8_t  port_id;     // AXI port index
  uint8_t  reserved[2];
  uint32_t id;          // AXI transaction ID or register offset
  uint64_t addr;        // memory address
  uint32_t size;        // payload size (bytes following this header)
  uint32_t value;       // register value or misc
};

static_assert(sizeof(VcsPacket) == 24, "VcsPacket must be 24 bytes");

// Reliable send: writes exactly `len` bytes to socket fd.
// Returns 0 on success, -1 on error.
static inline int send_all(int fd, const void* buf, size_t len) {
  const uint8_t* p = (const uint8_t*)buf;
  while (len > 0) {
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
    if (n <= 0) {
      if (n < 0 && errno == EINTR)
        continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

// Reliable recv: reads exactly `len` bytes from socket fd.
// Returns 0 on success, -1 on error/disconnect.
static inline int recv_all(int fd, void* buf, size_t len) {
  uint8_t* p = (uint8_t*)buf;
  while (len > 0) {
    ssize_t n = recv(fd, p, len, 0);
    if (n <= 0) {
      if (n < 0 && errno == EINTR)
        continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

// Non-blocking check if data is available on socket.
// Returns 1 if data available, 0 if not, -1 on error.
static inline int sock_has_data(int fd) {
  uint8_t peek;
  ssize_t n = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT);
  if (n > 0)
    return 1;
  if (n == 0)
    return -1; // peer closed
  if (errno == EAGAIN || errno == EWOULDBLOCK)
    return 0;
  return -1;
}
