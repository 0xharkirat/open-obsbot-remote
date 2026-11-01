#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "video_capture.h"
#include "log.h"

#include <algorithm>
#include <atomic>
#include <map>

@class ObsCaptureDelegate;

namespace obs {

struct VideoCapture::Impl {
    AVCaptureSession* session = nil;
    AVCaptureDevice*  device  = nil;
    AVCaptureDeviceInput* input = nil;
    AVCaptureVideoDataOutput* output = nil;
    ObsCaptureDelegate* delegate = nil;
    dispatch_queue_t queue = nullptr;

    mutable std::mutex jpeg_mu;
    std::vector<uint8_t> latest;
    std::atomic<uint64_t> seq{0};

    // Smaller preview variants: the claim counts and each live variant's
    // latest frame. They live here, not on the delegate, so they survive a
    // capture restart (the wake path in DeviceManager::set_active). The
    // delegate owns only the VideoToolbox objects that make the frames.
    struct VariantSlot {
        std::vector<uint8_t> latest;
        uint64_t seq = 0;
    };
    mutable std::mutex var_mu;
    preview::VariantRefs var_refs;
    std::map<preview::VariantKey, VariantSlot> var_slots;

    // Serialises start/stop. attach() runs on the libdev hotplug thread, but
    // retry_pending_captures() (after a late camera-permission grant) runs on
    // an AVFoundation callback thread - so start_unique_id/start_with_device/
    // stop can be entered concurrently on the same Impl and race the session /
    // input / output pointers. This lock prevents that. running() stays
    // lock-free (it only reads the atomic below).
    std::mutex ctl_mu;

    // Written under ctl_mu (start/stop), read lock-free by the MJPEG serving
    // threads via VideoCapture::running().
    std::atomic<bool> running{false};
};

}  // namespace obs

// ----------------------------------------------------------------------------

// The VideoToolbox objects for 1 small preview variant: a scaler from the
// program frame, the w x h buffer it writes, and a JPEG session at the
// variant's quality. Owned by the delegate, used only on its capture queue.
struct VtVariant {
    VTPixelTransferSessionRef scaler = nullptr;
    CVPixelBufferRef buf = nullptr;
    VTCompressionSessionRef enc = nullptr;
};

static void release_vt_variant(VtVariant& v) {
    if (v.enc) {
        VTCompressionSessionInvalidate(v.enc);
        CFRelease(v.enc);
        v.enc = nullptr;
    }
    if (v.scaler) {
        VTPixelTransferSessionInvalidate(v.scaler);
        CFRelease(v.scaler);
        v.scaler = nullptr;
    }
    if (v.buf) {
        CVPixelBufferRelease(v.buf);
        v.buf = nullptr;
    }
}

// An IOSurface-backed BGRA buffer, or null.
static CVPixelBufferRef make_bgra_buffer(int w, int h) {
    NSDictionary* attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef buf = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs,
                            &buf) != kCVReturnSuccess)
        return nullptr;
    return buf;
}

// A real-time VideoToolbox JPEG session at `quality` (0..1), or null.
static VTCompressionSessionRef make_jpeg_session(int w, int h, float quality) {
    VTCompressionSessionRef s = nullptr;
    OSStatus st = VTCompressionSessionCreate(
        kCFAllocatorDefault, w, h, kCMVideoCodecType_JPEG,
        nullptr, nullptr, nullptr, nullptr, nullptr, &s);
    if (st != noErr || !s) return nullptr;
    CFNumberRef qn = CFNumberCreate(nullptr, kCFNumberFloat32Type, &quality);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_Quality, qn);
    CFRelease(qn);
    VTSessionSetProperty(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    return s;
}

// Encode 1 frame through `s` into `out`. Returns false on any failure.
static bool encode_jpeg(VTCompressionSessionRef s, CVPixelBufferRef pb,
                        CMTime pts, std::vector<uint8_t>& out) {
    __block std::vector<uint8_t>* sink = &out;
    __block bool got = false;
    OSStatus st = VTCompressionSessionEncodeFrameWithOutputHandler(
        s, pb, pts, kCMTimeInvalid, nullptr, nullptr,
        ^(OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
            if (status != noErr || !sb) return;
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            if (!bb) return;
            size_t len = CMBlockBufferGetDataLength(bb);
            if (len == 0) return;
            sink->resize(len);
            if (CMBlockBufferCopyDataBytes(bb, 0, len, sink->data()) == noErr)
                got = true;
        });
    if (st != noErr) return false;
    // Blocks until the handler above has run, so `sink`/`got` are safe to
    // read after this returns (the handler fires on VT's queue, before this
    // completes).
    VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
    return got && !sink->empty();
}

