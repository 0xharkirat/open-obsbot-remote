#pragma once
#include <cstdint>

namespace obs {
class VideoCapture;
class AuthStore;

// Tiny standalone HTTP server that streams JPEG frames as
// multipart/x-mixed-replace. Token check via ?t=<token> in URL.
class MjpegServer {
public:
    MjpegServer();
    ~MjpegServer();

    bool start(uint16_t port, VideoCapture* video, AuthStore* auth);
    void stop();
    bool running() const;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace obs
