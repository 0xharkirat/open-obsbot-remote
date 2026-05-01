#include "device_session.h"
#include "ws_server.h"
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
    obs::run_ws_server(port, session);  // blocks
    return 0;
}
