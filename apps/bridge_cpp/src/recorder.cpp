#include "recorder.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <initializer_list>
#include <vector>

#include "device_manager.h"
#include "fs_util.h"
#include "log.h"
#include "video_capture.h"

namespace obs {
namespace {

int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

bool have_ffmpeg() { return ::system("command -v ffmpeg >/dev/null 2>&1") == 0; }

uint64_t file_size(const std::string& path) {
    struct stat st{};
    if (::stat(path.c_str(), &st) != 0) return 0;
    return static_cast<uint64_t>(st.st_size);
}

// "2026-08-15" and "142317", for <root>/<date>/<time>-<SN>.mp4.
//
// Date directories because a day's takes belong together, and the serial in
// the filename because two cameras on two days is the case that makes a flat
// undated directory useless. Local time, not UTC: someone looking for "the
// recording from this morning" means their morning.
//
// Seconds, not just HHMM, because two takes inside one minute is completely
// ordinary - stop, check the framing, start again - and at minute resolution
// the second one silently overwrites the first. Found by doing exactly that.
void stamp(std::string* date, std::string* time_of_day) {
    const std::time_t t = std::time(nullptr);
    std::tm tm{};
    ::localtime_r(&t, &tm);
    char d[16], h[16];
    std::strftime(d, sizeof d, "%Y-%m-%d", &tm);
    std::strftime(h, sizeof h, "%H%M%S", &tm);
    *date = d;
    *time_of_day = h;
}

// The tail of ffmpeg's stderr, for the `encoder_failed` message. Bounded,
// because an ffmpeg that failed on its very first argument can still produce
// a usage screen far longer than anything a UI should try to display.
std::string tail_of(const std::string& path, size_t max_bytes = 600) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f) return {};
    const std::streamoff size = f.tellg();
    const std::streamoff from = size > static_cast<std::streamoff>(max_bytes)
                                    ? size - static_cast<std::streamoff>(max_bytes)
                                    : 0;
    f.seekg(from);
    std::string s((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    // Collapse to one line: this ends up in a JSON ack and then in a toast.
    for (char& c : s) {
        if (c == '\n' || c == '\r') c = ' ';
    }
    return s;
}

}  // namespace

Recorder::~Recorder() { shutdown(); }

void Recorder::configure(const RecordConfig& cfg) {
    std::lock_guard<std::mutex> g(mu_);
    cfg_ = cfg;
}

uint64_t Recorder::free_bytes(const std::string& path) {
    return fsutil::free_bytes(path);
}

// Card ordering is not stable across boots, so hw:2,0 is a bug waiting for a
// reboot. /proc/asound/cards maps a stable ID string to the index; ALSA
// accepts that ID directly, so plughw:Lite,0 keeps working when the index moves.
//
// Format of the file is two lines per card:
//     2 [Lite           ]: USB-Audio - OBSBOT Tiny 2 Lite
//                          Remo Tech Co., Ltd. OBSBOT Tiny 2 Lite at usb-...
std::string Recorder::alsa_device_for_camera() {
    std::ifstream f("/proc/asound/cards");
    if (!f) return {};
    std::string line;
    while (std::getline(f, line)) {
        const size_t lb = line.find('[');
        const size_t rb = line.find(']', lb == std::string::npos ? 0 : lb);
        if (lb == std::string::npos || rb == std::string::npos) continue;

        std::string id = line.substr(lb + 1, rb - lb - 1);
        while (!id.empty() && id.back() == ' ') id.pop_back();
        while (!id.empty() && id.front() == ' ') id.erase(id.begin());

        // The model name is on this line or the detail line beneath it.
        std::string haystack = line;
        std::string detail;
        if (std::getline(f, detail)) haystack += " " + detail;
        for (char& c : haystack) c = static_cast<char>(::tolower(c));

        if (haystack.find("obsbot") != std::string::npos && !id.empty()) {
            // plughw, not hw: the plug layer converts sample rate, format and
            // channel count, so the recorder does not have to match whatever
            // this particular microphone happens to offer natively.
            return "plughw:" + id + ",0";
        }
    }
    return {};
}

RecordMode mode_from_string(const std::string& v) {
    if (v == "video") return RecordMode::Video;
    if (v == "audio") return RecordMode::Audio;
    // Anything else, including "" and a typo, is Both. A malformed request
    // should not cost the operator a take.
    return RecordMode::Both;
}

const char* mode_to_string(RecordMode m) {
    switch (m) {
        case RecordMode::Video: return "video";
        case RecordMode::Audio: return "audio";
        case RecordMode::Both:  break;
    }
    return "both";
}

CmdResult Recorder::start(DeviceManager* mgr, const std::string& device_id, RecordMode mode) {
    if (mgr == nullptr) return {false, "no_device", "no device manager"};

    std::lock_guard<std::mutex> g(mu_);
    if (active_.load()) {
        return {false, "already_recording", "a recording is already running"};
    }

    // Empty device_id means the on-air camera, per the contract.
    std::string sn = device_id.empty() ? mgr->active_sn() : device_id;
    if (sn.empty()) return {false, "no_device", "nothing is on air"};
    if (mgr->capture_for(sn) == nullptr) {
        return {false, "no_device", "no capture for " + sn};
    }

    if (!have_ffmpeg()) {
        return {false, "encoder_failed", "ffmpeg is not on PATH"};
    }

    std::string date, hhmm;
    stamp(&date, &hhmm);
    const std::string dir = cfg_.root + "/" + date;
    if (!fsutil::make_dirs(dir)) {
        return {false, "encoder_failed", "cannot create " + dir};
    }

    // Check space against the directory that will actually hold the file, not
    // the configured root, in case the root is a mount point and the date
    // directory is not.
    const uint64_t avail = free_bytes(dir);
    if (avail < cfg_.min_free_bytes) {
        char m[160];
        std::snprintf(m, sizeof m, "%.1f GiB free, need %.1f GiB",
                      avail / 1073741824.0, cfg_.min_free_bytes / 1073741824.0);
        return {false, "no_space", m};
    }

    const bool want_video = mode != RecordMode::Audio;
    const bool want_audio = mode != RecordMode::Video;

    // Resolve the microphone before choosing a filename, because in Audio
    // mode a missing one means there is no recording to make.
    std::string alsa;
    if (want_audio) {
        alsa = alsa_device_for_camera();
        if (alsa.empty()) {
            if (mode == RecordMode::Audio) {
                // Hard failure here, unlike Both. There is nothing left to
                // capture, and starting anyway would write an empty file that
                // looks like a successful take until someone plays it.
                LOGW("record: audio-only asked for but the camera exposes no "
                     "ALSA capture device");
                return {false, "audio_unavailable",
                        "this camera exposes no microphone"};
            }
            LOGW("record: audio asked for but the camera exposes no ALSA capture device"
                 "  -  recording silent");
        }
    }
    const bool with_audio = !alsa.empty();

    // An MP4 with no video track is legal and confusing: it opens in a video
    // player as a black rectangle with sound. Name it for what it holds.
    const char* ext = want_video ? ".mp4" : ".m4a";
    const std::string path = dir + "/" + hhmm + "-" + sn + ext;
    const std::string errlog = path + ".ffmpeg.log";

    // Audio-only opens no pipe and runs no pump thread. There is no video to
    // carry, and an encoder fed nothing is an encoder paid for nothing: this
    // mode costs roughly 57 MB an hour against 3.7 GB for video, which is the
    // whole reason it exists.
    int fds[2] = {-1, -1};
    if (want_video && ::pipe(fds) != 0) {
        return {false, "encoder_failed", std::string("pipe() failed: ") + std::strerror(errno)};
    }

    const std::string fps = std::to_string(cfg_.fps);
    const std::string bitrate = std::to_string(cfg_.bitrate_kbps) + "k";
    const std::string maxrate = std::to_string(cfg_.bitrate_kbps * 13 / 10) + "k";
    // One keyframe every two seconds. In a fragmented MP4 the fragment
    // boundary follows the keyframe, so this is also how much of the tail is
    // at risk when the process dies.
    const std::string gop = std::to_string(cfg_.fps * 2);

    std::vector<std::string> args = {
        "ffmpeg", "-hide_banner", "-loglevel", "warning", "-nostdin",
    };
    auto add = [&args](std::initializer_list<const char*> xs) {
        for (const char* x : xs) args.emplace_back(x);
    };
    if (want_video) {
        // Video in: the JPEGs the bridge already holds. Not /dev/video*.
        add({"-f", "mjpeg", "-framerate"});
        args.emplace_back(fps);
        add({"-i", "pipe:0"});
    }
    if (with_audio) {
        // No -ac or -ar here. Before -i those are INPUT constraints, and a raw
        // hw: device must be opened at exactly what the hardware offers. This
        // camera's mic is stereo-only at 32kHz (see /proc/asound/cardN/stream0),
        // so "-ac 1" made ALSA refuse with "cannot set channel count to 1" and
        // ffmpeg exited before writing a byte. alsa_device_for_camera() returns
        // a plughw: device, whose plug layer converts rate, format and channel
        // count on the way through, so the input needs no constraints at all
        // and a different camera with different native parameters still works.
        add({"-f", "alsa", "-i"});
        args.emplace_back(alsa);
    } else {
        add({"-an"});
    }

    if (want_video) {
        add({"-c:v"});
        args.emplace_back(cfg_.encoder);
        if (cfg_.encoder.find("nvenc") != std::string::npos) {
            add({"-preset", "p4"});
        }
        // MJPEG from this camera decodes to YUV422P and NVENC takes only 4:2:0.
        // The error it gives is "No capable devices found", which reads like a
        // missing GPU and is really a pixel format.
        add({"-pix_fmt", "yuv420p"});
        args.insert(args.end(), {
            "-b:v", bitrate, "-maxrate", maxrate, "-bufsize", bitrate,
            "-g", gop, "-r", fps, "-s", cfg_.size,
        });
    } else {
        add({"-vn"});
    }
    if (with_audio) {
        // Downmix here instead: after -i this is an OUTPUT option, done in
        // software, so it works whatever the microphone offers. Mono because
        // this is a speaker in a hall, not music, and a second identical
        // channel is bytes for nothing.
        add({"-c:a", "aac", "-ac", "1", "-b:a"});
        args.emplace_back(std::to_string(cfg_.audio_bitrate_kbps) + "k");
        // Stop when the video ends. Without this the ALSA input keeps the
        // process alive after stdin closes and stop() has to resort to a
        // signal, which is exactly when a moov atom goes missing. Meaningless
        // in audio-only, where ALSA is the only input and stop() signals.
        if (want_video) add({"-shortest"});
    }
    if (!want_video) {
        // frag_keyframe cuts a fragment at each video keyframe, and audio-only
        // has none, so without an explicit cadence the whole take would be one
        // fragment and a power cut would take all of it.
        add({"-frag_duration", "2000000"});  // 2s, matching the video GOP
    }
    args.insert(args.end(), {
        // Fragmented MP4: an index per fragment rather than one written on
        // close. A recording killed by a power cut stays playable up to the
        // last flushed fragment instead of being a total loss.
        "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
        // Fragmenting alone leaves the fragments in ffmpeg's 8 MiB IO buffer.
        // Without this the file stayed at 28 bytes and then jumped by exactly
        // 8388608; with it the header reaches disk at once and a silent
        // recording grows every couple of seconds, as the GOP implies.
        //
        // This is not only about the byte count the remote shows as a live
        // readout. A fragment still sitting in memory is a fragment a power
        // cut destroys, and this machine cannot boot unattended after one.
        //
        // KNOWN ISSUE: with audio muxed, nothing still reaches disk for about
        // eleven seconds and then arrives in one lump, so the guarantee above
        // does not yet hold for the audio path. Measured both ways on the same
        // build. The ALSA input logs buffer xruns, which points at it, but
        // -max_interleave_delta 0 did not change the behaviour, so the cause
        // is not simply the muxer waiting to interleave.
        "-flush_packets", "1",
        // The mp4 muxer writes .m4a too; the extension is what tells a player
        // and a human that there is no picture in it.
        "-f", "mp4", path,
    });

    const int pid = ::fork();
    if (pid < 0) {
        if (fds[0] >= 0) { ::close(fds[0]); ::close(fds[1]); }
        return {false, "encoder_failed", std::string("fork() failed: ") + std::strerror(errno)};
    }
    if (pid == 0) {
        if (fds[0] >= 0) {
            ::dup2(fds[0], STDIN_FILENO);
            ::close(fds[0]);
            ::close(fds[1]);
        }
        // stderr to a file beside the recording: it is both the source of the
        // encoder_failed message and something the operator can read later.
        const int elog = ::open(errlog.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (elog >= 0) { ::dup2(elog, STDERR_FILENO); ::close(elog); }
        std::vector<char*> argv;
        argv.reserve(args.size() + 1);
        for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
        ::execvp("ffmpeg", argv.data());
        ::_exit(127);
    }

    if (fds[0] >= 0) ::close(fds[0]);

    // Give the child a moment to reject its arguments. Reporting
    // encoder_failed now is far better than accepting the start and having the
    // UI show a recording that was never running.
    std::this_thread::sleep_for(std::chrono::milliseconds(400));
    int wstatus = 0;
    if (::waitpid(pid, &wstatus, WNOHANG) == pid) {
        if (fds[1] >= 0) ::close(fds[1]);
        const std::string why = tail_of(errlog);
        LOGW("record: ffmpeg exited immediately: %s", why.c_str());
        return {false, "encoder_failed", why.empty() ? "ffmpeg exited immediately" : why};
    }

    child_stdin_ = fds[1];
    child_pid_ = pid;
    device_id_ = sn;
    path_ = path;
    error_.clear();
    audio_ = with_audio;
    video_ = want_video;
    started_ = std::chrono::steady_clock::now();
    started_at_ms_ = now_ms();
    active_.store(true);
    if (want_video) {
        pumping_.store(true);
        pump_ = std::thread([this, mgr] { pump(mgr); });
    }

    if (want_video) {
        LOGI("record: %s %s@%dfps %dkbps%s -> %s",
             cfg_.encoder.c_str(), cfg_.size.c_str(), cfg_.fps, cfg_.bitrate_kbps,
             with_audio ? " +aac" : " (silent)", path.c_str());
    } else {
        LOGI("record: audio only, aac %dkbps -> %s",
             cfg_.audio_bitrate_kbps, path.c_str());
    }
    return {true, "", path};
}

void Recorder::pump(DeviceManager* mgr) {
    const auto interval = std::chrono::microseconds(1000000 / (cfg_.fps > 0 ? cfg_.fps : 25));
    auto next = std::chrono::steady_clock::now();
    uint64_t last_seq = 0;
    std::vector<uint8_t> frame;

    // Pin to the camera the recording started on. Unlike the H.264 preview
    // stream, a recording must NOT follow a TAKE: a file that silently
    // switches camera partway through is not what anyone asked for.
    std::string sn;
    {
        std::lock_guard<std::mutex> g(mu_);
        sn = device_id_;
    }

    while (pumping_.load()) {
        next += interval;
        std::this_thread::sleep_until(next);

        VideoCapture* cap = mgr->capture_for(sn);
        if (cap == nullptr) continue;

        const uint64_t seq = cap->frame_seq();
        if (seq == last_seq) continue;
        last_seq = seq;

        frame = cap->latest_jpeg();
        if (frame.empty()) continue;

        size_t off = 0;
        while (off < frame.size() && pumping_.load()) {
            const ssize_t n = ::write(child_stdin_, frame.data() + off, frame.size() - off);
            if (n > 0) { off += static_cast<size_t>(n); continue; }
            if (n < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            // ffmpeg died mid-take. Record why and surface it: a recording
            // that stopped without anyone noticing is the worst outcome here,
            // which is why `error` stays set until the next start.
            {
                std::lock_guard<std::mutex> g(mu_);
                error_ = n < 0 ? std::strerror(errno) : "encoder exited";
                LOGW("record: %s  -  recording stopped at %s",
                     error_.c_str(), path_.c_str());
            }
            pumping_.store(false);
            active_.store(false);
            mgr->notify_state_changed();
            return;
        }
    }
}

CmdResult Recorder::stop() {
    std::string path;
    {
        std::lock_guard<std::mutex> g(mu_);
        if (!active_.load() && !pump_.joinable()) {
            return {false, "not_recording", "nothing is recording"};
        }
        path = path_;
    }

    pumping_.store(false);
    if (pump_.joinable()) pump_.join();

    const bool had_pipe = child_stdin_ >= 0;
    if (child_stdin_ >= 0) { ::close(child_stdin_); child_stdin_ = -1; }
    if (child_pid_ > 0) {
        // Audio-only has no stdin, so there is no EOF to wait for: ALSA would
        // keep the process alive until the 5s timeout below and then take a
        // SIGTERM, which is exactly the path that risks the tail. Ask it to
        // finish now instead. ffmpeg treats SIGINT as "stop cleanly and write
        // the trailer", which is what stopping a recording means.
        if (!had_pipe) ::kill(child_pid_, SIGINT);
        // Closing stdin makes ffmpeg finish its last fragment and exit. Only
        // reach for a signal if it will not: SIGTERM here risks the tail of
        // the file, which is the whole reason for the wait.
        bool reaped = false;
        for (int i = 0; i < 50; ++i) {
            if (::waitpid(child_pid_, nullptr, WNOHANG) == child_pid_) { reaped = true; break; }
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        if (!reaped) {
            LOGW("record: ffmpeg did not exit within 5s  -  signalling");
            ::kill(child_pid_, SIGTERM);
            ::waitpid(child_pid_, nullptr, 0);
        }
        child_pid_ = -1;
    }

    active_.store(false);

    const uint64_t bytes = file_size(path);
    std::lock_guard<std::mutex> g(mu_);
    LOGI("record: stopped, %.1f MiB at %s", bytes / 1048576.0, path.c_str());
    return {true, "", path};
}

nlohmann::json Recorder::status() const {
    std::lock_guard<std::mutex> g(mu_);
    const bool on = active_.load();
    const uint64_t elapsed =
        on ? static_cast<uint64_t>(
                 std::chrono::duration_cast<std::chrono::seconds>(
                     std::chrono::steady_clock::now() - started_).count())
           : 0;
    return nlohmann::json{
        {"active", on},
        {"device_id", device_id_},
        {"started_at_ms", started_at_ms_},
        // Authoritative from here rather than counted on the client, so a
        // phone that reconnects mid-take shows the true elapsed time.
        {"elapsed_s", elapsed},
        {"bytes", file_size(path_)},
        {"path", path_},
        // What this take is doing. These can differ from the preference: in
        // Both mode a missing microphone downgrades to a silent recording
        // rather than losing the take, so an operator who thinks they are
        // capturing sound has to be able to see that they are not.
        {"audio", audio_},
        {"video", video_},
        // What the next one will capture, and whether a microphone exists.
        {"mode", mode_to_string(mode_pref_)},
        {"audio_available", !alsa_device_for_camera().empty()},
        {"disk_free_bytes", fsutil::free_bytes(cfg_.root)},
        {"error", error_},
    };
}

void Recorder::set_mode(RecordMode m) {
    std::lock_guard<std::mutex> g(mu_);
    mode_pref_ = m;
}

RecordMode Recorder::mode() const {
    std::lock_guard<std::mutex> g(mu_);
    return mode_pref_;
}

bool Recorder::audio_available() { return !alsa_device_for_camera().empty(); }

void Recorder::shutdown() {
    if (active_.load() || pump_.joinable()) {
        (void)stop();
    }
}

}  // namespace obs
