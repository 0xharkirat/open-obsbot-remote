#pragma once
#include <cstdint>

namespace obs {
class DeviceManager;
class AuthStore;

// Tiny standalone HTTP server that streams JPEG frames as
// multipart/x-mixed-replace. Token check via t=<token> in the query, at any
// position.
//
// Paths (all under port = ws_port + 1):
//   /preview/<sn>.mjpg      one specific camera by serial number
//   /preview/active.mjpg    follows the active camera; swaps source mid-stream
//                           (for OBS) without dropping the connection
//   /preview.mjpeg          legacy alias for /preview/active.mjpg
// Unknown SN -> 404. A camera with no frames yet (e.g. asleep) -> 503, served
// promptly rather than wedging the serving thread.
//
// Optional query parameters for a smaller stream (all 3 paths; the parser is
// preview_params.h). Out-of-range values clamp; malformed ones are ignored.
//   w=<160..1920>   width, rounded down to even; height is 16:9, even.
//                   Default 1920 (1920x1080).
//   fps=<1..30>     most frames per second sent. Default: no cap (camera rate).
//   q=<0.3..0.95>   JPEG quality, rounded to 0.05. Default 0.85.
// With w=1920 and q=0.85 the stream is the program frame as-is. Any other
// size or quality is 1 VideoToolbox encode per camera per (w, q), shared by
// every stream that asks for it.
class MjpegServer {
public:
    MjpegServer();
    ~MjpegServer();

    bool start(uint16_t port, DeviceManager* mgr, AuthStore* auth);
    void stop();
    bool running() const;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace obs
