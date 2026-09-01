import Foundation

final class FireworksVisualizer: RasterVisualizer {
  private struct Shell {
    var x: Double
    var y: Double
    var climb: Double
    var apex: Double
    var strength: Double
  }

  private struct Spark {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
    var lifespan: Double
    var golden: Bool
  }

  private var noise = DemoNoise(seed: 0xF1_4E_B0_11)
  private let skyline = CitySkyline(seed: 0x0DDBA11, blockWidth: 9, maxRise: 5)

  private var shells = [Shell](reservingCapacity: 4)
  private var sparks = [Spark](reservingCapacity: FireworksVisualizer.sparkCap)
  private var flash = 0.0
  private var burstStyle = 0
  private var sinceLaunch = 0.0

  private static let step = 1.0 / 24.0
  private static let sparkCap = 420

  init() {
    super.init(
      id: "fireworks", rows: 52, levels: 8, step: Self.step,
      ramp: VisualizerInkRamp.cinematic(
        low: (0.07, 0.13), mid: (0.38, 0.5), high: (0.68, 0.9), solidAt: 0.86))
  }

  override func resetRaster() {
    noise = DemoNoise(seed: 0xF1_4E_B0_11)
    shells.removeAll(keepingCapacity: true)
    sparks.removeAll(keepingCapacity: true)
    flash = 0
    burstStyle = 0
    sinceLaunch = 0
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    // A resize hands the raster fresh zeroed pixels, so only the in-flight
    // shells and sparks need discarding.
    if resized {
      shells.removeAll(keepingCapacity: true)
      sparks.removeAll(keepingCapacity: true)
    }
  }

  // MARK: - Simulation

  override func advanceRaster(_ frame: VisualizerFrame) {
    let w = Double(raster.width)
    let h = Double(raster.height)
    let waterline = max(2, Int(h * 0.76))

    raster.decay(0.86, drop: 3)

    sinceLaunch += Self.step
    if didBeat {
      launch(strength: 0.45 + energy.bass * 0.55, width: w, waterline: waterline)
      if energy.bass > 0.72, shells.count < 4 {
        launch(strength: 0.4 + energy.bass * 0.3, width: w, waterline: waterline)
      }
    } else if sinceLaunch > 2.6, shells.isEmpty, sparks.count < 20 {
      launch(strength: 0.28, width: w, waterline: waterline)
    }

    for index in shells.indices {
      shells[index].y -= shells[index].climb * Self.step
      shells[index].climb -= 26 * Self.step
      raster.plot(
        x: shells[index].x + VFDTrig.sin(shells[index].y * 0.13) * 0.4,
        y: shells[index].y, value: 150)
    }
    var shellIndex = 0
    while shellIndex < shells.count {
      if shells[shellIndex].y <= shells[shellIndex].apex || shells[shellIndex].climb <= 6 {
        burst(shells.remove(at: shellIndex))
      } else {
        shellIndex += 1
      }
    }

    for index in sparks.indices {
      sparks[index].life -= Self.step
      guard sparks[index].life > 0, sparks[index].y < h + 2 else {
        sparks[index].life = 0
        continue
      }
      let drag = sparks[index].golden ? 0.985 : 0.955
      sparks[index].vx *= drag
      sparks[index].vy = sparks[index].vy * drag + (sparks[index].golden ? 30 : 24) * Self.step
      sparks[index].x += sparks[index].vx * Self.step
      sparks[index].y += sparks[index].vy * Self.step

      let fade = pow(max(0, sparks[index].life / sparks[index].lifespan), 1.5)
      var value = fade * (sparks[index].golden ? 255 : 235)
      if sparks[index].life < sparks[index].lifespan * 0.3 {
        let gate = VisualizerRaster.hash(
          x: Int(sparks[index].x), y: Int(sparks[index].y),
          salt: UInt32(truncatingIfNeeded: energy.beatCount))
        if gate % 3 == 0 { value = 0 }
      }
      raster.plot(x: sparks[index].x, y: sparks[index].y, value: value)
    }
    sparks.removeAll { $0.life <= 0 }
    flash *= exp(-Self.step * 5.5)

    composeHarbor(waterline: waterline)
  }

