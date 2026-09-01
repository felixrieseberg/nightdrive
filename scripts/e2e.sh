#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

E2E=".scratch/e2e"
LIB="$E2E/library"
POD="$E2E/ipod"
DB="$POD/iPod_Control/iTunes/iTunesDB"

export NIGHTDRIVE_TRANSCODE_CACHE="$E2E/transcode-cache"
export NIGHTDRIVE_LOUDNESS_CACHE="$E2E/loudness-cache"

CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

echo "== e2e: building debug binary =="
node scripts/run-swiftpm.mjs build -c debug
BUILD_PRODUCTS_DIR="$(node scripts/run-swiftpm.mjs build -c debug --show-bin-path)"
BIN="$BUILD_PRODUCTS_DIR/Nightdrive"
if [[ ! -x "$BIN" ]]; then
  fail "SwiftPM did not produce an executable at $BIN"
fi

rm -rf "$E2E"
mkdir -p "$E2E"

"$BIN" seed-demo "$LIB" "$POD" || fail "seed-demo exited nonzero"
[ -f "$DB" ] || fail "seed-demo did not create $DB"
pass "seed-demo created library and fake iPod"

python3 - "$LIB/CLI Fixture.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1], 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(44100)
    output.writeframes(b'\0\0' * 44100)
PY
/usr/bin/afconvert "$LIB/CLI Fixture.wav" "$LIB/Local Only.caf" -f caff -d LEI16@44100 \
  || fail "could not create CAF CLI fixture"
pass "created WAV and CAF (transcode-needing) CLI fixtures"

LIB_BEFORE_COUNT="$(find "$LIB" -name '*.mp3' | wc -l | tr -d ' ')"
[ "$LIB_BEFORE_COUNT" -eq 18 ] || fail "expected 18 seeded library mp3s, got $LIB_BEFORE_COUNT"
find "$LIB" -name '*.mp3' -exec basename {} \; | sort > "$E2E/lib-before.txt"

STRIPPED_FILE="$(find "$POD/iPod_Control/Music" -name '*.mp3' | sort | head -1)"
[ -n "$STRIPPED_FILE" ] || fail "no mp3 found on the fake iPod"
python3 -c "
import sys
p = sys.argv[1]
d = open(p, 'rb').read()
i = d.find(b'\xff\xfb')
assert i > 0, 'no MPEG frame sync found'
open(p, 'wb').write(d[i:])
" "$STRIPPED_FILE"
[ "$(head -c 3 "$STRIPPED_FILE")" != "ID3" ] || fail "tag strip did not work"
pass "stripped ID3 tag from $(basename "$STRIPPED_FILE")"

STRIPPED_BASE="$(basename "$STRIPPED_FILE")"
STRIPPED_LINE="$("$BIN" dump "$DB" | grep -F ":$STRIPPED_BASE")" \
  || fail "stripped file $STRIPPED_BASE not found in iTunesDB dump"
STRIPPED_TITLE="$(printf '%s\n' "$STRIPPED_LINE" | sed 's/.*– //; s/ (.*//')"
[ -n "$STRIPPED_TITLE" ] || fail "could not parse title from dump line: $STRIPPED_LINE"
echo "     (stripped track's DB title: $STRIPPED_TITLE)"

SYNC1="$("$BIN" sync "$LIB" "$POD")" || fail "first sync exited nonzero"
printf '%s\n' "$SYNC1"
printf '%s\n' "$SYNC1" | grep -q "0 failures" || fail "first sync reported failures"
pass "first sync completed with 0 failures"
printf '%s\n' "$SYNC1" | grep -q "Library: 20 songs" \
  || fail "CLI did not discover every supported local audio format"
printf '%s\n' "$SYNC1" | grep -q "local-only: 0" \
  || fail "CLI still reports local-only audio despite transcode support"
pass "CLI discovers non-MP3 formats and schedules the CAF for the iPod"

CACHE_COUNT="$(find "$E2E/transcode-cache" -name '*.m4a' | wc -l | tr -d ' ')"
[ "$CACHE_COUNT" -eq 1 ] || fail "expected 1 cached conversion, got $CACHE_COUNT"
pass "the conversion landed in the checkout-local transcode cache"

