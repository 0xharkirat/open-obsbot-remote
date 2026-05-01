#include "ws_server.h"
#include "device_session.h"
#include "protocol.h"
#include "log.h"
#include "video_capture.h"

#include <crow_all.h>

#include <chrono>
#include <mutex>
#include <thread>
#include <unordered_set>

namespace obs {

void run_ws_server(uint16_t port, DeviceSession& session, VideoCapture* video) {
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
