#include "device_session.h"
#include "log.h"
#include "persist.h"

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

DeviceSession::DeviceSession(std::string sn)
    : sn_(std::move(sn)) {
    std::lock_guard<std::mutex> g(snap_mu_);
    snap_.sn = sn_;
}
DeviceSession::~DeviceSession() { stop(); }

void DeviceSession::attach(std::shared_ptr<Device> dev) {
    // Bind a freshly-plugged libdev device and hydrate the snapshot. The
    // SDK calls run on this session's worker thread (dev_ is worker-owned),
    // so we submit rather than touch dev_ from the DeviceManager thread.
    submit(
        [this, dev]() -> CmdResult {
            if (!dev) return {false, "internal", "null device"};
            dev_ = dev;

            // First attach for this SN migrates any v1-shaped persistence
            // (bare presets/sequence files) to the per-SN v2 layout. Idempotent.
            persist::migrate_v1_if_needed(sn_);

            {
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.sn = dev->devSn();
                snap_.model = product_name(dev->productType());
                snap_.firmware = dev->devVersion();
                snap_.connected = true;
                // Friendly name is persisted per-SN; hydrate it so the first
                // state push already carries the operator's label.
                auto names = persist::load_device_names();
                auto it = names.find(sn_);
                snap_.friendly_name = (it != names.end()) ? it->second : "";
            }
            LOGI("attached device: %s (%s) fw=%s vdev=%s",
                 snap_.sn.c_str(), snap_.model.c_str(), snap_.firmware.c_str(),
                 dev->videoDevPath().c_str());

            // Set zoom_max per product. Tiny 2 Lite digital zoom = 2.0×;
            // larger models reach 4.0×. Tail2 family goes higher.
            auto pt = dev->productType();
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

            // Disable the camera's auto-sleep. The Tiny 2 Lite suspends itself
            // after an idle timeout; when it does, its UVC video interface drops
            // and AVFoundation stops getting frames, and waking it does not
            // reliably bring the capture back - a camera that vanishes mid
            // service is the worst failure. cameraSetSuspendTimeU(0) disables
            // the timer (0 or negative = never sleep on the tiny2 series; the
            // DisableSleepWithoutStream call is meet-series only, so not usable
            // here).
            if (dev_->cameraSetSuspendTimeU(0) == 0) {
                LOGI("disabled camera auto-sleep (suspend time = never)");
            } else {
                LOGW("could not disable camera auto-sleep");
            }

            // Pull the camera's saved preset list so the UI can show names.
            refresh_presets_locked();

            // Hydrate sequence library list (per-SN) so the UI can populate
            // the dropdown immediately on first state push.
            {
                nlohmann::json lib = persist::load_sequence_library(sn_);
                std::vector<std::string> names;
                for (auto& it : lib.items()) names.push_back(it.key());
                std::sort(names.begin(), names.end());
                std::lock_guard<std::mutex> sg(snap_mu_);
                snap_.available_sequences = names;
            }
            return {true, "", ""};
        },
        [this](CmdResult) {
            if (on_state_) on_state_(snapshot());
        });
}

void DeviceSession::set_friendly_name(const std::string& name) {
    // Stamp-only: the DeviceManager calls this while holding its own lock and
    // then broadcasts a fresh envelope itself. Firing on_state_ here (which
    // routes back into the manager's broadcast, re-locking that same lock)
    // would deadlock. Persistence + broadcast are the caller's job.
    std::lock_guard<std::mutex> g(snap_mu_);
    snap_.friendly_name = name;
}

void DeviceSession::start(StateCallback on_state) {
    on_state_ = std::move(on_state);
    running_ = true;
    thr_ = std::thread([this]{ worker_loop(); });
    motion_thr_ = std::thread([this]{ motion_loop(); });
    // NOTE: the libdev device-changed callback + mDNS toggle now live in
    // DeviceManager, which owns the Devices singleton and drives attach().
    LOGI("device session %s started", sn_.c_str());
}

