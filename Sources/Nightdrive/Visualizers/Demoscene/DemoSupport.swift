import CoreGraphics
import Foundation

struct DemoNoise {
  private var state: UInt32

  init(seed: UInt32 = 0x1234_5678) {
    state = seed == 0 ? 1 : seed
  }

  mutating func next() -> UInt32 {
    state ^= state << 13
    state ^= state >> 17
    state ^= state << 5
    return state
  }

  mutating func unit() -> Double { Double(next() & 0xFF_FFFF) / Double(0x100_0000) }

  mutating func signed() -> Double { unit() * 2 - 1 }

  static func smooth(_ position: Double, seed: UInt32 = 0) -> Double {
    guard position.isFinite else { return 0.5 }
    let cell = position.rounded(.down)
    guard let index = Int(exactly: cell), index < Int.max else { return 0.5 }
    let t = position - cell
    let a = Double(VisualizerRaster.hash(x: index, y: 0, salt: seed) & 0xFFFF) / 65535
    let b = Double(VisualizerRaster.hash(x: index + 1, y: 0, salt: seed) & 0xFFFF) / 65535
    let blend = t * t * (3 - 2 * t)
    return a + (b - a) * blend
  }
}

extension VisualizerRaster {
  func strike(_ progress: Double, trail: Double = 0.22) {
    guard !isEmpty else { return }
    let crest = progress * Double(width + 12) - 6
    for x in 0..<width {
      let distance = (Double(x) - crest) / Double(width)
      let brightness =
        distance > 0 ? max(0, 0.15 - distance * 2) : max(0.1, 1 + distance / trail)
      guard brightness > 0.01 else { continue }
      let value = UInt8(min(255, brightness * 255))
      for y in 0..<height where self.value(x, y) < value {
        set(x, y, value)
      }
    }
  }

  func wipe(_ progress: Double) {
    guard !isEmpty else { return }
    let edge = Int(progress * Double(width + 6)) - 3
    for x in 0..<width {
      if x > edge {
        for y in 0..<height { set(x, y, 0) }
      } else if x > edge - 2 {
        for y in 0..<height { set(x, y, 255) }
      }
    }
  }
}
