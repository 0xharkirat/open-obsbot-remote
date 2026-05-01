#include "ws_server.h"
#include "device_session.h"
#include "protocol.h"
#include "log.h"

#include <crow_all.h>

#include <mutex>
#include <unordered_set>

namespace obs {

void run_ws_server(uint16_t port, DeviceSession& session) {
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

    LOGI("ws server listening on 0.0.0.0:%u  path=/v1  health=/health", (unsigned)port);
    app.bindaddr("0.0.0.0").port(port).multithreaded().run();
}

}  // namespace obs
