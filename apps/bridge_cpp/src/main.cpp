#include "device_session.h"
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

    obs::DeviceSession session;

    // Start UVC video capture in parallel (independent of libdev). This
    // exposes the camera as a regular MJPEG stream over HTTP so phone
    // clients can show a live preview. Both libdev and AVFoundation can
    // hold the camera at the same time.
    obs::VideoCapture video;
    if (!video.start()) {
        obs::log("warn ", "video capture not available  -  preview disabled");
    }

    // MJPEG preview server runs on the next port up (default 8766).
    // Best-effort  -  if the port is busy (e.g. previous instance dying),
    // log + continue without preview rather than crash the whole bridge.
    obs::MjpegServer mjpeg;
    if (video.running()) {
        try {
            if (!mjpeg.start((uint16_t)(port + 1), &video, &auth)) {
                obs::log("warn ", "mjpeg server failed to start (port busy?)  -  preview disabled");
            }
        } catch (const std::exception& e) {
            obs::log("error", "mjpeg server crashed: %s", e.what());
        }
    }

    try {
        obs::run_ws_server(port, session, &video, web_root, auth);  // blocks
    } catch (const std::exception& e) {
        obs::log("error", "ws server crashed: %s", e.what());
        return 1;
    }
    return 0;
}
