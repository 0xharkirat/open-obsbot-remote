#pragma once

// Recording to the bridge host's disk. Linux only.
//
// WHY THE HOST AND NOT THE CAMERA
//
// The Tiny 2 Lite has no storage. Every recording method in the SDK is
// annotated `@category tail air`: cameraSetVideoRecordR, cameraSetTakePhotosR,
// cameraSetRecordResolutionR, cameraSetRecordSplitSizeR. That is a different
// model with an SD slot. So "start recording" can only mean "the bridge writes
// a file", and on this host that is also where the disk and the hardware
// encoder already are.
//
// WHERE THE FRAMES COME FROM
//
// The same place the MJPEG server and the H.264 stream get them: the
// VideoCapture the bridge already holds, via DeviceManager. It deliberately
// does NOT open /dev/video* itself. Only one process can own a V4L2 capture
// device, and the bridge owns it; a recorder that tried to open its own would
// fail on a machine where everything is otherwise working, which is the worst
// kind of bug to diagnose.
//
// WHY FRAGMENTED MP4
//
// A plain MP4 writes its index (the `moov` atom) on close. Kill the process
// first and the file is unplayable - not truncated, unplayable. This machine
// has an encrypted root and cannot boot unattended after a power cut, so
// "the power went out mid-take" is a case that will happen. Fragmented MP4
// flushes an index per fragment, so a recording that dies is playable up to
// the last flushed fragment. A lost take is the failure that actually costs
// something here.
//
// WHY SHUTDOWN NEEDS NO CODE HERE
//
// The bridge exits via _Exit(0) from its signal handler and its supervisor
// watchdog, because libdev's global destructors crash on teardown (CLAUDE.md
// gotcha #14). So ~Recorder() does NOT run on a normal quit, and stop() is
// never called.
//
// That is fine, and it is fine for a reason worth stating rather than
// discovering. The write end of ffmpeg's stdin pipe dies with the process, so
// the kernel closes it, ffmpeg reads EOF, finishes its final fragment and
// exits of its own accord. The clean path is the automatic one. And if the
// machine loses power instead, the fragmented MP4 above is still playable.
// Both shutdown routes end with a usable file without this class being asked.
//
// WHAT THIS DOES NOT TOUCH
//
// /preview/<sn>.mjpg and /preview/active.mjpg are unchanged. They are what OBS
// consumes in production during services, on macOS, where none of this is
// compiled in at all.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>

#include <json.hpp>

#include "device_session.h"  // CmdResult

namespace obs {

class DeviceManager;

struct RecordConfig {
    // Date-stamped subdirectories are created under here.
    std::string root = "/srv/data/recordings";

    std::string size = "1920x1080";
    int fps = 25;

    // Deliberately far above the H.264 remote stream's 2.5 Mbps. That number
    // exists to fit a 14.8 Mbps upload; this one only has to fit a disk. At
    // 8 Mbps a 1080p25 hour is ~3.6 GB, so the 907 GB volume holds roughly 250
    // hours, and the quality is worth having in a recording you keep.
    int bitrate_kbps = 8000;

    std::string encoder = "h264_nvenc";

    // Refuse to start below this much free space. Filling the volume that
    // holds the photo library is a worse outcome than a refused recording,
    // and a recording that dies of ENOSPC halfway is worse than both.
    uint64_t min_free_bytes = 5ull << 30;  // 5 GiB

    // AAC at this rate when a track is muxed. Speech in a hall, not music.
    int audio_bitrate_kbps = 128;
};

// One recording at a time, bridge-global, mirroring how `active` works.
// Two concurrent recordings would double both the encode load and the disk
// write rate for no clear gain while there is one camera.
class Recorder {
public:
    Recorder() = default;
    ~Recorder();

    Recorder(const Recorder&) = delete;
    Recorder& operator=(const Recorder&) = delete;

    void configure(const RecordConfig& cfg);

    // `device_id` empty means the on-air camera. `want_audio` is a request,
    // not a requirement: if the camera exposes no capture device the recording
    // starts silent and status().audio comes back false. Losing the take
    // because the microphone was missing would be the wrong trade.
    CmdResult start(DeviceManager* mgr, const std::string& device_id, bool want_audio);

    CmdResult stop();

    // The `recording` block of the state event. Safe to call at any time,
    // including when nothing is recording.
    nlohmann::json status() const;

    bool active() const { return active_.load(); }

    // Stop without producing a CmdResult, for process shutdown.
    void shutdown();

private:
    void pump(DeviceManager* mgr);

    // Resolve the camera's ALSA capture device by card name rather than a
    // fixed index: card ordering is not stable across boots, so hw:2,0 is a
    // bug waiting for a reboot. Returns "" when the camera has no mic.
    static std::string alsa_device_for_camera();

    static uint64_t free_bytes(const std::string& path);

    mutable std::mutex mu_;
    RecordConfig cfg_;

    std::atomic<bool> active_{false};
    std::atomic<bool> pumping_{false};

    std::string device_id_;
    std::string path_;
    std::string error_;
    bool audio_ = false;
    std::chrono::steady_clock::time_point started_;
    int64_t started_at_ms_ = 0;

    std::thread pump_;
    int child_stdin_ = -1;
    int child_pid_ = -1;
};

}  // namespace obs
