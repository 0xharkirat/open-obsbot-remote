#pragma once
#include <cstdint>
#include <string>

namespace obs {
class DeviceManager;
class AuthStore;

// Run a Crow WebSocket + HTTP server on `port` (blocks). Also installs the
// DeviceManager's state broadcaster so every attached camera's snapshot fans
// out to subscribed clients as a single v2 envelope.
void run_ws_server(uint16_t port,
                   DeviceManager& mgr,
                   const std::string& web_root,
                   AuthStore& auth);
}
