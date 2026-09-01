registerVisualizer({
  id: 'radar',
  name: 'Radar',

  draw(frame, gfx) {
    const cx = frame.width / 2;
    const cy = frame.height / 2;
    const ry = cy - 2;
    const rx = cx - 3;
    const hub = 0.12;

    const step = Math.min(0.2, Math.max(0, frame.time - lastTime));
    lastTime = frame.time;
    const sweep = frame.time * (1.5 + frame.level * 0.9);
    const bearing = sweep % (Math.PI * 2);

    grid(gfx, cx, cy, rx, ry, hub);

    for (let tail = 0; tail < TAIL; tail++) {
      const from = sweep - (tail + 1) * 0.13;
      gfx.arc(cx, cy, rx, ry, from, from + 0.14, {
        color: 'glow',
        alpha: 0.22 * (1 - tail / TAIL),
        fill: true
      });
    }
    gfx.line(cx, cy, cx + Math.cos(sweep) * rx, cy + Math.sin(sweep) * ry, {
      color: 'glow', width: 1.4, glow: 3
    });

    for (let gate = 0; gate < GATES; gate++) {
      const value = frame.band(gate, GATES);
      if (value < 0.12 || Math.random() > value * 0.85 + 0.08) continue;
      const range = hub + (1 - hub) * ((gate + 0.5) / GATES);
      contacts.push({
        angle: bearing + (Math.random() - 0.5) * 0.05,
        range: range + (Math.random() - 0.5) * 0.06,
        strength: value,
        born: frame.time
      });
    }
    if (contacts.length > MAX_CONTACTS) {
      contacts.splice(0, contacts.length - MAX_CONTACTS);
    }

    const near = [];
    const strong = [];
    const fading = [];
    for (let i = contacts.length - 1; i >= 0; i--) {
      const contact = contacts[i];
      const age = frame.time - contact.born;
      if (age > LIFE) {
        contacts.splice(i, 1);
        continue;
      }
      const point = [
        cx + Math.cos(contact.angle) * rx * contact.range,
        cy + Math.sin(contact.angle) * ry * contact.range
      ];
      if (age > LIFE * 0.45) fading.push(point);
      else if (contact.strength > 0.62) strong.push(point);
      else near.push(point);
    }
    gfx.dots(fading, { color: 'dim', size: 1.6, round: true, alpha: 0.5 });
    gfx.dots(near, { color: 'glow', size: 2, round: true, alpha: 0.85 });
    gfx.dots(strong, { color: 'amber', size: 2.6, round: true, glow: 3 });

    if (frame.boot != null) {
      gfx.arc(cx, cy, rx * frame.boot, ry * frame.boot, 0, Math.PI * 2, {
        color: 'amber', alpha: 1 - frame.boot
      });
    }

    const azimuth = Math.round((bearing * 180) / Math.PI);
    gfx.text(String(azimuth).padStart(3, '0') + '\u00B0', 8, 9, {
      size: 7, color: 'dim'
    });
    const status = frame.isPlaying
      ? 'CONTACT ' + String(contacts.length).padStart(3, '0')
      : 'STANDBY';
    gfx.text(status, frame.width - 8, 9, {
      size: 7,
      color: contacts.length > 420 ? 'amber' : 'dim',
      align: 'trailing'
    });
  },

  reset() {
    contacts.length = 0;
    lastTime = 0;
  }
});

const GATES = 22;
const TAIL = 7;
const LIFE = 2.6;
const MAX_CONTACTS = 900;
const contacts = [];
let lastTime = 0;

function grid(gfx, cx, cy, rx, ry, hub) {
  for (let ring = 1; ring <= 3; ring++) {
    const t = hub + ((1 - hub) * ring) / 3;
    gfx.ellipse(cx - rx * t, cy - ry * t, rx * t * 2, ry * t * 2, { color: 'ghost' });
  }

  const ticks = [];
  for (let i = 0; i < 24; i++) {
    const angle = (i / 24) * Math.PI * 2;
    const inner = i % 6 === 0 ? 0.82 : 0.94;
    ticks.push([
      cx + Math.cos(angle) * rx * inner, cy + Math.sin(angle) * ry * inner,
      cx + Math.cos(angle) * rx, cy + Math.sin(angle) * ry
    ]);
  }
  ticks.push([cx - rx, cy, cx + rx, cy], [cx, cy - ry, cx, cy + ry]);
  gfx.segments(ticks, { color: 'ghost', width: 1 });
  gfx.circle(cx, cy, 1.5, { color: 'dim', fill: true });
}
