#include "core/rtmp.hpp"

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <cerrno>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <random>
#include <string_view>

namespace rec::core {
namespace {
#ifdef _WIN32
using Socket = SOCKET;
const Socket kNoSocket = INVALID_SOCKET;
void close_socket(Socket s) { closesocket(s); }
#else
using Socket = int;
const Socket kNoSocket = -1;
void close_socket(Socket s) { ::close(s); }
#endif

constexpr std::uint32_t kChunkSize = 4096;
constexpr int kTimeoutMs = 10000;
// Chunk streams: 2 protocol control, 3 connection commands, 4 audio, 6 video, 8 stream commands and data.
constexpr std::uint32_t kControl = 2, kCommands = 3, kAudio = 4, kVideo = 6, kStreamData = 8;

std::int64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

void put16(Bytes& b, std::uint32_t v) { b.push_back(std::uint8_t(v >> 8)); b.push_back(std::uint8_t(v)); }
void put24(Bytes& b, std::uint32_t v) { b.push_back(std::uint8_t(v >> 16)); put16(b, v); }
void put32(Bytes& b, std::uint32_t v) { b.push_back(std::uint8_t(v >> 24)); put24(b, v); }
std::uint32_t get16(const std::uint8_t* p) { return std::uint32_t(p[0]) << 8 | p[1]; }
std::uint32_t get24(const std::uint8_t* p) { return std::uint32_t(p[0]) << 16 | get16(p + 1); }
std::uint32_t get32(const std::uint8_t* p) { return std::uint32_t(p[0]) << 24 | get24(p + 1); }

// AMF0, the encoding of RTMP commands and metadata.
void amf_key(Bytes& b, std::string_view s) {
    put16(b, static_cast<std::uint32_t>(s.size()));
    b.insert(b.end(), s.begin(), s.end());
}
void amf_number(Bytes& b, double v) {
    b.push_back(0);
    std::uint64_t bits = 0;
    std::memcpy(&bits, &v, 8);
    for (int i = 7; i >= 0; --i) b.push_back(std::uint8_t(bits >> (i * 8)));
}
void amf_string(Bytes& b, std::string_view s) { b.push_back(2); amf_key(b, s); }
void amf_bool(Bytes& b, bool v) { b.push_back(1); b.push_back(v ? 1 : 0); }
void amf_null(Bytes& b) { b.push_back(5); }
void amf_end(Bytes& b) { b.push_back(0); b.push_back(0); b.push_back(9); }

struct AmfReader {
    const std::uint8_t* p;
    const std::uint8_t* end;
    bool need(std::size_t n) const { return static_cast<std::size_t>(end - p) >= n; }
};

// Reads one AMF0 value. Numbers land in number, strings in text; string fields of objects
// go to fields when given.
bool amf_read(AmfReader& r, int& kind, double& number, std::string& text,
              std::map<std::string, std::string>* fields, int depth) {
    if (depth > 8 || !r.need(1)) return false;
    kind = *r.p++;
    switch (kind) {
    case 0: {
        if (!r.need(8)) return false;
        std::uint64_t bits = 0;
        for (int i = 0; i < 8; ++i) bits = bits << 8 | r.p[i];
        std::memcpy(&number, &bits, 8);
        r.p += 8;
        return true;
    }
    case 1:
        if (!r.need(1)) return false;
        number = *r.p++;
        return true;
    case 2:
    case 12: {
        const std::size_t size = kind == 2 ? 2 : 4;
        if (!r.need(size)) return false;
        const std::size_t length = kind == 2 ? get16(r.p) : get32(r.p);
        r.p += size;
        if (!r.need(length)) return false;
        text.assign(reinterpret_cast<const char*>(r.p), length);
        r.p += length;
        kind = 2;
        return true;
    }
    case 5:
    case 6:
        return true;
    case 3:
    case 8: {
        if (kind == 8) {
            if (!r.need(4)) return false;
            r.p += 4;
        }
        for (;;) {
            if (!r.need(2)) return false;
            const std::size_t length = get16(r.p);
            r.p += 2;
            if (length == 0 && r.need(1) && *r.p == 9) { ++r.p; return true; }
            if (!r.need(length)) return false;
            std::string key(reinterpret_cast<const char*>(r.p), length);
            r.p += length;
            int field_kind = 0;
            double field_number = 0;
            std::string field_text;
            if (!amf_read(r, field_kind, field_number, field_text, nullptr, depth + 1)) return false;
            if (fields && field_kind == 2) (*fields)[key] = field_text;
        }
    }
    case 10: {
        if (!r.need(4)) return false;
        const auto count = get32(r.p);
        r.p += 4;
        for (std::uint32_t i = 0; i < count; ++i) {
            int item_kind = 0;
            double item_number = 0;
            std::string item_text;
            if (!amf_read(r, item_kind, item_number, item_text, nullptr, depth + 1)) return false;
        }
        return true;
    }
    case 11:
        if (!r.need(10)) return false;
        r.p += 10;
        return true;
    default:
        return false;
    }
}

struct Target {
    std::string host, port = "1935", authority, app, key;
};

constexpr const char* kShape = "stream URL must look like rtmp://host[:port]/app/stream-key";

std::string parse_url(const std::string& url, Target& t) {
    const std::string scheme = "rtmp://";
    if (url.rfind("rtmps://", 0) == 0) return "RTMPS is not supported yet; use an rtmp:// URL";
    if (url.rfind(scheme, 0) != 0) return "stream URL must start with rtmp://";
    const auto rest = url.substr(scheme.size());
    const auto slash = rest.find('/');
    if (slash == std::string::npos || slash == 0) return kShape;
    t.authority = rest.substr(0, slash);
    const auto path = rest.substr(slash + 1);
    const auto last = path.rfind('/');
    if (last == std::string::npos || last == 0 || last + 1 >= path.size()) return kShape;
    t.app = path.substr(0, last);
    t.key = path.substr(last + 1);
    std::string port;
    if (t.authority[0] == '[') {
        const auto close = t.authority.find(']');
        if (close == std::string::npos) return kShape;
        t.host = t.authority.substr(1, close - 1);
        if (close + 1 < t.authority.size()) {
            if (t.authority[close + 1] != ':') return kShape;
            port = t.authority.substr(close + 2);
        }
    } else {
        const auto colon = t.authority.rfind(':');
        t.host = t.authority.substr(0, colon);
        if (colon != std::string::npos) port = t.authority.substr(colon + 1);
    }
    if (!port.empty()) {
        if (port.size() > 5 || !std::all_of(port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; }))
            return kShape;
        t.port = port;
    }
    if (t.host.empty()) return kShape;
    return {};
}

bool connect_within(Socket s, const sockaddr* address, int length, int timeout_ms) {
#ifdef _WIN32
    u_long blocking = 1;
    ioctlsocket(s, FIONBIO, &blocking);
    if (::connect(s, address, length) != 0) {
        if (WSAGetLastError() != WSAEWOULDBLOCK) return false;
        fd_set writable, failed;
        FD_ZERO(&writable);
        FD_ZERO(&failed);
        FD_SET(s, &writable);
        FD_SET(s, &failed);
        timeval wait{timeout_ms / 1000, (timeout_ms % 1000) * 1000};
        if (select(0, nullptr, &writable, &failed, &wait) <= 0 || FD_ISSET(s, &failed)) return false;
    }
    int error = 0;
    int size = sizeof error;
    if (getsockopt(s, SOL_SOCKET, SO_ERROR, reinterpret_cast<char*>(&error), &size) != 0 || error) return false;
    blocking = 0;
    ioctlsocket(s, FIONBIO, &blocking);
#else
    const int flags = fcntl(s, F_GETFL, 0);
    fcntl(s, F_SETFL, flags | O_NONBLOCK);
    if (::connect(s, address, static_cast<socklen_t>(length)) != 0) {
        if (errno != EINPROGRESS) return false;
        pollfd wait{s, POLLOUT, 0};
        if (poll(&wait, 1, timeout_ms) <= 0) return false;
    }
    int error = 0;
    socklen_t size = sizeof error;
    if (getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error) return false;
    fcntl(s, F_SETFL, flags);
#endif
    return true;
}

void configure(Socket s) {
    int one = 1;
    setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&one), sizeof one);