void DeviceSession::stop() {
    if (!running_) return;
    running_ = false;
    // Seq teardown under seq_ctl_mu_ so a concurrent cmd_sequence_start/stop on
    // the worker thread cannot touch seq_thr_ at the same time. Released before
    // joining the worker thread below (the worker may be blocked on seq_ctl_mu_).
    {
        std::lock_guard<std::mutex> ctl(seq_ctl_mu_);
        seq_quit_ = true;
        seq_running_ = false;
        seq_cv_.notify_all();
        // Same trap as cmd_sequence_stop's B2 fix: if the sequencer thread
        // is blocked in motion_wait_idle() mid-transition, only the planner
        // thread can wake it - cancel the in-flight move BEFORE joining
        // seq_thr_. Without this, stop() blocks for the remaining move
        // duration (client-controlled, unbounded), and stop() runs on the
        // libdev hotplug thread via DeviceManager::detach - so unplugging
        // one camera mid-slow-move would stall attach/detach for every
        // other camera.
        motion_cancel();
        if (seq_thr_.joinable()) seq_thr_.join();
    }
    motion_quit_ = true;
    motion_cancel_ = true;
    motion_cv_.notify_all();
    if (motion_thr_.joinable()) motion_thr_.join();
    q_cv_.notify_all();
    if (thr_.joinable()) thr_.join();
    // NOTE: does NOT call Devices::get().close(). One camera detaching must
    // not tear down the shared libdev singleton and kill every other camera.
    // DeviceManager::stop() closes Devices once, at process shutdown.
}

// ============================================================
// MotionPlanner  -  bridge-side smooth interpolation for moves
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

// (Old `duration_ms_for(MoveSpeed, ...)` removed  -  the protocol now
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

