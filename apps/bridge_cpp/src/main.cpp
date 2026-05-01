#include "device_session.h"
#include "ws_server.h"
#include "video_capture.h"
#include "log.h"

#include <atomic>
#include <csignal>
#include <cstdlib>

static std::atomic<bool> g_shutdown{false};

static void on_signal(int) {
    g_shutdown = true;
    std::_Exit(0);  // crow's run() blocks; force exit on SIGINT
}

int main(int argc, char** argv) {
    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);

    obs::install_sdk_log_handler();

    uint16_t port = 8765;
    if (argc >= 2) port = (uint16_t)std::atoi(argv[1]);

    obs::DeviceSession session;

    // Start UVC video capture in parallel (independent of libdev). This
    // exposes the camera as a regular MJPEG stream over HTTP so phone
    // clients can show a live preview. Both libdev and AVFoundation can
    // hold the camera at the same time.
    obs::VideoCapture video;
    if (!video.start()) {
        obs::log("warn ", "video capture not available — preview disabled");
    }

    obs::run_ws_server(port, session, &video);  // blocks
    return 0;
}
