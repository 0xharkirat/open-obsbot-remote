#pragma once
#include <cstdint>

namespace obs {
class VideoCapture;

// Tiny standalone HTTP server that streams JPEG frames from the given
// VideoCapture as multipart/x-mixed-replace. Runs on its own thread;
// accepts unlimited concurrent clients.
//
// Bound on 0.0.0.0:<port>. URL: http://<host>:<port>/preview.mjpeg
//
// Crow can't do true streaming responses (it buffers until the handler
// returns), so we sidestep it with a hand-rolled server.
class MjpegServer {
public:
    MjpegServer();
    ~MjpegServer();

    // Start in the background. `video` must outlive this server.
    bool start(uint16_t port, VideoCapture* video);
    void stop();

    bool running() const;

private:
    struct Impl;
    Impl* impl_;
};

}  // namespace obs
