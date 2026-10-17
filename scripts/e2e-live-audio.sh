#!/usr/bin/env bash
# Live A/V sync acceptance on a Mac with Screen Recording permission and audible output.
# A full-screen window flashes white with a simultaneous beep once a second while rec
# records the display and system audio; rec probe then measures the offset in the file.
# REC_E2E_MIC=1 also records the default microphone (mix + stems).
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo 'live A/V sync E2E requires macOS' >&2; exit 1; }
command -v swiftc >/dev/null || { echo 'swiftc (Xcode command line tools) is required' >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts="${REC_E2E_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/rec-live-sync.XXXXXX")}"
mkdir -p "$artifacts"
capture_pid=""
cleanup() {
  if [[ -n "$capture_pid" ]] && kill -0 "$capture_pid" 2>/dev/null; then
    kill -TERM "$capture_pid" || true
    wait "$capture_pid" || true
  fi
}
trap cleanup EXIT

cmake -S "$root" -B "$root/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$root/build" --parallel
rec="$root/build/rec"
swiftc -O "$root/scripts/flash-beep.swift" -o "$artifacts/flash-beep"

args=(record --display 1 --system-audio -r 1080p -f 60 -t 12 --codec h264 -o "$artifacts/recording.mov")
if [[ "${REC_E2E_MIC:-0}" == 1 ]]; then args+=(--mic default); fi

echo "Saving recordings and evidence to: $artifacts"
"$rec" devices | tee "$artifacts/devices.txt"
"$rec" "${args[@]}" >"$artifacts/record.log" 2>&1 &
capture_pid="$!"

# Allow the recorder to establish its screen/audio stream and first video frame.
sleep 3
if ! kill -0 "$capture_pid" 2>/dev/null; then
  wait "$capture_pid" || true
  echo "Recording stopped before the stimulus; see $artifacts/record.log" >&2
  exit 1
fi

# Separate process: ScreenCaptureKit excludes only rec's own audio.
"$artifacts/flash-beep" 6 >"$artifacts/stimulus.log" 2>&1
wait "$capture_pid" || { echo "Recorder failed; see $artifacts/record.log" >&2; exit 1; }
capture_pid=""

"$rec" probe "$artifacts/recording.mov" | tee "$artifacts/recording.probe"
value() { awk -F= -v key="$1" '$1 == key { print $2 }' "$artifacts/recording.probe"; }
grep -qx 'codec=h264' "$artifacts/recording.probe"
grep -qx 'audio_codec=aac' "$artifacts/recording.probe"
if [[ "${REC_E2E_MIC:-0}" == 1 ]]; then grep -qx 'audio_tracks=3' "$artifacts/recording.probe"; fi
events="$(value av_sync_events)"
offset="$(value av_offset_ms)"
worst="$(value av_offset_max_ms)"
awk -v n="$events" 'BEGIN { exit !(n >= 4) }' || { echo "only $events flash/beep pairs found" >&2; exit 1; }
# ITU-R BT.1359 detectability: audio more than 45 ms early or 125 ms late.
awk -v m="$offset" 'BEGIN { exit !(m >= -45 && m <= 125) }' || { echo "A/V offset $offset ms is noticeable" >&2; exit 1; }

echo "Live A/V sync: $events flash/beep pairs, mean offset $offset ms (positive = audio late), worst $worst ms."
echo "Evidence: $artifacts"
