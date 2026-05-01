#pragma once
#include <cstdint>

namespace obs {
class DeviceSession;
class VideoCapture;

// Run a Crow WebSocket + HTTP server on `port` (blocks).
// `video` may be nullptr to disable the /preview.mjpeg route.
void run_ws_server(uint16_t port, DeviceSession& session, VideoCapture* video);
}
