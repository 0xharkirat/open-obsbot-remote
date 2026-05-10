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
//             which can deliver smooth motion at any duration —
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
    bool sequence_loop = true;          // legacy; mirrors mode != once

    // The preset id last recalled. -1 once any manual PTZ command lands.
    int active_preset_id = -1;

    // Sequencer state (mirrored to clients via state event).
    bool sequence_running = false;
    int  sequence_step_index = -1;
    int  sequence_elapsed_s = 0;
    int  sequence_total_s = 0;
    std::string sequence_mode = "forward";  // once | forward | ping_pong

    // Library of saved sequences. Keys are user-chosen names (e.g.
    // "Morning service", "Vocalist rehearsal"). The currently-loaded
    // sequence's name (or empty if unsaved) is tracked separately.
    std::vector<std::string> available_sequences;
    std::string              loaded_sequence;  // empty = unsaved scratch

    std::string ai_mode = "none";
    std::string ai_sub_mode = "normal";
    bool ai_enabled = false;
    std::string tracking_mode = "standard";

    bool hdr = false;
    int fov = 86;
    int brightness = 50, contrast = 50, saturation = 50, sharpness = 50, hue = 50;
    bool face_ae = false;
    bool face_focus = false;
    bool auto_focus = true;
    int  manual_focus = 50;
    bool flip_h = false;
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

    DeviceSession();
    ~DeviceSession();

    // Start watching for cameras over USB. Non-blocking. Calls onState() whenever the snapshot changes.
    void start(StateCallback on_state);
    void stop();

    bool connected() const;
    DeviceSnapshot snapshot() const;

    // ---- commands (thread-safe; submit to internal queue) ----
    using ReplyFn = std::function<void(CmdResult)>;
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

    // public so the C-style SDK trampoline can forward into us
    void on_dev_changed(const std::string& sn, bool plugged);

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

    void motion_loop();
    std::thread       motion_thr_;
    std::mutex        motion_mu_;
    std::condition_variable motion_cv_;
    std::atomic<bool> motion_quit_{false};
    std::atomic<bool> motion_cancel_{false};
    std::atomic<bool> motion_busy_{false};
    MotionTarget      motion_pending_{};
    bool              motion_have_pending_ = false;

    // zoom coalescing (mid-drag updates)
    std::chrono::steady_clock::time_point last_zoom_apply_{};

    // Pending zoom target — when set, the periodic poller refuses to
    // overwrite snap_.zoom until the camera-reported value reaches this
    // value (within tolerance). Otherwise the camera's slow firmware echo
    // would clobber the value cmd_zoom_set / cmd_preset_recall just
    // stamped, and clients would see zoom visibly snap back. Cleared once
    // the camera catches up.
    float pending_zoom_ = 0.0f;  // 0 = no pending target

    // AI mode set timestamp — used to give camera firmware time to register
    // the new mode before the periodic poller re-reads cs.tiny.ai_mode.
    std::chrono::steady_clock::time_point last_ai_apply_{};

    // Pending AI mode target — same pattern as pending_zoom_. The camera
    // firmware echo for ai_mode lags the cmd by hundreds of ms; without
    // this gate the poller reads the old value and flips snap_.ai_mode
    // back. Cleared once the camera reports the commanded mode.
    std::string pending_ai_mode_;

    // hdr debounce
    std::chrono::steady_clock::time_point last_hdr_apply_{};

    // AI-mode-clear-on-first-manual flag — prevents flapping when user
    // streams velocity ticks 10-30 Hz, each one hitting cameraSetAiModeU.
    // Set on first manual ptz/preset, cleared by cmd_ai_set_mode/enabled.
    bool ai_disabled_for_manual_ = false;
};

}
