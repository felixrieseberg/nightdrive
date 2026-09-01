import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class ComboVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "combo", name: "COMBO", wantsContinuousRedraw: true)

  private var caps = PeakCaps(hold: 0.7, gravity: 1.9)
  private var ladderCaps = PeakCaps(hold: 0.9, gravity: 1.1, ridesOnBars: false)
  private var beat = BeatDetector()

  func reset() {
    caps.reset()
    ladderCaps.reset()
    beat.reset()
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 120, size.height > 24 else { return }

    beat.update(frame, at: frame.time)

    let split = (size.width * 0.58).rounded()
    analyzer(
      in: CGRect(x: 0, y: 0, width: split - 6, height: size.height), frame: frame, into: &ctx)

    var rule = Path()
    var y: CGFloat = 1
    while y < size.height - 1 {
      rule.addRect(CGRect(x: split - 3, y: y, width: 1, height: 2))
      y += 4
    }
    ctx.fill(rule, with: .color(frame.palette.dim.opacity(0.5).color))

    right(
      in: CGRect(x: split + 3, y: 0, width: size.width - split - 3, height: size.height),
      frame: frame, into: &ctx)
  }

  private func analyzer(
    in rect: CGRect, frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    guard rect.width > 40 else { return }
    let palette = frame.palette
    let labelHeight = DotMatrix.height(dot: 1) + 2
    let field = CGRect(
      x: rect.minX, y: rect.minY + 1, width: rect.width, height: rect.height - labelHeight - 2)
    guard field.height > 8 else { return }

    let count = max(8, min(24, Int(field.width / 7)))
    let pitch = field.width / CGFloat(count)
    let barWidth = max(2, pitch - 1.6)
    let rows = max(5, min(14, Int(field.height / 3.2)))
    let cellHeight = field.height / CGFloat(rows)
    let cellDrawn = max(1.2, cellHeight - 1)

    let bars = frame.analyzerBars(count)
    caps.update(bars, at: frame.time)

    var ghost = Path()
    var lit = Path()
    var hot = Path()
    var capPath = Path()
    for index in 0..<count {
      let x = field.minX + CGFloat(index) * pitch
      let filled = Int((bars[index] * Double(rows)).rounded())
      for row in 0..<rows {
        let cell = CGRect(
          x: x, y: field.maxY - CGFloat(row + 1) * cellHeight, width: barWidth,
          height: cellDrawn)
        if row < filled {
          row >= rows - 2 ? hot.addRect(cell) : lit.addRect(cell)
        } else {
          ghost.addRect(cell)
        }
      }
      let capRow = min(rows - 1, max(0, Int((caps.value(index) * Double(rows)).rounded()) - 1))
      if caps.value(index) > 0.02 {
        capPath.addRect(
          CGRect(
            x: x, y: field.maxY - CGFloat(capRow + 1) * cellHeight, width: barWidth,
            height: max(1, cellDrawn * 0.55)))
      }
    }
    ctx.fill(ghost, with: .color(palette.ghost.color))
    ctx.glowing(palette.glow, radius: 2).fill(lit, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2).fill(hot, with: .color(palette.amber.color))
    ctx.glowing(palette.amber, radius: 2.5).fill(
      capPath, with: .color(palette.amber.opacity(0.9).color))

    var lettering = Path()
    let marks = ["63", "250", "1K", "4K", "16K"]
    for (index, mark) in marks.enumerated() {
      let fraction = Double(index) / Double(marks.count - 1)
      let width = DotMatrix.width(of: mark, dot: 1)
      let x = min(
        field.maxX - width, max(field.minX, field.minX + CGFloat(fraction) * field.width - width / 2))
      DotMatrix.draw(mark, at: CGPoint(x: x, y: field.maxY + 2), dot: 1, into: &lettering)
    }
    ctx.fill(lettering, with: .color(palette.dim.color))
  }

  private func right(
    in rect: CGRect, frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    guard rect.width > 50 else { return }
    let palette = frame.palette
    let line = DotMatrix.height(dot: 1)
    let compact = rect.height < 36

    var lettering = Path()
    var bright = Path()

    let times =
      "\(VisualizerFrame.clock(frame.elapsed))  -"
      + VisualizerFrame.clock(max(0, frame.duration - frame.elapsed))
    let timesWidth = DotMatrix.width(of: times, dot: 1)

    let title = frame.title.isEmpty ? String(localized: "NO DISC") : frame.title
    DotMatrix.draw(
      Self.fit(title, width: compact ? rect.width - timesWidth - 6 : rect.width, dot: 1),
      at: CGPoint(x: rect.minX, y: rect.minY + 1), dot: 1, into: &bright)

    if compact {
      DotMatrix.draw(
        times, at: CGPoint(x: rect.maxX - timesWidth, y: rect.minY + 1), dot: 1,
        into: &lettering)
    } else {
      let artist = frame.artist.isEmpty ? String(localized: "NIGHTDRIVE") : frame.artist
      DotMatrix.draw(
        Self.fit(artist, width: rect.width, dot: 1),
        at: CGPoint(x: rect.minX, y: rect.minY + line + 3), dot: 1, into: &lettering)
      DotMatrix.draw(
        times,
        at: CGPoint(x: rect.maxX - timesWidth, y: rect.maxY - line - 1), dot: 1,
        into: &lettering)
    }

    ctx.glowing(palette.glow, radius: 2).fill(bright, with: .color(palette.glow.color))
    ctx.fill(lettering, with: .color(palette.dim.color))

    let laddersTop = rect.minY + (compact ? line + 4 : line * 2 + 6)
    let laddersHeight = (compact ? rect.maxY - 1 : rect.maxY - line - 4) - laddersTop
    guard laddersHeight > 5 else { return }
    let rowHeight = max(2, min(5, (laddersHeight - 3) / 2))
    let gap = max(1, min(3, laddersHeight - rowHeight * 2))
    let levels = [
      min(1, frame.level * 0.5 + frame.energy(from: 0, to: 0.3) * 0.85),
      min(1, frame.level * 0.5 + frame.energy(from: 0.3, to: 1) * 0.95),
    ].map { value in frame.boot.map { boot in max(value, 1 - abs(boot - 0.5) * 2) } ?? value }
    ladderCaps.update(levels, at: frame.time)

    let labelWidth = DotMatrix.width(of: "R", dot: 1) + 3
    var ladderLabels = Path()
    var ghost = Path()
    var lit = Path()
    var over = Path()
    var capPath = Path()
    let segments = max(6, Int((rect.width - labelWidth) / 5))
    let segmentPitch = (rect.width - labelWidth) / CGFloat(segments)
    let segmentWidth = max(1.5, segmentPitch - 1.4)

    for (index, label) in ["L", "R"].enumerated() {
      let y = laddersTop + CGFloat(index) * (rowHeight + gap)
      DotMatrix.draw(
        label, at: CGPoint(x: rect.minX, y: y + (rowHeight - line) / 2), dot: 1,
        into: &ladderLabels)
      let filled = Int((levels[index] * Double(segments)).rounded())
      let capSegment = min(
        segments - 1, max(0, Int((ladderCaps.value(index) * Double(segments)).rounded()) - 1))
      for segment in 0..<segments {
        let cell = CGRect(
          x: rect.minX + labelWidth + CGFloat(segment) * segmentPitch, y: y,
          width: segmentWidth, height: rowHeight)
        if segment < filled {
          segment >= segments - 3 ? over.addRect(cell) : lit.addRect(cell)
        } else {
          ghost.addRect(cell)
        }
        if segment == capSegment, ladderCaps.value(index) > 0.02, segment >= filled {
          capPath.addRect(cell)
        }
      }
    }
    ctx.fill(ghost, with: .color(palette.ghost.color))
    ctx.fill(ladderLabels, with: .color(palette.dim.color))
    ctx.glowing(palette.glow, radius: 2).fill(lit, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2).fill(over, with: .color(palette.amber.color))
    ctx.glowing(palette.glow, radius: 2).fill(
      capPath, with: .color(palette.glow.opacity(0.75).color))
  }

  private static func fit(_ text: String, width: CGFloat, dot: CGFloat) -> String {
    let characters = DotMatrix.normalized(text)
    let advance = DotMatrix.advance(dot: dot)
    let capacity = max(1, Int((width + dot) / advance))
    guard characters.count > capacity else { return String(characters) }
    return String(characters.prefix(max(1, capacity - 1))) + "."
  }
}
