# rec-

A compact screen recorder for macOS, built with C++20 and Apple's capture and video encoding frameworks.

This is the first implementation, not feature parity with [rec-rs](https://github.com/michaelshimeles/rec-rs). It records one display to a `.mov` or `.mp4` file with H.264 or HEVC. It does not capture audio yet. Camera overlays, window selection, pause/resume, replay and streaming are not implemented.

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

`rec probe file.mov` reports decoded frames, dimensions, codec, and duration.



```sh
./scripts/smoke.sh
REC_E2E_CAPTURE=1 ./scripts/smoke.sh
```

The first command builds and checks the CLI contract. The second records a short real screen capture on macOS. If `ffprobe` is installed, it also checks the output video codec, frame count and dimensions. This is an end-to-end check, not a substitute for long-duration sync or quality measurement.

## Current limits

- Capture is display-only and video-only.
- The file writer currently drops an output frame when the hardware encoder is backpressured. Drops are counted. Retrying a bounded backlog is a follow-up before performance comparisons.
- ScreenCaptureKit performs scaling for non-native output. GPU Lanczos quality is future work.
- Capturing and encoding with macOS cannot be verified on a Linux host. See the CI workflow for the macOS build and smoke gate.
- There are no credible CPU, RAM, binary-size or quality comparisons with rec-rs yet.

The architecture rules and studied references are in [AGENTS.md](AGENTS.md).
