#pragma once
#include <cstdint>
#include <string>

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

    // `bindaddr` matches run_ws_server: every interface by default, 127.0.0.1
    // when a Tailscale serve or reverse proxy is the thing publishing it.
    bool start(uint16_t port, DeviceManager* mgr, AuthStore* auth,
               const std::string& bindaddr = "0.0.0.0");
    void stop();
    bool running() const;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace obs
