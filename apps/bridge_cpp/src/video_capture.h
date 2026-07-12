#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace obs {

// Multiply a JPEG's RGB by `factor` (0 = black, 1 = unchanged) and re-encode.
// This is the fade-from-black primitive: a program cut can ramp `factor` 0->1
// over ~0.5s so the incoming camera fades up from black on the active stream
// (baked into the MJPEG so OBS sees it, not just the webapp). Returns the input
// unchanged when factor >= 1 (the no-fade common case, so zero cost normally)
// or on any decode/encode failure. Uses Core Image + ImageIO (already linked).
// Kept as the fallback for the first take, when there is no outgoing frame to
// dissolve from (see jpeg_crossfade).
std::vector<uint8_t> jpeg_darken(const std::vector<uint8_t>& jpeg, float factor);

// Crossfade (dissolve) two JPEG frames: factor 0 = outgoing, 1 = incoming.
// The program-transition primitive - on a TAKE/cue with a fade, the bridge
// grabs the outgoing camera's frame and dissolves it into the incoming
// camera's live frames over the fade window, baked into active.mjpg so OBS
// sees the dissolve. Returns incoming unchanged when there is nothing to blend
// (empty outgoing, or factor >= 1) or on any failure.
std::vector<uint8_t> jpeg_crossfade(const std::vector<uint8_t>& outgoing,
                                    const std::vector<uint8_t>& incoming,
                                    float factor);

// Captures one OBSBOT camera as a regular UVC webcam via AVFoundation,
// JPEG-encodes the latest frame in software, and exposes it to the HTTP
// route. libdev is unaffected  -  control + video go to the same USB device
// over independent endpoints. macOS can run N of these simultaneously (one per
// physical camera) at 1080p MJPEG.
class VideoCapture {
public:
    VideoCapture();
    ~VideoCapture();

    // Pick the first AVCaptureDevice whose name contains `name_substr`
    // (case-insensitive). Empty = pick the first device whose name starts
    // with "OBSBOT". Returns false if no match or session fails to start.
    //
    // NOTE: name matching cannot tell two identical cameras apart - every
    // Tiny 2 Lite reports the SAME localizedName. Multi-cam MUST use
    // start_unique_id() instead.
    bool start(const std::string& name_substr = "");

    // Bind to the exact AVCaptureDevice whose uniqueID equals `unique_id`
    // (== Device::videoDevPath() on macOS - the SN -> capture-device join).
    // Retries briefly because a camera can appear in libdev before
    // AVFoundation enumerates it. Returns false if the device never appears or
    // the session fails to start.
    bool start_unique_id(const std::string& unique_id);

    // Trigger the macOS camera-permission (TCC) prompt without binding a
    // device. Called once at boot so the prompt fires even before any camera
    // has enumerated (the bridge UI keys "Granted" off the resulting log line).
    //
    // `on_result` (optional) fires with the user's answer if a prompt is
    // actually shown (status was NotDetermined). This is how the bridge
    // retries captures that already gave up at their 60s permission timeout:
    // if the operator clicks Allow minutes later, granting alone would leave
    // preview dead until a restart. Runs on an AVFoundation callback thread.
    static void request_camera_permission(
        std::function<void(bool granted)> on_result = {});

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
    // Configure + start a session bound to an AVCaptureDevice (passed as an
    // opaque bridged pointer so this stays in the C++ header). Shared by
    // start() and start_unique_id().
    bool start_with_device(void* device_ptr);

    std::unique_ptr<Impl> impl_;
};

}  // namespace obs
