#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <json.hpp>

#include "device_session.h"   // LoopMode + CmdResult (reused by the mix engine)

namespace obs {

class VideoCapture;

// One step of a cross-camera MIX sequence. Unlike a per-camera SequenceStep
// (which only moves one gimbal), a cue also names which camera goes on air
// (`camera_sn` -> program) and optionally pre-positions a second camera while
// this cue holds (`meanwhile`). There is deliberately NO on-air movement lock:
// when a cue recalls a preset on the program camera, that camera moves LIVE on
// air - a real-cameraman push/pan is the whole point of a PTZ. `preset_id <= 0`
// means "hold the current shot" (just cut to the camera without moving it).
struct MixCue {
    std::string camera_sn;            // program camera for this cue
    int preset_id = -1;               // <0 = hold current shot (no recall).
                                      // 0..5 are real slots (P1..P6), so the
                                      // hold sentinel must be negative, not 0.
    int move_ms = 0;                  // live move duration (0 = instant snap)
    int hold_s = 10;                  // dwell after the move lands
    std::string transition = "cut";   // "cut" now; "fade" arrives in P4
    bool has_meanwhile = false;       // pre-position a second camera this cue
    std::string mw_sn;                // meanwhile: which camera
    int mw_preset_id = 0;             // meanwhile: preset to pre-position to
    int mw_move_ms = 0;               // meanwhile: move duration
};

// Parse the wire `cues` array / `mode` string into engine types (used by
// protocol.cpp to build mix.set / mix.save_as arguments).
std::vector<MixCue> parse_mix_cues(const nlohmann::json& cues_json);
LoopMode parse_mix_mode(const std::string& s);

// A generic (non-OBSBOT) video source: the built-in cam, a USB webcam, an
// iPhone. It has a capture but NO DeviceSession, because there is nothing to
// control - no PTZ, no presets, no libdev. Keyed in order_/captures_ by a
// synthetic id "av:<uniqueID>", so every SN-keyed map takes it verbatim and the
// "av:" prefix makes every OBSBOT-only assumption greppable.
struct SourceMeta {
    std::string id;         // "av:<uniqueID>"
    std::string label;      // localizedName, shown in the UI
    std::string unique_id;  // AVCaptureDevice.uniqueID (capture binds to this)
};

// Owns every attached camera for the lifetime of the process.
//
// One DeviceSession per camera (keyed by the 14-char serial number), each with
// its OWN worker + MotionPlanner threads. libdev's device-changed callback is
// the single source of truth for attach / detach; on macOS cameras enumerate
// late (one Tiny 2 Lite showed up ~6 s after launch, the second by ~20 s), so
// the callback - not a boot-time scan - is what populates the manager.
//
// The manager also owns the per-camera AVFoundation VideoCapture objects
// (keyed by SN) so the MJPEG server can stream any camera by SN, or follow the
// active camera. Captures are created / restarted on attach and stopped (never
// destroyed) on detach, which keeps every VideoCapture* the MJPEG serving
// threads hold stable for the whole process - no use-after-free when a camera
// unplugs mid-stream.
//
// Thread model: a single mutex guards the session map, attach order, active
// SN, and the capture map. State broadcasts assemble the full v2 envelope
// under that lock (reading each session's own snapshot, which is guarded by
// the session's separate mutex). The one rule that avoids deadlock: never hold
// the manager mutex while join()-ing a session thread - detach extracts the
// session pointer under the lock, releases it, THEN stops + joins.
class DeviceManager {
public:
    // Called with a fully-assembled, dumped v2 state event whenever anything
    // observable changes (a device attaches / detaches, the active camera
    // switches, or any session pushes a fresh snapshot).
    using Broadcaster = std::function<void(const std::string&)>;

    DeviceManager();
    ~DeviceManager();

    // Register the libdev attach / detach callback, disable mDNS scanning, and
    // start broadcasting. Non-blocking. Cameras appear asynchronously as their
    // plug-in events fire.
    void start(Broadcaster broadcaster);

