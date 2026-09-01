# Visualizers

The fold-down deck's big glass shows one *visualizer* at a time. Modes are
swappable at runtime: click the display to cycle, right-click it to pick one,
or use Controls ▸ Visualizer (⇧⌘V steps to the next). Settings ▸ Visualizers
[chooses which modes](#choosing-which-modes-are-offered) that cycle contains.

Built-in modes come in four families: the three plain instruments and six
[raster/demoscene effects](#raster-modes) in the table below, plus the five-mode
[head-unit pack](#the-head-unit-pack) — the display patterns a 2000s car deck
shipped with — and the four-mode [movie-screen pack](#the-movie-screen-pack) —
the animated wallpapers a late-90s flagship deck idled on. The whole faceplate
can also wear a different [tube colourway](#tube-colourways), and anyone can
add more modes, in Swift or as a JavaScript plugin file.

| Mode | What it is |
| --- | --- |
| `SPECTRUM` | A fine-pitch dot-matrix spectrum with slow peak caps and amber overload cells |
| `SCOPE` | The waveform as an oscilloscope trace |
| `WATERFALL` | A scrolling spectrogram |
| `PLASMA` | Multi-sine plasma, dithered to VFD levels, with shock rings on the kick |
| `FIRE` | The Amiga fire routine, its grate seeded from the spectrum |
| `TUNNEL` | A table-driven elliptical tunnel, speed and rings on the beat |
| `ROTOZOOM` | A rotating, zooming tiled plate texture that punches on the kick |
| `VECTORS` | Glenz solids tumbling down an avenue of pylons under a starfield |
| `METABALLS` | Five spectrum-driven charges, contour-banded where they merge |

## The idea

A visualizer is a pure function from data to drawing:

```
VisualizerFrame  ──▶  draw()  ──▶  GraphicsContext
```

Everything a mode may read arrives in the frame — the FFT bands of the audio
actually being rendered, the waveform, the level, the transport, the track,
and the size of the glass. Nothing reaches back into the player. That is what
makes the modes interchangeable, what lets a plugin run safely on a background
thread, and what lets any mode be rendered to a PNG with no app running.

| File | What it holds |
| --- | --- |
| [`Visualizer.swift`](../Sources/Nightdrive/Visualizers/Visualizer.swift) | `VisualizerFrame`, the palette, the `Visualizer` protocol |
| [`VisualizerColorway.swift`](../Sources/Nightdrive/Visualizers/VisualizerColorway.swift) | The named tube colours and how the choice is persisted |
| [`BuiltInVisualizers.swift`](../Sources/Nightdrive/Visualizers/BuiltInVisualizers.swift) | The three plain instruments |
| [`HeadUnit/`](../Sources/Nightdrive/Visualizers/HeadUnit) | The head-unit pack and the machinery behind it |
| [`Demoscene/`](../Sources/Nightdrive/Visualizers/Demoscene) | The six raster effects, one file each |
| [`MovieScreen/`](../Sources/Nightdrive/Visualizers/MovieScreen) | The movie-screen pack: four animated-wallpaper scenes |
| [`VisualizerRaster.swift`](../Sources/Nightdrive/Visualizers/VisualizerRaster.swift) | The low-resolution intensity buffer and its ink ramps |
| [`VisualizerMath.swift`](../Sources/Nightdrive/Visualizers/VisualizerMath.swift) | Sine tables, 3D helpers, `AudioEnergy` |
| [`VFDDotFont.swift`](../Sources/Nightdrive/Visualizers/VFDDotFont.swift) | The 5×7 dot font the scrollers draw with |
| [`VisualizerRegistry.swift`](../Sources/Nightdrive/Visualizers/VisualizerRegistry.swift) | Every mode, built-in and plugin |
| [`VisualizerCatalog.swift`](../Sources/Nightdrive/Visualizers/VisualizerCatalog.swift) | Which modes are switched on, and in what order |
| [`VisualizerSample.swift`](../Sources/Nightdrive/Visualizers/VisualizerSample.swift) | The synthetic frame the previews are drawn from |
| [`VisualizerScriptRuntime.swift`](../Sources/Nightdrive/Visualizers/VisualizerScriptRuntime.swift) | The JavaScript bridge and the plugin API |
| [`DisplayList.swift`](../Sources/Nightdrive/Visualizers/DisplayList.swift) | How plugin drawing crosses back into Swift |
| [`VisualizerView.swift`](../Sources/Nightdrive/UI/VisualizerView.swift) | The deck's glass and the mode-switching UI |
| [`Settings/VisualizerSettingsView.swift`](../Sources/Nightdrive/UI/Settings/VisualizerSettingsView.swift) | The Visualizers settings pane |

## Adding a mode in Swift

Conform a class to `Visualizer` and add it to `VisualizerRegistry.makeBuiltIns()`:

```swift
@MainActor
final class LevelVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(id: "level", name: "LEVEL")

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let width = frame.width * frame.level
    ctx.glowing(frame.palette.glow)
      .fill(
        Path(CGRect(x: 0, y: 0, width: width, height: frame.height)),
        with: .color(frame.palette.glow.color))
  }
}
```

`reset()` is optional; implement it if the mode accumulates history, so
switching away and back doesn't show stale audio. Set
`wantsContinuousRedraw` on the descriptor if the mode animates on its own
clock rather than on the audio — otherwise it redraws when the analysis
updates, which costs nothing while paused.

Swift modes appear automatically under *Built-in* in Settings ▸ Visualizers,
JavaScript modes under *Plugins*; a new mode needs no presentation metadata.

Draw in the palette (`glow`, `amber`, `dim`, `ghost`) rather than picking
colours, so every mode looks like it came off the same tube — and so it
follows the user's [colourway](#tube-colourways) for free. Batch fills into
a few `Path`s instead of shading each cell separately: a VFD grid is hundreds
of rectangles and one glow filter per rectangle is what makes a `Canvas` crawl.

## Raster modes

Vector drawing cannot express plasma, fire, tunnels or rotozoomers — those are
per-pixel effects, and drawing a pixel as a filled rect is exactly the thing
above that makes the deck crawl. `VisualizerRaster` is the way out: a small
intensity buffer a mode writes into, converted to one `CGImage` and drawn with
a single call.

```swift
@MainActor
final class RippleVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(id: "ripple", name: "RIPPLE",
                                        wantsContinuousRedraw: true)
  private let raster = VisualizerRaster()
  private let energy = AudioEnergy()

  func reset() { energy.reset(); raster.clear() }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    energy.update(frame)
    raster.configure(for: frame.size, rows: 28)
    guard !raster.isEmpty else { return }

    for y in 0..<raster.height {
      for x in 0..<raster.width {
        let d = Double(x) / 9 + Double(y) / 5 + energy.flow
        raster.set(x, y, UInt8(VFDTrig.wave(d) * 255))
      }
    }

    if let boot = frame.boot { raster.strike(boot) }
    raster.blit(into: &ctx, in: CGRect(origin: .zero, size: frame.size),
                ramp: .phosphor(frame.palette), levels: 6)
  }
}
```

### The buffer

The grid is *intensity only* — one `UInt8` per dot, 0…255. Colour is applied at
blit time from the frame's palette, so an effect written once inherits whatever
tube colourway is active without knowing anything about it. Never write an RGB
value into an effect.

Size it once per frame with one of:

- `configure(for: frame.size, cell: 3.4)` — dots of roughly `cell` points.
- `configure(for: frame.size, rows: 28)` — a fixed number of rows, width
  following the glass's proportions. Better for anything with a horizon.

Both clamp to 8…640 × 4…160, both return `true` when the shape changed (drop
any per-column state you were caching), and both leave the raster **empty** for
a zero-sized or non-finite glass — always `guard !raster.isEmpty else { return }`.
The pixel, scratch and RGBA buffers are reused once the shape settles; only the
final blit copies the RGBA bytes into image-owned storage, intentionally,
because the `CGImage` can outlive the next frame that overwrites the buffer.

### Writing into it

| Call | What it does |
| --- | --- |
| `clear()` | Zeroes the grid |
| `set(x, y, v)` | Writes one dot |
| `value(x, y)` | Reads one dot, 0 outside |
| `plot(x, y, v)` | Additive, saturating at 255 |
| `plot(x: Double, y: Double, value:)` | Additive with bilinear spread — for sub-dot particles |
| `hspan(y:from:to:_:)` / `vspan(x:from:to:_:)` | Clipped runs; reversed bounds are fine |
| `line(from:to:_:)` | Bresenham between two `CGPoint`s |
| `sample(x:y:)` | Clamped read, for feedback and texture lookups |
| `decay(_:drop:)` | Multiply-and-subtract over the whole grid — phosphor trails |
| `convectUp(cooling:sway:jitter:salt:)` | The fire kernel: pull each row from the one below, cooled and jittered |
| `bloom(amount:)` | Cheap horizontal spread, to soften a hard edge |

`VisualizerRaster.hash(x:y:salt:)` is a `nonisolated` value hash for
deterministic per-dot noise, and `DemoNoise` in
[`Demoscene/DemoSupport.swift`](../Sources/Nightdrive/Visualizers/Demoscene/DemoSupport.swift)
adds a xorshift generator and `smooth()` value noise for coherent texture.
`DemoSupport` also adds `raster.strike(boot)` and `raster.wipe(_:)` for the
power-on self-test, and `raster.text(_:from:value:scale:)` to stamp the dot
font.

### Getting it on the glass

```swift
raster.blit(into: &ctx, in: rect, ramp: .phosphor(frame.palette), levels: 6)
```

`levels` is the bit depth. The buffer is quantized through an ordered Bayer
screen on the way out, which is what makes a smooth field look like a dot-matrix
panel resolving it rather than like a gradient. Six to nine levels reads as a
VFD; two or three reads as a 1-bit LCD.

Ramps map intensity to ink: `.phosphor` (dark → ghost → dim → glow),
`.heat` (…→ glow → amber) and `.amber`, or build a `VisualizerInkRamp` from
your own `VisualizerInkStop`s. **The top of the ramp is a trap**: with `levels: N`
a quantized dot lands on exactly `k/(N-1)`, so anything that saturates hits the
last stop, and a ramp ending in amber turns whole plateaus orange. Cap an
effect's base brightness around 0.6–0.8 and keep the top of the range for beat
highlights.

### Reading the music

`AudioEnergy` in
[`VisualizerMath.swift`](../Sources/Nightdrive/Visualizers/VisualizerMath.swift)
turns a frame into what an effect actually wants:

- `bass`, `mid`, `treble`, `level` — smoothed with a fast attack and slow
  release, and **auto-gained** against a peak follower, so a quiet track still
  fills the glass and a loud one doesn't clip.
- `beat` — 1 the instant a spectral-flux onset lands, decaying over a third of
  a second. `beatCount` and `sinceBeat` come with it.
- `flow` — a free-running phase in turns that advances with the music rather
  than with the wall clock, so an effect idles when the track does.
- `band(frame, i, of: n)` — one auto-gained bar of the spectrum, for effects
  that want its shape rather than three summary numbers.

`update(frame)` returns the seconds elapsed **and returns 0 on a repeat frame**.
Draws outpace the analyzer, so step your own state by that return value rather
than assuming one draw is one tick.

`VFDTrig` has 4096-entry sine tables — note the angles are in **turns**, not
radians — and `Vec3` / `Mat3` / `VFDCamera` cover the wireframe modes.
`VFDCamera.project` returns `nil` behind the camera and scales by the glass's
*short* side, which is what keeps a 3D object from being stretched into a smear
on a strip this wide.

### Composing for a responsive strip

The deck does not have one canonical drawable size. Its width follows the
window, and the live visualizer shares a 108-point-tall glass with artwork,
metadata, transport time and insets. Settings and the headless renderer hand
the same mode different shapes again. Keep these explicit reference geometries
in the test matrix:

| Reference | Geometry | What it exercises |
| --- | --- | --- |
| Wide strip | 770 × 45 | The roughly 17:1 layout used for performance measurements |
| Compact strip | 330 × 44 | A narrow-window regression target |
| Settings preview | 320:96 aspect | The wider Settings card, whose actual point size follows its container |
| CLI default | 900 × 64 | The default headless preview when `--size` is omitted |

Effects therefore have to be built for responsive, wide-and-short spaces, not
ported from a square demo:

- Ellipses, never circles. A tunnel's rings need a squash factor.
- Converging perspective rails come out nearly horizontal and read as nothing;
  use receding *pylons* instead.
- A tiled texture wants about two tiles vertically. Twenty-six is confetti.
- Anything stacked (bars, layers) needs a fixed station per element, or
  the stack bunches into a single lit band whenever the sines agree.
- Hard checkerboard parity aliases badly once the texture is finer than the dot
  grid. Smooth waves plus a detail fade toward flat grey — a mip-map substitute
  — is what makes depth read.

### Cost

Measured in release at 770 × 45, per `draw` call, against a 41.7 ms budget at
24 Hz: the raster modes run 0.15–0.4 ms. The three plain instruments run about 0.05 ms.
All of it is one `CGImage` per frame into a single `ctx.draw`, with the pixel
and ARGB buffers reused across frames.

## The head-unit pack

[`Visualizers/HeadUnit/`](../Sources/Nightdrive/Visualizers/HeadUnit) holds the
display patterns a 2000s car deck shipped with. They register together through
`HeadUnitVisualizers.all()`, so the pack costs `makeBuiltIns()` one line.

| Mode | What it is |
| --- | --- |
| `VU` | Twin analogue meters with real ballistics — the needle overshoots a transient and sags back between beats — on a lit face with a red zone, engraved numerals and a peak lamp, with the transport between them |
| `EQ CURVE` | The graphic-equalizer screen: a slider per band showing that band's departure from the overall balance, splined into a curve with the area under it filled, and the band centres lettered underneath |
| `RIPPLE` | A body of light whose surface swells on the bottom end, throws an expanding ring off every beat, and is reflected in the waterline below it |
| `MARQUEE` | `ARTIST - TITLE - ALBUM` crawling in 5×7 dot-matrix characters, with the indicator cluster (`MP3`/`ST`/`RPT`/`RDM`/`LOUD`/`EQ`) along the top and a bass-driven underline along the bottom |
| `COMBO` | The split screen: analyzer on the left, what's playing and two segmented level ladders with held peaks on the right |

[`HeadUnitSupport.swift`](../Sources/Nightdrive/Visualizers/HeadUnit/HeadUnitSupport.swift)
holds the shared machinery, all of it plain value types with no drawing in
them so the physics can be checked without a `Canvas`:

| Type | What it does |
| --- | --- |
| `DotMatrix` | The 5×7 font, its metrics, the unlit ghost grid, and folding of anything the panel can't letter |
| `PeakCaps` | Peak-hold caps: snap up instantly, hang for `hold` seconds, then accelerate down under `gravity` |
| `NeedleBallistics` | A meter needle as an under-damped mass on a spring, damped harder falling than rising |
| `BeatDetector` | Bass energy against a fast-attack running average, with a refractory gap and a decaying `pulse` |

All four clamp their time step and treat a clock that jumps backwards — which
is what a mode switch does — as a single frame, so nothing flies off the panel.

## The movie-screen pack

[`Visualizers/MovieScreen/`](../Sources/Nightdrive/Visualizers/MovieScreen)
holds the animated wallpapers — the aquarium-on-the-dashboard genre a late-90s
Kenwood or Pioneer flagship idled on. Each one is a raster scene that lives on
the synthetic frame's music: nothing in it is decoration that ignores the track.
They register together through `MovieScreenVisualizers.all()`.

| Mode | What it is |
| --- | --- |
| `AQUARIUM` | A tank in cross-section: a fish school that darts on every kick, bubbles streaming off the vents with the treble and popping amber at the surface, kelp swaying with the bass, dappled caustic light and leaning shafts, sand, and a wavering glinting waterline |
| `NIGHT DRIVE` | The windshield at 2 AM: a flat-plane three-lane highway whose lane dashes stream at music speed and lunge on the kick, high beams pooling on the asphalt with the bass, shoulder reflectors glinting past, curvature that swings two parallax skylines the other way — the near one an equalizer whose towers burn with their own spectrum bands — streetlights fixed in world space, slower traffic reeled in and swept past on the kicks, and oncoming headlights spawning on the onsets |
| `FIREWORKS` | A harbor show: shells launch on onsets with size following the bass, bursts rotate peony / ring / willow, sparks decay through a trail buffer, the flash lights the city's windows, and the whole sky reflects — shimmering — in the water |
| `DOLPHINS` | Pioneer's signature: a pod cruising as shadows under moonlit swell that breathes with the bass, leaping in ballistic arcs on the kicks — two on a heavy one — with spray at the exit and the entry, under a moon laying a glitter path on the water |

[`MovieScreenSupport.swift`](../Sources/Nightdrive/Visualizers/MovieScreen/MovieScreenSupport.swift)
holds `CitySkyline`, the deterministic silhouette-and-windows generator NIGHT
DRIVE and FIREWORKS share. All four scenes run the fixed-step simulation
pattern from the raster modes, keep their sprites in world or normalized
coordinates so a resize re-composes rather than breaks, and reserve the ink
ramp's amber stop for what actually saturates: surface glints, headlight
glare, taillights, willow sparks, the moon's core.

## Tube colourways

Which colour a head unit's display burned in was half its character, so the
tube colour is a theme. Controls ▸ Visualizer ▸ Tube Color picks one, and the
choice is persisted next to the selected mode.

| Id | Name | The tube |
| --- | --- | --- |
| `vfd` | MINT VFD | The default: mint-green vacuum fluorescent with amber overload |
| `ice` | ICE BLUE | Alpine's ice blue, with amber for anything that mattered |
| `xplod` | XPLOD RED | Sony Xplod: red glass and orange highlights |
| `amber` | AMBER GOLD | Kenwood's amber dot matrix with green accents |
| `arctic` | ARCTIC LCD | The cold white backlight behind a black LCD faceplate |
| `plasma` | PLASMA VIOLET | The aftermarket special: violet glass, hot pink overload |

A colourway is a `VisualizerPalette` with a stable id, threaded into
`VisualizerFrame.palette` before any mode is asked to draw — so any mode that
draws in the palette instead of hard-coding colours is themed automatically,
built-ins and JavaScript plugins alike (a plugin's
`'glow'`/`'amber'`/`'dim'`/`'ghost'` names resolve against the same palette).
The rest of the faceplate — toolbar VFD, seven-segment clock, deck chrome,
artwork tint — reads the same theme, so a colourway is never half-applied.

Adding one means appending to `VisualizerColorway.all` with an id that never
changes afterwards, since that id is what gets written to defaults. An id that
no longer exists falls back to the default tube rather than leaving the glass
unpainted.

## Choosing which modes are offered

With the built-ins, the packs and any plugins there are close to thirty modes.
**Settings ▸ Visualizers** is where that list gets shortened: every registered
mode listed under *Built-in* or *Plugins*, searchable, each with a mark showing
whether it's in the rotation, and a live preview of the selected mode in the
current tube colour, drawn from the same synthetic frame the CLI previews use.

Two controls sit under the preview and they are deliberately different things.
**Show on the Deck** is an action: it puts that mode on the glass now and folds
the deck open. **Keep in the rotation** is a standing choice: whether the deck
stops on that mode as it cycles.

It is an opt-out tool over a default of everything on: a fresh install offers
every mode there is, and the user switches things *off* if they want a shorter
rotation. What's switched on **is** the rotation, in order — there is no
separate cycle list. Switching a mode off takes it out of the ⇧⌘V rotation,
the click-to-cycle order and the Controls ▸ Visualizer menu; if it was showing
on the deck, the deck moves to the next enabled mode immediately. Rows can be
dragged to reorder the cycle.

The deck can never end up blank. The last mode left on can't be switched off,
and if the enabled set somehow empties anyway — the only mode left on was a
plugin whose file got deleted — every mode is offered again rather than none.

[`VisualizerCatalog`](../Sources/Nightdrive/Visualizers/VisualizerCatalog.swift)
persists the *disabled* ids, not the enabled ones, which is what makes the
behaviour around a changing mode list right:

- Nothing stored means nothing disabled: an empty or missing set is **all
  enabled**, never none.
- A mode nobody has ever heard of — a new built-in after an update, a plugin
  dropped in this morning — is **on** by default. Work is never hidden behind
  a preference the user didn't set.
- A plugin switched off, deleted, and dropped back in later is still off; the
  id is remembered even while nothing claims it.
- An id that no longer matches any mode is ignored, not pruned, and never
  crashes. Same for the saved order: unknown ids sort out, new ids append.

## Adding a mode in JavaScript

Every `.js` file in
`~/Library/Application Support/Nightdrive/Visualizers` is discovered in the
background at startup. Built-in modes are available immediately; plugins and
their diagnostics appear together when discovery finishes.
Controls ▸ Visualizer ▸ Open Visualizers Folder… creates it, seeded with a
getting-started README and the seven worked examples below. After editing,
choose Reload Plugins. Settings ▸ Visualizers has the same two commands in the
Actions menu on its status bar, and anything that failed to load is reported
in a banner across the top of the pane, with the file, the message and the
line.

A plugin is JavaScript running inside the app, so a file appearing in the
folder is not consent to run it: running is opt-in per file. Shipped examples
are auto-approved. Every other `.js` file — new, renamed, or an edit of
something previously approved — waits in a Settings ▸ Visualizers banner until
you approve it. An approval covers the exact bytes reviewed (name plus content
hash, recorded in Nightdrive's own preferences, never in the plugins folder,
where whatever wrote the plugin could forge it), so editing an approved plugin
sends it back to pending. The one exception is the CLI's `--dir`: naming a
folder on the command line is itself consent.

```js
registerVisualizer({
  id: 'my-mode',       // stable and unique; this is what gets remembered
  name: 'My Mode',     // shown on the glass, upper-cased
  continuous: true,    // false if you only move when the audio does
  draw(frame, gfx) {
    gfx.rect(0, 0, frame.width * frame.level, frame.height,
             { color: 'glow', glow: true })
  },
  reset() {}           // optional: drop accumulated state
})
```

### `frame`

| Field | Meaning |
| --- | --- |
| `width`, `height` | The glass, in points, origin top-left |
| `time` | Seconds since this mode became visible |
| `spectrum`, `peaks` | Log-spaced FFT bands, 0…1, low to high |
| `waveform` | The rendered samples, -1…1 |
| `level` | Smoothed output level, 0…1 |
| `elapsed`, `duration`, `isPlaying` | Transport |
| `title`, `artist`, `album` | The current track |
| `boot` | 0…1 while the deck's tube is striking, else `null` |
| `band(i, n)`, `peak(i, n)` | Spectrum resampled to `n` bars |
| `wave(fraction)` | Waveform sampled at 0…1 across the glass |
| `energy(lo, hi)` | Mean spectrum energy over a 0…1 slice of the range |
| `bass`, `mid`, `treble` | Shorthand for the three obvious slices |
| `beat` | 1 on an onset, decaying to 0 — a kick envelope |
| `beats` | Onsets counted since this mode became visible |

`band`, `peak`, `wave` and `energy` clamp their arguments. `beat` is derived in
the plugin bridge from the low end of the spectrum the plugin was already
given: it is a convenience for plugin authors, not another analysis stage.

### `gfx`

| Call | Draws |
| --- | --- |
| `rect(x, y, w, h, opts)` | A filled rectangle |
| `line(x1, y1, x2, y2, opts)` | One stroke |
| `path(points, opts)` | A polyline; `closed` and `fill` apply |
| `circle(cx, cy, r, opts)` | A circle, outlined unless `fill` |
| `ellipse(x, y, w, h, opts)` | An ellipse in a bounding box |
| `arc(cx, cy, rx, ry, from, to, opts)` | An arc, or a wedge with `fill` |
| `dots(points, opts)` | Many points in one op; `size`, `round` |
| `segments(list, opts)` | Many `[x1, y1, x2, y2]` strokes in one op |
| `text(string, x, y, opts)` | A monospaced string; `size`, `align` |
| `measure(string, size)` | That string's width in points |

`points` is `[[x, y], …]` or a flat `[x, y, x, y, …]`. `opts` takes `color`,
`alpha`, `glow` (`true` or a blur radius), `width`, `fill`, `closed`, `size`,
`round`, and `align` (`'leading'`, `'center'`, `'trailing'`).

`dots` and `segments` exist for the same reason the Swift modes build one
`Path` per pass: a thousand `line` calls are a thousand strokes and a thousand
glow filters, while one `segments` call is one of each. `arc` is sugar over
`path`, so curves cost the display list nothing new. All three clamp their
point count to `DisplayList.batchLimit` (20,000) on the JavaScript side, and
the decoder clamps it again on the way in.

#### Name the ink, don't pick the paint

`color` accepts `'glow'` (the tube's primary), `'amber'` (peaks, warnings),
`'dim'` (labels) and `'ghost'` (grids and unlit cells) — and also `'#4cffd6'`
or `[r, g, b]` in 0…1, for the rare case where a colour is part of the idea.

Prefer the names. The tube's colour is a user setting, so a plugin that names
its inks changes colour with the rest of the app, while one that hard-codes
mint stays mint on a red tube and looks broken. Every shipped example follows
this rule.

Remember the deck's glass is **wide and short** — a few dozen points tall.
Lay work out on an ellipse rather than a circle, as `radar.js` does, and write
vertical measurements as fractions of `frame.height`.

### The plugins folder

The first time Nightdrive creates the Visualizers folder, it copies in the
README and shipped examples. From then on the folder is entirely yours:
Nightdrive never overwrites, restores, or adds files to an existing folder.
New or revised examples in a later version remain available in the app bundle
and source tree instead. `NIGHTDRIVE_VISUALIZER_DIR` and the CLI's `--dir`
follow the same rule.

### The shipped examples

The examples are the API's documentation by example: each one is a self-contained
file that teaches a different corner of it, and each is loaded, drawn, reset
and drawn again by the test suite, so a change to the bridge that breaks one
fails the build.

| File | Idea | Teaches |
| --- | --- | --- |
| `vectorscope.js` | A rack of Lissajous cells with phosphor trails | `frame.wave()`, `gfx.path()` |
| `hyperwarp.js` | A star tunnel that punches to warp on the kick | `frame.beat`, `dots` + `segments` |
| `wireframe.js` | Five solids tumbling over a perspective floor | 3D maths in a plugin |
| `radar.js` | A beam painting the spectrum as decaying contacts | `gfx.arc()`, polar layout |
| `constellation.js` | A particle mesh blown apart by bass | State across frames |
| `glyph-rain.js` | Falling glyphs with the title decoding out of them | `gfx.text()`, per-column state |
| `eq-ladder.js` | A car head-unit graphic EQ with peak caps | That a real fascia is doable in JS |

### What plugins can and can't do

The JavaScriptCore context is bare: no file system, no network, no timers, no
`require`, no DOM. A plugin gets its frame, the drawing API, and `console.log`
(which prints to stderr). Each file is wrapped in its own closure, so plugins
keep state in module scope without colliding with each other.

Plugin code runs on a private serial queue, never the main thread, and plugin
folder discovery runs outside the main actor too. Drawing crosses back as a
flat display list, so a plugin renders one frame behind — invisible at 24 Hz.
Every call into a plugin — loading its file, drawing a frame — is bounded by a
JavaScriptCore execution time limit, so a plugin caught in an infinite loop is
interrupted, switched off and reported as failed, the same as one that throws,
while the app keeps loading and drawing everything else — at startup and on
Reload Plugins alike, so a runaway plugin can't brick a launch or wedge the
recovery path. Plugins do share the one queue, so a runaway one can briefly
stall the others until the watchdog trips; it can't freeze them indefinitely.
A plugin that throws shows its error on the glass, naming the file and the
line inside it. Plugins can't take an id that belongs to a built-in mode.

## Checking a mode without launching the app

```bash
Nightdrive visualizers
```

lists every registered mode and renders one synthetic frame through each
plugin, reporting load errors and exceptions with line numbers. Exit status is
non-zero if anything failed, so it works as a check in a script.

```bash
Nightdrive visualizers --dir .scratch/plugins --render .scratch/previews
Nightdrive visualizers --render .scratch/deck --size 770x45      # wide strip
Nightdrive visualizers --render .scratch/deck --size 330x44      # compact strip
Nightdrive visualizers --render .scratch/deck --colorway all     # every tube
```

`--render <dir>` writes a PNG preview of every mode, and `--dir <folder>` reads
plugins from somewhere other than the real folder. `--size <WxH>` renders at a
chosen reference size in points instead of the 900 × 64 CLI default; `770x45`
is the wide-strip reference used by the performance numbers above. Use both
wide and compact probes — no single value represents every window width or the
320:96 Settings preview. `--colorway` takes a colourway id or `all`; with more
than one, previews are written as `<id>-<colorway>.png`.

Previews use a synthetic frame with real levels and a 120 BPM kick in it, which
is also the only way to see a mode with signal: the demo library is made of
silent MP3s, so nothing in `make snapshots` drives the analyzer. Stateful modes
are played in for a couple of seconds before the shot, so falling peak caps,
needle ballistics, waterfalls and phosphor trails have something to show.

`make snapshots` additionally captures the deck showing every registered mode
as `deck-<id>.png`, with `NIGHTDRIVE_VISUALIZER_DIR` pointed at a scratch
plugin folder so the tour covers the same modes on every machine. But the
tour's window is never composited, so its animation timeline does not tick and
any mode that accumulates over frames — `WATERFALL`, `FIRE` — arrives with only
its first frame drawn; the sized CLI preview is how those get judged.

The tour also shoots the settings window — `settings-general.png`,
`settings-ipod-sync.png`, `settings-visualizers.png` (and
`settings-visualizers-last.png`, which selects the last registered mode, usually
a plugin), `settings-online.png`, and `settings-about.png` — one shot per tube
colourway, and the states that are otherwise hard to see: a search that matches
nothing, modes out of the rotation, and a plugin that won't parse.
That failed-plugin state is made real rather than faked: a script that
genuinely cannot parse is dropped in the scratch folder and taken away again,
only ever against a redirected folder, so an automated run can never write into
your own plugins. `make snapshots-settings` shoots only the settings states —
the fast loop when the settings window is what you are changing.
