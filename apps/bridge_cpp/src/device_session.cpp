#include "device_session.h"
#include "log.h"

#include <dev/devs.hpp>

#include <algorithm>
#include <cstring>
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

    Devices::get().setDevChangedCallback(s_dev_changed_trampoline, nullptr);
    Devices::get().setEnableMdnsScan(false);

    LOGI("device session started; waiting for camera plug-in...");
}

void DeviceSession::stop() {
    if (!running_) return;
    running_ = false;
    q_cv_.notify_all();
    if (thr_.joinable()) thr_.join();
    Devices::get().close();
    g_session = nullptr;
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
        snap_.zoom = z;
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
        switch (cs.tiny.ai_mode) {
            case Device::AiWorkModeNone: snap_.ai_mode = "none"; break;
            case Device::AiWorkModeGroup: snap_.ai_mode = "group"; break;
            case Device::AiWorkModeHuman: snap_.ai_mode = "human"; break;
            case Device::AiWorkModeHand: snap_.ai_mode = "hand"; break;
            case Device::AiWorkModeWhiteBoard: snap_.ai_mode = "whiteboard"; break;
            case Device::AiWorkModeDesk: snap_.ai_mode = "desk"; break;
            default: snap_.ai_mode = "none"; break;
        }
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

static CmdResult ok() { return {true, "", ""}; }
static CmdResult err(const char* code, const char* msg) { return {false, code, msg}; }

#define REQUIRE_DEV() \
    if (!dev_) return err("not_connected", "no camera attached")

void DeviceSession::cmd_ptz_angle(float yaw, float pitch, float roll, ReplyFn reply) {
    submit([this, yaw, pitch, roll]() -> CmdResult {
        REQUIRE_DEV();
        dev_->cameraSetAiModeU(Device::AiWorkModeNone);
        dev_->aiSetEnabledR(false);
        int32_t r = dev_->aiSetGimbalMotorAngleR(pitch, yaw, roll);
        return r == 0 ? ok() : err("device_busy", "aiSetGimbalMotorAngleR failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ptz_velocity(float yaw_speed, float pitch_speed, float roll_speed, ReplyFn reply) {
    auto now = steady_clock::now();
    submit([this, yaw_speed, pitch_speed, roll_speed, now]() -> CmdResult {
        REQUIRE_DEV();
        bool stopping = (yaw_speed == 0.f && pitch_speed == 0.f && roll_speed == 0.f);
        if (!stopping && (now - last_velocity_apply_ < milliseconds(30))) return ok();
        last_velocity_apply_ = now;
        dev_->cameraSetAiModeU(Device::AiWorkModeNone);
        dev_->aiSetEnabledR(false);
        int32_t r = dev_->aiSetGimbalSpeedCtrlR(pitch_speed, yaw_speed, roll_speed);
        return r == 0 ? ok() : err("device_busy", "aiSetGimbalSpeedCtrlR failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ptz_stop(ReplyFn reply) {
    submit([this]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->aiSetGimbalSpeedCtrlR(0.0, 0.0, 0.0);
        return r == 0 ? ok() : err("device_busy", "stop failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ptz_recenter(ReplyFn reply) {
    submit([this]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->gimbalRstPosR();
        return r == 0 ? ok() : err("device_busy", "recenter failed");
    }, std::move(reply));
}

void DeviceSession::cmd_zoom_set(float value, ReplyFn reply) {
    submit([this, value]() -> CmdResult {
        REQUIRE_DEV();
        if (value < 1.0f || value > 4.0f) return err("invalid_param", "zoom out of 1..4 range");
        int32_t r = dev_->cameraSetZoomAbsoluteR(value);
        return r == 0 ? ok() : err("device_busy", "zoom failed");
    }, std::move(reply));
}

void DeviceSession::cmd_zoom_set_smooth(float value, int speed, ReplyFn reply) {
    submit([this, value, speed]() -> CmdResult {
        REQUIRE_DEV();
        if (value < 1.0f || value > 4.0f) return err("invalid_param", "zoom out of range");
        if (speed < 1 || speed > 10) return err("invalid_param", "speed must be 1..10");
        int32_t r = dev_->cameraSetZoomWithSpeedAbsoluteR((uint32_t)(value * 100.f), (uint32_t)speed);
        return r == 0 ? ok() : err("device_busy", "zoom_smooth failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ai_set_mode(const std::string& mode, const std::string& sub, ReplyFn reply) {
    submit([this, mode, sub]() -> CmdResult {
        REQUIRE_DEV();
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
        return r == 0 ? ok() : err("device_busy", "set ai mode failed");
    }, std::move(reply));
}

void DeviceSession::cmd_ai_set_enabled(bool enabled, ReplyFn reply) {
    submit([this, enabled]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->aiSetEnabledR(enabled);
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
        return r == 0 ? ok() : err("device_busy", "fov failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_brightness(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageBrightnessR(v);
        return r == 0 ? ok() : err("device_busy", "brightness failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_contrast(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageContrastR(v);
        return r == 0 ? ok() : err("device_busy", "contrast failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_saturation(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageSaturationR(v);
        return r == 0 ? ok() : err("device_busy", "saturation failed");
    }, std::move(reply));
}
void DeviceSession::cmd_image_set_sharpness(int v, ReplyFn reply) {
    submit([this, v]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageSharpR(v);
        return r == 0 ? ok() : err("device_busy", "sharpness failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_face_ae(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetFaceAER(e ? 1 : 0);
        return r == 0 ? ok() : err("device_busy", "face ae failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_face_focus(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetFaceFocusR(e);
        return r == 0 ? ok() : err("device_busy", "face focus failed");
    }, std::move(reply));
}

void DeviceSession::cmd_image_set_flip_h(bool e, ReplyFn reply) {
    submit([this, e]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->cameraSetImageFlipHorizonU(e ? 1 : 0);
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

void DeviceSession::cmd_preset_recall(int id, ReplyFn reply) {
    submit([this, id]() -> CmdResult {
        REQUIRE_DEV();
        int32_t r = dev_->aiTrgGimbalPresetR(id);
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
        float z = 1.0f;
        dev_->cameraGetZoomAbsoluteR(z);
        pi.zoom = z;
        std::string n = name.substr(0, 60);
        std::memcpy(pi.name, n.c_str(), n.size());
        pi.name_len = (int32_t)n.size();
        int32_t r = dev_->aiAddGimbalPresetR(&pi);
        return r == 0 ? ok() : err("device_busy", "preset save failed");
    }, std::move(reply));
}

}  // namespace obs