// Scale the program frame to the variant's size on the VT hardware path and
// encode it at the variant's quality. The VT objects are made on first use.
static bool encode_variant(VtVariant& v, const obs::preview::VariantKey& k,
                           CVPixelBufferRef program, CMTime pts,
                           std::vector<uint8_t>& out) {
    const int w = k.w, h = obs::preview::height_for(k.w);
    if (!v.scaler &&
        VTPixelTransferSessionCreate(kCFAllocatorDefault, &v.scaler) != noErr) {
        v.scaler = nullptr;
        return false;
    }
    if (!v.buf && !(v.buf = make_bgra_buffer(w, h))) return false;
    if (VTPixelTransferSessionTransferImage(v.scaler, program, v.buf) != noErr)
        return false;
    if (!v.enc && !(v.enc = make_jpeg_session(w, h, k.q_pct / 100.0f)))
        return false;
    return encode_jpeg(v.enc, v.buf, pts, out);
}

@interface ObsCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
@public
    obs::VideoCapture::Impl* impl;
    // VideoToolbox JPEG session, created lazily off the first frame's
    // dimensions and torn down if they ever change. One per capture (per
    // camera), used only from that capture's AVFoundation callback queue, so
    // no locking is needed around it.
    VTCompressionSessionRef vtSession;
    int vtW, vtH;
    // Hardware scaler + reusable canonical-size buffer for cameras that do
    // not capture at the program format (lazily created, same thread rule).
    VTPixelTransferSessionRef vtScaler;
    CVPixelBufferRef vtCanonBuf;
    // The VT objects of each live small preview variant (same thread rule).
    std::map<obs::preview::VariantKey, VtVariant> vtVariants;
}
@end

// The canonical program format. EVERY source is scaled (letterboxed if the
// aspect differs) to this before encoding, so the full active.mjpg never
// changes dimensions mid-stream. (A small preview stream is scaled from this
// frame; it gets the full-size frame only for a frame whose variant encode
// fails.) A dimension change is not cosmetic: OBS re-inits its
// decoder and scene transform on one, which shows as a flash + abrupt cut on
// every TAKE between differently-sized cameras (a 720p Camo against 1080p
// OBSBOTs), and mixed-size crossfades would blend mismatched extents. A real
// vision mixer has one program format for the same reason.
static const int kCanonW = 1920;
static const int kCanonH = 1080;

@implementation ObsCaptureDelegate

// Release every VideoToolbox object this delegate owns. A capture stop or
// restart (the wake path) drops the delegate, and before this method the
// program session, scaler, and buffer leaked on each one.
- (void)dealloc {
    if (vtSession) {
        VTCompressionSessionInvalidate(vtSession);
        CFRelease(vtSession);
    }
    if (vtScaler) {
        VTPixelTransferSessionInvalidate(vtScaler);
        CFRelease(vtScaler);
    }
    if (vtCanonBuf) CVPixelBufferRelease(vtCanonBuf);
    for (auto& kv : vtVariants) release_vt_variant(kv.second);
}

// VideoToolbox JPEG straight off the CVPixelBuffer. The old (still present,
// now fallback) path rendered through Core Image - GPU render + readback +
// software ImageIO encode - which costs ~54ms per 1080p frame and capped the
// whole preview at ~18fps with the bridge burning ~80% CPU. VT encodes the
// same frame in a few ms, so the stream runs at the camera's native rate.
// Color: VT reads the buffer's own colorimetry tags (the sRGB forcing below
// was only ever a fix for Core Image's wide-gamut misread).
// Scale an off-format frame to the canonical program size on the VT hardware
// path. Returns the reused canonical buffer (valid until the next call), or
// null on failure (caller falls back to Core Image).
- (CVPixelBufferRef)canonicalize:(CVPixelBufferRef)pb {
    if (!vtScaler) {
        if (VTPixelTransferSessionCreate(kCFAllocatorDefault, &vtScaler) !=
            noErr) {
            vtScaler = nullptr;
            return nullptr;
        }
        VTSessionSetProperty(vtScaler,
                             kVTPixelTransferPropertyKey_ScalingMode,
                             kVTScalingMode_Letterbox);
    }
    if (!vtCanonBuf && !(vtCanonBuf = make_bgra_buffer(kCanonW, kCanonH)))
        return nullptr;
    if (VTPixelTransferSessionTransferImage(vtScaler, pb, vtCanonBuf) != noErr)
        return nullptr;
    return vtCanonBuf;
}

