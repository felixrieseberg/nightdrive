import CoreGraphics
import Foundation

// MARK: - Trigonometry

enum VFDTrig {
  private static let bits = 12
  private static let count = 1 << bits
  private static let table: [Double] = (0..<count).map {
    Foundation.sin(Double($0) / Double(count) * 2 * .pi)
  }

  static func sin(_ turns: Double) -> Double {
    guard turns.isFinite else { return 0 }
    let wrapped = turns - turns.rounded(.down)
    return table[Int(wrapped * Double(count)) & (count - 1)]
  }

  static func cos(_ turns: Double) -> Double { sin(turns + 0.25) }

  static func wave(_ turns: Double) -> Double { sin(turns) * 0.5 + 0.5 }
}

// MARK: - 3D

struct Vec3: Equatable, Sendable {
  var x: Double
  var y: Double
  var z: Double

  static let zero = Vec3(x: 0, y: 0, z: 0)

  static func + (a: Vec3, b: Vec3) -> Vec3 {
    Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
  }

  static func - (a: Vec3, b: Vec3) -> Vec3 {
    Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
  }

  static func * (v: Vec3, s: Double) -> Vec3 {
    Vec3(x: v.x * s, y: v.y * s, z: v.z * s)
  }

  func dot(_ other: Vec3) -> Double { x * other.x + y * other.y + z * other.z }

  func cross(_ other: Vec3) -> Vec3 {
    Vec3(
      x: y * other.z - z * other.y,
      y: z * other.x - x * other.z,
      z: x * other.y - y * other.x)
  }

  var length: Double { (x * x + y * y + z * z).squareRoot() }

  var normalized: Vec3 {
    let magnitude = length
    return magnitude > 0 ? self * (1 / magnitude) : .zero
  }
}

struct Mat3: Sendable {
  var m: (Double, Double, Double, Double, Double, Double, Double, Double, Double)

  static let identity = Mat3(m: (1, 0, 0, 0, 1, 0, 0, 0, 1))

  static func rotation(x: Double, y: Double, z: Double) -> Mat3 {
    let (sx, cx) = (VFDTrig.sin(x), VFDTrig.cos(x))
    let (sy, cy) = (VFDTrig.sin(y), VFDTrig.cos(y))
    let (sz, cz) = (VFDTrig.sin(z), VFDTrig.cos(z))
    return Mat3(
      m: (
        cy * cz, cz * sx * sy - cx * sz, cx * cz * sy + sx * sz,
        cy * sz, cx * cz + sx * sy * sz, -cz * sx + cx * sy * sz,
        -sy, cy * sx, cx * cy
      ))
  }

  func callAsFunction(_ v: Vec3) -> Vec3 {
    Vec3(
      x: m.0 * v.x + m.1 * v.y + m.2 * v.z,
      y: m.3 * v.x + m.4 * v.y + m.5 * v.z,
      z: m.6 * v.x + m.7 * v.y + m.8 * v.z)
  }
}

struct VFDCamera {
  var size: CGSize
  var focal: Double = 2.0
  var distance: Double = 3.4

  func project(_ v: Vec3) -> (point: CGPoint, depth: Double, scale: Double)? {
    let z = v.z + distance
    guard z > 0.05 else { return nil }
    let scale = focal / z
    let unit = min(size.height, size.width) * 0.5
    return (
      CGPoint(
        x: size.width * 0.5 + CGFloat(v.x * scale) * unit,
        y: size.height * 0.5 - CGFloat(v.y * scale) * unit),
      z, scale
    )
  }
}

// MARK: - Frame timing

enum FrameClock {
  static let defaultStep = 1.0 / 24.0

  static func clampedDelta(
    now: TimeInterval, last: TimeInterval, max maxStep: Double = 0.1
  ) -> Double {
    let elapsed = now - last
    guard last >= 0, elapsed >= 0 else { return defaultStep }
    return Swift.min(elapsed, maxStep)
  }
}

// MARK: - Listening

@MainActor
final class AudioEnergy {
  private(set) var bass: Double = 0
  private(set) var mid: Double = 0
  private(set) var treble: Double = 0
  private(set) var level: Double = 0

