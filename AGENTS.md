# rec- engineering notes

## Scope

Build a compact macOS recorder. Keep the recording engine usable from C++ without the CLI or a GUI. The first implementation captures one display and writes H.264 or HEVC video using ScreenCaptureKit and AVAssetWriter. Audio, window capture, camera compositing, replay, and streaming are future work, not implied by the current API.

## Decisions

- Use C++20. Limit Objective-C++ to Apple framework adapters in `src/platform/macos/`.
- The public object API is `rec::Recorder` with `start()`, `stop()`, `finished()`, `stats()`, and `failure()`. The CLI calls the same API.
- Keep the capture callback free of encoding, blocking I/O, and allocations except retaining the delivered pixel buffer.
- Own at most one latest captured surface in the engine. Use VideoToolbox via AVAssetWriter. Add queues only for a demonstrated need, with explicit size and overload behavior.
- Expose errors at the API boundary. No exceptions across the Apple callback boundary.
- Prefer Apple frameworks and the C++ standard library. Do not add FFmpeg, Qt, Electron, or a plugin framework by default.
- Verify end-to-end output files on macOS before claiming recording quality or performance. Linux builds exercise the CLI and unsupported-platform contract only.
- Do not write unit tests. Use end-to-end capture and output verification for behavior.
- Keep benchmarks reproducible: same machine, same screen content, codec, output frame rate, resolution, and recording duration. Include encoder backpressure and memory samples.
- Add an abstraction only when a concrete second implementation needs it.

## Reference codebases

- `michaelshimeles/rec-rs`: ScreenCaptureKit frame handling, timing, AVAssetWriter output, A/V synchronization, replay and streaming requirements. Study its tests and `PERFORMANCE.md` before changing output semantics.
- `obsproject/obs-studio`: separation of capture sources and outputs, texture lifetime, device changes, bounded queues, and encoder backpressure. Follow the architecture, not the plugin surface or GPL source code.
- `jhomra21/daw-browser-convex`: native C++ ownership, realtime callback discipline, and isolation of runtime from UI.
- `jhomra21/bgcut`: object-oriented public APIs, dependency direction, no speculative package splitting, and observable E2E acceptance.

These are references, not dependencies. Record the upstream revision when copying a precise behavior or benchmark. Do not copy incompatible licensed source.

## Layout

- `include/rec/`: public C++ API.
- `src/`: command-line frontend.
- `src/platform/macos/`: Apple capture, timing and encoding adapter.
- `src/platform/unsupported.cpp`: clear error on non-macOS hosts.
- `scripts/`: build and end-to-end smoke runs.
- `.github/workflows/`: native macOS build and capture-independent smoke gate.