// `program` gets the canonical frame that was encoded, for the variants.
- (bool)vtEncode:(CVPixelBufferRef)pb
             pts:(CMTime)pts
            into:(std::vector<uint8_t>&)out
         program:(CVPixelBufferRef*)program {
    int w = (int)CVPixelBufferGetWidth(pb);
    int h = (int)CVPixelBufferGetHeight(pb);
    if (w <= 0 || h <= 0) return false;
    if (w != kCanonW || h != kCanonH) {
        CVPixelBufferRef canon = [self canonicalize:pb];
        if (!canon) return false;
        pb = canon;
        w = kCanonW;
        h = kCanonH;
    }

    if (vtSession && (vtW != w || vtH != h)) {
        VTCompressionSessionInvalidate(vtSession);
        CFRelease(vtSession);
        vtSession = nullptr;
    }
    if (!vtSession) {
        vtSession = make_jpeg_session(w, h, 0.85f);
        if (!vtSession) return false;
        vtW = w; vtH = h;
    }
    *program = pb;
    return encode_jpeg(vtSession, pb, pts, out);
}

// Make this frame's small preview variants from the canonical `program`
// frame (null on the Core Image fallback). A variant that cannot be made
// gets the full-size frame for this frame, so its streams never stall. The VT
// objects of a variant with no claim left are released here.
- (void)encodeVariants:(CVPixelBufferRef)program pts:(CMTime)pts {
    std::vector<obs::preview::VariantKey> live;
    {
        std::lock_guard<std::mutex> g(impl->var_mu);
        live = impl->var_refs.live();
    }
    for (auto it = vtVariants.begin(); it != vtVariants.end();) {
        if (std::find(live.begin(), live.end(), it->first) != live.end()) {
            ++it;
            continue;
        }
        release_vt_variant(it->second);
        it = vtVariants.erase(it);
    }
    for (const auto& k : live) {
        std::vector<uint8_t> jpeg;
        if (!program || !encode_variant(vtVariants[k], k, program, pts, jpeg)) {
            std::lock_guard<std::mutex> g(impl->jpeg_mu);
            jpeg = impl->latest;
        }
        std::lock_guard<std::mutex> g(impl->var_mu);
        auto slot = impl->var_slots.find(k);
        if (slot == impl->var_slots.end()) continue;   // released meanwhile
        slot->second.latest = std::move(jpeg);
        ++slot->second.seq;
    }
}

- (void)captureOutput:(AVCaptureOutput*)output
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    // Fast path: VideoToolbox JPEG at the canonical program size (off-format
    // frames go through the VT hardware scaler first, so a 720p or 4K source
    // serves the same 1920x1080 as everything else). Core Image below is the
    // fallback for VT failure only.
    {
        std::vector<uint8_t> jpeg;
        CVPixelBufferRef program = nullptr;
        const CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        if ([self vtEncode:pixelBuffer pts:pts into:jpeg program:&program]) {
            {
                std::lock_guard<std::mutex> g(impl->jpeg_mu);
                impl->latest = std::move(jpeg);
            }
            impl->seq.fetch_add(1, std::memory_order_release);
            [self encodeVariants:program pts:pts];
            return;
        }
    }

    // Force sRGB color space on the input. Without this, CIImage adopts
    // whatever ICC profile the camera buffer carries (some Tiny 2 Lite
    // streams report BT.709 with limited-range pixels), which Core Image
    // then interprets as wide-gamut → preview gets a green/dark cast vs
    // OBSBOT Center's tone-mapped output.
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CIImage* ci = [CIImage imageWithCVPixelBuffer:pixelBuffer
                                          options:@{ kCIImageColorSpace: (__bridge id)srgb }];
    if (!ci) {
        CGColorSpaceRelease(srgb);
        return;
    }

    static CIContext* ctx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGColorSpaceRef ws = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        ctx = [CIContext contextWithOptions:@{
            kCIContextWorkingColorSpace: (__bridge id)ws,
            kCIContextOutputColorSpace:  (__bridge id)ws,
        }];
        CGColorSpaceRelease(ws);
    });

    // Downscale long-side to 1280px. Higher quality than the previous
    // 960px while still keeping JPEG payload reasonable on LAN.
    const CGFloat kTargetMaxDim = 1920.0;
    CGFloat w = ci.extent.size.width;
    CGFloat h = ci.extent.size.height;
    if (w > 0 && h > 0) {
        CGFloat scale = kTargetMaxDim / MAX(w, h);
        if (scale < 1.0) {
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        }
    }

    CGImageRef cgImage = [ctx createCGImage:ci
                                   fromRect:ci.extent
                                     format:kCIFormatRGBA8
                                 colorSpace:srgb];
    CGColorSpaceRelease(srgb);
    if (!cgImage) return;

    NSMutableData* jpeg = [NSMutableData data];
    CFStringRef utType =