LIB_AFTER_COUNT="$(find "$LIB" -name '*.mp3' | wc -l | tr -d ' ')"
[ "$LIB_AFTER_COUNT" -eq 21 ] || fail "library should have gained 3 mp3s (18 -> 21), has $LIB_AFTER_COUNT"
pass "library gained 3 mp3s from the iPod (18 -> 21)"

"$BIN" dump "$DB" | grep -q "^tracks: 23$" || fail "iPod DB should have 23 tracks after sync"
"$BIN" dump "$DB" | grep -q "CLI Fixture.*\.wav" \
  || fail "iPod database is missing the WAV discovered by the CLI"
"$BIN" dump "$DB" | grep -q "Local Only.*\.m4a" \
  || fail "iPod database is missing the transcoded CAF as an .m4a"
pass "iPod database has 23 tracks including the WAV and the transcoded CAF"

ARTDB="$POD/iPod_Control/Artwork/ArtworkDB"
printf '%s\n' "$SYNC1" | grep -q "Wrote album art for" \
  || fail "first sync did not report writing album art"
[ -f "$ARTDB" ] || fail "sync did not create $ARTDB"
[ "$(stat -f %z "$ARTDB")" -gt 132 ] || fail "ArtworkDB is implausibly small"
for SPEC in "F1016_1.ithmb:39200" "F1017_1.ithmb:6272"; do
  ITHMB="$POD/iPod_Control/Artwork/${SPEC%%:*}"
  TILE="${SPEC##*:}"
  [ -f "$ITHMB" ] || fail "sync did not create $ITHMB"
  SIZE="$(stat -f %z "$ITHMB")"
  [ "$SIZE" -gt 0 ] || fail "$(basename "$ITHMB") is empty"
  [ $((SIZE % TILE)) -eq 0 ] \
    || fail "$(basename "$ITHMB") size $SIZE is not a multiple of the $TILE-byte tile"
done
pass "album art store created with plausible ithmb tile sizes"

MTIME_BEFORE="$(stat -f %Fm "$DB")"
ART_MTIME_BEFORE="$(stat -f %Fm "$ARTDB")"
SYNC2="$("$BIN" sync "$LIB" "$POD")" || fail "second sync exited nonzero"
printf '%s\n' "$SYNC2"
printf '%s\n' "$SYNC2" | grep -q "Copied 0 to iPod, 0 to library" \
  || fail "second sync was not a no-op"
pass "second sync copied 0/0 (idempotent)"

MTIME_AFTER="$(stat -f %Fm "$DB")"
[ "$MTIME_BEFORE" = "$MTIME_AFTER" ] \
  || fail "no-op sync modified iTunesDB (mtime $MTIME_BEFORE -> $MTIME_AFTER)"
pass "no-op sync did not touch iTunesDB (mtime unchanged)"

ART_MTIME_AFTER="$(stat -f %Fm "$ARTDB")"
[ "$ART_MTIME_BEFORE" = "$ART_MTIME_AFTER" ] \
  || fail "no-op sync rebuilt ArtworkDB (mtime $ART_MTIME_BEFORE -> $ART_MTIME_AFTER)"
pass "no-op sync did not rebuild the album art store (mtime unchanged)"

find "$LIB" -name '*.mp3' -exec basename {} \; | sort > "$E2E/lib-after.txt"
comm -13 "$E2E/lib-before.txt" "$E2E/lib-after.txt" > "$E2E/lib-new.txt"
NEW_COUNT="$(wc -l < "$E2E/lib-new.txt" | tr -d ' ')"
[ "$NEW_COUNT" -eq 3 ] || fail "expected 3 new library files, got $NEW_COUNT"

RECON_NAME="$(grep -F "$STRIPPED_TITLE" "$E2E/lib-new.txt" | head -1)" \
  || fail "no pulled library file matches stripped title '$STRIPPED_TITLE'"
[ "$(head -c 3 "$LIB/$RECON_NAME")" = "ID3" ] \
  || fail "pulled file '$RECON_NAME' does not start with ID3 (tag not reconstructed)"
pass "stripped track '$STRIPPED_TITLE' was pulled with a reconstructed ID3 tag ($RECON_NAME)"

