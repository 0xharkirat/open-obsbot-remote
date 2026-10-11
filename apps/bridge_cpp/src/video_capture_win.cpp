// Media Foundation capture backend: the Windows twin of video_capture.mm and
// video_capture_v4l2.cpp.
//
// All three implement video_capture.h in full; this is the only
// Windows-specific translation unit in the bridge apart from the Winsock
// spellings in mjpeg_server.cpp and the stdin watchdog in main.cpp.
//
// Like the V4L2 path, the common case has no encoder in it. The Tiny 2 Lite
// emits MJPEG natively over UVC, and an IMFSourceReader asked for the camera's
// own MJPG media type hands back the compressed sample untouched, so each
// frame is one copy from the sample buffer. A camera that cannot do MJPEG
// (some generic webcams) falls back to RGB32 plus a WIC JPEG encode, which is
// what macOS does for every camera.
//
// Unlike the V4L2 path, the fade primitives are implemented: Windows Imaging
// Component ships with the OS and does the decode/encode round trip that
// Linux would need libjpeg-turbo for.

#include "video_capture.h"
#include "log.h"

#include "dev/dev.hpp"
#include "dev/devs.hpp"

#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <mutex>
#include <set>
#include <thread>

using Microsoft::WRL::ComPtr;

namespace obs {
namespace {

constexpr UINT32 kCaptureWidth  = 1920;
constexpr UINT32 kCaptureHeight = 1080;
constexpr float  kJpegQuality   = 0.85f;

// COM is per thread, and the threads that land here are not ours: libdev's
// hotplug thread, the MJPEG server's per-client threads, the retry path.
// Joining the multithreaded apartment is idempotent and harmless for every
// one of them, so do it lazily wherever MF or WIC is about to be touched.
void ensure_com() {
    thread_local bool done = false;
    if (done) return;
    HRESULT hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    // RPC_E_CHANGED_MODE: the thread is already STA (someone else's choice).
    // COM still works on it, which is all we need.
    done = SUCCEEDED(hr) || hr == RPC_E_CHANGED_MODE;
}

void ensure_mf() {
    static std::once_flag once;
    std::call_once(once, [] {
        ensure_com();
        HRESULT hr = ::MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
        if (FAILED(hr)) LOGE("mf: MFStartup failed: 0x%08lx", (unsigned long)hr);
    });
}

std::string to_utf8(const wchar_t* w) {
    if (w == nullptr || *w == L'\0') return {};
    int n = ::WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1) return {};
    std::string out((size_t)n - 1, '\0');
    ::WideCharToMultiByte(CP_UTF8, 0, w, -1, out.data(), n, nullptr, nullptr);
    return out;
}

std::wstring to_wide(const std::string& s) {
    if (s.empty()) return {};
    int n = ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 1) return {};
    std::wstring out((size_t)n - 1, L'\0');
    ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, out.data(), n);
    return out;
}

std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return (char)std::tolower(c); });
    return s;
}

std::string alloc_string(IMFActivate* a, REFGUID key) {
    wchar_t* w = nullptr;
    UINT32 len = 0;
    if (FAILED(a->GetAllocatedString(key, &w, &len))) return {};
    std::string out = to_utf8(w);
    ::CoTaskMemFree(w);
    return out;
}

struct MfDevice {
    std::string symlink;  // MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK
    std::string name;     // MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME
};

// Every video capture device Media Foundation can open, in MF's order.
//
// The symbolic link is the identity used everywhere else in the bridge. It is
// stable per physical port, and unlike /dev/v4l/by-id on Linux it does tell
// two identical cameras apart: a device without a USB iSerial gets an
// instance ID derived from its port, and that instance ID is part of the link.
std::vector<MfDevice> enumerate_mf_devices() {
    ensure_mf();
    ensure_com();
    std::vector<MfDevice> out;

    ComPtr<IMFAttributes> attrs;
    if (FAILED(::MFCreateAttributes(&attrs, 1))) return out;
    attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                   MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);

    IMFActivate** devs = nullptr;
    UINT32 count = 0;
    if (FAILED(::MFEnumDeviceSources(attrs.Get(), &devs, &count))) return out;
    for (UINT32 i = 0; i < count; ++i) {
        MfDevice d;
        d.symlink = alloc_string(devs[i], MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK);
        d.name    = alloc_string(devs[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME);
        if (!d.symlink.empty()) out.push_back(std::move(d));
        devs[i]->Release();
    }
    ::CoTaskMemFree(devs);
    return out;
}