bool DeviceSession::motion_wait_idle(int timeout_ms) {
    // Idempotent: if planner has nothing in flight AND nothing queued,
    // we're already idle. Snapshot motion_have_pending_ under the mutex
    // since the worker thread mutates it.
    using namespace std::chrono;
    std::unique_lock<std::mutex> g(motion_mu_);
    auto deadline = steady_clock::now() + milliseconds(timeout_ms);
    bool ok = motion_done_cv_.wait_until(g, deadline, [this]{
        return !motion_active_.load() && !motion_have_pending_;
    });
    return ok;
}

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
            // Mark this run as active under the lock so motion_wait_idle
            // racing on motion_done_cv_ sees a consistent active/pending
            // pair (have_pending=false, active=true).
            motion_active_.store(true);
        }
        if (t.duration_ms <= 0) {
            // Nothing to interpolate. Mark idle and notify waiters so
            // motion_wait_idle returns immediately on no-op runs.
            motion_active_.store(false);
            motion_done_cv_.notify_all();
            continue;
        }
        if (!dev_) {
            motion_active_.store(false);
            motion_done_cv_.notify_all();
            continue;
        }

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
        // doesn't jitter on sub-resolution gimbal moves. Zoom uses the
        // float-API (cameraSetZoomAbsoluteR, see below) which honors
        // sub-percent targets, so the fine 100 ms cadence works for
        // any duration without integer-quantization stutter.
        int tick_ms = t.tick_ms > 0 ? t.tick_ms : 100;
        int ticks   = std::max(1, t.duration_ms / tick_ms);
        const float largest_axis = std::max({
            t.yaw_set   ? std::abs(t.yaw_deg   - start_yaw)   : 0.f,
            t.pitch_set ? std::abs(t.pitch_deg - start_pitch) : 0.f,
            t.roll_set  ? std::abs(t.roll_deg  - start_roll)  : 0.f,
            t.zoom_set  ? std::abs(t.zoom_ratio - start_zoom) * 90.f : 0.f,
        });
        const float per_tick = largest_axis / ticks;
        if (per_tick > 0.f && per_tick < 0.1f && !t.zoom_set) {
            // Stretch tick to keep step ≥0.1° equivalent. Gimbal-only  - 
            // zoom keeps the fine cadence per the note above.
            const int new_tick = (int)(tick_ms * (0.1f / per_tick));
            tick_ms = std::min(new_tick, 500);
            ticks   = std::max(1, t.duration_ms / tick_ms);
        }

        // Per-tick gimbal speed (SDK 0..100 percentage). v1.2 used 90
        // everywhere  -  motor raced to each tick target inside the
        // window then waited, producing visible 100 ms-cadence
        // stutter on every duration_ms > 0 move. Live feedback:
        // "anything starting from 1 second time difference to change
        // preset is so shaky." Fix: pick a speed roughly matched to
        // the actual per-tick deg/s rate so the motor moves
        // continuously rather than racing-and-waiting.
        //
        // Map per-tick rate (deg/s) -> SDK percent. Tiny 2 Lite gimbal
        // top speed is ~150 deg/s, so percent ≈ rate / 1.5. Add ~30%
        // headroom (multiplied by 1.3) so each tick has slack to
        // converge to the eased target even if the SDK speed mapping
        // isn't perfectly linear. Floor at 5 so very slow pans still
        // move; cap at 100 (SDK max).
        // Per-tick gimbal speed (SDK 0..100 percentage). v1.2 used 90
        // everywhere  -  motor raced to each tick target inside the
        // window then waited, producing visible 100 ms-cadence
        // stutter on every duration_ms > 0 move. Live feedback:
        // "anything starting from 1 second time difference to change
        // preset is so shaky." Fix: pick a speed roughly matched to
        // the actual per-tick deg/s rate so the motor moves
        // continuously rather than racing-and-waiting.
        //
        // Map per-tick rate (deg/s) -> SDK percent. Tiny 2 Lite gimbal
        // top speed is ~150 deg/s, so percent ≈ rate / 1.5. Headroom
        // 2.0× so each tick has slack to converge to the eased target
        // even at the steeper midpoints of ease_in_out_sine. Floor at
        // 15 so very slow pans (60+ second plans) still cross the
        // motor's minimum-command deadband; cap at 100.
        const float duration_s_for_speed = std::max(0.001f, t.duration_ms / 1000.f);
        auto rate_to_pct = [duration_s_for_speed](bool axis_set, float delta_deg) -> int {
            if (!axis_set) return 90;
            const float rate_dps = std::abs(delta_deg) / duration_s_for_speed;
            const float pct = (rate_dps / 1.5f) * 2.0f;
            int p = (int)pct;
            if (p < 15) p = 15;
            if (p > 100) p = 100;
            return p;
        };
        const int yaw_pct   = rate_to_pct(t.yaw_set,   t.yaw_set   ? t.yaw_deg   - start_yaw   : 0.f);
        const int pitch_pct = rate_to_pct(t.pitch_set, t.pitch_set ? t.pitch_deg - start_pitch : 0.f);
        const int roll_pct  = rate_to_pct(t.roll_set,  t.roll_set  ? t.roll_deg  - start_roll  : 0.f);

        // Hybrid zoom strategy (post-PR-S empirical):
        //
        //   - For short plans (<= 1000 ms) we one-shot the target. The
        //     lens motor takes ~1 s to traverse 1.0×→2.0× at default
        //     speed; trying to tick through fewer than 10 waypoints
        //     would cause visible stepping.
        //   - For longer plans we tick the target at a slow cadence
        //     (zoom_tick_ms = 600 ms minimum). The lens converges to
        //     each waypoint before the next arrives  -  no overshoot
        //     oscillation  -  and the eased curve advances slowly
        //     enough that the duration_ms is honoured.
        //
        // v1.2 ticked every 100 ms, re-arming the lens's internal
        // plan on every call → visible in/out/in/out on any preset
        // recall combining motion + zoom delta. Empirical fix: keep
        // ticks ≥600 ms apart so the lens has time to settle.
        const int zoom_tick_ms = std::max(600, tick_ms);
        const bool zoom_oneshot = t.zoom_set && t.duration_ms <= 1000;
        if (zoom_oneshot) {
            dev_->cameraSetZoomAbsoluteR(t.zoom_ratio, -1);
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                pending_zoom_ = t.zoom_ratio;
            }
        }
        // Track the last zoom waypoint we actually sent so the long-plan
        // branch only re-fires the SDK call when the eased target has
        // drifted into a new tick window.
        auto last_zoom_send = steady_clock::now() - milliseconds(zoom_tick_ms);
        float last_zoom_sent = start_zoom;

        const auto t0 = steady_clock::now();
        for (int i = 1; i <= ticks && !motion_cancel_.load() && !motion_quit_.load(); ++i) {
            const float progress = (float)i / (float)ticks;
            const float eased    = ease_in_out_sine(progress);

            const float iy = t.yaw_set   ? lerpf(start_yaw,   t.yaw_deg,   eased) : start_yaw;
            const float ip = t.pitch_set ? lerpf(start_pitch, t.pitch_deg, eased) : start_pitch;
            const float ir = t.roll_set  ? lerpf(start_roll,  t.roll_deg,  eased) : start_roll;
            const float iz = t.zoom_set  ? lerpf(start_zoom,  t.zoom_ratio, eased) : start_zoom;

            // Drive gimbal with speed matched to per-tick rate so the
            // motor flows through ticks instead of pulse-racing to
            // each one.
            if (t.yaw_set || t.pitch_set || t.roll_set) {
                dev_->gimbalSetSpeedPositionR(ir, ip, iy, roll_pct, pitch_pct, yaw_pct);
            }
            // Long-plan zoom: re-fire the SDK call only when enough
            // time has elapsed since the last waypoint (≥600 ms by
            // default). This keeps the lens motor stable while still
            // honouring the user's duration_ms.
            if (t.zoom_set && !zoom_oneshot) {
                const auto now = steady_clock::now();
                if (now - last_zoom_send >= milliseconds(zoom_tick_ms)) {
                    dev_->cameraSetZoomAbsoluteR(iz, -1);
                    last_zoom_send = now;
                    last_zoom_sent = iz;
                    std::lock_guard<std::mutex> g(snap_mu_);
                    pending_zoom_ = iz;
                }
            }

            // Mirror progress into snap_ so state events show motion.
            {
                std::lock_guard<std::mutex> g(snap_mu_);
                if (t.yaw_set)   snap_.yaw   = iy;
                if (t.pitch_set) snap_.pitch = ip;
                if (t.roll_set)  snap_.roll  = ir;
                if (t.zoom_set) {
                    snap_.zoom = iz;
                }
            }

            // Sleep until next tick (compensate for SDK call latency).
            const auto due = t0 + milliseconds(i * tick_ms);
            std::this_thread::sleep_until(due);
        }
        (void)last_zoom_sent;  // useful for future logging / debugging

        // Final exact landing (if not cancelled). Use the same scaled
        // speed as the in-flight ticks so the motor doesn't lurch at
        // the very end. SDK ceiling 90 here was previously fine
        // because by this point the motor was already near target,
        // but the lurch was still visible on long pans.
        if (!motion_cancel_.load() && !motion_quit_.load()) {
            if (t.yaw_set || t.pitch_set || t.roll_set) {
                dev_->gimbalSetSpeedPositionR(
                    t.roll_set  ? t.roll_deg  : start_roll,
                    t.pitch_set ? t.pitch_deg : start_pitch,
                    t.yaw_set   ? t.yaw_deg   : start_yaw,
                    roll_pct, pitch_pct, yaw_pct);
            }
            if (t.zoom_set) {
                // Terminal landing on the float API  -  same call shape
                // as intra-plan waypoints so the lens doesn't
                // momentarily snap when transitioning into the final
                // exact target.
                dev_->cameraSetZoomAbsoluteR(t.zoom_ratio, -1);
                std::lock_guard<std::mutex> g(snap_mu_);
                snap_.zoom = t.zoom_ratio;
                pending_zoom_ = t.zoom_ratio;
            }
        }

        motion_busy_.store(false);
        // Drop motion_active_ + wake any motion_wait_idle waiter so the
        // sequencer (or any other caller chaining off the planner) can
        // resume. Order matters: the wait predicate reads motion_active_
        // after acquiring motion_mu_, so notify under no lock is fine.
        motion_active_.store(false);
        motion_done_cv_.notify_all();
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
        // Velocity watchdog: the phone refreshes velocity every ~100ms
        // while a control is held and sends stop twice on release. If
        // BOTH stops are lost (Wi-Fi drop, browser tab killed mid-hold),
        // nothing else would ever halt the gimbal - so any velocity
        // that has not been refreshed for 400ms is stopped here. The
        // worker wakes at least every 100ms, keeping the bound tight.
        if (velocity_active_ && dev_ &&
            now - last_velocity_apply_ > milliseconds(400)) {
            dev_->aiSetGimbalSpeedCtrlR(0.f, 0.f, 0.f);
            velocity_active_ = false;
            LOGW("ptz: velocity watchdog auto-stop (no refresh in 400ms)");
        }
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
        // camera read if it matches what we commanded  -  otherwise we'd
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

