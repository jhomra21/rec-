#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || { echo 'live audio E2E requires macOS' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'python3 is required for the audio stimulus' >&2; exit 1; }
command -v afplay >/dev/null || { echo 'afplay is required for system audio playback' >&2; exit 1; }

root="$(cd "$(dirname "$0")/.." && pwd)"
artifacts="${REC_E2E_ARTIFACT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/rec-live-audio.XXXXXX")}"
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

# A deterministic two-second WAV stimulus, played from a separate process so
# ScreenCaptureKit excludes only rec's own sounds, not this test's playback.
python3 - "$artifacts/stimulus.wav" <<'PY'
import math
import struct
import sys
import wave

rate = 48000
with wave.open(sys.argv[1], "wb") as wav:
    wav.setnchannels(2)
    wav.setsampwidth(2)
    wav.setframerate(rate)
    frames = bytearray()
    for n in range(rate * 2):
        pulse = (n % (rate // 2)) < (rate // 8)
        sample = int(10000 * math.sin(2 * math.pi * 440 * n / rate)) if pulse else 0
        frames += struct.pack("<hh", sample, sample)
    wav.writeframes(frames)
PY

echo "Saving recordings and evidence to: $artifacts"
"$rec" record --display 1 --system-audio -r 1080p -f 30 -t 8 \
    --codec h264 -o "$artifacts/recording.mov" >"$artifacts/record.log" 2>&1 &
capture_pid="$!"

# Allow the recorder to establish its screen/audio stream and first video frame.
sleep 3
if ! kill -0 "$capture_pid" 2>/dev/null; then
  wait "$capture_pid" || true
  echo "Recording stopped before audio playback; see $artifacts/record.log" >&2
  exit 1
fi

afplay "$artifacts/stimulus.wav"
wait "$capture_pid" || { echo "Recorder failed; see $artifacts/record.log" >&2; exit 1; }
capture_pid=""

"$rec" probe "$artifacts/recording.mov" | tee "$artifacts/recording.probe"
grep -qx 'codec=h264' "$artifacts/recording.probe"
grep -qx 'audio_codec=aac' "$artifacts/recording.probe"
awk -F= '/^audio_buffers=/ { if ($2 + 0 > 0) found=1 } END { exit !found }' "$artifacts/recording.probe"

echo "Live system audio captured and decoded. Inspect A/V timing and audio completeness:"
echo "$artifacts"