bool is_obsbot_name(const std::string& name) {
    return to_lower(name).find("obsbot") != std::string::npos;
}

// ----------------------------------------------------------------------------
// WIC helpers for the fade primitives and the non-MJPEG fallback
// ----------------------------------------------------------------------------

IWICImagingFactory* wic() {
    // The WIC factory is free-threaded, so one instance serves every thread.
    static IWICImagingFactory* factory = [] {
        ensure_com();
        IWICImagingFactory* f = nullptr;
        HRESULT hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                        CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&f));
        if (FAILED(hr)) LOGE("wic: factory creation failed: 0x%08lx", (unsigned long)hr);
        return f;
    }();
    ensure_com();
    return factory;
}

// A decoded frame: 24bpp BGR, rows top-down, `stride` bytes apart.
struct Bgr {
    UINT width = 0, height = 0, stride = 0;
    std::vector<uint8_t> px;
};

bool decode_jpeg(const std::vector<uint8_t>& jpeg, Bgr& out,
                 UINT want_w = 0, UINT want_h = 0) {
    IWICImagingFactory* f = wic();
    if (f == nullptr || jpeg.empty()) return false;

    ComPtr<IWICStream> stream;
    if (FAILED(f->CreateStream(&stream))) return false;
    if (FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(jpeg.data()),
                                            (DWORD)jpeg.size()))) return false;
    ComPtr<IWICBitmapDecoder> dec;
    if (FAILED(f->CreateDecoderFromStream(stream.Get(), nullptr,
                                          WICDecodeMetadataCacheOnDemand, &dec))) return false;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (FAILED(dec->GetFrame(0, &frame))) return false;

    ComPtr<IWICBitmapSource> src = frame;
    UINT w = 0, h = 0;
    src->GetSize(&w, &h);
    // Crossfade needs both frames the same size; scale the outgoing one to the
    // incoming one's dimensions when they differ (mixed-resolution cameras).
    if (want_w != 0 && want_h != 0 && (w != want_w || h != want_h)) {
        ComPtr<IWICBitmapScaler> scaler;
        if (FAILED(f->CreateBitmapScaler(&scaler))) return false;
        if (FAILED(scaler->Initialize(src.Get(), want_w, want_h,
                                      WICBitmapInterpolationModeLinear))) return false;
        src = scaler;
        w = want_w; h = want_h;
    }

    ComPtr<IWICFormatConverter> conv;
    if (FAILED(f->CreateFormatConverter(&conv))) return false;
    if (FAILED(conv->Initialize(src.Get(), GUID_WICPixelFormat24bppBGR,
                                WICBitmapDitherTypeNone, nullptr, 0.0,
                                WICBitmapPaletteTypeCustom))) return false;

    out.width = w;
    out.height = h;
    out.stride = (w * 3 + 3) & ~3u;
    out.px.resize((size_t)out.stride * h);
    return SUCCEEDED(conv->CopyPixels(nullptr, out.stride, (UINT)out.px.size(),
                                      out.px.data()));
}

// Luma sampling factors of a JPEG's first component, read from its SOF
// marker: 2x1 is 4:2:2 (what the Tiny 2 Lite sends), 2x2 is 4:2:0.
bool jpeg_sampling(const std::vector<uint8_t>& j, int& w, int& h, int& hs, int& vs) {
    size_t i = 2;
    while (i + 11 < j.size()) {
        if (j[i] != 0xFF) { ++i; continue; }
        const uint8_t m = j[i + 1];
        if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
            h = (j[i + 5] << 8) | j[i + 6];
            w = (j[i + 7] << 8) | j[i + 8];
            hs = j[i + 11] >> 4;
            vs = j[i + 11] & 0x0F;
            return true;
        }
        if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7)) { i += 2; continue; }
        i += 2 + ((j[i + 2] << 8) | j[i + 3]);
    }
    return false;
}

