#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

class Device;

namespace obs {

struct PresetInfo {
    int id = 0;
    std::string name;
    float yaw = 0.f, pitch = 0.f, roll = 0.f, zoom = 1.f;
};

/// Move-to-preset transition speed. "instant" = libdev default
/// (camera firmware decides), the rest map to s_yaw/s_pitch values for
/// gimbalSetSpeedPositionR (deg/sec).
// Sequencer step.
//
// `seconds` = how long the camera dwells on this preset before
//             advancing to the next step.
// `transition_ms` = how long the move TO this preset's attitude + zoom
//             should take. 0 = instant (SDK hardware path).
//             Anything else routes through the bridge MotionPlanner
//             which can deliver smooth motion at any duration  - 
//             from 0.5s ("snap") to 5+ minutes ("wedding pan").
struct SequenceStep {
    int preset_id = 0;
    int seconds = 60;
    int transition_ms = 0;          // 0 = instant
};

enum class LoopMode { once, forward, ping_pong };

struct DeviceSnapshot {
    std::string sn;
    std::string model;
    std::string firmware;
    // User-chosen label (device.rename). Empty = UI falls back to model +
    // last-4 of SN. Persisted per-SN in device_names.json.
    std::string friendly_name;
    // AVFoundation uniqueID for this camera (== Device::videoDevPath()).
    // The SN -> capture-device join the per-device MJPEG path needs. Not
    // emitted in the state event; surfaced for the MJPEG agent via
    // DeviceSession::video_dev_path().
    std::string video_dev_path;
    bool connected = false;
    int run_status = 1;       // 1=run, 3=sleep, 4=privacy

    float yaw = 0.f, pitch = 0.f, roll = 0.f;
    float zoom = 1.0f;
    // Tiny 2 Lite caps digital zoom at 2.0×. Tail Air / Tiny 2 = 4.0×.
    // Bridge queries the actual range from libdev at connect time and overwrites.
    float zoom_min = 1.0f, zoom_max = 2.0f;

    // List of saved presets, refreshed from camera on connect / save / delete.
    std::vector<PresetInfo> presets;

    // Active scratch sequence (steps + mode), mirrored to clients in
    // state event so the editor can hydrate on reopen.
    std::vector<SequenceStep> sequence_steps;

    // The preset id last recalled. -1 once any manual PTZ command lands.
    int active_preset_id = -1;

    // Sequencer state (mirrored to clients via state event).
    bool sequence_running = false;
    int  sequence_step_index = -1;
    int  sequence_elapsed_s = 0;
    int  sequence_total_s = 0;
    std::string sequence_mode = "forward";  // once | forward | ping_pong
    // Sub-phase of the active step. "moving" while the MotionPlanner is
    // physically driving toward the step's pose; "holding" while the
    // stay-timer (step.seconds) is counting down. Default "holding" so
    // instant-transition steps (transition_ms == 0) and idle state are
    // both correctly reported.
    std::string sequence_phase = "holding";

    // Library of saved sequences. Keys are user-chosen names (e.g.
    // "Morning service", "Vocalist rehearsal"). The currently-loaded
    // sequence's name (or empty if unsaved) is tracked separately.
    std::vector<std::string> available_sequences;
    std::string              loaded_sequence;  // empty = unsaved scratch

    std::string ai_mode = "none";
    std::string ai_sub_mode = "normal";
    bool ai_enabled = false;

    bool hdr = false;
    int fov = 86;
    int brightness = 50, contrast = 50, saturation = 50, sharpness = 50;
    bool face_ae = false;
    bool face_focus = false;
    bool auto_focus = true;
    int  manual_focus = 50;
    bool flip_h = false;

