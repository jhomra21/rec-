#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

#include "rec/rec.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

namespace rec {
void receive_frame(void* owner, CMSampleBufferRef sample);
void receive_audio(void* owner, CMSampleBufferRef sample);
void receive_failure(void* owner, NSError* error);
}

@interface RecCaptureOutput : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, assign) void* owner;
@end

@implementation RecCaptureOutput
- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)buffer
       ofType:(SCStreamOutputType)type {
    (void)stream;
    if (!self.owner) return;
    if (type == SCStreamOutputTypeScreen) rec::receive_frame(self.owner, buffer);
    else if (type == SCStreamOutputTypeAudio) rec::receive_audio(self.owner, buffer);
}
- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    (void)stream;
    if (self.owner) rec::receive_failure(self.owner, error);
}
@end

namespace rec {
namespace {
std::string message(NSError* error, const char* fallback) {
    return error ? std::string(error.localizedDescription.UTF8String ?: fallback) : std::string(fallback);
}

SCShareableContent* shareable(std::string& error) {
    __block SCShareableContent* content = nil;
    __block NSError* reported = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent* found, NSError* e) {
        content = found;
        reported = e;
        dispatch_semaphore_signal(done);
    }];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) {
        error = "ScreenCaptureKit did not return shareable content in 10 seconds";
        return nil;
    }
    if (!content) error = message(reported, "ScreenCaptureKit could not list displays. Check Screen Recording permission.");
    return content;
}

struct Size { std::uint32_t width, height; };

Size output_size(Options options, SCDisplay* display) {
    auto mode = CGDisplayCopyDisplayMode(display.displayID);
    const std::uint32_t native_w = mode ? static_cast<std::uint32_t>(CGDisplayModeGetPixelWidth(mode)) : display.width;
    const std::uint32_t native_h = mode ? static_cast<std::uint32_t>(CGDisplayModeGetPixelHeight(mode)) : display.height;
    if (mode) CGDisplayModeRelease(mode);
    if (!options.width || !options.height) return {native_w & ~1u, native_h & ~1u};
    const double factor = std::min({1.0, static_cast<double>(options.width) / native_w,
                                    static_cast<double>(options.height) / native_h});
    return {std::max(2u, static_cast<std::uint32_t>(native_w * factor) & ~1u),
            std::max(2u, static_cast<std::uint32_t>(native_h * factor) & ~1u)};
}

Result wait_capture(SCStream* stream, bool start) {
    __block NSError* reported = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    void (^completion)(NSError*) = ^(NSError* error) {
        reported = error;
        dispatch_semaphore_signal(done);
    };
    if (start) [stream startCaptureWithCompletionHandler:completion];
    else [stream stopCaptureWithCompletionHandler:completion];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)))
        return {start ? "screen capture start timed out" : "screen capture stop timed out"};
    return reported ? Result{message(reported, "screen capture failed")} : Result{};
}
} // namespace

std::vector<Display> list_displays(std::string& error) {
    @autoreleasepool {
        error.clear();
        SCShareableContent* content = shareable(error);
        if (!content) return {};
        std::vector<Display> result;
        for (SCDisplay* display in content.displays) {
            auto size = output_size(Options{.width = 0, .height = 0}, display);
            result.push_back({display.displayID, size.width, size.height,
                              "Display " + std::to_string(display.displayID)});
        }
        return result;
    }
}

// One retained surface and one encoding thread. The SCK callback never waits for the encoder.
class CaptureState {
public:
    explicit CaptureState(Options options) : options_(std::move(options)) {}
    ~CaptureState() { stop(); }