  private func launch(strength: Double, width: Double, waterline: Int) {
    guard shells.count < 4 else { return }
    sinceLaunch = 0
    let x = width * (0.12 + noise.unit() * 0.76)
    let apex = Double(raster.height) * (0.08 + noise.unit() * 0.3)
    let drop = Double(waterline) - apex
    let climb = (drop * 2.4 + 18) * (0.85 + noise.unit() * 0.2)
    shells.append(
      Shell(x: x, y: Double(waterline), climb: climb, apex: apex, strength: strength))
  }

  private func burst(_ shell: Shell) {
    let style = burstStyle % 3
    burstStyle += 1
    flash = min(1, flash + 0.35 + shell.strength * 0.5)

    let count = min(Self.sparkCap - sparks.count, Int(22 + shell.strength * 46))
    guard count > 0 else { return }
    let power = 26 + shell.strength * 26

    for i in 0..<count {
      var spark = Spark(
        x: shell.x, y: shell.y, vx: 0, vy: 0, life: 0, lifespan: 1, golden: false)
      switch style {
      case 0:
        let angle = noise.unit()
        let speed = power * (0.3 + noise.unit() * 0.7)
        spark.vx = VFDTrig.cos(angle) * speed
        spark.vy = VFDTrig.sin(angle) * speed * 0.55
        spark.lifespan = 0.9 + noise.unit() * 0.6
      case 1:
        let angle = Double(i) / Double(count) + noise.unit() * 0.02
        let speed = power * 0.95
        spark.vx = VFDTrig.cos(angle) * speed
        spark.vy = VFDTrig.sin(angle) * speed * 0.5
        spark.lifespan = 1.0 + noise.unit() * 0.3
      default:
        let angle = 0.25 + (noise.unit() - 0.5) * 0.34
        let speed = power * (0.5 + noise.unit() * 0.55)
        spark.vx = VFDTrig.cos(angle) * speed
        spark.vy = -abs(VFDTrig.sin(angle)) * speed * 0.75 - 6
        spark.lifespan = 1.8 + noise.unit() * 0.9
        spark.golden = true
      }
      spark.life = spark.lifespan
      sparks.append(spark)
    }

    for dx in -1...1 {
      for dy in -1...1 {
        raster.plot(x: shell.x + Double(dx), y: shell.y + Double(dy), value: dx == 0 && dy == 0 ? 255 : 120)
      }
    }
  }

  private func composeHarbor(waterline: Int) {
    let w = raster.width
    let h = raster.height

    for y in 0..<max(0, waterline - 6) {
      for x in 0..<w {
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0x57AB)
        guard hash % 131 == 0 else { continue }
        let twinkle = VFDTrig.wave(energy.flow * 0.5 + Double(hash % 512) / 37)
        raster.plot(x, y, UInt8(16 + twinkle * 26))
      }
    }

    for x in 0..<w {
      let rise = min(waterline, skyline.rise(at: x))
      let roofY = waterline - rise
      raster.vspan(x: x, from: roofY, to: waterline - 1, 30)
      for row in 1...max(1, rise) {
        let window = skyline.window(atColumn: x, rowsBelowRoof: row)
        guard window > 0 else { continue }
        raster.set(
          x, roofY + row - 1,
          UInt8(min(255, 52 + window * 58 + flash * 120)))
      }
    }
    raster.hspan(y: waterline, from: 0, to: w - 1, UInt8(min(255, 64 + flash * 130)))

    let depthRows = h - waterline - 1
    guard depthRows > 0 else { return }
    let squash = Double(waterline) / Double(depthRows)
    for dy in 1...depthRows {
      let y = waterline + dy
      let srcY = max(0, Double(waterline) - Double(dy) * squash)
      let attenuation = max(0.16, 0.62 - Double(dy) / Double(max(1, depthRows)) * 0.4)
      let wobble = 1.0 + Double(dy) * 0.35
      for x in 0..<w {
        let shimmer =
          VFDTrig.sin(Double(x) / 7.3 + energy.flow * 0.8 + Double(dy) * 0.16) * wobble
        let sampled = Double(raster.sample(x: Double(x) + shimmer, y: srcY))
        raster.set(x, y, UInt8(min(255, sampled * attenuation + 8)))
      }
    }
  }
}
