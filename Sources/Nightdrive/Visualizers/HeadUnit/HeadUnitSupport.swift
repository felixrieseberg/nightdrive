import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Dot-matrix font

enum DotMatrix {
  static let columns = 5
  static let rows = 7

  static func height(dot: CGFloat) -> CGFloat { CGFloat(rows) * dot }

  static func advance(dot: CGFloat, tracking: CGFloat = 1) -> CGFloat {
    (CGFloat(columns) + tracking) * dot
  }

  static func width(of text: String, dot: CGFloat, tracking: CGFloat = 1) -> CGFloat {
    let count = CGFloat(normalized(text).count)
    guard count > 0 else { return 0 }
    return count * advance(dot: dot, tracking: tracking) - tracking * dot
  }

  static func pixelSize(dot: CGFloat) -> CGFloat { max(1, dot * 0.86) }

  @discardableResult
  static func draw(
    _ text: String, at origin: CGPoint, dot: CGFloat, into path: inout Path,
    tracking: CGFloat = 1, clip: CGRect? = nil
  ) -> CGFloat {
    let size = pixelSize(dot: dot)
    var x = origin.x
    for character in normalized(text) {
      defer { x += advance(dot: dot, tracking: tracking) }
      if let clip, x + CGFloat(columns) * dot < clip.minX || x > clip.maxX { continue }
      guard let glyph = VFDDotFont.headUnitGlyph(character), glyph.contains(where: { $0 != 0 })
      else { continue }
      for column in 0..<columns {
        let bits = glyph[column]
        for row in 0..<rows where bits & (1 << UInt8(row)) != 0 {
          path.addRect(
            CGRect(
              x: x + CGFloat(column) * dot, y: origin.y + CGFloat(row) * dot,
              width: size, height: size))
        }
      }
    }
    return x
  }

  static func ghostGrid(in rect: CGRect, dot: CGFloat, into path: inout Path) {
    guard dot > 0, rect.width > 0, rect.height > 0 else { return }
    let size = max(0.8, dot * 0.7)
    var y = rect.minY
    while y + size <= rect.maxY + 0.01 {
      var x = rect.minX
      while x + size <= rect.maxX + 0.01 {
        path.addRect(CGRect(x: x, y: y, width: size, height: size))
        x += dot
      }
      y += dot
    }
  }

  static func normalized(_ text: String) -> [Character] {
    let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
    return folded.uppercased().map { character in
      if VFDDotFont.headUnitGlyph(character) != nil { return character }
      switch character {
      case "\u{2013}", "\u{2014}": return "-"
      case "\u{2018}", "\u{2019}", "`": return "'"
      case "\u{201C}", "\u{201D}": return "\""
      case "\u{2026}": return "."
      case "\t", "\n", "\r": return " "
      default: return "\u{00A4}"
      }
    }
  }
}

// MARK: - Peak-hold caps

struct PeakCaps {
  var hold: TimeInterval = 0.8
  var gravity: Double = 1.6
  var ridesOnBars = true

  private(set) var values: [Double] = []
  private var releaseAt: [TimeInterval] = []
  private var velocity: [Double] = []
  private var lastTime: TimeInterval = -1

  init(hold: TimeInterval = 0.8, gravity: Double = 1.6, ridesOnBars: Bool = true) {
    self.hold = hold
    self.gravity = gravity
    self.ridesOnBars = ridesOnBars
  }

  mutating func reset() {
    values.removeAll()
    releaseAt.removeAll()
    velocity.removeAll()
    lastTime = -1
  }

  mutating func update(_ bars: [Double], at time: TimeInterval) {
    if values.count != bars.count {
      values = bars
      releaseAt = bars.map { _ in time + hold }
      velocity = [Double](repeating: 0, count: bars.count)
      lastTime = time
      return
    }
    let step = FrameClock.clampedDelta(now: time, last: lastTime)
    lastTime = time

    for index in bars.indices {
      let bar = bars[index]
      if bar >= values[index] {
        values[index] = bar
        velocity[index] = 0
        releaseAt[index] = time + hold
      } else if time >= releaseAt[index] {
        velocity[index] += gravity * step
        values[index] -= velocity[index] * step
        if ridesOnBars, values[index] < bar {
          values[index] = bar
          velocity[index] = 0
          releaseAt[index] = time + hold
        }
        if values[index] < 0 {
          values[index] = 0
          velocity[index] = 0
        }
      }
    }
  }

