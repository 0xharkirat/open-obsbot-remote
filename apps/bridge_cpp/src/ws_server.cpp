#include "ws_server.h"
#include "device_session.h"
#include "protocol.h"
#include "log.h"
#include "video_capture.h"
#include "auth.h"
#include <json.hpp>

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
                   const std::string& web_root,
                   AuthStore& auth) {
    crow::SimpleApp app;
    app.loglevel(crow::LogLevel::Warning);

    std::mutex conn_mu;
    std::unordered_set<crow::websocket::connection*> conns;
    // per-connection auth flag
    std::unordered_set<crow::websocket::connection*> authed_conns;

    auto broadcast = [&](const std::string& payload) {
        std::lock_guard<std::mutex> g(conn_mu);
        for (auto* c : authed_conns) c->send_text(payload);
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
            authed_conns.erase(&conn);
            LOGI("ws client disconnected: %s (total=%zu)", reason.c_str(), conns.size());
        })
        .onmessage([&](crow::websocket::connection& conn, const std::string& data, bool /*is_binary*/) {
            // Auth gate: parse minimally to extract action + token.
            std::string action;
            std::string token;
            std::string id = "?";
            try {
                auto msg = nlohmann::json::parse(data);
                action = msg.value("action", "");
                token  = msg.value("token", "");
                id     = msg.value("id", "?");
            } catch (...) {}

            bool authed;
            {
                std::lock_guard<std::mutex> g(conn_mu);
                authed = authed_conns.count(&conn) > 0;
            }

            // Promote conn to authed if hello/pair carried a valid token or correct PIN.
            if (!authed) {
                if (action == "hello" && auth.is_valid_token(token)) {
                    std::lock_guard<std::mutex> g(conn_mu);
                    authed_conns.insert(&conn);
                    authed = true;
                } else if (action == "hello") {
                    try { conn.send_text(ack_err(id, "auth_required",
                        "send {action:'pair', pin:<6-digit>} or {action:'hello', token:<token>} first").dump()); } catch (...) {}
                    return;
                } else if (action == "pair") {
                    std::string pin;
                    try { pin = nlohmann::json::parse(data).value("pin", std::string{}); } catch (...) {}
                    auto t = auth.verify_pin_and_issue(pin);
                    if (!t.empty()) {
                        std::lock_guard<std::mutex> g(conn_mu);
                        authed_conns.insert(&conn);
                        nlohmann::json resp = ack_ok(id);
                        resp["token"] = t;
                        try { conn.send_text(resp.dump()); } catch (...) {}
                    } else {
                        try { conn.send_text(ack_err(id, "auth_failed", "wrong PIN").dump()); } catch (...) {}
                    }
                    return;  // pair handled here
                }
            }

            if (!authed && action != "ping") {
                try { conn.send_text(ack_err(id, "auth_required",
                    "send {action:'pair', pin:<6-digit>} or {action:'hello', token:<token>} first").dump()); } catch (...) {}
                return;
            }

            dispatch_message(session, data, [&conn](std::string out){
                try { conn.send_text(out); } catch (...) {}
            });
        });

    CROW_ROUTE(app, "/health")([](){ return "ok"; });

    // POST /pair  body: {"pin":"123456"}  →  {"ok":true,"token":"..."}
    // Convenience HTTP endpoint for the web client (single round-trip).
    CROW_ROUTE(app, "/pair").methods("POST"_method)
    ([&auth](const crow::request& req, crow::response& res){
        res.set_header("Access-Control-Allow-Origin", "*");
        res.set_header("Content-Type", "application/json");
        try {
            auto j = nlohmann::json::parse(req.body);
            std::string pin = j.value("pin", std::string{});
            auto tok = auth.verify_pin_and_issue(pin);
            if (tok.empty()) {
                res.code = 401;
                res.write("{\"ok\":false,\"err\":\"wrong PIN\"}");
            } else {
                res.write(std::string("{\"ok\":true,\"token\":\"") + tok + "\"}");
            }
        } catch (...) {
            res.code = 400;
            res.write("{\"ok\":false,\"err\":\"bad json\"}");
        }
        res.end();
    });

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

    auto serve_static = [web_root](const std::string& rel,
                                   crow::response& res,
                                   bool no_cache) {
        if (!path_is_safe(rel)) { res.code = 400; res.end(); return; }
        std::string body;
        if (!read_file(web_root + "/" + rel, body)) {
            res.code = 404; res.end(); return;
        }
        res.set_header("Content-Type", mime_for(rel));
        // index.html: never cache (so updates ship). Everything else:
        // cache for a year — Flutter web's asset filenames are hashed.
        if (no_cache) {
            res.set_header("Cache-Control", "no-cache");
        } else {
            res.set_header("Cache-Control", "public, max-age=31536000, immutable");
        }
        res.write(body);
        res.end();
    };

    if (serve_web) {
        CROW_ROUTE(app, "/")([web_root, serve_static](const crow::request&,
                                                     crow::response& res){
            serve_static("index.html", res, /*no_cache=*/true);
        });

        CROW_ROUTE(app, "/<path>")
        ([web_root, serve_static](const crow::request& /*req*/,
                                  crow::response& res, std::string path){
            if (path == "v1" || path == "health" ||
                path == "preview.mjpeg" || path == "pair") {
                res.code = 404; res.end(); return;
            }
            // index.html and json manifests should not be hard-cached.
            const bool no_cache = (path == "index.html" || path == "manifest.json" ||
                                   path == "flutter_service_worker.js" ||
                                   path == "version.json");
            serve_static(path, res, no_cache);
        });

        CROW_ROUTE(app, "/<path>/<path>")
        ([web_root, serve_static](const crow::request& /*req*/,
                                  crow::response& res,
                                  std::string a, std::string b){
            serve_static(a + "/" + b, res, /*no_cache=*/false);
        });

        CROW_ROUTE(app, "/<path>/<path>/<path>")
        ([web_root, serve_static](const crow::request& /*req*/,
                                  crow::response& res,
                                  std::string a, std::string b, std::string c){
            serve_static(a + "/" + b + "/" + c, res, /*no_cache=*/false);
        });

        CROW_ROUTE(app, "/<path>/<path>/<path>/<path>")
        ([web_root, serve_static](const crow::request& /*req*/,
                                  crow::response& res,
                                  std::string a, std::string b,
                                  std::string c, std::string d){
            serve_static(a + "/" + b + "/" + c + "/" + d, res, /*no_cache=*/false);
        });

        CROW_ROUTE(app, "/<path>/<path>/<path>/<path>/<path>")
        ([web_root, serve_static](const crow::request& /*req*/,
                                  crow::response& res,
                                  std::string a, std::string b,
                                  std::string c, std::string d,
                                  std::string e){
            serve_static(a + "/" + b + "/" + c + "/" + d + "/" + e,
                         res, /*no_cache=*/false);
        });
    }

    LOGI("ws server listening on 0.0.0.0:%u  path=/v1  health=/health", (unsigned)port);
    app.bindaddr("0.0.0.0").port(port).multithreaded().run();
}

}  // namespace obs
