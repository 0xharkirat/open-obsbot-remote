#pragma once
#include <cstdint>

namespace obs {
class DeviceSession;

// Run a Crow WebSocket server on `port` (blocks).
void run_ws_server(uint16_t port, DeviceSession& session);
}
