#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
artifacts="${REC_E2E_ARTIFACT_DIR:-$tmp}"
mkdir -p "$artifacts"

cmake -S "$root" -B "$tmp/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "$tmp/build" --parallel
rec="$tmp/build/rec"

# expect_failure PATTERN ARGS...: the command must fail and print PATTERN.
expect_failure() {
  local pattern="$1"; shift
  if "$rec" "$@" >"$tmp/failure.stdout" 2>"$tmp/failure.stderr"; then
    echo "accepted: rec $*" >&2; exit 1
  fi
  grep -q -- "$pattern" "$tmp/failure.stderr" || { cat "$tmp/failure.stderr" >&2; exit 1; }
}
# value KEY FILE: a key=value field from a probe report.
value() { awk -F= -v key="$1" '$1 == key { print $2 }' "$2"; }
# within VALUE LOW HIGH
within() {
  awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v != "" && v + 0 >= lo && v + 0 <= hi) }' \
    || { echo "$1 is outside [$2, $3]" >&2; exit 1; }
}

"$rec" --help | grep -q 'native macOS screen recorder'
expect_failure 'fps must be' record --fps invalid
expect_failure 'resolution must be' record --resolution gigantic
expect_failure 'requires --test-pattern' record --test-tone
expect_failure 'requires --test-pattern' record --test-mic
expect_failure 'needs a real screen' record --test-pattern --system-audio
expect_failure 'needs a real screen' record --test-pattern --mic default
expect_failure 'audio tracks must be' record --audio-tracks surround
expect_failure 'gain must be' record --mic-gain 99
expect_failure 'offset must be' record --system-audio-offset-ms 5000

if [[ "$(uname -s)" != Darwin ]]; then
  expect_failure 'requires macOS' devices
else
  # The live A/V sync stimulus must at least compile.
  swiftc -typecheck "$root/scripts/flash-beep.swift"

  # Hardware encode and AVFoundation decode without screen permissions.
  "$rec" record --test-pattern -r 1080p -f 30 -t 2 --codec h264 -o "$artifacts/h264.mov" | tee "$artifacts/h264.record.log"
  "$rec" probe "$artifacts/h264.mov" | tee "$artifacts/h264.probe"
  grep -qx 'codec=h264' "$artifacts/h264.probe"
  grep -qx 'width=1920' "$artifacts/h264.probe"
  grep -qx 'height=1080' "$artifacts/h264.probe"
  grep -qx 'frames=60' "$artifacts/h264.probe"
  grep -qx 'audio_tracks=0' "$artifacts/h264.probe"
  grep -q 'written 60, dropped 0' "$artifacts/h264.record.log"

  # Flash + beep through the AAC writer: measured A/V offset in the decoded file.
  "$rec" record --test-pattern --test-tone -r 1080p -f 30 -t 2 --codec h264 -o "$artifacts/av.mov" | tee "$artifacts/av.record.log"
  "$rec" probe "$artifacts/av.mov" | tee "$artifacts/av.probe"
  grep -qx 'codec=h264' "$artifacts/av.probe"
  grep -qx 'frames=60' "$artifacts/av.probe"
  grep -qx 'audio_tracks=1' "$artifacts/av.probe"
  grep -qx 'audio_codec=aac' "$artifacts/av.probe"
  grep -q 'written 60, dropped 0' "$artifacts/av.record.log"
  within "$(value audio_duration "$artifacts/av.probe")" 1.95 2.05
  within "$(value av_sync_events "$artifacts/av.probe")" 2 2
  within "$(value av_offset_max_ms "$artifacts/av.probe")" 0 20

  # A system-audio offset moves audio later by exactly that much.
  "$rec" record --test-pattern --test-tone --system-audio-offset-ms 100 -f 30 -t 2 -o "$artifacts/offset.mov" | tee "$artifacts/offset.record.log"
  "$rec" probe "$artifacts/offset.mov" | tee "$artifacts/offset.probe"
  within "$(value av_sync_events "$artifacts/offset.probe")" 2 2
  within "$(value av_offset_ms "$artifacts/offset.probe")" 80 120

  # Mixer: default track is the system + mic mix, followed by both stems.
  "$rec" record --test-pattern --test-tone --test-mic -f 30 -t 2 -o "$artifacts/mix.mov" | tee "$artifacts/mix.record.log"
  "$rec" probe "$artifacts/mix.mov" | tee "$artifacts/mix.probe"
  grep -qx 'audio_tracks=3' "$artifacts/mix.probe"
  grep -qx 'audio_codec=aac' "$artifacts/mix.probe"
  grep -q 'Mix buffers written' "$artifacts/mix.record.log"
  grep -q 'written 60, dropped 0' "$artifacts/mix.record.log"
  within "$(value audio_duration "$artifacts/mix.probe")" 1.95 2.05
  within "$(value av_sync_events "$artifacts/mix.probe")" 2 2
  within "$(value av_offset_max_ms "$artifacts/mix.probe")" 0 20

  "$rec" record --test-pattern --test-tone --test-mic --audio-tracks stems -f 30 -t 1 -o "$artifacts/stems.mp4" | tee "$artifacts/stems.record.log"
  "$rec" probe "$artifacts/stems.mp4" | tee "$artifacts/stems.probe"
  grep -qx 'audio_tracks=2' "$artifacts/stems.probe"
  "$rec" record --test-pattern --test-tone --test-mic --audio-tracks mix -f 30 -t 1 -o "$artifacts/mixonly.mov" | tee "$artifacts/mixonly.record.log"
  "$rec" probe "$artifacts/mixonly.mov" | tee "$artifacts/mixonly.probe"
  grep -qx 'audio_tracks=1' "$artifacts/mixonly.probe"

  "$rec" record --test-pattern -r 1080p -f 30 -t 1 --codec hevc -o "$artifacts/hevc.mp4" | tee "$artifacts/hevc.record.log"
  "$rec" probe "$artifacts/hevc.mp4" | tee "$artifacts/hevc.probe"
  grep -qx 'codec=hevc' "$artifacts/hevc.probe"
  grep -qx 'frames=30' "$artifacts/hevc.probe"
  grep -q 'written 30, dropped 0' "$artifacts/hevc.record.log"

  expect_failure 'already exists' record --test-pattern -t 1 -o "$artifacts/h264.mov"
  "$rec" probe "$artifacts/h264.mov" | grep -qx 'frames=60'

  if [[ "${REC_E2E_CAPTURE:-0}" == 1 ]]; then
    "$rec" record --display 1 -r 1080p -f 30 -t 3 --codec h264 -o "$artifacts/screen.mov" | tee "$artifacts/screen.record.log"
    "$rec" probe "$artifacts/screen.mov" | tee "$artifacts/screen.probe"
    grep -qx 'codec=h264' "$artifacts/screen.probe"
    grep -qx 'frames=90' "$artifacts/screen.probe"
  fi
fi
echo 'smoke passed'
