#include "mjpeg_server.h"
#include "device_manager.h"
#include "video_capture.h"
#include "auth.h"
#include "log.h"
#include "preview_params.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>   // TCP_NODELAY
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <functional>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

namespace obs {

struct MjpegServer::Impl {
    int listen_fd = -1;
    std::atomic<bool> running{false};
    std::thread accept_thr;
    DeviceManager* mgr = nullptr;
    AuthStore* auth = nullptr;
};

MjpegServer::MjpegServer() : impl_(new Impl) {}
MjpegServer::~MjpegServer() { stop(); delete impl_; }
bool MjpegServer::running() const { return impl_->running; }

static bool send_all(int fd, const char* data, size_t n) {
    while (n > 0) {
        ssize_t w = ::send(fd, data, n, 0);
        if (w <= 0) return false;
        data += w; n -= (size_t)w;
    }
    return true;
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

static void send_simple(int fd, const char* status_line, const char* body) {
    std::string resp = std::string("HTTP/1.1 ") + status_line + "\r\n"
        "Content-Type: text/plain\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: close\r\n\r\n";
    if (body) resp += body;
    send_all(fd, resp.data(), resp.size());
}

// True once `cap` has produced at least one frame.
static bool has_frame(VideoCapture* cap) {
    return cap && cap->running() && cap->frame_seq() > 0;
}

// Scope guard for 1 small stream's claim on a camera's shared encode. It
// releases the claim on every exit path, and moves it on a follow-active
// camera swap, so a variant stops as soon as its last stream leaves.
class VariantClaim {
public:
    explicit VariantClaim(const preview::VariantKey& k) : key_(k) {}
    ~VariantClaim() { move_to(nullptr, ""); }
    VariantClaim(const VariantClaim&) = delete;
    VariantClaim& operator=(const VariantClaim&) = delete;

    void move_to(VideoCapture* cap, const std::string& sn) {
        if (cap == cap_) return;
        if (cap_) cap_->release_variant(sn_, key_);
        cap_ = cap;
        sn_ = sn;
        if (cap_) cap_->claim_variant(sn_, key_);
    }

private:
    preview::VariantKey key_;
    VideoCapture* cap_ = nullptr;
    std::string sn_;
};

static int64_t now_us() {
    return std::chrono::duration_cast<std::chrono::microseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

static void serve_client(int fd, DeviceManager* mgr, AuthStore* auth) {
    char buf[2048];
    ssize_t n = ::recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { ::close(fd); return; }
    buf[n] = 0;

    // Hard-fail any TCP write that takes longer than 5 s. macOS's default
    // retransmit-then-give-up is ~15 min; that timer was leaving wedged
    // MJPEG threads + fds alive when the phone roamed Wi-Fi / backgrounded /
    // dropped NAT state (the "preview stops mid-stream with no error"
    // symptom). SO_KEEPALIVE probes the peer, SO_NOSIGPIPE avoids relying on
    // the per-process SIGPIPE handler in main.cpp.
    int yes2 = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes2, sizeof(yes2));
    struct timeval tv{5, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes2, sizeof(yes2));
    // Disable Nagle. Each frame goes out as a boundary + header + JPEG in
    // separate send_all calls, and Nagle holds the small writes back waiting
    // to coalesce with the next one - it delays the frame the consumer is
    // already waiting for. A live stream wants every byte on the wire now,
    // which is the whole reason TCP_NODELAY exists.
    ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes2, sizeof(yes2));

    // CORS preflight.
    if (std::strstr(buf, "OPTIONS ") == buf) {
        const char* resp =
            "HTTP/1.1 204 No Content\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET, OPTIONS\r\n"
            "Access-Control-Allow-Headers: *\r\n"
            "Connection: close\r\n\r\n";
        send_all(fd, resp, std::strlen(resp));
        ::close(fd);
        return;
    }

    std::string path = extract_path(buf);
    std::string key;
    if (!parse_preview_key(path, key)) {
        send_simple(fd, "404 Not Found", nullptr);
        ::close(fd);
        return;
    }

    // `t` may sit at any query position; `w`, `fps`, and `q` ask for a
    // smaller stream (preview_params.h). No parameters = today's stream.
    const preview::Params params = preview::parse_query(
        preview::request_query(std::string_view(buf, (size_t)n)));

    if (auth) {
        if (!auth->is_valid_token(params.token)) {
            send_simple(fd, "401 Unauthorized",
                        "missing or invalid t=<token> query parameter");
            ::close(fd);
            return;
        }
    }

    const bool follow_active = (key == "active");

    // Resolver: which VideoCapture do we pull from right now? For the active
    // stream this is re-evaluated every frame so the source can swap
    // mid-stream (OBS keeps its connection; a brief frozen frame is fine).
    // `sn` gets the serial it resolved, which labels the variant log lines.
    auto resolve = [mgr, follow_active, &key](std::string* sn = nullptr)
        -> VideoCapture* {
        const std::string s = follow_active ? mgr->active_sn() : key;
        if (sn) *sn = s;
        return s.empty() ? nullptr : mgr->capture_for(s);
    };

    // Unknown SN (specific stream) -> 404, before we commit to a 200.
    if (!follow_active && mgr->capture_for(key) == nullptr) {
        send_simple(fd, "404 Not Found", "no camera with that serial");
        ::close(fd);
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
            ::close(fd);
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
    if (!send_all(fd, hdr, std::strlen(hdr))) { ::close(fd); return; }

    LOGI("mjpeg: client connected fd=%d path=%s", fd, path.c_str());

    uint64_t last_seq = 0;
    VideoCapture* last_cap = nullptr;
    // With no `fps`, frame pacing is driven by the CAMERA, not by this loop: a
    // new frame is sent the moment its seq ticks, and `poll` is only how often
    // we check. The old design slept 50ms after every send - a hard ~20fps
    // ceiling that capped a 30fps camera at 18-19fps no matter how fast the
    // encoder was. `fade_tick` paces dissolve re-renders of the SAME camera
    // frame during a crossfade (each one is a decode+blend+encode; 100Hz of
    // those is waste). With `fps` set, the Pacer also holds back any frame,
    // real or dissolve, that would beat the stream's next 1/fps deadline.
    //
    // No deadline: this loop used to self-terminate after 2 hours, which is
    // exactly the "stream freezes after an hour or two and needs a manual
    // refresh in OBS" a real 3+ hour live service hit - OBS's Browser Source
    // never reconnects on stream end. A healthy stream must outlive the
    // service; dead peers are reaped by SO_SNDTIMEO/keepalive, wedged sends
    // break out of send_all, and detached specific-SN cameras end the stream
    // explicitly below.
    //
    // A small stream (`w` and `q` that do not resolve to 1920 and 0.85, see
    // Params::full) reads its camera's shared variant encode instead of the
    // program frame.
    const auto poll = std::chrono::milliseconds(10);
    const auto fade_tick = std::chrono::milliseconds(33);
    const bool full = params.full();
    const preview::VariantKey vkey{params.w, params.q_pct};
    VariantClaim claim(vkey);
    preview::Pacer pacer(params.fps);
    std::string sn;

    while (true) {
        VideoCapture* cap = resolve(&sn);
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
                 key.c_str(), fd);
            break;
        }
        if (cap != last_cap) {
            // Source swapped (active camera changed, or first pull). Reset the
            // seq tracker so the new source's latest frame goes out as soon as
            // the Pacer allows, and move a small stream's claim to the new
            // camera (a variant it starts has a frame from the next capture).
            last_cap = cap;
            last_seq = 0;
            if (!full) claim.move_to(cap, sn);
        }
        // Program transition: while a fade is running, dissolve the frozen
        // outgoing frame into the incoming camera's live frames. Only the
        // follow-active stream transitions (a fixed per-SN stream is a monitor).
        // During the window we keep emitting even without a NEW camera frame, so
        // the dissolve animates smoothly regardless of camera fps.
        std::vector<uint8_t> outgoing;
        const float fade = follow_active ? mgr->active_fade(outgoing) : 1.0f;
        const bool fading = fade < 1.0f;

        auto seq = full ? cap->frame_seq() : cap->variant_seq(vkey);
        if (seq == last_seq && !fading) {
            std::this_thread::sleep_for(poll);
            continue;
        }
        const int64_t now = params.fps > 0 ? now_us() : 0;
        if (!pacer.ready(now)) {
            std::this_thread::sleep_for(poll);
            continue;
        }
        auto jpeg = full ? cap->latest_jpeg() : cap->variant_jpeg(vkey);
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

        std::string part = "--obsboundary\r\n"
                           "Content-Type: image/jpeg\r\n"
                           "Content-Length: " + std::to_string(jpeg.size()) +
                           "\r\n\r\n";
        if (!send_all(fd, part.data(), part.size())) break;
        if (!send_all(fd, reinterpret_cast<const char*>(jpeg.data()), jpeg.size())) break;
        if (!send_all(fd, "\r\n", 2)) break;
        pacer.sent(now);
        // No sleep after a real frame - the seq check and the Pacer above set
        // the rate. Dissolve re-renders (same frame, new blend factor) also
        // wait `fade_tick`, so they never exceed about 30 per second.
        if (fading) std::this_thread::sleep_for(fade_tick);
    }

