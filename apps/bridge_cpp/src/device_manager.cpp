#include "device_manager.h"
#include "device_session.h"
#include "video_capture.h"
#include "protocol.h"
#include "persist.h"
#include "log.h"

#include <dev/devs.hpp>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <set>

namespace obs {

static int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

// Default fade-from-black duration for a "fade" transition (mix cue or TAKE).
static constexpr int kDefaultFadeMs = 500;

// CmdResult helpers, defined lower down but used by add_source/remove_source
// (which sit above them so the source API reads next to available_sources).
static CmdResult mok();
static CmdResult merr(const char* code, const std::string& msg);

// LoopMode <-> string. The per-camera sequencer has its own file-local copies
// in device_session.cpp; these small twins keep the mix engine self-contained
// rather than exporting them across a header. ponytail: two five-line funcs is
// less machinery than a new shared header for one enum.
static const char* loop_mode_str(LoopMode m) {
    switch (m) {
        case LoopMode::once:      return "once";
        case LoopMode::forward:   return "forward";
        case LoopMode::ping_pong: return "ping_pong";
    }
    return "forward";
}
static LoopMode parse_loop_mode(const std::string& s) {
    if (s == "once") return LoopMode::once;
    if (s == "ping_pong") return LoopMode::ping_pong;
    return LoopMode::forward;
}

static nlohmann::json cue_to_json(const MixCue& c) {
    nlohmann::json j{
        {"preset_id", c.preset_id},
        {"hold_s",    c.hold_s},
        {"enabled",   c.enabled},
        {"fade_ms",   c.fade_ms},
        {"move_ms",   c.move_ms},
    };
    // Emit a camera ONLY when it is genuinely pinned. A derived cue carries no
    // serial at all, which is precisely what makes a saved sequence portable to
    // any rig - export it, import it on another machine, and it still runs.
    // The legacy `meanwhile` and `transition` fields are deliberately not
    // written back: both are now derived, so re-saving an old file migrates it.
    if (!c.camera_sn.empty()) j["camera_sn"] = c.camera_sn;
    return j;
}

static MixCue cue_from_json(const nlohmann::json& j) {
    MixCue c;
    c.preset_id = j.value("preset_id", -1);   // absent = hold current shot
    c.hold_s    = j.value("hold_s", 10);
    c.enabled   = j.value("enabled", true);   // absent (pre-2.1) = enabled
    c.move_ms   = j.value("move_ms", 0);
    c.camera_sn = j.value("camera_sn", std::string{});  // now a PIN, not program
    if (c.hold_s < 1) c.hold_s = 1;
    if (c.move_ms < 0) c.move_ms = 0;

    // fade_ms is authoritative. A pre-2.1 file has no fade_ms, only a
    // transition string, so migrate it and preserve the old behaviour exactly:
    // "fade" was a 500ms crossfade, "cut" was instant.
    if (j.contains("fade_ms") && j["fade_ms"].is_number()) {
        c.fade_ms = j["fade_ms"].get<int>();
        if (c.fade_ms < -1)   c.fade_ms = -1;      // <0 = inherit the default
        if (c.fade_ms > 5000) c.fade_ms = 5000;
    } else {
        c.transition = j.value("transition", std::string("cut"));
        c.fade_ms = (c.transition == "fade") ? kDefaultFadeMs : 0;
    }

    // The meanwhile is derived now - it was always just "the next cue that needs
    // the other camera". Parse it so old files load, then let the solver
    // recompute it. Nothing here is read again.
    if (j.contains("meanwhile") && j["meanwhile"].is_object()) {
        auto& m = j["meanwhile"];
        c.has_meanwhile = true;
        c.mw_sn        = m.value("camera_sn", std::string{});
        c.mw_preset_id = m.value("preset_id", 0);
        c.mw_move_ms   = m.value("move_ms", 0);
    }
    return c;
}

static std::vector<MixCue> cues_from_json(const nlohmann::json& arr) {
    std::vector<MixCue> out;
    if (arr.is_array()) {
        for (auto& j : arr) {
            if (j.is_object()) out.push_back(cue_from_json(j));
        }
    }
    return out;
}

std::vector<MixCue> parse_mix_cues(const nlohmann::json& cues_json) {
    return cues_from_json(cues_json);
}
LoopMode parse_mix_mode(const std::string& s) { return parse_loop_mode(s); }

DeviceManager::DeviceManager() {}
DeviceManager::~DeviceManager() { stop(); }

void DeviceManager::start(Broadcaster broadcaster) {
    broadcaster_ = std::move(broadcaster);
    // Persisted preference: the camera the operator last routed to OBS. If it
    // is absent when cameras attach, recompute_active_locked falls back to the
    // first-attached camera.
    desired_active_ = persist::load_active_device();
    active_sn_.clear();
    // Rehydrate the active mix scratch so the editor shows the last-authored
    // cross-camera sequence on reopen (mirrors the per-camera scratch). Wrapped
    // in try/catch: a hand-edited mix.json with a wrong-typed field would throw
    // nlohmann::type_error, and a bricked launch mid-service is unacceptable -
    // fall back to an empty scratch instead.
    try {
        nlohmann::json m = persist::load_active_mix();
        nlohmann::json lib = persist::load_mix_library();
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues_from_json(m.value("cues", nlohmann::json::array()));
        mix_mode_ = parse_loop_mode(m.value("mode", std::string("forward")));
        for (auto& it : lib.items()) mix_available_.push_back(it.key());
        std::sort(mix_available_.begin(), mix_available_.end());
    } catch (const std::exception& e) {
        LOGW("mix: failed to rehydrate scratch/library (%s); starting empty",
             e.what());
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_.clear();
        mix_mode_ = LoopMode::forward;
    }
    started_ = true;

    Devices::get().setDevChangedCallback(
        [this](std::string sn, bool plugged, void* /*ud*/) {
            LOGI("device %s sn=%s", plugged ? "plugged" : "unplugged", sn.c_str());
            if (plugged) attach(sn);
            else         detach(sn);
        },
        nullptr);
    Devices::get().setEnableMdnsScan(false);

    // AVFoundation hotplug watch for GENERIC sources: unplug stops the capture
    // (state flips connected:false), replug of a known uniqueID restarts it.
    // OBSBOT cameras are untouched - the libdev callback above owns their
    // attach / detach. `this` outlives the process (main blocks in
    // run_ws_server), the same lifetime argument as the libdev callback.
    observe_av_devices([this](std::string uid, bool connected) {
        on_av_device_changed(uid, connected);
    });

    // Re-add generic sources persisted in sources.json. On a detached thread:
    // add_source starts the capture, which touches AVFoundation (the TCC
    // prompt can block for 60s) and retries ~3s for an absent device - neither
    // may stall boot. A device absent at boot stays listed with
    // connected:false (its capture never starts, no retry loop) until the
    // hotplug observer above sees it return.
    auto saved = persist::load_sources();
    if (!saved.empty()) {
        LOGI("source: restoring %zu persisted generic source(s)", saved.size());
        std::thread([this, saved = std::move(saved)]() {
            for (auto& [uid, label] : saved) add_source(uid, label);
        }).detach();
    }

    LOGI("device manager started; desired active='%s'; waiting for cameras...",
         desired_active_.c_str());
}

void DeviceManager::stop() {
    if (!started_) return;
    started_ = false;
    Devices::get().setDevChangedCallback(nullptr, nullptr);

    // Stop the mix engine before sessions die: mix_loop touches sessions.
    // Under mix_ctl_mu_ so a concurrent mix_start on a WS worker cannot
    // relaunch the thread after this join and before sessions_ is cleared.
    {
        std::lock_guard<std::mutex> ctl(mix_ctl_mu_);
        mix_running_ = false;
        mix_quit_ = true;
        mix_cv_.notify_all();
        if (mix_thr_.joinable()) mix_thr_.join();
    }

    std::vector<std::shared_ptr<DeviceSession>> dead;
    {
        std::lock_guard<std::mutex> g(mu_);
        for (auto& kv : sessions_) dead.push_back(kv.second);
        sessions_.clear();
        order_.clear();
        for (auto& kv : captures_) kv.second->stop();
    }
    // Join session threads with mu_ released (a worker may be mid-broadcast,
    // blocked on mu_).
    for (auto& d : dead) if (d) d->stop();
    dead.clear();

    // Close the libdev singleton exactly once, here. One camera detaching must
    // never do this (it would kill every other camera).
    Devices::get().close();
}

void DeviceManager::attach(const std::string& sn) {
    auto dev = Devices::get().getDevBySn(sn);
    if (!dev) {
        LOGW("attach: device %s not yet in libdev list; ignoring", sn.c_str());
        return;
    }
    // The SN -> capture-device join. On macOS this is videoDevPath(), the
    // AVFoundation uniqueID byte-for-byte; on Linux the SDK has no such method
    // and device_video_path() resolves a /dev/video* node instead. Captured
    // here synchronously; the session's own copy is hydrated asynchronously by
    // attach() below.
    std::string uid = device_video_path(dev.get());

    VideoCapture* cap = nullptr;
    {
        std::lock_guard<std::mutex> g(mu_);
        std::shared_ptr<DeviceSession> s;
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) {
            s = std::make_shared<DeviceSession>(sn);
            sessions_[sn] = s;
            order_.push_back(sn);
            // Every snapshot push from this session's worker re-broadcasts the
            // full multi-cam envelope.
            s->start([this](const DeviceSnapshot&) { broadcast(); });
        } else {
            s = it->second;   // re-attach (spurious replug / port change)
        }
        s->attach(dev);
        // Create or rebind the capture SLOT under the lock, but do NOT
        // start it here. Starting touches AVFoundation - the TCC prompt
        // plus device open can take seconds (an unanswered prompt:
        // forever), and holding mu_ across that starves every WS
        // handler; hello needs this lock for the devices summary, so
        // the whole bridge looked dead. Found live on the first
        // two-camera run.
        if (uid.empty()) {
            LOGW("capture: device %s has no video dev path; preview disabled",
                 sn.c_str());
        } else {
            auto cit = captures_.find(sn);
            if (cit == captures_.end()) {
                captures_[sn] = std::make_unique<VideoCapture>();
                cit = captures_.find(sn);
            } else {
                // Camera may have moved USB ports, which changes its
                // AVFoundation uniqueID; stop before rebinding below.
                cit->second->stop();
            }
            cap = cit->second.get();
            capture_uid_[sn] = uid;   // remembered for late-grant retry
        }
        recompute_active_locked();
    }
    // Slow I/O outside the lock. Safe: attach/detach serialize on the
    // libdev hotplug thread, so this capture slot cannot be erased
    // underneath us; MJPEG threads only resolve the pointer under mu_.
    if (cap != nullptr) {
        if (cap->start_unique_id(uid)) {
            LOGI("capture: %s streaming from uid=%s", sn.c_str(), uid.c_str());
        } else {
            LOGW("capture: %s failed to start (uid=%s); preview unavailable until replug",
                 sn.c_str(), uid.c_str());
        }
    }
    // The roster just changed, and the roster IS the colour palette: a third
    // camera makes an odd loop solvable, a second one makes crossfades possible
    // at all. Re-solve. mu_ is released by here - mix_replan() takes it itself,
    // and taking it twice would deadlock the process.
    mix_replan();
    broadcast();
}

