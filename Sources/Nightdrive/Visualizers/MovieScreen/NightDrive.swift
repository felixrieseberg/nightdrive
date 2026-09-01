import Foundation

final class NightDriveVisualizer: RasterVisualizer {
  private struct Oncoming {
    var z: Double
  }

  private struct Ahead {
    var z: Double
    var lane: Double
    var paceFactor: Double
  }

  private var noise = DemoNoise(seed: 0xD1_4E_57_01)
  private let skyline = CitySkyline(seed: 0xC17_15EA, blockWidth: 7, maxRise: 9)
  private let farCity = CitySkyline(seed: 0xFA_2C17, blockWidth: 11, maxRise: 5)

  private var distance = 0.0
  private var surge = 0.0
  private var curvature = 0.0
  private var traffic = [Oncoming](reservingCapacity: 3)
  private var ahead = [Ahead](reservingCapacity: 3)

  private static let step = 1.0 / 24.0
  private static let dashPeriod = 1.0
  private static let lightPeriod = 4.2
  private static let postPeriod = 1.4
  private static let cityBands = 12
  private static let roadSpread = 0.40

  init() {
    super.init(
      id: "nightdrive", name: "NIGHT DRIVE", rows: 48, levels: 8, step: Self.step,
      ramp: VisualizerInkRamp.cinematic(
        low: (0.1, 0.16), mid: (0.45, 0.6), high: (0.78, 1), solidAt: 0.93))
  }

  override func resetRaster() {
    noise = DemoNoise(seed: 0xD1_4E_57_01)
    distance = 0
    surge = 0
    curvature = 0
    traffic.removeAll(keepingCapacity: true)
    ahead.removeAll(keepingCapacity: true)
  }

  // MARK: - Simulation

  override func advanceRaster(_ frame: VisualizerFrame) {
    let cruise = frame.isPlaying ? 1.1 + energy.level * 3.4 : 0.4
    if didBeat {
      surge = max(surge, 3.4 + energy.bass * 4)
      if traffic.count < 3, traffic.allSatisfy({ $0.z < 12 }), noise.unit() < 0.7 {
        traffic.append(Oncoming(z: 16))
      }
    }
    surge *= exp(-Self.step * 2.4)
    let speed = cruise + surge
    distance += speed * Self.step

    let target = (DemoNoise.smooth(distance * 0.045, seed: 0xBE_4D) - 0.5) * 2.4
    curvature += (target - curvature) * min(1, Self.step * 1.1)

    for index in traffic.indices {
      traffic[index].z -= (speed + 4) * Self.step
    }
    traffic.removeAll { $0.z < 0.55 }

    if ahead.isEmpty {
      for base in [1.7, 4.4, 8.2] { spawnAhead(at: base + noise.unit() * 1.2) }
    }
    for index in ahead.indices {
      ahead[index].z += (cruise * ahead[index].paceFactor - speed) * Self.step
    }
    ahead.removeAll { $0.z < 0.45 || $0.z > 17 }
    while ahead.count < 3 { spawnAhead(at: 9.5 + noise.unit() * 2.5) }
  }

  private func spawnAhead(at z: Double) {
    let lane = 0.66 + (noise.unit() - 0.5) * 0.12
    let paceFactor = 0.78 + noise.unit() * 0.14
    ahead.append(Ahead(z: z, lane: lane, paceFactor: paceFactor))
  }

  // MARK: - Rendering

  override func composeRaster(_ frame: VisualizerFrame) {
    raster.clear()
    let w = raster.width
    let h = raster.height
    let wd = Double(w)
    let horizon = Int(Double(h) * 0.42)
    let below = max(1, h - horizon)
    let beat = energy.beat
    let bass = energy.bass

    func geometry(_ r: Int) -> (p: Double, center: Double, half: Double) {
      let p = Double(r) / Double(below)
      let reach = 1 - p
      let center = wd * 0.5 + curvature * reach * reach * wd * 0.38
      let half = max(1.8, wd * Self.roadSpread * p)
      return (p, center, half)
    }

    for y in 0..<max(0, horizon - 1) {
      for x in 0..<w {
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0x57A2)
        guard hash % 67 == 0 else { continue }
        let twinkle = VFDTrig.wave(energy.flow * 0.7 + Double(hash % 640) / 41)
        raster.set(x, y, UInt8(24 + twinkle * (40 + energy.treble * 80)))
      }
    }

    let farSlide = Int((-curvature * wd * 0.07).rounded())
    for x in 0..<w {
      let rise = min(horizon - 1, farCity.rise(at: x + farSlide) + 3)
      raster.vspan(x: x, from: horizon - rise, to: horizon, 16)
    }