// WICJpegYCrCbSubsampling for a luma sampling pair; 0 = encoder default.
BYTE wic_subsampling(int hs, int vs) {
    if (hs == 2 && vs == 2) return WICJpegYCrCbSubsampling420;
    if (hs == 2 && vs == 1) return WICJpegYCrCbSubsampling422;
    if (hs == 1 && vs == 1) return WICJpegYCrCbSubsampling444;
    if (hs == 1 && vs == 2) return WICJpegYCrCbSubsampling440;
    return 0;
}

// Encode `px` (top-down rows, `stride` bytes apart) as a JPEG.
// `format` is GUID_WICPixelFormat24bppBGR or GUID_WICPixelFormat32bppBGR.
// `subsampling` is a WICJpegYCrCbSubsampling value, 0 for the encoder default.
std::vector<uint8_t> encode_jpeg(const uint8_t* px, UINT w, UINT h, UINT stride,
                                 REFWICPixelFormatGUID format, BYTE subsampling = 0) {
    IWICImagingFactory* f = wic();
    if (f == nullptr) return {};

    ComPtr<IStream> mem;
    if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &mem))) return {};
    ComPtr<IWICBitmapEncoder> enc;
    if (FAILED(f->CreateEncoder(GUID_ContainerFormatJpeg, nullptr, &enc))) return {};
    if (FAILED(enc->Initialize(mem.Get(), WICBitmapEncoderNoCache))) return {};

    ComPtr<IWICBitmapFrameEncode> frame;
    ComPtr<IPropertyBag2> props;
    if (FAILED(enc->CreateNewFrame(&frame, &props))) return {};
    {
        PROPBAG2 opt[2]{};
        VARIANT v[2];
        opt[0].pstrName = const_cast<LPOLESTR>(L"ImageQuality");
        ::VariantInit(&v[0]);
        v[0].vt = VT_R4;
        v[0].fltVal = kJpegQuality;
        opt[1].pstrName = const_cast<LPOLESTR>(L"JpegYCrCbSubsampling");
        ::VariantInit(&v[1]);
        v[1].vt = VT_UI1;
        v[1].bVal = subsampling;
        props->Write(subsampling ? 2 : 1, opt, v);
    }
    if (FAILED(frame->Initialize(props.Get()))) return {};
    if (FAILED(frame->SetSize(w, h))) return {};

    WICPixelFormatGUID fmt = format;
    if (FAILED(frame->SetPixelFormat(&fmt))) return {};

    if (IsEqualGUID(fmt, format)) {
        if (FAILED(frame->WritePixels(h, stride, stride * h,
                                      const_cast<BYTE*>(px)))) return {};
    } else {
        // The JPEG encoder wants 24bpp; convert through a WIC bitmap.
        ComPtr<IWICBitmap> bmp;
        if (FAILED(f->CreateBitmapFromMemory(w, h, format, stride, stride * h,
                                             const_cast<BYTE*>(px), &bmp))) return {};
        ComPtr<IWICFormatConverter> conv;
        if (FAILED(f->CreateFormatConverter(&conv))) return {};
        if (FAILED(conv->Initialize(bmp.Get(), fmt, WICBitmapDitherTypeNone,
                                    nullptr, 0.0, WICBitmapPaletteTypeCustom))) return {};
        if (FAILED(frame->WriteSource(conv.Get(), nullptr))) return {};
    }
    if (FAILED(frame->Commit())) return {};
    if (FAILED(enc->Commit())) return {};

    HGLOBAL hg = nullptr;
    if (FAILED(::GetHGlobalFromStream(mem.Get(), &hg))) return {};
    STATSTG st{};
    if (FAILED(mem->Stat(&st, STATFLAG_NONAME))) return {};
    const size_t n = (size_t)st.cbSize.QuadPart;
    const auto* p = static_cast<const uint8_t*>(::GlobalLock(hg));
    if (p == nullptr) return {};
    std::vector<uint8_t> out(p, p + n);
    ::GlobalUnlock(hg);
    return out;
}

}  // namespace

// ----------------------------------------------------------------------------
// Fade primitives
// ----------------------------------------------------------------------------

