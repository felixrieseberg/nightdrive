import Foundation

final class AquariumVisualizer: RasterVisualizer {
  private struct Fish {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var cruise: Double
    var size: Double
    var phase: Double
    var lane: Double
  }

  private struct Bubble {
    var x: Double
    var y: Double
    var rise: Double
    var wobble: Double
    var big: Bool
  }

  private var noise = DemoNoise(seed: 0xA0_0A_F1_54)
  private var fish: [Fish] = []
  private var bubbles = [Bubble](reservingCapacity: AquariumVisualizer.bubbleCap)
  private var pops = [(x: Double, life: Double)](
    reservingCapacity: AquariumVisualizer.bubbleCap)
  private var spawnBudget = 0.0

  private static let step = 1.0 / 24.0
  private static let bubbleCap = 40

  init() {
    super.init(
      id: "aquarium", rows: 48, levels: 7, step: Self.step,
      ramp: VisualizerInkRamp.cinematic(
        low: (0.09, 0.15), mid: (0.42, 0.55), high: (0.75, 1), solidAt: 0.92))
  }

  override func resetRaster() {
    stock()
    spawnBudget = 0
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    if resized || fish.isEmpty { stock() }
  }

  // MARK: - Simulation

  private func stock() {
    fish.removeAll(keepingCapacity: true)
    bubbles.removeAll(keepingCapacity: true)
    pops.removeAll(keepingCapacity: true)
    guard !raster.isEmpty else { return }
    let w = Double(raster.width)
    let h = Double(raster.height)
    noise = DemoNoise(seed: 0xA0_0A_F1_54)

    let school = min(11, max(4, raster.width / 56))
    for _ in 0..<school {
      let size = 0.9 + noise.unit() * 1.1
      let lane = h * (0.28 + noise.unit() * 0.42)
      let heading: Double = noise.unit() < 0.5 ? -1 : 1
      let cruise = (0.16 + noise.unit() * 0.14) * (2.2 - size * 0.5)
      fish.append(
        Fish(
          x: noise.unit() * w, y: lane, vx: heading * cruise, vy: 0,
          cruise: cruise, size: size, phase: noise.unit(), lane: lane))
    }
    fish.append(
      Fish(
        x: w * 0.2, y: h * 0.5, vx: 0.12, vy: 0, cruise: 0.12,
        size: 2.6, phase: 0, lane: h * 0.5))
  }

  override func advanceRaster(_ frame: VisualizerFrame) {
    let w = Double(raster.width)
    let h = Double(raster.height)
    let floorY = h - 3

    for index in fish.indices {
      var f = fish[index]
      let heading: Double = f.vx < 0 ? -1 : 1
      if didBeat {
        f.vx += heading * (0.9 + energy.bass * 1.3) * (1.6 - f.size * 0.3)
        f.vy += (noise.unit() - 0.5) * 0.5
      }
      f.vx += (heading * f.cruise - f.vx) * 0.055
      f.vy += (f.lane - f.y) * 0.004
      f.vy *= 0.92
      f.phase += 0.06 + abs(f.vx) * 0.35

      f.x += f.vx
      f.y += f.vy + VFDTrig.sin(f.phase * 0.23) * 0.05
      f.y = min(max(f.y, 4), floorY - 2)

      let margin = f.size * 4 + 4
      if f.x > w + margin, heading > 0 {
        f.x = -margin
        f.lane = h * (0.26 + noise.unit() * 0.44)
      } else if f.x < -margin, heading < 0 {
        f.x = w + margin
        f.lane = h * (0.26 + noise.unit() * 0.44)
      }
      fish[index] = f
    }

    spawnBudget += Self.step * (1.4 + energy.treble * 16)
    while spawnBudget >= 1 {
      spawnBudget -= 1
      guard bubbles.count < Self.bubbleCap else { break }
      let vent = (0.18 + Double(noise.next() % 3) * 0.3 + noise.unit() * 0.12) * w
      bubbles.append(
        Bubble(
          x: vent, y: floorY, rise: 0.24 + noise.unit() * 0.2,
          wobble: noise.unit(), big: noise.unit() < 0.25))
    }
    for index in bubbles.indices {
      bubbles[index].y -= bubbles[index].rise
      bubbles[index].rise += 0.004
    }
    bubbles.removeAll { bubble in
      guard bubble.y <= 2.5 else { return false }
      pops.append((x: bubble.x, life: 1))
      return true
    }
    for index in pops.indices { pops[index].life -= 0.22 }
    pops.removeAll { $0.life <= 0 }
  }

  // MARK: - Rendering

