registerVisualizer({
  id: 'constellation',
  name: 'Constellation',

  draw(frame, gfx) {
    if (nodes.length === 0 || width !== frame.width || height !== frame.height) {
      build(frame.width, frame.height);
    }

    const step = Math.min(0.12, Math.max(0.001, frame.time - lastTime));
    lastTime = frame.time;

    const cx = frame.width / 2;
    const cy = frame.height / 2;
    const blast = frame.beat * frame.beat * 520;

    for (const node of nodes) {
      const energy = frame.band(node.band, BANDS);
      const dx = node.x - cx;
      const dy = node.y - cy;
      const distance = Math.max(8, Math.hypot(dx, dy));

      node.vx += ((node.homeX - node.x) * SPRING + (dx / distance) * blast) * step;
      node.vy += ((node.homeY - node.y) * SPRING + (dy / distance) * blast * 0.5) * step;
      node.vx += (Math.random() - 0.5) * (30 + energy * 420) * step;
      node.vy += (Math.random() - 0.5) * (14 + energy * 150) * step;
      node.vx *= DAMPING;
      node.vy *= DAMPING;
      node.x += node.vx * step;
      node.y += node.vy * step;
      node.energy = energy;
    }

    const links = [];
    const reach = REACH * (1 + frame.level * 0.5);
    for (let i = 0; i < nodes.length; i++) {
      const a = nodes[i];
      const limit = Math.min(nodes.length, i + NEIGHBOURS);
      for (let j = i + 1; j < limit; j++) {
        const b = nodes[j];
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        if (dx * dx + dy * dy < reach * reach) links.push([a.x, a.y, b.x, b.y]);
      }
    }
    gfx.segments(links, { color: 'glow', alpha: 0.3, width: 1 });

    const quiet = [];
    const loud = [];
    for (const node of nodes) {
      (node.energy > 0.5 ? loud : quiet).push([node.x, node.y]);
    }
    gfx.dots(quiet, { color: 'glow', size: 1.8, round: true, alpha: 0.75 });
    gfx.dots(loud, { color: 'amber', size: 3.4, round: true, glow: 3 });

    if (frame.beat > 0.35) {
      const radius = (1 - frame.beat) * frame.width * 0.55;
      gfx.ellipse(cx - radius, cy - radius * 0.13, radius * 2, radius * 0.26, {
        color: 'amber', alpha: frame.beat * 0.45
      });
    }

    gfx.text('NODES ' + nodes.length, 6, frame.height - 6, { size: 7, color: 'dim' });
    gfx.text('LINKS ' + links.length, frame.width - 6, frame.height - 6, {
      size: 7, color: links.length > nodes.length ? 'amber' : 'dim', align: 'trailing'
    });
  },

  reset() {
    nodes.length = 0;
    lastTime = 0;
  }
});

const COUNT = 120;
const BANDS = 24;
const SPRING = 22;
const DAMPING = 0.9;
const REACH = 34;
const NEIGHBOURS = 7;

const nodes = [];
let width = 0;
let height = 0;
let lastTime = 0;

function build(w, h) {
  nodes.length = 0;
  width = w;
  height = h;
  for (let i = 0; i < COUNT; i++) {
    const x = ((i + 0.5) / COUNT) * w + (Math.random() - 0.5) * (w / COUNT);
    const y = h * (0.12 + Math.random() * 0.76);
    nodes.push({
      x: x, y: y, homeX: x, homeY: y, vx: 0, vy: 0,
      band: Math.floor((x / w) * (BANDS - 1)), energy: 0
    });
  }
  nodes.sort((a, b) => a.homeX - b.homeX);
}