    // Exposure / WB (v1.2 PR G). Tiny 2 Lite SDK support is partial:
    //   - anti_flicker, wb_auto, wb_kelvin work via the standard SDK calls.
    //   - exposure_mode + ev_bias are tagged "tail air" in dev.hpp; the
    //     bridge attempts the SDK calls and reports ok=false on failure
    //     so the client UI can grey out the controls.
    std::string exposure_mode = "auto";    // "auto" | "manual"
    float ev_bias = 0.0f;                  // -3.0 .. +3.0 (1/3 stops)
    std::string anti_flicker = "off";      // "off" | "50" | "60" | "auto"
    bool wb_auto = true;
    int wb_kelvin = 4700;                  // typical midpoint when auto off
};

// Result of a command execution.
struct CmdResult {
    bool ok = true;
    std::string err;
    std::string msg;
};

class DeviceSession {
public:
    using StateCallback = std::function<void(const DeviceSnapshot&)>;
    using ReplyFn = std::function<void(CmdResult)>;

    // `sn` identifies the camera for its entire lifetime: the persistence
    // key, the routing key, and the MJPEG path component. A fake session
    // makes zero libdev calls and its MJPEG path 404s; it exists so CI and
    // single-camera dev machines can exercise the multi-cam UI without a
    // second physical camera (--fake-device <SN>).
    explicit DeviceSession(std::string sn, bool fake = false);
    ~DeviceSession();

    const std::string& sn() const { return sn_; }
    bool is_fake() const { return fake_; }

    // AVFoundation uniqueID (== Device::videoDevPath()), captured on
    // attach. Empty until a real device is bound (and always empty for
    // fake sessions). The next agent's per-device MJPEG path joins on
    // this. Reads a copy under the snapshot mutex.
    std::string video_dev_path() const;

    // Launch the worker + motion threads. Non-blocking. on_state fires
    // whenever this device's snapshot changes. The DeviceManager owns the
    // libdev device-changed callback and drives attach() / removal.
    void start(StateCallback on_state);
    void stop();

    // Bind a freshly-plugged libdev device and hydrate the snapshot
    // (model / firmware / zoom range / presets / persisted sequences). The
    // SDK work runs on this session's worker thread.
    void attach(std::shared_ptr<Device> dev);

    // Stamp a fake session's identity into its snapshot (fake devices only).
    void init_fake();

    // Stamp the friendly name (device.rename) into the snapshot. Does NOT
    // broadcast or persist - the DeviceManager owns both (it calls this under
    // its own lock, so broadcasting from here would deadlock).
    void set_friendly_name(const std::string& name);

    // Apply a WS action to a fake device as a snapshot-only no-op so the UI
    // still reacts. Never touches libdev. `raw` is the original JSON message.
    void cmd_fake(const std::string& action, const std::string& raw, ReplyFn reply);

    bool connected() const;
    DeviceSnapshot snapshot() const;

    // ---- commands (thread-safe; submit to internal queue) ----
    void submit(std::function<CmdResult()> work, ReplyFn reply);

    // High-level helpers (compose work + reply for convenience)
    // duration_ms = 0 → instant SDK path. Non-zero routes through the
    // MotionPlanner. Both axes finish at the same time.
    void cmd_ptz_angle(float yaw, float pitch, float roll, int duration_ms, ReplyFn reply);
    // Velocity is rate-based; client multiplies its own deflection by
    // whatever speed-factor the user chose. Bridge passes through.
    void cmd_ptz_velocity(float yaw_speed, float pitch_speed, float roll_speed, ReplyFn reply);
    void cmd_ptz_stop(ReplyFn reply);
    void cmd_ptz_recenter(ReplyFn reply);
    void cmd_zoom_set(float value, bool terminal, int duration_ms, ReplyFn reply);
    void cmd_zoom_set_smooth(float value, int speed, ReplyFn reply);
    void cmd_ai_set_mode(const std::string& mode, const std::string& sub, ReplyFn reply);
    void cmd_ai_set_enabled(bool enabled, ReplyFn reply);
    void cmd_image_set_hdr(bool enabled, ReplyFn reply);
    void cmd_image_set_fov(int fov, ReplyFn reply);
    // Single-channel setters. Superseded by cmd_image_set_color (which sets
    // any subset atomically) but kept live: the dead-code cut is deferred to
    // a later PR, not this one.
    void cmd_image_set_brightness(int v, ReplyFn reply);
    void cmd_image_set_contrast(int v, ReplyFn reply);
    void cmd_image_set_saturation(int v, ReplyFn reply);
    void cmd_image_set_sharpness(int v, ReplyFn reply);
    void cmd_image_set_color(bool has_brightness, int brightness,
                             bool has_contrast, int contrast,
                             bool has_saturation, int saturation,
                             bool has_sharpness, int sharpness,
                             ReplyFn reply);
    void cmd_image_set_face_ae(bool e, ReplyFn reply);
    void cmd_image_set_face_focus(bool e, ReplyFn reply);
    void cmd_image_set_flip_h(bool e, ReplyFn reply);