#ifdef _WIN32
    const DWORD timeout = kTimeoutMs;
#else
    const timeval timeout{kTimeoutMs / 1000, 0};
#ifdef SO_NOSIGPIPE
    setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
#endif
    setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<const char*>(&timeout), sizeof timeout);
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<const char*>(&timeout), sizeof timeout);
}

bool readable(Socket s) {
#ifdef _WIN32
    fd_set set;
    FD_ZERO(&set);
    FD_SET(s, &set);
    timeval none{0, 0};
    return select(0, &set, nullptr, nullptr, &none) > 0;
#else
    pollfd wait{s, POLLIN, 0};
    return poll(&wait, 1, 0) > 0;
#endif
}

bool parse_command(const Bytes& data, std::string& name, double& transaction, std::vector<double>& numbers,
                   std::map<std::string, std::string>& info) {
    AmfReader r{data.data(), data.data() + data.size()};
    int kind = 0;
    double number = 0;
    std::string text;
    if (!amf_read(r, kind, number, name, nullptr, 0) || kind != 2) return false;
    if (!amf_read(r, kind, transaction, text, nullptr, 0) || kind != 0) return false;
    while (r.p < r.end) {
        text.clear();
        if (!amf_read(r, kind, number, text, &info, 0)) break;
        if (kind == 0) numbers.push_back(number);
    }
    return true;
}