    LOGI("mjpeg: client disconnected fd=%d path=%s", fd, path.c_str());
    ::close(fd);
}

bool MjpegServer::start(uint16_t port, DeviceManager* mgr, AuthStore* auth) {
    if (impl_->running) return true;
    impl_->mgr = mgr;
    impl_->auth = auth;

    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { LOGE("mjpeg: socket failed: %s", strerror(errno)); return false; }

    int yes = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    if (::bind(fd, (sockaddr*)&addr, sizeof(addr)) < 0) {
        LOGE("mjpeg: bind :%u failed: %s", (unsigned)port, strerror(errno));
        ::close(fd);
        return false;
    }
    if (::listen(fd, 8) < 0) {
        LOGE("mjpeg: listen failed: %s", strerror(errno));
        ::close(fd);
        return false;
    }

    impl_->listen_fd = fd;
    impl_->running = true;
    impl_->accept_thr = std::thread([this]{
        while (impl_->running) {
            sockaddr_in cli{};
            socklen_t cli_len = sizeof(cli);
            int c = ::accept(impl_->listen_fd, (sockaddr*)&cli, &cli_len);
            if (c < 0) {
                if (errno == EINTR || errno == EAGAIN) continue;
                if (impl_->running) {
                    LOGW("mjpeg: accept failed: %s", strerror(errno));
                }
                break;
            }
            try {
                std::thread(serve_client, c, impl_->mgr, impl_->auth).detach();
            } catch (const std::exception& e) {
                LOGW("mjpeg: thread spawn failed fd=%d, leaked-or-closed: %s", c, e.what());
                ::close(c);
            }
        }
    });

    LOGI("mjpeg server listening on 0.0.0.0:%u  /preview/<sn>.mjpg  /preview/active.mjpg",
         (unsigned)port);
    return true;
}

void MjpegServer::stop() {
    if (!impl_->running) return;
    impl_->running = false;
    if (impl_->listen_fd >= 0) {
        ::shutdown(impl_->listen_fd, SHUT_RDWR);
        ::close(impl_->listen_fd);
        impl_->listen_fd = -1;
    }
    if (impl_->accept_thr.joinable()) impl_->accept_thr.join();
}

}  // namespace obs
