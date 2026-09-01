#!/bin/bash
# Repeatable release-build CPU and memory benchmark for steady-state idle and
# playback. Every case gets a fresh process, fake library, fake iPod, defaults
# suite and app-data directory. Playback starts through a launch-only benchmark
# hook so accessibility/UI automation cannot contaminate the measurement.
#
# Memory is sampled once per second across the sample window and averaged, so
# a single track-change transient cannot dominate a case. The app reports its
# window occlusion state to a file each case; visible cases fail loudly if any
# window is covered (a stray window over the app flips it into the cheap
# hidden-rendering path and corrupts results by >100 MiB) and obscured cases
# fail loudly if the cover did not actually cover.
#
# PERFORMANCE_BENCHMARK_TIMELINE=1 prints every per-second sample and dumps the
# footprint category breakdown when a sample spikes above the case minimum.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
WARMUP_SECONDS="${PERFORMANCE_BENCHMARK_WARMUP_SECONDS:-10}"
SAMPLE_SECONDS="${PERFORMANCE_BENCHMARK_SAMPLE_SECONDS:-20}"
CASES="${PERFORMANCE_BENCHMARK_CASES:-all}"
TIMELINE="${PERFORMANCE_BENCHMARK_TIMELINE:-0}"
SPIKE_DUMP_BYTES=$((50 * 1048576))
BENCHMARK_SWIFT_FLAGS=(-Xswiftc -DNIGHTDRIVE_PERFORMANCE_BENCHMARK)
# seed-demo and the visualizers subcommand are development-tools-only code;
# debug builds define the flag via Package.swift, release builds need it passed.
if [[ "$CONFIG" == "release" ]]; then
  BENCHMARK_SWIFT_FLAGS+=(-Xswiftc -DNIGHTDRIVE_DEVELOPMENT_TOOLS)
fi
RUN_ROOT=".scratch/performance-benchmark-$$"
COVER_BIN="$RUN_ROOT/performance-benchmark-cover"
COVER_READY="$RUN_ROOT/cover-ready"
DEMO_LIBRARY="$RUN_ROOT/library"
DEMO_IPOD="$RUN_ROOT/ipod"
BIN=""
APP_PID=""
COVER_PID=""
OCCLUSION_FILE=""
SUITES=()

cleanup_processes() {
  if [[ -n "$COVER_PID" ]]; then
    kill "$COVER_PID" 2>/dev/null || true
    wait "$COVER_PID" 2>/dev/null || true
    COVER_PID=""
  fi
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
  fi
}

cleanup() {
  cleanup_processes
  for suite in ${SUITES[@]+"${SUITES[@]}"}; do
    defaults delete "$suite" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$suite.plist"
  done
  rm -rf "$RUN_ROOT"
}
trap cleanup EXIT

if find /Volumes -mindepth 2 -maxdepth 2 -type d -name iPod_Control -print -quit \
  | grep -q .; then
  echo "FAIL: a real mounted iPod may be present; refusing to run an automated benchmark" >&2
  exit 1
fi

if stale="$(pgrep -lx Nightdrive)"; then
  if [[ "${PERFORMANCE_BENCHMARK_ALLOW_RUNNING:-0}" = 1 ]]; then
    echo "WARN: Nightdrive is already running; continuing because" >&2
    echo "PERFORMANCE_BENCHMARK_ALLOW_RUNNING=1. Occlusion verification will" >&2
    echo "fail the run if these instances cover the benchmark windows:" >&2
    printf '%s\n' "$stale" >&2
  else
    echo "FAIL: Nightdrive is already running; a stale instance can cover the" >&2
    echo "benchmark windows and corrupt visible-case results. Quit or kill these" >&2
    echo "instances yourself first (this script never kills processes it did not start)," >&2
    echo "or rerun with PERFORMANCE_BENCHMARK_ALLOW_RUNNING=1 to rely on the in-app" >&2
    echo "occlusion check instead:" >&2
    printf '%s\n' "$stale" >&2
    exit 1
  fi
fi

mkdir -p "$RUN_ROOT"

echo "== performance benchmark: building $CONFIG binary =="
node scripts/run-swiftpm.mjs build -c "$CONFIG" "${BENCHMARK_SWIFT_FLAGS[@]}"
BUILD_PRODUCTS_DIR="$(
  node scripts/run-swiftpm.mjs build -c "$CONFIG" \
    "${BENCHMARK_SWIFT_FLAGS[@]}" --show-bin-path
)"
BIN="$BUILD_PRODUCTS_DIR/Nightdrive"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: SwiftPM did not produce an executable at $BIN" >&2
  exit 1
fi

