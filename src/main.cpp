#include "rec/rec.hpp"

#include <atomic>
#include <charconv>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdlib>
#include <iostream>
#include <string_view>
#include <thread>

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
                 "  -o, --output FILE       Output .mp4 or .mov (default: rec.mov)\n"
                 "  --display N             Display number from devices (default: 1)\n"
                 "  -r, --resolution SIZE    1080p, 1440p, 4k, or native\n"
                 "  -f, --fps N              24, 25, 30, 50, 60, or 120\n"
                 "  -t, --duration SECONDS   Recording length (0 = until Ctrl-C)\n"
                 "  --codec NAME             auto, h264, hevc\n"
                 "  --bitrate MBPS           Target megabits/second (0 = automatic)\n"
                 "  --no-cursor              Do not record the cursor\n"
                 "  --test-pattern           Synthetic encode (no screen permission)\n"
                 "  --test-tone              Add synthetic AAC audio to test pattern\n";
}

bool integer(std::string_view s, std::uint32_t& out) {
    const char* end = s.data() + s.size();
    const auto [p, ec] = std::from_chars(s.data(), end, out);
    return ec == std::errc{} && p == end;
}

bool duration(std::string_view s, double& out) {
    std::string owned(s);
    char* end = nullptr;
    out = std::strtod(owned.c_str(), &end);
    return end != owned.c_str() && *end == '\0' && std::isfinite(out) && out >= 0 && out <= 86400;
}

bool parse(int argc, char** argv, rec::Options& o, std::string& error) {
    for (int i = 2; i < argc; ++i) {
        std::string_view arg(argv[i]);
        if (arg == "--no-cursor") { o.cursor = false; continue; }
        if (arg == "--test-pattern") { o.test_pattern = true; continue; }
        if (arg == "--test-tone") { o.test_tone = true; continue; }
        if (i + 1 >= argc) { error = "missing value for " + std::string(arg); return false; }
        std::string_view value(argv[++i]);
        if (arg == "-o" || arg == "--output") o.output = value;
        else if (arg == "--display") {
            if (!integer(value, o.display) || o.display == 0) { error = "invalid display index"; return false; }
        } else if (arg == "-f" || arg == "--fps") {
            if (!integer(value, o.fps) || (o.fps != 24 && o.fps != 25 && o.fps != 30 && o.fps != 50 && o.fps != 60 && o.fps != 120)) {
                error = "fps must be 24, 25, 30, 50, 60, or 120"; return false;
            }
        } else if (arg == "-t" || arg == "--duration") {
            if (!duration(value, o.duration_seconds)) { error = "invalid duration"; return false; }
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
        } else { error = "unknown option: " + std::string(arg); return false; }
    }
    if (o.test_tone && !o.test_pattern) { error = "--test-tone requires --test-pattern"; return false; }
    if (o.output.empty() || (o.output.size() < 4 ||
        (o.output.substr(o.output.size() - 4) != ".mov" && o.output.substr(o.output.size() - 4) != ".mp4"))) {
        error = "output must end with .mov or .mp4";
        return false;
    }
    return true;
}
} // namespace

int main(int argc, char** argv) {
    if (argc == 1 || std::string_view(argv[1]) == "--help" || std::string_view(argv[1]) == "-h") {
        usage(); return 0;
    }
    const std::string_view command(argv[1]);
    if (command == "devices") {
        if (argc != 2) { std::cerr << "devices takes no options\n"; return 2; }
        std::string error;
        auto screens = rec::list_displays(error);
        if (!error.empty()) { std::cerr << error << '\n'; return 1; }
        for (std::size_t i = 0; i < screens.size(); ++i) {
            const auto& screen = screens[i];
            std::cout << i + 1 << ": " << screen.name << " (" << screen.width << "x" << screen.height
                      << ", id " << screen.id << ")\n";
        }
        return 0;
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
                  << "\naudio_codec=" << probe.audio_codec << "\naudio_buffers=" << probe.audio_buffers
                  << "\naudio_duration=" << probe.audio_duration_seconds << '\n';
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
    std::cout << "Recording to " << options.output << " (Ctrl-C to stop)\n";
    while (!interrupted.load() && !recorder.finished()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    const auto stopped = recorder.stop();
    const auto stats = recorder.stats();
    std::cout << "Captured " << stats.captured << ", written " << stats.written
              << ", dropped " << stats.dropped << '\n';
    if (!stopped) { std::cerr << stopped.error << '\n'; return 1; }
    if (!recorder.failure().empty()) { std::cerr << recorder.failure() << '\n'; return 1; }
    std::cout << "Saved " << options.output << '\n';
    return 0;
}
