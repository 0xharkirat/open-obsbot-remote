#pragma once

#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include <json.hpp>

namespace obs {

class DeviceSession;
class VideoCapture;

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
    bool set_active(const std::string& sn, std::string& err_code);
    // Set / clear the friendly name (empty clears). Persists to
    // device_names.json. Returns false + "not_found" for an unknown SN.
    bool rename(const std::string& sn, const std::string& name, std::string& err_code);

    // ---- MJPEG join ----
    // Stable VideoCapture* for a camera by SN (or nullptr if unknown). Never
    // freed for the process lifetime, so the pointer is safe to use after the
    // manager lock is released.
    VideoCapture* capture_for(const std::string& sn);

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
    std::string active_sn_;
    std::string desired_active_;       // persisted preference, loaded at start()
    Broadcaster broadcaster_;
    bool started_ = false;
};

}  // namespace obs