void DeviceManager::detach(const std::string& sn) {
    std::shared_ptr<DeviceSession> dead;
    {
        std::lock_guard<std::mutex> g(mu_);
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) return;
        dead = it->second;
        sessions_.erase(it);
        order_.erase(std::remove(order_.begin(), order_.end(), sn), order_.end());
        // Stop this camera's capture but KEEP the object so MJPEG threads that
        // hold its pointer never dangle.
        auto cit = captures_.find(sn);
        if (cit != captures_.end()) cit->second->stop();
        recompute_active_locked();
    }
    // Join the session's worker + motion + sequence threads with mu_ released.
    if (dead) dead->stop();
    dead.reset();
    // A camera left, so the colouring changes (and a running mix may now be
    // down to one camera, where every transition has to move on air). Re-solve.
    mix_replan();
    broadcast();
}

void DeviceManager::recompute_active_locked() {
    // A persisted preference wins whenever it is actually attached (covers the
    // boot race where a non-preferred camera enumerates first, and restores the
    // preference when it replugs).
    if (!desired_active_.empty() && sessions_.count(desired_active_)) {
        active_sn_ = desired_active_;
        return;
    }
    // Keep the current active if it is still attached.
    if (!active_sn_.empty() && sessions_.count(active_sn_)) return;
    // Otherwise fall back to the first-attached camera (or none).
    active_sn_ = order_.empty() ? std::string{} : order_.front();
}


