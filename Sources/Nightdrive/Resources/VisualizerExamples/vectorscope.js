registerVisualizer({
  id: 'vectorscope',
  name: 'Vectorscope',

  draw(frame, gfx) {
    const cells = Math.max(1, Math.min(6, Math.round(frame.width / (frame.height * 3.4))));
    const cellWidth = frame.width / cells;
    const ry = frame.height * 0.4;
    const rx = Math.min(cellWidth * 0.44, ry * 2.4);
    const cy = frame.height * 0.47;

    graticule(gfx, frame, cells, cellWidth, cy, rx, ry);

    const push = frame.time - lastPush >= 1 / 24;
    if (push) lastPush = frame.time;

    const gain = (0.62 + frame.level * 0.55) * (1 + frame.beat * 0.4);
    let correlation = 0;

    for (let cell = 0; cell < cells; cell++) {
      const cx = (cell + 0.5) * cellWidth;
      const delay = 0.02 + cell * 0.032 + 0.018 * Math.sin(frame.time * 0.31 + cell);

      const trace = [];
      let dot = 0;
      for (let i = 0; i < POINTS; i++) {
        const t = i / (POINTS - 1);
        const l = frame.wave(t);
        const r = frame.wave(t + delay > 1 ? t + delay - 1 : t + delay);
        dot += l * r;
        trace.push(
          cx + (l - r) * 0.7071 * rx * gain,
          cy - (l + r) * 0.7071 * ry * gain
        );
      }
      correlation += dot / POINTS / 0.5;

      const history = ghosts[cell] || (ghosts[cell] = []);
      if (push) {
        history.unshift(trace);
        if (history.length > GHOSTS) history.length = GHOSTS;
      }

      for (let age = history.length - 1; age >= 0; age--) {
        const live = age === 0;
        gfx.path(history[age], {
          color: live && frame.beat > 0.45 ? 'amber' : 'glow',
          alpha: live ? 1 : 0.45 / (age + 1),
          width: live ? 1.5 : 1,
          glow: live ? 3 : 0
        });
      }
      gfx.circle(trace[0], trace[1], 1.5, { color: 'amber', fill: true, glow: 3 });
    }

    const phase = frame.isPlaying ? correlation / cells : 0;
    gfx.text('X / Y  \u00D7' + cells, 6, frame.height - 6, { size: 7, color: 'dim' });
    gfx.text(
      'PHASE ' + (phase >= 0 ? '+' : '') + phase.toFixed(2),
      frame.width - 6, frame.height - 6,
      { size: 7, color: Math.abs(phase) > 0.9 ? 'amber' : 'dim', align: 'trailing' }
    );
  },

  reset() {
    ghosts.length = 0;
    lastPush = -1;
  }
});

const POINTS = 96;
const GHOSTS = 4;
const ghosts = [];
let lastPush = -1;

function graticule(gfx, frame, cells, cellWidth, cy, rx, ry) {
  const marks = [];
  for (let cell = 0; cell < cells; cell++) {
    const cx = (cell + 0.5) * cellWidth;
    gfx.ellipse(cx - rx, cy - ry, rx * 2, ry * 2, { color: 'ghost' });
    marks.push(
      [cx - rx * 0.12, cy, cx + rx * 0.12, cy],
      [cx, cy - ry * 0.16, cx, cy + ry * 0.16]
    );
    for (let i = 0; i < 4; i++) {
      const angle = Math.PI / 4 + (i * Math.PI) / 2;
      marks.push([
        cx + Math.cos(angle) * rx * 0.84, cy + Math.sin(angle) * ry * 0.84,
        cx + Math.cos(angle) * rx * 1.04, cy + Math.sin(angle) * ry * 1.04
      ]);
    }
    if (cell > 0) {
      marks.push([cell * cellWidth, 2, cell * cellWidth, frame.height - 12]);
    }
  }
  gfx.segments(marks, { color: 'ghost', width: 1 });
}