#if defined(__has_builtin) && __has_builtin(__builtin_available)
        (__bridge CFStringRef)UTTypeJPEG.identifier;
#else
        CFSTR("public.jpeg");
#endif

    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)jpeg, utType, 1, nullptr);
    if (!dest) {
        CGImageRelease(cgImage);
        return;
    }

    // q=0.80 → big quality jump from 0.55 with ~2x payload (still fine
    // on LAN). Below 0.70 chroma artefacts visible on faces.
    NSDictionary* props = @{ (id)kCGImageDestinationLossyCompressionQuality: @0.85 };
    CGImageDestinationAddImage(dest, cgImage, (__bridge CFDictionaryRef)props);
    CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(cgImage);

    {
        std::lock_guard<std::mutex> g(impl->jpeg_mu);
        impl->latest.assign((const uint8_t*)jpeg.bytes,
                            (const uint8_t*)jpeg.bytes + jpeg.length);
    }
    impl->seq.fetch_add(1, std::memory_order_release);
    [self encodeVariants:nullptr pts:kCMTimeInvalid];
}

@end

// ----------------------------------------------------------------------------

namespace obs {

std::vector<uint8_t> jpeg_darken(const std::vector<uint8_t>& jpeg_in,
                                 float factor) {
    if (jpeg_in.empty() || factor >= 1.0f) return jpeg_in;  // no-op common case
    if (factor < 0.0f) factor = 0.0f;
    @autoreleasepool {
        NSData* inData = [NSData dataWithBytesNoCopy:(void*)jpeg_in.data()
                                              length:jpeg_in.size()
                                        freeWhenDone:NO];
        CGImageSourceRef src =
            CGImageSourceCreateWithData((__bridge CFDataRef)inData, nullptr);
        if (!src) return jpeg_in;
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
        CFRelease(src);
        if (!cg) return jpeg_in;

        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CIImage* ci = [CIImage imageWithCGImage:cg];
        CGImageRelease(cg);

        // Multiply RGB by factor (0 = black, 1 = unchanged); leave alpha.
        CIFilter* mtx = [CIFilter filterWithName:@"CIColorMatrix"];
        [mtx setValue:ci forKey:kCIInputImageKey];
        [mtx setValue:[CIVector vectorWithX:factor Y:0 Z:0 W:0] forKey:@"inputRVector"];
        [mtx setValue:[CIVector vectorWithX:0 Y:factor Z:0 W:0] forKey:@"inputGVector"];
        [mtx setValue:[CIVector vectorWithX:0 Y:0 Z:factor W:0] forKey:@"inputBVector"];
        [mtx setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:1] forKey:@"inputAVector"];
        [mtx setValue:[CIVector vectorWithX:0 Y:0 Z:0 W:0] forKey:@"inputBiasVector"];
        CIImage* out = mtx.outputImage;
        if (!out) { CGColorSpaceRelease(srgb); return jpeg_in; }

        static CIContext* dctx = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            CGColorSpaceRef ws = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            dctx = [CIContext contextWithOptions:@{
                kCIContextWorkingColorSpace: (__bridge id)ws,
                kCIContextOutputColorSpace:  (__bridge id)ws,
            }];
            CGColorSpaceRelease(ws);
        });

        CGImageRef outCg = [dctx createCGImage:out
                                      fromRect:ci.extent
                                        format:kCIFormatRGBA8
                                    colorSpace:srgb];
        CGColorSpaceRelease(srgb);
        if (!outCg) return jpeg_in;

        NSMutableData* outData = [NSMutableData data];
        CFStringRef utType =
