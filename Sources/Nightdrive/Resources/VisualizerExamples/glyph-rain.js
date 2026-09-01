registerVisualizer({
  id: 'glyphrain',
  name: 'Glyph Rain',

  draw(frame, gfx) {
    const cell = 8;
    const count = Math.max(8, Math.floor(frame.width / 11));
    if (columns.length !== count) build(count, frame.height, cell);

    const step = Math.min(0.12, Math.max(0, frame.time - lastTime));
    lastTime = frame.time;

    const label = (frame.title || 'NO SIGNAL').toUpperCase().slice(0, count - 2);
    const first = Math.floor((count - label.length) / 2);
    const row = Math.round(frame.height * 0.56);
    reveal += step * (2.2 + frame.level * 7);
    if (reveal > label.length + 8) reveal = 0;

    for (let i = 0; i < count; i++) {
      const column = columns[i];
      const energy = frame.band(i, count);
      const speed = (14 + energy * 190 + frame.beat * 120) * column.rate;
      column.y += speed * step;

      column.churn += (2 + energy * 22) * step;
      if (column.churn > 1) {
        column.churn = 0;
        column.glyphs[column.head] = pick();
        column.head = (column.head + 1) % column.glyphs.length;
      }

      if (column.y > frame.height + cell * TRAIL) {
        column.y = -cell * Math.random() * TRAIL;
        column.rate = 0.55 + Math.random() * 0.9;
      }

      const x = ((i + 0.5) / count) * frame.width;
      const length = Math.max(2, Math.round(TRAIL * (0.5 + energy * 0.6 + frame.level * 0.3)));
      for (let t = 0; t < length; t++) {
        const y = column.y - t * cell;
        if (y < -cell || y > frame.height + cell) continue;
        if (i >= first && i < first + label.length && Math.abs(y - row) < 7) continue;
        const glyph = column.glyphs[(column.head + t) % column.glyphs.length];
        const head = t === 0;
        gfx.text(glyph, x, y, {
          size: 8,
          align: 'center',
          color: head ? 'amber' : 'glow',
          alpha: head ? 1 : Math.max(0.08, 1 - t / length),
          glow: head ? 3 : 0
        });
      }
    }

    for (let j = 0; j < label.length; j++) {
      const glyph = label.charAt(j);
      if (glyph === ' ') continue;
      const x = ((first + j + 0.5) / count) * frame.width;
      const locked = j < reveal - 1;
      gfx.text(locked ? glyph : columns[(first + j) % count].glyphs[0], x, row, {
        size: 9,
        align: 'center',
        color: locked ? 'amber' : 'glow',
        alpha: locked ? 1 : 0.55,
        glow: locked ? 4 : 0
      });
    }
    if (label.length > 0) {
      const left = (first / count) * frame.width;
      const right = ((first + label.length) / count) * frame.width;
      gfx.line(left, row + 7, right, row + 7, { color: 'amber', alpha: 0.35 });
    }
  },

  reset() {
    columns.length = 0;
    lastTime = 0;
    reveal = 0;
  }
});

const GLYPHS =
  'ｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌ' +
  'ﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜｦﾝ0123456789';
const TRAIL = 7;
const columns = [];
let lastTime = 0;
let reveal = 0;

function pick() {
  return GLYPHS.charAt(Math.floor(Math.random() * GLYPHS.length));
}

function build(count, height, cell) {
  columns.length = 0;
  for (let i = 0; i < count; i++) {
    const glyphs = [];
    for (let t = 0; t < TRAIL + 1; t++) glyphs.push(pick());
    columns.push({
      y: Math.random() * (height + cell * TRAIL),
      rate: 0.55 + Math.random() * 0.9,
      churn: Math.random(),
      head: 0,
      glyphs: glyphs
    });
  }
}
