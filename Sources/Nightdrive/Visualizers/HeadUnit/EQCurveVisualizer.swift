import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class EQCurveVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "eq", name: "EQ CURVE", wantsContinuousRedraw: true)

  private static let sevenBand = ["60", "150", "400", "1K", "2.4K", "6K", "15K"]
  private static let thirteenBand = [
    "32", "50", "80", "125", "200", "315", "500", "800", "1.2K", "2K", "3.1K", "8K", "16K",
  ]

  private var sliders: [Double] = []
  private var lastTime: TimeInterval = -1

  func reset() {
    sliders.removeAll()
    lastTime = -1
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 90, size.height > 26 else { return }
    let palette = frame.palette

    let labels = size.width > 620 ? Self.thirteenBand : Self.sevenBand
    let count = labels.count

    let labelHeight = DotMatrix.height(dot: 1)
    let gutter: CGFloat = size.width > 260 ? DotMatrix.width(of: "+12", dot: 1) + 6 : 0
    let field = CGRect(
      x: gutter, y: 2, width: size.width - gutter - 2, height: size.height - labelHeight - 6)
    guard field.width > 40, field.height > 12 else { return }

    updateSliders(frame, count: count)

    let pitch = field.width / CGFloat(count)
    func sliderX(_ index: Int) -> CGFloat { field.minX + (CGFloat(index) + 0.5) * pitch }
    func sliderY(_ value: Double) -> CGFloat { field.maxY - CGFloat(value) * field.height }

    var rules = Path()
    var tracks = Path()
    for level in [0.06, 0.5, 0.94] {
      let y = sliderY(level)
      var x = field.minX
      while x < field.maxX {
        rules.addRect(CGRect(x: x, y: y - 0.5, width: 2, height: 1))
        x += 5
      }
    }
    for index in 0..<count {
      let x = sliderX(index)
      var y = field.minY
      while y < field.maxY {
        tracks.addRect(CGRect(x: x - 0.5, y: y, width: 1, height: 2))
        y += 4
      }
    }
    ctx.fill(rules, with: .color(palette.ghost.opacity(1.6).color))
    ctx.fill(tracks, with: .color(palette.ghost.opacity(1.6).color))

    var curve = Path()
    var envelope = Path()
    let midline = sliderY(0.5)
    for index in 0..<count {
      let point = CGPoint(x: sliderX(index), y: sliderY(sliders[index]))
      if index == 0 {
        curve.move(to: CGPoint(x: field.minX, y: point.y))
        curve.addLine(to: point)
        envelope.move(to: CGPoint(x: field.minX, y: midline))
        envelope.addLine(to: CGPoint(x: field.minX, y: point.y))
        envelope.addLine(to: point)
      } else {
        let previous = CGPoint(x: sliderX(index - 1), y: sliderY(sliders[index - 1]))
        let midX = (previous.x + point.x) / 2
        curve.addCurve(
          to: point, control1: CGPoint(x: midX, y: previous.y),
          control2: CGPoint(x: midX, y: point.y))
        envelope.addCurve(
          to: point, control1: CGPoint(x: midX, y: previous.y),
          control2: CGPoint(x: midX, y: point.y))
      }
    }
    if let last = sliders.last {
      curve.addLine(to: CGPoint(x: field.maxX, y: sliderY(last)))
      envelope.addLine(to: CGPoint(x: field.maxX, y: sliderY(last)))
      envelope.addLine(to: CGPoint(x: field.maxX, y: midline))
      envelope.closeSubpath()
    }
    ctx.fill(envelope, with: .color(palette.glow.opacity(0.16).color))
    ctx.glowing(palette.glow, radius: 3).stroke(
      curve, with: .color(palette.glow.color),
      style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

    var caps = Path()
    var hotCaps = Path()
    let capWidth = min(pitch * 0.52, 16)
    for index in 0..<count {
      let rect = CGRect(
        x: sliderX(index) - capWidth / 2, y: sliderY(sliders[index]) - 1.75,
        width: capWidth, height: 3.5)
      let path = Path(roundedRect: rect, cornerRadius: 1.2)
      if sliders[index] > 0.82 || sliders[index] < 0.18 {
        hotCaps.addPath(path)
      } else {
        caps.addPath(path)
      }
    }
    ctx.glowing(palette.glow, radius: 2).fill(caps, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2.5).fill(hotCaps, with: .color(palette.amber.color))

    var lettering = Path()
    let labelY = field.maxY + 3
    let showLabels = pitch > DotMatrix.width(of: "2.4K", dot: 1) + 4
    if showLabels {
      for (index, label) in labels.enumerated() {
        DotMatrix.draw(
          label,
          at: CGPoint(x: sliderX(index) - DotMatrix.width(of: label, dot: 1) / 2, y: labelY),
          dot: 1, into: &lettering)
      }
    }
    if gutter > 0 {
      for (label, level) in [("+12", 0.94), ("0", 0.5), ("-12", 0.06)] {
        DotMatrix.draw(
          label,
          at: CGPoint(
            x: gutter - 5 - DotMatrix.width(of: label, dot: 1),
            y: sliderY(level) - DotMatrix.height(dot: 1) / 2),
          dot: 1, into: &lettering)
      }
      DotMatrix.draw("EQ", at: CGPoint(x: 1, y: labelY), dot: 1, into: &lettering)
    }
    ctx.fill(lettering, with: .color(palette.dim.color))
  }

  private func updateSliders(_ frame: VisualizerFrame, count: Int) {
    if sliders.count != count {
      sliders = [Double](repeating: 0.5, count: count)
      lastTime = -1
    }
    let step = FrameClock.clampedDelta(now: frame.time, last: lastTime)
    lastTime = frame.time

    var bands = (0..<count).map { frame.band($0, of: count) }
    let average = bands.reduce(0, +) / Double(count)
    if let boot = frame.boot {
      bands = (0..<count).map { index in
        let crest = boot * Double(count + 4) - 2
        return average + max(0, 1 - abs(Double(index) - crest) / 2.2) * 0.9
      }
    }

    for index in 0..<count {
      let departure = (bands[index] - average) * 1.5 + frame.level * 0.12
      let target =
        frame.isPlaying || frame.boot != nil
        ? min(0.96, max(0.04, 0.5 + departure)) : 0.5
      let rate = target > sliders[index] ? 9.0 : 4.5
      sliders[index] += (target - sliders[index]) * min(1, step * rate)
    }
  }
}