#if defined(__has_builtin) && __has_builtin(__builtin_available)
            (__bridge CFStringRef)UTTypeJPEG.identifier;
#else
            CFSTR("public.jpeg");
#endif
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)outData, utType, 1, nullptr);
        if (!dest) { CGImageRelease(outCg); return jpeg_in; }
        NSDictionary* props =
            @{ (id)kCGImageDestinationLossyCompressionQuality: @0.85 };
        CGImageDestinationAddImage(dest, outCg, (__bridge CFDictionaryRef)props);
        bool ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        CGImageRelease(outCg);
        if (!ok) return jpeg_in;

        return std::vector<uint8_t>(
            (const uint8_t*)outData.bytes,
            (const uint8_t*)outData.bytes + outData.length);
    }
}

std::vector<uint8_t> jpeg_crossfade(const std::vector<uint8_t>& outgoing,
                                    const std::vector<uint8_t>& incoming,
                                    float factor) {
    // Dissolve outgoing -> incoming. factor 0 = outgoing, 1 = incoming.
    if (incoming.empty()) return incoming;
    if (outgoing.empty() || factor >= 1.0f) return incoming;  // nothing to blend
    if (factor < 0.0f) factor = 0.0f;
    @autoreleasepool {
        auto decode = [](const std::vector<uint8_t>& j) -> CIImage* {
            NSData* d = [NSData dataWithBytesNoCopy:(void*)j.data()
                                             length:j.size()
                                       freeWhenDone:NO];
            CGImageSourceRef s =
                CGImageSourceCreateWithData((__bridge CFDataRef)d, nullptr);
            if (!s) return nil;
            CGImageRef cg = CGImageSourceCreateImageAtIndex(s, 0, nullptr);
            CFRelease(s);
            if (!cg) return nil;
            CIImage* ci = [CIImage imageWithCGImage:cg];
            CGImageRelease(cg);
            return ci;
        };
        CIImage* a = decode(outgoing);
        CIImage* b = decode(incoming);
        if (!a || !b) return incoming;

        // Stretch the outgoing to the incoming's extent when they differ,
        // because a partial-coverage dissolve leaves transparency that JPEG
        // flattens to white. On the full program stream both are the
        // canonical size, but on a small preview stream (preview_params.h)
        // this is the normal path on every TAKE fade: the outgoing is the
        // frozen full-size frame and the incoming is the small variant. Both
        // are 16:9, so the stretch keeps the framing.
        if (!CGRectEqualToRect(a.extent, b.extent) && a.extent.size.width > 0 &&
            a.extent.size.height > 0) {
            a = [a imageByApplyingTransform:CGAffineTransformMakeScale(
                        b.extent.size.width / a.extent.size.width,
                        b.extent.size.height / a.extent.size.height)];
        }

        CIFilter* diss = [CIFilter filterWithName:@"CIDissolveTransition"];
        [diss setValue:a forKey:kCIInputImageKey];        // time 0 = outgoing
        [diss setValue:b forKey:kCIInputTargetImageKey];  // time 1 = incoming
        [diss setValue:@(factor) forKey:kCIInputTimeKey];
        CIImage* out = diss.outputImage;
        if (!out) return incoming;

        static CIContext* xctx = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            CGColorSpaceRef ws = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            xctx = [CIContext contextWithOptions:@{
                kCIContextWorkingColorSpace: (__bridge id)ws,
                kCIContextOutputColorSpace:  (__bridge id)ws,
            }];
            CGColorSpaceRelease(ws);
        });

        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        // Render at the incoming frame's extent (the destination size).
        CGImageRef outCg = [xctx createCGImage:out
                                      fromRect:b.extent
                                        format:kCIFormatRGBA8
                                    colorSpace:srgb];
        CGColorSpaceRelease(srgb);
        if (!outCg) return incoming;

        NSMutableData* outData = [NSMutableData data];
        CFStringRef utType =
#if defined(__has_builtin) && __has_builtin(__builtin_available)
            (__bridge CFStringRef)UTTypeJPEG.identifier;
#else
            CFSTR("public.jpeg");
