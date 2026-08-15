#include "device_manager.h"
#include "ws_server.h"
#include "video_capture.h"
#include "mjpeg_server.h"
#ifndef __APPLE__
#include "h264_stream.h"
#endif
#include "auth.h"
#include "log.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <string>
#include <thread>

#include <cerrno>
#include <unistd.h>   // read, STDIN_FILENO

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

    // Die with the supervisor, by watching stdin for EOF.
    //
    // Quitting the .app left this process orphaned to launchd, still holding
    // the camera and ports 8765/8766. Two separate symptoms came from that one
    // orphan: the macOS camera indicator stayed lit (the AVCaptureSession is
    // still open) and OBSBOT Center could not take the camera (libdev still
    // holds the USB control endpoint - see gotcha #19).
    //
    // Watching from THIS side is what makes it reliable. macOS has no
    // PR_SET_PDEATHSIG, and a crashed or force-quit supervisor runs no cleanup
    // code at all, so anything parent-side covers only the polite case - which
    // was never the broken one.
    //
    // stdin is the right fd for it and needs no plumbing: Dart's
    // ProcessStartMode.normal connects the child's stdin to a real pipe whose
    // WRITE end the supervisor holds, and the Dart VM marks both ends
    // FD_CLOEXEC, so no grandchild can inherit the write end and silently
    // disable this. Nothing else here reads stdin. When the supervisor dies by
    // ANY means, including SIGKILL and a panic, the kernel closes its end and
    // read() returns 0.
    //
    // Preferred over polling getppid(): instant rather than up to a second
    // late, no pid to be recycled, and no false positive when a debugger
    // attaches (PT_ATTACH reparents the traced process, which a getppid watch
    // reads as the supervisor dying). It also closes the startup race for
    // free - an already-dead supervisor gives EOF on the first read instead of
    // arming a watch for a change that already happened.
    //
    // Under run-bridge.sh stdin is the terminal, which stays open, so the dev
    // path is unaffected.
    std::thread([]() {
        char b;
        ssize_t n;
        while ((n = ::read(STDIN_FILENO, &b, 1)) > 0) {
            // The supervisor never writes to us; drain anything anyway.
        }
        if (n < 0 && errno == EINTR) return;   // not a death; leave it alone
        obs::log_line_to_file("supervisor gone; exiting so the camera is released");
        // _Exit for the same reason as the signal handler: libdev's global
        // destructors crash on teardown (gotcha #14). Every OS resource we
        // hold, the camera included, is reclaimed by the kernel regardless of
        // how the process ends.
        std::_Exit(0);
    }).detach();

    obs::install_sdk_log_handler();

    uint16_t port = 8765;
    std::string web_root;
    // Every interface, which is what a remote on the same Wi-Fi needs. A
    // headless deployment behind `tailscale serve` passes --bind 127.0.0.1 so
    // the ports are not also raw on the LAN.
    std::string bindaddr = "0.0.0.0";

#ifndef __APPLE__
    // Off unless asked for. The MJPEG preview is the primary path and costs
    // nothing extra; this one spawns an encoder, so it only runs on request.
    bool h264_on = false;
    obs::H264Config h264;
#endif

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--web-root" && i + 1 < argc) { web_root = argv[++i]; }
        else if (a == "--port" && i + 1 < argc) { port = (uint16_t)std::atoi(argv[++i]); }
        else if (a == "--bind" && i + 1 < argc) { bindaddr = argv[++i]; }
#ifndef __APPLE__
        else if (a == "--h264") { h264_on = true; }
        else if (a == "--h264-dir" && i + 1 < argc) { h264.out_dir = argv[++i]; }
        else if (a == "--h264-size" && i + 1 < argc) { h264.size = argv[++i]; }
        else if (a == "--h264-fps" && i + 1 < argc) { h264.fps = std::atoi(argv[++i]); }
        else if (a == "--h264-bitrate" && i + 1 < argc) { h264.bitrate_kbps = std::atoi(argv[++i]); }
        else if (a == "--h264-encoder" && i + 1 < argc) { h264.encoder = argv[++i]; }
#endif
        else if (a.size() && a[0] != '-') { port = (uint16_t)std::atoi(a.c_str()); }
    }
    if (web_root.empty()) {
        const char* env = std::getenv("OBSBOT_WEB_ROOT");
        if (env) web_root = env;
    }

    // Auth store path (persists PIN + tokens across launches).
    //
    // The two platforms disagree about where per-user state belongs, and using
    // the macOS path on Linux would drop a "Library/Application Support"
    // directory into $HOME, which is both wrong and invisible to anything that
    // manages config. Linux follows the XDG base directory spec instead.
    std::string auth_path = obs::auth_store_path();
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
        if (!mjpeg.start((uint16_t)(port + 1), &mgr, &auth, bindaddr)) {
            obs::log("warn ", "mjpeg server failed to start (port busy?)  -  preview disabled");
        }
    } catch (const std::exception& e) {
        obs::log("error", "mjpeg server crashed: %s", e.what());
    }

#ifndef __APPLE__
    // Start the remote H.264 path before the blocking server call. It pulls
    // frames from the same captures the MJPEG server uses, so it needs nothing
    // of its own and cannot contend for /dev/video*.
    obs::H264Stream h264_stream;
    std::string h264_dir;
    if (h264_on) {
        if (h264.out_dir.empty()) {
            // Default under XDG cache: transient, regenerated on every start,
            // and specifically NOT under the web root, which the shipped
            // systemd unit mounts read-only.
            const char* xdg = std::getenv("XDG_CACHE_HOME");
            const char* home = std::getenv("HOME");
            h264.out_dir = (xdg && *xdg) ? std::string(xdg) + "/obsbot-bridge/h264"
                         : (home && *home) ? std::string(home) + "/.cache/obsbot-bridge/h264"
                         : "/tmp/obsbot-bridge-h264";
        }
        if (h264_stream.start(&mgr, h264)) {
            h264_dir = h264.out_dir;
            obs::log("info ", "h264: playlist at /h264/live.m3u8?t=<token> on port %d", (int)port);
        }
    }
#else
    const std::string h264_dir;
#endif

    try {
        obs::run_ws_server(port, mgr, web_root, auth, bindaddr, h264_dir);  // blocks; calls mgr.start()
    } catch (const std::exception& e) {
        obs::log("error", "ws server crashed: %s", e.what());
        return 1;
    }
    return 0;
}
