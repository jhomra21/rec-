# rec-rs parity and E2E acceptance

Full parity with `michaelshimeles/rec-rs` is the product goal. This is a living acceptance inventory, not a list of implemented features. A feature is **verified** only after running it end to end on the named platform (macOS is primary; Windows is tracked alongside) and inspecting the saved result or observable behavior. Do not check off a feature because it compiles or because an internal helper succeeds.

## Capture and output

| Capability | State | Required acceptance |
| --- | --- | --- |
| Display capture | macOS: implemented, real-capture verification pending. Windows: verified (WGC, 4K display at 30/60 fps, 0 drops) | 30/60 fps on physical display, correct dimensions and output frames |
| Window capture | Missing | Resize, occlusion, title/ID selection, minimize/reopen |
| Region capture | Missing | Retina coordinate mapping, crop boundaries, no stretching |
| Native resolution and presets | Implemented, quality unverified | Native/1080p/1440p/4K on 16:9 and 16:10 displays |
| 24/25/30/50/60/120 fps | Implemented, real-capture verification pending | Exact frame grid, refresh-rate/encoder limits handled |
| H.264/HEVC MOV/MP4 | Synthetic E2E verified on macOS; synthetic and live verified on Windows (Media Foundation, ISO MP4 structure for .mov) | Encode, finalize, full decode and frame-count verification |
| ProRes 422 | Missing | MOV, quality and file-size inspection |
| GPU Lanczos scaling | Missing | Native 5K capture vs output, GPU residency, image-quality comparison |
| System audio | macOS: SCK capture with output-latency offset, live sync unverified on a permissioned Mac. Windows: WASAPI loopback, live flash/beep mean −12.8 ms, worst 13.3 ms | `scripts/e2e-live-audio.sh` / `.ps1`: flash/beep offset within ITU window; drift, overload, sleep and device changes |
| Microphone | macOS: SCK capture (macOS 15), device selection, unverified on a permissioned Mac. Windows: WASAPI capture, live 3-track run verified (USB interface, 0 drops) | `REC_E2E_MIC=1` live script; mono/stereo input, 44.1 kHz device, disconnect/reconnect |
| Mixed audio and separate stems | Synthetic mix + stems verified on macOS and Windows; live mix verified on Windows | Gain, limiter, offsets, gap handling verified live; tracks import into an editor |
| Single-clock A/V sync | Implemented on both: timestamp-accurate CFR grid, host-clock audio; synthetic offset < 20 ms; Windows live 12 s within 17.2 ms | Live flash/beep offset on macOS, 30-minute drift |
| Camera capture and overlays | Missing | Cold-start exposure, device selection, hot-plug, masks and transforms |
| Pause/resume | Missing | Video and audio timelines remain gapless through repeated pauses |
| Fragmented/crash-safe output | Missing | Kill mid-write, playable fragments, normal finalization |
| Cursor and click indicators | Partial | Cursor visible/hidden, scale and click overlay |
| Synthetic video + tone E2E | Passed on macOS CI; passed locally on Windows | Encoded movies + complete decoder probe saved as CI artifacts |
| Synthetic flash/beep sync, mixer and track layouts | Passed on macOS CI; passed locally on Windows | Measured offset, offset flag, 1/2/3-track layouts in decoded files |

## Replay and live output

| Capability | State | Required acceptance |
| --- | --- | --- |
| Replay buffer (15–300 s) | Missing | Keyframe-safe save without stopping the capture |
| RTMP and RTMPS | Missing | Authentication, reconnect, 4K stream, keyframe timing |
| WHIP/WebRTC | Missing | Server handshake, ICE/DTLS/SRTP, A/V sync, cleanup |
| Shared live encoder | Missing | Replay and simultaneous streams share one encode |
| Stream keys in Keychain | Missing | No keys in logs/settings, revoke and replace |
| Capture survives GUI close | Missing | Recording, replay and streams continue headless |

## Application experience

| Capability | State | Required acceptance |
| --- | --- | --- |
| Native app and live preview | Missing | Composited preview matches export, minimal idle work |
| Scene presets and switching | Missing | Screen, screen+cam and camera switching without stopping |
| Floating camera layout controls | Missing | Drag/snap, circle/rounded/square/pill/squircle, border/shadow |
| Audio meters | Missing | Per-source peak meters, no render work while hidden |
| CLI recording status | Implemented (TTY only) | Elapsed time and drops visible while recording |
| Menu bar and Dock behavior | Missing | Start/pause/stop/save/quit, finalized file on exit |
| Global hotkeys | Missing | Registered/unregistered safely, conflicts visible |
| Settings persistence | Missing | No recording corruption on invalid/stale settings |
| Device/permission diagnostics | Partial | Useful errors and permission recovery in the app |
| File reveal and quick actions | Missing | One-click reveal, last recording, retry, sensible paths |

## Joyful UI guidelines

- Recording status must be unmistakable. A clear timer, accessible stop control, and visible audio activity matter more than decoration.
- Show the exact output: the same composition and crop as the saved movie. No surprises when exporting.
- Make the fast path one action: choose a screen or window, record, stop, reveal.
- Keep controls responsive and keyboard-friendly. Use short, purposeful motion with a reduced-motion option. No animated UI should run while hidden.
- Treat failure as recoverable: state the missing permission or device, keep already recorded data, and give the user the next useful action.
- Do not charge memory for dormant features: inactive camera, hidden preview, replay-disabled buffer, and streaming-disabled networking must not allocate sustained runtime resources.

## Verification rules

1. CLI and native UI must call the same recorder core. Do not reimplement capture or writer logic in the frontend.
2. Prefer E2E validation; do not add unit tests. Any CI check of behavior must produce a repeatable output artifact.
3. Synthetic E2E must produce H.264 MOV and HEVC MP4, retain the files, decode every frame with the platform decoder (AVFoundation or Media Foundation), verify monotonic timestamps, frame count, codec, and no overwrite.
4. On a permissioned Mac, test real screen/window/camera/audio recordings including stop, cancellation, device unplug, sleep/wake, display change, 30-minute soak, and SIGTERM.
5. Compare against rec-rs using the same Mac, screen contents, codec, resolution, frame rate, and duration. Collect process RSS, CPU, frame drops, quality, binary and app size. Separate hardware-encoder and WindowServer resource usage from process RSS/CPU.
6. Keep this list honest. Compiler success is not recording parity; synthetic recording is not proof of ScreenCaptureKit behavior; CPU/RAM improvements are claims only after paired benchmarks.