// v2: "no_device" is the single "there is no camera here" error code across
// the whole bridge (replaces v1's "not_connected"). Routing in protocol.cpp
// normally guarantees a bound device before dispatch reaches a session, so
// this is a safety net for the narrow window where a device detaches between
// routing and execution.
#define REQUIRE_DEV() \
    if (!dev_) return err("no_device", "no camera attached")

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
    // Velocity is rate-based  -  client decides how fast it wants the
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
        // makes the SDK flap and the camera's AI status oscillate  - 
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
        if (r == 0) velocity_active_ = !stopping;
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
        if (r == 0) velocity_active_ = false;
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
            // Don't pre-stamp snap_.zoom here  -  the planner ticks update
            // it progressively (see motion_loop), so state events show
            // smooth zoom motion. Pre-stamping would make clients see
            // the target value immediately even though the lens is
            // still mid-traversal.
            return ok();
        }
        // Mid-drag coalesce: only drop a duplicate if the value barely
        // changed AND the previous apply was very recent. Always accept
        // edge values (=zmin or =zmax) and any value the client tagged as
        // `final` (drag-end, button tap) so the camera always lands where
        // the user released  -  even if the gap from the previous tick is
        // tiny.
        const bool edge = (v == zmin || v == zmax);
        const bool tiny_step = std::abs(v - prev_v) < 0.1f;
        const bool terminal = edge || client_terminal;
        if (!terminal && tiny_step && (now - last_zoom_apply_) < milliseconds(80)) return ok();
        last_zoom_apply_ = now;
        // Instant zoom (duration_ms=0 or mid-drag): cancel any in-flight
        // planner zoom from a previous slow command. Without this, an
        // instant zoom right after a slow zoom plan races: planner keeps
        // pushing toward the old target while the user just snapped to a
        // new value.
        if (terminal) motion_cancel();
        // Float-API cameraSetZoomAbsoluteR: smooth on Tiny 2 Lite. The
        // uint-API cameraSetZoomWithSpeedAbsoluteR is broken on this
        // product  -  gets stuck at 1.33×. The speed param is ignored on
        // Tiny 2 Lite anyway (the SDK header tags zoom_speed as
        // "tail2/tail2s only").
        int32_t r = dev_->cameraSetZoomAbsoluteR(v, -1);
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
        // SDK speed ignored on Tiny 2 Lite  -  pass through anyway to the
        // float API which handles speed internally per product.
        int32_t r = dev_->cameraSetZoomAbsoluteR(value, speed);
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

