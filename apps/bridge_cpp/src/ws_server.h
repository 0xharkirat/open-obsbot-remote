#pragma once
#include <cstdint>
#include <string>

namespace obs {
class DeviceSession;
class VideoCapture;

// Run a Crow WebSocket + HTTP server on `port` (blocks).
// `video` may be nullptr to disable the /preview.mjpeg route.
// `web_root` (optional) — if non-empty and the directory exists, the server
// serves the Flutter web build (apps/mobile/build/web) from `/`. Phones can
// then point Safari/Chrome at http://<mac>:<port>/ and use the remote
// without installing anything.
void run_ws_server(uint16_t port,
                   DeviceSession& session,
                   VideoCapture* video,
                   const std::string& web_root);
}
