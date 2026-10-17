#include "rec/rec.hpp"

#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <string_view>
#include <thread>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

namespace {
std::atomic_bool interrupted{false};

extern "C" void on_signal(int) { interrupted.store(true); }

void usage() {
    std::cout << "rec: native macOS screen recorder\n\n"
                 "Usage:\n"
                 "  rec devices\n"
                 "  rec record [options]\n"
                 "  rec probe FILE\n\n"
                 "Options:\n"
                 "  -o, --output FILE              Output .mp4 or .mov (default: rec.mov)\n"
                 "  --display N                    Display number from devices (default: 1)\n"
                 "  -r, --resolution SIZE          1080p, 1440p, 4k, or native\n"
                 "  -f, --fps N                    24, 25, 30, 50, 60, or 120\n"
                 "  -t, --duration SECONDS         Recording length (0 = until Ctrl-C)\n"
                 "  --codec NAME                   auto, h264, hevc\n"
                 "  --bitrate MBPS                 Target megabits/second (0 = automatic)\n"
                 "  --no-cursor                    Do not record the cursor\n"
                 "  --system-audio                 Record macOS system audio\n"
                 "  --mic DEVICE                   Record a microphone: default, or an ID or name from devices\n"
                 "  --audio-tracks LAYOUT          both (mix + stems), mix, or stems (default: both)\n"
                 "  --system-gain DB               System audio level in the mix (-60 to 24)\n"
                 "  --mic-gain DB                  Microphone level in the mix (-60 to 24)\n"
                 "  --system-audio-offset-ms MS    Delay system audio (default: output device latency)\n"
                 "  --mic-offset-ms MS             Delay the microphone (default: 0)\n"
                 "  --test-pattern                 Synthetic video that flashes once a second\n"
                 "  --test-tone                    Add a beep with each flash as system audio\n"
                 "  --test-mic                     Add a quiet synthetic microphone\n";
}

bool integer(std::string_view s, std::uint32_t& out) {
    const char* end = s.data() + s.size();
    const auto [p, ec] = std::from_chars(s.data(), end, out);
    return ec == std::errc{} && p == end;
}

bool number(std::string_view s, double low, double high, double& out) {
    std::string owned(s);
    char* end = nullptr;
    out = std::strtod(owned.c_str(), &end);
    return end != owned.c_str() && *end == '\0' && std::isfinite(out) && out >= low && out <= high;
}

bool parse(int argc, char** argv, rec::Options& o, std::string& error) {
    for (int i = 2; i < argc; ++i) {
        std::string_view arg(argv[i]);
        if (arg == "--no-cursor") { o.cursor = false; continue; }
        if (arg == "--test-pattern") { o.test_pattern = true; continue; }
        if (arg == "--test-tone") { o.test_tone = true; continue; }
        if (arg == "--test-mic") { o.test_mic = true; continue; }
        if (arg == "--system-audio") { o.system_audio = true; continue; }
        if (i + 1 >= argc) { error = "missing value for " + std::string(arg); return false; }
        std::string_view value(argv[++i]);
        double real = 0;
        if (arg == "-o" || arg == "--output") o.output = value;
        else if (arg == "--display") {
            if (!integer(value, o.display) || o.display == 0) { error = "invalid display index"; return false; }
        } else if (arg == "-f" || arg == "--fps") {
            if (!integer(value, o.fps) || (o.fps != 24 && o.fps != 25 && o.fps != 30 && o.fps != 50 && o.fps != 60 && o.fps != 120)) {
                error = "fps must be 24, 25, 30, 50, 60, or 120"; return false;
            }
        } else if (arg == "-t" || arg == "--duration") {
            if (!number(value, 0, 86400, o.duration_seconds)) { error = "invalid duration"; return false; }
        } else if (arg == "-r" || arg == "--resolution") {
            if (value == "native") { o.width = o.height = 0; }
            else if (value == "1080p") { o.width = 1920; o.height = 1080; }
            else if (value == "1440p") { o.width = 2560; o.height = 1440; }
            else if (value == "4k") { o.width = 3840; o.height = 2160; }
            else { error = "resolution must be 1080p, 1440p, 4k, or native"; return false; }
        } else if (arg == "--codec") {
            if (value == "auto") o.codec = rec::Codec::automatic;
            else if (value == "h264") o.codec = rec::Codec::h264;
            else if (value == "hevc") o.codec = rec::Codec::hevc;
            else { error = "codec must be auto, h264, or hevc"; return false; }
        } else if (arg == "--bitrate") {
            if (!integer(value, o.bitrate_mbps) || o.bitrate_mbps > 300) { error = "bitrate must be between 0 and 300 Mb/s"; return false; }
        } else if (arg == "--mic") {
            if (value.empty()) { error = "--mic needs a device: default, or an ID or name from `rec devices`"; return false; }
            o.microphone = true;
            o.microphone_device = value;
        } else if (arg == "--audio-tracks") {
            if (value == "both") o.audio_tracks = rec::AudioTracks::both;
            else if (value == "mix") o.audio_tracks = rec::AudioTracks::mix;
            else if (value == "stems") o.audio_tracks = rec::AudioTracks::stems;
            else { error = "audio tracks must be both, mix, or stems"; return false; }
        } else if (arg == "--system-gain" || arg == "--mic-gain") {
            if (!number(value, -60, 24, real)) { error = "gain must be between -60 and 24 dB"; return false; }
            (arg == "--system-gain" ? o.system_gain_db : o.mic_gain_db) = real;
        } else if (arg == "--system-audio-offset-ms" || arg == "--mic-offset-ms") {
            if (!number(value, -1000, 1000, real)) { error = "offset must be between -1000 and 1000 ms"; return false; }
            if (arg == "--mic-offset-ms") o.mic_offset_ms = real;
            else o.system_audio_offset_ms = real;
        } else { error = "unknown option: " + std::string(arg); return false; }
    }
    if ((o.test_tone || o.test_mic) && !o.test_pattern) {
        error = std::string(o.test_tone ? "--test-tone" : "--test-mic") + " requires --test-pattern"; return false;
    }
    if ((o.system_audio || o.microphone) && o.test_pattern) {
        error = std::string(o.system_audio ? "--system-audio" : "--mic") + " needs a real screen capture"; return false;
    }
    if (o.output.empty() || (o.output.size() < 4 ||
        (o.output.substr(o.output.size() - 4) != ".mov" && o.output.substr(o.output.size() - 4) != ".mp4"))) {
        error = "output must end with .mov or .mp4";
        return false;
    }
    return true;
}

bool terminal() {
#ifdef _WIN32
    return _isatty(1) != 0;
#else
    return isatty(STDOUT_FILENO) != 0;
#endif
}

// One rewritten line: elapsed time and anything that needs attention.
void show_status(const rec::Stats& stats, std::chrono::steady_clock::duration elapsed, bool audio) {
    const auto tenths = std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count() / 100;
    std::cout << "\r\033[31m\xE2\x97\x8F\033[0m REC " << std::setfill('0') << std::setw(2) << tenths / 600 << ':'
              << std::setw(2) << (tenths / 10) % 60 << '.' << tenths % 10 << std::setfill(' ')
              << "   " << stats.written << " frames";
    if (stats.dropped) std::cout << ", \033[33m" << stats.dropped << " dropped\033[0m";
    if (audio && stats.audio_dropped + stats.mic_dropped)
        std::cout << ", \033[33maudio drops " << stats.audio_dropped + stats.mic_dropped << "\033[0m";
    std::cout << "\033[K" << std::flush;
}
} // namespace

