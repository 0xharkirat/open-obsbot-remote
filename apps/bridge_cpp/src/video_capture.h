#pragma once

#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace obs {

// Captures the Tiny 2 Lite as a regular UVC webcam via AVFoundation,
// JPEG-encodes the latest frame in software, and exposes it to the HTTP
// route. libdev is unaffected  -  control + video go to the same USB device
// over independent endpoints.
class VideoCapture {
public:
    VideoCapture();
    ~VideoCapture();

    // Pick the first AVCaptureDevice whose name contains `name_substr`
    // (case-insensitive). Empty = pick the first device whose name starts
    // with "OBSBOT". Returns false if no match or session fails to start.
    bool start(const std::string& name_substr = "");
    void stop();

    bool running() const;

    // Returns a copy of the latest JPEG, or empty vector if none yet.
    std::vector<uint8_t> latest_jpeg() const;

    // Returns a monotonically increasing counter  -  useful for clients
    // wanting to wait for the next frame.
    uint64_t frame_seq() const;

    // Public so the AVFoundation delegate (Objective-C++) can write into
    // it. Treat as opaque from C++ callers.
    struct Impl;

private:
    std::unique_ptr<Impl> impl_;
};

}  // namespace obs
