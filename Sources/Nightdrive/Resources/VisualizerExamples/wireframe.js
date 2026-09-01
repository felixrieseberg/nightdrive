registerVisualizer({
  id: 'wireframe',
  name: 'Wireframe',

  draw(frame, gfx) {
    const cx = frame.width / 2;
    const horizon = frame.height * 0.46;

    floor(gfx, frame, cx, horizon);

    const spacing = frame.width / ROW.length;
    const edges = [];
    const corners = [];
    const hot = [];

    for (let i = 0; i < ROW.length; i++) {
      const solid = SOLIDS[ROW[i]];
      const spin = spins[i];
      const drive = frame.band(i, ROW.length);
      spin.x += (0.3 + drive * 1.6) * STEP;
      spin.y += (0.45 + drive * 2.4) * STEP;
      spin.z += (0.17 + drive * 0.7) * STEP;

      const originX = (i + 0.5) * spacing;
      const originY = horizon - frame.height * 0.2;
      const size = frame.height * (0.32 + drive * 0.16);
      const distance = 175 - frame.beat * 45;
      const k = FOCAL / distance;

      const points = [];
      for (const vertex of solid.vertices) {
        const p = rotate(spin, vertex[0] * size, vertex[1] * size, vertex[2] * size);
        const z = p[2] + distance;
        if (z < 12) {
          points.push(null);
          continue;
        }
        const scale = FOCAL / z;
        points.push([originX + p[0] * scale, originY + p[1] * scale, z]);
      }

      for (const edge of solid.edges) {
        const a = points[edge[0]];
        const b = points[edge[1]];
        if (!a || !b) continue;
        edges.push([a[0], a[1], b[0], b[1]]);
      }
      for (const point of points) {
        if (point) (drive > 0.5 ? hot : corners).push([point[0], point[1]]);
      }

      const shadow = size * k;
      gfx.ellipse(
        originX - shadow, horizon + (CAMERA * FOCAL) / distance - shadow * 0.16,
        shadow * 2, shadow * 0.34, { color: 'ghost', fill: true });
    }

    gfx.segments(edges, {
      color: frame.beat > 0.4 ? 'amber' : 'glow',
      width: 1.3,
      glow: 3
    });
    gfx.dots(corners, { color: 'glow', size: 2, round: true, alpha: 0.8 });
    gfx.dots(hot, { color: 'amber', size: 3, round: true, glow: 3 });

    gfx.text('WIRE ' + edges.length, 6, frame.height - 6, { size: 7, color: 'dim' });
    gfx.text(frame.isPlaying ? 'ROT 3AX' : 'HOLD', frame.width - 6, frame.height - 6, {
      size: 7, color: 'dim', align: 'trailing'
    });
  },

  reset() {
    for (let i = 0; i < spins.length; i++) {
      spins[i].x = 0.4 + i * 0.3;
      spins[i].y = 0.2 + i * 0.5;
      spins[i].z = 0;
    }
    scroll = 0;
  }
});

const STEP = 1 / 24;

const SOLIDS = [
  {
    vertices: [
      [-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1],
      [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]
    ],
    edges: [
      [0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4],
      [0, 4], [1, 5], [2, 6], [3, 7]
    ]
  },
  {
    vertices: [[0, -1.3, 0], [1.3, 0, 0], [0, 0, 1.3], [-1.3, 0, 0], [0, 0, -1.3], [0, 1.3, 0]],
    edges: [
      [0, 1], [0, 2], [0, 3], [0, 4], [5, 1], [5, 2], [5, 3], [5, 4],
      [1, 2], [2, 3], [3, 4], [4, 1]
    ]
  },
  {
    vertices: [[0, -1.2, 0], [-1.1, 0.8, -0.7], [1.1, 0.8, -0.7], [0, 0.8, 1.3]],
    edges: [[0, 1], [0, 2], [0, 3], [1, 2], [2, 3], [3, 1]]
  }
];

const ROW = [0, 1, 2, 1, 0];
const spins = ROW.map((_, i) => ({ x: 0.4 + i * 0.3, y: 0.2 + i * 0.5, z: 0 }));
let scroll = 0;

function rotate(spin, x, y, z) {
  let s = Math.sin(spin.x), c = Math.cos(spin.x);
  const y1 = y * c - z * s, z1 = y * s + z * c;
  s = Math.sin(spin.y); c = Math.cos(spin.y);
  const x2 = x * c + z1 * s, z2 = -x * s + z1 * c;
  s = Math.sin(spin.z); c = Math.cos(spin.z);
  return [x2 * c - y1 * s, x2 * s + y1 * c, z2];
}

function floor(gfx, frame, cx, horizon) {
  scroll = (scroll + (16 + frame.level * 95) * STEP) % SPACING;
  const lines = [];

  for (let row = 0; row <= ROWS; row++) {
    const depth = NEAR + row * SPACING - scroll;
    if (depth < NEAR * 0.5) continue;
    const y = horizon + (CAMERA * FOCAL) / depth;
    if (y > frame.height + 2) continue;
    lines.push([0, y, frame.width, y]);
  }

  const far = NEAR + ROWS * SPACING;
  for (let column = -COLUMNS; column <= COLUMNS; column++) {
    const offset = column * SPREAD;
    lines.push([
      cx + (offset * FOCAL) / NEAR, horizon + (CAMERA * FOCAL) / NEAR,
      cx + (offset * FOCAL) / far, horizon + (CAMERA * FOCAL) / far
    ]);
  }

  gfx.segments(lines, { color: 'ghost', width: 1 });
  gfx.line(0, horizon, frame.width, horizon, {
    color: 'dim',
    alpha: 0.3 + frame.bass * 0.5,
    glow: frame.bass > 0.6
  });
}

const FOCAL = 120;
const CAMERA = 20;
const NEAR = 52;
const SPACING = 22;
const ROWS = 24;
const COLUMNS = 26;
const SPREAD = 22;
