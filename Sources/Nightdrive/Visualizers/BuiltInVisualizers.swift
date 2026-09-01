import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class SpectrumVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "spectrum", name: "SPECTRUM", wantsContinuousRedraw: true)

  private var caps = PeakCaps(hold: 0.85, gravity: 1.7)

  func reset() {
    caps.reset()
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 24, size.height > 12 else { return }

    let pitch = max(4.5, min(8, size.width / 150))
    let bars = max(20, Int(size.width / pitch))
    let cellWidth = max(1.6, (size.width - CGFloat(bars - 1) * 1.6) / CGFloat(bars))
    let step = (size.width - cellWidth) / CGFloat(max(1, bars - 1))

    let rows = max(7, min(20, Int(size.height / 3.1)))
    let rowPitch = size.height / CGFloat(rows)
    let cellHeight = max(1.2, rowPitch - 1)
    let overload = Int(Double(rows) * 0.82)
    let hot = Int(Double(rows) * 0.55)

    let flash = frame.boot.map { $0 < 0.3 } ?? false
    let values = flash ? [Double](repeating: 1, count: bars) : frame.analyzerBars(bars)
    caps.update(values, at: frame.time)

    var ghost = Path()
    var lit = Path()
    var loud = Path()
    var over = Path()
    var capPath = Path()

    func cell(_ bar: Int, _ row: Int, height: CGFloat) -> CGRect {
      CGRect(
        x: CGFloat(bar) * step,
        y: size.height - CGFloat(row + 1) * rowPitch + (rowPitch - height),
        width: cellWidth, height: height)
    }

    for bar in 0..<bars {
      let litRows = min(rows, Int((values[bar] * Double(rows)).rounded(.up)))
      for row in 0..<rows {
        let rect = cell(bar, row, height: cellHeight)
        if row < litRows {
          if row >= overload {
            over.addRect(rect)
          } else if row >= hot {
            loud.addRect(rect)
          } else {
            lit.addRect(rect)
          }
        } else {
          ghost.addRect(rect)
        }
      }

      if litRows == 0 {
        lit.addRect(cell(bar, 0, height: cellHeight))
      }

      let capRow = Int((caps.value(bar) * Double(rows)).rounded(.up))
      if capRow > litRows, capRow <= rows {
        capPath.addRect(cell(bar, capRow - 1, height: max(1.2, cellHeight * 0.45)))
      }
    }

    let palette = frame.palette
    ctx.fill(ghost, with: .color(palette.ghost.color))
    let mark = size.height - CGFloat(overload) * rowPitch - 0.5
    ctx.fill(
      Path(CGRect(x: 0, y: mark, width: size.width, height: 0.7)),
      with: .color(palette.amber.opacity(0.16).color))

    ctx.glowing(palette.glow, radius: 1.2)
      .fill(lit, with: .color(palette.glow.opacity(0.82).color))
    ctx.glowing(palette.glow, radius: 2)
      .fill(loud, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2.5)
      .fill(over, with: .color(palette.amber.color))
    ctx.glowing(palette.amber, radius: 1.5)
      .fill(capPath, with: .color(palette.amber.opacity(0.9).color))
  }
}

@MainActor
final class ScopeVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(id: "scope", name: "SCOPE")

  private var history: [[Float]] = []
  private var lastPush: TimeInterval = -1

  func reset() {
    history.removeAll()
    lastPush = -1
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    if frame.time - lastPush >= 1.0 / 24.0 {
      lastPush = frame.time
      history.insert(frame.waveform, at: 0)
      if history.count > 4 { history.removeLast(history.count - 4) }
    }

    let size = frame.size
    let mid = size.height / 2
    graticule(frame, into: &ctx)

    for (age, wave) in history.enumerated().reversed() {
      guard wave.count > 1 else { continue }
      var trace = Path()
      let gain = Double(mid) * 1.9
      for i in 0..<wave.count {
        let x = CGFloat(i) / CGFloat(wave.count - 1) * size.width
        let y = min(size.height - 1, max(1, mid - CGFloat(Double(wave[i]) * gain)))
        let point = CGPoint(x: x, y: y)
        i == 0 ? trace.move(to: point) : trace.addLine(to: point)
      }
      let fade = age == 0 ? 1.0 : 0.22 / Double(age)
      let layer = age == 0 ? ctx.glowing(frame.palette.glow, radius: 3) : ctx
      layer.stroke(
        trace, with: .color(frame.palette.glow.opacity(fade).color),
        style: StrokeStyle(lineWidth: age == 0 ? 1.6 : 1, lineCap: .round, lineJoin: .round))
    }
  }

  private func graticule(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    var dots = Path()
    let columns = 12
    let rows = 6
    for column in 1..<columns {
      let x = size.width * CGFloat(column) / CGFloat(columns)
      var y: CGFloat = 2
      while y < size.height {
        dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
        y += 4
      }
    }
    for row in 1..<rows {
      let y = size.height * CGFloat(row) / CGFloat(rows)
      var x: CGFloat = 2
      while x < size.width {
        dots.addRect(CGRect(x: x, y: y, width: 1, height: 1))
        x += 4
      }
    }
    ctx.fill(dots, with: .color(frame.palette.ghost.color))
    ctx.fill(
      Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)),
      with: .color(frame.palette.ghost.color))
  }
}

@MainActor
final class WaterfallVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(id: "waterfall", name: "WATERFALL")

  private var columns: [[Float]] = []
  private var lastPush: TimeInterval = -1

  private static let rows = 7

  func reset() {
    columns.removeAll()
    lastPush = -1
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    let cellWidth: CGFloat = 9
    let capacity = max(8, Int(size.width / cellWidth) + 1)

    if frame.time - lastPush >= 1.0 / 24.0 {
      lastPush = frame.time
      let boot = frame.boot
      let column = (0..<Self.rows).map { row -> Float in
        let value = frame.band(row, of: Self.rows)
        return Float(max(value, boot == nil ? 0 : 1))
      }
      columns.insert(column, at: 0)
      if columns.count > capacity { columns.removeLast(columns.count - capacity) }
    }

    let rowHeight = (size.height - CGFloat(Self.rows - 1)) / CGFloat(Self.rows)
    guard rowHeight > 0 else { return }

    var tiers = [Path](repeating: Path(), count: 4)
    for (index, column) in columns.enumerated() {
      let x = size.width - CGFloat(index + 1) * cellWidth
      guard x > -cellWidth else { break }
      for row in 0..<min(Self.rows, column.count) {
        let value = Double(column[row])
        guard value > 0.04 else { continue }
        let tier = min(3, Int(value * 4))
        let y = size.height - CGFloat(row + 1) * rowHeight - CGFloat(row)
        tiers[tier].addRect(
          CGRect(x: x, y: y, width: cellWidth - 1, height: rowHeight))
      }
    }

    let palette = frame.palette
    let inks: [VisualizerColor] = [
      palette.glow.opacity(0.35), palette.glow.opacity(0.65), palette.glow, palette.amber,
    ]
    for (tier, path) in tiers.enumerated() where !path.isEmpty {
      let layer = tier >= 2 ? ctx.glowing(inks[tier]) : ctx
      layer.fill(path, with: .color(inks[tier].color))
    }

    if columns.isEmpty {
      ctx.fill(
        Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
        with: .color(palette.ghost.color))
    }
  }
}
