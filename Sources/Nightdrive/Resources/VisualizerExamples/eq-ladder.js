registerVisualizer({
  id: 'eqladder',
  name: 'EQ Ladder',
  continuous: false,

  draw(frame, gfx) {
    const legend = 9;
    const top = 2;
    const usable = frame.height - legend - top;
    const rows = Math.max(5, Math.min(9, Math.floor(usable / 4)));
    const gutter = 46;
    const left = gutter;
    const right = frame.width - gutter;
    const bandWidth = (right - left) / BANDS.length;
    const cellHeight = usable / rows;

    if (caps.length !== BANDS.length) caps.length = 0;

    for (let band = 0; band < BANDS.length; band++) {
      const x = left + band * bandWidth + 1;
      const w = bandWidth - 3;
      const value = Math.max(
        frame.band(band, BANDS.length),
        frame.boot == null ? 0 : Math.max(0, 1 - Math.abs(band - frame.boot * BANDS.length) / 2)
      );
      const lit = Math.round(value * rows);

      for (let row = 0; row < rows; row++) {
        const y = top + usable - (row + 1) * cellHeight;
        const height = cellHeight - 1;
        const overload = row >= rows - 2;
        if (row < lit) {
          gfx.rect(x, y, w, height, {
            color: overload ? 'amber' : 'glow',
            glow: 2
          });
        } else if (overload) {
          gfx.rect(x, y, w, height, { color: 'amber', alpha: 0.16 });
        } else {
          gfx.rect(x, y, w, height, { color: 'ghost' });
        }
      }

      let cap = caps[band];
      if (!cap) cap = caps[band] = { value: 0, hold: 0, fall: 0 };
      if (value >= cap.value) {
        cap.value = value;
        cap.hold = HOLD;
        cap.fall = 0;
      } else if (cap.hold > 0) {
        cap.hold--;
      } else {
        cap.fall += 0.0016;
        cap.value = Math.max(0, cap.value - cap.fall);
      }
      if (cap.value > 0.02) {
        const y = top + usable - cap.value * usable - 1;
        gfx.rect(x, y, w, 1.6, { color: 'amber', alpha: 0.9, glow: 2 });
      }

      gfx.text(BANDS[band], x + w / 2, frame.height - 2, {
        size: 6.5, align: 'center', color: 'dim'
      });
    }

    meters(gfx, frame, left, right, top, usable);
  },

  reset() {
    caps.length = 0;
  }
});

const BANDS = [
  '63', '100', '160', '250', '400', '630', '1K',
  '1K6', '2K5', '4K', '6K3', '10K', '16K'
];
const HOLD = 14;
const caps = [];

function meters(gfx, frame, left, right, top, usable) {
  const ticks = 7;
  for (let i = 0; i < ticks; i++) {
    const on = frame.level * ticks > i;
    const y = top + usable - ((i + 1) / ticks) * usable;
    const hot = i >= ticks - 2;
    for (const x of [left - 12, right + 6]) {
      gfx.rect(x, y, 6, usable / ticks - 1.5, {
        color: on ? (hot ? 'amber' : 'glow') : 'ghost',
        glow: on && hot ? 2 : 0
      });
    }
  }

  gfx.text('GEQ', 4, 9, { size: 7, color: 'dim' });
  gfx.text(frame.isPlaying ? 'PLAY' : 'PAUSE', 4, 19, { size: 7, color: 'dim' });
  gfx.text('LOUD', frame.width - 4, 9, {
    size: 7,
    align: 'trailing',
    color: frame.bass > 0.55 ? 'amber' : 'dim',
    glow: frame.bass > 0.55 ? 2 : 0
  });
  const db = frame.level > 0.001 ? (20 * Math.log10(frame.level)).toFixed(0) : '-\u221E';
  gfx.text(db + ' dB', frame.width - 4, 19, { size: 7, align: 'trailing', color: 'dim' });
}
