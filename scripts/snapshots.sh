#!/bin/bash
# Background GUI verification: launch Nightdrive with the self-snapshot tour
# (NIGHTDRIVE_SNAPSHOT_DIR) and assert it produced every expected PNG. Snapshot
# mode uses accessory activation, so the real windows paint without taking
# focus, adding a Dock icon, or interrupting work in the foreground app.
#
# The tour is seven independent scopes — library, playback, deck, faceplate,
# visualizers, settings, colorways — and the app can shoot any subset, so this
# runs one instance per scope at the same time and the tour costs its longest
# scope rather than the sum. Each instance gets its own preferences domain,
# plugin folder, app data, playback state and transcode handoffs; they share
# only the read-only demo library and fake iPod.
#
# Usage:
#   scripts/snapshots.sh                     every scope, concurrently
#   scripts/snapshots.sh --settings          only the Settings window
#   scripts/snapshots.sh --scope deck,library
#   scripts/snapshots.sh --serial            one process, scopes in order
#
# Launching the GUI needs an unsandboxed shell (WindowServer access).
set -euo pipefail
cd "$(dirname "$0")/.."

SNAP_DIR=".scratch/snapshots"
DEMO_LIB=".scratch/demo-library"
DEMO_IPOD=".scratch/demo-ipod"
RUN_DIR=".scratch/snapshot-runs-$$"
TIMEOUT=300
VISUALIZER_SHARDS="${NIGHTDRIVE_SNAPSHOT_VISUALIZER_SHARDS:-5}"

ALL_SCOPES=(library playback deck faceplate visualizers settings colorways maintenance)
SCOPES=("${ALL_SCOPES[@]}")
SERIAL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --settings)
      SCOPES=(settings colorways)
      shift
      ;;
    --scope)
      [ "$#" -ge 2 ] || {
        echo "usage: $0 --scope <name[,name…]>" >&2
        exit 2
      }
      IFS=',' read -r -a SCOPES <<<"$2"
      shift 2
      ;;
    --serial)
      SERIAL=1
      shift
      ;;
    *)
      echo "usage: $0 [--settings | --scope <name[,name…]>] [--serial]" >&2
      exit 2
      ;;
  esac
done

for scope in "${SCOPES[@]}"; do
  case " ${ALL_SCOPES[*]} " in
    *" $scope "*) ;;
    *)
      echo "unknown scope: $scope (known: ${ALL_SCOPES[*]})" >&2
      exit 2
      ;;
  esac
done

# What each scope owes, so a tour that quits early is a failure rather than a
# quietly shorter run.
LIBRARY_EXPECTED=(
  library.png selection.png bulk-editor.png single-editor.png
  single-editor-genre-empty.png single-editor-genre-one-character.png
  single-editor-genre-typed.png single-editor-genre-submitted.png
  artists.png albums.png genres.png search-no-results.png command-palette.png quick-search.png
  suggestions-disabled.png
)
PLAYBACK_EXPECTED=(
  device.png playing.png up-next.png playlists.png listening.png
  sync-details-failures.png
)
DECK_EXPECTED=(
  deck-opening.png deck-hello.png deck.png deck-up-next.png
)
FACEPLATE_EXPECTED=(
  deck-pose-early.png deck-pose-half.png deck-pose-overshoot.png
  deck-detached.png faceplate.png faceplate-resized.png faceplate-mini.png
)
VISUALIZERS_EXPECTED=(
  deck-spectrum.png deck-scope.png deck-waterfall.png
  deck-plasma.png deck-fire.png deck-tunnel.png deck-rotozoom.png
  deck-vectors.png deck-metaballs.png
  deck-vu.png deck-eq.png deck-ripple.png
  deck-marquee.png deck-combo.png
  deck-constellation.png deck-eqladder.png deck-glyphrain.png
  deck-hyperwarp.png deck-radar.png
  deck-vectorscope.png deck-wireframe.png
  deck-aquarium.png deck-nightdrive.png deck-fireworks.png deck-dolphins.png
)
SETTINGS_EXPECTED=(
  settings-general.png settings-ipod-sync.png settings-visualizers.png
  settings-online.png about.png controls.png
  settings-visualizers-last.png settings-visualizers-nomatch.png
  settings-visualizers-off.png
  settings-visualizers-issue.png
)
COLORWAYS_EXPECTED=(
  settings-colorway-vfd.png settings-colorway-ice.png settings-colorway-xplod.png
  settings-colorway-amber.png settings-colorway-arctic.png settings-colorway-plasma.png
)
MAINTENANCE_EXPECTED=(
  find-duplicates.png clean-up-genres.png find-metadata-problems.png organize-library.png
)

expected_for() {
  case "$1" in
    library) printf '%s\n' "${LIBRARY_EXPECTED[@]}" ;;
    playback) printf '%s\n' "${PLAYBACK_EXPECTED[@]}" ;;
    deck) printf '%s\n' "${DECK_EXPECTED[@]}" ;;
    faceplate) printf '%s\n' "${FACEPLATE_EXPECTED[@]}" ;;
    visualizers) printf '%s\n' "${VISUALIZERS_EXPECTED[@]}" ;;
    settings) printf '%s\n' "${SETTINGS_EXPECTED[@]}" ;;
    colorways) printf '%s\n' "${COLORWAYS_EXPECTED[@]}" ;;
    maintenance) printf '%s\n' "${MAINTENANCE_EXPECTED[@]}" ;;
  esac
}

echo "== snapshots: building debug binary =="
node scripts/run-swiftpm.mjs build -c debug
BUILD_PRODUCTS_DIR="$(node scripts/run-swiftpm.mjs build -c debug --show-bin-path)"
BIN="$BUILD_PRODUCTS_DIR/Nightdrive"
if [[ ! -x "$BIN" ]]; then
  echo "FAIL: SwiftPM did not produce an executable at $BIN" >&2
  exit 1