// --- v1.2 PR G: exposure / anti-flicker / white balance ---------------------
//
// cameraSetExposureModeR + cameraSetAAEEvBiasR are SDK-tagged "tail air"
// only in libdev's headers, but empirical probing on a live Tiny 2 Lite
// (firmware 6.2.8.1, chore/exposure-empirical-probe, 2026-05-12) showed
// every variant returns r=0  -  the firmware accepts them. The earlier
// "unsupported" guard was unnecessary and made the UI grey out
// permanently-working controls.

namespace {
// DevAEEvBiasType maps -3.0..+3.0 in 1/3 stops onto enum 0..18.
// idx = round((bias + 3.0) / (1/3))
int ev_bias_to_enum(float bias) {
    if (bias < -3.0f) bias = -3.0f;
    if (bias >  3.0f) bias =  3.0f;
    int idx = static_cast<int>((bias + 3.0f) * 3.0f + 0.5f);
    if (idx < 0) idx = 0;
    if (idx > 18) idx = 18;
    return idx;
}
float ev_bias_from_enum(int idx) {
    if (idx < 0) idx = 0;
    if (idx > 18) idx = 18;
    return (idx / 3.0f) - 3.0f;
}
int anti_flicker_to_enum(const std::string& m) {
    if (m == "50") return 1;   // PowerLineFreq50
    if (m == "60") return 2;   // PowerLineFreq60
    if (m == "auto") return 3; // PowerLineFreqAuto
    return 0;                  // PowerLineFreqOff
}
std::string anti_flicker_from_enum(int v) {
    switch (v) {
        case 1: return "50";
        case 2: return "60";
        case 3: return "auto";
        default: return "off";
    }
}
} // namespace

