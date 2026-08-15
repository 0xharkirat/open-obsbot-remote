// V4L2 capture backend: the Linux twin of video_capture.mm.
//
// Both files implement video_capture.h in full; this is the only Linux-specific
// translation unit in the bridge. Everything else - device control, WebSocket,
// MJPEG serving, the mix engine, auth, persistence - is portable C++ that talks
// to libdev, Crow and Asio, and compiles unchanged.
//
// The interesting difference from the AVFoundation path is that there is no
// encoder here at all. macOS captures native frames and runs VideoToolbox to
// produce the JPEGs the MJPEG route serves. The Tiny 2 Lite emits MJPEG
// natively over UVC (1920x1080 at up to 60fps, 3840x2160 at 30), so V4L2 hands
// us JPEG bytes that go straight out the socket. The capture path is a memcpy.
//
// What is missing relative to macOS is the fade primitives, which do need a
// decode/encode round trip - see jpeg_darken below.

#include "video_capture.h"
#include "log.h"

#include "dev/dev.hpp"
#include "dev/devs.hpp"

#include <fcntl.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <linux/videodev2.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstring>
#include <dirent.h>
#include <set>
#include <thread>

namespace obs {
namespace {

constexpr int    kBufferCount   = 4;
constexpr uint32_t kCaptureWidth  = 1920;
constexpr uint32_t kCaptureHeight = 1080;

// ioctl restarted on EINTR. Every V4L2 call needs this: a signal arriving
// mid-ioctl (which the SDK's own threads make routine) otherwise looks like a
// device failure and tears down a working capture.
int xioctl(int fd, unsigned long req, void* arg) {
    int r;
    do { r = ::ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return s;
}

// Resolve /dev/v4l/by-path/... to the /dev/videoN it points at. Returns the
// input unchanged when it is not a symlink, so callers can pass either form.
std::string resolve_node(const std::string& path) {
    char buf[PATH_MAX];
    ssize_t n = ::readlink(path.c_str(), buf, sizeof(buf) - 1);
    if (n <= 0) return path;
    buf[n] = '\0';
    std::string target(buf);
    if (!target.empty() && target[0] == '/') return target;
    auto slash = path.find_last_of('/');
    std::string dir = (slash == std::string::npos) ? "." : path.substr(0, slash);
    char real[PATH_MAX];
    std::string joined = dir + "/" + target;
    if (::realpath(joined.c_str(), real) != nullptr) return std::string(real);
    return joined;
}

// True when this node can actually deliver video, as opposed to metadata.
// Each UVC camera exposes two nodes; on the Tiny 2 Lite /dev/video3 streams
// and /dev/video4 is metadata. device_caps distinguishes them when the driver
// sets V4L2_CAP_DEVICE_CAPS, and the format enumeration is the belt-and-braces
// check for drivers that do not.
bool is_capture_node(int fd, std::string* card_out) {
    v4l2_capability cap{};
    if (xioctl(fd, VIDIOC_QUERYCAP, &cap) == -1) return false;

    uint32_t caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS)
                        ? cap.device_caps : cap.capabilities;
    if ((caps & V4L2_CAP_VIDEO_CAPTURE) == 0) return false;
    if ((caps & V4L2_CAP_STREAMING) == 0) return false;

    v4l2_fmtdesc fmt{};
    fmt.index = 0;
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_ENUM_FMT, &fmt) == -1) return false;

    if (card_out != nullptr)
        *card_out = reinterpret_cast<const char*>(cap.card);
    return true;
}

// The stable name for a node, when udev has made one. Preferred over
// /dev/videoN because the number is allocation order and moves between boots,
// whereas by-path encodes the physical USB port.
//
// Note what is NOT used here: /dev/v4l/by-id. This camera reports no USB
// iSerial, so every Tiny 2 Lite yields the identical
// "usb-Remo_Tech_Co.__Ltd._OBSBOT_Tiny_2_Lite-video-index0". by-id cannot tell
// two of them apart; by-path can, because they occupy different ports.
std::string stable_id_for(const std::string& node) {
    const char* dir_path = "/dev/v4l/by-path";
    DIR* d = ::opendir(dir_path);
    if (d == nullptr) return node;
    std::string found = node;
    while (dirent* e = ::readdir(d)) {
        if (e->d_name[0] == '.') continue;
        std::string link = std::string(dir_path) + "/" + e->d_name;
        if (resolve_node(link) == node) { found = link; break; }
    }
    ::closedir(d);
    return found;
}

