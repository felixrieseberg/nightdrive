# Nightdrive

Nightdrive is a native SwiftUI macOS app for syncing a folder of MP3s with
classic click-wheel iPods. The executable also provides a CLI used by the demo
and end-to-end test harnesses.

## Where to work

- `Sources/Nightdrive/` contains the app, iTunesDB reader and writer, sync
  engine, CLI, and snapshot harness.
- `Sources/Nightdrive/Visualizers/` contains the deck's swappable display
  modes and the JavaScript plugin bridge. See
  [`docs/visualizers.md`](docs/visualizers.md) before adding a mode; use
  `Nightdrive visualizers --render <dir>` to see what one looks like without
  launching the app.
- `Tests/NightdriveTests/` contains unit and filesystem integration tests.
- `scripts/` contains app packaging, release, CLI end-to-end, snapshot, and
  SwiftPM tooling.
- `Resources/` contains app-bundle metadata and assets.
- `ReleaseNotes/<version>.md` holds the user-facing notes each release ships as
  its Sparkle update description and GitHub release body. See
  [`DISTRIBUTION.md`](DISTRIBUTION.md) for how releases and in-app updates
  work; never create or move a release tag by hand.

## Common commands

```bash
make verify-fast                         # Swift lint + debug compile (<1s warm)
make build                               # debug compile only
make verify-test                         # build and run the unit/tooling tests
make verify-test TEST_FILTER=SyncEngine  # run matching tests
make verify-full                         # complete automated suite (~20s warm)
make format                              # format Swift sources and tests
make help                                # list every supported command
```

Prefer Make targets over direct `swift` commands: the SwiftPM wrapper keeps
mutable build state inside the current checkout, shares versioned compiler
caches across worktrees, and gives every debug build the same compiler flags so
switching targets doesn't recompile the world. See
[`VERIFICATION.md`](VERIFICATION.md) for the verification tiers and tuning
options.

## Safe app testing

Never point an automated or exploratory check at a mounted real iPod. Use only
the generated fake iPod under `.scratch/` unless the user explicitly asks to
work with a particular real device.

Do not use `make run`, `make open`, or `open dist/Nightdrive.app` for automated
verification because they activate the app. Use the existing test surfaces:

```bash
make e2e        # CLI sync against an isolated fake library and fake iPod
make snapshots  # background GUI tour; writes PNGs and exits without taking focus
```

Snapshot tours use accessory activation: their windows still paint for
in-process capture, but Nightdrive does not take focus, add a Dock icon, or
appear in the app switcher. The tour is eight independent scopes run as several
isolated instances at once, so it costs its longest scope rather than the sum;
pass `--scope deck,library` while iterating on one part, or `--serial` for a
single ordered process. The PNGs land in `.scratch/snapshots/`. A successful
script proves the app completed the tour and produced plausible images; visual
verification still requires opening the PNGs you changed. Read
[`.claude/skills/verify/SKILL.md`](.claude/skills/verify/SKILL.md) before
driving the app or sync CLI.

## The Develop menu

`Sources/Nightdrive/Development/` holds a development-only menu that reaches
states a from-source build otherwise needs hardware or a relaunch to reach:
mounting fake iPods, faking their free space or write failures, corrupting a
fake database, resetting the sync ledger and listening history, replaying the
deck ceremony, and driving the capture harness.

It is gated twice — the `NIGHTDRIVE_DEVELOPMENT_TOOLS` compile flag (debug
builds, or `DEVELOPMENT_TOOLS=1` for a release-configured one) and the
`NightdriveDevelopmentTitleSuffix` marker `scripts/build-app.sh` stamps into
non-release bundles. A shipping bundle carries neither.

Every destructive item refuses to act on a real volume: fake iPods are plain
directories, real ones are mounted volumes, and `DevelopmentSafety` keys on
exactly that. Keep new items behind the same check.

Scratch data must remain checkout-local. Tests and scripts may remove only the
specific gitignored paths they created. Preserve demo data and unrelated
scratch artifacts unless the requested operation explicitly replaces them.

`make sizzle` records the scripted ~60s demo video (Develop ▸ Demo in debug
builds runs the same tracks interactively). Unlike the snapshot tour it shows
the app on screen for about a minute and needs the display awake, so treat it
as a content-producing command the user asks for, never part of automated
verification. It runs against the user's real library, playlists, and podcast
subscriptions, but only ever syncs a staged fake iPod named "My iPod" — never
a real device; the recording lands in `~/Movies/Nightdrive Demos` unless
`NIGHTDRIVE_DEMO_OUTPUT_DIR` says otherwise.

`make demo-video` re-encodes the newest such recording into `docs/demo.mp4`,
the clip the website autoplays, and its poster frame. The header of
[`scripts/encode-demo-video.sh`](scripts/encode-demo-video.sh) explains the
size and quality it settles on and why.

## Conventions

- Keep Swift changes idiomatic and formatted with the repository
  `.swift-format` configuration.
- Keep dependencies light; the app is intentionally a SwiftPM-native macOS
  executable.
- Add focused tests for iTunesDB compatibility, filesystem safety, sync
  idempotency, and recovery behavior when changing those areas.
- Preserve the CLI end-to-end guarantees: two-way copy, ID3 reconstruction,
  idempotent no-op sync, database backup, and rejection of corrupt databases
  and non-iPod folders.
- Preserve unrelated work in a dirty worktree.