void DeviceManager::broadcast() {
    if (!broadcaster_) return;
    try {
        broadcaster_(build_state_event().dump());
    } catch (...) {}
}

// A generic source has no DeviceSession, so it has no DeviceSnapshot to run
// through build_device_entry. Emit a stripped entry: identity + connected, the
// "video" kind so the UI hides the PTZ/preset/image controls, and empty preset
// list. Everything else the Dart DeviceState defaults (it reads every block as
// `?? default`), so a control-less source parses cleanly. `connected` is
// simply "is its capture running" - a source unplugged (or absent at boot)
// stays listed, just disconnected.
static nlohmann::json source_state_entry(const SourceMeta& m, bool connected) {
    return nlohmann::json{
        {"device_id", m.id},
        {"kind", "video"},
        {"device", {
            {"sn", m.id},
            {"model_display", m.label},
            {"firmware", ""},
            {"connected", connected},
            {"run_status", connected ? "run" : "unknown"},
            {"friendly_name", m.label},
        }},
        {"presets", nlohmann::json::array()},
        {"active_preset_id", -1},
    };
}

nlohmann::json DeviceManager::build_state_event() {
    std::lock_guard<std::mutex> g(mu_);
    nlohmann::json devs = nlohmann::json::array();
    for (auto& sn : order_) {
        auto it = sessions_.find(sn);
        if (it != sessions_.end()) {
            devs.push_back(build_device_entry(it->second->snapshot()));
            continue;
        }
        auto sit = sources_.find(sn);
        if (sit != sources_.end()) {
            // running() is a lock-free atomic read, safe under mu_.
            auto cit = captures_.find(sn);
            const bool conn = cit != captures_.end() && cit->second->running();
            devs.push_back(source_state_entry(sit->second, conn));
        }
    }
    nlohmann::json ev{
        {"event", "state"},
        {"version", "2.0"},
        {"ts", now_ms()},
        {"active_device_id", active_sn_},
        {"devices", std::move(devs)},
        {"mix", mix_state()},
    };
    // Omitted entirely rather than sent as a disabled stub when there is no
    // recorder, so a client can tell "this build cannot record" from "this
    // build is not recording right now".
    if (recording_status_fn_) {
        try {
            ev["recording"] = recording_status_fn_();
        } catch (...) {}
    }
    return ev;
}

void DeviceManager::set_recording_status_fn(StatusFn fn) {
    std::lock_guard<std::mutex> g(mu_);
    recording_status_fn_ = std::move(fn);
}

void DeviceManager::set_record_action_fn(ActionFn fn) {
    std::lock_guard<std::mutex> g(mu_);
    record_action_fn_ = std::move(fn);
}

CmdResult DeviceManager::dispatch_record(const std::string& action,
                                         const nlohmann::json& msg) {
    ActionFn fn;
    {
        std::lock_guard<std::mutex> g(mu_);
        fn = record_action_fn_;
    }
    if (!fn) {
        return {false, "not_supported", "this build has no recorder"};
    }
    // Called with the lock released: start() reaches back into capture_for()
    // and active_sn(), both of which take mu_.
    return fn(action, msg);
}

nlohmann::json DeviceManager::recording_status() {
    StatusFn fn;
    {
        std::lock_guard<std::mutex> g(mu_);
        fn = recording_status_fn_;
    }
    if (!fn) return nlohmann::json();
    try { return fn(); } catch (...) { return nlohmann::json(); }
}

void DeviceManager::notify_state_changed() { broadcast(); }

nlohmann::json DeviceManager::available_sources() {
    // Snapshot which uniqueIDs are already bound (OBSBOT sessions store their
    // uid in capture_uid_) so the UI can grey those out. Held under mu_.
    std::set<std::string> in_use;
    {
        std::lock_guard<std::mutex> g(mu_);
        for (auto& kv : capture_uid_) {
            if (!kv.second.empty()) in_use.insert(kv.second);
        }
    }
    nlohmann::json arr = nlohmann::json::array();
    for (const auto& d : list_av_devices()) {
        arr.push_back({
            {"unique_id", d.unique_id},
            {"name", d.name},
            {"obsbot", d.is_obsbot},
            {"in_use", in_use.count(d.unique_id) > 0},
        });
    }
    return arr;
}

