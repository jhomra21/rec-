#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace rec::core {

using Bytes = std::vector<std::uint8_t>;

// FLV tag bodies carried by RTMP audio (8) and video (9) messages.
namespace flv {
// One encoded H.264 access unit in Annex-B form, converted to length-prefixed NAL units.
// SPS, PPS and access-unit delimiters are removed from the body and returned separately.
struct AccessUnit {
    Bytes body;  // Complete FLV video tag body (frame type, AVC packet type 1, NAL units).
    Bytes sps, pps;
    bool key = false;
};
bool avc_frame(const std::uint8_t* data, std::size_t size, AccessUnit& out);
Bytes avc_sequence_header(const Bytes& sps, const Bytes& pps);
// Splits Annex-B parameter sets, e.g. MF_MT_MPEG_SEQUENCE_HEADER.
void parameter_sets(const std::uint8_t* data, std::size_t size, Bytes& sps, Bytes& pps);
Bytes aac_sequence_header(std::uint32_t rate, std::uint32_t channels);
Bytes aac_frame(const std::uint8_t* data, std::size_t size);
} // namespace flv

struct StreamInfo {
    std::uint32_t width = 0, height = 0, fps = 0;
    std::uint32_t video_kbps = 0, audio_kbps = 0;
    std::uint32_t audio_rate = 48000, audio_channels = 2;
};

// Publishes one live stream to an rtmp:// URL. open() blocks while it connects; after that
// video() and audio() only queue, and a sender thread owns the socket. The queue holds
// about three seconds of media. When the network falls behind, new video is dropped until
// the next keyframe so the stream recovers cleanly; sequence headers are never dropped.
class RtmpPublisher {
public:
    RtmpPublisher();
    ~RtmpPublisher();
    RtmpPublisher(const RtmpPublisher&) = delete;
    RtmpPublisher& operator=(const RtmpPublisher&) = delete;

    std::string open(const std::string& url, const StreamInfo& info);  // Empty on success.
    // False when the message was not queued: not live, or dropped to keep up.
    bool video(std::uint32_t ms, bool key, bool header, Bytes body);
    bool audio(std::uint32_t ms, bool header, Bytes body);
    // Sends what is queued for at most flush_ms, ends the stream, and disconnects.
    void close(int flush_ms);

    bool live() const noexcept { return live_.load(); }
    std::uint64_t bytes() const noexcept { return bytes_.load(); }
    std::uint64_t dropped_frames() const noexcept { return dropped_.load(); }
    std::string failure() const;
    // The URL without its stream key, safe to print.
    static std::string redact(const std::string& url);

private:
    struct Packet {
        std::uint8_t type = 0;
        std::uint32_t ms = 0;
        Bytes body;
    };
    struct Incoming {
        std::uint32_t timestamp = 0, delta = 0, length = 0, stream = 0;
        std::uint8_t type = 0;
        bool extended = false;
        Bytes payload;
    };
    struct Message {
        std::uint8_t type = 0;
        Bytes data;
    };
    struct Command {
        std::string name;
        double transaction = 0;
        std::vector<double> numbers;  // Number arguments after the transaction ID, in order.
        std::map<std::string, std::string> info;  // String fields of object arguments.
    };

    bool push(std::uint8_t type, std::uint32_t ms, bool header, bool key, Bytes body);
    void run();
    bool send_all(const std::uint8_t* data, std::size_t size);
    bool read_exact(std::uint8_t* data, std::size_t size);
    bool write_message(std::uint32_t csid, std::uint8_t type, std::uint32_t stream, std::uint32_t ms, const Bytes& body);
    bool read_message(Message& out);
    bool handle_control(const Message& message);
    // Waits for the _result or _error of a transaction, or with status set, the next onStatus.
    bool await_command(double transaction, bool status, Command& out, std::string& error);
    void fail(std::string text);

    std::intptr_t socket_ = -1;
    bool winsock_ = false;
    std::uint32_t chunk_in_ = 128, chunk_out_ = 128;
    std::uint32_t window_ = 0;
    std::uint64_t received_ = 0, acknowledged_ = 0;
    std::uint32_t stream_id_ = 0;
    std::string key_;
    std::map<std::uint32_t, Incoming> incoming_;
    Bytes out_;

    mutable std::mutex mutex_;
    std::condition_variable wake_;
    std::deque<Packet> queue_;
    std::size_t queued_bytes_ = 0, max_bytes_ = 0;
    bool need_key_ = false;
    bool closing_ = false;
    bool sender_done_ = false;
    std::int64_t flush_deadline_ms_ = 0;
    std::string failure_;
    std::thread sender_;
    std::atomic_bool live_{false};
    std::atomic<std::uint64_t> bytes_{0}, dropped_{0};
};

} // namespace rec::core