  func value(_ index: Int) -> Double {
    index >= 0 && index < values.count ? values[index] : 0
  }
}

// MARK: - Needle ballistics

struct NeedleBallistics {
  var frequency: Double = 16
  var risingDamping: Double = 0.5
  var fallingDamping: Double = 0.9

  private(set) var position: Double = 0
  private(set) var velocity: Double = 0
  private var lastTime: TimeInterval = -1

  init(frequency: Double = 16, risingDamping: Double = 0.5, fallingDamping: Double = 0.9) {
    self.frequency = frequency
    self.risingDamping = risingDamping
    self.fallingDamping = fallingDamping
  }

  mutating func reset() {
    position = 0
    velocity = 0
    lastTime = -1
  }

  @discardableResult
  mutating func step(toward target: Double, at time: TimeInterval) -> Double {
    let step = FrameClock.clampedDelta(now: time, last: lastTime)
    lastTime = time
    return advance(toward: target, by: step)
  }

  @discardableResult
  mutating func advance(toward target: Double, by step: Double) -> Double {
    guard step > 0 else { return position }
    let slices = max(1, Int((step / 0.008).rounded(.up)))
    let slice = step / Double(slices)
    for _ in 0..<slices {
      let error = target - position
      let damping = error >= 0 ? risingDamping : fallingDamping
      velocity += (frequency * frequency * error - 2 * damping * frequency * velocity) * slice
      position += velocity * slice
    }
    if position > 1.12 {
      position = 1.12
      velocity = min(velocity, 0)
    } else if position < -0.06 {
      position = -0.06
      velocity = max(velocity, 0)
    }
    return position
  }
}

// MARK: - Beat detection

struct BeatDetector {
  var threshold: Double = 1.3
  var refractory: TimeInterval = 0.22

  private(set) var energy: Double = 0
  private(set) var average: Double = 0
  private(set) var pulse: Double = 0
  private(set) var count: Int = 0
  private var lastBeat: TimeInterval = -10
  private var lastTime: TimeInterval = -1
  private let pulseDecay: TimeInterval = 0.34

  init(threshold: Double = 1.3, refractory: TimeInterval = 0.22) {
    self.threshold = threshold
    self.refractory = refractory
  }

  mutating func reset() {
    energy = 0
    average = 0
    pulse = 0
    count = 0
    lastBeat = -10
    lastTime = -1
  }

  @discardableResult
  mutating func update(_ frame: VisualizerFrame, at time: TimeInterval) -> Bool {
    let step = FrameClock.clampedDelta(now: time, last: lastTime)
    lastTime = time

    let bands = 5
    var low = 0.0
    for index in 0..<bands { low += frame.band(index, of: 24) }
    energy = low / Double(bands)
    average += (energy - average) * min(1, step * (energy > average ? 6.0 : 1.6))

    pulse = max(0, pulse - step / pulseDecay)
    let hit =
      frame.isPlaying && energy > 0.07 && energy > average * threshold
      && time - lastBeat > refractory
    if hit {
      lastBeat = time
      count += 1
      pulse = 1
    }
    return hit
  }
}

// MARK: - Frame conveniences

extension VisualizerFrame {
  func selfTestCrest(bar: Int, of count: Int) -> Double {
    guard let boot else { return 0 }
    let crest = boot * Double(count + 10) - 5
    return max(0, 1 - abs(Double(bar) - crest) / 5)
  }

  func analyzerBars(_ count: Int) -> [Double] {
    (0..<count).map { index in
      max(band(index, of: count), selfTestCrest(bar: index, of: count))
    }
  }

  func energy(from low: Double, to high: Double, bands: Int = 24) -> Double {
    let first = max(0, min(bands - 1, Int(low * Double(bands - 1))))
    let last = max(first, min(bands - 1, Int(high * Double(bands - 1))))
    var total = 0.0
    for index in first...last { total += band(index, of: bands) }
    return min(1, total / Double(last - first + 1))
  }

  static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds.isFinite ? seconds : 0))
    return String(format: "%d:%02d", total / 60, total % 60)
  }
}
