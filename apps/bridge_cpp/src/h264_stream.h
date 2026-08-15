#pragma once

// A second, far cheaper video path for watching the camera from outside the
// house. Linux only, off unless asked for.
//
// WHY THIS EXISTS - the arithmetic is the whole feature
//
// The camera emits MJPEG, which is a complete JPEG per frame with no
// compression between frames. Measured on a Tiny 2 Lite at 1080p: ~343 KB a
// frame, ~30 fps, so /preview/active.mjpg runs at roughly 80 Mbps. Over USB
// that is nothing. On a LAN it is nothing. The domestic upload link this
// bridge sits behind was measured at 14.8 Mbps, so the MJPEG preview is about
// five times more than the house can send, and remote viewing degenerates into
// a slideshow of half-drawn frames.
//
// H.264 compresses between frames, and a mostly-static room compresses
// enormously. The same 1080p25 picture costs 2-4 Mbps, call it a twelfth of
// the MJPEG. That fits the measured budget with room for everything else in
// the house. The GTX 1650 in this machine encodes it in hardware (h264_nvenc),
// so the transcode costs no CPU worth counting.
//
// WHAT THIS DOES NOT TOUCH
//
// /preview/<sn>.mjpg and /preview/active.mjpg are unchanged. They are what OBS
// consumes in production during services, on macOS, and nothing here runs in
// that build or alters that path. This is strictly an additional endpoint.
//
// HOW IT GETS FRAMES
//
// It pulls from the same VideoCapture the MJPEG server pulls from, via
// DeviceManager, and writes those JPEGs into ffmpeg's stdin. It deliberately
// does NOT open /dev/video* itself: only one process can hold a V4L2 capture
// device, and the bridge already holds it. Feeding ffmpeg from the frames we
// already have avoids that fight entirely, and costs one memcpy per frame.

#include <atomic>
#include <string>
#include <thread>

namespace obs {

class DeviceManager;

struct H264Config {
    // Where ffmpeg writes the playlist and segments. Must be writable by the
    // service: the shipped systemd unit sets ProtectHome=read-only, so this
    // cannot live under the web root without also widening ReadWritePaths.
    std::string out_dir;

    // 1080p25 at 2.5 Mbps is the default because it is the largest picture
    // that comfortably fits a 14.8 Mbps upload once everything else in the
    // house is accounted for. Drop to 720p when the link is busier.
    std::string size = "1920x1080";
    int fps = 25;
    int bitrate_kbps = 2500;

    // h264_nvenc on this hardware. Falls back to libx264 when NVENC is absent,
    // which costs real CPU and is why it is not the default.
    std::string encoder = "h264_nvenc";

    // Two-second segments, ten-segment window. Short segments cut latency;
    // a ten-segment window is enough for a player to ride out a hiccup
    // without the directory growing without bound.
    int segment_seconds = 2;
    int playlist_size = 10;
};

// Spawns ffmpeg and pumps frames into it for as long as it is running.
// Construction does nothing; start() does the work and is safe to call once.
class H264Stream {
public:
    H264Stream() = default;
    ~H264Stream();

    H264Stream(const H264Stream&) = delete;
    H264Stream& operator=(const H264Stream&) = delete;

    // Returns false and logs when ffmpeg is missing, the output directory
    // cannot be created, or the child fails to spawn. A false here is never
    // fatal to the bridge: the MJPEG path is what matters and it is unaffected.
    bool start(DeviceManager* mgr, const H264Config& cfg);

    void stop();

    bool running() const { return running_.load(); }

    // Absolute path of the playlist, for the HTTP layer to serve.
    std::string playlist_path() const;

    // Directory the HTTP layer serves segments from.
    const std::string& out_dir() const { return cfg_.out_dir; }

private:
    void pump(DeviceManager* mgr);

    H264Config cfg_;
    std::atomic<bool> running_{false};
    std::thread pump_;
    int child_stdin_ = -1;
    int child_pid_ = -1;
};

}  // namespace obs
