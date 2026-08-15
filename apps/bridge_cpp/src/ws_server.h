#pragma once
#include <cstdint>
#include <string>

namespace obs {
class DeviceManager;
class AuthStore;

// Run a Crow WebSocket + HTTP server on `port` (blocks). Also installs the
// DeviceManager's state broadcaster so every attached camera's snapshot fans
// out to subscribed clients as a single v2 envelope.
//
// `bindaddr` defaults to every interface, which is what a LAN remote needs.
// Pass 127.0.0.1 when something else is publishing the port - a Tailscale
// `serve`, or any reverse proxy - so the bridge is not also reachable raw from
// the local network.
void run_ws_server(uint16_t port,
                   DeviceManager& mgr,
                   const std::string& web_root,
                   AuthStore& auth,
                   const std::string& bindaddr = "0.0.0.0",
                   // Directory holding the HLS playlist and segments produced
                   // by H264Stream, served under /h264/. Empty disables the
                   // route entirely, which is the case on macOS and whenever
                   // --h264 was not passed.
                   const std::string& h264_dir = "");
}