  private(set) var beat: Double = 0
  private(set) var beatCount = 0
  private(set) var didBeat = false
  private(set) var sinceBeat: Double = 99

  private(set) var flow: Double = 0

  private(set) var ceiling: Double = AudioEnergy.floorLevel

  private var previous: [Float] = []
  private var history: [Double] = []
  private var lastTime: TimeInterval = -1

  private static let historyLength = 24
  private static let cooldown: Double = 0.12
  private static let floorLevel: Double = 0.16

  func reset() {
    bass = 0
    mid = 0
    treble = 0
    level = 0
    beat = 0
    beatCount = 0
    didBeat = false
    sinceBeat = 99
    flow = 0
    ceiling = Self.floorLevel
    previous.removeAll()
    history.removeAll()
    lastTime = -1
  }

  @discardableResult
  func update(_ frame: VisualizerFrame) -> Double {
    didBeat = false
    if lastTime >= 0 {
      let elapsed = frame.time - lastTime
      if elapsed >= 0, elapsed <= 0.0005 {
        return 0
      }
    }
    let dt = FrameClock.clampedDelta(now: frame.time, last: lastTime, max: 0.25)
    lastTime = frame.time

    let bands = frame.spectrum
    let rawBass = energy(bands, from: 0.0, to: 0.18)
    let rawMid = energy(bands, from: 0.18, to: 0.55)
    let rawTreble = energy(bands, from: 0.55, to: 1.0)
    let rawLevel = min(1, max(0, frame.level.isFinite ? frame.level : 0))

    let loudest = max(rawBass, max(rawMid, max(rawTreble, rawLevel)))
    if loudest > ceiling {
      ceiling = loudest
    } else {
      ceiling = max(Self.floorLevel, ceiling - (ceiling - loudest) * min(1, dt / 2.2))
    }
    let gain = 1 / ceiling

    bass = envelope(bass, target: min(1, rawBass * gain), dt: dt)
    mid = envelope(mid, target: min(1, rawMid * gain), dt: dt)
    treble = envelope(treble, target: min(1, rawTreble * gain), dt: dt)
    level = envelope(level, target: min(1, rawLevel * gain), dt: dt)

    beat = max(0, beat - dt * 3.0)
    sinceBeat += dt
    flow += dt * (0.06 + level * 0.55 + bass * 0.35)

    detectOnset(bands)
    return dt
  }

  func band(_ frame: VisualizerFrame, _ index: Int, of count: Int) -> Double {
    min(1, frame.band(index, of: count) / ceiling)
  }

  private func envelope(_ current: Double, target: Double, dt: Double) -> Double {
    let tau = target > current ? 0.04 : 0.26
    let alpha = 1 - exp(-dt / tau)
    return current + (target - current) * alpha
  }

  private func energy(_ bands: [Float], from: Double, to: Double) -> Double {
    guard bands.count > 1 else { return 0 }
    let last = Double(bands.count - 1)
    let lo = Int((from * last).rounded(.down))
    let hi = min(bands.count - 1, max(lo, Int((to * last).rounded())))
    var sum = 0.0
    for index in lo...hi {
      let band = Double(bands[index])
      sum += band.isFinite ? min(1, max(0, band)) : 0
    }
    return min(1, sum / Double(hi - lo + 1))
  }

  private func detectOnset(_ bands: [Float]) {
    guard bands.count > 1 else { return }
    defer { previous = bands }
    guard previous.count == bands.count else { return }

    var flux = 0.0
    for index in 0..<bands.count {
      let rise = Double(bands[index]) - Double(previous[index])
      if rise > 0 { flux += rise }
    }
    flux /= Double(bands.count)

    history.append(flux)
    if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    guard history.count >= 6 else { return }

    let mean = history.reduce(0, +) / Double(history.count)
    let threshold = mean * 1.55 + 0.006 * ceiling / Self.floorLevel
    if flux > threshold, level > 0.05, sinceBeat > Self.cooldown {
      beat = 1
      beatCount += 1
      didBeat = true
      sinceBeat = 0
    }
  }
}
