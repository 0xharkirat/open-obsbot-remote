#include "device_session.h"
#include "log.h"

#include <dev/devs.hpp>
#include <json.hpp>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <sys/stat.h>
#include <thread>
#include <utility>

using namespace std::chrono;

namespace obs {

// forward decls — used by on_dev_changed before their bodies appear lower
static nlohmann::json read_lib();
static void write_lib(const nlohmann::json& j);

static std::string product_name(ObsbotProductType t) {
    switch (t) {
        case ObsbotProdTiny: return "Tiny";
        case ObsbotProdTiny4k: return "Tiny 4K";
        case ObsbotProdTiny2: return "Tiny 2";
        case ObsbotProdTiny2Lite: return "Tiny 2 Lite";
        case ObsbotProdTinySE: return "Tiny SE";
        case ObsbotProdTiny3: return "Tiny 3";
        case ObsbotProdTiny3Lite: return "Tiny 3 Lite";
        case ObsbotProdMeet: return "Meet";
        case ObsbotProdMeet4k: return "Meet 4K";
        case ObsbotProdMeet2: return "Meet 2";
        case ObsbotProdMeetSE: return "Meet SE";
        case ObsbotProdTailAir: return "Tail Air";
        case ObsbotProdTail2: return "Tail 2";
        default: return "Unknown";
    }
}

static DeviceSession* g_session = nullptr;

static void s_dev_changed_trampoline(std::string sn, bool plugged, void* /*ud*/) {
    if (g_session) g_session->on_dev_changed(sn, plugged);
}

void DeviceSession::on_dev_changed(const std::string& sn, bool plugged) {
    LOGI("device %s sn=%s", plugged ? "plugged" : "unplugged", sn.c_str());
    submit(
        [this, sn, plugged]() -> CmdResult {
            auto& devs = Devices::get();
            if (plugged) {
                auto d = devs.getDevBySn(sn);
                if (!d) return {false, "internal", "device not in list"};
                dev_ = d;
                {
                    std::lock_guard<std::mutex> g(snap_mu_);
                    snap_.sn = d->devSn();
                    snap_.model = product_name(d->productType());
                    snap_.firmware = d->devVersion();
                    snap_.connected = true;
                }
                LOGI("active device: %s (%s) fw=%s",
                     snap_.sn.c_str(), snap_.model.c_str(), snap_.firmware.c_str());

                // Set zoom_max per product. Tiny 2 Lite digital zoom = 2.0×;
                // larger models reach 4.0×. Tail2 family goes higher.
                auto pt = d->productType();
                float zmax = 2.0f;
                if (pt == ObsbotProdTiny2 || pt == ObsbotProdTailAir ||
                    pt == ObsbotProdTinySE || pt == ObsbotProdTiny3 ||
                    pt == ObsbotProdTiny3Lite || pt == ObsbotProdTail2 ||
                    pt == ObsbotProdTail2S) {
                    zmax = 4.0f;
                }
                {
                    std::lock_guard<std::mutex> g(snap_mu_);
                    snap_.zoom_min = 1.0f;
                    snap_.zoom_max = zmax;
                }
                LOGI("zoom range set to %.1f..%.1fx", 1.0f, zmax);

                // Force HDR off on connect. Tiny 2 Lite ships HDR DOL2TO1
                // raw frames over UVC; OBSBOT Center applies a tone-map
                // before display. Our AVFoundation passthrough doesn't,
                // so HDR ON in our pipeline produces a dark, low-contrast
                // preview. Better to stream SDR until we add a tone-map
                // CIFilter. cameraSetWdrR is cheap; this only fires on
                // device-plugged so users can re-enable HDR mid-session
                // if they want to experiment.
                if (dev_->cameraSetWdrR(Device::DevWdrModeNone) == 0) {
                    std::lock_guard<std::mutex> g(snap_mu_);
                    snap_.hdr = false;
                    LOGI("forced HDR off on connect (raw HDR not supported in MJPEG path)");
                }

                // Pull the camera's saved preset list so the UI can show names.
                refresh_presets_locked();

                // Hydrate sequence library list so the UI can populate the
                // dropdown immediately on first state push.
                {
                    nlohmann::json lib = read_lib();
                    std::vector<std::string> names;
                    for (auto& it : lib.items()) names.push_back(it.key());
                    std::sort(names.begin(), names.end());
                    std::lock_guard<std::mutex> sg(snap_mu_);
                    snap_.available_sequences = names;
                }
            } else {
                if (dev_ && dev_->devSn() == sn) {
                    dev_.reset();
                    std::lock_guard<std::mutex> g(snap_mu_);
                    snap_.connected = false;
                }
            }
            return {true, "", ""};
        },
        [this](CmdResult) {
            if (on_state_) on_state_(snapshot());
        });
}

DeviceSession::DeviceSession() {}
DeviceSession::~DeviceSession() { stop(); }

void DeviceSession::start(StateCallback on_state) {
    on_state_ = std::move(on_state);
    g_session = this;
    running_ = true;
    thr_ = std::thread([this]{ worker_loop(); });
    motion_thr_ = std::thread([this]{ motion_loop(); });

    Devices::get().setDevChangedCallback(s_dev_changed_trampoline, nullptr);
    Devices::get().setEnableMdnsScan(false);

    LOGI("device session started; waiting for camera plug-in...");
}

void DeviceSession::stop() {
    if (!running_) return;
    running_ = false;
    seq_quit_ = true;
    seq_running_ = false;
    seq_cv_.notify_all();
    if (seq_thr_.joinable()) seq_thr_.join();
    motion_quit_ = true;
    motion_cancel_ = true;
    motion_cv_.notify_all();
    if (motion_thr_.joinable()) motion_thr_.join();
    q_cv_.notify_all();
    if (thr_.joinable()) thr_.join();
    Devices::get().close();
    g_session = nullptr;
}

// ============================================================
// MotionPlanner — bridge-side smooth interpolation for moves
// slower than the SDK's own floor.
//
// Design: docs/SLOW_MOTION_DESIGN.md
//
// Single worker thread; new motion_start cancels any in-flight move
// and replaces it. Safe to call from the command worker thread.
// ============================================================

static float ease_in_out_sine(float t) {
    if (t <= 0.f) return 0.f;
    if (t >= 1.f) return 1.f;
    return 0.5f * (1.f - std::cos((float)M_PI * t));
}

static float lerpf(float a, float b, float t) { return a + (b - a) * t; }

// (Old `duration_ms_for(MoveSpeed, ...)` removed — the protocol now
// carries a `duration_ms` field directly. Clients pick how long a move
// should take in absolute time and the planner honors it.)

void DeviceSession::motion_start(MotionTarget t) {
    {
        std::lock_guard<std::mutex> g(motion_mu_);
        motion_pending_ = std::move(t);
        motion_have_pending_ = true;
        motion_cancel_ = true;       // cancel anything currently running
    }
    motion_cv_.notify_all();
}

void DeviceSession::motion_cancel() {
    motion_cancel_ = true;
    motion_cv_.notify_all();
}

bool DeviceSession::motion_busy() const { return motion_busy_.load(); }

void DeviceSession::motion_loop() {
    using namespace std::chrono;
    while (!motion_quit_.load()) {
        // Wait until a pending target arrives.
        MotionTarget t;
        {
            std::unique_lock<std::mutex> g(motion_mu_);
            motion_cv_.wait(g, [&]{
                return motion_quit_.load() || motion_have_pending_;
            });
            if (motion_quit_.load()) break;
            t = std::move(motion_pending_);
            motion_have_pending_ = false;
            motion_cancel_ = false;     // fresh run
        }
        if (t.duration_ms <= 0) continue;
        if (!dev_) continue;

        motion_busy_.store(true);

        // Capture starting attitude / zoom from snap_ (current observed).
        float start_yaw = 0.f, start_pitch = 0.f, start_roll = 0.f, start_zoom = 1.0f;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            start_yaw   = snap_.yaw;
            start_pitch = snap_.pitch;
            start_roll  = snap_.roll;
            start_zoom  = snap_.zoom;
        }

        // Adaptive tick: keep at least 0.1° step / tick so the motor
        // doesn't jitter on sub-resolution moves.
        int tick_ms = t.tick_ms > 0 ? t.tick_ms : 100;
        int ticks   = std::max(1, t.duration_ms / tick_ms);
        const float largest_axis = std::max({
            t.yaw_set   ? std::abs(t.yaw_deg   - start_yaw)   : 0.f,
            t.pitch_set ? std::abs(t.pitch_deg - start_pitch) : 0.f,
            t.roll_set  ? std::abs(t.roll_deg  - start_roll)  : 0.f,
            t.zoom_set  ? std::abs(t.zoom_ratio - start_zoom) * 90.f : 0.f,
        });
        const float per_tick = largest_axis / ticks;
        if (per_tick > 0.f && per_tick < 0.1f) {
            // Stretch tick to keep step ≥0.1° equivalent.
            const int new_tick = (int)(tick_ms * (0.1f / per_tick));
            tick_ms = std::min(new_tick, 500);
            ticks   = std::max(1, t.duration_ms / tick_ms);
        }

        const auto t0 = steady_clock::now();
        for (int i = 1; i <= ticks && !motion_cancel_.load() && !motion_quit_.load(); ++i) {
            const float progress = (float)i / (float)ticks;
            const float eased    = ease_in_out_sine(progress);

            const float iy = t.yaw_set   ? lerpf(start_yaw,   t.yaw_deg,   eased) : start_yaw;
            const float ip = t.pitch_set ? lerpf(start_pitch, t.pitch_deg, eased) : start_pitch;
            const float ir = t.roll_set  ? lerpf(start_roll,  t.roll_deg,  eased) : start_roll;
            const float iz = t.zoom_set  ? lerpf(start_zoom,  t.zoom_ratio, eased) : start_zoom;

            // Drive gimbal at SDK ceiling so each waypoint is reached
            // within the tick window. The planner owns the *target update
            // rate*, not the per-segment motion rate.
            if (t.yaw_set || t.pitch_set || t.roll_set) {
                dev_->gimbalSetSpeedPositionR(ir, ip, iy, 90, 90, 90);
            }
            if (t.zoom_set) {
                dev_->cameraSetZoomWithSpeedAbsoluteR((uint32_t)(iz * 100.f), 10);
            }

            // Mirror progress into snap_ so state events show motion.
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                if (t.yaw_set)   snap_.yaw   = iy;
                if (t.pitch_set) snap_.pitch = ip;
                if (t.roll_set)  snap_.roll  = ir;
                if (t.zoom_set) {
                    snap_.zoom = iz;
                    pending_zoom_ = iz;
                }
            }

            // Sleep until next tick (compensate for SDK call latency).
            const auto due = t0 + milliseconds(i * tick_ms);
            std::this_thread::sleep_until(due);
        }

