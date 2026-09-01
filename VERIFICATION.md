# Verification

Use the cheapest tier that covers the change while iterating, then run the
complete gate before handoff.

```bash
make verify-fast                          # Swift lint + debug compile
make verify-test TEST_FILTER=SyncEngine   # matching unit tests
make verify-test                          # all unit and tooling tests
make verify-localizations                 # compiler extraction matches the catalog
make verify-localized-errors              # new LocalizedError copy uses the catalog
make verify-full                          # lint, build, tests, CLI e2e, snapshots
```

## Large-library benchmark

`make benchmark-library` measures the scan and in-memory index path at 20,000,
50,000, and 100,000 tracks. Its 50,000-track case represents about 200 GiB of
music at the default four MiB per track. It does not create that audio payload:
all fixture tracks are copy-on-write clones of one sparse MP3. Disk use is
limited to filesystem directory entries, a small audio allocation, and the real
JSON index being measured. Each case is removed when the benchmark exits,
including on failure.

The report includes fixture creation, synthetic metadata construction, cache
encoding and decoding, file discovery, generation-stamp checks, full warm
reconciliation (including catalog sorting and browser-index preparation), a
single file change driven through the live folder-event pipeline (watcher,
debounce, incremental reconciliation, and its persisted cache delta), a single
changed file re-scan, a 1,000-file import, phase-end RSS, peak RSS, and cache
and fixture sizes. This is an opt-in performance tool and is not part of
`make verify-full`.

Use environment variables to shorten or reshape an iteration:

```bash
LIBRARY_BENCHMARK_COUNTS=1000 make benchmark-library
LIBRARY_BENCHMARK_COUNTS=20000,50000 LIBRARY_BENCHMARK_IMPORT_COUNT=0 make benchmark-library
LIBRARY_BENCHMARK_LOGICAL_TRACK_MIB=8 make benchmark-library
make benchmark-library BENCHMARK_CONFIG=debug
```

On a fourteen-core machine, `verify-fast` is about two seconds warm and
thirteen from an empty `.build`; `verify-full` about twenty warm and fifty cold.

There is only one debug build, and it is the fast one: debugger symbols are
dropped unless asked for with `NIGHTDRIVE_DEBUG_INFO_FORMAT=dwarf`. llbuild
keys every compile on its exact command line, so use that setting consistently
while debugging, or every alternation recompiles the whole executable. Release
builds are unaffected.

`make format` rewrites Swift files using `.swift-format`; `make lint` checks
the same paths without modifying them. Both skip files unchanged since they
were last clean — a content-hash marker in `.build/nightdrive-verification/`,
keyed on the formatter version and `.swift-format`, recording nothing when a
run fails — so a warm `make lint` takes hundredths of a second. Pass `--all`,
or set `NIGHTDRIVE_LINT_CACHE=0`, to force every file.

## String catalog

`Resources/Localizable.xcstrings` is generated from the compiler's localization
data rather than `xcstringstool`'s lightweight parser, so interpolations keep
their real format types. After adding, removing, or changing localized UI copy,
run `make localizations`. `make verify-localizations` performs the same
extraction into a temporary catalog and fails when syncing would produce a
diff; the complete verification gate runs this check automatically.

Development-tool and scripted-demo sources are intentionally excluded from
the production catalog. The catalog itself is not a SwiftPM target resource:
`scripts/build-app.sh` compiles its translations directly into the app's main
Resources directory, avoiding a second raw copy in the SwiftPM resource bundle.

`make verify-localized-errors` complements compiler extraction: it uses
SwiftSyntax to reject raw string literals inside production
`LocalizedError.errorDescription` implementations. A fingerprinted allowlist
holds existing localization debt steady—changing or adding raw copy fails—while
`Demo/` and `Development/` remain excluded. Remove an allowlist entry when its
error description is localized. After intentionally localizing existing debt,
regenerate the snapshot with
`./scripts/verify-localized-errors.sh --print-allowlist > scripts/localized-error-allowlist.json`
and review the diff. Never use the snapshot to approve new raw copy.

## What the complete gate covers