std::vector<uint8_t> jpeg_darken(const std::vector<uint8_t>& jpeg, float factor) {
    if (factor >= 1.0f || jpeg.empty()) return jpeg;
    if (factor < 0.0f) factor = 0.0f;
    Bgr img;
    if (!decode_jpeg(jpeg, img)) return jpeg;
    const int k = (int)std::lround(factor * 256.0f);
    for (auto& b : img.px) b = (uint8_t)((b * k) >> 8);
    // Same chroma format as the camera's own frames, so the stream around the
    // fade does not change format (see jpeg_conform).
    int w = 0, h = 0, hs = 0, vs = 0;
    const BYTE sub = jpeg_sampling(jpeg, w, h, hs, vs) ? wic_subsampling(hs, vs) : 0;
    auto out = encode_jpeg(img.px.data(), img.width, img.height, img.stride,
                           GUID_WICPixelFormat24bppBGR, sub);
    return out.empty() ? jpeg : out;
}

std::vector<uint8_t> jpeg_crossfade(const std::vector<uint8_t>& outgoing,
                                    const std::vector<uint8_t>& incoming,
                                    float factor) {
    if (outgoing.empty() || factor >= 1.0f || incoming.empty()) return incoming;
    if (factor < 0.0f) factor = 0.0f;
    Bgr in;
    if (!decode_jpeg(incoming, in)) return incoming;
    Bgr out_img;
    if (!decode_jpeg(outgoing, out_img, in.width, in.height)) return incoming;
    if (out_img.px.size() != in.px.size()) return incoming;

    const int k = (int)std::lround(factor * 256.0f);   // weight of incoming
    for (size_t i = 0; i < in.px.size(); ++i)
        in.px[i] = (uint8_t)((in.px[i] * k + out_img.px[i] * (256 - k)) >> 8);
    int w = 0, h = 0, hs = 0, vs = 0;
    const BYTE sub = jpeg_sampling(incoming, w, h, hs, vs) ? wic_subsampling(hs, vs) : 0;
    auto out = encode_jpeg(in.px.data(), in.width, in.height, in.stride,
                           GUID_WICPixelFormat24bppBGR, sub);
    return out.empty() ? incoming : out;
}

std::vector<uint8_t> jpeg_conform(const std::vector<uint8_t>& jpeg,
                                  int width, int height,
                                  int luma_h, int luma_v) {
    int w = 0, h = 0, hs = 0, vs = 0;
    if (!jpeg_sampling(jpeg, w, h, hs, vs)) return {};
    if (w == width && h == height && hs == luma_h && vs == luma_v) return jpeg;
    const BYTE sub = wic_subsampling(luma_h, luma_v);
    if (sub == 0) return {};
    // Letterbox rather than stretch, as the macOS pipeline does (2.5.0): fit
    // the source inside the stream's size, centred on black, so a 4:3 webcam
    // keeps its shape in a 16:9 program.
    UINT fw = (UINT)width, fh = (UINT)height;
    if (w > 0 && h > 0) {
        if ((long long)w * height > (long long)h * width) fh = (UINT)((long long)h * width / w);
        else                                              fw = (UINT)((long long)w * height / h);
    }
    fw = std::max(2u, fw & ~1u);
    fh = std::max(2u, fh & ~1u);
    Bgr img;
    if (!decode_jpeg(jpeg, img, fw, fh)) return {};
    Bgr canvas;
    canvas.width = (UINT)width;
    canvas.height = (UINT)height;
    canvas.stride = (canvas.width * 3 + 3) & ~3u;
    canvas.px.assign((size_t)canvas.stride * canvas.height, 0);
    const UINT ox = (canvas.width - img.width) / 2, oy = (canvas.height - img.height) / 2;
    for (UINT y = 0; y < img.height; ++y)
        std::memcpy(canvas.px.data() + (size_t)(y + oy) * canvas.stride + ox * 3,
                    img.px.data() + (size_t)y * img.stride, (size_t)img.width * 3);
    return encode_jpeg(canvas.px.data(), canvas.width, canvas.height, canvas.stride,
                       GUID_WICPixelFormat24bppBGR, sub);
}

// ----------------------------------------------------------------------------
// SN -> capture-device join
// ----------------------------------------------------------------------------