void DeviceSession::cmd_image_set_exposure_mode(const std::string& mode, ReplyFn reply) {
    submit([this, mode]() -> CmdResult {
        REQUIRE_DEV();
        int32_t ev = (mode == "manual") ? 1 /*DevExposureManual*/
                                        : 2 /*DevExposureAllAuto*/;
        int32_t r = dev_->cameraSetExposureModeR(ev);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.exposure_mode = (mode == "manual") ? "manual" : "auto";
            return ok();
        }
        return err("device_busy", "exposure mode failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_ev_bias(float bias, ReplyFn reply) {
    submit([this, bias]() -> CmdResult {
        REQUIRE_DEV();
        int idx = ev_bias_to_enum(bias);
        int32_t r = dev_->cameraSetAAEEvBiasR(
            static_cast<Device::DevAEEvBiasType>(idx));
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ev_bias = ev_bias_from_enum(idx);
            return ok();
        }
        return err("device_busy", "EV bias failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_anti_flicker(const std::string& mode, ReplyFn reply) {
    submit([this, mode]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetAntiFlickR(anti_flicker_to_enum(mode));
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.anti_flicker = anti_flicker_from_enum(anti_flicker_to_enum(mode));
            return ok();
        }
        return err("device_busy", "anti-flicker failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_wb_auto(bool enabled, ReplyFn reply) {
    submit([this, enabled]() -> CmdResult {
        REQUIRE_DEV();
        // Auto = DevWhiteBalanceAuto (0); param ignored.
        // When switching to manual, preserve last kelvin.
        int kelvin;
        {
            std::lock_guard<std::mutex> g(snap_mu_);
            kelvin = snap_.wb_kelvin;
        }
        const auto wb = enabled
            ? Device::DevWhiteBalanceAuto
            : Device::DevWhiteBalanceManual;
        int32_t r = dev_->cameraSetWhiteBalanceR(wb, kelvin);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.wb_auto = enabled;
            return ok();
        }
        return err("device_busy", "wb auto failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_wb_temp(int kelvin, ReplyFn reply) {
    submit([this, kelvin]() -> CmdResult {
        REQUIRE_DEV();
        int k = kelvin;
        if (k < 2800) k = 2800;
        if (k > 6500) k = 6500;
        int32_t r = dev_->cameraSetWhiteBalanceR(
            Device::DevWhiteBalanceManual, k);
        if (r == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.wb_auto = false;
            snap_.wb_kelvin = k;
            return ok();
        }
        return err("device_busy", "wb temp failed");
    }, std::move(reply));
}

// v1.2.1 PR P  -  re-read live exposure / anti-flicker / WB state from
// the camera. Best-effort per field: if any individual read fails the
// snap_ field is left at its current value (no clobber to a bogus
// default). Always returns ok() unless the device is missing.
void DeviceSession::cmd_image_refresh(ReplyFn reply) {
    submit([this]() -> CmdResult {
        REQUIRE_DEV();
        int32_t exp_mode = -1;
        if (dev_->cameraGetExposureModeR(exp_mode) == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            // DevExposureManual=1, DevExposureAllAuto=2.
            snap_.exposure_mode = (exp_mode == 1) ? "manual" : "auto";
        }
        Device::DevAEEvBiasType bias_enum;
        if (dev_->cameraGetAAEEvBiasR(bias_enum) == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.ev_bias = ev_bias_from_enum(static_cast<int>(bias_enum));
        }
        int32_t flick = -1;
        if (dev_->cameraGetAntiFlickR(flick) == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.anti_flicker = anti_flicker_from_enum(flick);
        }
        Device::DevWhiteBalanceType wb_type;
        int32_t wb_kelvin = 0;
        if (dev_->cameraGetWhiteBalanceR(wb_type, wb_kelvin) == 0) {
            std::lock_guard<std::mutex> g(snap_mu_);
            snap_.wb_auto = (wb_type == Device::DevWhiteBalanceAuto);
            if (wb_kelvin > 0) snap_.wb_kelvin = wb_kelvin;
        }
        return ok();
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

// (speed_to_rates removed  -  all moves now flow through the
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
        // often comes back as 1.0  -  so we keep our own zoom in PresetInfo
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
            // Instant: hardware preset recall + immediate zoom snap
            // (float API; uint-API is broken on Tiny 2 Lite).
            r = dev_->aiTrgGimbalPresetR(id);
            if (r == 0 && found && p.zoom > 0.5f) {
                dev_->cameraSetZoomAbsoluteR(p.zoom, -1);
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

// Persist the active scratch sequence for one camera. v2 keys sequence.json
// by SN via the persist layer; the legacy top-level "loop" bool is dropped
// (superseded by "mode").
static void persist_sequence(const std::string& sn,
                             const std::vector<SequenceStep>& steps, LoopMode mode) {
    nlohmann::json j;
    j["mode"] = loop_mode_str(mode);
    j["steps"] = nlohmann::json::array();
    for (auto& s : steps) {
        j["steps"].push_back({
            {"preset_id",     s.preset_id},
            {"seconds",       s.seconds},
            {"transition_ms", s.transition_ms},
        });
    }
    persist::store_active_sequence(sn, j);
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
            persist_sequence(sn_, seq_steps_, seq_mode_);
            // Mirror to snapshot so clients see the new steps immediately
            // (sequencer editor hydrates from state.sequence.steps on
            // open / when 'loaded' changes).
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_steps = steps;
            snap_.loaded_sequence = "";   // editing scratch
        }
        seq_cv_.notify_all();
        return ok();
    }, std::move(reply));
}

// ----- saved sequence library -----
// (v1's single-file read_lib/write_lib helpers are gone: the library is now
//  per-SN through the persist layer - persist::load_sequence_library /
//  store_sequence_library, keyed by this session's sn_.)

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
        nlohmann::json lib = persist::load_sequence_library(sn_);
        lib[name] = sequence_to_json(steps, mode);
        persist::store_sequence_library(sn_, lib);
        // also update active scratch + name
        std::vector<std::string> names;
        for (auto& it : lib.items()) names.push_back(it.key());
        std::sort(names.begin(), names.end());
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            seq_steps_ = steps;
            seq_mode_  = mode;
            persist_sequence(sn_, seq_steps_, seq_mode_);
        }
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.available_sequences = names;
            snap_.loaded_sequence = name;
            snap_.sequence_steps = steps;
            snap_.sequence_mode = loop_mode_str(mode);
        }
        LOGI("sequence: saved as '%s' (%zu in library)", name.c_str(), names.size());
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_load(const std::string& name, ReplyFn reply) {
    submit([this, name]() -> CmdResult {
        nlohmann::json lib = persist::load_sequence_library(sn_);
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
            persist_sequence(sn_, seq_steps_, seq_mode_);
        }
        {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.loaded_sequence = name;
            snap_.sequence_steps = steps;
            snap_.sequence_mode = loop_mode_str(mode);
        }
        seq_cv_.notify_all();
        LOGI("sequence: loaded '%s' (%zu steps)", name.c_str(), steps.size());
        return ok();
    }, std::move(reply));
}

void DeviceSession::cmd_sequence_delete(const std::string& name, ReplyFn reply) {
    submit([this, name]() -> CmdResult {
        nlohmann::json lib = persist::load_sequence_library(sn_);
        if (!lib.contains(name)) {
            std::string m = "no sequence named '" + name + "'";
            return CmdResult{false, "not_found", m};
        }
        lib.erase(name);
        persist::store_sequence_library(sn_, lib);
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
        // seq_ctl_mu_ serialises the seq_thr_ lifecycle against stop() (hotplug
        // thread) and cmd_sequence_stop. running_ guards a start that races
        // teardown so it cannot relaunch onto a stopping session.
        std::lock_guard<std::mutex> ctl(seq_ctl_mu_);
        if (!running_) return ok();
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
        {
            std::lock_guard<std::mutex> ctl(seq_ctl_mu_);
            seq_running_ = false;
            seq_quit_ = true;
            seq_cv_.notify_all();
            // B2 fix: if the sequencer is currently blocked inside
            // motion_wait_idle (waiting for a long transition to land),
            // the planner thread is the only one that can wake it. Cancel
            // the in-flight move so motion_wait_idle returns and the
            // sequencer loop exits its CV wait promptly. Without this, a
            // stop pressed mid-30-second-move would block the worker
            // thread on seq_thr_.join() for the rest of the move duration.
            motion_cancel();
            if (seq_thr_.joinable()) seq_thr_.join();
        }
        std::lock_guard<std::mutex> sg(snap_mu_);
        snap_.sequence_running = false;
        snap_.sequence_step_index = -1;
        snap_.sequence_elapsed_s = 0;
        snap_.sequence_total_s = 0;
        snap_.sequence_phase = "holding";   // reset to default
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
                dev_->cameraSetZoomAbsoluteR(p.zoom, -1);
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

    {
        // B2 fix: previously the stay-timer (`step.seconds`) was started
        // immediately after trigger_step() enqueued the motion plan,
        // which meant the move duration and the hold duration ran
        // concurrently against the same `total = seconds` budget. With
        // seconds=40 + transition_ms=30000 the user only saw ~10 s of
        // observable hold time before the next step fired. Fix: wait
        // for the planner to physically complete the move before
        // starting the stay clock.
        // Read under seq_mu_ with a bounds check: a sequence.set / sequence.load
        // carrying an empty or shorter steps list runs on the worker thread and
        // can shrink seq_steps_ while this bootstrap runs on the seq thread. The
        // main loop and trigger_step already guard the index; this line did not.
        int transition_ms = 0;
        {
            std::lock_guard<std::mutex> g(seq_mu_);
            if (seq_step_index_ >= 0 &&
                seq_step_index_ < static_cast<int>(seq_steps_.size())) {
                transition_ms = seq_steps_[seq_step_index_].transition_ms;
            }
        }
        if (transition_ms > 0) {
            std::lock_guard<std::mutex> sg(snap_mu_);
            snap_.sequence_phase = "moving";
        }
        trigger_step(seq_step_index_);
        if (transition_ms > 0) {
            if (on_state_) on_state_(snapshot());
            // Generous deadline (transition_ms + 500 ms) so an ease-out
            // tail or one extra adaptive tick doesn't trip the timeout
            // and prematurely start the hold.
            motion_wait_idle(transition_ms + 500);
            {
                std::lock_guard<std::mutex> sg(snap_mu_);
                snap_.sequence_phase = "holding";
            }
            if (on_state_) on_state_(snapshot());
        }
        step_started = std::chrono::steady_clock::now();  // stay clock starts NOW
    }

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
            // Same B2 chain as the bootstrap path above: trigger the
            // move, block until the planner reports idle, then start
            // the next step's stay clock. Without the wait, fast steps
            // with long transitions would burn most of `seconds` on the
            // move and the hold would appear truncated.
            int next_transition_ms = 0;
            {
                std::lock_guard<std::mutex> g(seq_mu_);
                if (next >= 0 && next < (int)seq_steps_.size()) {
                    next_transition_ms = seq_steps_[next].transition_ms;
                }
            }
            if (next_transition_ms > 0) {
                std::lock_guard<std::mutex> sg(snap_mu_);
                snap_.sequence_phase = "moving";
            }
            trigger_step(next);
            if (next_transition_ms > 0) {
                if (on_state_) on_state_(snapshot());
                motion_wait_idle(next_transition_ms + 500);
                {
                    std::lock_guard<std::mutex> sg(snap_mu_);
                    snap_.sequence_phase = "holding";
                }
                if (on_state_) on_state_(snapshot());
            }
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
        snap_.sequence_phase = "holding";   // reset to default
    }
    if (on_state_) on_state_(snapshot());
}

}  // namespace obs
