#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
fi
if [[ "${REC_E2E_CAPTURE:-0}" == 1 ]]; then
  [[ "$(uname -s)" == Darwin ]] || { echo 'screen capture E2E requires macOS' >&2; exit 1; }
  "$rec" record --display 1 -r 1080p -f 30 -t 3 --codec h264 -o "$tmp/demo.mov"
  [[ -s "$tmp/demo.mov" ]] || { echo 'missing recording output' >&2; exit 1; }
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,nb_frames \
      -of default=noprint_wrappers=1 "$tmp/demo.mov" | tee "$tmp/probe.txt"
    grep -q '^codec_name=h264$' "$tmp/probe.txt"
    grep -q '^nb_frames=90$' "$tmp/probe.txt"
  fi
fi
echo 'smoke passed'
