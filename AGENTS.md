# rec- engineering notes

## Scope

Build a compact macOS recorder. Keep the recording engine usable from C++ without the CLI or a GUI. The current implementation captures one display, system audio and a microphone with ScreenCaptureKit and writes H.264 or HEVC video plus AAC audio (a mix and per-source stems) with AVAssetWriter. The product goal is full feature parity with rec-rs, including audio, camera, scenes, replay, streaming, and a native UI. Track implemented, verified, and missing behavior separately in `docs/parity.md`. Do not imply parity from a compiled interface.

## Decisions

- Use C++20. Limit Objective-C++ to Apple framework adapters in `src/platform/macos/`.
- The public object API is `rec::Recorder` with `start()`, `stop()`, `finished()`, `stats()`, and `failure()`. The CLI calls the same API.
- Keep capture callbacks free of encoding, blocking I/O, and allocations except retaining the delivered buffer.
- Stamp every source on the host clock. Video is written on an exact 1/fps grid, emitted 40 ms behind real time so each slot uses the frame that was on screen at that instant. The engine holds at most three pending surfaces plus the current one (SCK `queueDepth` 6). Use VideoToolbox via AVAssetWriter.
- Audio sources use fixed 16-buffer queues that drop the oldest on overflow. The recording thread drains them, including while it waits for video backpressure, because AVAssetWriter interleaves inputs. The mixer owns a 2-second timeline and is allocated only when two sources are mixed. Add other queues only for a demonstrated need, with explicit size and overload behavior.
- Expose errors at the API boundary. No exceptions across the Apple callback boundary.
- Prefer Apple frameworks and the C++ standard library. Do not add FFmpeg, Qt, Electron, or a plugin framework by default.
- Verify end-to-end output files on macOS before claiming recording quality or performance. Linux builds exercise the CLI and unsupported-platform contract only.
- Do not write unit tests. Use end-to-end capture and output verification for behavior; retain output recordings and probe results as reproducible CI artifacts.
- Keep benchmarks reproducible: same machine, same screen content, codec, output frame rate, resolution, and recording duration. Include encoder backpressure and memory samples.
- Add an abstraction only when a concrete second implementation needs it.
- The native interface should feel joyful, clear and responsive: one-step recording, obvious status, accessible controls, and no hidden-preview background rendering. Keep the recording core independent from UI lifecycles.

## Reference codebases

Use these projects to understand patterns and tradeoffs, not as templates to copy.

- `michaelshimeles/rec-rs`: ScreenCaptureKit frame handling, timing, AVAssetWriter output, A/V synchronization, replay and streaming requirements. Study its tests and `PERFORMANCE.md` before changing output semantics.
- `obsproject/obs-studio`: separation of capture sources and outputs, texture lifetime, device changes, bounded queues, and encoder backpressure. Follow the architecture, not the plugin surface or GPL source code.
- `jhomra21/daw-browser-convex`: native C++ ownership, realtime callback discipline, and isolation of runtime from UI.
- `jhomra21/bgcut`: object-oriented public APIs, dependency direction, no speculative package splitting, and observable E2E acceptance.

- `anomalyco/opencode` (OpenCode v2): package and domain ownership, Solid application structure, service boundaries, persistence, command/action design, and keeping UI state separate from lower-level runtime services.
- `earendil-works/pi` (Pi): narrow interfaces, small composable building blocks, direct code, package boundaries, and avoiding unnecessary abstraction.
- `diffusionstudio/editor` (Diffusion Studio), plus authorized `monorepo-new` when available: editor architecture, media/application boundaries, worker and background processing, and larger product organization.
- `joshpuckett/dialkit` (DialKit): fine-grained interactive controls, parameter editing, reactive UI APIs, and small composable building blocks.
- `solidjs-community/solid-primitives` (Solid Primitives): Solid API design, browser behavior, storage/persistence, lifecycle and cleanup, and package-local ownership.
- `anomalyco/opentui` (OpenTUI): explicit command/result contracts, keyboard and interaction ownership, renderer/core separation, package APIs, and cleanup behavior in interactive systems.

These are references, not dependencies. Record the upstream revision when copying a precise behavior or benchmark. Do not copy incompatible licensed source.

## Layout

- `include/rec/`: public C++ API.
- `src/`: command-line frontend.
- `src/platform/macos/`: Apple capture, timing and encoding adapter.
- `src/platform/unsupported.cpp`: clear error on non-macOS hosts.
- `scripts/`: build and end-to-end smoke runs.
- `.github/workflows/`: native macOS build and capture-independent smoke gate.