CmdResult DeviceManager::add_source(const std::string& unique_id,
                                    const std::string& label) {
    if (unique_id.empty()) return merr("invalid_param", "unique_id required");
    const std::string id = "av:" + unique_id;
    const std::string lbl = label.empty() ? id : label;
    VideoCapture* cap = nullptr;
    {
        std::lock_guard<std::mutex> g(mu_);
        if (captures_.count(id)) return mok();   // idempotent: already added
        // Never shadow an OBSBOT camera already bound to a session.
        for (auto& kv : capture_uid_) {
            if (kv.second == unique_id)
                return merr("in_use", "that camera is already a source");
        }
        auto vc = std::make_unique<VideoCapture>();
        cap = vc.get();
        captures_[id] = std::move(vc);
        capture_uid_[id] = unique_id;
        sources_[id] = SourceMeta{id, lbl, unique_id};
        order_.push_back(id);
        if (active_sn_.empty()) active_sn_ = id;   // first source goes on air
    }
    persist::store_source(unique_id, lbl);   // survive a bridge restart
    // Start capture with mu_ released: it touches AVFoundation (and may block on
    // the TCC prompt), exactly as attach() does for OBSBOT captures.
    if (cap) {
        if (cap->start_unique_id(unique_id))
            LOGI("source: added %s '%s'", id.c_str(), lbl.c_str());
        else
            LOGW("source: %s failed to start (uid=%s); preview unavailable",
                 id.c_str(), unique_id.c_str());
    }
    broadcast();
    return mok();
}

CmdResult DeviceManager::remove_source(const std::string& id) {
    VideoCapture* cap = nullptr;
    std::string uid;
    {
        std::lock_guard<std::mutex> g(mu_);
        auto sit = sources_.find(id);
        if (sit == sources_.end()) return merr("not_found", "no source " + id);
        uid = sit->second.unique_id;
        auto cit = captures_.find(id);
        if (cit != captures_.end()) {
            cap = cit->second.get();
            // Retire, never destroy: MJPEG serving threads (capture_for) and
            // the AV hotplug observer hold raw VideoCapture* across mu_, so
            // destroying here is a use-after-free on a phone streaming this
            // source at the moment of removal. Same immortality rule the
            // OBSBOT captures follow; one stopped object per remove is the
            // price of never crashing a serving thread.
            retired_captures_.push_back(std::move(cit->second));
            captures_.erase(cit);
        }
        capture_uid_.erase(id);
        sources_.erase(sit);
        order_.erase(std::remove(order_.begin(), order_.end(), id), order_.end());
        if (active_sn_ == id) recompute_active_locked();
    }
    if (cap) cap->stop();   // AVFoundation I/O with mu_ released
    persist::store_source(uid, "");   // empty label = remove the entry
    LOGI("source: removed %s", id.c_str());
    broadcast();
    return mok();
}

bool DeviceManager::is_source(const std::string& id) {
    std::lock_guard<std::mutex> g(mu_);
    return sources_.count(id) > 0;
}

void DeviceManager::on_av_device_changed(const std::string& unique_id,
                                         bool connected) {
    // Resolve the uniqueID to a known generic source. An OBSBOT camera's uid
    // never lives in sources_ (add_source refuses uids bound to a session),
    // so this early-out is what keeps libdev's attach / detach authoritative
    // for OBSBOT cameras.
    std::string id;
    VideoCapture* cap = nullptr;
    {
        std::lock_guard<std::mutex> g(mu_);
        for (auto& kv : sources_) {
            if (kv.second.unique_id == unique_id) { id = kv.first; break; }
        }
        if (id.empty()) return;   // not a generic source
        auto cit = captures_.find(id);
        if (cit != captures_.end()) cap = cit->second.get();
    }
    if (cap == nullptr) return;
    // Capture start / stop + broadcast with mu_ released, per the add_source
    // discipline; VideoCapture::ctl_mu_ serialises against concurrent starts
    // (e.g. the boot rehydrate thread racing an arrival notification).
    if (connected) {
        if (cap->running()) return;   // already streaming; nothing to do
        if (cap->start_unique_id(unique_id))
            LOGI("source: %s reconnected", id.c_str());
        else
            LOGW("source: %s reappeared but capture failed to start", id.c_str());
    } else {
        // Stop so state flips connected:false and the MJPEG route 503s instead
        // of serving the last frozen frame.
        cap->stop();
        LOGI("source: %s disconnected", id.c_str());
    }
    broadcast();
}

nlohmann::json DeviceManager::device_summaries() {
    std::lock_guard<std::mutex> g(mu_);
    nlohmann::json arr = nlohmann::json::array();
    for (auto& sn : order_) {
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) continue;
        arr.push_back(device_summary(it->second->snapshot(), sn == active_sn_));
    }
    return arr;
}

size_t DeviceManager::device_count() {
    std::lock_guard<std::mutex> g(mu_);
    return sessions_.size();
}

std::string DeviceManager::active_sn() {
    std::lock_guard<std::mutex> g(mu_);
    return active_sn_;
}

std::shared_ptr<DeviceSession> DeviceManager::session_by_sn(const std::string& sn) {
    std::lock_guard<std::mutex> g(mu_);
    auto it = sessions_.find(sn);
    return it == sessions_.end() ? nullptr : it->second;
}

std::shared_ptr<DeviceSession> DeviceManager::sole_session() {
    std::lock_guard<std::mutex> g(mu_);
    if (sessions_.size() != 1) return nullptr;
    return sessions_.begin()->second;
}