    let bands = (0..<Self.cityBands).map { energy.band(frame, $0, of: Self.cityBands) }
    let citySlide = Int((-curvature * wd * 0.22).rounded())
    for x in 0..<w {
      let sampleX = x + citySlide
      let rise = min(horizon, skyline.rise(at: sampleX))
      guard rise > 0 else { continue }
      let band = bands[min(Self.cityBands - 1, x * Self.cityBands / w)]
      let roofY = horizon - rise
      raster.vspan(x: x, from: roofY, to: horizon, 28)
      raster.set(x, roofY, UInt8(28 + band * 70))
      for row in 1...rise {
        let window = skyline.window(atColumn: sampleX, rowsBelowRoof: row)
        guard window > 0 else { continue }
        let flicker = 0.75 + 0.25 * VFDTrig.wave(energy.flow * 0.4 + window * 9)
        let lit = 40 + window * flicker * (36 + band * 165 + beat * 30)
        raster.set(x, roofY + row, UInt8(min(235, lit)))
      }
    }
    raster.hspan(y: horizon, from: 0, to: w - 1, UInt8(min(200, 40 + beat * 85 + bass * 18)))
    if horizon + 1 < h {
      raster.hspan(y: horizon + 1, from: 0, to: w - 1, UInt8(min(140, 22 + beat * 55)))
    }

    let zScale = Double(below) * 0.55
    for r in 1...below {
      let y = horizon + r
      guard y < h else { break }
      let (p, center, half) = geometry(r)
      let z = zScale / Double(r)
      let near = 0.45 + 0.55 * p

      let tone = 16 + p * 12
      raster.hspan(y: y, from: Int(center - half), to: Int(center + half), UInt8(tone))
      let pool = p * p * (6 + bass * 46)
      if p > 0.35 {
        let inner = half * 0.55
        raster.hspan(
          y: y, from: Int(center - inner), to: Int(center + inner), UInt8(tone + pool * 0.5))
      }
      if p > 0.55 {
        let core = half * 0.3
        raster.hspan(
          y: y, from: Int(center - core), to: Int(center + core), UInt8(tone + pool))
      }

      let edge = min(255, (235 + beat * 45) * near)
      for side in [-1.0, 1.0] {
        let x = center + side * half
        raster.plot(x: x, y: Double(y), value: edge)
        if p > 0.45 { raster.plot(x: x + side, y: Double(y), value: edge * 0.55) }
      }

      let dashPhase = 3.2 * log(z) + distance / Self.dashPeriod
      if dashPhase - dashPhase.rounded(.down) < 0.55 {
        let dashWidth = max(1, Int((p * 2.6).rounded()))
        let value = UInt8(min(255, (215 + beat * 55) * near))
        for lane in [-1.0, 1.0] {
          let laneX = Int(center + lane * half / 3)
          raster.hspan(
            y: y, from: laneX - dashWidth / 2,
            to: laneX - dashWidth / 2 + dashWidth - 1, value)
        }
      }
    }

    let firstPost = (distance / Self.postPeriod).rounded(.down) + 1
    for i in 0..<12 {
      let z = (firstPost + Double(i)) * Self.postPeriod - distance
      guard z > 0.3 else { continue }
      let rd = zScale / z
      guard rd >= 1, rd <= Double(below) else { continue }
      let r = Int(rd)
      let (p, center, half) = geometry(r)
      let y = Double(horizon + r)
      let glint = min(250, (50 + p * 150) * (0.45 + 0.55 * bass) + beat * 40)
      for side in [-1.0, 1.0] {
        let x = center + side * (half + 1.5 + p * 4)
        raster.plot(x: x, y: y, value: glint)
        if p > 0.5 { raster.plot(x: x, y: y - 1, value: glint * 0.45) }
      }
    }

    let firstLamp = (distance / Self.lightPeriod).rounded(.down) + 1
    for i in 0..<10 {
      let ordinal = firstLamp + Double(i)
      let z = ordinal * Self.lightPeriod - distance
      guard z > 0.4 else { continue }
      let rd = zScale / z
      guard rd >= 1, rd <= Double(below) else { continue }
      let r = Int(rd)
      let y = horizon + r
      let (p, center, half) = geometry(r)
      let side: Double = Int(ordinal) % 2 == 0 ? -1 : 1
      let x = Int((center + side * (half + 3 + p * 10)).rounded())
      let poleTop = y - max(2, Int(p * 13))
      raster.vspan(x: x, from: poleTop, to: y, UInt8(min(255, 90 * (0.35 + 0.65 * p))))
      let arm = Int(side < 0 ? 1 : -1)
      let head = 160 + p * 95
      raster.plot(x: Double(x + arm), y: Double(poleTop), value: head)
      raster.plot(x: Double(x + arm) + side * -0.6, y: Double(poleTop) - 0.5, value: head * 0.5)
      raster.plot(x + arm * 2, poleTop, UInt8(min(255, 70 + p * 70)))
      raster.plot(x + arm, poleTop - 1, UInt8(min(255, 55 + p * 75)))
      raster.plot(x + arm, poleTop + 1, UInt8(min(255, 40 + p * 60)))
    }