  override func composeRaster(_ frame: VisualizerFrame) {
    let w = raster.width
    let h = raster.height
    let wd = Double(w)
    let hd = Double(h)
    let flow = energy.flow

    for y in 0..<h {
      let depth = Double(y) / hd
      let value = UInt8(22 + pow(1 - depth, 1.6) * 16)
      raster.hspan(y: y, from: 0, to: w - 1, value)
    }

    let causticRows = min(h - 1, Int(hd * 0.5))
    let sharp = 150 + energy.treble * 110 + energy.beat * 70
    for y in 2..<causticRows {
      let fade = pow(1 - Double(y) / (hd * 0.5), 1.6)
      guard fade > 0.02 else { continue }
      for x in 0..<w {
        let xd = Double(x)
        let drift = DemoNoise.smooth(xd / 47, seed: 0xCA_57) * 1.7
        let a = VFDTrig.wave(xd / 21 + flow * 0.42 + drift + Double(y) * 0.055)
        let b = VFDTrig.wave(xd / 10 - flow * 0.31 - Double(y) * 0.075)
        let net = a * b
        guard net > 0.62 else { continue }
        raster.plot(x, y, UInt8(min(165, (net - 0.62) * sharp * fade * 3.4)))
      }
    }

    for beam in 0..<3 {
      let bd = Double(beam)
      let anchor = wd * (0.18 + bd * 0.3) + VFDTrig.sin(flow * 0.03 + bd * 0.37) * wd * 0.08
      let strength = (0.5 + 0.5 * VFDTrig.wave(flow * 0.05 + bd * 0.61)) * (36 + energy.level * 38)
      for y in 0..<(h - 3) {
        let fade = pow(1 - Double(y) / hd, 1.2)
        let center = anchor + Double(y) * 0.45
        let half = 4.5 + Double(y) * 0.14
        let lo = Int((center - half).rounded(.down))
        let hi = Int((center + half).rounded(.up))
        guard lo <= hi else { continue }
        for x in lo...hi {
          let falloff = 1 - abs(Double(x) - center) / (half + 0.5)
          guard falloff > 0 else { continue }
          raster.plot(x, y, UInt8(min(255, strength * falloff * fade)))
        }
      }
    }

    for x in 0..<w {
      let lift = VFDTrig.sin(Double(x) / 13 + flow * 0.9)
      let y = 1 + Int((lift * 0.8).rounded())
      raster.plot(x, y, UInt8(96 + energy.level * 50))
      if VisualizerRaster.hash(x: x, y: Int(flow * 6), salt: 0x5EA5) % 47 == 0 {
        raster.plot(x, y, UInt8(120 + energy.beat * 135))
      }
    }
    for pop in pops {
      let x = Int(pop.x.rounded())
      let v = UInt8(min(255, pop.life * 255))
      raster.plot(x, 1, v)
      raster.plot(x - 1, 2, v / 2)
      raster.plot(x + 1, 2, v / 2)
    }

    for x in 0..<w {
      let dune = DemoNoise.smooth(Double(x) / 11, seed: 0xD0_0E) * 3.4
      let top = h - 1 - Int(dune.rounded())
      for y in max(0, top)..<h {
        let grain = VisualizerRaster.hash(x: x, y: y, salt: 0x5A_4D) % 22
        raster.set(x, y, UInt8(38 + grain))
      }
    }

    let stalks = max(3, w / 90)
    for stalk in 0..<stalks {
      let sd = Double(stalk)
      let anchor = wd * (0.5 + sd) / Double(stalks)
      let top = hd * (0.22 + DemoNoise.smooth(sd * 3.7, seed: 0xEE_1) * 0.3)
      let anchorY = h - 2
      guard Double(anchorY) > top else { continue }
      let span = Double(anchorY) - top
      var y = Double(anchorY)
      while y >= top {
        let height = (Double(anchorY) - y) / span
        let sway =
          VFDTrig.sin(flow * 0.3 + sd * 0.73 + height * 0.9)
          * (1.2 + energy.bass * 4.5) * height
        let x = anchor + sway
        raster.plot(x: x, y: y, value: 74 + height * 46)
        if Int(y) % 3 == 0 {
          let side: Double = Int(y) % 6 == 0 ? 1.4 : -1.4
          raster.plot(x: x + side, y: y - 0.4, value: 70)
        }
        y -= 1
      }
    }

    for f in fish.sorted(by: { $0.size < $1.size }) {
      drawFish(f)
    }

    for bubble in bubbles {
      let wobbleSpread = (1 - bubble.y / hd) * 1.6
      let x = bubble.x + VFDTrig.sin(flow * 1.8 + bubble.wobble) * wobbleSpread
      if bubble.big {
        raster.plot(x: x, y: bubble.y - 1, value: 120)
        raster.plot(x: x, y: bubble.y + 1, value: 120)
        raster.plot(x: x - 1, y: bubble.y, value: 120)
        raster.plot(x: x + 1, y: bubble.y, value: 120)
      } else {
        raster.plot(x: x, y: bubble.y, value: 150)
      }
    }
  }

  private func drawFish(_ f: Fish) {
    let heading: Double = f.vx < 0 ? -1 : 1
    let length = f.size * 2.3
    let body = 128 + f.size * 50 + energy.beat * 26
    var dx = -length
    while dx <= length {
      let across = dx / length
      let half = f.size * 0.62 * (1 - across * across).squareRoot()
      var dy = -half
      while dy <= half {
        let shade = 1 - 0.35 * abs(dy) / max(half, 0.001)
        raster.plot(x: f.x + dx * heading, y: f.y + dy, value: body * shade)
        dy += 1
      }
      dx += 1
    }
    let beat = VFDTrig.sin(f.phase)
    let tailX = f.x - heading * (length + 1)
    let spread = 0.4 + abs(beat) * (f.size * 0.7)
    raster.plot(x: tailX, y: f.y, value: body * 0.7)
    raster.plot(x: tailX - heading * 0.8, y: f.y - spread, value: body * 0.55)
    raster.plot(x: tailX - heading * 0.8, y: f.y + spread, value: body * 0.55)
    if f.size >= 1.4 {
      raster.set(
        Int((f.x + heading * length * 0.55).rounded()),
        Int((f.y - f.size * 0.2).rounded()), 18)
    }
  }
}