// Annex-B NAL units without start codes or trailing zero bytes.
template <class Visit>
bool each_nal(const std::uint8_t* d, std::size_t n, Visit&& visit) {
    const auto code = [&](std::size_t at) -> std::size_t {
        if (at + 3 <= n && d[at] == 0 && d[at + 1] == 0 && d[at + 2] == 1) return 3;
        if (at + 4 <= n && d[at] == 0 && d[at + 1] == 0 && d[at + 2] == 0 && d[at + 3] == 1) return 4;
        return 0;
    };
    bool found = false;
    std::size_t start = 0;
    const auto emit = [&](std::size_t from, std::size_t to) {
        while (to > from && d[to - 1] == 0) --to;
        if (to > from) visit(d + from, to - from);
    };
    for (std::size_t i = 0; i < n;) {
        if (const auto length = code(i)) {
            if (found) emit(start, i);
            found = true;
            i += length;
            start = i;
        } else {
            ++i;
        }
    }
    if (found) emit(start, n);
    return found;
}

// Reads exp-Golomb fields from an SPS after removing emulation-prevention bytes.
class Bits {
public:
    Bits(const std::uint8_t* d, std::size_t n) {
        for (std::size_t i = 0; i < n; ++i) {
            if (i >= 2 && d[i] == 3 && d[i - 1] == 0 && d[i - 2] == 0) continue;
            bytes_.push_back(d[i]);
        }
    }
    std::uint32_t bit() {
        if (position_ >= bytes_.size() * 8) { ok = false; return 0; }
        const auto v = (bytes_[position_ / 8] >> (7 - position_ % 8)) & 1u;
        ++position_;
        return v;
    }
    std::uint32_t ue() {
        int zeros = 0;
        while (ok && bit() == 0) if (++zeros > 31) { ok = false; return 0; }
        std::uint32_t v = 0;
        for (int i = 0; i < zeros; ++i) v = v << 1 | bit();
        return (1u << zeros) - 1 + v;
    }
    bool ok = true;

private:
    Bytes bytes_;
    std::size_t position_ = 0;
};
} // namespace

