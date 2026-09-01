import Foundation

@MainActor
enum HeadUnitVisualizers {
  static func all() -> [any Visualizer] {
    [
      VUVisualizer(),
      EQCurveVisualizer(),
      RippleVisualizer(),
      MarqueeVisualizer(),
      ComboVisualizer(),
    ]
  }
}
