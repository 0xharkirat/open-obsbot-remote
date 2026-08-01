#include "device_manager.h"
#include "ws_server.h"
#include "video_capture.h"
#include "mjpeg_server.h"
#include "auth.h"
#include "log.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <string>
#include <thread>

#include <unistd.h>   // getppid

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

    // Die with the supervisor. Quitting the .app left this process orphaned to
    // launchd, still holding the camera - so macOS kept showing the camera-in-
    // use indicator, other apps could not open the camera, and ports 8765/8766
    // stayed bound until the next launch cleaned them up.
    //
    // Watching from THIS side rather than killing from the parent is what makes
    // it reliable: a crashed or force-quit supervisor runs no cleanup code at
    // all, and there is no parent-death signal on macOS. Comparing against the
    // ppid captured at startup avoids firing when the bridge is deliberately
    // launched already-orphaned (nohup, a detached shell).
    std::thread([initial_ppid = getppid()]() {
        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            if (getppid() != initial_ppid) {
                LOGI("supervisor gone; exiting so the camera is released");
                // _Exit for the same reason as the signal handler: libdev's
                // global destructors crash on teardown.
                std::_Exit(0);
            }
        }
    }).detach();

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
    //
    // If the operator answers the prompt AFTER a camera's attach-time capture
    // already gave up at its 60s timeout, retry those captures on grant -
    // otherwise preview stays black until a manual restart (hit live during
    // two-camera bring-up: prompt ignored for minutes, then Allow -> no video).
    // `mgr` outlives the process (run_ws_server blocks below), so capturing it
    // by reference in this AVFoundation callback is safe.
    obs::VideoCapture::request_camera_permission([&mgr](bool granted) {
        if (granted) mgr.retry_pending_captures();
    });

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
