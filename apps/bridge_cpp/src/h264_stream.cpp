#include "h264_stream.h"

#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csignal>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <initializer_list>
#include <string>
#include <vector>

#include "device_manager.h"
#include "log.h"
#include "video_capture.h"

namespace obs {
namespace {

// mkdir -p, because the operator should not have to pre-create a cache dir.
bool make_dirs(const std::string& path) {
    if (path.empty()) return false;
    std::string acc;
    size_t i = 0;
    if (path[0] == '/') { acc = "/"; i = 1; }
    while (i <= path.size()) {
        const size_t slash = path.find('/', i);
        const std::string part =
            path.substr(i, slash == std::string::npos ? std::string::npos : slash - i);
        if (!part.empty()) {
            if (!acc.empty() && acc.back() != '/') acc += '/';
            acc += part;
            if (::mkdir(acc.c_str(), 0755) != 0 && errno != EEXIST) return false;
        }
        if (slash == std::string::npos) break;
        i = slash + 1;
    }
    return true;
}

bool have_ffmpeg() { return ::system("command -v ffmpeg >/dev/null 2>&1") == 0; }

}  // namespace

H264Stream::~H264Stream() { stop(); }

std::string H264Stream::playlist_path() const { return cfg_.out_dir + "/live.m3u8"; }

bool H264Stream::start(DeviceManager* mgr, const H264Config& cfg) {
    if (running_.load()) return true;
    cfg_ = cfg;

    if (!have_ffmpeg()) {
        LOGW("h264: ffmpeg not on PATH  -  remote H.264 stream disabled");
        return false;
    }
    if (!make_dirs(cfg_.out_dir)) {
        LOGW("h264: cannot create %s  -  remote H.264 stream disabled",
             cfg_.out_dir.c_str());
        return false;
    }

    int fds[2];
    if (::pipe(fds) != 0) {
        LOGW("h264: pipe() failed: %s", std::strerror(errno));
        return false;
    }

    const std::string seg_pattern = cfg_.out_dir + "/seg%05d.ts";
    const std::string playlist = playlist_path();
    const std::string bitrate = std::to_string(cfg_.bitrate_kbps) + "k";
    // A ceiling ~30% above target keeps a busy scene from spiking past what
    // the link can carry, which is the whole point of the exercise.
    const std::string maxrate = std::to_string(cfg_.bitrate_kbps * 13 / 10) + "k";
    const std::string fps = std::to_string(cfg_.fps);
    // One keyframe per segment, so a player can start on any segment boundary.
    const std::string gop = std::to_string(cfg_.fps * cfg_.segment_seconds);

    std::vector<std::string> args = {
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
        // Input: the JPEGs the bridge already holds, fed on stdin. Not the
        // V4L2 device - only one process can own that, and we do.
        "-f", "mjpeg", "-framerate", fps, "-i", "pipe:0",
        "-an",
        "-c:v", cfg_.encoder,
    };
    auto add = [&args](std::initializer_list<const char*> xs) {
        for (const char* x : xs) args.emplace_back(x);
    };
    // p4/ll are NVENC-only knobs; handing them to libx264 makes it refuse to
    // start. Appending rather than splicing at a magic index keeps this from
    // silently corrupting the argument list the next time an option is added.
    if (cfg_.encoder.find("nvenc") != std::string::npos) {
        add({"-preset", "p4", "-tune", "ll"});
    }
    // MJPEG from this camera decodes to YUV422P, and NVENC accepts only 4:2:0
    // ("YUV422P not supported / No capable devices found", which reads like
    // a missing GPU and is really a pixel format). libx264 would take 4:2:2
    // but few players will, so normalise for both encoders.
    add({"-pix_fmt", "yuv420p"});
    args.insert(args.end(), {
        "-b:v", bitrate, "-maxrate", maxrate, "-bufsize", bitrate,
        "-g", gop, "-r", fps,
        "-s", cfg_.size,
        "-f", "hls",
        "-hls_time", std::to_string(cfg_.segment_seconds),
        "-hls_list_size", std::to_string(cfg_.playlist_size),
        // delete_segments keeps the directory bounded; omit_endlist keeps
        // players treating it as live rather than a finished recording.
        "-hls_flags", "delete_segments+omit_endlist",
        "-hls_segment_filename", seg_pattern,
        playlist,
    });

    const int pid = ::fork();
    if (pid < 0) {
        ::close(fds[0]); ::close(fds[1]);
        LOGW("h264: fork() failed: %s", std::strerror(errno));
        return false;
    }
    if (pid == 0) {
        ::dup2(fds[0], STDIN_FILENO);
        ::close(fds[0]);
        ::close(fds[1]);
        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
        ::execvp("ffmpeg", argv.data());
        ::_exit(127);  // exec failed; the parent sees the pipe close
    }

    ::close(fds[0]);
    child_stdin_ = fds[1];
    child_pid_ = pid;
    running_.store(true);
    pump_ = std::thread([this, mgr] { pump(mgr); });

    LOGI("h264: %s %s@%dfps %dkbps -> %s",
         cfg_.encoder.c_str(), cfg_.size.c_str(), cfg_.fps, cfg_.bitrate_kbps,
         playlist.c_str());
    return true;
}

void H264Stream::pump(DeviceManager* mgr) {
    const auto interval = std::chrono::microseconds(1000000 / (cfg_.fps > 0 ? cfg_.fps : 25));
    auto next = std::chrono::steady_clock::now();
    uint64_t last_seq = 0;
    std::vector<uint8_t> frame;

    while (running_.load()) {
        next += interval;
        std::this_thread::sleep_until(next);

        // Follow the on-air camera, re-resolved every tick, so a TAKE swaps
        // this stream too rather than stranding it on a detached camera.
        const std::string sn = mgr->active_sn();
        VideoCapture* cap = sn.empty() ? nullptr : mgr->capture_for(sn);
        if (cap == nullptr) continue;

        // Re-sending an unchanged frame would still cost a full JPEG on the
        // pipe for no new picture. Skip it; ffmpeg holds the last one.
        const uint64_t seq = cap->frame_seq();
        if (seq == last_seq) continue;
        last_seq = seq;

        frame = cap->latest_jpeg();
        if (frame.empty()) continue;

        size_t off = 0;
        while (off < frame.size() && running_.load()) {
            const ssize_t n = ::write(child_stdin_, frame.data() + off, frame.size() - off);
            if (n > 0) { off += static_cast<size_t>(n); continue; }
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            // ffmpeg died or the pipe broke. Stop rather than spin: the MJPEG
            // path is unaffected, and the operator sees this in the journal.
            LOGW("h264: write to ffmpeg failed (%s)  -  stream stopped",
                 n < 0 ? std::strerror(errno) : "pipe closed");
            running_.store(false);
            return;
        }
    }
}

void H264Stream::stop() {
    if (!running_.exchange(false)) {
        // Not running, but a pump thread may still be joinable after a
        // write failure set running_ false from inside pump().
        if (pump_.joinable()) pump_.join();
        return;
    }
    if (pump_.joinable()) pump_.join();
    if (child_stdin_ >= 0) { ::close(child_stdin_); child_stdin_ = -1; }
    if (child_pid_ > 0) {
        // Closing stdin makes ffmpeg finish and exit on its own; only reach
        // for a signal if it does not take the hint.
        for (int i = 0; i < 30; ++i) {
            if (::waitpid(child_pid_, nullptr, WNOHANG) == child_pid_) { child_pid_ = -1; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (child_pid_ > 0) {
            ::kill(child_pid_, SIGTERM);
            ::waitpid(child_pid_, nullptr, 0);
            child_pid_ = -1;
        }
    }
    LOGI("h264: stopped");
}

}  // namespace obs
