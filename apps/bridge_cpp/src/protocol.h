#pragma once

#include <json.hpp>
#include <string>

namespace obs {

class DeviceSession;
struct DeviceSnapshot;
struct CmdResult;

// Build a state event payload from a snapshot.
nlohmann::json build_state_event(const DeviceSnapshot& s);

// Dispatch a single client message. `reply_send` is called with the JSON
// response string (may be called from the SDK thread).
void dispatch_message(DeviceSession& session,
                      const std::string& raw,
                      std::function<void(std::string)> reply_send);

nlohmann::json ack_ok(const std::string& id);
nlohmann::json ack_err(const std::string& id, const std::string& code, const std::string& msg);

}