bool DeviceManager::set_active(const std::string& sn, std::string& err_code,
                              int fade_ms) {
    {
        std::lock_guard<std::mutex> g(mu_);
        auto it = sessions_.find(sn);
        // A generic source has no session but is still a valid program target:
        // accept it if it has a capture. Only the sleep/wake block below is
        // session-specific (a webcam does not sleep the way an OBSBOT does).
        const bool has_session = (it != sessions_.end());
        if (!has_session && captures_.find(sn) == captures_.end()) {
            err_code = "not_found";
            return false;
        }
        const std::string old_active = active_sn_;   // outgoing camera
        active_sn_ = sn;
        desired_active_ = sn;
        // Set the transition window atomically with active_sn_ (no 1-frame flash
        // at the start) and UNCONDITIONALLY: a cut (fade_ms == 0) must CLEAR any
        // fade still in progress, or the cut inherits the leftover dissolve - the
        // exact bug an operator hits fading then cutting back. fade_mu_ is a leaf
        // lock, so nesting it under mu_ keeps lock order consistent.
        {
            std::lock_guard<std::mutex> fg(fade_mu_);
            fade_ms_ = fade_ms > 0 ? fade_ms : 0;
            fade_start_ = std::chrono::steady_clock::now();
            // For a fade, freeze the outgoing camera's current frame so the MJPEG
            // server can dissolve it into the incoming camera's live frames. On a
            // cut, clear it. capture_for() would re-lock mu_ (held here), so read
            // captures_ directly. latest_jpeg() takes the capture's own lock.
            fade_outgoing_.clear();
            if (fade_ms > 0 && !old_active.empty()) {
                auto cit = captures_.find(old_active);
                if (cit != captures_.end() && cit->second) {
                    fade_outgoing_ = cit->second->latest_jpeg();
                }
            }
        }
        // Implicit wake: if the target is asleep, wake it before it goes live
        // so OBS (which consumes /preview/active.mjpg) does not pull a black
        // stream. Async - the camera takes ~1 s to wake regardless. Sources
        // have no session and never sleep, so this whole block is OBSBOT-only.
        if (has_session && it->second->snapshot().run_status == 3 /*sleep*/) {
            LOGI("set_active: %s is asleep, waking before switch", sn.c_str());
            it->second->cmd_system_run_status("run", [](CmdResult) {});
            // The camera's UVC video interface drops while asleep and returns a
            // second or so after waking; AVFoundation does not auto-rebind, so
            // the capture would stay dead (blank preview + OBS feed) even though
            // the camera is awake. Restart it on a detached thread -
            // start_unique_id retries internally, covering the wake latency, and
            // VideoCapture::ctl_mu_ serialises this against attach/detach.
            auto cit = captures_.find(sn);
            auto uidit = capture_uid_.find(sn);
            if (cit != captures_.end() && cit->second &&
                uidit != capture_uid_.end() && !uidit->second.empty()) {
                VideoCapture* cap = cit->second.get();
                const std::string uid = uidit->second;
                std::thread([cap, uid]() {
                    cap->stop();
                    cap->start_unique_id(uid);
                }).detach();
            }
        }
    }
    persist::store_active_device(sn);
    broadcast();
    return true;
}

float DeviceManager::active_fade(std::vector<uint8_t>& outgoing) {
    std::lock_guard<std::mutex> g(fade_mu_);
    if (fade_ms_ <= 0) return 1.0f;
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - fade_start_).count();
    if (elapsed >= fade_ms_) {                 // transition complete
        fade_ms_ = 0;
        fade_outgoing_.clear();
        return 1.0f;
    }
    outgoing = fade_outgoing_;                 // frozen frame to dissolve from
    const float f = static_cast<float>(elapsed) / static_cast<float>(fade_ms_);
    return f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f);
}

bool DeviceManager::rename(const std::string& sn, const std::string& name,
                           std::string& err_code) {
    // Trim surrounding whitespace, cap at 60 chars. Empty clears the name.
    std::string trimmed = name;
    auto not_space = [](unsigned char ch) { return !std::isspace(ch); };
    trimmed.erase(trimmed.begin(),
                  std::find_if(trimmed.begin(), trimmed.end(), not_space));
    trimmed.erase(std::find_if(trimmed.rbegin(), trimmed.rend(), not_space).base(),
                  trimmed.end());
    if (trimmed.size() > 60) trimmed = trimmed.substr(0, 60);

    {
        std::lock_guard<std::mutex> g(mu_);
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) { err_code = "not_found"; return false; }
        it->second->set_friendly_name(trimmed);   // stamp-only; no broadcast
    }
    persist::store_device_name(sn, trimmed);
    broadcast();
    return true;
}

VideoCapture* DeviceManager::capture_for(const std::string& sn) {
    std::lock_guard<std::mutex> g(mu_);
    auto it = captures_.find(sn);
    return it == captures_.end() ? nullptr : it->second.get();
}

void DeviceManager::retry_pending_captures() {
    // Snapshot the not-yet-running captures + their uids under the lock, then
    // do the slow AVFoundation start OUTSIDE it (same rule as attach(): never
    // hold mu_ across a capture start - it starves every WS handler).
    std::vector<std::pair<VideoCapture*, std::string>> pending;
    {
        std::lock_guard<std::mutex> g(mu_);
        for (auto& kv : captures_) {
            VideoCapture* cap = kv.second.get();
            if (cap == nullptr || cap->running()) continue;
            auto uit = capture_uid_.find(kv.first);
            if (uit == capture_uid_.end() || uit->second.empty()) continue;
            pending.emplace_back(cap, uit->second);
        }
    }
    if (pending.empty()) return;
    LOGI("capture: retrying %zu pending capture(s) after permission grant",
         pending.size());
    for (auto& [cap, uid] : pending) {
        if (cap->start_unique_id(uid)) {
            LOGI("capture: retry started streaming from uid=%s", uid.c_str());
        } else {
            LOGW("capture: retry still failed for uid=%s", uid.c_str());
        }
    }
    broadcast();
}