// On Windows, unlike Linux, the SDK does declare Device::videoDevPath(): dev.hpp
// guards it with `#ifdef _WIN32 / #elif __APPLE__`, returning std::wstring
// here: a device-interface path for the camera's video function. Match it
// against what MF enumerates so the id this returns is exactly what
// start_unique_id() and list_av_devices() use.
std::string device_video_path(Device* dev) {
    if (dev == nullptr) return {};

    // The Windows overload returns std::wstring (dev.hpp, `#ifdef _WIN32`).
    const std::string sdk_path = to_lower(to_utf8(dev->videoDevPath().c_str()));
    LOGI("mf: libdev reports video path '%s' for %s", sdk_path.c_str(),
         dev->devSn().c_str());
    const auto devices = enumerate_mf_devices();

    if (!sdk_path.empty()) {
        for (const auto& d : devices)
            if (to_lower(d.symlink) == sdk_path) return d.symlink;
        // Measured on a Tiny 2 Lite (SDK 1.3.0, Windows 11): libdev returns the
        // DirectShow interface path, class {65e8773d-...} (KSCATEGORY_VIDEO),
        // while MF enumerates the same function under {e5323777-...}
        // (KSCATEGORY_VIDEO_CAMERA). Everything before "#{" is the device
        // instance and is identical in both, so join on that. It is exact
        // per physical camera, port-derived when there is no USB serial.
        auto instance = [](const std::string& p) {
            auto k = p.find("#{");
            return k == std::string::npos ? p : p.substr(0, k);
        };
        const std::string want = instance(sdk_path);
        for (const auto& d : devices)
            if (instance(to_lower(d.symlink)) == want) return d.symlink;
        LOGW("mf: libdev path '%s' for %s matches no capture device; "
             "falling back to name order", sdk_path.c_str(), dev->devSn().c_str());
    }

    // Fallback, as on Linux: the Nth camera libdev reports takes the Nth
    // OBSBOT capture device in MF order.
    std::vector<std::string> obsbot;
    for (const auto& d : devices)
        if (is_obsbot_name(d.name)) obsbot.push_back(d.symlink);
    if (obsbot.empty()) {
        LOGW("mf: no OBSBOT capture device found for %s", dev->devSn().c_str());
        return {};
    }
    if (obsbot.size() == 1) return obsbot.front();

    const std::string sn = dev->devSn();
    size_t index = 0;
    bool found = false;
    for (auto& d : Devices::get().getDevList()) {
        if (d && d->devSn() == sn) { found = true; break; }
        ++index;
    }
    if (!found || index >= obsbot.size()) {
        LOGW("mf: %s not positionally matched among %zu OBSBOT devices",
             sn.c_str(), obsbot.size());
        return {};
    }
    LOGW("mf: %s joined to capture device %zu POSITIONALLY; verify the preview "
         "matches the camera you are driving", sn.c_str(), index);
    return obsbot[index];
}

// ----------------------------------------------------------------------------
// Enumeration and hotplug
// ----------------------------------------------------------------------------

std::vector<AvVideoDevice> list_av_devices() {
    std::vector<AvVideoDevice> out;
    for (auto& d : enumerate_mf_devices()) {
        AvVideoDevice v;
        v.unique_id = d.symlink;
        v.name = d.name;
        v.is_obsbot = is_obsbot_name(d.name);
        out.push_back(std::move(v));
    }
    return out;
}

// Polls, for the same reason the V4L2 path does: it only drives generic-source
// captures (OBSBOT attach/detach come from libdev's hotplug thread), and a 2s
// delay is not worth a hidden window for WM_DEVICECHANGE.
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
    ComPtr<IMFMediaSource> source;
    ComPtr<IMFSourceReader> reader;
    bool native_mjpeg = true;   // false: RGB32 frames, encoded here
    UINT32 width = 0, height = 0;

    std::thread worker;
    std::atomic<bool> stopping{false};

    mutable std::mutex jpeg_mu;
    std::vector<uint8_t> latest;
    std::atomic<uint64_t> seq{0};

    // Serialises start/stop against each other, matching the other backends.
    std::mutex ctl_mu;
    // Guards `source` while the worker swaps it during a reopen.
    std::mutex src_mu;
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

// Windows has no per-app prompt for desktop programs. Camera access is one
// switch, Settings > Privacy & security > Camera > "Let desktop apps access
// your camera", and when it is off the device open fails with
// E_ACCESSDENIED straight away (logged in start_unique_id). Nothing to request.
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
    LOGW("mf: no capture device matching '%s'", want.c_str());
    return false;
}

