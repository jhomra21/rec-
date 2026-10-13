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

"$rec" --help | grep -q 'native macOS screen recorder'
if "$rec" record --fps invalid >"$tmp/invalid.stdout" 2>"$tmp/invalid.stderr"; then
  echo 'invalid fps was accepted' >&2; exit 1
fi
grep -q 'fps must be' "$tmp/invalid.stderr"
if "$rec" record --resolution gigantic >"$tmp/invalid.stdout" 2>"$tmp/invalid.stderr"; then
  echo 'invalid resolution was accepted' >&2; exit 1
fi
grep -q 'resolution must be' "$tmp/invalid.stderr"

if [[ "$(uname -s)" != Darwin ]]; then
  if "$rec" devices >"$tmp/device.stdout" 2>"$tmp/device.stderr"; then
    echo 'unsupported platform unexpectedly returned displays' >&2; exit 1
  fi
  grep -q 'requires macOS' "$tmp/device.stderr"
else
  # Hardware encode and AVFoundation decode without screen permissions.
  "$rec" record --test-pattern -r 1080p -f 30 -t 2 --codec h264 -o "$artifacts/h264.mov" | tee "$artifacts/h264.record.log"
  "$rec" probe "$artifacts/h264.mov" | tee "$artifacts/h264.probe"
  grep -qx 'codec=h264' "$artifacts/h264.probe"
  grep -qx 'width=1920' "$artifacts/h264.probe"
  grep -qx 'height=1080' "$artifacts/h264.probe"
  grep -qx 'frames=60' "$artifacts/h264.probe"
  grep -q 'written 60, dropped 0' "$artifacts/h264.record.log"

  "$rec" record --test-pattern -r 1080p -f 30 -t 1 --codec hevc -o "$artifacts/hevc.mp4" | tee "$artifacts/hevc.record.log"
  "$rec" probe "$artifacts/hevc.mp4" | tee "$artifacts/hevc.probe"
  grep -qx 'codec=hevc' "$artifacts/hevc.probe"
  grep -qx 'frames=30' "$artifacts/hevc.probe"
  grep -q 'written 30, dropped 0' "$artifacts/hevc.record.log"

  if "$rec" record --test-pattern -t 1 -o "$artifacts/h264.mov" >"$tmp/overwrite.stdout" 2>"$tmp/overwrite.stderr"; then
    echo 'existing recording was overwritten' >&2; exit 1
  fi
  grep -q 'already exists' "$tmp/overwrite.stderr"
  "$rec" probe "$artifacts/h264.mov" | grep -qx 'frames=60'

  if [[ "${REC_E2E_CAPTURE:-0}" == 1 ]]; then
    "$rec" record --display 1 -r 1080p -f 30 -t 3 --codec h264 -o "$artifacts/screen.mov" | tee "$artifacts/screen.record.log"
    "$rec" probe "$artifacts/screen.mov" | tee "$artifacts/screen.probe"
    grep -qx 'codec=h264' "$artifacts/screen.probe"
    grep -qx 'frames=90' "$artifacts/screen.probe"
  fi
fi
echo 'smoke passed'