        // Final exact landing (if not cancelled).
        if (!motion_cancel_.load() && !motion_quit_.load()) {
            if (t.yaw_set || t.pitch_set || t.roll_set) {
                dev_->gimbalSetSpeedPositionR(
                    t.roll_set  ? t.roll_deg  : start_roll,
                    t.pitch_set ? t.pitch_deg : start_pitch,
                    t.yaw_set   ? t.yaw_deg   : start_yaw,
                    90, 90, 90);
            }
            if (t.zoom_set) {
                dev_->cameraSetZoomWithSpeedAbsoluteR((uint32_t)(t.zoom_ratio * 100.f), 10);
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.zoom = t.zoom_ratio;
                pending_zoom_ = t.zoom_ratio;
            }
        }

        motion_busy_.store(false);
    }
}

bool DeviceSession::connected() const {
    std::lock_guard<std::mutex> g(snap_mu_);
    return snap_.connected;
}

DeviceSnapshot DeviceSession::snapshot() const {
    std::lock_guard<std::mutex> g(snap_mu_);
    return snap_;
}

void DeviceSession::submit(std::function<CmdResult()> work, ReplyFn reply) {
    {
        std::lock_guard<std::mutex> g(q_mu_);
        q_.push_back({std::move(work), std::move(reply)});
    }
    q_cv_.notify_one();
}

void DeviceSession::worker_loop() {
    auto next_poll = steady_clock::now();
    while (running_) {
        std::unique_lock<std::mutex> lk(q_mu_);
        q_cv_.wait_for(lk, milliseconds(100),
                       [&]{ return !q_.empty() || !running_; });
        if (!running_) break;
        while (!q_.empty()) {
            auto item = std::move(q_.front());
            q_.pop_front();
            lk.unlock();
            CmdResult r = item.work ? item.work() : CmdResult{true, "", ""};
            if (item.reply) item.reply(std::move(r));
            if (on_state_) on_state_(snapshot());
            lk.lock();
        }
        lk.unlock();

        auto now = steady_clock::now();
        if (now >= next_poll && dev_) {
            next_poll = now + milliseconds(500);
            poll_status_locked();
            if (on_state_) on_state_(snapshot());
        }
    }
}