fi

if [ ! -d "$DEMO_LIB" ] || [ ! -d "$DEMO_IPOD" ]; then
  "$BIN" seed-demo "$DEMO_LIB" "$DEMO_IPOD"
fi

# Only clear the shots this run is about to retake, so scopes can be mixed.
mkdir -p "$SNAP_DIR"
for scope in "${SCOPES[@]}"; do
  while IFS= read -r name; do
    rm -f "$SNAP_DIR/$name"
  done < <(expected_for "$scope")
done
# The maintenance tour seeds a uniquely named messy library inside the
# snapshot directory; sweep copies left behind by earlier runs.
rm -rf "$SNAP_DIR"/messy-library-*

mkdir -p "$RUN_DIR"
PIDS=()
SUITES=()

# SwiftUI animation timelines stop advancing while the display sleeps, so a
# tour that dozes partway through shoots blank glass. Held for the run only;
# this never wakes a display that is already asleep.
if command -v caffeinate >/dev/null 2>&1; then
  caffeinate -d -i -w $$ &
  disown $! 2>/dev/null || true
fi
cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  for suite in ${SUITES[@]+"${SUITES[@]}"}; do
    defaults delete "$suite" >/dev/null 2>&1 || true
    # `defaults delete` clears the domain but can leave an empty plist behind.
    rm -f "$HOME/Library/Preferences/$suite.plist"
  done
  rm -rf "$RUN_DIR"
}
trap cleanup EXIT

# Starting with no plugin folder makes the app install the current examples, so
# the tour covers the same modes whatever an older checkout left behind.
start_instance() {
  local name="$1" scope_list="$2" shard="${3:-}"
  local suite="dev.nightdrive.snapshots.$$.$name"
  local instance="$RUN_DIR/$name"
  mkdir -p "$instance"
  SUITES+=("$suite")
  NIGHTDRIVE_LIBRARY="$PWD/$DEMO_LIB" \
    NIGHTDRIVE_EXTRA_VOLUMES="$PWD/$DEMO_IPOD" \
    NIGHTDRIVE_SNAPSHOT_DIR="$PWD/$SNAP_DIR" \
    NIGHTDRIVE_SNAPSHOT_SCOPE="$scope_list" \
    NIGHTDRIVE_SNAPSHOT_SHARD="$shard" \
    NIGHTDRIVE_VISUALIZER_DIR="$PWD/$instance/visualizers" \
    NIGHTDRIVE_DEFAULTS_SUITE="$suite" \
    NIGHTDRIVE_PLAYBACK_STATE_PATH="$PWD/$instance/playback-state.json" \
    NIGHTDRIVE_LOUDNESS_CACHE="$PWD/.scratch/snapshots-loudness-cache" \
    NIGHTDRIVE_APP_DATA_DIR="$PWD/$instance/app-data" \
    NIGHTDRIVE_TRANSCODE_HANDOFF_ROOT="$PWD/$instance/transcode-handoffs" \
    "$BIN" >"$instance/log" 2>&1 &
  PIDS+=($!)
}

if [ "$SERIAL" -eq 1 ]; then
  echo "== snapshots: ${SCOPES[*]} (one process) =="
  start_instance "serial" "$(
    IFS=,
    echo "${SCOPES[*]}"
  )"
else
  instances=0
  for scope in "${SCOPES[@]}"; do
    # One shot per registered mode outgrows every other scope.
    if [ "$scope" = visualizers ]; then
      for i in $(seq 1 "$VISUALIZER_SHARDS"); do
        start_instance "visualizers-$i" visualizers "$i/$VISUALIZER_SHARDS"
        instances=$((instances + 1))
      done
    else
      start_instance "$scope" "$scope"
      instances=$((instances + 1))
    fi
  done
  echo "== snapshots: ${SCOPES[*]} ($instances concurrent) =="
fi

# One shared deadline so a hung tour cannot stall the run forever.
status=0
elapsed=0
while [ "$elapsed" -lt "$TIMEOUT" ]; do
  running=0
  for pid in "${PIDS[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then running=1; fi
  done
  [ "$running" -eq 0 ] && break
  sleep 1
  elapsed=$((elapsed + 1))
done

for pid in "${PIDS[@]}"; do
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "FAIL: an app instance did not exit within ${TIMEOUT}s (snapshot tour hung?)" >&2
    status=1
    continue
  fi
  if ! wait "$pid"; then
    echo "FAIL: an app instance exited nonzero" >&2
    status=1
  fi
done

for log in "$RUN_DIR"/*/log; do
  [ -s "$log" ] || continue
  echo "-- $(basename "$(dirname "$log")") output --" >&2
  cat "$log" >&2
done

count=0
for scope in "${SCOPES[@]}"; do
  if [ -z "$(expected_for "$scope")" ]; then
    echo "FAIL: scope '$scope' has no expected shots — add it to expected_for()" >&2
    exit 1
  fi
  while IFS= read -r name; do
    count=$((count + 1))
    f="$SNAP_DIR/$name"
    if [ ! -f "$f" ]; then
      echo "FAIL: missing $f" >&2
      status=1
      continue
    fi
    size="$(stat -f %z "$f")"
    if [ "$size" -le 20480 ]; then
      echo "FAIL: $f is only ${size} bytes (expected >20KB)" >&2
      status=1
    else
      echo "PASS: $PWD/$f (${size} bytes)"
    fi
  done < <(expected_for "$scope")
done

[ "$status" -eq 0 ] && echo "snapshots: $count PNGs written to $PWD/$SNAP_DIR"
exit "$status"