    // Stop every session (joins their threads) and close the libdev singleton
    // exactly once. Safe to call from the signal path is NOT guaranteed - the
    // process uses _Exit(0) for signal shutdown (CLAUDE.md #14); this is the
    // clean-teardown path for tests / normal exit.
    void stop();

    // ---- state ----
    // Assemble the v2 state envelope:
    //   {"event":"state","version":"2.0","ts":..,"active_device_id":..,"devices":[..]}
    nlohmann::json build_state_event();
    // Compact per-device identity array for `hello` / `device.list` acks.
    nlohmann::json device_summaries();

    // Any-cam: every camera AVFoundation can see, each flagged `obsbot` (already
    // driven by libdev) and `in_use` (already bound to a session/source), so a
    // client can offer the rest as generic video sources. Bridge-scoped.
    nlohmann::json available_sources();

    // Add / remove a generic video source by AVFoundation uniqueID. add is
    // idempotent (re-adding a live source is a no-op ok). Both re-broadcast.
    CmdResult add_source(const std::string& unique_id, const std::string& label);
    CmdResult remove_source(const std::string& id);

    // ---- routing helpers (used by protocol.cpp) ----
    size_t device_count();
    std::string active_sn();
    // Exact SN lookup. Returns nullptr if no such camera is attached. Sessions
    // are shared_ptr so that a command dispatched on the WS thread keeps the
    // session alive even if a detach on the libdev thread removes it mid-call.
    std::shared_ptr<DeviceSession> session_by_sn(const std::string& sn);
    // Single-camera convenience: the sole attached session, or nullptr if the
    // count is not exactly 1.
    std::shared_ptr<DeviceSession> sole_session();

    // ---- device.* actions ----
    // Switch the active (OBS-routed) camera. Persists to active.json. If the
    // target is asleep it is woken first (implicit wake) before the switch.
    // Returns false + fills err_code ("not_found") for an unknown SN.
    //
    // fade_ms > 0 starts a fade-from-black window: the active MJPEG stream
    // ramps the incoming camera up from black over fade_ms (~500). 0 = hard cut.
    bool set_active(const std::string& sn, std::string& err_code, int fade_ms = 0);

    // Progress of an in-flight program transition on the active stream:
    // returns 1.0 when no transition is running, else 0..1 (0 = outgoing frame,
    // 1 = incoming). When a fade is running, `outgoing` is filled with the
    // frozen frame from the camera that was on air at the switch, so the MJPEG
    // server can dissolve it into the live incoming frames (jpeg_crossfade). If
    // `outgoing` comes back empty (first take, nothing to dissolve from), the
    // server falls back to fade-from-black. Cheap; safe to call per frame.
    float active_fade(std::vector<uint8_t>& outgoing);
    // Set / clear the friendly name (empty clears). Persists to
    // device_names.json. Returns false + "not_found" for an unknown SN.
    bool rename(const std::string& sn, const std::string& name, std::string& err_code);

    // ---- MJPEG join ----
    // Stable VideoCapture* for a camera by SN (or nullptr if unknown). Never
    // freed for the process lifetime, so the pointer is safe to use after the
    // manager lock is released.
    VideoCapture* capture_for(const std::string& sn);

    // Retry starting every attached camera's capture that is not already
    // running. Idempotent (a running capture is a no-op). Called when the
    // macOS camera permission is granted AFTER the attach-time capture starts
    // already timed out on an unanswered prompt - otherwise preview stays dead
    // until a manual restart. Does its AVFoundation I/O with mu_ released.
    void retry_pending_captures();

