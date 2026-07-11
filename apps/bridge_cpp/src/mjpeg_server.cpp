#include "mjpeg_server.h"
#include "device_manager.h"
#include "video_capture.h"
#include "auth.h"
#include "log.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <fcntl.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <functional>
#include <string>
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

    if (auth) {
        std::string tok = extract_token_from_url(buf);
        if (!auth->is_valid_token(tok)) {
            send_simple(fd, "401 Unauthorized", "missing or invalid ?t= token");
            ::close(fd);
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
    const auto period = std::chrono::milliseconds(50);  // ~20 fps
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::hours(2);

    while (std::chrono::steady_clock::now() < deadline) {
        VideoCapture* cap = resolve();
        if (cap == nullptr) {
            // Active stream with no live camera right now: keep the connection
            // open (OBS holds it); the client shows its last frame frozen.
            std::this_thread::sleep_for(period);
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
            // seq tracker so the new source's current frame is sent right away.
            last_cap = cap;
            last_seq = 0;
        }
        auto seq = cap->frame_seq();
        if (seq == last_seq) {
            std::this_thread::sleep_for(period);
            continue;
        }
        auto jpeg = cap->latest_jpeg();
        if (jpeg.empty()) {
            std::this_thread::sleep_for(period);
            continue;
        }
        last_seq = seq;

        std::string part = "--obsboundary\r\n"
                           "Content-Type: image/jpeg\r\n"
                           "Content-Length: " + std::to_string(jpeg.size()) +
                           "\r\n\r\n";
        if (!send_all(fd, part.data(), part.size())) break;
        if (!send_all(fd, reinterpret_cast<const char*>(jpeg.data()), jpeg.size())) break;
        if (!send_all(fd, "\r\n", 2)) break;
        std::this_thread::sleep_for(period);
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