namespace {

// Pick the camera's best native MJPEG mode: 1080p if offered, at the highest
// frame rate not above 30. 60fps MJPEG doubles the preview's bandwidth for
// nothing OBS or a phone can use. Returns nullptr if there is no MJPEG at all.
ComPtr<IMFMediaType> pick_mjpeg_type(IMFSourceReader* reader) {
    ComPtr<IMFMediaType> best;
    double best_score = -1;
    for (DWORD i = 0;; ++i) {
        ComPtr<IMFMediaType> t;
        HRESULT hr = reader->GetNativeMediaType(
            (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, i, &t);
        if (hr == MF_E_NO_MORE_TYPES || FAILED(hr)) break;
        GUID sub{};
        if (FAILED(t->GetGUID(MF_MT_SUBTYPE, &sub)) || sub != MFVideoFormat_MJPG) continue;
        UINT32 w = 0, h = 0, num = 0, den = 1;
        MFGetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, &w, &h);
        MFGetAttributeRatio(t.Get(), MF_MT_FRAME_RATE, &num, &den);
        const double fps = den ? (double)num / den : 0;
        double score = 0;
        if (w == kCaptureWidth && h == kCaptureHeight) score += 1e9;
        else if (w <= kCaptureWidth) score += (double)w * h;   // biggest that fits
        score += (fps <= 30.5 ? fps * 1000 : 30000 - fps);
        if (score > best_score) { best_score = score; best = t; }
    }
    return best;
}

// One opened camera: the device source plus a reader configured for either
// the camera's native MJPEG (preferred) or RGB32 for the WIC fallback.
struct Opened {
    ComPtr<IMFMediaSource> source;
    ComPtr<IMFSourceReader> reader;
    bool native = false;
    UINT32 w = 0, h = 0;
};

// Open the device and configure a reader. `attempts` covers the window where
// libdev reports a camera before Windows has its video interface up. Errors
// are logged only when `verbose`, so the busy-camera retry loop stays quiet.
HRESULT open_camera(const std::string& uid, Opened& out, int attempts, bool verbose) {
    const std::wstring wlink = to_wide(uid);
    ComPtr<IMFAttributes> attrs;
    HRESULT hr = ::MFCreateAttributes(&attrs, 2);
    if (FAILED(hr)) return hr;
    attrs->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                   MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    attrs->SetString(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                     wlink.c_str());

    ComPtr<IMFMediaSource> source;
    hr = E_FAIL;
    for (int attempt = 0; attempt < attempts; ++attempt) {
        hr = ::MFCreateDeviceSource(attrs.Get(), &source);
        if (SUCCEEDED(hr) || hr == E_ACCESSDENIED) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }
    if (hr == E_ACCESSDENIED) {
        LOGE("mf: camera access denied. Turn on Settings > Privacy & security "
             "> Camera > 'Let desktop apps access your camera'");
        return hr;
    }
    if (FAILED(hr)) {
        if (verbose) LOGW("mf: could not open %s: 0x%08lx", uid.c_str(), (unsigned long)hr);
        return hr;
    }

    // Two readers, one for each path. The native-MJPEG reader must NOT enable
    // video processing, or MF would insert a decoder; the fallback reader
    // needs it, to convert whatever the camera emits into RGB32.
    auto make_reader = [&](bool processing, ComPtr<IMFSourceReader>& r) {
        ComPtr<IMFAttributes> ra;
        ::MFCreateAttributes(&ra, 1);
        ra->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, processing ? TRUE : FALSE);
        return SUCCEEDED(::MFCreateSourceReaderFromMediaSource(source.Get(), ra.Get(), &r));
    };

