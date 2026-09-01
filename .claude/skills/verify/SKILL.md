---
name: verify
description: Verify the native Nightdrive macOS app with its Swift tests, fake-iPod CLI end-to-end flow, and self-driven GUI snapshots.
---

# Verifying Nightdrive

Use repository Make targets for all builds and tests:

```bash
make verify-fast                         # lint + debug compile
make verify-test                         # unit and tooling tests
make verify-test TEST_FILTER=SyncEngine  # matching tests
make e2e                                 # CLI sync against a fake iPod
make snapshots                           # GUI tour into .scratch/snapshots/
make verify-full                         # complete handoff gate
```

Never test against a mounted real iPod unless the user explicitly asks you to
work with that exact device. The normal verification paths create isolated
fake-device data under `.scratch/`.

## CLI end-to-end check

`make e2e` covers the built-in `seed-demo`, `sync`, and `dump` commands. It
verifies two-way copying, reconstructed ID3 tags, idempotency, preservation of
the previous iTunesDB, and clear rejection of corrupt or non-iPod inputs; it
exits nonzero on the first failed assertion. For manual CLI experiments, create
a fresh library and fake iPod below `.scratch/` and use the executable produced
by `make build` — never an arbitrary mounted volume.

## GUI snapshots

`make snapshots` seeds demo data when necessary, launches Nightdrive with
checkout-local environment overrides, and waits for the app's self-driven tour
to exit. The tour uses accessory activation: its real windows still paint for
in-process capture, but the app does not take focus, add a Dock icon, or appear
in the app switcher. It is eight independent scopes — `library`, `playback`,
`deck`, `faceplate`, `visualizers`, `settings`, `colorways` and `maintenance`
— run as several fully isolated instances at once, so it costs its longest
scope rather than the
sum. While iterating on one part, shoot only that part:

```bash
scripts/snapshots.sh --scope deck        # or any comma-separated set
scripts/snapshots.sh --settings          # shorthand for the Settings window
scripts/snapshots.sh --serial            # one process, scopes in order
```

The script holds off display sleep while it runs, but start runs with the
display awake — nothing can rescue one that begins asleep, and a run that
dozes partway through shoots blank glass because the deck's greeting animation
stops advancing on a sleeping display.

A full run writes:

- `.scratch/snapshots/library.png`
- `.scratch/snapshots/device.png`
- `.scratch/snapshots/playing.png`
- `.scratch/snapshots/deck-*.png` — the deck opening, its HELLO greeting
  (`deck-hello`, played once per launch), seated, deterministic
  mechanism poses (`deck-pose-early`, `deck-pose-half`, `deck-pose-overshoot`),
  the naked chassis with the faceplate detached (`deck-detached`),
  and one shot per registered visualizer
- `.scratch/snapshots/faceplate.png` — the detached faceplate's floating panel
  at its natural size, `faceplate-resized.png` stretched past it, and
  `faceplate-mini.png` shrunk to its half-scale floor
- `.scratch/snapshots/settings-*.png` — the settings window, one shot per tab

After the command passes, open the PNGs covering what you changed: file
presence and size checks do not establish that layout and content are visually
correct.

The harness needs a WindowServer session and deliberately uses
`NIGHTDRIVE_LIBRARY` for the fake MP3 library, `NIGHTDRIVE_EXTRA_VOLUMES` for
the fake iPod, and `NIGHTDRIVE_SNAPSHOT_DIR` for output.

`NSVisualEffectView` and system material effects may not match an activated
on-screen window in offscreen captures. Judge structure, clipping, content, and
state; do not treat material differences alone as regressions. Capacity values
for the fake iPod come from the host filesystem and are not device fixtures.

## Interactive launch

`make run` and `make open` build and launch the packaged app. `make demo-run`
launches it with a checkout-local fake library and fake iPod. All three can
activate a window, so do not use them for automated verification. Use them only
when the user requested an interactive launch.

## Build behavior

The Makefile's SwiftPM wrapper isolates mutable `.build` state per checkout and
bounds compiler load across worktrees; see `VERIFICATION.md` for cache, slot,
job, watchdog, and sandbox settings. `make clean` removes only declared build
and test outputs — do not remove other `.scratch/` content, which may belong to
the user or another in-progress check.
