import CoreGraphics
import Foundation

@MainActor
enum MovieScreenVisualizers {
  static func all() -> [any Visualizer] {
    [
      AquariumVisualizer(),
      NightDriveVisualizer(),
      FireworksVisualizer(),
      DolphinsVisualizer(),
    ]
  }
}

struct CitySkyline: Sendable {
  var seed: UInt32
  var blockWidth: Int
  var maxRise: Int

  func rise(at x: Int) -> Int {
    let width = max(1, blockWidth)
    let block = x < 0 ? (x - width + 1) / width : x / width
    let h = VisualizerRaster.hash(x: block, y: 0, salt: seed)
    return 1 + Int(h % UInt32(max(1, maxRise)))
  }

  func window(atColumn x: Int, rowsBelowRoof row: Int) -> Double {
    guard row >= 1 else { return 0 }
    let h = VisualizerRaster.hash(x: x, y: row, salt: seed &+ 0x51DE)
    guard h % 5 == 0 else { return 0 }
    return 0.55 + Double(h >> 8 & 0xFF) / 255 * 0.45
  }
}
