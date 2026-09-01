import Observation
import SwiftUI

@Observable
@MainActor
final class VFDTheme {
  static let shared = VFDTheme()

  private(set) var colorway: VisualizerColorway

  var palette: VisualizerPalette { colorway.palette }

  init(colorway: VisualizerColorway = .stored(in: NightdriveDefaults.current)) {
    self.colorway = colorway
  }

  func select(id: String) {
    colorway = VisualizerColorway.colorway(id: id)
  }
}
