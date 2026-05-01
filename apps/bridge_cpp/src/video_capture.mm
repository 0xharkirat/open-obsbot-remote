#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "video_capture.h"
#include "log.h"

#include <atomic>

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

    bool running = false;
};

}  // namespace obs

// ----------------------------------------------------------------------------

@interface ObsCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
@public
    obs::VideoCapture::Impl* impl;
}
@end

@implementation ObsCaptureDelegate

- (void)captureOutput:(AVCaptureOutput*)output
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection*)connection {
    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    CIImage* ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (!ci) return;

    static CIContext* ctx = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ctx = [CIContext contextWithOptions:nil];
    });

    // Downscale long-side to 960px so the JPEG fits in <120 KB at q=0.40.
    // This is plenty for "where is the camera pointed" preview on a phone.
    const CGFloat kTargetMaxDim = 960.0;
    CGFloat w = ci.extent.size.width;
    CGFloat h = ci.extent.size.height;
    if (w > 0 && h > 0) {
        CGFloat scale = kTargetMaxDim / MAX(w, h);
        if (scale < 1.0) {
            ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        }
    }

    CGImageRef cgImage = [ctx createCGImage:ci fromRect:ci.extent];
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

    NSDictionary* props = @{ (id)kCGImageDestinationLossyCompressionQuality: @0.40 };
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
}

@end

// ----------------------------------------------------------------------------

namespace obs {

static AVCaptureDevice* find_device(const std::string& substr) {
    NSString* needle = nil;
    if (!substr.empty()) {
        needle = [[NSString stringWithUTF8String:substr.c_str()] lowercaseString];
    }

    AVCaptureDeviceDiscoverySession* disc = nil;
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

    NSArray<AVCaptureDevice*>* devices = disc.devices;
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

VideoCapture::VideoCapture() : impl_(new Impl) {}
VideoCapture::~VideoCapture() { stop(); }

bool VideoCapture::start(const std::string& name_substr) {
    @autoreleasepool {
        if (impl_->running) return true;

        // Request authorization (will prompt the user the first time)
        AVAuthorizationStatus auth = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (auth == AVAuthorizationStatusNotDetermined) {
            __block BOOL granted = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL g) {
                granted = g;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (!granted) {
                LOGW("video: camera permission denied");
                return false;
            }
        } else if (auth != AVAuthorizationStatusAuthorized) {
            LOGW("video: camera not authorized (status=%ld); enable in System Settings → Privacy & Security → Camera", (long)auth);
            return false;
        }

        AVCaptureDevice* d = find_device(name_substr);
        if (!d) { LOGW("video: no matching capture device"); return false; }
        impl_->device = d;
        LOGI("video: using device '%s'", d.localizedName.UTF8String);

        NSError* err = nil;
        impl_->input = [AVCaptureDeviceInput deviceInputWithDevice:d error:&err];
        if (!impl_->input) {
            LOGE("video: input error: %s", err.localizedDescription.UTF8String);
            return false;
        }

        impl_->session = [[AVCaptureSession alloc] init];
        impl_->session.sessionPreset = AVCaptureSessionPreset1280x720;

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

        impl_->queue = dispatch_queue_create("com.obsbot.bridge.capture",
                                             DISPATCH_QUEUE_SERIAL);
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
}

void VideoCapture::stop() {
    @autoreleasepool {
        if (!impl_) return;
        if (impl_->session) {
            [impl_->session stopRunning];
            impl_->session = nil;
        }
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

}  // namespace obs