    Result start() {
        @autoreleasepool {
            if (active_) return {"already recording"};
            if (options_.fps == 0 || options_.fps > 120) return {"invalid frame rate"};
            if (options_.test_tone && !options_.test_pattern) return {"test tone needs test pattern"};
            if (options_.system_audio && options_.test_pattern) return {"system audio requires a screen"};
            std::string error;
            if (options_.output.empty()) return {"output path is empty"};
            NSString* path = [NSString stringWithUTF8String:options_.output.c_str()];
            if (!path) return {"invalid output path"};
            if ([[NSFileManager defaultManager] fileExistsAtPath:path])
                return {"output file already exists: " + options_.output};
            if (!options_.test_pattern) {
            SCShareableContent* content = shareable(error);
            if (!content) return {error};
            if (options_.display > content.displays.count) return {"display index not found; run `rec devices`"};
            SCDisplay* display = content.displays[options_.display - 1];
            size_ = output_size(options_, display);
            if (!size_.width || !size_.height) return {"display has no usable pixel dimensions"};
            SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
            config.width = size_.width;
            config.height = size_.height;
            config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            config.minimumFrameInterval = CMTimeMake(9, static_cast<int32_t>(options_.fps * 10));
            config.queueDepth = 3;
            config.showsCursor = options_.cursor;
            config.capturesAudio = options_.system_audio;
            config.sampleRate = 48000;
            config.channelCount = 2;
            config.excludesCurrentProcessAudio = YES;
            config.scalesToFit = YES;
            config.preservesAspectRatio = YES;
            receiver_ = [[RecCaptureOutput alloc] init];
            receiver_.owner = this;
            queue_ = dispatch_queue_create("rec.capture.frames", DISPATCH_QUEUE_SERIAL);
            if (options_.system_audio)
                audio_dispatch_queue_ = dispatch_queue_create("rec.capture.audio", DISPATCH_QUEUE_SERIAL);
            stream_ = [[SCStream alloc] initWithFilter:filter configuration:config delegate:receiver_];
            NSError* streamError = nil;
            if (![stream_ addStreamOutput:receiver_ type:SCStreamOutputTypeScreen
                      sampleHandlerQueue:queue_ error:&streamError]) {
                error = message(streamError, "could not subscribe to screen frames");
                cleanup_capture();
                return {error};
            }
            if (options_.system_audio &&
                ![stream_ addStreamOutput:receiver_ type:SCStreamOutputTypeAudio
                      sampleHandlerQueue:audio_dispatch_queue_ error:&streamError]) {
                error = message(streamError, "could not subscribe to system audio");
                cleanup_capture();
                return {error};
            }
            auto started = wait_capture(stream_, true);
            if (!started) { cleanup_capture(); return started; }
            active_ = true;
            {
                std::unique_lock lock(mutex_);
                if (!frames_ready_.wait_for(lock, std::chrono::seconds(8), [this] {
                    return newest_ != nullptr || !failure_.empty();
                })) {
                    error = "no screen frames arrived within 8 seconds (check Screen Recording permission)";
                } else if (!failure_.empty()) {
                    error = failure_;
                }
            }
            if (!error.empty()) { stop(); return {error}; }
            } else {
                // Exercise the real VideoToolbox writer without TCC, display or compositor.
                size_ = {options_.width ? options_.width : 1920u,
                         options_.height ? options_.height : 1080u};
                size_.width &= ~1u;
                size_.height &= ~1u;
                if (size_.width < 2 || size_.height < 2) return {"invalid synthetic frame dimensions"};
                CVPixelBufferRef pixel = nullptr;
                NSDictionary* attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
                const CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                    size_.width, size_.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    (__bridge CFDictionaryRef)attributes, &pixel);
                if (result != kCVReturnSuccess || !pixel) return {"synthetic frame allocation failed"};
                CVPixelBufferLockBaseAddress(pixel, 0);
                for (size_t row = 0; row < CVPixelBufferGetHeightOfPlane(pixel, 0); ++row) {
                    auto* y = static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel, 0));
                    const auto stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0);
                    std::memset(y + row * stride, row % 24 < 12 ? 175 : 65,
                                CVPixelBufferGetWidthOfPlane(pixel, 0));
                }
                for (size_t row = 0; row < CVPixelBufferGetHeightOfPlane(pixel, 1); ++row) {
                    auto* uv = static_cast<std::uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel, 1));
                    const auto stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 1);
                    std::memset(uv + row * stride, 128,
                                CVPixelBufferGetWidthOfPlane(pixel, 1) * 2);
                }
                CVPixelBufferUnlockBaseAddress(pixel, 0);
                {
                    std::lock_guard lock(mutex_);
                    newest_ = pixel;
                    captured_.store(1);
                }
                active_.store(true);
            }
            auto ready = create_writer();
            if (!ready) { stop(); return ready; }
            activity_ = [[NSProcessInfo processInfo]
                beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                reason:@"Screen recording"];
            finished_.store(false);
            stop_requested_.store(false);
            host_origin_ = CMClockGetTime(CMClockGetHostTimeClock());
            pacer_ = std::thread([this] { run(); });
            return {};
        }
    }

    Result stop() {
        @autoreleasepool {
            if (pacer_.joinable()) { stop_requested_.store(true); pacer_.join(); }
            Result result;
            if (stream_) {
                if (active_) result = wait_capture(stream_, false);
                // Drain callbacks before clearing their unowned C++ pointer.
                if (queue_) dispatch_sync(queue_, ^{});
                if (audio_dispatch_queue_) dispatch_sync(audio_dispatch_queue_, ^{});
                cleanup_capture();
            }
            if (writer_) {
                if (writer_.status == AVAssetWriterStatusWriting) {
                    [input_ markAsFinished];
                    if (audio_input_) [audio_input_ markAsFinished];
                    dispatch_semaphore_t done = dispatch_semaphore_create(0);
                    [writer_ finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
                    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)))
                        result = {"timed out finalizing the recording"};
                }
                if (writer_.status == AVAssetWriterStatusFailed)
                    result = {message(writer_.error, "video writer failed")};
                adaptor_ = nil;
                audio_input_ = nil;
                input_ = nil;
                writer_ = nil;
            }
            if (activity_) { [[NSProcessInfo processInfo] endActivity:activity_]; activity_ = nil; }
            {
                std::lock_guard lock(mutex_);
                while (audio_count_) {
                    CFRelease(audio_packets_[audio_head_]);
                    audio_packets_[audio_head_] = nullptr;
                    audio_head_ = (audio_head_ + 1) % audio_packets_.size();
                    --audio_count_;
                }
            }
            {
                std::lock_guard lock(mutex_);
                if (newest_) { CVPixelBufferRelease(newest_); newest_ = nullptr; }
            }
            active_ = false;
            return result;
        }
    }

    void on_frame(CMSampleBufferRef sample) {
        if (!CMSampleBufferIsValid(sample)) return;
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
        if (attachments && CFArrayGetCount(attachments) > 0) {
            NSDictionary* info = (__bridge NSDictionary*)CFArrayGetValueAtIndex(attachments, 0);
            NSNumber* status = info[SCStreamFrameInfoStatus];
            if (status && status.integerValue != SCFrameStatusComplete) return;
        }
        CVPixelBufferRef pixel = (CVPixelBufferRef)CMSampleBufferGetImageBuffer(sample);
        if (!pixel) return;
        CVPixelBufferRetain(pixel);
        {
            std::lock_guard lock(mutex_);
            auto* old = newest_;
            newest_ = pixel;
            if (old) CVPixelBufferRelease(old);
            captured_.fetch_add(1, std::memory_order_relaxed);
        }
        frames_ready_.notify_one();
    }

    void on_audio(CMSampleBufferRef sample) {
        if (!CMSampleBufferIsValid(sample) || !CMSampleBufferDataIsReady(sample)) return;
        CFRetain(sample);
        std::lock_guard lock(mutex_);
        if (audio_count_ == audio_packets_.size()) {
            CFRelease(audio_packets_[audio_head_]);
            audio_packets_[audio_head_] = nullptr;
            audio_head_ = (audio_head_ + 1) % audio_packets_.size();
            --audio_count_;
            audio_dropped_.fetch_add(1, std::memory_order_relaxed);
        }
        audio_packets_[(audio_head_ + audio_count_) % audio_packets_.size()] = sample;
        ++audio_count_;
    }

    void on_failure(NSError* error) {
        {
            std::lock_guard lock(mutex_);
            failure_ = message(error, "screen capture stopped unexpectedly");
        }
        finished_.store(true);
        frames_ready_.notify_one();
    }

    bool running() const noexcept { return active_ && !finished_.load(); }
    bool finished() const noexcept { return finished_.load(); }
    Stats stats() const noexcept {
        return {captured_.load(), written_.load(), dropped_.load(),
                audio_written_.load(), audio_dropped_.load()};
    }
    std::string failure() const { std::lock_guard lock(mutex_); return failure_; }