while IFS= read -r name; do
  [ "$(head -c 3 "$LIB/$name")" = "ID3" ] || fail "pulled file '$name' has no ID3 tag"
done < "$E2E/lib-new.txt"
pass "all 3 files pulled from the iPod start with an ID3 tag"

[ -f "$DB.nightdrive.bak" ] || fail "iTunesDB.nightdrive.bak missing"
pass "iTunesDB.nightdrive.bak exists"

PLFILE="$LIB/.nightdrive-playlists.json"
printf '%s\n' "$SYNC1" | grep -q 'Added playlist "On-The-Go 1" to the library' \
  || fail "first sync did not import the seeded device playlist"
[ -f "$PLFILE" ] || fail "sync did not persist library playlists to $PLFILE"
grep -q '"On-The-Go 1"' "$PLFILE" || fail "$PLFILE is missing the imported playlist"
pass "seeded device playlist was imported into the library"

python3 - "$PLFILE" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
imported = next(p for p in data if p['name'] == 'On-The-Go 1')
assert len(imported['trackIDs']) >= 2, 'imported playlist too small for fixture'
data.append({
    'id': '11111111-2222-3333-4444-555555555555',
    'name': 'Road Trip',
    'trackIDs': list(reversed(imported['trackIDs'][:2])),
    'syncEnabled': True,
})
json.dump(data, open(path, 'w'))
PY
SYNC3="$("$BIN" sync "$LIB" "$POD")" || fail "playlist push sync exited nonzero"
printf '%s\n' "$SYNC3" | grep -q 'Created playlist "Road Trip" on the iPod' \
  || fail "sync did not push the new library playlist to the device"
"$BIN" dump "$DB" | grep -q "Road Trip: 2 tracks" \
  || fail "iPod database is missing the pushed playlist"
pass "library playlist 'Road Trip' was pushed to the iPod (2 ordered tracks)"

OTG="$POD/iPod_Control/iTunes/OTGPlaylistInfo"
python3 - "$OTG" <<'PY'
import struct, sys
data = b'mhpo' + struct.pack('<4I', 20, 4, 3, 0) + struct.pack('<3I', 5, 3, 9)
open(sys.argv[1], 'wb').write(data)
PY
SYNC4="$("$BIN" sync "$LIB" "$POD")" || fail "On-The-Go sync exited nonzero"
printf '%s\n' "$SYNC4" | grep -q 'Imported On-The-Go playlist as "On-The-Go 2"' \
  || fail "sync did not import the On-The-Go playlist"
[ ! -f "$OTG" ] || fail "consumed On-The-Go file was not deleted"
grep -q '"On-The-Go 2"' "$PLFILE" || fail "$PLFILE is missing the On-The-Go import"
pass "On-The-Go playlist was imported as 'On-The-Go 2' and its file consumed"

SYNC5="$("$BIN" sync "$LIB" "$POD")" || fail "On-The-Go push sync exited nonzero"
printf '%s\n' "$SYNC5" | grep -q 'Created playlist "On-The-Go 2" on the iPod' \
  || fail "sync did not push the imported On-The-Go playlist to the device"
"$BIN" dump "$DB" | grep -q "On-The-Go 2: 3 tracks" \
  || fail "iPod database is missing the pushed On-The-Go playlist"
pass "imported On-The-Go playlist was pushed back to the iPod as a real playlist"

PL_MTIME_BEFORE="$(stat -f %Fm "$DB")"
SYNC6="$("$BIN" sync "$LIB" "$POD")" || fail "post-playlist sync exited nonzero"
printf '%s\n' "$SYNC6" | grep -q "Playlist changes: 0" \
  || fail "post-playlist sync still reported playlist changes"
printf '%s\n' "$SYNC6" | grep -q "Copied 0 to iPod, 0 to library" \
  || fail "post-playlist sync copied files"
[ "$PL_MTIME_BEFORE" = "$(stat -f %Fm "$DB")" ] \
  || fail "post-playlist no-op sync modified iTunesDB"
pass "sync after playlist round trips is a true no-op"

