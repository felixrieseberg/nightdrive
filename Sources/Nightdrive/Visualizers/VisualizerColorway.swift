import Foundation

struct VisualizerColorway: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var shortName: String
  var palette: VisualizerPalette

  static let all: [VisualizerColorway] = [
    VisualizerColorway(
      id: "vfd", name: String(localized: "MINT VFD"), shortName: String(localized: "MINT"),
      palette: .vfd),
    VisualizerColorway(
      id: "ice", name: String(localized: "ICE BLUE"), shortName: String(localized: "ICE"),
      palette: .ice),
    VisualizerColorway(
      id: "xplod", name: String(localized: "XPLOD RED"), shortName: String(localized: "XPLOD"),
      palette: .xplod),
    VisualizerColorway(
      id: "amber", name: String(localized: "AMBER GOLD"),
      shortName: String(localized: "AMBER"), palette: .amberGold),
    VisualizerColorway(
      id: "arctic", name: String(localized: "ARCTIC LCD"),
      shortName: String(localized: "ARCTIC"), palette: .arctic),
    VisualizerColorway(
      id: "plasma", name: String(localized: "PLASMA VIOLET"),
      shortName: String(localized: "PLASMA"), palette: .plasma),
  ]

  static let `default` = all[0]

  static func colorway(id: String?) -> VisualizerColorway {
    guard let id, let match = all.first(where: { $0.id == id }) else { return .default }
    return match
  }

  static func palette(id: String?) -> VisualizerPalette {
    colorway(id: id).palette
  }

  // MARK: - Persistence

  static let defaultsKey = "visualizerColorway"

  static func stored(in defaults: UserDefaults) -> VisualizerColorway {
    colorway(id: defaults.string(forKey: defaultsKey))
  }

  static func store(_ id: String, in defaults: UserDefaults) {
    defaults.set(id, forKey: defaultsKey)
  }
}

extension VisualizerPalette {
  static let ice = VisualizerPalette(
    glow: VisualizerColor(red: 0.52, green: 0.80, blue: 1.0),
    amber: VisualizerColor(red: 1.0, green: 0.71, blue: 0.29),
    dim: VisualizerColor(red: 0.52, green: 0.80, blue: 1.0, alpha: 0.46),
    ghost: VisualizerColor(red: 0.52, green: 0.80, blue: 1.0, alpha: 0.10))

  static let xplod = VisualizerPalette(
    glow: VisualizerColor(red: 1.0, green: 0.31, blue: 0.24),
    amber: VisualizerColor(red: 1.0, green: 0.78, blue: 0.28),
    dim: VisualizerColor(red: 1.0, green: 0.36, blue: 0.26, alpha: 0.48),
    ghost: VisualizerColor(red: 1.0, green: 0.38, blue: 0.28, alpha: 0.12))

  static let amberGold = VisualizerPalette(
    glow: VisualizerColor(red: 1.0, green: 0.72, blue: 0.22),
    amber: VisualizerColor(red: 0.62, green: 1.0, blue: 0.45),
    dim: VisualizerColor(red: 1.0, green: 0.74, blue: 0.28, alpha: 0.46),
    ghost: VisualizerColor(red: 1.0, green: 0.76, blue: 0.32, alpha: 0.11))

  static let arctic = VisualizerPalette(
    glow: VisualizerColor(red: 0.90, green: 0.96, blue: 1.0),
    amber: VisualizerColor(red: 0.42, green: 0.72, blue: 1.0),
    dim: VisualizerColor(red: 0.82, green: 0.92, blue: 1.0, alpha: 0.44),
    ghost: VisualizerColor(red: 0.78, green: 0.90, blue: 1.0, alpha: 0.10))

  static let plasma = VisualizerPalette(
    glow: VisualizerColor(red: 0.72, green: 0.55, blue: 1.0),
    amber: VisualizerColor(red: 1.0, green: 0.42, blue: 0.78),
    dim: VisualizerColor(red: 0.72, green: 0.55, blue: 1.0, alpha: 0.46),
    ghost: VisualizerColor(red: 0.74, green: 0.58, blue: 1.0, alpha: 0.12))
}