`make verify-full` lints, tests the tooling, builds once, then runs the unit
suite, `make e2e` and `make snapshots` concurrently. Each stage's output is
printed whole so a failure reads as one transcript; set `VERIFY_SERIAL=1` to
run the stages in order.

The unit suite covers iTunesDB parsing and round trips, malformed databases,
metadata, path traversal defenses, two-way sync, rollback, idempotency, and
filesystem edge cases. It runs a process per test case, roughly three times
quicker than one ordered process; set `TEST_PARALLEL=0` when a failure needs
reading in sequence.

Test fixtures create their scratch directories below `NSTemporaryDirectory()`;
set the standard `TMPDIR` environment variable to redirect them.

`make e2e` uses only `.scratch/e2e/`: it generates a library and fake iPod,
performs a two-way CLI sync, verifies ID3 tag reconstruction, proves a second
sync is a no-op, checks the database backup, and rejects both a truncated
database and a non-iPod folder.

`make snapshots` launches the app with a seeded library and fake iPod; the app
uses accessory activation (no focus, no Dock icon), drives itself through the
states worth judging, and exits. The tour is eight independent scopes shot by
fully isolated concurrent instances, so it costs its longest scope — the
visualizer sweep, itself sharded — rather than the sum:

```text
library      library.png, selection.png, the two info editors, and the
             collection browsers
playback     device.png, playing.png, up-next/playlists/listening, and
             sync-details-failures.png
deck         deck-opening.png, deck-hello.png, deck.png
faceplate    three pinned poses, deck-detached.png, and the three panel shots
visualizers  deck-<mode>.png for every registered mode, plugins included
settings     one shot per Settings pane, a plugin previewing, a search that
             matches nothing, and a failed plugin
colorways    one shot per tube colourway
maintenance  find-duplicates.png, clean-up-genres.png, and organize-library.png against a
             deliberately messy library
```

```bash
scripts/snapshots.sh                    # every scope, concurrently
scripts/snapshots.sh --settings         # only the Settings window
scripts/snapshots.sh --scope deck,library
scripts/snapshots.sh --serial           # one process, scopes in order
NIGHTDRIVE_SNAPSHOT_VISUALIZER_SHARDS=1 scripts/snapshots.sh
```

The script checks that every image the requested scopes owe exists and is
nontrivial; before claiming visual verification, open and inspect every image
you changed. The harness needs a WindowServer session and must never be
redirected to a real mounted iPod. It holds off display and idle sleep — a
sleeping display stops the deck's greeting animation and shoots blank glass —
but cannot rescue a run started with the display already asleep.

## Worktree-safe SwiftPM wrapper

Make targets invoke `scripts/run-swiftpm.mjs`. Each checkout keeps its own
mutable `.build` directory; compiler module caches are shared in a generation
keyed by the Swift toolchain, `Package.swift`, and `Package.resolved`. By
default two SwiftPM processes may compile concurrently across worktrees, with
compiler jobs divided among the slots actually held — a lone build gets the
whole machine. A process silent for 90 seconds is terminated and retried once,
and `--disable-sandbox` is added only when the current shell needs it. The
defaults can be adjusted:

```bash
NIGHTDRIVE_SWIFT_JOBS=6 make build
NIGHTDRIVE_DEBUG_INFO_FORMAT=dwarf make build
NIGHTDRIVE_SWIFTPM_SLOTS=1 make verify-full
NIGHTDRIVE_SWIFTPM_WATCHDOG_SECONDS=300 make verify-test
NIGHTDRIVE_SWIFT_CACHE_DIR=/absolute/cache/path make build
NIGHTDRIVE_SWIFTPM_DISABLE_SANDBOX=false make build   # boolean; omit to auto-detect
```

## Cache maintenance

```bash
make verification-cache-status
make verification-cache-prune
make verification-cache-prune NIGHTDRIVE_CACHE_MAX_AGE_DAYS=7
```

Pruning preserves the current toolchain/package generation and refuses to run
while a shared verification slot is active. `make clean` removes only the
current checkout's build products and known test outputs, never the shared
module cache or another worktree's state.