namespace flv {
bool avc_frame(const std::uint8_t* data, std::size_t size, AccessUnit& out) {
    out.body.assign({0x27, 0x01, 0, 0, 0});
    out.sps.clear();
    out.pps.clear();
    out.key = false;
    bool slices = false;
    each_nal(data, size, [&](const std::uint8_t* nal, std::size_t n) {
        const int type = nal[0] & 0x1f;
        if (type == 7) { out.sps.assign(nal, nal + n); return; }
        if (type == 8) { out.pps.assign(nal, nal + n); return; }
        if (type == 9) return;
        if (type == 5) out.key = true;
        put32(out.body, static_cast<std::uint32_t>(n));
        out.body.insert(out.body.end(), nal, nal + n);
        slices = true;
    });
    if (out.key) out.body[0] = 0x17;
    return slices;
}

void parameter_sets(const std::uint8_t* data, std::size_t size, Bytes& sps, Bytes& pps) {
    each_nal(data, size, [&](const std::uint8_t* nal, std::size_t n) {
        if ((nal[0] & 0x1f) == 7) sps.assign(nal, nal + n);
        if ((nal[0] & 0x1f) == 8) pps.assign(nal, nal + n);
    });
}

// AVCDecoderConfigurationRecord (ISO/IEC 14496-15), with the chroma and bit-depth fields
// that High profiles require.
Bytes avc_sequence_header(const Bytes& sps, const Bytes& pps) {
    Bytes b{0x17, 0x00, 0, 0, 0, 1, sps[1], sps[2], sps[3], 0xFF, 0xE1};
    put16(b, static_cast<std::uint32_t>(sps.size()));
    b.insert(b.end(), sps.begin(), sps.end());
    b.push_back(1);
    put16(b, static_cast<std::uint32_t>(pps.size()));
    b.insert(b.end(), pps.begin(), pps.end());
    const int profile = sps[1];
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 ||
        profile == 86 || profile == 118 || profile == 128 || profile == 138 || profile == 139 || profile == 134) {
        Bits bits(sps.data() + 4, sps.size() - 4);
        bits.ue();  // seq_parameter_set_id
        std::uint32_t chroma = bits.ue();
        if (chroma == 3) bits.bit();
        std::uint32_t luma_depth = bits.ue(), chroma_depth = bits.ue();
        if (!bits.ok || chroma > 3 || luma_depth > 7 || chroma_depth > 7) { chroma = 1; luma_depth = chroma_depth = 0; }
        b.push_back(std::uint8_t(0xFC | chroma));
        b.push_back(std::uint8_t(0xF8 | luma_depth));
        b.push_back(std::uint8_t(0xF8 | chroma_depth));
        b.push_back(0);
    }
    return b;
}

Bytes aac_sequence_header(std::uint32_t rate, std::uint32_t channels) {
    constexpr std::array<std::uint32_t, 13> rates{96000, 88200, 64000, 48000, 44100, 32000, 24000,
                                                  22050, 16000, 12000, 11025, 8000, 7350};
    const auto index = static_cast<std::uint32_t>(std::find(rates.begin(), rates.end(), rate) - rates.begin());
    // AudioSpecificConfig: AAC-LC (object type 2), sampling index, channel configuration.
    const std::uint32_t config = 2u << 11 | (index & 15u) << 7 | (channels & 15u) << 3;
    return {0xAF, 0x00, std::uint8_t(config >> 8), std::uint8_t(config)};
}

Bytes aac_frame(const std::uint8_t* data, std::size_t size) {
    Bytes b{0xAF, 0x01};
    b.insert(b.end(), data, data + size);
    return b;
}
} // namespace flv

RtmpPublisher::RtmpPublisher() = default;
RtmpPublisher::~RtmpPublisher() { close(0); }

std::string RtmpPublisher::redact(const std::string& url) {
    Target target;
    if (!parse_url(url, target).empty()) return "(invalid stream URL)";
    return "rtmp://" + target.authority + "/" + target.app + "/****";
}

std::string RtmpPublisher::failure() const {
    std::lock_guard lock(mutex_);
    return failure_;
}

