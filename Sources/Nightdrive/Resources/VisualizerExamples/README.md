# Nightdrive visualizers

Every `.js` file in this folder is a plugin for the fold-down deck. Drop one
in, choose **Controls ▸ Visualizer ▸ Reload Plugins**, and it shows up in the
mode list next to the built-in ones.

The seven `.js` files sitting next to this README are working examples, meant
to be read, copied and hacked on. Delete the ones you don't want; they are only
written once, when this folder is created.

## The smallest plugin that works

```js
registerVisualizer({
  id: 'hello',              // stable and unique; this is what gets remembered
  name: 'Hello',            // shown on the glass, upper-cased
  continuous: true,         // false = only redraw when the audio moves
  draw(frame, gfx) {
    gfx.rect(0, frame.height / 2 - 4, frame.width * frame.level, 8, {
      color: 'glow',
      glow: true
    });
  },
  reset() {}                // optional; called when the mode is switched away
});
```

One file may register several modes. `draw` is called about 24 times a second
while the deck is open, and never on the main thread.

## The glass is wide and short

Roughly 480×46 points in the app — a letterbox, not a square. Circles waste it;
ellipses, horizons and things that run left to right fill it. Every example
here composes for that shape, and every vertical measurement is written as a
fraction of `frame.height` so it survives a resize.

## `frame`

| field | meaning |
| --- | --- |
| `width`, `height` | the glass, in points, origin top-left |
| `time` | seconds since this mode became visible |
| `spectrum`, `peaks` | log-spaced FFT bands, 0…1, low to high |
| `waveform` | the samples being played, -1…1 |
| `level` | smoothed output level, 0…1 |
| `elapsed`, `duration`, `isPlaying` | transport |
| `title`, `artist`, `album` | the current track |
| `boot` | 0…1 while the tube is striking, `null` the rest of the time |
| `band(i, n)`, `peak(i, n)` | the spectrum resampled to `n` bars |
| `wave(t)` | the waveform sampled at `t` = 0…1 across the glass |
| `energy(lo, hi)` | mean spectrum energy over a 0…1 slice of the range |
| `bass`, `mid`, `treble` | shorthand for the three obvious slices |
| `beat` | 1 on an onset, decaying to 0 — a kick envelope |
| `beats` | how many onsets since this mode became visible |

`band`, `peak` and `wave` clamp their arguments, so you can hand them anything.

## `gfx`

| call | draws |
| --- | --- |
| `rect(x, y, w, h, opts)` | a rectangle, filled |
| `line(x1, y1, x2, y2, opts)` | one stroke |
| `path(points, opts)` | a polyline through `[[x, y], …]`; `closed`, `fill` |
| `circle(cx, cy, r, opts)` | a circle, outlined unless `fill` |
| `ellipse(x, y, w, h, opts)` | an ellipse in a bounding box |
| `arc(cx, cy, rx, ry, from, to, opts)` | an arc, or a filled wedge with `fill` |
| `dots(points, opts)` | many points in one call; `size`, `round` |
| `segments(list, opts)` | many `[x1, y1, x2, y2]` strokes in one call |
| `text(string, x, y, opts)` | a monospaced string; `size`, `align` |
| `measure(string, size)` | how wide that string will be, in points |

`opts` accepts `color`, `alpha`, `glow` (`true` or a blur radius), `width`,
`fill`, `closed`, `size`, `round` and `align` (`'leading'`, `'center'`,
`'trailing'`).

**Use `dots` and `segments` for anything you draw more than a handful of.**
A thousand `line` calls are a thousand strokes and a thousand glow passes; one
`segments` call is one of each. The examples lean on this hard — the warp
tunnel, the constellation and the wireframe are each a couple of batched calls
a frame.

## Colour: name the ink, don't pick the paint

```js
gfx.line(0, y, frame.width, y, { color: 'glow' });   // yes
gfx.line(0, y, frame.width, y, { color: '#4cffd6' }); // no
```

| ink | what it is |
| --- | --- |
| `'glow'` | the tube's primary colour — the bright thing |
| `'amber'` | the warning/accent colour: peaks, overload, highlights |
| `'dim'` | labels and readouts |
| `'ghost'` | grids, rings, unlit cells |

The deck's tube colour is a user setting. A plugin that names its inks changes
colour with the rest of the app; a plugin that hard-codes `'#4cffd6'` stays
mint on a red tube and looks broken. Literal `'#rrggbb'` and `[r, g, b]` in
0…1 do work, for the rare case where a colour is genuinely part of the idea.

## The sandbox

Each file is evaluated once, in its own closure, in a bare JavaScriptCore
context. There is no filesystem, no network, no timers, no `require`, no DOM
and no `window` — a plugin gets `frame`, `gfx`, `Math`, `JSON` and
`console.log`, which goes to the app's standard error.

Because the file is a closure, module-scope state is yours to keep between
frames; that's how the warp tunnel remembers its stars. Implement `reset()` to
clear it, and derive motion from `frame.time` rather than counting frames, so
a dropped frame doesn't slow you down.

Plugins run on a private queue, one frame behind what you hear, and a mode
that throws is dropped for that frame with the error shown on the glass. A
plugin cannot take an `id` that belongs to a built-in mode.

## Checking your work without launching the app

```sh
Nightdrive visualizers                            # list and smoke-test every mode
Nightdrive visualizers --dir ./my-plugins         # …from somewhere else
Nightdrive visualizers --render ./previews        # PNG of every mode
```

It exits non-zero if a plugin fails to load or throws while drawing, and the
message carries the file name and the line number.

## The examples

| file | what it shows off |
| --- | --- |
| `vectorscope.js` | a rack of Lissajous cells — `frame.wave()` and `gfx.path()` |
| `hyperwarp.js` | a star tunnel that punches to warp on the kick — `frame.beat` |
| `wireframe.js` | five solids tumbling over a perspective floor — 3D by hand |
| `radar.js` | a sweeping beam painting the spectrum as contacts — `gfx.arc()` |
| `constellation.js` | a particle mesh blown apart by bass — state across frames |
| `glyph-rain.js` | falling glyph columns with the title decoding out of them |
| `eq-ladder.js` | a car head-unit graphic EQ, peak caps and all, in JS |

They are yours: edit them, delete them, keep your own files beside them.
Nightdrive never overwrites, restores, or adds files after it creates this
folder; new or revised examples in a later version live in the app bundle and
source tree without changing your copy.