// ---------------------------------------------------------------------------
// Mix engine (cross-camera sequencer)
// ---------------------------------------------------------------------------

static CmdResult mok() { return CmdResult{true, "", ""}; }
static CmdResult merr(const char* code, const std::string& msg) {
    return CmdResult{false, code, msg};
}

// Serialise the active scratch (cues + mode) to mix.json.
static void persist_mix_scratch(const std::vector<MixCue>& cues, LoopMode mode) {
    nlohmann::json m;
    m["mode"] = loop_mode_str(mode);
    m["cues"] = nlohmann::json::array();
    for (auto& c : cues) m["cues"].push_back(cue_to_json(c));
    persist::store_active_mix(m);
}

nlohmann::json DeviceManager::mix_state_locked() {
    nlohmann::json cues = nlohmann::json::array();
    for (auto& c : mix_cues_) cues.push_back(cue_to_json(c));

    // The solved plan. Camera and meanwhile are DERIVED, so the client renders
    // them read-only instead of asking the operator to retype a pointer the
    // engine already knows.
    nlohmann::json plan = nlohmann::json::array();
    for (const auto& pc : mix_plan_.cues) {
        nlohmann::json mw = nlohmann::json::array();
        for (const auto& m : pc.meanwhile) {
            mw.push_back({{"camera_sn", m.camera_sn}, {"preset_id", m.preset_id}});
        }
        plan.push_back({
            {"cue_index",   pc.cue_index},   // maps back to the authored card
            {"camera_sn",   pc.camera_sn},
            {"preset_id",   pc.preset_id},
            {"hold_s",      pc.hold_s},
            {"fade_ms",     pc.fade_ms},
            {"on_air_move", pc.on_air_move},
            {"move_ms",     pc.move_ms},
            {"meanwhile",   std::move(mw)},
        });
    }

    // The run cursor indexes the PLAN (enabled cues only). Hand the client the
    // AUTHORED index as `cue_index` so it can highlight the right card without
    // redoing the mapping, and the raw plan cursor separately.
    int live_cue = -1;
    if (mix_cue_index_ >= 0 && mix_cue_index_ < (int)mix_plan_.cues.size())
        live_cue = mix_plan_.cues[mix_cue_index_].cue_index;

    return nlohmann::json{
        {"running",    mix_running_.load()},
        {"cue_index",  live_cue},
        {"plan_index", mix_cue_index_},
        {"cue_count",  (int)mix_cues_.size()},
        {"phase",      mix_phase_},
        {"elapsed_s",  mix_elapsed_s_},
        {"total_s",    mix_total_s_},
        {"mode",       loop_mode_str(mix_mode_)},
        {"loaded",     mix_loaded_},
        {"cues",       std::move(cues)},
        {"plan",       std::move(plan)},
        {"forced_move_at", mix_plan_.forced_move_at},
        {"forced_reason",  mix_plan_.forced_reason},
        {"warnings",       mix_plan_.warnings},
        {"available",  mix_available_},
    };
}

nlohmann::json DeviceManager::mix_state() {
    std::lock_guard<std::mutex> g(mix_mu_);
    return mix_state_locked();
}

void DeviceManager::mix_replan() {
    // Snapshot the roster and preset poses under mu_ FIRST, release it, and only
    // then take mix_mu_. The documented hierarchy is mu_ -> mix_mu_ and taking
    // them the other way round is how you deadlock this process.
    std::vector<std::string> cams;
    std::map<std::string, std::map<int, std::pair<float, float>>> poses;
    {
        std::lock_guard<std::mutex> g(mu_);
        for (auto& kv : sessions_) {
            if (!kv.second) continue;
            cams.push_back(kv.first);
            for (const auto& p : kv.second->snapshot().presets) {
                poses[kv.first][p.id] = {p.yaw, p.pitch};
            }
        }
    }

    // Only ever used to decide WHICH edge to sacrifice when an odd loop forces
    // one on-air pan. An unknown pose scores high, so we never sacrifice an edge
    // whose cost we cannot actually see.
    mix::PanCost cost = [&poses](const std::string& sn, int a, int b) -> float {
        auto d = poses.find(sn);
        if (d == poses.end()) return 1e6f;
        auto pa = d->second.find(a);
        auto pb = d->second.find(b);
        if (pa == d->second.end() || pb == d->second.end()) return 1e6f;
        const float dy = pa->second.first - pb->second.first;
        const float dp = pa->second.second - pb->second.second;
        return std::sqrt(dy * dy + dp * dp);
    };

    std::lock_guard<std::mutex> g(mix_mu_);
    std::vector<mix::Cue> in;
    in.reserve(mix_cues_.size());
    for (const auto& c : mix_cues_) {
        mix::Cue mc;
        mc.preset_id = c.preset_id;
        mc.hold_s    = c.hold_s;
        mc.enabled   = c.enabled;
        mc.fade_ms   = c.fade_ms;
        mc.move_ms   = c.move_ms;
        mc.pin_sn    = c.camera_sn;   // empty = derive
        in.push_back(mc);
    }
    // A forward loop wraps, so it is a CYCLE (and only an even one 2-colours).
    // Ping-pong and once walk a PATH, which has no wrap edge to violate - that
    // is why ping-pong is the free escape from an odd cue count.
    const bool is_cycle = (mix_mode_ == LoopMode::forward);
    mix_plan_ = mix::solve(in, cams, is_cycle, cost, kDefaultFadeMs);

    if (!mix_plan_.forced_reason.empty()) {
        LOGW("mix: %s", mix_plan_.forced_reason.c_str());
    }
}