// Every /dev/videoN that can stream video, in numeric order.
std::vector<std::string> enumerate_capture_nodes(
    std::vector<std::string>* cards = nullptr) {
    std::vector<std::pair<int, std::string>> numbered;
    DIR* d = ::opendir("/dev");
    if (d == nullptr) return {};
    while (dirent* e = ::readdir(d)) {
        std::string name(e->d_name);
        if (name.rfind("video", 0) != 0) continue;
        std::string digits = name.substr(5);
        if (digits.empty() ||
            !std::all_of(digits.begin(), digits.end(), ::isdigit)) continue;
        numbered.emplace_back(std::stoi(digits), "/dev/" + name);
    }
    ::closedir(d);
    std::sort(numbered.begin(), numbered.end());

    std::vector<std::string> out;
    for (auto& [num, path] : numbered) {
        int fd = ::open(path.c_str(), O_RDWR | O_NONBLOCK);
        if (fd < 0) continue;
        std::string card;
        bool ok = is_capture_node(fd, &card);
        ::close(fd);
        if (!ok) continue;
        out.push_back(path);
        if (cards != nullptr) cards->push_back(card);
    }
    return out;
}

}  // namespace

// ----------------------------------------------------------------------------
// Fade primitives
//
// TODO: implement with libjpeg-turbo, which is already a dependency of every
// desktop Linux and is installed on the target host. Both functions need the
// same shape: decompress to RGB, scale or blend, recompress. macOS gets this
// from Core Image and ImageIO for free, which is why the .mm versions are
// short.
//
// Returning the input unchanged is the documented fallback in video_capture.h
// ("Returns the input unchanged ... on any decode/encode failure"), so callers
// already handle it: a TAKE with a fade becomes a hard cut. That is a cosmetic
// loss, and a running bridge matters more than a pretty transition.
// ----------------------------------------------------------------------------

std::vector<uint8_t> jpeg_darken(const std::vector<uint8_t>& jpeg, float factor) {
    (void)factor;
    return jpeg;
}

std::vector<uint8_t> jpeg_crossfade(const std::vector<uint8_t>& outgoing,
                                    const std::vector<uint8_t>& incoming,
                                    float factor) {
    (void)outgoing;
    (void)factor;
    return incoming;
}

// ----------------------------------------------------------------------------
// SN -> capture-device join
// ----------------------------------------------------------------------------

std::string device_video_path(Device* dev) {
    if (dev == nullptr) return {};

    std::vector<std::string> cards;
    std::vector<std::string> nodes = enumerate_capture_nodes(&cards);

    std::vector<std::string> obsbot_nodes;
    for (size_t i = 0; i < nodes.size(); ++i) {
        if (to_lower(cards[i]).find("obsbot") != std::string::npos)
            obsbot_nodes.push_back(nodes[i]);
    }

    if (obsbot_nodes.empty()) {
        LOGW("v4l2: no OBSBOT capture node found for %s", dev->devSn().c_str());
        return {};
    }
    if (obsbot_nodes.size() == 1) {
        return stable_id_for(obsbot_nodes.front());
    }

    // More than one camera. There is no serial to join on - see stable_id_for -
    // so fall back to position: the Nth camera libdev reports takes the Nth
    // OBSBOT node in /dev order. Both lists are stable within a run, so this
    // holds until something is replugged, at which point a wrong pairing shows
    // up as the wrong preview under the right controls.
    std::string sn = dev->devSn();
    size_t index = 0;
    bool found = false;
    for (auto& d : Devices::get().getDevList()) {
        if (d && d->devSn() == sn) { found = true; break; }
        ++index;
    }
    if (!found || index >= obsbot_nodes.size()) {
        LOGW("v4l2: %s not positionally matched among %zu OBSBOT nodes",
             sn.c_str(), obsbot_nodes.size());
        return {};
    }
    LOGW("v4l2: %s joined to %s POSITIONALLY (%zu cameras, none report a USB "
         "serial); verify the preview matches the camera you are driving",
         sn.c_str(), obsbot_nodes[index].c_str(), obsbot_nodes.size());
    return stable_id_for(obsbot_nodes[index]);
}

// ----------------------------------------------------------------------------
// Enumeration and hotplug
// ----------------------------------------------------------------------------

std::vector<AvVideoDevice> list_av_devices() {
    std::vector<std::string> cards;
    std::vector<std::string> nodes = enumerate_capture_nodes(&cards);

    std::vector<AvVideoDevice> out;
    out.reserve(nodes.size());
    for (size_t i = 0; i < nodes.size(); ++i) {
        AvVideoDevice v;
        v.unique_id = stable_id_for(nodes[i]);
        v.name = cards[i];
        v.is_obsbot = to_lower(cards[i]).find("obsbot") != std::string::npos;
        out.push_back(std::move(v));
    }
    return out;
}