private:
    Result create_writer() {
        NSString* path = [NSString stringWithUTF8String:options_.output.c_str()];
        NSURL* url = [NSURL fileURLWithPath:path];
        AVFileType type = [path.pathExtension.lowercaseString isEqualToString:@"mp4"]
            ? AVFileTypeMPEG4 : AVFileTypeQuickTimeMovie;
        NSError* error = nil;
        writer_ = [[AVAssetWriter alloc] initWithURL:url fileType:type error:&error];
        if (!writer_) return {message(error, "could not create output movie")};
        bool hevc = options_.codec == Codec::hevc ||
            (options_.codec == Codec::automatic && size_.height > 1080);
        const std::uint64_t bitrate = static_cast<std::uint64_t>(options_.bitrate_mbps ?
            options_.bitrate_mbps : (size_.height > 1440 ? 50 : size_.height > 1080 ? 30 : 20)) * 1000000;
        NSDictionary* settings = @{
            AVVideoCodecKey: hevc ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264,
            AVVideoWidthKey: @(size_.width), AVVideoHeightKey: @(size_.height),
            AVVideoCompressionPropertiesKey: @{
                AVVideoAverageBitRateKey: @(bitrate),
                AVVideoExpectedSourceFrameRateKey: @(options_.fps),
                AVVideoMaxKeyFrameIntervalKey: @(options_.fps * 2),
                AVVideoAllowFrameReorderingKey: @NO
            }
        };
        input_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
        input_.expectsMediaDataInRealTime = YES;
        if (![writer_ canAddInput:input_]) return {"video encoder cannot accept the selected settings"};
        [writer_ addInput:input_];
        if (options_.test_tone || options_.system_audio) {
            NSDictionary* audioSettings = @{
                AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                AVSampleRateKey: @48000,
                AVNumberOfChannelsKey: @2,
                AVEncoderBitRateKey: @192000
            };
            audio_input_ = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                           outputSettings:audioSettings];
            audio_input_.expectsMediaDataInRealTime = YES;
            if (![writer_ canAddInput:audio_input_]) return {"AAC writer cannot accept synthetic audio"};
            [writer_ addInput:audio_input_];
        }
        // No adaptor pool: SCK's IOSurface-backed pixel buffer goes to VideoToolbox unchanged.
        adaptor_ = [AVAssetWriterInputPixelBufferAdaptor
            assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input_ sourcePixelBufferAttributes:nil];
        if (![writer_ startWriting]) return {message(writer_.error, "video writer could not start")};
        [writer_ startSessionAtSourceTime:kCMTimeZero];
        return {};
    }

    void write_system_audio() {
        if (!audio_input_ || !options_.system_audio) return;
        // Drain on the recording thread. Never encode or block in the SCK callback.
        for (std::size_t packet = 0; packet < audio_packets_.size(); ++packet) {
            CMSampleBufferRef sample = nullptr;
            {
                std::lock_guard lock(mutex_);
                if (!audio_count_) break;
                sample = audio_packets_[audio_head_];
                audio_packets_[audio_head_] = nullptr;
                audio_head_ = (audio_head_ + 1) % audio_packets_.size();
                --audio_count_;
            }
            if (!sample) continue;
            const auto timestamp = CMSampleBufferGetPresentationTimeStamp(sample);
            if (!CMTIME_IS_VALID(timestamp) || CMTimeCompare(timestamp, host_origin_) < 0) {
                audio_dropped_.fetch_add(1);
                CFRelease(sample);
                continue;
            }

            CMItemCount entries = 0;
            auto status = CMSampleBufferGetSampleTimingInfoArray(sample, 0, nullptr, &entries);
            std::array<CMSampleTimingInfo, 8> timing{};
            if (status != noErr || entries < 1 ||
                entries > static_cast<CMItemCount>(timing.size())) {
                audio_dropped_.fetch_add(1);
                CFRelease(sample);
                continue;
            }
            status = CMSampleBufferGetSampleTimingInfoArray(sample, entries, timing.data(), &entries);
            if (status != noErr) {
                audio_dropped_.fetch_add(1);
                CFRelease(sample);
                continue;
            }
            for (CMItemCount i = 0; i < entries; ++i) {
                if (CMTIME_IS_VALID(timing[i].presentationTimeStamp))
                    timing[i].presentationTimeStamp =
                        CMTimeSubtract(timing[i].presentationTimeStamp, host_origin_);
                if (CMTIME_IS_VALID(timing[i].decodeTimeStamp))
                    timing[i].decodeTimeStamp =
                        CMTimeSubtract(timing[i].decodeTimeStamp, host_origin_);
            }

            CMSampleBufferRef adjusted = nullptr;
            status = CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample,
                                                            entries, timing.data(), &adjusted);
            CFRelease(sample);
            if (status != noErr || !adjusted) {
                audio_dropped_.fetch_add(1);
                continue;
            }
            if (audio_input_.readyForMoreMediaData &&
                [audio_input_ appendSampleBuffer:adjusted]) {
                audio_written_.fetch_add(1);
            } else {
                audio_dropped_.fetch_add(1);
                if (writer_.status == AVAssetWriterStatusFailed) {
                    std::lock_guard lock(mutex_);
                    failure_ = message(writer_.error, "system audio encoding failed");
                    finished_.store(true);
                }
            }
            CFRelease(adjusted);
        }
    }

    bool write_test_tone(std::uint64_t sample_limit) {
        if (!audio_input_) return true;
        AudioStreamBasicDescription format{};
        format.mSampleRate = 48000;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        format.mBytesPerPacket = 4;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = 4;
        format.mChannelsPerFrame = 2;
        format.mBitsPerChannel = 16;

        CMAudioFormatDescriptionRef description = nullptr;
        if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &format, 0, nullptr, 0,
                                            nullptr, nullptr, &description) != noErr)
            return false;

        bool ok = true;
        while (audio_samples_ < sample_limit && !stop_requested_.load() && !finished_.load()) {
            const auto count = static_cast<std::uint32_t>(
                std::min<std::uint64_t>(1024, sample_limit - audio_samples_));
            std::vector<std::int16_t> samples(count * 2);
            for (std::uint32_t i = 0; i < count; ++i) {
                const auto index = audio_samples_ + i;
                // A short 440 Hz beep at the start of every second.
                const double phase = 2.0 * 3.141592653589793 * 440.0 * (index % 48000) / 48000.0;
                const auto value = static_cast<std::int16_t>((index % 48000 < 4800)
                    ? std::sin(phase) * 8000.0 : 0.0);
                samples[i * 2] = value;
                samples[i * 2 + 1] = value;
            }
            CMBlockBufferRef block = nullptr;
            const auto bytes = samples.size() * sizeof(std::int16_t);
            if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, bytes,
                kCFAllocatorDefault, nullptr, 0, bytes, 0, &block) != kCMBlockBufferNoErr) {
                ok = false; break;
            }
            if (CMBlockBufferReplaceDataBytes(samples.data(), block, 0, bytes) != kCMBlockBufferNoErr) {
                CFRelease(block); ok = false; break;
            }
            CMSampleTimingInfo timing{CMTimeMake(1, 48000),
                                      CMTimeMake(static_cast<std::int64_t>(audio_samples_), 48000),
                                      kCMTimeInvalid};
            CMSampleBufferRef sample = nullptr;
            const auto status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, description,
                                                          count, 1, &timing, 0, nullptr, &sample);
            CFRelease(block);
            if (status != noErr || !sample) { ok = false; break; }
            const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
            while (!audio_input_.readyForMoreMediaData && !stop_requested_.load() &&
                   std::chrono::steady_clock::now() < deadline)
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            if (!audio_input_.readyForMoreMediaData || ![audio_input_ appendSampleBuffer:sample]) {
                ok = false;
            } else {
                audio_samples_ += count;
            }
            CFRelease(sample);
            if (!ok) break;
        }
        CFRelease(description);
        return ok;
    }

    void run() {
        using namespace std::chrono;
        const auto begin = steady_clock::now();
        const auto limit = options_.duration_seconds > 0
            ? static_cast<std::uint64_t>(std::llround(options_.duration_seconds * options_.fps)) : UINT64_MAX;
        for (std::uint64_t slot = 0; slot < limit && !stop_requested_.load() && !finished_; ++slot) {
            const auto tick = begin + nanoseconds(slot * 1000000000ull / options_.fps);
            std::this_thread::sleep_until(tick);
            if (stop_requested_.load() || finished_) break;
            @autoreleasepool {
                CVPixelBufferRef frame = nullptr;
                {
                    std::lock_guard lock(mutex_);
                    frame = newest_;
                    if (frame) CVPixelBufferRetain(frame);
                }
                // Retry the same timestamp for up to 500 ms on transient backpressure.
                // Never hold a stream callback or create an unbounded frame queue.
                bool appended = false;
                const auto deadline = tick + milliseconds(500);
                while (frame && !stop_requested_.load() && !finished_.load() &&
                       steady_clock::now() < deadline && writer_.status != AVAssetWriterStatusFailed) {
                    if (input_.readyForMoreMediaData &&
                        [adaptor_ appendPixelBuffer:frame withPresentationTime:
                            CMTimeMake(static_cast<int64_t>(slot), static_cast<int32_t>(options_.fps))]) {
                        appended = true;
                        break;
                    }
                    std::this_thread::sleep_for(milliseconds(2));
                }
                if (appended) {
                    written_.fetch_add(1);
                    const auto target = ((slot + 1) * 48000ull) / options_.fps;
                    if (options_.test_tone && !write_test_tone(target)) {
                        std::lock_guard lock(mutex_);
                        failure_ = message(writer_.error, "synthetic AAC append failed");
                        finished_.store(true);
                    }
                } else if (!stop_requested_.load()) dropped_.fetch_add(1);
                if (writer_.status == AVAssetWriterStatusFailed) {
                    std::lock_guard lock(mutex_);
                    failure_ = message(writer_.error, "video encoding failed");
                    finished_.store(true);
                }
                if (frame) CVPixelBufferRelease(frame);
                write_system_audio();
            }
        }
        if (!stop_requested_.load()) write_system_audio();
        finished_.store(true);
    }

    void cleanup_capture() {
        if (receiver_) receiver_.owner = nullptr;
        receiver_ = nil;
        stream_ = nil;
        queue_ = nil;
        audio_dispatch_queue_ = nil;
    }

    Options options_;
    Size size_{};
    mutable std::mutex mutex_;
    std::condition_variable frames_ready_;
    CVPixelBufferRef newest_ = nullptr;
    std::string failure_;
    SCStream* __strong stream_ = nil;
    RecCaptureOutput* __strong receiver_ = nil;
    dispatch_queue_t queue_ = nullptr;
    dispatch_queue_t audio_dispatch_queue_ = nullptr;
    std::array<CMSampleBufferRef, 16> audio_packets_{};
    std::size_t audio_head_ = 0;
    std::size_t audio_count_ = 0;
    CMTime host_origin_ = kCMTimeInvalid;
    AVAssetWriter* __strong writer_ = nil;
    AVAssetWriterInput* __strong input_ = nil;
    AVAssetWriterInput* __strong audio_input_ = nil;
    std::uint64_t audio_samples_ = 0;
    AVAssetWriterInputPixelBufferAdaptor* __strong adaptor_ = nil;
    id __strong activity_ = nil;
    std::thread pacer_;
    std::atomic_bool stop_requested_{false};
    std::atomic_bool active_{false};
    std::atomic_bool finished_{false};
    std::atomic<std::uint64_t> captured_{0}, written_{0}, dropped_{0};
    std::atomic<std::uint64_t> audio_written_{0}, audio_dropped_{0};
};