void DeviceManager::mix_set(const std::vector<MixCue>& cues, LoopMode mode) {
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues;
        mix_mode_ = mode;
        mix_loaded_.clear();   // editing scratch
    }
    // The camera and the meanwhile are derived, so every edit re-solves. This is
    // also all that "disable a step" needs: the cue drops out of the plan and
    // the colouring closes over the hole by itself.
    mix_replan();
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        // The run cursor indexes the PLAN (enabled cues only), not the authored
        // list, so it has to be re-clamped against the new plan length.
        const int n = (int)mix_plan_.cues.size();
        if (mix_running_) {
            if (n == 0) { mix_running_ = false; mix_quit_ = true; }
            else if (mix_cue_index_ >= n) mix_cue_index_ = n - 1;
        }
    }
    persist_mix_scratch(cues, mode);
    mix_cv_.notify_all();   // let a shrink/clear take effect at the next boundary
    broadcast();
}

CmdResult DeviceManager::mix_start() {
    // Whole transition under mix_ctl_mu_: the running-check, the join of a
    // finished thread, and the relaunch must be atomic vs. a concurrent
    // start/stop on another WS worker thread.
    std::lock_guard<std::mutex> ctl(mix_ctl_mu_);
    // Never (re)launch during/after teardown: stop() clears started_ before it
    // joins under the same ctl mutex, so this prevents a start racing shutdown
    // from relaunching the thread onto sessions that are about to be freed.
    if (!started_) return mok();
    if (mix_running_) return mok();
    // Re-solve against the roster as it is RIGHT NOW: a camera may have been
    // plugged in or pulled since the cues were authored, and that changes the
    // colouring (three cameras make an odd loop clean; one camera makes every
    // transition an on-air pan).
    mix_replan();
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        if (mix_plan_.cues.empty())
            return merr("invalid_param", "no enabled cues to run");
        mix_cue_index_ = 0;
        mix_direction_ = 1;
    }
    // Join the finishing thread BEFORE arming the flags. mix_loop's exit
    // cleanup clears mix_running_; if we set it true first and then join, that
    // cleanup runs during the join and clobbers our true back to false, so the
    // relaunched loop sees running==false and no-ops. Order matters here.
    if (mix_thr_.joinable()) mix_thr_.join();
    mix_quit_ = false;
    mix_running_ = true;
    mix_thr_ = std::thread(&DeviceManager::mix_loop, this);
    return mok();
}

CmdResult DeviceManager::mix_stop() {
    {
        std::lock_guard<std::mutex> ctl(mix_ctl_mu_);
        mix_running_ = false;
        mix_quit_ = true;
        mix_cv_.notify_all();
        if (mix_thr_.joinable()) mix_thr_.join();
    }
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cue_index_ = -1;
        mix_phase_ = "holding";
        mix_elapsed_s_ = 0;
        mix_total_s_ = 0;
    }
    broadcast();
    return mok();
}

CmdResult DeviceManager::mix_save_as(const std::string& name,
                                     const std::vector<MixCue>& cues,
                                     LoopMode mode) {
    if (name.empty()) return merr("invalid_param", "name required");
    nlohmann::json lib = persist::load_mix_library();
    nlohmann::json entry;
    entry["mode"] = loop_mode_str(mode);
    entry["cues"] = nlohmann::json::array();
    for (auto& c : cues) entry["cues"].push_back(cue_to_json(c));
    lib[name] = entry;
    persist::store_mix_library(lib);
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues;
        mix_mode_ = mode;
        mix_loaded_ = name;
        mix_available_.clear();
        for (auto& it : lib.items()) mix_available_.push_back(it.key());
        std::sort(mix_available_.begin(), mix_available_.end());
    }
    persist_mix_scratch(cues, mode);
    LOGI("mix: saved as '%s'", name.c_str());
    broadcast();
    return mok();
}

CmdResult DeviceManager::mix_load(const std::string& name) {
    nlohmann::json lib = persist::load_mix_library();
    if (!lib.contains(name)) return merr("not_found", "no mix named '" + name + "'");
    auto& e = lib[name];
    std::vector<MixCue> cues = cues_from_json(e.value("cues", nlohmann::json::array()));
    LoopMode mode = parse_loop_mode(e.value("mode", std::string("forward")));
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues;
        mix_mode_ = mode;
        mix_loaded_ = name;
    }
    // A loaded sequence carries shots, not cameras (unless it is a pre-2.1 file,
    // which arrives fully pinned). Solve it against whatever is plugged in here.
    mix_replan();
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        const int n = (int)mix_plan_.cues.size();
        if (mix_running_ && mix_cue_index_ >= n)
            mix_cue_index_ = (n == 0) ? -1 : n - 1;
    }
    persist_mix_scratch(cues, mode);
    mix_cv_.notify_all();
    LOGI("mix: loaded '%s' (%zu cues)", name.c_str(), cues.size());
    broadcast();
    return mok();
}

CmdResult DeviceManager::mix_delete(const std::string& name) {
    nlohmann::json lib = persist::load_mix_library();
    if (!lib.contains(name)) return merr("not_found", "no mix named '" + name + "'");
    lib.erase(name);
    persist::store_mix_library(lib);
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_available_.clear();
        for (auto& it : lib.items()) mix_available_.push_back(it.key());
        std::sort(mix_available_.begin(), mix_available_.end());
        if (mix_loaded_ == name) mix_loaded_.clear();
    }
    LOGI("mix: deleted '%s'", name.c_str());
    broadcast();
    return mok();
}

