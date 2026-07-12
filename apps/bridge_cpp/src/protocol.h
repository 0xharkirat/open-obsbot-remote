#pragma once

#include <functional>
#include <string>

#include <json.hpp>

namespace obs {

class DeviceSession;
class DeviceManager;
struct DeviceSnapshot;
struct CmdResult;

// One element of the v2 state event's `devices` array. Field names are the
// authority in packages/obsbot_protocol/lib/src/device_state.dart (fromEvent).
nlohmann::json build_device_entry(const DeviceSnapshot& s);

// Compact identity record for `hello` / `device.list` acks.
nlohmann::json device_summary(const DeviceSnapshot& s, bool active);

// Dispatch a single client message. Routes device-scoped actions to the right
// session via `mgr` (see the routing table in protocol.cpp). `reply_send` is
// called with the JSON response string (may fire later, from a worker thread).
void dispatch_message(DeviceManager& mgr,
                      const std::string& raw,
                      std::function<void(std::string)> reply_send);

nlohmann::json ack_ok(const nlohmann::json& id);
nlohmann::json ack_err(const nlohmann::json& id, const std::string& code, const std::string& msg);

}  // namespace obs
