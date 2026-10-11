#include "mjpeg_server.h"
#include "device_manager.h"
#include "video_capture.h"
#include "auth.h"
#include "log.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>   // TCP_NODELAY
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>
#endif

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace obs {

// The few places Winsock and BSD sockets disagree. The server logic below is
// identical on every platform; only these spellings change.
#ifdef _WIN32
using sock_t = SOCKET;
static constexpr sock_t kNoSocket = INVALID_SOCKET;
static void close_sock(sock_t s) { ::closesocket(s); }
static int sock_err() { return ::WSAGetLastError(); }
static std::string sock_errstr(int e) { return "WSA error " + std::to_string(e); }
#define SHUT_RDWR SD_BOTH
#else
using sock_t = int;
static constexpr sock_t kNoSocket = -1;
static void close_sock(sock_t s) { ::close(s); }
static int sock_err() { return errno; }
static std::string sock_errstr(int e) { return std::strerror(e); }
#endif

struct MjpegServer::Impl {
    sock_t listen_fd = kNoSocket;
    std::atomic<bool> running{false};
    std::thread accept_thr;
    DeviceManager* mgr = nullptr;
    AuthStore* auth = nullptr;
};

MjpegServer::MjpegServer() : impl_(new Impl) {}
MjpegServer::~MjpegServer() { stop(); delete impl_; }
bool MjpegServer::running() const { return impl_->running; }

// MSG_NOSIGNAL is the Linux way to keep a write to a closed socket from
// raising SIGPIPE; macOS spells the same guarantee SO_NOSIGPIPE, set once per
// socket in serve_client below. main.cpp also ignores SIGPIPE process-wide, so
// this is belt and braces on both platforms.
#ifndef MSG_NOSIGNAL
#define MSG_NOSIGNAL 0
#endif

static bool send_all(sock_t fd, const char* data, size_t n) {
    while (n > 0) {
        // Winsock takes an int length; one JPEG is far below 2 GB, but clamp
        // so a huge buffer is sent in pieces rather than truncated.
        int chunk = n > (1u << 30) ? (1 << 30) : (int)n;
        auto w = ::send(fd, data, chunk, MSG_NOSIGNAL);
        if (w <= 0) return false;
        data += w; n -= (size_t)w;
    }
    return true;
}

static std::string extract_token_from_url(const char* req) {
    const char* p = std::strstr(req, "?t=");
    if (!p) return "";
    p += 3;
    std::string out;
    while (*p && *p != ' ' && *p != '&' && *p != '\r' && *p != '\n') { out += *p++; }
    return out;
}

// Pull the request target (the path, without query string) out of the request
// line, e.g. "GET /preview/RMOW1234.mjpg?t=abc HTTP/1.1" -> "/preview/RMOW1234.mjpg".
static std::string extract_path(const char* req) {
    const char* sp = std::strchr(req, ' ');
    if (!sp) return "";
    const char* start = sp + 1;
    const char* end = start;
    while (*end && *end != ' ' && *end != '?' && *end != '\r' && *end != '\n') ++end;
    return std::string(start, end);
}

// The client's User-Agent, truncated, for the connect log line. The bridge
// window reads it to tell OBS (ffmpeg's "Lavf/..." from a Media Source, or
// "OBS/..." from a Browser Source) apart from a phone remote, which pulls the
// same active.mjpg for its program preview.
static std::string extract_user_agent(const char* req) {
    const char* p = std::strstr(req, "\nUser-Agent:");
    if (!p) p = std::strstr(req, "\nuser-agent:");
    if (!p) return "-";
    p += 12;
    while (*p == ' ') ++p;
    std::string out;
    while (*p && *p != '\r' && *p != '\n' && out.size() < 60) {
        out += (*p == ' ') ? '_' : *p;   // one token, so the log stays parseable
        ++p;
    }
    return out.empty() ? "-" : out;
}

// Resolve the requested path to a camera "key": "active" for the active
// stream, or a serial number for a specific camera. Returns false if the path
// is not a preview path at all.
static bool parse_preview_key(const std::string& path, std::string& key) {
    if (path == "/preview.mjpeg") { key = "active"; return true; }  // legacy alias
    const std::string prefix = "/preview/";
    const std::string suffix = ".mjpg";
    if (path.size() > prefix.size() + suffix.size() &&
        path.compare(0, prefix.size(), prefix) == 0 &&
        path.compare(path.size() - suffix.size(), suffix.size(), suffix) == 0) {
        key = path.substr(prefix.size(),
                          path.size() - prefix.size() - suffix.size());
        return !key.empty();
    }
    return false;
}

static void send_simple(sock_t fd, const char* status_line, const char* body) {
    std::string resp = std::string("HTTP/1.1 ") + status_line + "\r\n"
        "Content-Type: text/plain\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: close\r\n\r\n";
    if (body) resp += body;
    send_all(fd, resp.data(), resp.size());
}

// Size and luma sampling of a JPEG, from its SOF marker. Used to keep one
// format per active.mjpg connection; see jpeg_conform in video_capture.h.
struct JpegFormat {
    int w = 0, h = 0, hs = 0, vs = 0;
    bool operator==(const JpegFormat& o) const {
        return w == o.w && h == o.h && hs == o.hs && vs == o.vs;
    }
};

static bool jpeg_format(const std::vector<uint8_t>& j, JpegFormat& f) {
    size_t i = 2;
    while (i + 11 < j.size()) {
        if (j[i] != 0xFF) { ++i; continue; }
        const uint8_t m = j[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
            f.h = (j[i + 5] << 8) | j[i + 6];
            f.w = (j[i + 7] << 8) | j[i + 8];
            f.hs = j[i + 11] >> 4;
            f.vs = j[i + 11] & 0x0F;
            return true;
        }
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
        i += 2 + ((j[i + 2] << 8) | j[i + 3]);
    }
    return false;
}

// True once `cap` has produced at least one frame.
static bool has_frame(VideoCapture* cap) {
    return cap && cap->running() && cap->frame_seq() > 0;
}

static void serve_client(sock_t fd, DeviceManager* mgr, AuthStore* auth) {
    char buf[2048];
    auto n = ::recv(fd, buf, (int)sizeof(buf) - 1, 0);
    if (n <= 0) { close_sock(fd); return; }
    buf[n] = 0;

    // Hard-fail any TCP write that takes longer than 5 s. macOS's default
    // retransmit-then-give-up is ~15 min; that timer was leaving wedged
    // MJPEG threads + fds alive when the phone roamed Wi-Fi / backgrounded /
    // dropped NAT state (the "preview stops mid-stream with no error"
    // symptom). SO_KEEPALIVE probes the peer, SO_NOSIGPIPE avoids relying on
    // the per-process SIGPIPE handler in main.cpp.
    int yes2 = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, (const char*)&yes2, sizeof(yes2));
#ifdef _WIN32
    // Winsock takes the send timeout as a DWORD of milliseconds, not a timeval.
    DWORD tv = 5000;
#else
    struct timeval tv{5, 0};
#endif
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, (const char*)&tv, sizeof(tv));
#ifdef SO_NOSIGPIPE
    // macOS and the BSDs only. Linux has no such socket option; send_all
    // passes MSG_NOSIGNAL on every write instead, which is the same guarantee
    // applied per call rather than per socket.
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes2, sizeof(yes2));
#endif
    // Disable Nagle. Each frame goes out as a boundary + header + JPEG in
    // separate send_all calls, and Nagle holds the small writes back waiting
    // to coalesce with the next one - it delays the frame the consumer is
    // already waiting for. A live stream wants every byte on the wire now,
    // which is the whole reason TCP_NODELAY exists.
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, (const char*)&yes2, sizeof(yes2));

    // CORS preflight.
    if (std::strstr(buf, "OPTIONS ") == buf) {
        const char* resp =
            "HTTP/1.1 204 No Content\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
            "Access-Control-Allow-Headers: *\r\n"
            "Connection: close\r\n\r\n";
        send_all(fd, resp, std::strlen(resp));
        close_sock(fd);
        return;
    }

    std::string path = extract_path(buf);
    std::string key;
    if (!parse_preview_key(path, key)) {
        send_simple(fd, "404 Not Found", nullptr);
        close_sock(fd);
        return;
    }

    if (auth) {
        std::string tok = extract_token_from_url(buf);
        if (!auth->is_valid_token(tok)) {
            send_simple(fd, "401 Unauthorized", "missing or invalid ?t= token");
            close_sock(fd);
            return;
        }
    }

    const bool follow_active = (key == "active");

    // Resolver: which VideoCapture do we pull from right now? For the active
    // stream this is re-evaluated every frame so the source can swap
    // mid-stream (OBS keeps its connection; a brief frozen frame is fine).
    auto resolve = [mgr, follow_active, &key]() -> VideoCapture* {
        if (follow_active) {
            std::string sn = mgr->active_sn();
            return sn.empty() ? nullptr : mgr->capture_for(sn);
        }
        return mgr->capture_for(key);
    };

    // Unknown SN (specific stream) -> 404, before we commit to a 200.
    if (!follow_active && mgr->capture_for(key) == nullptr) {
        send_simple(fd, "404 Not Found", "no camera with that serial");
        close_sock(fd);
        return;
    }

    // Wait briefly for a first frame so a just-attached or waking camera can
    // connect, but do NOT wedge the thread: a camera with no frames (asleep,
    // privacy) gets a prompt 503.
    const auto first_frame_deadline =
        std::chrono::steady_clock::now() + std::chrono::milliseconds(1500);
    while (!has_frame(resolve())) {
        if (std::chrono::steady_clock::now() >= first_frame_deadline) {
            send_simple(fd, "503 Service Unavailable",
                        "camera has no video yet (asleep or starting)");
            close_sock(fd);
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    const char* hdr =
        "HTTP/1.1 200 OK\r\n"
        "Cache-Control: no-cache, no-store, private\r\n"
        "Pragma: no-cache\r\n"
        "Connection: close\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
        "Access-Control-Allow-Headers: *\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=obsboundary\r\n\r\n";
    if (!send_all(fd, hdr, std::strlen(hdr))) { close_sock(fd); return; }

    LOGI("mjpeg: client connected fd=%d path=%s ua=%s", (int)fd, path.c_str(),
         extract_user_agent(buf).c_str());

    uint64_t last_seq = 0;
    VideoCapture* last_cap = nullptr;
    JpegFormat stream_fmt;   // format of this connection's first frame
    bool have_fmt = false;
    // Frame pacing is driven by the CAMERA, not by this loop: a new frame is
    // sent the moment frame_seq ticks, and `poll` is only how often we check.
    // The old design slept 50ms after every send - a hard ~20fps ceiling that
    // capped a 30fps camera at 18-19fps no matter how fast the encoder was.
    // `fade_tick` paces dissolve re-renders of the SAME camera frame during a
    // crossfade (each one is a decode+blend+encode; 100Hz of those is waste).
    //
    // No deadline: this loop used to self-terminate after 2 hours, which is
    // exactly the "stream freezes after an hour or two and needs a manual
    // refresh in OBS" a real 3+ hour live service hit - OBS's Browser Source
    // never reconnects on stream end. A healthy stream must outlive the
    // service; dead peers are reaped by SO_SNDTIMEO/keepalive, wedged sends
    // break out of send_all, and detached specific-SN cameras end the stream
    // explicitly below.
    const auto poll = std::chrono::milliseconds(10);
    const auto fade_tick = std::chrono::milliseconds(33);

    while (true) {
        VideoCapture* cap = resolve();
        if (cap == nullptr) {
            // Active stream with no live camera right now: keep the connection
            // open (OBS holds it); the client shows its last frame frozen.
            std::this_thread::sleep_for(poll);
            continue;
        }
        // A specific-SN stream whose camera detached must END, not freeze:
        // detach() stops the capture but keeps the object (pointer
        // stability for these threads), so frame_seq() goes quiet and this
        // loop would otherwise spin silently until the 2h deadline -
        // holding the thread + socket while the phone shows a frozen frame
        // with no error. Ending the stream fires the client's error /
        // reconnect path instead. The follow-active stream keeps its
        // freeze-and-swap behaviour: OBS holds that connection across cuts
        // by design. (Cross-review finding, corroborated by both external
        // reviewers.)
        if (!follow_active && !cap->running()) {
            LOGI("mjpeg: camera for %s detached; ending stream fd=%d",
                 key.c_str(), (int)fd);
            break;
        }
        if (cap != last_cap) {
            // Source swapped (active camera changed, or first pull). Reset the
            // seq tracker so the new source's current frame is sent right away.
            last_cap = cap;
            last_seq = 0;
        }
        // Program transition: while a fade is running, dissolve the frozen
        // outgoing frame into the incoming camera's live frames. Only the
        // follow-active stream transitions (a fixed per-SN stream is a monitor).
        // During the window we keep emitting even without a NEW camera frame, so
        // the dissolve animates smoothly regardless of camera fps.
        std::vector<uint8_t> outgoing;
        const float fade = follow_active ? mgr->active_fade(outgoing) : 1.0f;
        const bool fading = fade < 1.0f;

        auto seq = cap->frame_seq();
        if (seq == last_seq && !fading) {
            std::this_thread::sleep_for(poll);
            continue;
        }
        auto jpeg = cap->latest_jpeg();
        if (jpeg.empty()) {
            std::this_thread::sleep_for(poll);
            continue;
        }
        last_seq = seq;
        if (fading) {
            // Crossfade from the outgoing camera; fall back to fade-from-black on
            // the first take, when there is no outgoing frame to dissolve from.
            jpeg = outgoing.empty()
                       ? obs::jpeg_darken(jpeg, fade)
                       : obs::jpeg_crossfade(outgoing, jpeg, fade);
        }
        // Pin the follow-active stream to its first frame's size and chroma
        // format. OBS's Media Source crashes in swscale when either changes
        // mid-stream, which a TAKE between unlike cameras (or a fade frame
        // encoded differently from the camera's JPEG) would otherwise do. A
        // per-SN stream never changes source, so it is left alone.
        if (follow_active) {
            JpegFormat f;
            if (jpeg_format(jpeg, f)) {
                if (!have_fmt) {
                    stream_fmt = f;
                    have_fmt = true;
                } else if (!(f == stream_fmt)) {
                    jpeg = obs::jpeg_conform(jpeg, stream_fmt.w, stream_fmt.h,
                                             stream_fmt.hs, stream_fmt.vs);
                    if (jpeg.empty()) {   // could not conform: drop, never crash OBS
                        std::this_thread::sleep_for(poll);
                        continue;
                    }
                }
            }
        }

        std::string part = "--obsboundary\r\n"
                           "Content-Type: image/jpeg\r\n"
                           "Content-Length: " + std::to_string(jpeg.size()) +
                           "\r\n\r\n";
        if (!send_all(fd, part.data(), part.size())) break;
        if (!send_all(fd, reinterpret_cast<const char*>(jpeg.data()), jpeg.size())) break;
        if (!send_all(fd, "\r\n", 2)) break;
        // No sleep after a real frame - the seq check above is the pacer. Only
        // dissolve re-renders (same frame, new blend factor) are throttled.
        if (fading) std::this_thread::sleep_for(fade_tick);
    }

    LOGI("mjpeg: client disconnected fd=%d path=%s", (int)fd, path.c_str());
    close_sock(fd);
}

bool MjpegServer::start(uint16_t port, DeviceManager* mgr, AuthStore* auth,
                        const std::string& bindaddr) {
    if (impl_->running) return true;
    impl_->mgr = mgr;
    impl_->auth = auth;

#ifdef _WIN32
    // Asio initialises Winsock too, but only once the WS server starts, which
    // is after this. WSAStartup is reference-counted, so calling it twice is
    // the documented way to share it.
    WSADATA wsa;
    if (::WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        LOGE("mjpeg: WSAStartup failed");
        return false;
    }
#endif
    sock_t fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd == kNoSocket) { LOGE("mjpeg: socket failed: %s", sock_errstr(sock_err()).c_str()); return false; }

    int yes = 1;
#ifdef _WIN32
    // SO_REUSEADDR on Windows lets a second process steal a port that is in
    // active use, which is not what it means on POSIX. Exclusive use is the
    // safe equivalent: a stale bridge makes bind fail loudly instead.
    ::setsockopt(fd, SOL_SOCKET, SO_EXCLUSIVEADDRUSE, (const char*)&yes, sizeof(yes));
#else
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#endif

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    if (bindaddr.empty() || bindaddr == "0.0.0.0") {
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
    } else if (::inet_pton(AF_INET, bindaddr.c_str(), &addr.sin_addr) != 1) {
        LOGE("mjpeg: bad bind address '%s'", bindaddr.c_str());
        close_sock(fd);
        return false;
    }

    if (::bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        LOGE("mjpeg: bind :%u failed: %s", (unsigned)port, sock_errstr(sock_err()).c_str());
        close_sock(fd);
        return false;
    }
    if (::listen(fd, 8) < 0) {
        LOGE("mjpeg: listen failed: %s", sock_errstr(sock_err()).c_str());
        close_sock(fd);
        return false;
    }

    impl_->listen_fd = fd;
    impl_->running = true;
    impl_->accept_thr = std::thread([this]{
        while (impl_->running) {
            sockaddr_in cli{};
            socklen_t cli_len = sizeof(cli);
            sock_t c = ::accept(impl_->listen_fd, (sockaddr*)&cli, &cli_len);
            if (c == kNoSocket) {
#ifndef _WIN32
                if (errno == EINTR || errno == EAGAIN) continue;
#endif
                if (impl_->running) {
                    LOGW("mjpeg: accept failed: %s", sock_errstr(sock_err()).c_str());
                }
                break;
            }
            try {
                std::thread(serve_client, c, impl_->mgr, impl_->auth).detach();
            } catch (const std::exception& e) {
                LOGW("mjpeg: thread spawn failed fd=%d, leaked-or-closed: %s", (int)c, e.what());
                close_sock(c);
            }
        }
    });

    LOGI("mjpeg server listening on %s:%u  /preview/<sn>.mjpg  /preview/active.mjpg",
         bindaddr.empty() ? "0.0.0.0" : bindaddr.c_str(), (unsigned)port);
    return true;
}

void MjpegServer::stop() {
    if (!impl_->running) return;
    impl_->running = false;
    if (impl_->listen_fd != kNoSocket) {
        ::shutdown(impl_->listen_fd, SHUT_RDWR);
        close_sock(impl_->listen_fd);
        impl_->listen_fd = kNoSocket;
    }
    if (impl_->accept_thr.joinable()) impl_->accept_thr.join();
}

}  // namespace obs