void RtmpPublisher::fail(std::string text) {
    {
        std::lock_guard lock(mutex_);
        if (failure_.empty()) failure_ = std::move(text);
    }
    live_.store(false);
}

bool RtmpPublisher::send_all(const std::uint8_t* data, std::size_t size) {
    const auto s = static_cast<Socket>(socket_);
    while (size) {
#ifdef _WIN32
        const int sent = ::send(s, reinterpret_cast<const char*>(data), static_cast<int>(std::min<std::size_t>(size, 1 << 20)), 0);
#else
#ifdef MSG_NOSIGNAL
        const ssize_t sent = ::send(s, data, size, MSG_NOSIGNAL);
#else
        const ssize_t sent = ::send(s, data, size, 0);
#endif
        if (sent < 0 && errno == EINTR) continue;
#endif
        if (sent <= 0) return false;
        data += sent;
        size -= static_cast<std::size_t>(sent);
    }
    return true;
}

bool RtmpPublisher::read_exact(std::uint8_t* data, std::size_t size) {
    const auto s = static_cast<Socket>(socket_);
    while (size) {
#ifdef _WIN32
        const int got = ::recv(s, reinterpret_cast<char*>(data), static_cast<int>(std::min<std::size_t>(size, 1 << 20)), 0);
#else
        const ssize_t got = ::recv(s, data, size, 0);
        if (got < 0 && errno == EINTR) continue;
#endif
        if (got <= 0) return false;
        data += got;
        size -= static_cast<std::size_t>(got);
        received_ += static_cast<std::uint64_t>(got);
    }
    return true;
}

// Every message starts with a full (type 0) header; continuation chunks use type 3.
bool RtmpPublisher::write_message(std::uint32_t csid, std::uint8_t type, std::uint32_t stream, std::uint32_t ms,
                                  const Bytes& body) {
    out_.clear();
    const bool extended = ms >= 0xFFFFFF;
    out_.push_back(std::uint8_t(csid));
    put24(out_, extended ? 0xFFFFFF : ms);
    put24(out_, static_cast<std::uint32_t>(body.size()));
    out_.push_back(type);
    for (int i = 0; i < 4; ++i) out_.push_back(std::uint8_t(stream >> (i * 8)));
    if (extended) put32(out_, ms);
    for (std::size_t offset = 0; offset < body.size(); offset += chunk_out_) {
        if (offset) {
            out_.push_back(std::uint8_t(0xC0 | csid));
            if (extended) put32(out_, ms);
        }
        const auto n = std::min<std::size_t>(chunk_out_, body.size() - offset);
        out_.insert(out_.end(), body.begin() + static_cast<std::ptrdiff_t>(offset),
                    body.begin() + static_cast<std::ptrdiff_t>(offset + n));
    }
    if (!send_all(out_.data(), out_.size())) return false;
    bytes_.fetch_add(out_.size());
    return true;
}

bool RtmpPublisher::read_message(Message& out) {
    for (;;) {
        std::uint8_t head[3];
        if (!read_exact(head, 1)) return false;
        const int format = head[0] >> 6;
        std::uint32_t csid = head[0] & 0x3f;
        if (csid == 0) {
            if (!read_exact(head + 1, 1)) return false;
            csid = 64u + head[1];
        } else if (csid == 1) {
            if (!read_exact(head + 1, 2)) return false;
            csid = 64u + head[1] + 256u * head[2];
        }
        auto& in = incoming_[csid];
        const bool starting = in.payload.empty();
        std::uint8_t header[11];
        const std::size_t size = format == 0 ? 11 : format == 1 ? 7 : format == 2 ? 3 : 0;
        if (size && !read_exact(header, size)) return false;
        std::uint32_t field = 0;
        if (format <= 2) {
            field = get24(header);
            in.extended = field == 0xFFFFFF;
        }
        if (format <= 1) {
            in.length = get24(header + 3);
            in.type = header[6];
        }
        if (format == 0) in.stream = header[7] | header[8] << 8 | header[9] << 16 | std::uint32_t(header[10]) << 24;
        if (in.extended) {  // Also repeated in type 3 chunks of a message that uses it.
            std::uint8_t ext[4];
            if (!read_exact(ext, 4)) return false;
            field = get32(ext);
        }
        if (format == 0) in.timestamp = field;
        else if (format <= 2) { in.delta = field; if (starting) in.timestamp += field; }
        else if (starting) in.timestamp += in.delta;
        if (in.length > (16u << 20)) return false;
        const auto want = std::min<std::size_t>(chunk_in_, in.length - in.payload.size());
        const auto at = in.payload.size();
        in.payload.resize(at + want);
        if (want && !read_exact(in.payload.data() + at, want)) return false;
        if (in.payload.size() < in.length) continue;
        out.type = in.type;
        out.data.swap(in.payload);
        in.payload.clear();
        if (window_ && received_ - acknowledged_ >= window_ / 2) {
            Bytes ack;
            put32(ack, static_cast<std::uint32_t>(received_));
            if (!write_message(kControl, 3, 0, 0, ack)) return false;
            acknowledged_ = received_;
        }
        return true;
    }
}