    ComPtr<IMFSourceReader> reader;
    bool native = false;
    UINT32 w = 0, h = 0;
    if (make_reader(false, reader)) {
        if (auto t = pick_mjpeg_type(reader.Get())) {
            if (SUCCEEDED(reader->SetCurrentMediaType(
                    (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, nullptr, t.Get()))) {
                MFGetAttributeSize(t.Get(), MF_MT_FRAME_SIZE, &w, &h);
                native = true;
            }
        }
    }
    if (!native) {
        reader.Reset();
        if (!make_reader(true, reader)) {
            if (verbose) LOGE("mf: could not create a source reader for %s", uid.c_str());
            source->Shutdown();
            return E_FAIL;
        }
        ComPtr<IMFMediaType> t;
        ::MFCreateMediaType(&t);
        t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        t->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
        hr = reader->SetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM,
                                         nullptr, t.Get());
        if (FAILED(hr)) {
            if (verbose)
                LOGE("mf: %s offers neither MJPEG nor an RGB32 conversion: 0x%08lx",
                     uid.c_str(), (unsigned long)hr);
            source->Shutdown();
            return hr;
        }
        ComPtr<IMFMediaType> cur;
        reader->GetCurrentMediaType((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, &cur);
        if (cur) MFGetAttributeSize(cur.Get(), MF_MT_FRAME_SIZE, &w, &h);
    }

    out.source = source;
    out.reader = reader;
    out.native = native;
    out.w = w;
    out.h = h;
    return S_OK;
}

}  // namespace

