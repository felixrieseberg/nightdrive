import CoreGraphics
import Foundation
import SwiftUI

struct VisualizerColor: Sendable, Hashable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double = 1

  var color: Color {
    Color(red: red, green: green, blue: blue).opacity(alpha)
  }

  var relativeLuminance: Double {
    func linear(_ channel: Double) -> Double {
      channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }

  func contrastRatio(against other: VisualizerColor) -> Double {
    let a = relativeLuminance
    let b = other.relativeLuminance
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
  }

  func opacity(_ value: Double) -> VisualizerColor {
    VisualizerColor(red: red, green: green, blue: blue, alpha: alpha * value)
  }
}

struct VisualizerPalette: Sendable, Hashable {
  var glow: VisualizerColor
  var amber: VisualizerColor
  var dim: VisualizerColor
  var ghost: VisualizerColor

  static let vfd = VisualizerPalette(
    glow: VisualizerColor(red: 0.45, green: 1.0, blue: 0.84),
    amber: VisualizerColor(red: 1.0, green: 0.72, blue: 0.36),
    dim: VisualizerColor(red: 0.45, green: 1.0, blue: 0.84, alpha: 0.45),
    ghost: VisualizerColor(red: 0.45, green: 1.0, blue: 0.84, alpha: 0.09))
}

struct VisualizerFrame: Sendable {
  var size: CGSize
  var time: TimeInterval = 0
  var spectrum: [Float] = []
  var peaks: [Float] = []
  var waveform: [Float] = []
  var level: Double = 0
  var elapsed: TimeInterval = 0
  var duration: TimeInterval = 0
  var isPlaying: Bool = false
  var title: String = ""
  var artist: String = ""
  var album: String = ""
  var boot: Double?
  var palette: VisualizerPalette = .vfd

  var width: CGFloat { size.width }
  var height: CGFloat { size.height }

  func band(_ index: Int, of count: Int) -> Double {
    Self.resample(spectrum, index: index, of: count)
  }

  func peak(_ index: Int, of count: Int) -> Double {
    Self.resample(peaks, index: index, of: count)
  }

  func wave(at fraction: Double) -> Double {
    guard waveform.count > 1 else { return 0 }
    let pos = min(max(fraction, 0), 1) * Double(waveform.count - 1)
    let lo = Int(pos)
    let hi = min(waveform.count - 1, lo + 1)
    let t = pos - Double(lo)
    let value = Double(waveform[lo]) * (1 - t) + Double(waveform[hi]) * t
    return value.isFinite ? value : 0
  }

  private static func resample(_ values: [Float], index: Int, of count: Int) -> Double {
    guard values.count > 1, count > 1, index >= 0 else { return 0 }
    let pos = Double(index) * Double(values.count - 1) / Double(count - 1)
    let lo = min(values.count - 1, max(0, Int(pos)))
    let hi = min(values.count - 1, lo + 1)
    let t = pos - Double(lo)
    let value = Double(values[lo]) * (1 - t) + Double(values[hi]) * t
    return value.isFinite ? value : 0
  }
}

enum VisualizerGroup: String, CaseIterable, Hashable, Sendable, Identifiable {
  case builtIn
  case plugin

  var id: String { rawValue }

  var title: String {
    switch self {
    case .builtIn: String(localized: "Built-in")
    case .plugin: String(localized: "Plugins")
    }
  }

  var symbol: String {
    switch self {
    case .builtIn: "square.grid.2x2"
    case .plugin: "puzzlepiece.extension"
    }
  }
}

struct VisualizerDescriptor: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var isPlugin: Bool = false
  var wantsContinuousRedraw: Bool = false
  var group: VisualizerGroup { isPlugin ? .plugin : .builtIn }
}

@MainActor
protocol Visualizer: AnyObject {
  var descriptor: VisualizerDescriptor { get }
  func reset()
  func draw(_ frame: VisualizerFrame, into context: inout GraphicsContext)
}

extension Visualizer {
  func reset() {}
  var id: String { descriptor.id }
}

extension GraphicsContext {
  func glowing(_ color: VisualizerColor, radius: CGFloat = 1.5) -> GraphicsContext {
    var copy = self
    copy.addFilter(.shadow(color: color.color.opacity(0.7), radius: radius))
    return copy
  }
}
