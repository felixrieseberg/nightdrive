registerVisualizer({
  id: 'hyperwarp',
  name: 'Hyperwarp',

  draw(frame, gfx) {
    const cx = frame.width / 2;
    const cy = frame.height / 2;
    if (stars.length === 0) seed();

    const step = Math.min(0.1, Math.max(0, frame.time - lastTime));
    lastTime = frame.time;

    warp += ((0.4 + frame.level * 1.6 + frame.beat * 4.5) - warp) * Math.min(1, step * 8);
    const travel = warp * step * 55;

    for (let i = 0; i < RINGS; i++) {
      const depth = DEPTH - ((ringPhase + (i * DEPTH) / RINGS) % DEPTH);
      const k = FOCAL / Math.max(NEAR, depth);
      const rx = k * frame.width * 0.62;
      const ry = k * frame.height * 0.62;
      if (rx > frame.width * 1.4) continue;
      gfx.ellipse(cx - rx, cy - ry, rx * 2, ry * 2, {
        color: 'glow',
        alpha: 0.05 + 0.3 * (1 - depth / DEPTH)
      });
    }
    ringPhase = (ringPhase + travel) % DEPTH;

    const trails = [];
    const distant = [];
    for (const star of stars) {
      const previous = star.z;
      star.z -= travel;
      if (star.z < NEAR) {
        respawn(star);
        continue;
      }

      const k = FOCAL / star.z;
      const x = cx + star.x * k * frame.width * 0.5;
      const y = cy + star.y * k * frame.height * 0.5;
      if (x < -30 || x > frame.width + 30 || y < -20 || y > frame.height + 20) continue;

      if (star.z > DEPTH * 0.45) {
        distant.push([x, y]);
        continue;
      }
      const previousK = FOCAL / previous;
      trails.push([
        cx + star.x * previousK * frame.width * 0.5,
        cy + star.y * previousK * frame.height * 0.5,
        x, y
      ]);
    }

    gfx.dots(distant, { color: 'glow', size: 1.2, alpha: 0.55 });
    gfx.segments(trails, {
      color: warp > 2.6 ? 'amber' : 'glow',
      alpha: 0.95,
      width: 1.4,
      glow: 3
    });

    gfx.circle(cx, cy, 1.5 + frame.beat * 3, {
      color: 'amber', fill: true, alpha: 0.5 + frame.beat * 0.5, glow: 4
    });

    const knots = (warp * 41).toFixed(0);
    gfx.text('WARP ' + knots, 6, frame.height - 6, {
      size: 7,
      color: warp > 2.6 ? 'amber' : 'dim',
      glow: warp > 2.6 ? 2 : 0
    });
    gfx.text(frame.isPlaying ? 'FIELD ' + stars.length : 'DRIFT',
      frame.width - 6, frame.height - 6, { size: 7, color: 'dim', align: 'trailing' });
  },

  reset() {
    stars.length = 0;
    lastTime = 0;
    warp = 0.4;
    ringPhase = 0;
  }
});

const COUNT = 300;
const DEPTH = 120;
const NEAR = 7;
const FOCAL = 26;
const RINGS = 8;
const stars = [];
let lastTime = 0;
let warp = 0.4;
let ringPhase = 0;

function seed() {
  for (let i = 0; i < COUNT; i++) {
    const star = { x: 0, y: 0, z: 0 };
    respawn(star);
    star.z = NEAR + Math.random() * (DEPTH - NEAR);
    stars.push(star);
  }
}

function respawn(star) {
  const angle = Math.random() * Math.PI * 2;
  const radius = 0.3 + Math.random() * 0.9;
  star.x = Math.cos(angle) * radius;
  star.y = Math.sin(angle) * radius;
  star.z = DEPTH;
}