Result probe_file(const std::string& path, Probe& probe) {
    @autoreleasepool {
        probe = {};
        NSString* name = [NSString stringWithUTF8String:path.c_str()];
        if (!name) return {"invalid recording path"};
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:name] options:nil];
        AVAssetTrack* track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        if (!track) return {"no video track"};
        const CGSize size = track.naturalSize;
        probe.width = static_cast<std::uint32_t>(std::abs(size.width));
        probe.height = static_cast<std::uint32_t>(std::abs(size.height));
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        const auto codec = format ? CMFormatDescriptionGetMediaSubType(format) : 0;
        probe.codec = codec == kCMVideoCodecType_H264 ? "h264" :
                      codec == kCMVideoCodecType_HEVC ? "hevc" : "other";
        NSError* error = nil;
        AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) return {message(error, "could not open movie")};
        AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track
            outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        if (![reader canAddOutput:output]) return {"could not decode video"};
        [reader addOutput:output];
        if (![reader startReading]) return {message(reader.error, "video decode start failed")};
        CMTime previous = kCMTimeInvalid;
        while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
            const CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sample);
            if (CMTIME_IS_VALID(previous) && CMTimeCompare(timestamp, previous) <= 0) {
                CFRelease(sample);
                [reader cancelReading];
                return {"video timestamps are not strictly increasing"};
            }
            previous = timestamp;
            ++probe.frames;
            CFRelease(sample);
        }
        if (reader.status != AVAssetReaderStatusCompleted)
            return {message(reader.error, "video decode failed")};
        if (!probe.frames) return {"no decoded frames"};
        probe.duration_seconds = CMTimeGetSeconds(track.timeRange.duration);
        AVAssetTrack* audio = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        if (audio) {
            CMFormatDescriptionRef audioFormat =
                (__bridge CMFormatDescriptionRef)audio.formatDescriptions.firstObject;
            const auto subtype = audioFormat ? CMFormatDescriptionGetMediaSubType(audioFormat) : 0;
            probe.audio_codec = subtype == kAudioFormatMPEG4AAC ? "aac" : "other";
            probe.audio_duration_seconds = CMTimeGetSeconds(audio.timeRange.duration);
            NSError* audioError = nil;
            AVAssetReader* audioReader = [[AVAssetReader alloc] initWithAsset:asset error:&audioError];
            if (!audioReader) return {message(audioError, "could not open audio track")};
            AVAssetReaderTrackOutput* audioOutput = [[AVAssetReaderTrackOutput alloc]
                initWithTrack:audio outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
            if (![audioReader canAddOutput:audioOutput]) return {"could not decode audio"};
            [audioReader addOutput:audioOutput];
            if (![audioReader startReading]) return {message(audioReader.error, "audio decode start failed")};
            while (CMSampleBufferRef buffer = [audioOutput copyNextSampleBuffer]) {
                ++probe.audio_buffers;
                CFRelease(buffer);
            }
            if (audioReader.status != AVAssetReaderStatusCompleted)
                return {message(audioReader.error, "audio decode failed")};
            if (!probe.audio_buffers) return {"audio track has no decoded samples"};
        }
        return {};
    }
}

void receive_frame(void* owner, CMSampleBufferRef sample) {
    static_cast<CaptureState*>(owner)->on_frame(sample);
}
void receive_audio(void* owner, CMSampleBufferRef sample) {
    static_cast<CaptureState*>(owner)->on_audio(sample);
}
void receive_failure(void* owner, NSError* error) {
    static_cast<CaptureState*>(owner)->on_failure(error);
}

class Recorder::Impl {
public:
    explicit Impl(Options options) : capture(std::move(options)) {}
    CaptureState capture;
};
Recorder::Recorder(Options options) : impl_(std::make_unique<Impl>(std::move(options))) {}
Recorder::~Recorder() = default;
Result Recorder::start() { return impl_->capture.start(); }
Result Recorder::stop() { return impl_->capture.stop(); }
bool Recorder::running() const noexcept { return impl_->capture.running(); }
bool Recorder::finished() const noexcept { return impl_->capture.finished(); }
Stats Recorder::stats() const noexcept { return impl_->capture.stats(); }
std::string Recorder::failure() const { return impl_->capture.failure(); }

} // namespace rec
