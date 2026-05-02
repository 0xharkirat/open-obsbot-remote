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
enum class MoveSpeed { instant, slow, medium, fast };

struct SequenceStep {
    int preset_id = 0;
    int seconds = 60;
    MoveSpeed speed = MoveSpeed::medium;
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

    // The preset id last recalled. -1 once any manual PTZ command lands.
    int active_preset_id = -1;

    // Sequencer state (mirrored to clients via state event).
    bool sequence_running = false;
    int  sequence_step_index = -1;
    int  sequence_elapsed_s = 0;
    int  sequence_total_s = 0;
    std::string sequence_mode = "forward";  // once | forward | ping_pong

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
    void cmd_ptz_angle(float yaw, float pitch, float roll, ReplyFn reply);
    void cmd_ptz_velocity(float yaw_speed, float pitch_speed, float roll_speed, ReplyFn reply);
    void cmd_ptz_stop(ReplyFn reply);
    void cmd_ptz_recenter(ReplyFn reply);
    void cmd_zoom_set(float value, ReplyFn reply);
    void cmd_zoom_set_smooth(float value, int speed, ReplyFn reply);
    void cmd_ai_set_mode(const std::string& mode, const std::string& sub, ReplyFn reply);
    void cmd_ai_set_enabled(bool enabled, ReplyFn reply);
    void cmd_image_set_hdr(bool enabled, ReplyFn reply);
    void cmd_image_set_fov(int fov, ReplyFn reply);
    void cmd_image_set_brightness(int v, ReplyFn reply);
    void cmd_image_set_contrast(int v, ReplyFn reply);
    void cmd_image_set_saturation(int v, ReplyFn reply);
    void cmd_image_set_sharpness(int v, ReplyFn reply);
    void cmd_image_set_face_ae(bool e, ReplyFn reply);
    void cmd_image_set_face_focus(bool e, ReplyFn reply);
    void cmd_image_set_flip_h(bool e, ReplyFn reply);
    void cmd_system_run_status(const std::string& s, ReplyFn reply);
    void cmd_preset_recall(int id, MoveSpeed speed, ReplyFn reply);
    void cmd_preset_save(int id, const std::string& name, ReplyFn reply);
    void cmd_preset_delete(int id, ReplyFn reply);

    // Sequencer.
    void cmd_sequence_set(const std::vector<SequenceStep>& steps, LoopMode mode, ReplyFn reply);
    void cmd_sequence_start(ReplyFn reply);
    void cmd_sequence_stop(ReplyFn reply);

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

    // hdr debounce
    std::chrono::steady_clock::time_point last_hdr_apply_{};
};

}