// Polls rather than watching. libudev would be the right answer and is the
// obvious next change, but it is a new link dependency for a callback that
// only drives generic-source captures: OBSBOT attach and detach come from
// libdev's own hotplug thread, not from here. A 2s worst-case delay before a
// replugged webcam reappears is not worth a dependency in the first version.
void observe_av_devices(std::function<void(std::string, bool)> cb) {
    std::thread([cb = std::move(cb)]() {
        std::set<std::string> known;
        for (auto& d : list_av_devices()) known.insert(d.unique_id);

        for (;;) {
            std::this_thread::sleep_for(std::chrono::seconds(2));

            std::set<std::string> now;
            for (auto& d : list_av_devices()) now.insert(d.unique_id);

            for (const auto& id : now)
                if (known.find(id) == known.end()) cb(id, true);
            for (const auto& id : known)
                if (now.find(id) == now.end()) cb(id, false);

            known.swap(now);
        }
    }).detach();
}

// ----------------------------------------------------------------------------
// VideoCapture
// ----------------------------------------------------------------------------

struct VideoCapture::Impl {
    int fd = -1;

    struct Buffer {
        void*  start  = nullptr;
        size_t length = 0;
    };
    std::vector<Buffer> buffers;

    std::thread worker;
    std::atomic<bool> stopping{false};

    mutable std::mutex jpeg_mu;
    std::vector<uint8_t> latest;
    std::atomic<uint64_t> seq{0};

    // Serialises start/stop against each other, matching the macOS Impl. The
    // callers are the same: libdev's hotplug thread and the retry path.
    std::mutex ctl_mu;
    std::atomic<bool> running{false};
};

VideoCapture::VideoCapture() : impl_(std::make_unique<Impl>()) {}

VideoCapture::~VideoCapture() { stop(); }

bool VideoCapture::running() const { return impl_->running.load(); }

std::vector<uint8_t> VideoCapture::latest_jpeg() const {
    std::lock_guard<std::mutex> g(impl_->jpeg_mu);
    return impl_->latest;
}

uint64_t VideoCapture::frame_seq() const { return impl_->seq.load(); }

// No TCC on Linux, and no equivalent: access to /dev/video* is a filesystem
// permission, granted by membership of the `video` group at login. If the
// process cannot open the node it fails immediately with EACCES rather than
// waiting on a prompt, so there is nothing to request and nothing to retry.
void VideoCapture::request_camera_permission(
    std::function<void(bool granted)> on_result) {
    if (on_result) on_result(true);
}

bool VideoCapture::start(const std::string& name_substr) {
    std::string want = to_lower(name_substr.empty() ? "obsbot" : name_substr);
    for (const auto& d : list_av_devices()) {
        if (to_lower(d.name).find(want) != std::string::npos)
            return start_unique_id(d.unique_id);
    }
    LOGW("v4l2: no capture device matching '%s'", want.c_str());
    return false;
}