int main(int argc, char** argv) {
    if (argc == 1 || std::string_view(argv[1]) == "--help" || std::string_view(argv[1]) == "-h") {
        usage(); return 0;
    }
    const std::string_view command(argv[1]);
    if (command == "devices") {
        if (argc != 2) { std::cerr << "devices takes no options\n"; return 2; }
        int status = 0;
        std::string error;
        auto screens = rec::list_displays(error);
        if (!error.empty()) { std::cerr << error << '\n'; status = 1; }
        std::cout << "Displays:\n";
        for (std::size_t i = 0; i < screens.size(); ++i) {
            const auto& screen = screens[i];
            std::cout << "  " << i + 1 << ": " << screen.name << " (" << screen.width << "x" << screen.height
                      << ", id " << screen.id << ")\n";
        }
        auto microphones = rec::list_microphones(error);
        if (!error.empty()) { std::cerr << error << '\n'; status = 1; }
        std::cout << "Microphones:\n";
        for (const auto& mic : microphones) std::cout << "  " << mic.name << " (id " << mic.id << ")\n";
        std::cout << "Default output latency: " << std::fixed << std::setprecision(1)
                  << rec::default_output_latency_ms() << " ms\n";
        return status;
    }
    if (command == "probe") {
        if (argc != 3) { std::cerr << "usage: rec probe FILE\n"; return 2; }
        rec::Probe probe;
        if (auto result = rec::probe_file(argv[2], probe); !result) {
            std::cerr << result.error << '\n'; return 1;
        }
        std::cout << "codec=" << probe.codec << "\nwidth=" << probe.width
                  << "\nheight=" << probe.height << "\nframes=" << probe.frames
                  << "\nduration=" << probe.duration_seconds
                  << "\naudio_tracks=" << probe.audio_tracks
                  << "\naudio_codec=" << probe.audio_codec << "\naudio_buffers=" << probe.audio_buffers
                  << "\naudio_duration=" << probe.audio_duration_seconds
                  << "\nav_sync_events=" << probe.sync_events
                  << "\nav_offset_ms=" << probe.av_offset_ms
                  << "\nav_offset_max_ms=" << probe.av_offset_max_ms << '\n';
        return 0;
    }
    if (command != "record") { std::cerr << "unknown command: " << command << '\n'; return 2; }

    rec::Options options;
    std::string error;
    if (!parse(argc, argv, options, error)) { std::cerr << error << '\n'; return 2; }
    rec::Recorder recorder(options);
    if (auto result = recorder.start(); !result) { std::cerr << result.error << '\n'; return 1; }

    std::signal(SIGINT, on_signal);
    std::signal(SIGTERM, on_signal);
    const bool audio = options.system_audio || options.microphone || options.test_tone || options.test_mic;
    const bool live = terminal();
    std::cout << "Recording to " << options.output << " (Ctrl-C to stop)\n";
    const auto began = std::chrono::steady_clock::now();
    auto shown = began - std::chrono::seconds(1);
    while (!interrupted.load() && !recorder.finished()) {
        const auto now = std::chrono::steady_clock::now();
        if (live && now - shown >= std::chrono::milliseconds(250)) {
            show_status(recorder.stats(), now - began, audio);
            shown = now;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (live) std::cout << "\r\033[KFinishing...\n" << std::flush;
    const auto stopped = recorder.stop();
    const auto stats = recorder.stats();
    std::cout << "Captured " << stats.captured << ", written " << stats.written
              << ", dropped " << stats.dropped << '\n';
    if (options.system_audio || options.test_tone)
        std::cout << "System audio buffers written " << stats.audio_written << ", dropped " << stats.audio_dropped
                  << " (offset " << std::fixed << std::setprecision(1) << stats.system_audio_offset_ms << " ms)\n";
    if (options.microphone || options.test_mic)
        std::cout << "Microphone buffers written " << stats.mic_written << ", dropped " << stats.mic_dropped << '\n';
    if (stats.mix_written) std::cout << "Mix buffers written " << stats.mix_written << '\n';
    if (!stopped) { std::cerr << stopped.error << '\n'; return 1; }
    if (!recorder.failure().empty()) { std::cerr << recorder.failure() << '\n'; return 1; }
    std::cout << "Saved " << options.output << '\n';
    return 0;
}
