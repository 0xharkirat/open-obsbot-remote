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

namespace obs {

static int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

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
        {"camera_sn", c.camera_sn},
        {"preset_id", c.preset_id},
        {"move_ms",   c.move_ms},
        {"hold_s",    c.hold_s},
        {"transition", c.transition},
    };
    if (c.has_meanwhile) {
        j["meanwhile"] = {
            {"camera_sn", c.mw_sn},
            {"preset_id", c.mw_preset_id},
            {"move_ms",   c.mw_move_ms},
        };
    }
    return j;
}

static MixCue cue_from_json(const nlohmann::json& j) {
    MixCue c;
    c.camera_sn  = j.value("camera_sn", std::string{});
    c.preset_id  = j.value("preset_id", -1);   // absent = hold current shot
    c.move_ms    = j.value("move_ms", 0);
    c.hold_s     = j.value("hold_s", 10);
    c.transition = j.value("transition", std::string("cut"));
    if (c.hold_s < 1) c.hold_s = 1;
    if (c.move_ms < 0) c.move_ms = 0;
    if (j.contains("meanwhile") && j["meanwhile"].is_object()) {
        auto& m = j["meanwhile"];
        c.has_meanwhile = true;
        c.mw_sn        = m.value("camera_sn", std::string{});
        c.mw_preset_id = m.value("preset_id", 0);
        c.mw_move_ms   = m.value("move_ms", 0);
        if (c.mw_sn.empty()) c.has_meanwhile = false;
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
    // cross-camera sequence on reopen (mirrors the per-camera scratch).
    {
        nlohmann::json m = persist::load_active_mix();
        nlohmann::json lib = persist::load_mix_library();
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues_from_json(m.value("cues", nlohmann::json::array()));
        mix_mode_ = parse_loop_mode(m.value("mode", std::string("forward")));
        for (auto& it : lib.items()) mix_available_.push_back(it.key());
        std::sort(mix_available_.begin(), mix_available_.end());
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

    LOGI("device manager started; desired active='%s'; waiting for cameras...",
         desired_active_.c_str());
}

void DeviceManager::stop() {
    if (!started_) return;
    started_ = false;
    Devices::get().setDevChangedCallback(nullptr, nullptr);

    // Stop the mix engine before sessions die: mix_loop touches sessions.
    mix_running_ = false;
    mix_quit_ = true;
    mix_cv_.notify_all();
    if (mix_thr_.joinable()) mix_thr_.join();

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
    // videoDevPath() (macOS) is the AVFoundation uniqueID byte-for-byte - the
    // SN -> capture-device join. Captured here synchronously; the session's own
    // copy is hydrated asynchronously by attach() below.
    std::string uid = dev->videoDevPath();

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

nlohmann::json DeviceManager::build_state_event() {
    std::lock_guard<std::mutex> g(mu_);
    nlohmann::json devs = nlohmann::json::array();
    for (auto& sn : order_) {
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) continue;
        devs.push_back(build_device_entry(it->second->snapshot()));
    }
    return nlohmann::json{
        {"event", "state"},
        {"version", "2.0"},
        {"ts", now_ms()},
        {"active_device_id", active_sn_},
        {"devices", std::move(devs)},
        {"mix", mix_state()},
    };
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

bool DeviceManager::set_active(const std::string& sn, std::string& err_code) {
    {
        std::lock_guard<std::mutex> g(mu_);
        auto it = sessions_.find(sn);
        if (it == sessions_.end()) { err_code = "not_found"; return false; }
        active_sn_ = sn;
        desired_active_ = sn;
        // Implicit wake: if the target is asleep, wake it before it goes live
        // so OBS (which consumes /preview/active.mjpg) does not pull a black
        // stream. Async - the camera takes ~1 s to wake regardless.
        if (it->second->snapshot().run_status == 3 /*sleep*/) {
            LOGI("set_active: %s is asleep, waking before switch", sn.c_str());
            it->second->cmd_system_run_status("run", [](CmdResult) {});
        }
    }
    persist::store_active_device(sn);
    broadcast();
    return true;
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
    return nlohmann::json{
        {"running",   mix_running_.load()},
        {"cue_index", mix_cue_index_},
        {"cue_count", (int)mix_cues_.size()},
        {"phase",     mix_phase_},
        {"elapsed_s", mix_elapsed_s_},
        {"total_s",   mix_total_s_},
        {"mode",      loop_mode_str(mix_mode_)},
        {"loaded",    mix_loaded_},
        {"cues",      std::move(cues)},
        {"available", mix_available_},
    };
}

nlohmann::json DeviceManager::mix_state() {
    std::lock_guard<std::mutex> g(mix_mu_);
    return mix_state_locked();
}

void DeviceManager::mix_set(const std::vector<MixCue>& cues, LoopMode mode) {
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        mix_cues_ = cues;
        mix_mode_ = mode;
        mix_loaded_.clear();   // editing scratch
        if (mix_running_) {
            if (mix_cues_.empty()) { mix_running_ = false; mix_quit_ = true; }
            else if (mix_cue_index_ >= (int)mix_cues_.size())
                mix_cue_index_ = (int)mix_cues_.size() - 1;
        }
    }
    persist_mix_scratch(cues, mode);
    mix_cv_.notify_all();   // let a shrink/clear take effect at the next boundary
    broadcast();
}

CmdResult DeviceManager::mix_start() {
    if (mix_running_) return mok();
    {
        std::lock_guard<std::mutex> g(mix_mu_);
        if (mix_cues_.empty()) return merr("invalid_param", "no mix configured");
        mix_cue_index_ = 0;
        mix_direction_ = 1;
    }
    mix_quit_ = false;
    mix_running_ = true;
    if (mix_thr_.joinable()) mix_thr_.join();
    mix_thr_ = std::thread(&DeviceManager::mix_loop, this);
    return mok();
}

CmdResult DeviceManager::mix_stop() {
    mix_running_ = false;
    mix_quit_ = true;
    mix_cv_.notify_all();
    if (mix_thr_.joinable()) mix_thr_.join();
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
        if (mix_running_ && mix_cue_index_ >= (int)mix_cues_.size())
            mix_cue_index_ = mix_cues_.empty() ? -1 : (int)mix_cues_.size() - 1;
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
        MixCue cue;
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            int n = (int)mix_cues_.size();
            if (n == 0) { mix_running_ = false; break; }
            if (mix_cue_index_ < 0 || mix_cue_index_ >= n) mix_cue_index_ = 0;
            cue = mix_cues_[mix_cue_index_];
            mix_phase_ = "moving";
            mix_elapsed_s_ = 0;
            mix_total_s_ = cue.hold_s;
        }
        broadcast();

        // 1) Program switch + live moves. NO on-air lock: the program camera
        //    physically moves to its preset ON AIR (cmd_preset_recall ramps it
        //    over move_ms) - the whole point of the mixer. Held lock-free so
        //    set_active()/session_by_sn() (which take mu_) never self-deadlock.
        if (!cue.camera_sn.empty()) {
            std::string ec;
            set_active(cue.camera_sn, ec);
        }
        if (cue.preset_id >= 0) {   // <0 = hold current shot (no recall)
            if (auto s = session_by_sn(cue.camera_sn))
                s->cmd_preset_recall(cue.preset_id, cue.move_ms, [](CmdResult) {});
        }
        if (cue.has_meanwhile && cue.mw_preset_id >= 0) {
            if (auto s = session_by_sn(cue.mw_sn))
                s->cmd_preset_recall(cue.mw_preset_id, cue.mw_move_ms, [](CmdResult) {});
        }

        // 2) Moving phase: let the live move land before the hold clock starts.
        if (cue.move_ms > 0) {
            if (!wait_ms(cue.move_ms)) break;
        }

        // 3) Holding phase: dwell on the shot, ticking elapsed once a second.
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            mix_phase_ = "holding";
            mix_elapsed_s_ = 0;
            mix_total_s_ = cue.hold_s;
        }
        broadcast();
        bool stopping = false;
        for (int e = 0; e < cue.hold_s; ++e) {
            if (!wait_ms(1000)) { stopping = true; break; }
            {
                std::lock_guard<std::mutex> g(mix_mu_);
                mix_elapsed_s_ = e + 1;
            }
            broadcast();
        }
        if (stopping) break;

        // 4) Advance per loop mode (mirrors the per-camera sequencer).
        {
            std::lock_guard<std::mutex> g(mix_mu_);
            int cur = mix_cue_index_;
            int cnt = (int)mix_cues_.size();
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
