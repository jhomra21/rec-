# MediaMTX, a local RTMP server for the streaming E2E on macOS: pinned release,
# checksum-verified. Source this file; scripts/windows-common.ps1 has the Windows twin.
mediamtx_version=v1.21.2
mediamtx_pid=""

# get_mediamtx CACHE: downloads MediaMTX once into CACHE and prints the binary's path.
get_mediamtx() {
  local cache="$1" arch sha dir archive hash
  case "$(uname -m)" in
    arm64) arch=arm64; sha=7d0d0c5c11527cbd10bde1c3d728864eb0334a9b653566cd73c0259750cbf093 ;;
    x86_64) arch=amd64; sha=87a00062b6a588aa1158f875504a3b56c80d62e2611dc450b83d0534e1b49198 ;;
    *) echo "no MediaMTX build for $(uname -m)" >&2; return 1 ;;
  esac
  dir="$cache/mediamtx-$mediamtx_version-$arch"
  if [[ ! -x "$dir/mediamtx" ]]; then
    mkdir -p "$dir"
    archive="$dir/mediamtx.tar.gz"
    curl -fsSL -o "$archive" \
      "https://github.com/bluenviron/mediamtx/releases/download/$mediamtx_version/mediamtx_${mediamtx_version}_darwin_$arch.tar.gz"
    hash="$(shasum -a 256 "$archive" | awk '{ print $1 }')"
    if [[ "$hash" != "$sha" ]]; then
      rm -f "$archive"
      echo "MediaMTX download checksum mismatch: $hash" >&2
      return 1
    fi
    tar -xzf "$archive" -C "$dir" mediamtx
    rm -f "$archive"
  fi
  echo "$dir/mediamtx"
}

# start_mediamtx BINARY RECORDINGS WORK: serves RTMP only on 127.0.0.1:1935 and records
# every published stream as fragmented MP4 under RECORDINGS.
start_mediamtx() {
  local binary="$1" recordings="$2" work="$3" attempt
  mkdir -p "$recordings" "$work"
  cat >"$work/mediamtx.yml" <<CONFIG
logLevel: info
api: no
metrics: no
pprof: no
playback: no
rtsp: no
rtmp: yes
rtmpAddress: 127.0.0.1:1935
hls: no
webrtc: no
srt: no
moq: no
pathDefaults:
  record: yes
  recordPath: $recordings/%path/%Y-%m-%d_%H-%M-%S-%f
  recordFormat: fmp4
  recordPartDuration: 1s
  recordSegmentDuration: 1h
paths:
  all_others:
CONFIG
  "$binary" "$work/mediamtx.yml" >"$work/mediamtx.log" 2>&1 &
  mediamtx_pid="$!"
  for attempt in $(seq 75); do
    if ! kill -0 "$mediamtx_pid" 2>/dev/null; then
      echo "MediaMTX exited: $(cat "$work/mediamtx.log")" >&2
      mediamtx_pid=""
      return 1
    fi
    if (exec 9<>/dev/tcp/127.0.0.1/1935) 2>/dev/null; then return 0; fi
    sleep 0.2
  done
  stop_mediamtx
  echo 'MediaMTX did not open 127.0.0.1:1935' >&2
  return 1
}

stop_mediamtx() {
  if [[ -n "$mediamtx_pid" ]]; then
    kill "$mediamtx_pid" 2>/dev/null || true
    wait "$mediamtx_pid" 2>/dev/null || true
    mediamtx_pid=""
  fi
}
