#pragma once
#include <cstdint>
#include <string>

namespace obs {
class DeviceSession;
class VideoCapture;
class AuthStore;

// Run a Crow WebSocket + HTTP server on `port` (blocks).
void run_ws_server(uint16_t port,
                   DeviceSession& session,
                   VideoCapture* video,
                   const std::string& web_root,
                   AuthStore& auth);
}
