# rec-

A compact screen recorder for macOS and Windows, built with C++20 and each platform's native capture and hardware encoding frameworks.

Full feature parity with [rec-rs](https://github.com/michaelshimeles/rec-rs) is the goal; the current implementation is intentionally narrower. It records one display to a `.mov` or `.mp4` file with H.264 or HEVC, with optional system audio (`--system-audio`) and microphone (`--mic`). Both audio sources are recorded together as a mix track plus a separate track for each source. The synthetic flash-and-beep path is verified in CI on both platforms. Live capture with system audio and a microphone passes the flash/beep sync test on a Mac (M3 Pro) and on a Windows PC; see the Mac evidence ([run 1](docs/evidence/2026-10-16-live-test/README.md), [run 2](docs/evidence/2026-10-16-run2/README.md), [run 3](docs/evidence/2026-10-16-run3/README.md), [run 4: pause and crash safety](docs/evidence/2026-10-17-run4/README.md)) and the Windows measurements below. Recordings can be paused and resumed, and a crash leaves a playable file. Camera overlays, window selection, replay and streaming are not implemented.

## Build

Requires macOS 15 or newer, Xcode command line tools, and Screen Recording permission.

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/rec devices
./build/rec record --display 1 -r 1080p -f 60 -t 10 --codec h264 -o demo.mov
```

### Windows

Requires Windows 10 version 1903 or newer and Visual Studio 2022 (or Build Tools) with the C++ workload. From a developer PowerShell:

```powershell
cmake -S . -B build
cmake --build build --config Release --parallel
.\build\Release\rec.exe devices
.\build\Release\rec.exe record -r 1080p -f 60 -t 10 --system-audio --mic default -o demo.mp4
```

Windows uses Windows.Graphics.Capture for the display, a Direct3D 11 video processor to scale and convert to NV12 on the GPU, WASAPI for system audio (loopback) and the microphone, and the Media Foundation sink writer with the hardware encoder of the GPU that drives the display. Frames stay on the GPU from capture to encoder. Windows writes ISO MP4 structure for both `.mp4` and `.mov`. If Windows blocks the microphone, turn on "Let desktop apps access your microphone" in Settings > Privacy & security > Microphone.

### macOS permissions

macOS may prompt for Screen Recording permission on the first attempt. Allow access to the app that starts the CLI in System Settings > Privacy & Security > Screen & System Audio Recording, then retry.

`-r native` selects the display's native pixel size. The other resolution presets bound the output dimensions without stretching or upscaling. If a recording already exists at the output path, rec refuses to overwrite it.

You can stop an unlimited recording with Ctrl-C:

```sh
./build/rec record --duration 0 --codec hevc -o capture.mp4
```

### Pause, resume and crash safety

While recording in a terminal, press `p` or space to pause and resume, and `q` or Ctrl-C to stop. The status line shows PAUSED and the recorded time. Paused time is cut from the movie: video and every audio track continue without a gap, and `-t` counts recorded time, not wall time. When stdin is piped, rec reads one command per line (`pause`, `resume`, `toggle`, `stop`), so scripts and other programs can drive a recording:

```sh
{ sleep 5; echo pause; sleep 3; echo resume; } | ./build/rec record -t 10 -o demo.mov
```

Recordings are written in fragments, so a crash, kill or power loss keeps everything up to the last fragment (about 1 s on macOS). On macOS a normal stop turns the fragments into a regular movie. On Windows, H.264 files stay fragmented MP4, which players read normally. Windows HEVC uses the regular MP4 writer and is **not** crash-safe, because Windows' fragmented MP4 writer rejects HEVC.

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
- On Windows, every source is stamped on the QueryPerformanceCounter clock. System audio is delayed by the default output endpoint's stream latency plus one device period.

## Verify

The `--test-pattern` capture path bypasses desktop permission and encodes a real synthetic NV12 video using VideoToolbox. The frame flashes white for 100 ms once a second. `--test-tone` adds a beep at each flash as system audio, and `--test-mic` adds a quiet synthetic microphone so the mixer and every track layout run without permissions.

`rec probe file.mov` decodes every video frame and the default audio track with AVFoundation. It reports codec, dimensions, frame count, durations, and the number of audio tracks. It also measures A/V sync: each dark-to-bright video frame is paired with the nearest audio onset within 500 ms, and the probe reports the number of pairs (`av_sync_events`), the mean offset (`av_offset_ms`, positive means audio is late), and the worst offset.

On Windows, `rec probe` uses the Media Foundation source reader instead.

For live A/V sync on a Mac with Screen Recording permission and audible output, run:

```sh
bash scripts/e2e-live-audio.sh                 # display + system audio
REC_E2E_MIC=1 bash scripts/e2e-live-audio.sh   # also the default microphone (mix + stems)
REC_E2E_PAUSE=1 bash scripts/e2e-live-audio.sh # pause 2 s mid-stimulus; the movie keeps 12 s and stays in sync
```

The script compiles `scripts/flash-beep.swift`, which flashes a full-screen window white with a simultaneous beep once a second. It records the display and system audio, probes the movie, and fails if fewer than four flash/beep pairs are found or if the mean offset falls outside the ITU-R BT.1359 detectability window (audio up to 45 ms early or 125 ms late). The movie, logs and probe report stay in the printed evidence directory.

On Windows the equivalent is `scripts/e2e-live-audio.ps1` (set `$env:REC_E2E_MIC='1'` to add the microphone). Its stimulus, `scripts/flash-beep.ps1`, drives the flash from the audio device's play position.

```sh
./scripts/smoke.sh
REC_E2E_CAPTURE=1 ./scripts/smoke.sh
```

```powershell
.\scripts\smoke.ps1                              # Windows: same checks through Media Foundation
$env:REC_E2E_CAPTURE='1'; .\scripts\smoke.ps1    # also a real display capture
```

The first command builds, encodes real synthetic H.264 and HEVC movies through VideoToolbox, and decodes them through AVFoundation. It checks timestamp ordering, frame count and codec. It also checks track layouts (single, mix + stems, stems, mix only), that the flash/beep offset in the decoded file is within 20 ms, and that `--system-audio-offset-ms 100` moves audio 100 ms later. The second command additionally captures a real screen with Screen Recording permission. CI publishes the synthetic movies and probe reports as a downloadable workflow artifact. These checks are not a substitute for live-capture sync and performance measurements.

## Windows measurements

One run each on a Windows 11 (26200) PC with an RTX 5070 Ti driving a 3840x2160 display. These are single runs, not paired benchmarks against rec-rs.

| Check | Result |
| --- | --- |
| `scripts/smoke.ps1` with `REC_E2E_CAPTURE=1` | Passed: synthetic offset ≤ 10.8 ms, 100 ms offset flag measured 100.2 ms, 1/2/3-track layouts, HEVC, real 3 s capture with 90/90 frames |
| `scripts/e2e-live-audio.ps1` (display + system audio) | 7 flash/beep pairs, mean −12.8 ms, worst 13.3 ms; 720/720 frames, 0 dropped |
| Same with `REC_E2E_MIC=1` | 3 audio tracks, 7 pairs, mean −11.9 ms, worst 17.2 ms; 0 dropped |
| After pause/resume and fragmented MP4, display + system audio | 7 pairs, mean −22.2 ms, worst 22.5 ms; 720/720 frames |
| Same with `REC_E2E_MIC=1 REC_E2E_PAUSE=1` (2 s pause mid-stimulus) | 720/720 frames, 12.01 s of audio on 3 tracks, 7 pairs, mean −24.8 ms, worst 27.9 ms; 0 dropped |
| Hard kill 4 s into an H.264 recording (`smoke.ps1`) | File decodes: 90 frames, 3 flash/beep pairs within 10.8 ms |
| 15 s, 1080p60 H.264, system audio + mic | 900/900 frames; 1.1–2.0 s CPU total (7–13% of one core); peak working set 119 MB |
| 15 s, native 4K60 HEVC, system audio | 900/900 frames; 0.9–1.0 s CPU total (about 6% of one core); peak working set 116 MB |
| `rec.exe` size | 150 KB |

Most of the working set and private memory belongs to the GPU driver's Direct3D allocations, not recorder buffers.

## Current limits

- Capture is display-only.
- Pausing a live recording on macOS cuts audio per capture buffer (about 10–20 ms), so a sound that spans the pause can leave up to one buffer at the cut. Windows cuts at the exact sample. Neither has been tested with a sound playing at the pause instant.
- Windows HEVC recordings are not crash-safe (see above).
- Windows loopback captures the default output device. rec plays silence on it while recording so the audio clock keeps moving when nothing else plays.
- The output latency is read once, when recording starts. Switching output devices mid-recording keeps the old offset.
- A microphone that is not 48 kHz is resampled linearly per buffer for the mix. Its stem is converted by AVFoundation.
- The file writer retries transient encoder backpressure for up to 500 ms per timestamp. Overload beyond that deadline may drop frames; drops are counted and must be evaluated under stress.
- ScreenCaptureKit performs scaling for non-native output. GPU Lanczos quality is future work.
- Capturing and encoding with macOS cannot be verified on a Linux host. See the CI workflow for the macOS and Windows build and smoke gates. GPU-less CI runners may lack an HEVC encoder; the Windows smoke reports that case as skipped.
- There are no credible CPU, RAM, binary-size or quality comparisons with rec-rs yet.

See [the parity and E2E acceptance tracker](docs/parity.md) for the remaining features and evidence required before release. Architecture rules and studied references are in [AGENTS.md](AGENTS.md).
