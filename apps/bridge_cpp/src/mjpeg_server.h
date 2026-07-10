#pragma once
#include <cstdint>

namespace obs {
class DeviceManager;
class AuthStore;

// Tiny standalone HTTP server that streams JPEG frames as
// multipart/x-mixed-replace. Token check via ?t=<token> in URL.
//
// Paths (all under port = ws_port + 1):
//   /preview/<sn>.mjpg      one specific camera by serial number
//   /preview/active.mjpg    follows the active camera; swaps source mid-stream
//                           (for OBS) without dropping the connection
//   /preview.mjpeg          legacy alias for /preview/active.mjpg
// Unknown SN -> 404. A camera with no frames yet (e.g. asleep) -> 503, served
// promptly rather than wedging the serving thread.
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