void DeviceSession::poll_status_locked() {
    if (!dev_) return;

    Device::AiGimbalStateInfo gi{};
    if (dev_->aiGetGimbalStateR(&gi) == 0) {
        std::lock_guard<std::mutex> g(snap_mu_);
        snap_.yaw = gi.yaw_motor;
        snap_.pitch = gi.pitch_motor;
        snap_.roll = gi.roll_motor;
    }

    float z = 1.0f;
    if (dev_->cameraGetZoomAbsoluteR(z) == 0) {
        std::lock_guard<std::mutex> g(snap_mu_);
        // Pending-target semantics: while we're waiting for the camera to
        // reach the most-recently-commanded zoom, don't overwrite snap_.zoom
        // with the camera's transient reading. Clear pending once the
        // camera has caught up (within 0.05x). Without this, slow zoom
        // moves (speed=4 mid-drag, or preset recall) cause state events to
        // visibly snap back to the old value because the poller wins.
        if (pending_zoom_ > 0.5f) {
            if (std::abs(z - pending_zoom_) < 0.05f) {
                pending_zoom_ = 0.0f;        // camera reached target
                snap_.zoom = z;
            }
            // else: keep snap_.zoom at the commanded value
        } else {
            snap_.zoom = z;
        }
    }

    auto cs = dev_->cameraStatus();
    if (dev_->productType() == ObsbotProdTiny2 ||
        dev_->productType() == ObsbotProdTiny2Lite) {
        std::lock_guard<std::mutex> g(snap_mu_);
        snap_.hdr = cs.tiny.hdr != 0;
        snap_.fov = (cs.tiny.fov == 0 ? 86 : (cs.tiny.fov == 1 ? 78 : 65));
        snap_.face_ae = cs.tiny.face_ae != 0;
        snap_.face_focus = cs.tiny.face_auto_focus != 0;
        snap_.auto_focus = cs.tiny.auto_focus != 0;
        snap_.manual_focus = cs.tiny.manual_focus_value;
        snap_.run_status = cs.tiny.dev_status;
        snap_.flip_h = cs.tiny.image_flip_hor != 0;
        // AI mode poll uses pending-target semantics like zoom. While
        // pending_ai_mode_ is set, only update snap_.ai_mode from the
        // camera read if it matches what we commanded — otherwise we'd
        // flip back to the firmware's stale echo. Cleared once camera
        // catches up.
        std::string cam_mode;
        switch (cs.tiny.ai_mode) {
            case Device::AiWorkModeNone: cam_mode = "none"; break;
            case Device::AiWorkModeGroup: cam_mode = "group"; break;
            case Device::AiWorkModeHuman: cam_mode = "human"; break;
            case Device::AiWorkModeHand: cam_mode = "hand"; break;
            case Device::AiWorkModeWhiteBoard: cam_mode = "whiteboard"; break;
            case Device::AiWorkModeDesk: cam_mode = "desk"; break;
            default: cam_mode = "none"; break;
        }
        if (!pending_ai_mode_.empty()) {
            if (cam_mode == pending_ai_mode_) {
                pending_ai_mode_.clear();        // camera caught up
                snap_.ai_mode = cam_mode;
            }
            // else: keep snap_.ai_mode at the commanded value
        } else {
            snap_.ai_mode = cam_mode;
        }
        // sub_mode follows the same gate
        if (pending_ai_mode_.empty()) {
            switch (cs.tiny.ai_sub_mode) {
                case Device::AiSubModeNormal: snap_.ai_sub_mode = "normal"; break;
                case Device::AiSubModeUpperBody: snap_.ai_sub_mode = "upper_body"; break;
                case Device::AiSubModeCloseUp: snap_.ai_sub_mode = "close_up"; break;
                case Device::AiSubModeHeadHide: snap_.ai_sub_mode = "head_hide"; break;
                case Device::AiSubModeLowerBody: snap_.ai_sub_mode = "lower_body"; break;
                default: snap_.ai_sub_mode = "normal"; break;
            }
        }
    }
}

static CmdResult ok() { return {true, "", ""}; }
static CmdResult err(const char* code, const char* msg) { return {false, code, msg}; }
static bool valid_percent(int v) { return v >= 0 && v <= 100; }

#define REQUIRE_DEV() \
    if (!dev_) return err("not_connected", "no camera attached")

void DeviceSession::clear_active_preset_locked() {
    snap_.active_preset_id = -1;
}