    // v1.2 PR G  -  exposure / anti-flicker / white balance.
    // Empirical probe on Tiny 2 Lite firmware 6.2.8.1 confirmed both
    // exposure_mode + ev_bias return r=0; the SDK's "tail air" tag is
    // misleading.
    void cmd_image_set_exposure_mode(const std::string& mode, ReplyFn reply);
    void cmd_image_set_ev_bias(float bias, ReplyFn reply);
    void cmd_image_set_anti_flicker(const std::string& mode, ReplyFn reply);
    void cmd_image_set_wb_auto(bool enabled, ReplyFn reply);
    void cmd_image_set_wb_temp(int kelvin, ReplyFn reply);
    // v1.2.1 PR P  -  read live exposure / anti-flicker / WB state back
    // from the camera and stamp snap_. Defensive against firmware
    // drift or another control app (e.g. OBSBOT Center) changing
    // values while we were disconnected.
    void cmd_image_refresh(ReplyFn reply);

    void cmd_system_run_status(const std::string& s, ReplyFn reply);
    void cmd_preset_recall(int id, int duration_ms, ReplyFn reply);
    void cmd_preset_save(int id, const std::string& name, ReplyFn reply);
    void cmd_preset_delete(int id, ReplyFn reply);

    // Sequencer.
    void cmd_sequence_set(const std::vector<SequenceStep>& steps, LoopMode mode, ReplyFn reply);
    void cmd_sequence_start(ReplyFn reply);
    void cmd_sequence_stop(ReplyFn reply);

    // Sequence library.
    void cmd_sequence_save_as(const std::string& name,
                              const std::vector<SequenceStep>& steps,
                              LoopMode mode, ReplyFn reply);
    void cmd_sequence_load(const std::string& name, ReplyFn reply);
    void cmd_sequence_delete(const std::string& name, ReplyFn reply);

private:
    struct Item {
        std::function<CmdResult()> work;
        ReplyFn reply;
    };

    void worker_loop();
    void poll_status_locked();
    void refresh_presets_locked();
    void clear_active_preset_locked();
    void sequence_loop();
    void sequence_advance_locked(bool& should_run, std::chrono::steady_clock::time_point& step_started);

    // Sequence state (worker thread reads, command thread writes).
    std::vector<SequenceStep> seq_steps_;
    LoopMode seq_mode_ = LoopMode::forward;
    int seq_direction_ = 1;            // +1 or -1 for ping_pong
    std::atomic<bool> seq_running_{false};
    std::atomic<bool> seq_quit_{false};
    std::thread seq_thr_;
    std::condition_variable seq_cv_;
    std::mutex seq_mu_;
    int seq_step_index_ = 0;
    std::chrono::steady_clock::time_point seq_step_started_{};

    // Stable identity for this session (persistence + routing + MJPEG key).
    std::string sn_;
    bool fake_ = false;

    // shared snapshot
    mutable std::mutex snap_mu_;
    DeviceSnapshot snap_;