PLAYCOUNTS="$POD/iPod_Control/iTunes/Play Counts"
HISTFILE="$LIB/.nightdrive-history.json"
PENDING="$LIB/.nightdrive-pending-plays.json"
python3 - "$PLAYCOUNTS" <<'PY'
import struct, sys
plays_by_index = [3] + [0] * 22
data = b'mhdp' + struct.pack('<3I', 16, 28, len(plays_by_index))
for plays in plays_by_index:
    data += struct.pack('<7I', plays, 0, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(data)
PY
SYNC7="$("$BIN" sync "$LIB" "$POD")" || fail "Play Counts sync exited nonzero"
printf '%s\n' "$SYNC7" | grep -q "Picked up 3 plays from the iPod." \
  || fail "sync did not report the device plays"
[ ! -f "$PLAYCOUNTS" ] || fail "consumed Play Counts file was not deleted"
[ ! -f "$PENDING" ] || fail "pending playback report was not cleared"
python3 - "$HISTFILE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
device = [h for h in payload['history'] if h.get('source') == 'device']
assert len(device) == 3, f"expected 3 device plays in history, got {len(device)}"
total = sum(m['playCount'] for m in payload['metadataByID'].values())
assert total == 3, f"expected 3 total plays, got {total}"
PY
pass "device plays landed in local history exactly once and the file was consumed"

python3 - "$PLAYCOUNTS" <<'PY'
import struct, sys
plays_by_index = [0, 2] + [0] * 21
data = b'mhdp' + struct.pack('<3I', 16, 28, len(plays_by_index))
for plays in plays_by_index:
    data += struct.pack('<7I', plays, 0, 0, 0, 0, 0, 0)
open(sys.argv[1], 'wb').write(data)
PY
CRASH_OUT="$(NIGHTDRIVE_SIMULATE_CRASH_BEFORE_PLAYBACK_MERGE=1 "$BIN" sync "$LIB" "$POD")" \
  || fail "crash-simulated sync exited nonzero"
printf '%s\n' "$CRASH_OUT" | grep -q "Simulated crash before playback merge." \
  || fail "crash hook did not trigger"
[ -f "$PLAYCOUNTS" ] || fail "Play Counts file must survive a crash before the merge"
[ -f "$PENDING" ] || fail "pending playback report missing after the simulated crash"
SYNC8="$("$BIN" sync "$LIB" "$POD")" || fail "post-crash sync exited nonzero"
printf '%s\n' "$SYNC8" | grep -q "Picked up 2 plays from the iPod." \
  || fail "post-crash sync did not replay the pending plays"
[ ! -f "$PLAYCOUNTS" ] || fail "replayed Play Counts file was not deleted"
[ ! -f "$PENDING" ] || fail "pending playback report was not cleared after replay"
python3 - "$HISTFILE" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
device = [h for h in payload['history'] if h.get('source') == 'device']
assert len(device) == 5, f"expected 5 device plays in history, got {len(device)}"
total = sum(m['playCount'] for m in payload['metadataByID'].values())
assert total == 5, f"expected 5 total plays, got {total}"
PY
SYNC9="$("$BIN" sync "$LIB" "$POD")" || fail "post-replay sync exited nonzero"
printf '%s\n' "$SYNC9" | grep -q "Picked up" && fail "plays were double-counted after replay"
pass "interrupted sync replayed the device plays exactly once"

POD2="$E2E/ipod2"
"$BIN" seed-demo "$E2E/lib-scope-tmp" "$POD2" || fail "second seed-demo exited nonzero"
rm -rf "$E2E/lib-scope-tmp"
DB2="$POD2/iPod_Control/iTunes/iTunesDB"
set +e
OVER_OUT="$(NIGHTDRIVE_FAKE_AVAILABLE_CAPACITY=1000000 "$BIN" sync "$LIB" "$POD2" 2>&1)"
OVER_RC=$?
set -e
[ "$OVER_RC" -ne 0 ] || fail "over-capacity sync exited 0"
printf '%s\n' "$OVER_OUT" | grep -q "over the iPod's free space" \
  || fail "over-capacity sync did not report the shortfall: $OVER_OUT"
printf '%s\n' "$OVER_OUT" | grep -q "Suggested trim" \
  || fail "over-capacity sync did not print a trim suggestion"
"$BIN" dump "$DB2" | grep -q "^tracks: 3$" \
  || fail "over-capacity sync copied files before refusing"
pass "over-capacity sync refuses with a shortfall and trim suggestion"

SCOPE1="$("$BIN" sync "$LIB" "$POD2" --scope "playlists=Road Trip")" \
  || fail "scoped sync exited nonzero"
printf '%s\n' "$SCOPE1"
printf '%s\n' "$SCOPE1" | grep -q "Saved sync scope for this iPod: 1 playlist" \
  || fail "scoped sync did not persist the scope"
printf '%s\n' "$SCOPE1" | grep -q "Scope excludes" \
  || fail "scoped sync did not report scope exclusions"
printf '%s\n' "$SCOPE1" | grep -q "not in this sync (kept" \
  || fail "scoped sync did not report the not-in-this-sync device song as kept"
printf '%s\n' "$SCOPE1" | grep -q 'Created playlist "Road Trip" on the iPod' \
  || fail "scoped sync did not push the chosen playlist"
printf '%s\n' "$SCOPE1" | grep -q "0 failures" || fail "scoped sync reported failures"
"$BIN" dump "$DB2" | grep -q "^tracks: 3$" \
  || fail "scoped sync with removals off must not delete device tracks"
"$BIN" dump "$DB2" | grep -q "Road Trip: 2 tracks" \
  || fail "iPod 2 database is missing the scoped playlist"
pass "playlist-scoped sync kept songs not in this sync and pushed the playlist"

SCOPE2="$("$BIN" sync "$LIB" "$POD2" --song-sync library-to-ipod --confirm-removals)" \
  || fail "confirmed-removal sync exited nonzero"
printf '%s\n' "$SCOPE2"
printf '%s\n' "$SCOPE2" | grep -q "Sync scope: 1 playlist" \
  || fail "second scoped sync did not reuse the persisted scope"
printf '%s\n' "$SCOPE2" | grep -q "Saved song sync for this iPod: One-way (Library to iPod)" \
  || fail "confirmed-removal sync did not persist Library-to-iPod mode"
printf '%s\n' "$SCOPE2" | grep -q "Removing 1 song not in this sync from the iPod." \
  || fail "confirmed-removal sync did not plan the removal"
printf '%s\n' "$SCOPE2" | grep -q "removed 1 from iPod" \
  || fail "confirmed-removal sync did not remove the song not in this sync"
"$BIN" dump "$DB2" | grep -q "^tracks: 2$" \
  || fail "iPod 2 should have 2 tracks after the confirmed removal"
pass "confirmed removal deleted the song not in this sync"

set +e
INVALID_DIRECTION="$("$BIN" sync "$LIB" "$POD2" \
  --song-sync two-way --confirm-removals 2>&1)"
INVALID_DIRECTION_RC=$?
set -e
[ "$INVALID_DIRECTION_RC" -ne 0 ] \
  || fail "conflicting song direction and removal confirmation exited 0"
printf '%s\n' "$INVALID_DIRECTION" | grep -q \
  -- "--confirm-removals requires Library-to-iPod song sync" \
  || fail "conflicting song direction error was unclear: $INVALID_DIRECTION"
pass "conflicting removal confirmation is rejected before changing the saved direction"

SCOPE_MTIME_BEFORE="$(stat -f %Fm "$DB2")"
SCOPE3="$("$BIN" sync "$LIB" "$POD2")" || fail "scoped no-op sync exited nonzero"
printf '%s\n' "$SCOPE3" | grep -q "Song sync: One-way (Library to iPod)" \
  || fail "rejected CLI options changed the saved song direction"
printf '%s\n' "$SCOPE3" | grep -q "Copied 0 to iPod, 0 to library" \
  || fail "scoped follow-up sync was not a no-op"
printf '%s\n' "$SCOPE3" | grep -q "removed 0 from iPod" \
  || fail "scoped follow-up sync removed songs"
[ "$SCOPE_MTIME_BEFORE" = "$(stat -f %Fm "$DB2")" ] \
  || fail "scoped no-op sync modified iTunesDB"
pass "scoped sync is a no-op once the device matches the scope"

head -c 300 "$DB" > "$E2E/truncated.itdb"
if "$BIN" dump "$E2E/truncated.itdb" >/dev/null 2>&1; then
  fail "dump accepted a truncated iTunesDB"
fi
pass "dump rejects a truncated iTunesDB"

mkdir -p "$E2E/not-an-ipod"
set +e
NOPOD_MSG="$("$BIN" sync "$LIB" "$E2E/not-an-ipod" 2>&1)"
NOPOD_RC=$?
set -e
[ "$NOPOD_RC" -ne 0 ] || fail "sync against a non-iPod dir exited 0"
printf '%s\n' "$NOPOD_MSG" | grep -q "does not look like an iPod" \
  || fail "non-iPod error message unclear: $NOPOD_MSG"
pass "sync rejects a non-iPod directory with a clear message"

VIZ_DIR="$E2E/visualizers"
VIZ_PREVIEWS="$E2E/visualizer-previews"
"$BIN" visualizers --dir "$VIZ_DIR" --render "$VIZ_PREVIEWS" --size 64x32 \
  > "$E2E/visualizer-report.txt" \
  || fail "visualizer preview report exited nonzero"
[ -s "$VIZ_PREVIEWS/spectrum.png" ] \
  || fail "visualizer report did not render spectrum.png"
pass "visualizer CLI renders previews to completion"

SLIB="$E2E/shuffle-library"
SPOD="$E2E/shuffle-ipod"
SDB="$SPOD/iPod_Control/iTunes/iTunesDB"
SSD="$SPOD/iPod_Control/iTunes/iTunesSD"
"$BIN" seed-demo "$SLIB" "$SPOD" --shuffle || fail "seed-demo --shuffle exited nonzero"
grep -q "MA564" "$SPOD/iPod_Control/Device/SysInfo" \
  || fail "fake shuffle does not carry a shuffle model number"
[ -f "$SSD" ] || fail "seeding the shuffle's database did not regenerate iTunesSD"
pass "seeded a fake 2nd-generation shuffle"

SSYNC1="$("$BIN" sync "$SLIB" "$SPOD")" || fail "shuffle sync exited nonzero"
printf '%s\n' "$SSYNC1"
printf '%s\n' "$SSYNC1" | grep -q "0 failures" || fail "shuffle sync reported failures"
printf '%s\n' "$SSYNC1" | grep -q "Playlist changes: 0" \
  || fail "shuffle sync must not touch playlists"
if printf '%s\n' "$SSYNC1" | grep -q "Wrote album art"; then
  fail "shuffle sync must not write album art"
fi
[ ! -e "$SPOD/iPod_Control/Artwork/ArtworkDB" ] \
  || fail "shuffle sync created an ArtworkDB"
[ -f "$SSD" ] || fail "shuffle sync did not write iTunesSD"
STRACKS="$("$BIN" dump "$SDB" | sed -n 's/^tracks: //p')"
[ "$STRACKS" -gt 0 ] || fail "shuffle sync left an empty database"
SSD_SIZE="$(stat -f %z "$SSD")"
[ "$SSD_SIZE" -eq $((18 + STRACKS * 558)) ] \
  || fail "iTunesSD is $SSD_SIZE bytes; expected 18+${STRACKS}*558"
pass "shuffle sync wrote a $STRACKS-song iTunesSD and skipped artwork/playlists"

SDB_MTIME="$(stat -f %Fm "$SDB")"
SSD_MTIME="$(stat -f %Fm "$SSD")"
SSYNC2="$("$BIN" sync "$SLIB" "$SPOD")" || fail "second shuffle sync exited nonzero"
printf '%s\n' "$SSYNC2" | grep -q "Copied 0 to iPod, 0 to library" \
  || fail "second shuffle sync was not a no-op"
[ "$SDB_MTIME" = "$(stat -f %Fm "$SDB")" ] \
  || fail "no-op shuffle sync rewrote iTunesDB"
[ "$SSD_MTIME" = "$(stat -f %Fm "$SSD")" ] \
  || fail "no-op shuffle sync rewrote iTunesSD"
pass "unchanged shuffle sync writes neither iTunesDB nor iTunesSD"

echo ""
echo "e2e: $CHECKS checks passed"