bool RtmpPublisher::handle_control(const Message& m) {
    switch (m.type) {
    case 1:
        if (m.data.size() >= 4) chunk_in_ = std::max<std::uint32_t>(1, get32(m.data.data()) & 0x7FFFFFFF);
        return true;
    case 5:
        if (m.data.size() >= 4) window_ = get32(m.data.data());
        return true;
    case 4:
        if (m.data.size() >= 6 && get16(m.data.data()) == 6) {  // Ping request: answer with the same time.
            Bytes pong;
            put16(pong, 7);
            pong.insert(pong.end(), m.data.begin() + 2, m.data.begin() + 6);
            write_message(kControl, 4, 0, 0, pong);
        }
        return true;
    case 2:
    case 3:
    case 6:
        return true;
    default:
        return false;
    }
}

bool RtmpPublisher::await_command(double transaction, bool status, Command& out, std::string& error) {
    const auto deadline = now_ms() + kTimeoutMs;
    while (now_ms() < deadline) {
        Message m;
        if (!read_message(m)) { error = "the stream server closed the connection"; return false; }
        if (handle_control(m) || m.type != 20) continue;
        Command c;
        if (!parse_command(m.data, c.name, c.transaction, c.numbers, c.info)) continue;
        if (status ? c.name == "onStatus"
                   : (c.name == "_result" || c.name == "_error") && c.transaction == transaction) {
            out = std::move(c);
            return true;
        }
    }
    error = "the stream server did not answer";
    return false;
}

