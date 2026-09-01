#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_EXEC="$(pwd -P)/dist/Nightdrive.app/Contents/MacOS/Nightdrive"

matching_pids() {
  ps -axo pid=,args= | awk -v app="$APP_EXEC" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "")
      if ($0 == app || index($0, app " ") == 1) {
        print pid
      }
    }
  '
}

pids="$(matching_pids)"
if [[ -z "$pids" ]]; then
  exit 0
fi

for pid in $pids; do
  kill "$pid" 2>/dev/null || true
done

for _ in {1..25}; do
  pids="$(matching_pids)"
  if [[ -z "$pids" ]]; then
    exit 0
  fi
  sleep 0.2
done

for pid in $pids; do
  kill -KILL "$pid" 2>/dev/null || true
done