bool VideoCapture::start_unique_id(const std::string& unique_id) {
    std::lock_guard<std::mutex> g(impl_->ctl_mu);
    if (impl_->running.load()) return true;
    if (unique_id.empty()) return false;

    std::string node = resolve_node(unique_id);

    // Retry briefly, as the macOS path does. libdev reports a camera as soon
    // as it has talked to it over the control endpoint, which can be before
    // udev has finished creating the video node.
    int fd = -1;
    for (int attempt = 0; attempt < 20; ++attempt) {
        fd = ::open(node.c_str(), O_RDWR);
        if (fd >= 0) break;
        if (errno == EACCES) {
            LOGE("v4l2: %s permission denied; is this user in the 'video' group?",
                 node.c_str());
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    if (fd < 0) {
        LOGW("v4l2: could not open %s: %s", node.c_str(), std::strerror(errno));
        return false;
    }

    auto fail = [&](const char* what) {
        LOGE("v4l2: %s on %s: %s", what, node.c_str(), std::strerror(errno));
        ::close(fd);
        return false;
    };

    std::string card;
    if (!is_capture_node(fd, &card)) {
        LOGE("v4l2: %s is not a streaming capture device", node.c_str());
        ::close(fd);
        return false;
    }

    // Ask for MJPEG so the camera does the compression. Falling back to a raw
    // format would mean encoding every frame in software here, which is the
    // job this backend exists to avoid; better to fail loudly.
    v4l2_format fmt{};
    fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    fmt.fmt.pix.width       = kCaptureWidth;
    fmt.fmt.pix.height      = kCaptureHeight;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
    fmt.fmt.pix.field       = V4L2_FIELD_ANY;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) == -1) return fail("VIDIOC_S_FMT");
    if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_MJPEG) {
        LOGE("v4l2: %s would not give MJPEG (got %.4s); software encoding is "
             "not implemented", node.c_str(),
             reinterpret_cast<const char*>(&fmt.fmt.pix.pixelformat));
        ::close(fd);
        return false;
    }

    v4l2_requestbuffers req{};
    req.count  = kBufferCount;
    req.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &req) == -1) return fail("VIDIOC_REQBUFS");
    if (req.count < 2) {
        LOGE("v4l2: %s gave only %u buffers", node.c_str(), req.count);
        ::close(fd);
        return false;
    }

    std::vector<Impl::Buffer> bufs(req.count);
    for (uint32_t i = 0; i < req.count; ++i) {
        v4l2_buffer b{};
        b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.memory = V4L2_MEMORY_MMAP;
        b.index  = i;
        if (xioctl(fd, VIDIOC_QUERYBUF, &b) == -1) return fail("VIDIOC_QUERYBUF");
        bufs[i].length = b.length;
        bufs[i].start = ::mmap(nullptr, b.length, PROT_READ | PROT_WRITE,
                               MAP_SHARED, fd, b.m.offset);
        if (bufs[i].start == MAP_FAILED) return fail("mmap");
        if (xioctl(fd, VIDIOC_QBUF, &b) == -1) return fail("VIDIOC_QBUF");
    }

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) == -1) return fail("VIDIOC_STREAMON");

    impl_->fd = fd;
    impl_->buffers = std::move(bufs);
    impl_->stopping.store(false);
    impl_->running.store(true);

    LOGI("v4l2: streaming %ux%u MJPEG from %s (%s)",
         fmt.fmt.pix.width, fmt.fmt.pix.height, node.c_str(), card.c_str());

    Impl* impl = impl_.get();
    impl_->worker = std::thread([impl]() {
        while (!impl->stopping.load()) {
            pollfd p{impl->fd, POLLIN, 0};
            int pr = ::poll(&p, 1, 1000);
            if (pr == 0) continue;                        // idle camera, retry
            if (pr < 0) { if (errno == EINTR) continue; break; }

            v4l2_buffer b{};
            b.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE;
            b.memory = V4L2_MEMORY_MMAP;
            if (xioctl(impl->fd, VIDIOC_DQBUF, &b) == -1) {
                if (errno == EAGAIN) continue;
                LOGW("v4l2: DQBUF failed: %s", std::strerror(errno));
                break;
            }

            if (b.bytesused > 0 && b.index < impl->buffers.size()) {
                // The whole capture path, in one copy. No decode, no encode:
                // these bytes are already the JPEG the MJPEG route serves.
                const auto* src =
                    static_cast<const uint8_t*>(impl->buffers[b.index].start);
                std::vector<uint8_t> frame(src, src + b.bytesused);
                {
                    std::lock_guard<std::mutex> g(impl->jpeg_mu);
                    impl->latest.swap(frame);
                }
                impl->seq.fetch_add(1);
            }

            if (xioctl(impl->fd, VIDIOC_QBUF, &b) == -1) {
                LOGW("v4l2: QBUF failed: %s", std::strerror(errno));
                break;
            }
        }
        impl->running.store(false);
    });

    return true;
}

void VideoCapture::stop() {
    std::lock_guard<std::mutex> g(impl_->ctl_mu);
    if (impl_->fd < 0) return;

    impl_->stopping.store(true);
    if (impl_->worker.joinable()) impl_->worker.join();

    v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    xioctl(impl_->fd, VIDIOC_STREAMOFF, &type);

    for (auto& b : impl_->buffers)
        if (b.start != nullptr && b.start != MAP_FAILED) ::munmap(b.start, b.length);
    impl_->buffers.clear();

    ::close(impl_->fd);
    impl_->fd = -1;
    impl_->running.store(false);

    {
        std::lock_guard<std::mutex> jg(impl_->jpeg_mu);
        impl_->latest.clear();
    }
}

// start_with_device is the macOS-only seam between start() and
// start_unique_id(): it takes a bridged AVCaptureDevice pointer. The V4L2 path
// has no equivalent - both entry points resolve to a device node and share
// start_unique_id - but the declaration is in the shared header, so define it
// rather than diverge the interface.
bool VideoCapture::start_with_device(void* device_ptr) {
    (void)device_ptr;
    return false;
}

}  // namespace obs
