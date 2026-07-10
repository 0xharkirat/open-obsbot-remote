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

DeviceManager::DeviceManager() {}
DeviceManager::~DeviceManager() { stop(); }

void DeviceManager::start(Broadcaster broadcaster) {
    broadcaster_ = std::move(broadcaster);
    // Persisted preference: the camera the operator last routed to OBS. If it
    // is absent when cameras attach, recompute_active_locked falls back to the
    // first-attached camera.
    desired_active_ = persist::load_active_device();
    active_sn_.clear();
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

}  // namespace obs