// Called on the worker thread after the stream failed. Drops the dead source
// and reopens the camera every 2s until it succeeds or stop() is called. Only
// the worker touches `reader`; `source` is swapped under src_mu because stop()
// shuts it down from another thread to unblock ReadSample.
static bool reopen(VideoCapture::Impl* impl, const std::string& uid) {
    {
        std::lock_guard<std::mutex> g(impl->src_mu);
        if (impl->source) impl->source->Shutdown();
        impl->reader.Reset();
        impl->source.Reset();
    }
    {
        // No stale frame: the MJPEG server answers 503 rather than freezing on
        // the last picture while the camera is held elsewhere.
        std::lock_guard<std::mutex> jg(impl->jpeg_mu);
        impl->latest.clear();
    }
    for (int tries = 0; !impl->stopping.load(); ++tries) {
        for (int i = 0; i < 20 && !impl->stopping.load(); ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (impl->stopping.load()) break;
        Opened o;
        if (FAILED(open_camera(uid, o, 1, false))) continue;
        std::lock_guard<std::mutex> g(impl->src_mu);
        if (impl->stopping.load()) { o.source->Shutdown(); break; }
        impl->source = o.source;
        impl->reader = o.reader;
        impl->native_mjpeg = o.native;
        impl->width = o.w;
        impl->height = o.h;
        // Not logged here: opening succeeds even while another app holds the
        // stream, and only the first frame proves the camera is ours again.
        // The worker announces that, since the supervisor reads "capture
        // session started" as the camera being up.
        return true;
    }
    return false;
}

bool VideoCapture::start_unique_id(const std::string& unique_id) {
    std::lock_guard<std::mutex> g(impl_->ctl_mu);
    if (impl_->running.load()) return true;
    if (unique_id.empty()) return false;
    ensure_mf();
    ensure_com();

    Opened o;
    if (FAILED(open_camera(unique_id, o, 20, true))) return false;

    impl_->source = o.source;
    impl_->reader = o.reader;
    impl_->native_mjpeg = o.native;
    impl_->width = o.w;
    impl_->height = o.h;
    impl_->stopping.store(false);
    impl_->running.store(true);

    // "video: capture session started" is the line the supervisor keys camera
    // status off (same string the AVFoundation path logs).
    LOGI("video: capture session started (Media Foundation, %ux%u %s) for %s",
         o.w, o.h, o.native ? "native MJPEG" : "RGB32 + WIC encode", unique_id.c_str());

    Impl* impl = impl_.get();
    const std::string uid = unique_id;
    impl_->worker = std::thread([impl, uid]() {
        ensure_com();
        bool recovering = false;
        while (!impl->stopping.load()) {
            DWORD flags = 0;
            ComPtr<IMFSample> sample;
            HRESULT hr = impl->reader->ReadSample(
                (DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0,
                nullptr, &flags, nullptr, &sample);
            if (FAILED(hr) || (flags & (MF_SOURCE_READERF_ERROR |
                                        MF_SOURCE_READERF_ENDOFSTREAM))) {
                if (impl->stopping.load()) break;
                // A UVC stream is exclusive on Windows. The usual failure here
                // is another app (OBS's own Video Capture Device, OBSBOT
                // Center, Teams) opening the camera first, which surfaces as
                // MF_E_HW_MFT_FAILED_START_STREAMING or a hardware-busy error.
                // Giving up made the preview dead until a bridge restart; keep
                // the slot and reopen until the camera is free again. An
                // unplug ends here too, and libdev's detach stops us.
                if (hr == (HRESULT)0xC00D3704 /*MF_E_HW_MFT_FAILED_START_STREAMING*/ ||
                    hr == (HRESULT)0xC00D3EA2 /*MF_E_VIDEO_RECORDING_DEVICE_PREEMPTED*/ ||
                    hr == (HRESULT)0x800700AA /*ERROR_BUSY*/) {
                    LOGW("mf: camera is in use by another app (0x%08lx); close it "
                         "or remove its Video Capture Device in OBS. Retrying.",
                         (unsigned long)hr);
                } else {
                    LOGW("mf: ReadSample failed: 0x%08lx; reopening", (unsigned long)hr);
                }
                if (!reopen(impl, uid)) break;
                recovering = true;
                continue;
            }
            if (!sample) continue;   // stream tick, no picture
            if (recovering) {
                recovering = false;
                LOGI("video: capture session started (Media Foundation, %ux%u %s) "
                     "for %s (recovered)", impl->width, impl->height,
                     impl->native_mjpeg ? "native MJPEG" : "RGB32 + WIC encode",
                     uid.c_str());
            }

            ComPtr<IMFMediaBuffer> buf;
            if (FAILED(sample->ConvertToContiguousBuffer(&buf))) continue;

            std::vector<uint8_t> frame;
            if (impl->native_mjpeg) {
                // The whole capture path, in one copy: these bytes are already
                // the JPEG the MJPEG route serves.
                BYTE* p = nullptr;
                DWORD len = 0;
                if (FAILED(buf->Lock(&p, nullptr, &len))) continue;
                frame.assign(p, p + len);
                buf->Unlock();
            } else {
                // Lock2D gives the real pitch, which is negative for a
                // bottom-up RGB buffer; walking from scanline 0 by pitch reads
                // it top-down either way.
                ComPtr<IMF2DBuffer> b2;
                BYTE* scan0 = nullptr;
                LONG pitch = 0;
                if (SUCCEEDED(buf.As(&b2)) && SUCCEEDED(b2->Lock2D(&scan0, &pitch))) {
                    const UINT row = impl->width * 4;
                    std::vector<uint8_t> px((size_t)row * impl->height);
                    for (UINT y = 0; y < impl->height; ++y)
                        std::memcpy(px.data() + (size_t)y * row, scan0 + (LONG)y * pitch, row);
                    b2->Unlock2D();
                    frame = encode_jpeg(px.data(), impl->width, impl->height, row,
                                        GUID_WICPixelFormat32bppBGR);
                } else {
                    BYTE* p = nullptr;
                    DWORD len = 0;
                    if (FAILED(buf->Lock(&p, nullptr, &len))) continue;
                    const UINT row = impl->width * 4;
                    if (len >= (DWORD)row * impl->height)
                        frame = encode_jpeg(p, impl->width, impl->height, row,
                                            GUID_WICPixelFormat32bppBGR);
                    buf->Unlock();
                }
            }
            if (frame.empty()) continue;
            {
                std::lock_guard<std::mutex> g(impl->jpeg_mu);
                impl->latest.swap(frame);
            }
            impl->seq.fetch_add(1);
        }
        impl->running.store(false);
    });

    return true;
}

void VideoCapture::stop() {
    std::lock_guard<std::mutex> g(impl_->ctl_mu);
    if (!impl_->running.load() && !impl_->worker.joinable()) return;

    impl_->stopping.store(true);
    // Shutting the source down makes a ReadSample blocked on a stalled camera
    // return MF_E_SHUTDOWN, so the join below cannot hang.
    {
        std::lock_guard<std::mutex> sg(impl_->src_mu);
        if (impl_->source) impl_->source->Shutdown();
    }
    if (impl_->worker.joinable()) impl_->worker.join();

    impl_->reader.Reset();
    impl_->source.Reset();
    impl_->running.store(false);

    {
        std::lock_guard<std::mutex> jg(impl_->jpeg_mu);
        impl_->latest.clear();
    }
}

// start_with_device is the macOS-only seam between start() and
// start_unique_id(); see the matching note in video_capture_v4l2.cpp.
bool VideoCapture::start_with_device(void* device_ptr) {
    (void)device_ptr;
    return false;
}

}  // namespace obs