xcrun swiftc -parse-as-library -O scripts/idle-benchmark-cover.swift -o "$COVER_BIN"
"$BIN" seed-demo "$DEMO_LIBRARY" "$DEMO_IPOD" >/dev/null

cpu_seconds() {
  ps -p "$1" -o time= | awk '
    {
      count = split($0, parts, ":")
      seconds = 0
      for (i = 1; i <= count; i++) seconds = seconds * 60 + parts[i]
      printf "%.2f", seconds
    }
  '
}

memory_footprint() {
  local output footprint peak
  output="$(footprint -p "$1" -f bytes --noCategories 2>/dev/null || true)"
  footprint="$(printf '%s\n' "$output" | awk '/phys_footprint:/ { print $2; exit }')"
  peak="$(printf '%s\n' "$output" | awk '/phys_footprint_peak:/ { print $2; exit }')"
  if [[ -z "$footprint" ]]; then
    footprint="$(ps -p "$1" -o rss= | awk '{ print $1 * 1024 }')"
  fi
  if [[ -z "$peak" ]]; then
    peak="$footprint"
  fi
  printf '%s %s\n' "$footprint" "$peak"
}

# Fails the run when the app's self-reported window occlusion state does not
# match what the case is supposed to measure.
verify_occlusion() {
  local covered="$1" context="$2" visible occluded
  read -r visible occluded < <(
    sed -n '1s/[^0-9 ]//gp' "$OCCLUSION_FILE" 2>/dev/null | grep . || echo "-1 -1")
  if [[ "$visible" = -1 ]]; then
    echo "FAIL: app never reported window occlusion state ($context)" >&2
    exit 1
  fi
  if [[ "$covered" = true && "$visible" != 0 ]]; then
    echo "FAIL: $visible window(s) still visible under the cover ($context)" >&2
    exit 1
  fi
  if [[ "$covered" = false && ( "$occluded" != 0 || "$visible" = 0 ) ]]; then
    echo "FAIL: $occluded of $((visible + occluded)) app window(s) are occluded ($context);" >&2
    echo "      something is covering the benchmark app, which corrupts visible-case results" >&2
    exit 1
  fi
}