std::string RtmpPublisher::open(const std::string& url, const StreamInfo& info) {
    Target target;
    if (auto error = parse_url(url, target); !error.empty()) return error;
    key_ = target.key;
    const std::string where = target.host + ":" + target.port;
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return "could not start Windows networking";
    winsock_ = true;
#endif
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;
    addrinfo* found = nullptr;
    if (getaddrinfo(target.host.c_str(), target.port.c_str(), &hints, &found) != 0 || !found)
        return "could not resolve " + target.host;
    for (auto* a = found; a && socket_ == -1; a = a->ai_next) {
        const Socket s = ::socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (s == kNoSocket) continue;
        if (connect_within(s, a->ai_addr, static_cast<int>(a->ai_addrlen), 5000)) socket_ = static_cast<std::intptr_t>(s);
        else close_socket(s);
    }
    freeaddrinfo(found);
    if (socket_ == -1) return "could not connect to " + where;
    configure(static_cast<Socket>(socket_));

    // Plain handshake: C0+C1, S0+S1, C2 echoes S1, S2.
    Bytes hello(1 + 1536);
    hello[0] = 3;
    std::mt19937 random(static_cast<std::uint32_t>(now_ms()));
    for (std::size_t i = 9; i < hello.size(); ++i) hello[i] = static_cast<std::uint8_t>(random());
    Bytes reply(1 + 1536);
    if (!send_all(hello.data(), hello.size()) || !read_exact(reply.data(), reply.size()) ||
        !send_all(reply.data() + 1, 1536) || !read_exact(reply.data() + 1, 1536))
        return "RTMP handshake with " + where + " failed";

    Bytes b;
    put32(b, kChunkSize);
    if (!write_message(kControl, 1, 0, 0, b)) return "lost the connection to " + where;
    chunk_out_ = kChunkSize;

    const std::string tc_url = "rtmp://" + target.authority + "/" + target.app;
    b.clear();
    amf_string(b, "connect");
    amf_number(b, 1);
    b.push_back(3);
    amf_key(b, "app"); amf_string(b, target.app);
    amf_key(b, "type"); amf_string(b, "nonprivate");
    amf_key(b, "flashVer"); amf_string(b, "FMLE/3.0 (compatible; rec)");
    amf_key(b, "tcUrl"); amf_string(b, tc_url);
    amf_end(b);
    Command answer;
    std::string error;
    if (!write_message(kCommands, 20, 0, 0, b)) return "lost the connection to " + where;
    if (!await_command(1, false, answer, error)) return error;
    if (answer.name == "_error")
        return "the stream server refused app '" + target.app + "': " + answer.info["description"];

    for (const char* name : {"releaseStream", "FCPublish"}) {
        b.clear();
        amf_string(b, name);
        amf_number(b, name[0] == 'r' ? 2 : 3);
        amf_null(b);
        amf_string(b, key_);
        if (!write_message(kCommands, 20, 0, 0, b)) return "lost the connection to " + where;
    }
    b.clear();
    amf_string(b, "createStream");
    amf_number(b, 4);
    amf_null(b);
    if (!write_message(kCommands, 20, 0, 0, b) || !await_command(4, false, answer, error))
        return error.empty() ? "lost the connection to " + where : error;
    if (answer.name == "_error" || answer.numbers.empty()) return "the stream server could not create a stream";
    stream_id_ = static_cast<std::uint32_t>(answer.numbers.back());

    b.clear();
    amf_string(b, "publish");
    amf_number(b, 5);
    amf_null(b);
    amf_string(b, key_);
    amf_string(b, "live");
    if (!write_message(kStreamData, 20, stream_id_, 0, b) || !await_command(0, true, answer, error))
        return error.empty() ? "lost the connection to " + where : error;
    const auto code = answer.info["code"];
    if (code.find("Publish.Start") == std::string::npos) {
        const auto description = answer.info["description"];
        return "the stream server refused the stream: " + code + (description.empty() ? "" : " (" + description + ")");
    }

    b.clear();
    amf_string(b, "@setDataFrame");
    amf_string(b, "onMetaData");
    b.push_back(8);
    put32(b, 11);
    amf_key(b, "width"); amf_number(b, info.width);
    amf_key(b, "height"); amf_number(b, info.height);
    amf_key(b, "framerate"); amf_number(b, info.fps);
    amf_key(b, "videocodecid"); amf_number(b, 7);
    amf_key(b, "videodatarate"); amf_number(b, info.video_kbps);
    amf_key(b, "audiocodecid"); amf_number(b, 10);
    amf_key(b, "audiodatarate"); amf_number(b, info.audio_kbps);
    amf_key(b, "audiosamplerate"); amf_number(b, info.audio_rate);
    amf_key(b, "audiosamplesize"); amf_number(b, 16);
    amf_key(b, "stereo"); amf_bool(b, info.audio_channels == 2);
    amf_key(b, "encoder"); amf_string(b, "rec");
    amf_end(b);
    if (!write_message(kStreamData, 18, stream_id_, 0, b)) return "lost the connection to " + where;

    max_bytes_ = std::max<std::size_t>(2u << 20, std::size_t(info.video_kbps + info.audio_kbps) * 1000 / 8 * 3);
    live_.store(true);
    sender_ = std::thread([this] { run(); });
    return {};
}