    // ---- mix.* actions (cross-camera sequencer) ----
    // The mix engine lives here (not on a session) because a cue spans cameras:
    // it switches the program (set_active) and drives preset recalls on any
    // session. It runs its own thread and never holds mu_ while calling
    // set_active()/session_by_sn() (both take mu_ themselves).
    void mix_set(const std::vector<MixCue>& cues, LoopMode mode);   // + persist scratch
    CmdResult mix_start();
    CmdResult mix_stop();
    CmdResult mix_save_as(const std::string& name,
                          const std::vector<MixCue>& cues, LoopMode mode);
    CmdResult mix_load(const std::string& name);
    CmdResult mix_delete(const std::string& name);

private:
    void on_dev_changed(const std::string& sn, bool plugged);
    void attach(const std::string& sn);
    void detach(const std::string& sn);
    // Assemble + hand the current envelope to the broadcaster. Must NOT be
    // called while holding mu_.
    void broadcast();
    // Recompute active_sn_ after the session set changed. Caller holds mu_.
    void recompute_active_locked();
    // Start (or restart) the per-SN capture bound to the given AVFoundation
    // uniqueID. Caller holds mu_.

    std::mutex mu_;
    std::map<std::string, std::shared_ptr<DeviceSession>> sessions_;
    std::vector<std::string> order_;   // SNs in attach order (drives devices[])
    std::map<std::string, std::unique_ptr<VideoCapture>> captures_;
    // sn -> AVFoundation uniqueID last bound for that camera's capture, so
    // retry_pending_captures() can re-issue start_unique_id after a late
    // permission grant.
    std::map<std::string, std::string> capture_uid_;

    // Generic (non-OBSBOT) sources, keyed by their "av:<uniqueID>" id. These
    // have an entry in order_ + captures_ + capture_uid_ but NO session, so
    // build_state_event emits a stripped entry for them.
    std::map<std::string, SourceMeta> sources_;
    std::string active_sn_;
    std::string desired_active_;       // persisted preference, loaded at start()
    Broadcaster broadcaster_;
    // Read on the WS worker thread (mix_start's teardown guard) and written on
    // the WS/main thread in start()/stop(); atomic so the guard is race-free.
    std::atomic<bool> started_{false};

    // Program-transition state for the active stream (set by set_active with
    // fade_ms>0, read per-frame by active_fade()). fade_outgoing_ is the frozen
    // frame from the camera that was on air at the switch, dissolved into the
    // incoming camera's live frames over the window.
    std::mutex fade_mu_;
    std::chrono::steady_clock::time_point fade_start_{};
    int fade_ms_ = 0;
    std::vector<uint8_t> fade_outgoing_;

    // ---- mix engine ----
    // Guards the cue list + run cursor. Separate from mu_ so the mix thread can
    // call set_active()/session_by_sn() (which take mu_) without self-deadlock.
    void mix_loop();
    nlohmann::json mix_state_locked();      // caller holds mix_mu_
    nlohmann::json mix_state();             // takes mix_mu_
    // Serialises the ENTIRE mix_start / mix_stop / teardown transition
    // (running-check + signal + join + relaunch of mix_thr_). Unlike the
    // per-camera sequencer, mix commands run directly on Crow worker threads,
    // so two concurrent WS clients could otherwise race the std::thread object
    // (double-join, or move-assign onto a joinable thread -> std::terminate).
    // The mix loop NEVER takes this mutex, so holding it across join() is safe.
    std::mutex mix_ctl_mu_;
    std::mutex mix_mu_;
    std::condition_variable mix_cv_;
    std::vector<MixCue> mix_cues_;
    LoopMode mix_mode_ = LoopMode::forward;
    std::string mix_loaded_;                // library name, "" = scratch
    std::vector<std::string> mix_available_; // saved-library names (cached)
    std::atomic<bool> mix_running_{false};
    std::atomic<bool> mix_quit_{false};
    std::thread mix_thr_;
    int mix_cue_index_ = -1;                // -1 idle
    int mix_direction_ = 1;                 // ping_pong direction
    std::string mix_phase_ = "holding";     // "moving" | "holding"
    int mix_elapsed_s_ = 0;
    int mix_total_s_ = 0;
};

}  // namespace obs
