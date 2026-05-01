#include "ws_server.h"
#include "device_session.h"
#include "protocol.h"
#include "log.h"
#include "video_capture.h"

#include <crow_all.h>

#include <chrono>
#include <fstream>
#include <mutex>
#include <sstream>
#include <sys/stat.h>
#include <thread>
#include <unordered_set>

namespace obs {

// Map common file extensions to MIME types for static-file serving.
static const char* mime_for(const std::string& path) {
    auto ends = [&](const char* s){
        size_t n = std::strlen(s);
        return path.size() >= n &&
               path.compare(path.size() - n, n, s) == 0;
    };
    if (ends(".html"))  return "text/html; charset=utf-8";
    if (ends(".js"))    return "application/javascript";
    if (ends(".mjs"))   return "application/javascript";
    if (ends(".wasm"))  return "application/wasm";
    if (ends(".css"))   return "text/css";
    if (ends(".json"))  return "application/json";
    if (ends(".png"))   return "image/png";
    if (ends(".jpg") || ends(".jpeg")) return "image/jpeg";
    if (ends(".svg"))   return "image/svg+xml";
    if (ends(".ico"))   return "image/x-icon";
    if (ends(".woff"))  return "font/woff";
    if (ends(".woff2")) return "font/woff2";
    if (ends(".ttf"))   return "font/ttf";
    if (ends(".otf"))   return "font/otf";
    if (ends(".map"))   return "application/json";
    return "application/octet-stream";
}

static bool read_file(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

static bool path_is_safe(const std::string& rel) {
    // disallow .. traversal and absolute paths
    if (rel.find("..") != std::string::npos) return false;
    if (!rel.empty() && rel.front() == '/') return false;
    return true;
}

void run_ws_server(uint16_t port,
                   DeviceSession& session,
                   VideoCapture* video,
                   const std::string& web_root) {
    crow::SimpleApp app;
    app.loglevel(crow::LogLevel::Warning);

    std::mutex conn_mu;
    std::unordered_set<crow::websocket::connection*> conns;

    auto broadcast = [&](const std::string& payload) {
        std::lock_guard<std::mutex> g(conn_mu);
        for (auto* c : conns) c->send_text(payload);
    };

    // hook session state pushes into broadcaster
    session.start([&](const DeviceSnapshot& s) {
        try {
            auto j = build_state_event(s);
            broadcast(j.dump());
        } catch (...) {}
    });

    CROW_WEBSOCKET_ROUTE(app, "/v1")
        .onopen([&](crow::websocket::connection& conn) {
            std::lock_guard<std::mutex> g(conn_mu);
            conns.insert(&conn);
            LOGI("ws client connected (total=%zu)", conns.size());
        })
        .onclose([&](crow::websocket::connection& conn, const std::string& reason, uint16_t /*status*/) {
            std::lock_guard<std::mutex> g(conn_mu);
            conns.erase(&conn);
            LOGI("ws client disconnected: %s (total=%zu)", reason.c_str(), conns.size());
        })
        .onmessage([&](crow::websocket::connection& conn, const std::string& data, bool /*is_binary*/) {
            dispatch_message(session, data, [&conn](std::string out){
                try { conn.send_text(out); } catch (...) {}
            });
        });

    CROW_ROUTE(app, "/health")([](){ return "ok"; });

    // Static file serving for the Flutter web bundle.
    bool serve_web = false;
    {
        struct stat st;
        if (!web_root.empty() && ::stat(web_root.c_str(), &st) == 0 && S_ISDIR(st.st_mode)) {
            serve_web = true;
            LOGI("serving web app from %s at /", web_root.c_str());
        } else if (!web_root.empty()) {
            LOGW("web_root '%s' not found, web app disabled", web_root.c_str());
        }
    }

    if (serve_web) {
        CROW_ROUTE(app, "/")([web_root](const crow::request& /*req*/, crow::response& res){
            std::string body;
            if (!read_file(web_root + "/index.html", body)) {
                res.code = 500; res.write("index.html missing"); res.end(); return;
            }
            res.set_header("Content-Type", "text/html; charset=utf-8");
            res.set_header("Cache-Control", "no-cache");
            res.write(body);
            res.end();
        });

        CROW_ROUTE(app, "/<path>")
        ([web_root](const crow::request& /*req*/, crow::response& res, std::string path){
            // Reserved paths handled elsewhere — guard so we don't shadow them.
            if (path == "v1" || path == "health" || path == "preview.mjpeg") {
                res.code = 404; res.end(); return;
            }
            if (!path_is_safe(path)) { res.code = 400; res.end(); return; }
            std::string body;
            if (!read_file(web_root + "/" + path, body)) {
                res.code = 404; res.end(); return;
            }
            res.set_header("Content-Type", mime_for(path));
            res.write(body);
            res.end();
        });

        // Flutter web ships nested asset paths (assets/..., canvaskit/..., icons/...)
        // — handle a single extra path segment depth.
        CROW_ROUTE(app, "/<path>/<path>")
        ([web_root](const crow::request& /*req*/, crow::response& res,
                    std::string a, std::string b){
            std::string rel = a + "/" + b;
            if (!path_is_safe(rel)) { res.code = 400; res.end(); return; }
            std::string body;
            if (!read_file(web_root + "/" + rel, body)) {
                res.code = 404; res.end(); return;
            }
            res.set_header("Content-Type", mime_for(rel));
            res.write(body);
            res.end();
        });

        CROW_ROUTE(app, "/<path>/<path>/<path>")
        ([web_root](const crow::request& /*req*/, crow::response& res,
                    std::string a, std::string b, std::string c){
            std::string rel = a + "/" + b + "/" + c;
            if (!path_is_safe(rel)) { res.code = 400; res.end(); return; }
            std::string body;
            if (!read_file(web_root + "/" + rel, body)) {
                res.code = 404; res.end(); return;
            }
            res.set_header("Content-Type", mime_for(rel));
            res.write(body);
            res.end();
        });
    }

    if (video) {
        CROW_ROUTE(app, "/preview.mjpeg")
        ([video](const crow::request& /*req*/, crow::response& res) {
            if (!video->running()) {
                res.code = 503;
                res.set_header("Content-Type", "text/plain");
                res.write("video capture not running — check macOS camera permission");
                res.end();
                return;
            }
            res.set_header("Content-Type",
                "multipart/x-mixed-replace; boundary=obsboundary");
            res.set_header("Cache-Control", "no-cache, no-store, private");
            res.set_header("Connection", "close");
            res.set_header("Pragma", "no-cache");

            uint64_t last_seq = 0;
            const auto period = std::chrono::milliseconds(80);  // ~12 fps
            for (int i = 0; i < 60 * 60 * 12; ++i) {  // 1h cap
                auto seq = video->frame_seq();
                if (seq != last_seq) {
                    auto jpeg = video->latest_jpeg();
                    if (!jpeg.empty()) {
                        std::string header = "--obsboundary\r\n"
                                             "Content-Type: image/jpeg\r\n"
                                             "Content-Length: " +
                                             std::to_string(jpeg.size()) +
                                             "\r\n\r\n";
                        res.write(header);
                        res.write(std::string(reinterpret_cast<const char*>(jpeg.data()),
                                              jpeg.size()));
                        res.write("\r\n");
                        last_seq = seq;
                    }
                }
                std::this_thread::sleep_for(period);
            }
            res.end();
        });
        LOGI("preview MJPEG route enabled at /preview.mjpeg");
    }

    LOGI("ws server listening on 0.0.0.0:%u  path=/v1  health=/health", (unsigned)port);
    app.bindaddr("0.0.0.0").port(port).multithreaded().run();
}

}  // namespace obs
