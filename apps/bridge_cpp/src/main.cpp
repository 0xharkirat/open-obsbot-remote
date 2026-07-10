#include "device_manager.h"
#include "ws_server.h"
#include "video_capture.h"
#include "mjpeg_server.h"
#include "auth.h"
#include "log.h"

#include <atomic>
#include <csignal>
#include <cstdlib>
#include <string>

static std::atomic<bool> g_shutdown{false};

static void on_signal(int) {
    g_shutdown = true;
    // _Exit skips libdev's global destructors  -  they have a known crash
    // on teardown that we'd rather not trigger in front of the user.
    std::_Exit(0);
}

int main(int argc, char** argv) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    // Ignore SIGPIPE  -  when a phone client closes its socket mid-write
    // (very common: page reload, switch tab, lock screen), the default
    // POSIX behaviour is to terminate the process. We want the bridge
    // to keep serving everyone else.
    std::signal(SIGPIPE, SIG_IGN);

    obs::install_sdk_log_handler();

    uint16_t port = 8765;
    std::string web_root;
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--web-root" && i + 1 < argc) { web_root = argv[++i]; }
        else if (a == "--port" && i + 1 < argc) { port = (uint16_t)std::atoi(argv[++i]); }
        else if (a.size() && a[0] != '-') { port = (uint16_t)std::atoi(a.c_str()); }
    }
    if (web_root.empty()) {
        const char* env = std::getenv("OBSBOT_WEB_ROOT");
        if (env) web_root = env;
    }

    // Auth store path (persists PIN + tokens across launches).
    std::string auth_path;
    if (const char* home = std::getenv("HOME")) {
        auth_path = std::string(home) +
            "/Library/Application Support/Open OBSBOT Bridge/auth.json";
    } else {
        auth_path = "/tmp/obsbot-bridge-auth.json";
    }
    obs::AuthStore auth(auth_path);

    // The DeviceManager owns every attached camera (control sessions) AND the
    // per-camera AVFoundation captures. Cameras appear asynchronously via
    // libdev's attach callback once run_ws_server calls mgr.start().
    obs::DeviceManager mgr;

    // Trigger the macOS camera-permission (TCC) prompt up front so it fires
    // even before a camera enumerates. Per-camera capture then starts on
    // attach. libdev + AVFoundation can hold the same USB device at once.
    obs::VideoCapture::request_camera_permission();

    // MJPEG preview server runs on the next port up (default 8766). It resolves
    // captures from the manager per request (/preview/<sn>.mjpg,
    // /preview/active.mjpg), so it starts unconditionally - streams become
    // available as cameras attach. Best-effort: if the port is busy, log +
    // continue without preview rather than crash the whole bridge.
    obs::MjpegServer mjpeg;
    try {
        if (!mjpeg.start((uint16_t)(port + 1), &mgr, &auth)) {
            obs::log("warn ", "mjpeg server failed to start (port busy?)  -  preview disabled");
        }
    } catch (const std::exception& e) {
        obs::log("error", "mjpeg server crashed: %s", e.what());
    }

    try {
        obs::run_ws_server(port, mgr, web_root, auth);  // blocks; calls mgr.start()
    } catch (const std::exception& e) {
        obs::log("error", "ws server crashed: %s", e.what());
        return 1;
    }
    return 0;
}
