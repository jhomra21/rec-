# rec-

A compact screen recorder for macOS, built with C++20 and Apple's capture and video encoding frameworks.

Full feature parity with [rec-rs](https://github.com/michaelshimeles/rec-rs) is the goal; the first implementation is intentionally narrower. It records one display to a `.mov` or `.mp4` file with H.264 or HEVC. It does not capture live audio yet; a synthetic AAC tone is available for E2E verification. Camera overlays, window selection, pause/resume, replay and streaming are not implemented.

## Build

Requires macOS 15 or newer, Xcode command line tools, and Screen Recording permission.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/rec devices
./build/rec record --display 1 -r 1080p -f 60 -t 10 --codec h264 -o demo.mov
```

macOS may prompt for Screen Recording permission on the first attempt. Allow access to the app that starts the CLI in System Settings > Privacy & Security > Screen & System Audio Recording, then retry.

`-r native` selects the display's native pixel size. The other resolution presets bound the output dimensions without stretching or upscaling. If a recording already exists at the output path, rec refuses to overwrite it.

You can stop an unlimited recording with Ctrl-C:

```sh
./build/rec record --duration 0 --codec hevc -o capture.mp4
```

`rec::Recorder` in `include/rec/rec.hpp` is the public library API. The CLI uses the same engine. The current implementation holds only the latest IOSurface-backed pixel buffer and passes it to AVAssetWriter without CPU pixel copying. It uses ScreenCaptureKit for resizing in this initial version.

## Verify

The `--test-pattern` capture path bypasses desktop permission and encodes a real synthetic NV12 video using VideoToolbox. On macOS, the smoke command also runs `rec probe` to decode every frame using AVFoundation, verify the codec and frame count, and check monotonic timestamps. Screen recording permission is still needed to validate a real display.

`rec probe file.mov` reports decoded frames, dimensions, codec, duration, and audio-track properties if present. Use `--test-pattern --test-tone` to exercise AAC encoding and decoding without microphone or desktop permissions.

```sh
./scripts/smoke.sh
REC_E2E_CAPTURE=1 ./scripts/smoke.sh
```

The first command builds, encodes real synthetic H.264 and HEVC movies through VideoToolbox, decodes them through AVFoundation, checks every frame's timestamp ordering and validates the exact frame count and codec. The second additionally captures a real screen with Screen Recording permission. CI publishes the synthetic video files and probe reports as a downloadable workflow artifact. These checks are not a substitute for longer A/V sync and performance measurements.

## Current limits

- Capture is display-only and video-only.
- The file writer retries transient encoder backpressure for up to 500 ms per timestamp. Overload beyond that deadline may drop frames; drops are counted and must be evaluated under stress.
- ScreenCaptureKit performs scaling for non-native output. GPU Lanczos quality is future work.
- Capturing and encoding with macOS cannot be verified on a Linux host. See the CI workflow for the macOS build and smoke gate.
- There are no credible CPU, RAM, binary-size or quality comparisons with rec-rs yet.

See [the parity and E2E acceptance tracker](docs/parity.md) for the remaining features and evidence required before release. Architecture rules and studied references are in [AGENTS.md](AGENTS.md).