    std::shared_ptr<Device> dev_;     // touched only by worker thread
    StateCallback on_state_;

    // command queue
    std::mutex q_mu_;
    std::condition_variable q_cv_;
    std::deque<Item> q_;
    std::atomic<bool> running_{false};
    std::thread thr_;

    // velocity coalescing
    std::chrono::steady_clock::time_point last_velocity_apply_{};

    // ----- MotionPlanner: bridge-side smooth interpolation for moves
    // slower than the SDK's own floor.
    //
    // Each MotionPlannerTarget is a goal attitude + zoom to reach over
    // a wall-clock duration. The planner thread drives at most one
    // target at a time; new starts cancel any in-flight one.
    struct MotionTarget {
        bool   yaw_set = false;   float yaw_deg   = 0.f;
        bool   pitch_set = false; float pitch_deg = 0.f;
        bool   roll_set = false;  float roll_deg  = 0.f;
        bool   zoom_set = false;  float zoom_ratio = 1.f;
        int    duration_ms = 0;   // 0 = no interp (caller did instant path)
        int    tick_ms     = 100;
        std::string tag;
    };
    void motion_start(MotionTarget t);
    void motion_cancel();
    bool motion_busy() const;
    // Block calling thread until the MotionPlanner is idle (no in-flight
    // target and no pending one), or until timeout_ms elapses. Returns
    // true if idle, false on timeout. Idempotent: returns true immediately
    // if already idle. Used by the sequencer to chain
    // `trigger_step -> wait-for-move -> stay-timer` so the per-step
    // `seconds` budget covers the hold phase only (B2 fix).
    bool motion_wait_idle(int timeout_ms);

    void motion_loop();
    std::thread       motion_thr_;
    std::mutex        motion_mu_;
    std::condition_variable motion_cv_;
    std::condition_variable motion_done_cv_;
    std::atomic<bool> motion_quit_{false};
    std::atomic<bool> motion_cancel_{false};
    std::atomic<bool> motion_busy_{false};
    // motion_active_ is true between dequeuing a MotionTarget and the
    // end of the final-landing block (including instant-cancelled runs).
    // Distinct from motion_busy_ in that it covers the full lifecycle of
    // one planner pass and is the predicate motion_done_cv_ fires on.
    std::atomic<bool> motion_active_{false};
    MotionTarget      motion_pending_{};
    bool              motion_have_pending_ = false;

    // zoom coalescing (mid-drag updates)
    std::chrono::steady_clock::time_point last_zoom_apply_{};

    // Pending zoom target  -  when set, the periodic poller refuses to
    // overwrite snap_.zoom until the camera-reported value reaches this
    // value (within tolerance). Otherwise the camera's slow firmware echo
    // would clobber the value cmd_zoom_set / cmd_preset_recall just
    // stamped, and clients would see zoom visibly snap back. Cleared once
    // the camera catches up.
    float pending_zoom_ = 0.0f;  // 0 = no pending target

    // AI mode set timestamp  -  used to give camera firmware time to register
    // the new mode before the periodic poller re-reads cs.tiny.ai_mode.
    std::chrono::steady_clock::time_point last_ai_apply_{};

    // Pending AI mode target  -  same pattern as pending_zoom_. The camera
    // firmware echo for ai_mode lags the cmd by hundreds of ms; without
    // this gate the poller reads the old value and flips snap_.ai_mode
    // back. Cleared once the camera reports the commanded mode.
    std::string pending_ai_mode_;

    // hdr debounce
    std::chrono::steady_clock::time_point last_hdr_apply_{};

    // AI-mode-clear-on-first-manual flag  -  prevents flapping when user
    // streams velocity ticks 10-30 Hz, each one hitting cameraSetAiModeU.
    // Set on first manual ptz/preset, cleared by cmd_ai_set_mode/enabled.
    bool ai_disabled_for_manual_ = false;
};

}