run_case() {
  local name="$1"
  local deck_open="$2"
  local covered="$3"
  local autoplay="$4"
  local suite="dev.nightdrive.performance-benchmark.$$.${name}"
  local app_data="$RUN_ROOT/app-data-$name"
  local playback_state="$RUN_ROOT/playback-$name.json"
  local playback_ready="$RUN_ROOT/playback-ready-$name"
  local visualizers="$RUN_ROOT/visualizers-$name"
  local log="$RUN_ROOT/app-$name.log"
  local before after cpu average wall_before wall_after wall
  local sample peak sum count minimum maximum spike_dumped
  local memory_before footprint range i

  SUITES+=("$suite")
  OCCLUSION_FILE="$RUN_ROOT/occlusion-$name"
  defaults write "$suite" opensDeckOnLaunch -bool "$deck_open"
  defaults write "$suite" visualizerMode -string nightdrive

  NIGHTDRIVE_LIBRARY="$PWD/$DEMO_LIBRARY" \
  NIGHTDRIVE_EXTRA_VOLUMES="$PWD/$DEMO_IPOD" \
  NIGHTDRIVE_VISUALIZER_DIR="$PWD/$visualizers" \
  NIGHTDRIVE_DEFAULTS_SUITE="$suite" \
  NIGHTDRIVE_PLAYBACK_STATE_PATH="$PWD/$playback_state" \
  NIGHTDRIVE_LOUDNESS_CACHE="$PWD/$RUN_ROOT/loudness-cache" \
  NIGHTDRIVE_APP_DATA_DIR="$PWD/$app_data" \
  NIGHTDRIVE_PERFORMANCE_BENCHMARK_AUTOPLAY="$autoplay" \
  NIGHTDRIVE_PERFORMANCE_BENCHMARK_READY_PATH="$PWD/$playback_ready" \
  NIGHTDRIVE_PERFORMANCE_BENCHMARK_OCCLUSION_PATH="$PWD/$OCCLUSION_FILE" \
  "$BIN" >"$log" 2>&1 &
  APP_PID=$!

  if [[ "$autoplay" = 1 ]]; then
    for _ in {1..150}; do
      [[ -s "$playback_ready" ]] && break
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 0.1
    done
    if ! grep -qx ready "$playback_ready" 2>/dev/null; then
      echo "FAIL: playback did not become ready for $name (see $log)" >&2
      [[ -f "$playback_ready" ]] && sed -n '1p' "$playback_ready" >&2
      exit 1
    fi
  fi

  sleep "$WARMUP_SECONDS"
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    echo "FAIL: app exited during warmup for $name (see $log)" >&2
    exit 1
  fi

  if [[ "$covered" = true ]]; then
    rm -f "$COVER_READY"
    "$COVER_BIN" >"$COVER_READY" 2>"$RUN_ROOT/cover.log" &
    COVER_PID=$!
    for _ in {1..50}; do
      [[ -s "$COVER_READY" ]] && break
      sleep 0.1
    done
    if [[ ! -s "$COVER_READY" ]]; then
      echo "FAIL: cover window did not become ready" >&2
      exit 1
    fi
    sleep 2
  fi

  read -r memory_before _ < <(memory_footprint "$APP_PID")
  verify_occlusion "$covered" "$name before sampling"
  sum=0
  count=0
  minimum=""
  maximum=""
  peak="$memory_before"
  spike_dumped=0
  [[ "$TIMELINE" = 1 ]] && echo "  timeline for $name:"
  wall_before="$(date +%s)"
  before="$(cpu_seconds "$APP_PID")"
  for ((i = 1; i <= SAMPLE_SECONDS; i++)); do
    sleep 1
    if ! kill -0 "$APP_PID" 2>/dev/null; then
      echo "FAIL: app exited during sampling for $name (see $log)" >&2
      exit 1
    fi
    read -r sample peak < <(memory_footprint "$APP_PID")
    verify_occlusion "$covered" "$name at sample ${i}s"
    sum=$((sum + sample))
    count=$((count + 1))
    if [[ -z "$minimum" || "$sample" -lt "$minimum" ]]; then minimum="$sample"; fi
    if [[ -z "$maximum" || "$sample" -gt "$maximum" ]]; then maximum="$sample"; fi
    if [[ "$TIMELINE" = 1 ]]; then
      awk -v t="$i" -v bytes="$sample" \
        'BEGIN { printf "    t=%02ds footprint=%.1f MiB\n", t, bytes / 1048576 }'
      if [[ "$spike_dumped" = 0 && "$((sample - minimum))" -gt "$SPIKE_DUMP_BYTES" ]]; then
        spike_dumped=1
        echo "    spike detected at t=${i}s; category breakdown:"
        footprint -p "$APP_PID" 2>/dev/null | sed 's/^/      /' || true
      fi
    fi
  done
  after="$(cpu_seconds "$APP_PID")"
  wall_after="$(date +%s)"
  wall=$((wall_after - wall_before))
  [[ "$wall" -lt 1 ]] && wall=1
  cpu="$(awk -v before="$before" -v after="$after" 'BEGIN { printf "%.2f", after - before }')"
  average="$(awk -v cpu="$cpu" -v wall="$wall" \
    'BEGIN { printf "%.2f", cpu * 100 / wall }')"
  footprint="$(awk -v sum="$sum" -v count="$count" \
    'BEGIN { printf "%.1f", sum / count / 1048576 }')"
  range="$(awk -v low="$minimum" -v high="$maximum" \
    'BEGIN { printf "%.1f-%.1f", low / 1048576, high / 1048576 }')"
  peak="$(awk -v bytes="$peak" 'BEGIN { printf "%.1f", bytes / 1048576 }')"
  printf "%-22s %10s %11s%% %14s %17s %14s\n" \
    "$name" "$cpu" "$average" "$footprint MiB" "$range MiB" "$peak MiB"

  cleanup_processes
  defaults delete "$suite" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$suite.plist"
}

echo
printf "%-22s %10s %12s %14s %17s %14s\n" \
  "scenario" "CPU seconds" "average CPU" "footprint" "sampled range" "lifetime peak"
if [[ "$CASES" = all || "$CASES" = idle || "$CASES" = idle-closed ]]; then
  run_case "idle-deck-closed" false false 0
fi
if [[ "$CASES" = all || "$CASES" = idle || "$CASES" = idle-visible ]]; then
  run_case "idle-deck-visible" true false 0
fi
if [[ "$CASES" = all || "$CASES" = idle || "$CASES" = idle-obscured ]]; then
  run_case "idle-deck-obscured" true true 0
fi
if [[ "$CASES" = all || "$CASES" = playback || "$CASES" = playback-closed ]]; then
  run_case "playing-deck-closed" false false 1
fi
if [[ "$CASES" = all || "$CASES" = playback || "$CASES" = playback-visible ]]; then
  run_case "playing-deck-visible" true false 1
fi
if [[ "$CASES" = all || "$CASES" = playback || "$CASES" = playback-obscured ]]; then
  run_case "playing-deck-obscured" true true 1
fi
echo
echo "Sampled each scenario once per second for ${SAMPLE_SECONDS}s after a ${WARMUP_SECONDS}s warmup."
echo "footprint is the mean of the per-second samples; sampled range is their min-max."