void DeviceSession::cmd_ptz_angle(float yaw, float pitch, float roll, int duration_ms, ReplyFn reply) {
    submit([this, yaw, pitch, roll, duration_ms]() -> CmdResult {
        REQUIRE_DEV();
        // New absolute move preempts any in-flight planner motion.
        motion_cancel();
        dev_->cameraSetAiModeU(Device::AiWorkModeNone);
        dev_->aiSetEnabledR(false);
        ai_disabled_for_manual_ = true;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_mode = "none";
            snap_.ai_enabled = false;
            pending_ai_mode_ = "none";
        }
        if (duration_ms <= 0) {
            int32_t r = dev_->aiSetGimbalMotorAngleR(pitch, yaw, roll);
            if (r == 0) {
                std::lock_guard<std::mutex> g(snap_mu_);
                clear_active_preset_locked();
            }
            return r == 0 ? ok() : err("device_busy", "aiSetGimbalMotorAngleR failed");
        }
        MotionTarget t;
        t.yaw_set    = true;  t.yaw_deg    = yaw;
        t.pitch_set  = true;  t.pitch_deg  = pitch;
        if (roll > -999.f) { t.roll_set = true; t.roll_deg = roll; }
        t.duration_ms = duration_ms;
        t.tag = "ptz.angle";
        motion_start(std::move(t));
        std::lock_guard<std::mutex> g(snap_mu_);
        clear_active_preset_locked();
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_ptz_velocity(float yaw_speed, float pitch_speed, float roll_speed, ReplyFn reply) {
    auto now = steady_clock::now();
    // Joystick / direct velocity preempts any planner-driven move.
    motion_cancel();
    // Velocity is rate-based — client decides how fast it wants the
    // joystick or hold-button to push (multiply its own deflection by
    // whatever speed-factor the user chose). Bridge passes the value
    // through to aiSetGimbalSpeedCtrlR.
    submit([this, yaw_speed, pitch_speed, roll_speed, now]() -> CmdResult {
        REQUIRE_DEV();
        bool stopping = (yaw_speed == 0.f && pitch_speed == 0.f && roll_speed == 0.f);
        if (!stopping && (now - last_velocity_apply_ < milliseconds(30))) return ok();
        last_velocity_apply_ = now;
        // Only disable AI on the first manual command. Repeating
        // cameraSetAiModeU/aiSetEnabledR every velocity tick (10-30 Hz)
        // makes the SDK flap and the camera's AI status oscillate —
        // user sees AI "connecting/disconnecting" rapidly.
        if (!ai_disabled_for_manual_) {
            dev_->cameraSetAiModeU(Device::AiWorkModeNone);
            dev_->aiSetEnabledR(false);
            ai_disabled_for_manual_ = true;
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.ai_mode = "none";
                snap_.ai_enabled = false;
                pending_ai_mode_ = "none";
            }
            // Camera firmware needs ~50ms to register AI-off before it
            // accepts manual gimbal-speed commands. Without this small
            // delay the very first velocity tick after a cold start (or
            // after AI was on) silently no-ops because the camera is
            // still owned by the AI tracker.
            std::this_thread::sleep_for(milliseconds(50));
        }
        // Sign convention (protocol): positive yaw_speed pans camera RIGHT
        // in the viewer frame, positive pitch_speed tilts camera UP. The
        // OBSBOT SDK's gimbal-frame convention is the opposite on both
        // axes, so flip once here. Doing this in the bridge keeps every
        // current and future client (web, native, third-party) consistent.
        int32_t r = dev_->aiSetGimbalSpeedCtrlR(-pitch_speed, -yaw_speed, roll_speed);
        if (r == 0 && !stopping) {
            std::lock_guard<std::mutex> g(snap_mu_);
            clear_active_preset_locked();
        }
        return r == 0 ? ok() : err("device_busy", "aiSetGimbalSpeedCtrlR failed");
    }, std::move(reply));
}

// `cmd_ptz_stop` and `cmd_ptz_recenter` also cancel the planner so
// emergency-stop is honored even when an ultra interpolation is mid-pan.
void DeviceSession::cmd_ptz_stop(ReplyFn reply) {
    motion_cancel();
    submit([this]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->aiSetGimbalSpeedCtrlR(0.0, 0.0, 0.0);
        return r == 0 ? ok() : err("device_busy", "stop failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ptz_recenter(ReplyFn reply) {
    motion_cancel();
    submit([this]() -> CmdResult {
        REQUIRE_DEV();
        dev_->cameraSetAiModeU(Device::AiWorkModeNone);
        dev_->aiSetEnabledR(false);
        ai_disabled_for_manual_ = true;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_mode = "none";
            snap_.ai_enabled = false;
            pending_ai_mode_ = "none";
        }
        int32_t r = dev_->gimbalRstPosR();
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            clear_active_preset_locked();
        }
        return r == 0 ? ok() : err("device_busy", "recenter failed");
    }, std::move(reply));
}

void DeviceSession::cmd_zoom_set(float value, bool client_terminal, int duration_ms, ReplyFn reply) {
    auto now = steady_clock::now();
    submit([this, value, client_terminal, duration_ms, now]() -> CmdResult {
        REQUIRE_DEV();
        float zmin = 1.0f, zmax = 4.0f;
        float prev_v = 1.0f;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            zmin = snap_.zoom_min;
            zmax = snap_.zoom_max;
            prev_v = snap_.zoom;
        }
        float v = value;
        if (v < zmin) v = zmin;
        if (v > zmax) v = zmax;
        // duration_ms > 0 → drive zoom through the planner so the lens
        // motor delivers smooth motion at any duration. duration_ms = 0
        // → one-shot SDK (mid-drag rapid update path).
        if (duration_ms > 0 && std::abs(v - prev_v) > 0.02f) {
            motion_cancel();
            MotionTarget t;
            t.zoom_set = true;
            t.zoom_ratio = v;
            t.duration_ms = duration_ms;
            t.tag = "zoom.set d=" + std::to_string(duration_ms);
            motion_start(std::move(t));
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.zoom = v;
            pending_zoom_ = v;
            return ok();
        }
        // Mid-drag coalesce: only drop a duplicate if the value barely
        // changed AND the previous apply was very recent. Always accept
        // edge values (=zmin or =zmax) and any value the client tagged as
        // `final` (drag-end, button tap) so the camera always lands where
        // the user released — even if the gap from the previous tick is
        // tiny.
        const bool edge = (v == zmin || v == zmax);
        const bool tiny_step = std::abs(v - prev_v) < 0.1f;
        const bool terminal = edge || client_terminal;
        if (!terminal && tiny_step && (now - last_zoom_apply_) < milliseconds(80)) return ok();
        last_zoom_apply_ = now;
        // Lower zoom-motor speed (4) when mid-drag = smoother; speed 10
        // on terminal. (No tier-based pacing here — that's handled by
        // the planner branch above.)
        uint32_t zspeed_motor = terminal ? 10u : 4u;
        int32_t r = dev_->cameraSetZoomWithSpeedAbsoluteR(
            (uint32_t)(v * 100.f), zspeed_motor);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.zoom = v;
            pending_zoom_ = v;
        }
        return r == 0 ? ok() : err("device_busy", "zoom failed");
    }, std::move(reply));
}