#endif
        CGImageDestinationRef dest = CGImageDestinationCreateWithData(
            (__bridge CFMutableDataRef)outData, utType, 1, nullptr);
        if (!dest) { CGImageRelease(outCg); return incoming; }
        NSDictionary* props =
            @{ (id)kCGImageDestinationLossyCompressionQuality: @0.85 };
        CGImageDestinationAddImage(dest, outCg, (__bridge CFDictionaryRef)props);
        bool ok = CGImageDestinationFinalize(dest);
        CFRelease(dest);
        CGImageRelease(outCg);
        if (!ok) return incoming;

        return std::vector<uint8_t>(
            (const uint8_t*)outData.bytes,
            (const uint8_t*)outData.bytes + outData.length);
    }
}

// One process-lifetime discovery session. Its `devices` property tracks
// hotplug on its own, so every discover_devices() call sees the current set,
// and holding a live discovery session is also what makes AVFoundation post
// the WasConnected / WasDisconnected notifications observe_av_devices relies
// on even while zero capture sessions are running.
static AVCaptureDeviceDiscoverySession* discovery_session() {
    static AVCaptureDeviceDiscoverySession* disc = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(macOS 14.0, *)) {
            disc = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeExternal,
                                                   AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                      mediaType:AVMediaTypeVideo
                                       position:AVCaptureDevicePositionUnspecified];
        } else {
            disc = [AVCaptureDeviceDiscoverySession
                discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                      mediaType:AVMediaTypeVideo
                                       position:AVCaptureDevicePositionUnspecified];
        }
    });
    return disc;
}

static NSArray<AVCaptureDevice*>* discover_devices() {
    return discovery_session().devices;
}

void observe_av_devices(std::function<void(std::string, bool)> cb) {
    discovery_session();   // keep-alive that makes the notifications fire
    // Each block copies `fn`; both copies live as long as the observers (the
    // process). The observer tokens are deliberately dropped - this is a
    // register-once, process-lifetime watch, same as the libdev callback.
    std::function<void(std::string, bool)> fn = std::move(cb);
    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:AVCaptureDeviceWasConnectedNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* n) {
        AVCaptureDevice* d = (AVCaptureDevice*)n.object;
        // The same notifications fire for microphones; video only.
        if (d && [d hasMediaType:AVMediaTypeVideo])
            fn(std::string(d.uniqueID.UTF8String), true);
    }];
    [nc addObserverForName:AVCaptureDeviceWasDisconnectedNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification* n) {
        AVCaptureDevice* d = (AVCaptureDevice*)n.object;
        if (d && [d hasMediaType:AVMediaTypeVideo])
            fn(std::string(d.uniqueID.UTF8String), false);
    }];
}

std::vector<AvVideoDevice> list_av_devices() {
    std::vector<AvVideoDevice> out;
    for (AVCaptureDevice* d in discover_devices()) {
        AvVideoDevice v;
        v.unique_id = d.uniqueID.UTF8String;
        v.name = d.localizedName.UTF8String;
        NSString* lname = [d.localizedName lowercaseString];
        v.is_obsbot = [lname containsString:@"obsbot"];
        out.push_back(std::move(v));
    }
    return out;
}

static AVCaptureDevice* find_device(const std::string& substr) {
    NSString* needle = nil;
    if (!substr.empty()) {
        needle = [[NSString stringWithUTF8String:substr.c_str()] lowercaseString];
    }

    NSArray<AVCaptureDevice*>* devices = discover_devices();
    LOGI("video: %lu capture devices visible", (unsigned long)devices.count);
    for (AVCaptureDevice* d in devices) {
        LOGI("video: candidate '%s' (id=%s)",
             d.localizedName.UTF8String, d.uniqueID.UTF8String);
    }

    for (AVCaptureDevice* d in devices) {
        NSString* lname = [d.localizedName lowercaseString];
        if (needle && [lname containsString:needle]) return d;
        if (!needle && [lname containsString:@"obsbot"]) return d;
    }
    if (needle && devices.count > 0) {
        // fall back to first device if no match
        return devices.firstObject;
    }
    return nil;
}

// Ensure camera (TCC) permission. Prompts on first run; returns true only when
// authorized. Blocks until the prompt is answered.
static bool ensure_camera_permission() {
    AVAuthorizationStatus auth =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (auth == AVAuthorizationStatusAuthorized) return true;
    if (auth == AVAuthorizationStatusNotDetermined) {
        __block BOOL granted = NO;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL g) {
            granted = g;
            dispatch_semaphore_signal(sem);
        }];
        // Bounded: this runs on capture-start paths (hotplug thread, MJPEG
        // serving threads). An unanswered TCC prompt must degrade to
        // "preview unavailable", never wedge a thread forever - the v2
        // bring-up deadlocked exactly here with DISPATCH_TIME_FOREVER.
        if (dispatch_semaphore_wait(
                sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
            LOGW("video: camera permission prompt unanswered after 60s");
            return false;
        }
        if (!granted) { LOGW("video: camera permission denied"); return false; }
        return true;
    }
    LOGW("video: camera not authorized (status=%ld); enable in System Settings → Privacy & Security → Camera",
         (long)auth);
    return false;
}

