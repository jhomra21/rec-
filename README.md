# rec-

A compact screen recorder for macOS, built with C++20 and Apple's capture and video encoding frameworks.

Full feature parity with [rec-rs](https://github.com/michaelshimeles/rec-rs) is the goal; the current implementation is intentionally narrower. It records one display to a `.mov` or `.mp4` file with H.264 or HEVC, with optional system audio (`--system-audio`) and microphone (`--mic`). Both audio sources are recorded together as a mix track plus a separate track for each source. The synthetic flash-and-beep path is verified in CI. Live capture is implemented but still awaits a run on a Mac with the required permissions. Camera overlays, window selection, pause/resume, replay and streaming are not implemented.

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

`rec::Recorder` in `include/rec/rec.hpp` is the public library API. The CLI uses the same engine. IOSurface-backed pixel buffers go to AVAssetWriter without CPU pixel copying. It uses ScreenCaptureKit for resizing in this initial version.

## Audio and sync

```sh
./build/rec devices                                   # displays, microphones, output latency
./build/rec record --system-audio --mic default -t 30 -o talk.mov
```

| Track | Contents |
| --- | --- |
| 1 video | H.264 or HEVC, constant frame rate, keyframe every 2 s |
| 2 audio | Mix of system audio and microphone, AAC 48 kHz stereo 256 kb/s (default track) |
| 3 audio | System audio stem, AAC 48 kHz stereo 256 kb/s |
| 4 audio | Microphone stem, AAC 48 kHz mono 128 kb/s |

- With a single audio source there is a single audio track. `--audio-tracks mix` writes only the mix; `--audio-tracks stems` writes only the stems. The audio tracks share an alternate group with the mix as default, so players use the mix and editors see every track.
- `--system-gain` and `--mic-gain` (dB) apply to the mix. The mix goes through a limiter that keeps it under −1 dBFS instead of clipping.
- **Single clock.** Video frames, system audio and the microphone are stamped on the host clock. Video is written on an exact 1/fps grid, 40 ms behind real time, so each slot uses the frame that was on screen at that instant instead of the newest frame that happened to arrive.
- **System audio latency.** ScreenCaptureKit captures system audio when macOS mixes it, one output latency before you hear it. rec delays it by the default output device's latency from CoreAudio (`rec devices` prints it). Override with `--system-audio-offset-ms`; shift the microphone with `--mic-offset-ms`.
- The microphone is captured through ScreenCaptureKit (macOS 15). macOS asks for microphone permission on first use.

## Verify

The `--test-pattern` capture path bypasses desktop permission and encodes a real synthetic NV12 video using VideoToolbox. The frame flashes white for 100 ms once a second. `--test-tone` adds a beep at each flash as system audio, and `--test-mic` adds a quiet synthetic microphone so the mixer and every track layout run without permissions.

`rec probe file.mov` decodes every video frame and the default audio track with AVFoundation. It reports codec, dimensions, frame count, durations, and the number of audio tracks. It also measures A/V sync: each dark-to-bright video frame is paired with the nearest audio onset within 500 ms, and the probe reports the number of pairs (`av_sync_events`), the mean offset (`av_offset_ms`, positive means audio is late), and the worst offset.

For live A/V sync on a Mac with Screen Recording permission and audible output, run:

```sh
bash scripts/e2e-live-audio.sh                 # display + system audio
REC_E2E_MIC=1 bash scripts/e2e-live-audio.sh   # also the default microphone (mix + stems)
```

The script compiles `scripts/flash-beep.swift`, which flashes a full-screen window white with a simultaneous beep once a second. It records the display and system audio, probes the movie, and fails if fewer than four flash/beep pairs are found or if the mean offset falls outside the ITU-R BT.1359 detectability window (audio up to 45 ms early or 125 ms late). The movie, logs and probe report stay in the printed evidence directory.

```sh
./scripts/smoke.sh
REC_E2E_CAPTURE=1 ./scripts/smoke.sh
```

The first command builds, encodes real synthetic H.264 and HEVC movies through VideoToolbox, and decodes them through AVFoundation. It checks timestamp ordering, frame count and codec. It also checks track layouts (single, mix + stems, stems, mix only), that the flash/beep offset in the decoded file is within 20 ms, and that `--system-audio-offset-ms 100` moves audio 100 ms later. The second command additionally captures a real screen with Screen Recording permission. CI publishes the synthetic movies and probe reports as a downloadable workflow artifact. These checks are not a substitute for live-capture sync and performance measurements.

## Current limits

- Capture is display-only. Live system audio and microphone capture have not yet been verified on a permissioned Mac.
- The output latency is read once, when recording starts. Switching output devices mid-recording keeps the old offset.
- A microphone that is not 48 kHz is resampled linearly per buffer for the mix. Its stem is converted by AVFoundation.
- The file writer retries transient encoder backpressure for up to 500 ms per timestamp. Overload beyond that deadline may drop frames; drops are counted and must be evaluated under stress.
- ScreenCaptureKit performs scaling for non-native output. GPU Lanczos quality is future work.
- Capturing and encoding with macOS cannot be verified on a Linux host. See the CI workflow for the macOS build and smoke gate.
- There are no credible CPU, RAM, binary-size or quality comparisons with rec-rs yet.

See [the parity and E2E acceptance tracker](docs/parity.md) for the remaining features and evidence required before release. Architecture rules and studied references are in [AGENTS.md](AGENTS.md).