void DeviceSession::cmd_zoom_set_smooth(float value, int speed, ReplyFn reply) {
    submit([this, value, speed]() -> CmdResult {
        REQUIRE_DEV();
        float zmin = 1.0f, zmax = 4.0f;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            zmin = snap_.zoom_min;
            zmax = snap_.zoom_max;
        }
        if (value < zmin || value > zmax) {
            return err("invalid_param", "zoom out of camera range");
        }
        if (speed < 1 || speed > 10) return err("invalid_param", "speed must be 1..10");
        int32_t r = dev_->cameraSetZoomWithSpeedAbsoluteR((uint32_t)(value * 100.f), (uint32_t)speed);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.zoom = value;
            pending_zoom_ = value;
        }
        return r == 0 ? ok() : err("device_busy", "zoom_smooth failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ai_set_mode(const std::string& mode, const std::string& sub, ReplyFn reply) {
    submit([this, mode, sub]() -> CmdResult {
        REQUIRE_DEV();
        // User explicitly set an AI mode → drop the manual-disable latch
        // so the next ptz command will properly turn AI off again.
        ai_disabled_for_manual_ = (mode == "none");
        Device::AiWorkModeType m = Device::AiWorkModeNone;
        if (mode == "none") m = Device::AiWorkModeNone;
        else if (mode == "human") m = Device::AiWorkModeHuman;
        else if (mode == "hand") m = Device::AiWorkModeHand;
        else if (mode == "group") m = Device::AiWorkModeGroup;
        else if (mode == "whiteboard") m = Device::AiWorkModeWhiteBoard;
        else if (mode == "desk") m = Device::AiWorkModeDesk;
        else return err("invalid_param", "unknown ai mode");

        int32_t s = 0;
        if (m == Device::AiWorkModeHuman) {
            if      (sub == "normal")     s = Device::AiSubModeNormal;
            else if (sub == "upper_body") s = Device::AiSubModeUpperBody;
            else if (sub == "close_up")   s = Device::AiSubModeCloseUp;
            else if (sub == "head_hide")  s = Device::AiSubModeHeadHide;
            else if (sub == "lower_body") s = Device::AiSubModeLowerBody;
            else                          s = Device::AiSubModeNormal;
        }
        int32_t r = dev_->cameraSetAiModeU(m, s);
        if (r == 0) {
            // Stamp snapshot inline so clients see the new mode on the next
            // state event without waiting for the camera-firmware poller
            // (~500ms cadence) to catch up. Set pending_ai_mode_ so the
            // poller doesn't flip snap_.ai_mode back to the stale echo.
            last_ai_apply_ = steady_clock::now();
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_mode = mode;
            snap_.ai_sub_mode = (m == Device::AiWorkModeHuman) ? sub : std::string("normal");
            snap_.ai_enabled = (m != Device::AiWorkModeNone);
            pending_ai_mode_ = mode;
        }
        return r == 0 ? ok() : err("device_busy", "set ai mode failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ai_set_enabled(bool enabled, ReplyFn reply) {
    submit([this, enabled]() -> CmdResult {
        REQUIRE_DEV();
        ai_disabled_for_manual_ = !enabled;
        int32_t r = dev_->aiSetEnabledR(enabled);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_enabled = enabled;
        }
        return r == 0 ? ok() : err("device_busy", "ai enable failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_hdr(bool enabled, ReplyFn reply) {
    auto now = steady_clock::now();
    submit([this, enabled, now]() -> CmdResult {
        REQUIRE_DEV();
        if (now - last_hdr_apply_ < seconds(3)) return err("debounced", "wait 3s between HDR toggles");
        last_hdr_apply_ = now;
        int32_t r = dev_->cameraSetWdrR(enabled ? Device::DevWdrModeDol2TO1 : Device::DevWdrModeNone);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.hdr = enabled;
        }
        return r == 0 ? ok() : err("device_busy", "hdr failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_fov(int fov, ReplyFn reply) {
    submit([this, fov]() -> CmdResult {
        REQUIRE_DEV();
        Device::FovType f;
        if (fov == 86) f = Device::FovType86;
        else if (fov == 78) f = Device::FovType78;
        else if (fov == 65) f = Device::FovType65;
        else return err("invalid_param", "fov must be 86, 78, or 65");
        int32_t r = dev_->cameraSetFovU(f);
        if (r == 0) {
            // Camera firmware can take ~1s to echo new FOV in cs.tiny.fov;
            // stamp snap_ inline so the very next state event already
            // shows the new value to clients (UI feels instant).
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.fov = fov;
        }
        return r == 0 ? ok() : err("device_busy", "fov failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_brightness(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        if (!valid_percent(v)) return err("invalid_param", "brightness must be 0..100");
        int32_t r = dev_->cameraSetImageBrightnessR(v);
        return r == 0 ? ok() : err("device_busy", "brightness failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_contrast(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        if (!valid_percent(v)) return err("invalid_param", "contrast must be 0..100");
        int32_t r = dev_->cameraSetImageContrastR(v);
        return r == 0 ? ok() : err("device_busy", "contrast failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_saturation(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        if (!valid_percent(v)) return err("invalid_param", "saturation must be 0..100");
        int32_t r = dev_->cameraSetImageSaturationR(v);
        return r == 0 ? ok() : err("device_busy", "saturation failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_sharpness(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        if (!valid_percent(v)) return err("invalid_param", "sharpness must be 0..100");
        int32_t r = dev_->cameraSetImageSharpR(v);
        return r == 0 ? ok() : err("device_busy", "sharpness failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_color(bool has_brightness, int brightness,
                                        bool has_contrast, int contrast,
                                        bool has_saturation, int saturation,
                                        bool has_sharpness, int sharpness,
                                        ReplyFn reply) {
    submit([this,
            has_brightness, brightness,
            has_contrast, contrast,
            has_saturation, saturation,
            has_sharpness, sharpness]() -> CmdResult {
        REQUIRE_DEV();
        if (has_brightness && !valid_percent(brightness)) {
            return err("invalid_param", "brightness must be 0..100");
        }
        if (has_contrast && !valid_percent(contrast)) {
            return err("invalid_param", "contrast must be 0..100");
        }
        if (has_saturation && !valid_percent(saturation)) {
            return err("invalid_param", "saturation must be 0..100");
        }
        if (has_sharpness && !valid_percent(sharpness)) {
            return err("invalid_param", "sharpness must be 0..100");
        }

        if (has_brightness && dev_->cameraSetImageBrightnessR(brightness) != 0) {
            return err("device_busy", "brightness failed");
        }
        if (has_contrast && dev_->cameraSetImageContrastR(contrast) != 0) {
            return err("device_busy", "contrast failed");
        }
        if (has_saturation && dev_->cameraSetImageSaturationR(saturation) != 0) {
            return err("device_busy", "saturation failed");
        }
        if (has_sharpness && dev_->cameraSetImageSharpR(sharpness) != 0) {
            return err("device_busy", "sharpness failed");
        }
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            if (has_brightness) snap_.brightness = brightness;
            if (has_contrast) snap_.contrast = contrast;
            if (has_saturation) snap_.saturation = saturation;
            if (has_sharpness) snap_.sharpness = sharpness;
        }
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_face_ae(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetFaceAER(e ? 1 : 0);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.face_ae = e;
        }
        return r == 0 ? ok() : err("device_busy", "face ae failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_face_focus(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetFaceFocusR(e);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.face_focus = e;
        }
        return r == 0 ? ok() : err("device_busy", "face focus failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_flip_h(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageFlipHorizonU(e ? 1 : 0);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.flip_h = e;
        }
        return r == 0 ? ok() : err("device_busy", "flip failed");
    }, std::move(reply));
}

void DeviceSession::cmd_system_run_status(const std::string& s, ReplyFn reply) {
    submit([this, s]() -> CmdResult {
        REQUIRE_DEV();
        Device::DevStatus ds;
        if (s == "run") ds = Device::DevStatusRun;
        else if (s == "sleep") ds = Device::DevStatusSleep;
        else return err("invalid_param", "status must be run or sleep");
        int32_t r = dev_->cameraSetDevRunStatusR(ds);
        return r == 0 ? ok() : err("device_busy", "run_status failed");
    }, std::move(reply));
}

// (speed_to_rates removed — all moves now flow through the
// MotionPlanner which takes a duration_ms directly.)

// (gimbal_move_ms / zoom_speed_for_duration removed: superseded by
// duration_ms_for() + the MotionPlanner's own pacing, which keeps zoom
// and gimbal in sync axis-by-axis instead of via post-hoc speed picking.)

void DeviceSession::cmd_preset_recall(int id, int duration_ms, ReplyFn reply) {
    submit([this, id, duration_ms]() -> CmdResult {
        REQUIRE_DEV();
        if (!ai_disabled_for_manual_) {
            dev_->cameraSetAiModeU(Device::AiWorkModeNone);
            dev_->aiSetEnabledR(false);
            ai_disabled_for_manual_ = true;
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_mode = "none";
            snap_.ai_enabled = false;
            pending_ai_mode_ = "none";
        }

        // Look up the preset (we cache it in snap_.presets). Camera-side
        // firmware presets reliably store yaw/pitch/roll BUT zoom field
        // often comes back as 1.0 — so we keep our own zoom in PresetInfo
        // and explicitly restore on every recall, regardless of speed.
        PresetInfo p{};
        bool found = false;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            for (auto& it : snap_.presets) {
                if (it.id == id) { p = it; found = true; break; }
            }
        }

        // Any new preset recall preempts an in-flight planner move.
        motion_cancel();

        int32_t r = 0;
        if (duration_ms <= 0) {
            // Instant: hardware preset recall + immediate zoom snap.
            r = dev_->aiTrgGimbalPresetR(id);
            if (r == 0 && found && p.zoom > 0.5f) {
                dev_->cameraSetZoomWithSpeedAbsoluteR(
                    (uint32_t)(p.zoom * 100.f), 10);
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.zoom = p.zoom;
                pending_zoom_ = p.zoom;
            }
        } else if (found) {
            // Smooth move: gimbal + zoom both driven by the planner so
            // they finish at exactly the same time.
            MotionTarget t;
            t.yaw_set    = true;  t.yaw_deg    = p.yaw;
            t.pitch_set  = true;  t.pitch_deg  = p.pitch;
            t.roll_set   = true;  t.roll_deg   = p.roll;
            if (p.zoom > 0.5f) { t.zoom_set = true; t.zoom_ratio = p.zoom; }
            t.duration_ms = duration_ms;
            t.tag = "preset.recall id=" + std::to_string(id);
            motion_start(std::move(t));
        } else {
            // Preset list not hydrated yet; fall back to instant hardware.
            r = dev_->aiTrgGimbalPresetR(id);
        }

        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.active_preset_id = id;
        }
        return r == 0 ? ok() : err("device_busy", "preset recall failed");
    }, std::move(reply));
}

void DeviceSession::cmd_preset_save(int id, const std::string& name, ReplyFn reply) {
    submit([this, id, name]() -> CmdResult {
        REQUIRE_DEV();
        Device::PresetPosInfo pi{};
        pi.id = id;
        Device::AiGimbalStateInfo gi{};
        dev_->aiGetGimbalStateR(&gi);
        pi.yaw = gi.yaw_motor;
        pi.pitch = gi.pitch_motor;
        pi.roll = gi.roll_motor;
        // Zoom: read OUR snapshot (which we update inline on every zoom set),
        // not cameraGetZoomAbsoluteR, which reports a stale value right after
        // a zoom command and made every saved preset come back as zoom=1.0.
        float z;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            z = snap_.zoom;
        }
        if (z < 1.0f) z = 1.0f;
        pi.zoom = z;
        std::string n = name.substr(0, 60);
        std::memcpy(pi.name, n.c_str(), n.size());
        pi.name_len = (int32_t)n.size();
        int32_t r = dev_->aiAddGimbalPresetR(&pi);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            // overwrite-or-insert by id
            bool found = false;
            for (auto& p : snap_.presets) {
                if (p.id == id) { p = {id, n, pi.yaw, pi.pitch, pi.roll, pi.zoom}; found = true; break; }
            }
            if (!found) snap_.presets.push_back({id, n, pi.yaw, pi.pitch, pi.roll, pi.zoom});
            std::sort(snap_.presets.begin(), snap_.presets.end(),
                      [](const PresetInfo& a, const PresetInfo& b){ return a.id < b.id; });
            snap_.active_preset_id = id;
        }
        return r == 0 ? ok() : err("device_busy", "preset save failed");
    }, std::move(reply));
}

void DeviceSession::cmd_preset_delete(int id, ReplyFn reply) {
    submit([this, id]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->aiDelGimbalPresetR(id);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.presets.erase(std::remove_if(snap_.presets.begin(), snap_.presets.end(),
                [id](const PresetInfo& p){ return p.id == id; }), snap_.presets.end());
            if (snap_.active_preset_id == id) snap_.active_preset_id = -1;
        }
        return r == 0 ? ok() : err("device_busy", "preset delete failed");
    }, std::move(reply));
}

void DeviceSession::refresh_presets_locked() {
    if (!dev_) return;
    Device::DevDataArray ids{};
    if (dev_->aiGetGimbalPresetListR(&ids) != 0) {
        LOGW("preset list query failed");
        return;
    }
    int n = ids.len;
    if (n < 0 || n > 16) n = 0;
    std::vector<PresetInfo> out;
    out.reserve(n);
    for (int i = 0; i < n; ++i) {
        int32_t pid = ids.data_int32[i];
        Device::PresetPosInfo info{};
        if (dev_->aiGetGimbalPresetInfoWithIdR(&info, pid) == 0) {
            std::string nm;
            int nl = info.name_len;
            if (nl < 0) nl = 0;
            if (nl > (int)sizeof(info.name)) nl = sizeof(info.name);
            nm.assign(info.name, info.name + nl);
            out.push_back({pid, nm, info.yaw, info.pitch, info.roll, info.zoom});
        }
    }
    std::sort(out.begin(), out.end(),
              [](const PresetInfo& a, const PresetInfo& b){ return a.id < b.id; });
    {
        std::lock_guard<std::mutex> g(snap_mu_);
        snap_.presets = std::move(out);
    }
    LOGI("presets loaded: %d entries", (int)snap_.presets.size());
}

// ----------------------------------------------------------------------------
// Sequencer

static std::string sequence_file_path() {
    const char* home = std::getenv("HOME");
    if (!home) return "";
    std::string dir = std::string(home) + "/Library/Application Support/Open OBSBOT Bridge";
    ::mkdir(dir.c_str(), 0755);
    return dir + "/sequence.json";
}

// Backward-compat: read old "speed" string entries from a sequences.json
// produced by v1.0 / v1.1 of the bridge. We translate the old tier name
// to a duration_ms so the planner can drive the same move. Roughly:
//
//   instant → 0          (no interp; SDK hardware path)
//   fast    → 1000ms     (~1s for a 90° pan)
//   medium  → 2000ms     (~2s)
//   slow    → 5000ms     (~5s)
//   cinema  → 22000ms    (~22s)
//   ultra   → 300000ms   (~5 min)
//
// New saves use `transition_ms` directly; nothing else writes "speed".
static int legacy_speed_to_ms(const std::string& s) {
    if (s == "instant") return 0;
    if (s == "fast")    return 1000;
    if (s == "medium")  return 2000;
    if (s == "slow")    return 5000;
    if (s == "cinema")  return 22000;
    if (s == "ultra")   return 300000;
    return 2000;        // default to medium-ish
}

static std::string sequences_lib_path() {
    const char* home = std::getenv("HOME");
    if (!home) return "";
    std::string dir = std::string(home) + "/Library/Application Support/Open OBSBOT Bridge";
    ::mkdir(dir.c_str(), 0755);
    return dir + "/sequences.json";
}

static const char* loop_mode_str(LoopMode m) {
    switch (m) {
        case LoopMode::once:      return "once";
        case LoopMode::forward:   return "forward";
        case LoopMode::ping_pong: return "ping_pong";
    }
    return "forward";
}

static LoopMode parse_loop_mode(const std::string& s, bool legacy_loop = true) {
    if (s == "once")      return LoopMode::once;
    if (s == "forward")   return LoopMode::forward;
    if (s == "ping_pong") return LoopMode::ping_pong;
    // fallback to legacy bool: loop=true → forward, loop=false → once
    return legacy_loop ? LoopMode::forward : LoopMode::once;
}

static void persist_sequence(const std::vector<SequenceStep>& steps, LoopMode mode) {
    std::string path = sequence_file_path();
    if (path.empty()) return;
    nlohmann::json j;
    j["mode"] = loop_mode_str(mode);
    j["loop"] = (mode != LoopMode::once);  // legacy field
    j["steps"] = nlohmann::json::array();
    for (auto& s : steps) {
        j["steps"].push_back({
            {"preset_id",     s.preset_id},
            {"seconds",       s.seconds},
            {"transition_ms", s.transition_ms},
        });
    }
    std::ofstream f(path);
    if (f) f << j.dump(2);
}

void DeviceSession::cmd_sequence_set(const std::vector<SequenceStep>& steps, LoopMode mode, ReplyFn reply) {
    submit([this, steps, mode]() -> CmdResult {
        bool was_running = seq_running_.load();
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            seq_steps_ = steps;
            seq_mode_ = mode;
            if (was_running) {
                if (seq_steps_.empty()) {
                    seq_running_ = false;
                    seq_quit_ = true;
                } else if (seq_step_index_ >= (int)seq_steps_.size()) {
                    seq_step_index_ = (int)seq_steps_.size() - 1;
                }
            }
            persist_sequence(seq_steps_, seq_mode_);
            // Mirror to snapshot so clients see the new steps immediately
            // (sequencer editor hydrates from state.sequence.steps on
            // open / when 'loaded' changes).
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_steps = steps;
            snap_.sequence_loop = (mode != LoopMode::once);
            snap_.loaded_sequence = "";   // editing scratch
        }
        seq_cv_.notify_all();
        return ok();
    }, std::move(reply));
}

// ----- saved sequence library -----

static nlohmann::json read_lib() {
    std::ifstream f(sequences_lib_path());
    if (!f) return nlohmann::json::object();
    try {
        nlohmann::json j; f >> j;
        if (j.is_object()) return j;
    } catch (...) {}
    return nlohmann::json::object();
}
static void write_lib(const nlohmann::json& j) {
    std::ofstream f(sequences_lib_path());
    if (f) f << j.dump(2);
}

static nlohmann::json sequence_to_json(const std::vector<SequenceStep>& steps,
                                       LoopMode mode) {
    nlohmann::json out;
    out["mode"] = loop_mode_str(mode);
    out["steps"] = nlohmann::json::array();
    for (auto& s : steps) {
        out["steps"].push_back({
            {"preset_id",     s.preset_id},
            {"seconds",       s.seconds},
            {"transition_ms", s.transition_ms},
        });
    }
    return out;
}

void DeviceSession::cmd_sequence_save_as(const std::string& name,
                                         const std::vector<SequenceStep>& steps,
                                         LoopMode mode, ReplyFn reply) {
    submit([this, name, steps, mode]() -> CmdResult {
        if (name.empty()) return err("invalid_param", "name required");
        nlohmann::json lib = read_lib();
        lib[name] = sequence_to_json(steps, mode);
        write_lib(lib);
        // also update active scratch + name
        std::vector<std::string> names;
        for (auto& it : lib.items()) names.push_back(it.key());
        std::sort(names.begin(), names.end());
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            seq_steps_ = steps;
            seq_mode_  = mode;
            persist_sequence(seq_steps_, seq_mode_);
        }
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.available_sequences = names;
            snap_.loaded_sequence = name;
            snap_.sequence_steps = steps;
            snap_.sequence_mode = loop_mode_str(mode);
            snap_.sequence_loop = (mode != LoopMode::once);
        }
        LOGI("sequence: saved as '%s' (%zu in library)", name.c_str(), names.size());
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_load(const std::string& name, ReplyFn reply) {
    submit([this, name]() -> CmdResult {
        nlohmann::json lib = read_lib();
        if (!lib.contains(name)) {
            std::string m = "no sequence named '" + name + "'";
            return CmdResult{false, "not_found", m};
        }
        auto& entry = lib[name];
        std::vector<SequenceStep> steps;
        for (auto& it : entry["steps"]) {
            SequenceStep s;
            s.preset_id = it.value("preset_id", 0);
            s.seconds   = it.value("seconds", 60);
            // Prefer the new `transition_ms`. Fall back to legacy
            // `speed: "slow|cinema|..."` strings written by v1.0/v1.1.
            if (it.contains("transition_ms")) {
                s.transition_ms = it.value("transition_ms", 0);
            } else if (it.contains("speed") && it["speed"].is_string()) {
                s.transition_ms = legacy_speed_to_ms(it["speed"].get<std::string>());
            } else {
                s.transition_ms = 2000;
            }
            if (s.seconds < 3) s.seconds = 3;
            steps.push_back(s);
        }
        LoopMode mode = parse_loop_mode(entry.value("mode", std::string("forward")));
        bool was_running = seq_running_.load();
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            seq_steps_ = steps;
            seq_mode_  = mode;
            if (was_running) {
                if (seq_step_index_ >= (int)seq_steps_.size()) {
                    seq_step_index_ = (int)seq_steps_.size() - 1;
                }
            }
            persist_sequence(seq_steps_, seq_mode_);
        }
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.loaded_sequence = name;
            snap_.sequence_steps = steps;
            snap_.sequence_mode = loop_mode_str(mode);
            snap_.sequence_loop = (mode != LoopMode::once);
        }
        seq_cv_.notify_all();
        LOGI("sequence: loaded '%s' (%zu steps)", name.c_str(), steps.size());
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_delete(const std::string& name, ReplyFn reply) {
    submit([this, name]() -> CmdResult {
        nlohmann::json lib = read_lib();
        if (!lib.contains(name)) {
            std::string m = "no sequence named '" + name + "'";
            return CmdResult{false, "not_found", m};
        }
        lib.erase(name);
        write_lib(lib);
        std::vector<std::string> names;
        for (auto& it : lib.items()) names.push_back(it.key());
        std::sort(names.begin(), names.end());
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.available_sequences = names;
            if (snap_.loaded_sequence == name) snap_.loaded_sequence = "";
        }
        LOGI("sequence: deleted '%s' (%zu left)", name.c_str(), names.size());
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_start(ReplyFn reply) {
    submit([this]() -> CmdResult {
        if (seq_running_) return ok();
        std::lock_guard<std::mutex> g(seq_mu_);
        if (seq_steps_.empty()) return err("invalid_param", "no sequence configured");
        seq_running_ = true;
        seq_quit_ = false;
        seq_step_index_ = 0;
        seq_direction_ = 1;
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_mode = loop_mode_str(seq_mode_);
        }
        if (seq_thr_.joinable()) seq_thr_.join();
        seq_thr_ = std::thread(&DeviceSession::sequence_loop, this);
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_running = true;
            snap_.sequence_step_index = 0;
            snap_.sequence_total_s = seq_steps_[0].seconds;
            snap_.sequence_elapsed_s = 0;
        }
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_stop(ReplyFn reply) {
    submit([this]() -> CmdResult {
        seq_running_ = false;
        seq_quit_ = true;
        seq_cv_.notify_all();
        if (seq_thr_.joinable()) seq_thr_.join();
        std::lock_guard<std::mutex> sg(snap_mu_);
        snap_.sequence_running = false;
        snap_.sequence_step_index = -1;
        snap_.sequence_elapsed_s = 0;
        snap_.sequence_total_s = 0;
        return ok();
    }, std::move(reply));
}

void DeviceSession::sequence_loop() {
    LOGI("sequence: started");
    auto step_started = std::chrono::steady_clock::now();

    auto trigger_step = [&](int idx){
        if (!dev_) return;
        SequenceStep step;
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            if (idx < 0 || idx >= (int)seq_steps_.size()) return;
            step = seq_steps_[idx];
        }
        int pid = step.preset_id;
        int total = step.seconds;
        // honor per-step speed
        dev_->cameraSetAiModeU(Device::AiWorkModeNone);
        dev_->aiSetEnabledR(false);
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ai_mode = "none";
            snap_.ai_enabled = false;
            pending_ai_mode_ = "none";
        }
        // Each sequence step carries its own `transition_ms`. 0 = instant
        // (camera firmware path); >0 routes through the MotionPlanner so
        // gimbal + zoom land together at exactly that wall-clock time.
        motion_cancel();
        if (step.transition_ms <= 0) {
            dev_->aiTrgGimbalPresetR(pid);
            // Snap zoom too on instant.
            PresetInfo p{};
            bool found = false;
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                for (auto& it : snap_.presets) {
                    if (it.id == pid) { p = it; found = true; break; }
                }
            }
            if (found && p.zoom > 0.5f) {
                dev_->cameraSetZoomWithSpeedAbsoluteR(
                    (uint32_t)(p.zoom * 100.f), 10);
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.zoom = p.zoom;
                pending_zoom_ = p.zoom;
            }
        } else {
            PresetInfo p{};
            bool found = false;
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                for (auto& it : snap_.presets) {
                    if (it.id == pid) { p = it; found = true; break; }
                }
            }
            if (found) {
                MotionTarget t;
                t.yaw_set   = true;  t.yaw_deg   = p.yaw;
                t.pitch_set = true;  t.pitch_deg = p.pitch;
                t.roll_set  = true;  t.roll_deg  = p.roll;
                if (p.zoom > 0.5f) { t.zoom_set = true; t.zoom_ratio = p.zoom; }
                t.duration_ms = step.transition_ms;
                t.tag = "sequence step idx=" + std::to_string(idx);
                motion_start(std::move(t));
            } else {
                dev_->aiTrgGimbalPresetR(pid);
            }
        }
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.active_preset_id = pid;
            snap_.sequence_running = true;
            snap_.sequence_step_index = idx;
            snap_.sequence_total_s = total;
            snap_.sequence_elapsed_s = 0;
        }
        LOGI("sequence: step %d → preset %d for %ds", idx, pid, total);
    };

    trigger_step(seq_step_index_);
    step_started = std::chrono::steady_clock::now();

    while (seq_running_ && !seq_quit_) {
        std::unique_lock<std::mutex> lk(seq_mu_);
        seq_cv_.wait_for(lk, std::chrono::milliseconds(500));
        if (seq_quit_ || !seq_running_) break;

        int idx = seq_step_index_;
        if (idx < 0 || idx >= (int)seq_steps_.size()) break;
        int total = seq_steps_[idx].seconds;
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - step_started).count();

        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_elapsed_s = (int)elapsed;
        }
        if (on_state_) on_state_(snapshot());

        if (elapsed >= total) {
            int n = (int)seq_steps_.size();
            int next = idx;
            switch (seq_mode_) {
                case LoopMode::once: {
                    next = idx + 1;
                    if (next >= n) { seq_running_ = false; }
                    break;
                }
                case LoopMode::forward: {
                    next = (idx + 1) % n;
                    break;
                }
                case LoopMode::ping_pong: {
                    if (n <= 1) { next = 0; break; }
                    int candidate = idx + seq_direction_;
                    if (candidate >= n) {
                        seq_direction_ = -1;
                        candidate = idx - 1;
                    } else if (candidate < 0) {
                        seq_direction_ = 1;
                        candidate = idx + 1;
                    }
                    next = candidate;
                    break;
                }
            }
            if (!seq_running_) break;
            seq_step_index_ = next;
            lk.unlock();
            trigger_step(next);
            step_started = std::chrono::steady_clock::now();
        }
    }

    LOGI("sequence: stopped");
    {
        std::lock_guard<std::mutex> sg(snap_mu_);
        snap_.sequence_running = false;
        snap_.sequence_step_index = -1;
        snap_.sequence_elapsed_s = 0;
        snap_.sequence_total_s = 0;
    }
    if (on_state_) on_state_(snapshot());
}

}  // namespace obs