VideoCapture::VideoCapture() : impl_(new Impl) {}
VideoCapture::~VideoCapture() { stop(); }

// Fire-and-forget: nudges the TCC prompt at startup WITHOUT blocking.
// Called from main() before the servers bind; the v2 refactor briefly
// made this synchronous (semaphore wait on the completion handler),
// which deadlocked the whole bridge when the status was NotDetermined -
// WS + MJPEG never bound, and the bridge UI that would have told the
// user "camera permission missing" needs that very WS to exist. The
// capture-start paths keep their own blocking ensure_camera_permission
// gate; by the time a client asks for frames the prompt has resolved.
void VideoCapture::request_camera_permission(
        std::function<void(bool)> on_result) {
    @autoreleasepool {
        AVAuthorizationStatus auth =
            [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (auth == AVAuthorizationStatusNotDetermined) {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL g) {
                LOGI("video: camera permission %s", g ? "granted" : "denied");
                if (on_result) on_result(g);
            }];
        }
    }
}

// Configure + start a capture session bound to `d`. Fills impl_ and flips
// running. Assumes permission is already granted and impl_->running is false.
bool VideoCapture::start_with_device(void* device_ptr) {
    AVCaptureDevice* d = (__bridge AVCaptureDevice*)device_ptr;
    impl_->device = d;
    LOGI("video: using device '%s' (id=%s)",
         d.localizedName.UTF8String, d.uniqueID.UTF8String);

    NSError* err = nil;
    impl_->input = [AVCaptureDeviceInput deviceInputWithDevice:d error:&err];
    if (!impl_->input) {
        LOGE("video: input error: %s", err.localizedDescription.UTF8String);
        return false;
    }

    impl_->session = [[AVCaptureSession alloc] init];
    // Tiny 2 Lite native is 1080p; capturing at 720p forces a firmware
    // downsample path that looks dimmer + less sharp than what OBSBOT
    // Center shows. Use 1080p and let our own downscale (1280px long
    // side) handle final preview size.
    if ([impl_->session canSetSessionPreset:AVCaptureSessionPreset1920x1080]) {
        impl_->session.sessionPreset = AVCaptureSessionPreset1920x1080;
    } else {
        impl_->session.sessionPreset = AVCaptureSessionPreset1280x720;
    }

    if (![impl_->session canAddInput:impl_->input]) {
        LOGE("video: cannot add input");
        return false;
    }
    [impl_->session addInput:impl_->input];

    impl_->output = [[AVCaptureVideoDataOutput alloc] init];
    impl_->output.alwaysDiscardsLateVideoFrames = YES;
    impl_->output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_32BGRA)
    };

    impl_->delegate = [[ObsCaptureDelegate alloc] init];
    impl_->delegate->impl = impl_.get();

    // Per-device serial queue so N simultaneous captures don't share one.
    std::string qname = std::string("com.obsbot.bridge.capture.") +
                        d.uniqueID.UTF8String;
    impl_->queue = dispatch_queue_create(qname.c_str(), DISPATCH_QUEUE_SERIAL);
    [impl_->output setSampleBufferDelegate:impl_->delegate queue:impl_->queue];

    if (![impl_->session canAddOutput:impl_->output]) {
        LOGE("video: cannot add output");
        return false;
    }
    [impl_->session addOutput:impl_->output];

    [impl_->session startRunning];
    impl_->running = impl_->session.isRunning;
    if (impl_->running) {
        LOGI("video: capture session started");
    } else {
        LOGW("video: session.isRunning is false");
    }
    return impl_->running;
}

bool VideoCapture::start(const std::string& name_substr) {
    @autoreleasepool {
        if (impl_->running) return true;
        // Permission wait can block up to 60s; do it before taking ctl_mu so a
        // concurrent start/stop is not stalled behind an unanswered prompt.
        if (!ensure_camera_permission()) return false;
        std::lock_guard<std::mutex> g(impl_->ctl_mu);
        if (impl_->running) return true;   // re-check under the lock
        AVCaptureDevice* d = find_device(name_substr);
        if (!d) { LOGW("video: no matching capture device"); return false; }
        return start_with_device((__bridge void*)d);
    }
}