    for car in ahead.sorted(by: { $0.z > $1.z }) {
      let rd = zScale / max(car.z, 0.001)
      guard rd >= 1 else { continue }
      let r = min(below, Int(rd))
      let y = horizon + r
      let (p, center, half) = geometry(r)
      let lane = center + half * car.lane
      let sep = max(1.2, min(half * 0.2, Double(below) * 0.55))
      let skirt = 110 + p * 80 + beat * 45
      let ly = Double(y) - 1 - p * 1.5
      let row = Int(ly.rounded())
      let lampWidth = min(4, 1 + Int(sep / 3.5))

      if sep >= 3 {
        let left = Int((lane - sep).rounded())
        let right = Int((lane + sep).rounded())
        let carH = min(14, max(2, Int(sep * 0.9)))
        let bodyRows = max(1, Int(Double(carH) * 0.55))
        let cabinRows = max(1, carH - bodyRows)

        raster.hspan(y: row + 1, from: left + 1, to: right - 1, 10)

        let panel = UInt8(min(120, 46 + p * 60))
        for b in 0..<bodyRows {
          raster.hspan(y: row - b, from: left, to: right, panel)
        }

        let cabinInk = UInt8(min(95, 28 + p * 45))
        let glass = UInt8(min(150, 70 + p * 60))
        for k in 1...cabinRows {
          let taper = 0.8 - 0.2 * Double(k - 1) / Double(max(1, cabinRows - 1))
          let cw = max(1.0, sep * taper)
          let cy = row - bodyRows - k + 1
          raster.hspan(y: cy, from: Int(lane - cw), to: Int(lane + cw), cabinInk)
          if k < cabinRows {
            let ww = max(1.0, cw * 0.72)
            raster.hspan(y: cy, from: Int(lane - ww), to: Int(lane + ww), glass)
          }
        }

        if sep >= 5 { raster.plot(x: lane, y: Double(row), value: 90) }

        let lampRows = min(4, bodyRows)
        for side in [-1, 1] {
          let corner = side < 0 ? left : right
          for b in 0..<lampRows {
            for k in 0..<lampWidth {
              raster.set(corner - side * k, row - b, 255)
            }
          }
          raster.plot(x: Double(corner), y: ly, value: skirt * 0.45)
        }
      } else {
        for side in [-1.0, 1.0] {
          let lx = lane + side * sep
          raster.plot(x: lx, y: ly, value: skirt)
          raster.plot(Int(lx.rounded()), row, 255)
        }
      }

      if p > 0.25 {
        let glare = (p - 0.25) * 170
        let spill = 1 + sep * 0.3
        raster.plot(x: lane - sep - spill, y: ly, value: glare)
        raster.plot(x: lane + sep + spill, y: ly, value: glare)
      }
    }

    for car in traffic {
      let rd = zScale / max(car.z, 0.001)
      guard rd >= 1 else { continue }
      let r = min(below, Int(rd))
      let y = horizon + r
      let (p, center, half) = geometry(r)
      let lane = center - half * 0.62
      let sep = max(1.0, min(half * 0.16, Double(below) * 0.45))
      let bright = 90.0 + p * 165
      let ly = Double(y) - 1 - p * 1.5
      raster.plot(x: lane - sep, y: ly, value: bright)
      raster.plot(x: lane + sep, y: ly, value: bright)
      if sep >= 4 {
        let row = Int(ly.rounded())
        raster.plot(Int((lane - sep).rounded()) + 1, row, UInt8(min(255, bright * 0.8)))
        raster.plot(Int((lane + sep).rounded()) - 1, row, UInt8(min(255, bright * 0.8)))
      }
      if p > 0.55 {
        let halo = (p - 0.55) * 180
        let spill = 1 + sep * 0.3
        for dx in [-spill, spill] {
          raster.plot(x: lane - sep + dx, y: ly, value: halo)
          raster.plot(x: lane + sep + dx, y: ly, value: halo)
        }
        raster.plot(x: lane - sep, y: ly - 1, value: halo * 0.6)
        raster.plot(x: lane + sep, y: ly - 1, value: halo * 0.6)
      }
    }
  }
}
