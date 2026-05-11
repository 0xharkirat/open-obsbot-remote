#include "protocol.h"
#include "device_session.h"
#include "log.h"

#include <chrono>
#include <utility>

using nlohmann::json;
using std::string;

namespace obs {

static int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

json build_state_event(const DeviceSnapshot& s) {
    json presets = json::array();
    for (auto& p : s.presets) {
        presets.push_back({
            {"id", p.id}, {"name", p.name},
            {"yaw", p.yaw}, {"pitch", p.pitch}, {"roll", p.roll}, {"zoom", p.zoom},
        });
    }
    return json{
        {"event", "state"},
        {"ts", now_ms()},
        {"device", {
            {"sn", s.sn},
            {"model", "tiny2lite"},
            {"model_display", s.model},
            {"firmware", s.firmware},
            {"connected", s.connected},
            {"run_status", s.run_status == 1 ? "run" :
                          s.run_status == 3 ? "sleep" :
                          s.run_status == 4 ? "privacy" : "unknown"}
        }},
        {"ptz", {
            {"yaw", s.yaw}, {"pitch", s.pitch}, {"roll", s.roll}
        }},
        {"zoom", {
            {"value", s.zoom}, {"min", s.zoom_min}, {"max", s.zoom_max}
        }},
        {"ai", {
            {"mode", s.ai_mode},
            {"sub_mode", s.ai_sub_mode},
            {"enabled", s.ai_enabled},
            {"tracking_mode", s.tracking_mode}
        }},
        {"image", {
            {"hdr", s.hdr},
            {"fov", s.fov},
            {"brightness", s.brightness},
            {"contrast", s.contrast},
            {"saturation", s.saturation},
            {"sharpness", s.sharpness},
            {"hue", s.hue},
            {"face_ae", s.face_ae},
            {"face_focus", s.face_focus},
            {"auto_focus", s.auto_focus},
            {"manual_focus", s.manual_focus},
            {"flip_h", s.flip_h},
            // v1.2 PR G additions.
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

json ack_ok(const string& id) {
    return json{{"type", "ack"}, {"id", id}, {"ok", true}};
}

json ack_err(const string& id, const string& code, const string& msg) {
    return json{{"type", "ack"}, {"id", id}, {"ok", false}, {"err", code}, {"msg", msg}};
}

void dispatch_message(DeviceSession& session,
                      const string& raw,
                      std::function<void(std::string)> reply_send) {
    json msg;
    try {
        msg = json::parse(raw);
    } catch (...) {
        reply_send(ack_err("?", "invalid_param", "not valid JSON").dump());
        return;
    }

    string id = msg.value("id", "?");
    string action = msg.value("action", "");

    auto reply_cb = [id, reply_send](CmdResult r) {
        json j = r.ok ? ack_ok(id) : ack_err(id, r.err, r.msg);
        reply_send(j.dump());
    };

    try {
    if (action == "hello") {
        json devices = json::array();
        auto s = session.snapshot();
        if (s.connected) {
            devices.push_back({
                {"sn", s.sn},
                {"model", "tiny2lite"},
                {"model_display", s.model},
                {"firmware", s.firmware},
                {"connected", true}
            });
        }
        json resp = ack_ok(id);
        resp["server"] = {
            {"version", "1.0.0"},
            {"protocol", 1},
            {"host", "obsbot-bridge"}
        };
        resp["devices"] = devices;
        reply_send(resp.dump());
        return;
    }

    if (action == "subscribe" || action == "unsubscribe") {
        // subscription is implicit per-connection; just ack
        reply_send(ack_ok(id).dump());
        if (action == "subscribe") {
            reply_send(build_state_event(session.snapshot()).dump());
        }
        return;
    }

    if (action == "ping") {
        reply_send(json{{"type", "pong"}, {"id", id}, {"ts", now_ms()}}.dump());
        return;
    }

    // ---- camera commands ----

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

    // v1.2 PR G — exposure / anti-flicker / white balance.
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

    if (action == "system.run_status") {
        string s = msg.value("status", "run");
        session.cmd_system_run_status(s, reply_cb);
        return;
    }

    if (action == "preset.recall") {
        int pid = msg.value("preset_id", 0);
        // Protocol contract: `duration_ms` is the move time. 0 = instant.
        // No defaults — callers should pass it explicitly. Older clients
        // that omit the field get instant.
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
