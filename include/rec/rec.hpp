#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace rec {

enum class Codec { automatic, h264, hevc };

struct Options {
    std::string output = "rec.mov";
    std::uint32_t display = 1; // 1-based index from list_displays()
    std::uint32_t width = 1920; // bounding box, 0/0 selects native resolution
    std::uint32_t height = 1080;
    std::uint32_t fps = 60;
    std::uint32_t bitrate_mbps = 0; // 0 = selected from resolution
    Codec codec = Codec::automatic;
    bool cursor = true;
    bool test_pattern = false; // Synthetic frame, for hardware-encoder E2E without screen permission.
    double duration_seconds = 10.0; // 0 = until stop()
};

struct Display {
    std::uint32_t id = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::string name;
};

struct Stats {
    std::uint64_t captured = 0;
    std::uint64_t written = 0;
    std::uint64_t dropped = 0;
};

struct Probe {
    std::uint64_t frames = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    double duration_seconds = 0;
    std::string codec;
};

struct Result {
    std::string error;
    explicit operator bool() const noexcept { return error.empty(); }
};

// A failure sets error and returns an empty list.
std::vector<Display> list_displays(std::string& error);
Result probe_file(const std::string& path, Probe& probe);

class Recorder {
public:
    explicit Recorder(Options options);
    ~Recorder();

    Recorder(const Recorder&) = delete;
    Recorder& operator=(const Recorder&) = delete;

    Result start();
    Result stop(); // Finalizes the output before returning.
    bool running() const noexcept;
    bool finished() const noexcept; // Duration reached or capture failed.
    Stats stats() const noexcept;
    std::string failure() const;

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace rec