bool VideoCapture::start_unique_id(const std::string& unique_id) {
    @autoreleasepool {
        if (impl_->running) return true;
        if (unique_id.empty()) return false;
        if (!ensure_camera_permission()) return false;
        std::lock_guard<std::mutex> g(impl_->ctl_mu);
        if (impl_->running) return true;   // re-check under the lock

        NSString* uid = [NSString stringWithUTF8String:unique_id.c_str()];
        // A camera can be visible to libdev slightly before AVFoundation
        // enumerates it, and (freshly woken) can lag a bit more. Retry for a
        // few seconds rather than failing the first attach.
        AVCaptureDevice* d = nil;
        for (int i = 0; i < 20 && !d; ++i) {
            d = [AVCaptureDevice deviceWithUniqueID:uid];
            if (!d) {
                // deviceWithUniqueID can miss external cams on some macOS
                // versions; fall back to scanning the discovery list.
                for (AVCaptureDevice* c in discover_devices()) {
                    if ([c.uniqueID isEqualToString:uid]) { d = c; break; }
                }
            }
            if (!d) [NSThread sleepForTimeInterval:0.15];
        }
        if (!d) {
            LOGW("video: no capture device with uniqueID=%s", unique_id.c_str());
            return false;
        }
        return start_with_device((__bridge void*)d);
    }
}

void VideoCapture::stop() {
    @autoreleasepool {
        if (!impl_) return;
        std::lock_guard<std::mutex> g(impl_->ctl_mu);
        if (impl_->session) {
            [impl_->session stopRunning];
            impl_->session = nil;
        }
        // Detach the delegate and drain its queue, so no frame callback still
        // runs when the delegate's dealloc releases its VideoToolbox objects.
        if (impl_->output) [impl_->output setSampleBufferDelegate:nil queue:nil];
        if (impl_->queue) dispatch_sync(impl_->queue, ^{});
        impl_->input = nil;
        impl_->output = nil;
        impl_->delegate = nil;
        impl_->queue = nullptr;
        impl_->device = nil;
        impl_->running = false;
    }
}

bool VideoCapture::running() const { return impl_ && impl_->running; }

std::vector<uint8_t> VideoCapture::latest_jpeg() const {
    if (!impl_) return {};
    std::lock_guard<std::mutex> g(impl_->jpeg_mu);
    return impl_->latest;
}

uint64_t VideoCapture::frame_seq() const {
    if (!impl_) return 0;
    return impl_->seq.load(std::memory_order_acquire);
}

void VideoCapture::claim_variant(const std::string& sn,
                                 const preview::VariantKey& k) {
    int clients = 0;
    {
        std::lock_guard<std::mutex> g(impl_->var_mu);
        clients = impl_->var_refs.claim(k);
        if (clients == 1) impl_->var_slots[k] = {};
    }
    if (clients == 1) {
        LOGI("preview: variant start sn=%s %dx%d q=%.2f clients=%d", sn.c_str(),
             k.w, preview::height_for(k.w), k.q_pct / 100.0, clients);
    }
}

void VideoCapture::release_variant(const std::string& sn,
                                   const preview::VariantKey& k) {
    int clients = 0;
    {
        std::lock_guard<std::mutex> g(impl_->var_mu);
        clients = impl_->var_refs.release(k);
        if (clients == 0) impl_->var_slots.erase(k);
    }
    if (clients == 0) {
        LOGI("preview: variant stop sn=%s %dx%d q=%.2f clients=%d", sn.c_str(),
             k.w, preview::height_for(k.w), k.q_pct / 100.0, clients);
    }
}

std::vector<uint8_t> VideoCapture::variant_jpeg(
        const preview::VariantKey& k) const {
    std::lock_guard<std::mutex> g(impl_->var_mu);
    auto it = impl_->var_slots.find(k);
    return it == impl_->var_slots.end() ? std::vector<uint8_t>{}
                                        : it->second.latest;
}

uint64_t VideoCapture::variant_seq(const preview::VariantKey& k) const {
    std::lock_guard<std::mutex> g(impl_->var_mu);
    auto it = impl_->var_slots.find(k);
    return it == impl_->var_slots.end() ? 0 : it->second.seq;
}

}  // namespace obs