bool RtmpPublisher::push(std::uint8_t type, std::uint32_t ms, bool header, bool key, Bytes body) {
    {
        std::lock_guard lock(mutex_);
        if (!live_.load() || closing_) return false;
        const bool video = type == 9;
        if (!header) {
            if (video && need_key_ && !key) { dropped_.fetch_add(1); return false; }
            if (queued_bytes_ + body.size() > max_bytes_) {
                if (video) { dropped_.fetch_add(1); need_key_ = true; }
                return false;
            }
            if (video && key) need_key_ = false;
        }
        queued_bytes_ += body.size();
        queue_.push_back({type, ms, std::move(body)});
    }
    wake_.notify_one();
    return true;
}

bool RtmpPublisher::video(std::uint32_t ms, bool key, bool header, Bytes body) { return push(9, ms, header, key, std::move(body)); }
bool RtmpPublisher::audio(std::uint32_t ms, bool header, Bytes body) { return push(8, ms, header, false, std::move(body)); }

void RtmpPublisher::run() {
    for (;;) {
        Packet packet;
        {
            std::unique_lock lock(mutex_);
            wake_.wait_for(lock, std::chrono::milliseconds(50), [this] { return !queue_.empty() || closing_; });
            if (closing_ && (queue_.empty() || now_ms() > flush_deadline_ms_)) break;
            if (queue_.empty()) packet.type = 0;
            else {
                packet = std::move(queue_.front());
                queue_.pop_front();
                queued_bytes_ -= packet.body.size();
            }
        }
        if (packet.type && !write_message(packet.type == 9 ? kVideo : kAudio, packet.type, stream_id_, packet.ms, packet.body)) {
            fail("lost the connection to the stream server");
            break;
        }
        bool ended = false;
        while (!ended && readable(static_cast<Socket>(socket_))) {
            Message m;
            if (!read_message(m)) { fail("the stream server closed the connection"); ended = true; break; }
            if (handle_control(m) || m.type != 20) continue;
            Command c;
            if (parse_command(m.data, c.name, c.transaction, c.numbers, c.info) && c.name == "onStatus" &&
                c.info["level"] == "error") {
                fail("the stream server ended the stream: " + c.info["code"] + " " + c.info["description"]);
                ended = true;
            }
        }
        if (ended) break;
    }
    {
        std::lock_guard lock(mutex_);
        sender_done_ = true;
    }
    wake_.notify_all();
}

void RtmpPublisher::close(int flush_ms) {
    if (sender_.joinable()) {
        std::unique_lock lock(mutex_);
        closing_ = true;
        flush_deadline_ms_ = now_ms() + flush_ms;
        wake_.notify_all();
        // A send blocked on a stalled network cannot see the deadline; closing the socket ends it.
        if (!wake_.wait_for(lock, std::chrono::milliseconds(flush_ms + 1000), [this] { return sender_done_; })) {
            lock.unlock();
#ifdef _WIN32
            shutdown(static_cast<Socket>(socket_), SD_BOTH);
#else
            shutdown(static_cast<Socket>(socket_), SHUT_RDWR);
#endif
        } else {
            lock.unlock();
        }
        sender_.join();
    }
    if (socket_ != -1) {
        if (live_.load()) {
            Bytes b;
            amf_string(b, "FCUnpublish");
            amf_number(b, 6);
            amf_null(b);
            amf_string(b, key_);
            write_message(kCommands, 20, 0, 0, b);
            b.clear();
            amf_string(b, "deleteStream");
            amf_number(b, 7);
            amf_null(b);
            amf_number(b, stream_id_);
            write_message(kCommands, 20, 0, 0, b);
        }
#ifdef _WIN32
        shutdown(static_cast<Socket>(socket_), SD_SEND);
#else
        shutdown(static_cast<Socket>(socket_), SHUT_WR);
#endif
        close_socket(static_cast<Socket>(socket_));
        socket_ = -1;
    }
    live_.store(false);
#ifdef _WIN32
    if (winsock_) { WSACleanup(); winsock_ = false; }
#endif
}

} // namespace rec::core
