#include "protocol.h"
#include "device_session.h"
#include "device_manager.h"
#include "log.h"

#include <chrono>
#include <memory>
#include <utility>

using nlohmann::json;
using std::string;

namespace obs {

static const char* run_status_str(int ds) {
    switch (ds) {
        case 1: return "run";
        case 3: return "sleep";
        case 4: return "privacy";
        default: return "unknown";
    }
}

json build_device_entry(const DeviceSnapshot& s) {
    json presets = json::array();
    for (auto& p : s.presets) {
        presets.push_back({
            {"id", p.id}, {"name", p.name},
            {"yaw", p.yaw}, {"pitch", p.pitch}, {"roll", p.roll}, {"zoom", p.zoom},
        });
    }
    return json{
        // Top-level canonical id (== SN). device_state.dart reads this first.
        {"device_id", s.sn},
        {"device", {
            {"sn", s.sn},
            {"model_display", s.model},
            {"firmware", s.firmware},
            // A sleeping camera is connected:true with run_status:"sleep" -
            // sleep is a run state, never an omission from devices[].
            {"connected", s.connected},
            {"run_status", run_status_str(s.run_status)},
            {"friendly_name", s.friendly_name},
        }},
        {"ptz", {
            {"yaw", s.yaw}, {"pitch", s.pitch}, {"roll", s.roll}
        }},
        {"zoom", {
            {"value", s.zoom}, {"min", s.zoom_min}, {"max", s.zoom_max}
        }},
        {"ai", {
            {"mode", s.ai_mode},
            {"sub_mode", s.ai_sub_mode},   // wire value for head-hide is "head_hide"
            {"enabled", s.ai_enabled},
            // v2 drops the dead ai.tracking_mode field.
        }},
        {"image", {
            {"hdr", s.hdr},
            {"fov", s.fov},
            {"brightness", s.brightness},
            {"contrast", s.contrast},
            {"saturation", s.saturation},
            {"sharpness", s.sharpness},
            // v2 drops the dead image.hue field.
            {"face_ae", s.face_ae},
            {"face_focus", s.face_focus},
            {"auto_focus", s.auto_focus},
            {"manual_focus", s.manual_focus},
            {"flip_h", s.flip_h},
            {"exposure_mode", s.exposure_mode},
            {"ev_bias", s.ev_bias},
            {"anti_flicker", s.anti_flicker},
            {"wb_auto", s.wb_auto},
            {"wb_kelvin", s.wb_kelvin},
        }},
        {"presets", presets},
        {"active_preset_id", s.active_preset_id},
        {"sequence", {
            {"running", s.sequence_running},
            {"step_index", s.sequence_step_index},
            {"elapsed_s", s.sequence_elapsed_s},
            {"total_s", s.sequence_total_s},
            {"mode", s.sequence_mode},
            // "moving" while MotionPlanner is in flight; "holding" while the
            // stay-timer counts. v2 drops the dead legacy sequence.loop bool.
            {"phase", s.sequence_phase},
            {"available", s.available_sequences},
            {"loaded", s.loaded_sequence},
            {"steps", [&]() {
                json arr = json::array();
                for (auto& st : s.sequence_steps) {
                    arr.push_back({
                        {"preset_id",     st.preset_id},
                        {"seconds",       st.seconds},
                        {"transition_ms", st.transition_ms},
                    });
                }
                return arr;
            }()},
        }},
    };
}

json device_summary(const DeviceSnapshot& s, bool active) {
    return json{
        {"device_id", s.sn},
        {"sn", s.sn},
        {"model_display", s.model},
        {"firmware", s.firmware},
        {"friendly_name", s.friendly_name},
        {"connected", s.connected},
        {"run_status", run_status_str(s.run_status)},
        {"active", active},
    };
}

// `id` is OPAQUE: clients choose its type (the v1 phone + mjs harness
// send strings, the v2 Dart transport sends ints) and the bridge echoes
// it back verbatim. Typing it as std::string crashed the WS worker with
// json.type_error.302 the moment a v2 client connected - found live on
// the first two-camera run.
json ack_ok(const json& id) {
    return json{{"type", "ack"}, {"id", id}, {"ok", true}};
}

json ack_err(const json& id, const string& code, const string& msg) {
    return json{{"type", "ack"}, {"id", id}, {"ok", false}, {"err", code}, {"msg", msg}};
}

// Resolve the target session per the v2 routing table:
//   0 cameras                       -> err "no_device"
//   1 camera,  no device_id         -> that camera (v1 single-cam clients work)
//   2+ cameras, no device_id        -> err "device_required"
//   device_id present, no match     -> err "not_found"
// Returns nullptr (and sends the error ack) when there is no route.
static std::shared_ptr<DeviceSession> route_target(
        DeviceManager& mgr, const json& msg, const json& id,
        const std::function<void(std::string)>& reply_send) {
    size_t n = mgr.device_count();
    if (n == 0) {
        reply_send(ack_err(id, "no_device", "no camera attached").dump());
        return nullptr;
    }
    string did = msg.value("device_id", string{});
    if (did.empty()) {
        if (n == 1) return mgr.sole_session();
        reply_send(ack_err(id, "device_required",
            "multiple cameras attached; specify device_id").dump());
        return nullptr;
    }
    auto s = mgr.session_by_sn(did);
    if (!s) {
        reply_send(ack_err(id, "not_found", "no camera with device_id " + did).dump());
        return nullptr;
    }
    return s;
}

void dispatch_message(DeviceManager& mgr,
                      const string& raw,
                      std::function<void(std::string)> reply_send) {
    json msg;
    try {
        msg = json::parse(raw);
    } catch (...) {
        reply_send(ack_err("?", "invalid_param", "not valid JSON").dump());
        return;
    }

    json id = msg.contains("id") ? msg["id"] : json("?");
    string action = msg.value("action", "");

    auto reply_cb = [id, reply_send](CmdResult r) {
        json j = r.ok ? ack_ok(id) : ack_err(id, r.err, r.msg);
        reply_send(j.dump());
    };

    try {
    // ---- bridge-scoped actions (not tied to a single camera) ----

    if (action == "hello") {
        json resp = ack_ok(id);
        resp["server"] = {
            {"version", "2.0.0"},
            {"protocol", "2.0"},
            {"host", "obsbot-bridge"}
        };
        resp["devices"] = mgr.device_summaries();
        resp["active_device_id"] = mgr.active_sn();
        reply_send(resp.dump());
        return;
    }

    if (action == "subscribe" || action == "unsubscribe") {
        // subscription is implicit per-connection; just ack
        reply_send(ack_ok(id).dump());
        if (action == "subscribe") {
            reply_send(mgr.build_state_event().dump());
        }
        return;
    }

    if (action == "ping") {
        reply_send(json{{"type", "pong"}, {"id", id}, {"ts",
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count()}}.dump());
        return;
    }

    if (action == "device.list") {
        json resp = ack_ok(id);
        resp["devices"] = mgr.device_summaries();
        resp["active_device_id"] = mgr.active_sn();
        reply_send(resp.dump());
        return;
    }

    if (action == "device.set_active") {
        string sn = msg.value("device_id", string{});
        if (sn.empty()) sn = msg.value("sn", string{});
        string ec;
        if (mgr.set_active(sn, ec)) reply_send(ack_ok(id).dump());
        else reply_send(ack_err(id, ec, "no camera with device_id " + sn).dump());
        return;
    }

    if (action == "device.rename") {
        string sn = msg.value("device_id", string{});
        if (sn.empty()) sn = msg.value("sn", string{});
        string name = msg.value("name", string{});
        string ec;
        if (mgr.rename(sn, name, ec)) reply_send(ack_ok(id).dump());
        else reply_send(ack_err(id, ec, "no camera with device_id " + sn).dump());
        return;
    }

    // ---- device-scoped actions: resolve the target camera first ----

    auto sess = route_target(mgr, msg, id, reply_send);
    if (!sess) return;
    DeviceSession& session = *sess;

    if (action == "ptz.angle") {
        float yaw = msg.value("yaw", 0.0f);
        float pitch = msg.value("pitch", 0.0f);
        float roll = msg.value("roll", -1000.0f);
        int dur = msg.value("duration_ms", 0);
        session.cmd_ptz_angle(yaw, pitch, roll, dur, reply_cb);
        return;
    }
    if (action == "ptz.velocity") {
        float ys = msg.value("yaw_speed", 0.0f);
        float ps = msg.value("pitch_speed", 0.0f);
        float rs = msg.value("roll_speed", 0.0f);
        session.cmd_ptz_velocity(ys, ps, rs, reply_cb);
        return;
    }
    if (action == "ptz.stop")     { session.cmd_ptz_stop(reply_cb); return; }
    if (action == "ptz.recenter") { session.cmd_ptz_recenter(reply_cb); return; }

    if (action == "zoom.set") {
        float v = msg.value("value", 1.0f);
        bool terminal = msg.value("final", false);
        int dur = msg.value("duration_ms", 0);
        session.cmd_zoom_set(v, terminal, dur, reply_cb);
        return;
    }
    if (action == "zoom.set_smooth") {
        float v = msg.value("value", 1.0f);
        int   s = msg.value("speed", 5);
        session.cmd_zoom_set_smooth(v, s, reply_cb);
        return;
    }
    if (action == "ai.set_mode") {
        string m = msg.value("mode", "none");
        string sub = msg.value("sub_mode", "normal");
        session.cmd_ai_set_mode(m, sub, reply_cb);
        return;
    }
    if (action == "ai.set_enabled") {
        bool e = msg.value("enabled", false);
        session.cmd_ai_set_enabled(e, reply_cb);
        return;
    }

    if (action == "image.set_hdr") {
        bool e = msg.value("enabled", false);
        session.cmd_image_set_hdr(e, reply_cb);
        return;
    }
    if (action == "image.set_fov") {
        int f = msg.value("fov", 86);
        session.cmd_image_set_fov(f, reply_cb);
        return;
    }
    if (action == "image.set_color") {
        const bool has_brightness = msg.contains("brightness");
        const bool has_contrast = msg.contains("contrast");
        const bool has_saturation = msg.contains("saturation");
        const bool has_sharpness = msg.contains("sharpness");
        session.cmd_image_set_color(
            has_brightness, has_brightness ? msg["brightness"].get<int>() : 0,
            has_contrast, has_contrast ? msg["contrast"].get<int>() : 0,
            has_saturation, has_saturation ? msg["saturation"].get<int>() : 0,
            has_sharpness, has_sharpness ? msg["sharpness"].get<int>() : 0,
            reply_cb);
        return;
    }
    if (action == "image.set_face_ae")    { session.cmd_image_set_face_ae(msg.value("enabled", false), reply_cb); return; }
    if (action == "image.set_face_focus") { session.cmd_image_set_face_focus(msg.value("enabled", false), reply_cb); return; }
    if (action == "image.set_flip_h")     { session.cmd_image_set_flip_h(msg.value("enabled", false), reply_cb); return; }

    // exposure / anti-flicker / white balance.
    if (action == "image.set_exposure_mode") {
        session.cmd_image_set_exposure_mode(msg.value("mode", std::string("auto")), reply_cb);
        return;
    }
    if (action == "image.set_ev_bias") {
        session.cmd_image_set_ev_bias(static_cast<float>(msg.value("bias", 0.0)), reply_cb);
        return;
    }
    if (action == "image.set_anti_flicker") {
        session.cmd_image_set_anti_flicker(msg.value("mode", std::string("off")), reply_cb);
        return;
    }
    if (action == "image.set_wb_auto") {
        session.cmd_image_set_wb_auto(msg.value("enabled", true), reply_cb);
        return;
    }
    if (action == "image.set_wb_temp") {
        session.cmd_image_set_wb_temp(msg.value("kelvin", 4700), reply_cb);
        return;
    }
    if (action == "image.refresh") {
        session.cmd_image_refresh(reply_cb);
        return;
    }

    if (action == "system.run_status") {
        string s = msg.value("status", "run");
        session.cmd_system_run_status(s, reply_cb);
        return;
    }

    if (action == "preset.recall") {
        int pid = msg.value("preset_id", 0);
        int dur = msg.value("duration_ms", 0);
        session.cmd_preset_recall(pid, dur, reply_cb);
        return;
    }
    if (action == "preset.save") {
        int pid = msg.value("preset_id", 0);
        string name = msg.value("name", "");
        session.cmd_preset_save(pid, name, reply_cb);
        return;
    }
    if (action == "preset.delete") {
        int pid = msg.value("preset_id", 0);
        session.cmd_preset_delete(pid, reply_cb);
        return;
    }

    if (action == "sequence.set") {
        std::vector<SequenceStep> steps;
        if (msg.contains("steps") && msg["steps"].is_array()) {
            for (auto& it : msg["steps"]) {
                SequenceStep s;
                s.preset_id = it.value("preset_id", 0);
                s.seconds   = it.value("seconds", 60);
                s.transition_ms = it.value("transition_ms", 0);
                if (s.seconds < 3) s.seconds = 3;
                if (s.transition_ms < 0) s.transition_ms = 0;
                steps.push_back(s);
            }
        }
        // Prefer "mode"; fall back to legacy bool "loop".
        LoopMode mode = LoopMode::forward;
        if (msg.contains("mode") && msg["mode"].is_string()) {
            std::string m = msg["mode"];
            if (m == "once") mode = LoopMode::once;
            else if (m == "ping_pong") mode = LoopMode::ping_pong;
            else mode = LoopMode::forward;
        } else {
            bool loop = msg.value("loop", true);
            mode = loop ? LoopMode::forward : LoopMode::once;
        }
        session.cmd_sequence_set(steps, mode, reply_cb);
        return;
    }
    if (action == "sequence.start") {
        session.cmd_sequence_start(reply_cb);
        return;
    }
    if (action == "sequence.stop") {
        session.cmd_sequence_stop(reply_cb);
        return;
    }

    // Sequence library
    if (action == "sequence.save_as") {
        std::string name = msg.value("name", std::string{});
        std::vector<SequenceStep> steps;
        if (msg.contains("steps") && msg["steps"].is_array()) {
            for (auto& it : msg["steps"]) {
                SequenceStep s;
                s.preset_id = it.value("preset_id", 0);
                s.seconds   = it.value("seconds", 60);
                s.transition_ms = it.value("transition_ms", 0);
                if (s.seconds < 3) s.seconds = 3;
                if (s.transition_ms < 0) s.transition_ms = 0;
                steps.push_back(s);
            }
        }
        LoopMode mode = LoopMode::forward;
        if (msg.contains("mode") && msg["mode"].is_string()) {
            std::string m = msg["mode"];
            if (m == "once") mode = LoopMode::once;
            else if (m == "ping_pong") mode = LoopMode::ping_pong;
        }
        session.cmd_sequence_save_as(name, steps, mode, reply_cb);
        return;
    }
    if (action == "sequence.load") {
        std::string name = msg.value("name", std::string{});
        session.cmd_sequence_load(name, reply_cb);
        return;
    }
    if (action == "sequence.delete") {
        std::string name = msg.value("name", std::string{});
        session.cmd_sequence_delete(name, reply_cb);
        return;
    }

    reply_send(ack_err(id, "unsupported", "unknown action: " + action).dump());
    } catch (const std::exception& e) {
        reply_send(ack_err(id, "invalid_param", e.what()).dump());
    }
}

}  // namespace obs
