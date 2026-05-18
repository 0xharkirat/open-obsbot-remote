#include "mjpeg_server.h"
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
#include <string>
#include <thread>
#include <vector>

namespace obs {

struct MjpegServer::Impl {
    int listen_fd = -1;
    std::atomic<bool> running{false};
    std::thread accept_thr;
    VideoCapture* video = nullptr;
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
    // looking for `?t=...` in the request line
    const char* p = std::strstr(req, "?t=");
    if (!p) return "";
    p += 3;
    std::string out;
    while (*p && *p != ' ' && *p != '&' && *p != '\r' && *p != '\n') { out += *p++; }
    return out;
}

static void serve_client(int fd, VideoCapture* video, AuthStore* auth) {
    char buf[2048];
    ssize_t n = ::recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { ::close(fd); return; }
    buf[n] = 0;

    // Hard-fail any TCP write that takes longer than 5 s. macOS's default
    // retransmit-then-give-up is ~15 min; that timer was leaving wedged
    // MJPEG threads + fds alive when the phone roamed Wi-Fi / backgrounded /
    // dropped NAT state, producing the "preview stops mid-stream with no
    // error" symptom. SO_KEEPALIVE kicks the kernel into probing the peer,
    // SO_NOSIGPIPE avoids the per-process SIGPIPE handler in `main.cpp`
    // being the only line of defence.
    int yes2 = 1;
    ::setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes2, sizeof(yes2));
    struct timeval tv{5, 0};
    ::setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes2, sizeof(yes2));

    // Allow CORS preflight
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

    if (std::strstr(buf, "/preview.mjpeg") == nullptr) {
        const char* resp =
            "HTTP/1.1 404 Not Found\r\n"
            "Content-Length: 0\r\n"
            "Connection: close\r\n\r\n";
        send_all(fd, resp, std::strlen(resp));
        ::close(fd);
        return;
    }

    if (auth) {
        std::string tok = extract_token_from_url(buf);
        if (!auth->is_valid_token(tok)) {
            const char* resp =
                "HTTP/1.1 401 Unauthorized\r\n"
                "Content-Type: text/plain\r\n"
                "Access-Control-Allow-Origin: *\r\n"
                "Connection: close\r\n\r\n"
                "missing or invalid ?t= token";
            send_all(fd, resp, std::strlen(resp));
            ::close(fd);
            return;
        }
    }

    if (!video || !video->running()) {
        const char* resp =
            "HTTP/1.1 503 Service Unavailable\r\n"
            "Content-Type: text/plain\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Connection: close\r\n\r\n"
            "video capture not running — check macOS camera permission";
        send_all(fd, resp, std::strlen(resp));
        ::close(fd);
        return;
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

    LOGI("mjpeg: client connected fd=%d", fd);

    uint64_t last_seq = 0;
    const auto period = std::chrono::milliseconds(50);  // ~20 fps
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::hours(2);

    while (std::chrono::steady_clock::now() < deadline) {
        auto seq = video->frame_seq();
        if (seq == last_seq) {
            std::this_thread::sleep_for(period);
            continue;
        }
        auto jpeg = video->latest_jpeg();
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

    LOGI("mjpeg: client disconnected fd=%d", fd);
    ::close(fd);
}

bool MjpegServer::start(uint16_t port, VideoCapture* video, AuthStore* auth) {
    if (impl_->running) return true;
    impl_->video = video;
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
                std::thread(serve_client, c, impl_->video, impl_->auth).detach();
            } catch (const std::exception& e) {
                LOGW("mjpeg: thread spawn failed fd=%d, leaked-or-closed: %s", c, e.what());
                ::close(c);
            }
        }
    });

    LOGI("mjpeg server listening on 0.0.0.0:%u  /preview.mjpeg", (unsigned)port);
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