// While one cue is live, every OTHER camera walks to the shot it will next be
// live on. In a forward loop that is simply "the next cue that uses it", but
// ping-pong reverses at the ends, so the answer depends on which way we are
// currently travelling. Hence this walks the real run order rather than reading
// the plan's forward-pass snapshot (which is only what the UI displays).
static std::vector<mix::Meanwhile> meanwhile_at(const mix::Plan& plan, int i,
                                                int dir, LoopMode mode) {
    const int n = (int)plan.cues.size();
    std::vector<mix::Meanwhile> out;
    if (n <= 1 || i < 0 || i >= n) return out;

    std::set<std::string> idle;
    for (const auto& c : plan.cues) idle.insert(c.camera_sn);
    idle.erase(plan.cues[i].camera_sn);
    if (idle.empty()) return out;

    int cur = i, d = dir;
    for (int step = 0; step < 2 * n && !idle.empty(); ++step) {
        int nxt;
        switch (mode) {
            case LoopMode::once:
                nxt = cur + 1;
                if (nxt >= n) return out;      // nothing further is coming
                break;
            case LoopMode::forward:
                nxt = (cur + 1) % n;
                break;
            case LoopMode::ping_pong: {
                int cand = cur + d;
                if (cand >= n)     { d = -1; cand = cur - 1; }
                else if (cand < 0) { d =  1; cand = cur + 1; }
                nxt = cand;
                break;
            }
            default:
                return out;
        }
        if (nxt == i) break;                   // came all the way round
        const mix::PlannedCue& pc = plan.cues[nxt];
        if (idle.erase(pc.camera_sn) > 0) {
            out.push_back(mix::Meanwhile{pc.camera_sn, pc.preset_id});
        }
        cur = nxt;
    }
    return out;
}

void DeviceManager::mix_loop() {
    LOGI("mix: started");

    // Interruptible sleep. Returns false the moment the run should end (stop
    // pressed, or the cue list emptied mid-run), so callers break out promptly.
    auto wait_ms = [&](int ms) -> bool {
        std::unique_lock<std::mutex> lk(mix_mu_);
        mix_cv_.wait_for(lk, std::chrono::milliseconds(ms),
                         [&] { return mix_quit_.load() || !mix_running_.load(); });
        return mix_running_.load() && !mix_quit_.load();
    };

    while (mix_running_ && !mix_quit_) {
        mix::PlannedCue pc;
        std::vector<mix::Meanwhile> mw;
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            int n = (int)mix_plan_.cues.size();
            if (n == 0) { mix_running_ = false; break; }
            if (mix_cue_index_ < 0 || mix_cue_index_ >= n) mix_cue_index_ = 0;
            pc = mix_plan_.cues[mix_cue_index_];
            mw = meanwhile_at(mix_plan_, mix_cue_index_, mix_direction_, mix_mode_);
            mix_phase_ = "moving";
            mix_elapsed_s_ = 0;
            mix_total_s_ = pc.hold_s;
        }
        broadcast();

        // 1) Program switch. fade_ms is per-cue now. A cue the solver marked
        //    on_air_move carries fade_ms == 0 by construction: the same camera is
        //    live either side of it, so there is no second feed to dissolve into
        //    and it pans LIVE instead. Held lock-free so set_active() /
        //    session_by_sn() (which take mu_) never self-deadlock.
        if (!pc.camera_sn.empty()) {
            std::string ec;
            set_active(pc.camera_sn, ec, pc.fade_ms);
        }
        if (pc.preset_id >= 0) {   // <0 = hold current shot (no recall)
            if (auto s = session_by_sn(pc.camera_sn))
                s->cmd_preset_recall(pc.preset_id, pc.move_ms, [](CmdResult) {});
        }

        // 2) The meanwhile, derived: every idle camera walks to the shot it will
        //    next be live on. It is off air, so nobody can see it - it goes as
        //    fast as the gimbal allows and carries no duration to tune.
        for (const auto& m : mw) {
            if (m.preset_id < 0) continue;
            if (auto s = session_by_sn(m.camera_sn))
                s->cmd_preset_recall(m.preset_id, 0, [](CmdResult) {});
        }

        // 3) Moving phase: let a live pan land before the hold clock starts.
        if (pc.move_ms > 0) {
            if (!wait_ms(pc.move_ms)) break;
        }

        // 4) Holding phase: dwell on the shot, ticking elapsed once a second.
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            mix_phase_ = "holding";
            mix_elapsed_s_ = 0;
            mix_total_s_ = pc.hold_s;
        }
        broadcast();
        bool stopping = false;
        for (int e = 0; e < pc.hold_s; ++e) {
            if (!wait_ms(1000)) { stopping = true; break; }
            {
                std::lock_guard<std::mutex> g(mix_mu_);
                mix_elapsed_s_ = e + 1;
            }
            broadcast();
        }
        if (stopping) break;

        // 5) Advance per loop mode (mirrors the per-camera sequencer).
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            int cur = mix_cue_index_;
            int cnt = (int)mix_plan_.cues.size();
            if (cnt == 0) { mix_running_ = false; break; }
            int next = cur;
            switch (mix_mode_) {
                case LoopMode::once:
                    next = cur + 1;
                    if (next >= cnt) mix_running_ = false;
                    break;
                case LoopMode::forward:
                    next = (cur + 1) % cnt;
                    break;
                case LoopMode::ping_pong:
                    if (cnt <= 1) { next = 0; break; }
                    {
                        int cand = cur + mix_direction_;
                        if (cand >= cnt) { mix_direction_ = -1; cand = cur - 1; }
                        else if (cand < 0) { mix_direction_ = 1; cand = cur + 1; }
                        next = cand;
                    }
                    break;
            }
            mix_cue_index_ = next;
        }
    }

    LOGI("mix: stopped");
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_running_ = false;
        mix_cue_index_ = -1;
        mix_phase_ = "holding";
        mix_elapsed_s_ = 0;
        mix_total_s_ = 0;
    }
    broadcast();
}

}  // namespace obs
