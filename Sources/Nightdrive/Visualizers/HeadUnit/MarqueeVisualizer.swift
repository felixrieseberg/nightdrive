import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class MarqueeVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "marquee", name: "MARQUEE", wantsContinuousRedraw: true)

  private var beat = BeatDetector()
  var scroll: CGFloat = 0
  private var lastTime: TimeInterval = -1

  private static let speed: CGFloat = 46

  func reset() {
    beat.reset()
    scroll = 0
    lastTime = -1
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 60, size.height > 22 else { return }
    let palette = frame.palette

    let step = FrameClock.clampedDelta(now: frame.time, last: lastTime)
    lastTime = frame.time
    beat.update(frame, at: frame.time)

    let statusHeight = DotMatrix.height(dot: 1) + 3
    let underlineHeight: CGFloat = 4
    let band = CGRect(
      x: 0, y: statusHeight, width: size.width,
      height: size.height - statusHeight - underlineHeight - 3)
    guard band.height > 8 else { return }

    status(
      in: CGRect(x: 0, y: 0, width: size.width, height: statusHeight), frame: frame,
      into: &ctx)

    let dot = max(1.5, (band.height / CGFloat(DotMatrix.rows) * 2).rounded(.down) / 2)
    let textY = (band.midY - DotMatrix.height(dot: dot) / 2).rounded()

    var ghost = Path()
    DotMatrix.ghostGrid(
      in: CGRect(x: 0, y: textY, width: size.width, height: DotMatrix.height(dot: dot)),
      dot: dot, into: &ghost)
    ctx.fill(ghost, with: .color(palette.ghost.color))

    let message = Self.message(frame)
    let width = DotMatrix.width(of: message, dot: dot)
    var text = Path()

    if let boot = frame.boot {
      var all = Path()
      DotMatrix.ghostGrid(
        in: CGRect(
          x: 0, y: textY, width: size.width * min(1, boot * 1.6),
          height: DotMatrix.height(dot: dot)),
        dot: dot, into: &all)
      ctx.glowing(palette.glow, radius: 2).fill(all, with: .color(palette.glow.color))
    } else {
      let gap = DotMatrix.advance(dot: dot) * 5
      let period = width + gap
      if !scroll.isFinite { scroll = 0 }
      scroll = (scroll + Self.speed * CGFloat(step)).truncatingRemainder(dividingBy: period)
      let displayScroll = Self.scrollingGridOffset(scroll, pitch: dot)
      let clip = CGRect(x: 0, y: band.minY, width: size.width, height: band.height)
      for textX in Self.repeatingGridOrigins(
        panelWidth: size.width, period: period, offset: displayScroll)
      {
        DotMatrix.draw(
          message, at: CGPoint(x: textX, y: textY), dot: dot, into: &text, clip: clip)
      }
    }
    ctx.glowing(palette.glow, radius: 2.5).fill(text, with: .color(palette.glow.color))

    underline(
      in: CGRect(
        x: 0, y: size.height - underlineHeight, width: size.width, height: underlineHeight),
      frame: frame, into: &ctx)
  }

  static func scrollingGridOffset(_ offset: CGFloat, pitch: CGFloat) -> CGFloat {
    guard pitch > 0, pitch.isFinite, offset.isFinite else { return 0 }
    return (offset / pitch).rounded(.down) * pitch
  }

  static func repeatingGridOrigins(
    panelWidth: CGFloat, period: CGFloat, offset: CGFloat
  ) -> [CGFloat] {
    guard panelWidth > 0, panelWidth.isFinite, period > 0, period.isFinite, offset.isFinite else {
      return []
    }
    var origin = -offset.truncatingRemainder(dividingBy: period)
    if origin > 0 { origin -= period }

    var origins: [CGFloat] = []
    while origin < panelWidth {
      origins.append(origin)
      origin += period
    }
    return origins
  }

  private static func message(_ frame: VisualizerFrame) -> String {
    let parts = [frame.artist, frame.title, frame.album].filter { !$0.isEmpty }
    guard !parts.isEmpty else {
      return String(localized: "NO DISC  -  NIGHTDRIVE  -  READY")
    }
    return parts.joined(separator: "  -  ")
  }

  private func status(
    in rect: CGRect, frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    let palette = frame.palette
    var lit = Path()
    var unlit = Path()
    var litText = Path()
    var unlitText = Path()

    let flags: [(String, Bool)] = [
      ("MP3", true),
      ("ST", frame.isPlaying),
      ("RPT", false),
      ("RDM", false),
      ("LOUD", frame.energy(from: 0, to: 0.2) > 0.45),
      ("EQ", frame.isPlaying),
    ]

    var x: CGFloat = 1
    for (label, on) in flags {
      let width = DotMatrix.width(of: label, dot: 1) + 4
      guard x + width < rect.maxX - 74 else { break }
      let box = Path(
        roundedRect: CGRect(x: x, y: rect.minY, width: width, height: 9),
        cornerRadius: 1.5)
      if on {
        DotMatrix.draw(label, at: CGPoint(x: x + 2, y: rect.minY + 1), dot: 1, into: &litText)
        lit.addPath(box)
      } else {
        DotMatrix.draw(label, at: CGPoint(x: x + 2, y: rect.minY + 1), dot: 1, into: &unlitText)
        unlit.addPath(box)
      }
      x += width + 3
    }

    ctx.fill(unlit, with: .color(palette.ghost.color))
    ctx.fill(unlitText, with: .color(palette.dim.opacity(0.4).color))
    ctx.glowing(palette.glow, radius: 1.5).stroke(
      lit, with: .color(palette.glow.opacity(0.55).color), lineWidth: 1)
    ctx.glowing(palette.glow, radius: 1.5).fill(litText, with: .color(palette.glow.color))

    let times =
      "\(VisualizerFrame.clock(frame.elapsed))  -"
      + VisualizerFrame.clock(max(0, frame.duration - frame.elapsed))
    var digits = Path()
    DotMatrix.draw(
      times,
      at: CGPoint(x: rect.maxX - DotMatrix.width(of: times, dot: 1) - 2, y: rect.minY + 1),
      dot: 1, into: &digits)
    ctx.fill(digits, with: .color(palette.dim.color))
  }

  private func underline(
    in rect: CGRect, frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    let palette = frame.palette
    let cells = max(8, Int(rect.width / 9))
    let gap: CGFloat = 2
    let cellWidth = (rect.width - CGFloat(cells - 1) * gap) / CGFloat(cells)
    guard cellWidth > 0 else { return }

    let energy =
      frame.boot.map { 1 - abs($0 - 0.5) * 2 }
      ?? min(1, frame.energy(from: 0, to: 0.28) * 0.75 + beat.pulse * 0.45)
    let half = Double(cells) / 2
    let reach = energy * half

    var lit = Path()
    var hot = Path()
    var ghost = Path()
    let fraction = frame.duration > 0 ? min(1, max(0, frame.elapsed / frame.duration)) : 0
    for cell in 0..<cells {
      let distance = abs(Double(cell) + 0.5 - half)
      let rect = CGRect(
        x: rect.minX + CGFloat(cell) * (cellWidth + gap), y: rect.minY,
        width: cellWidth, height: rect.height - 1)
      if distance < reach {
        distance > half * 0.78 ? hot.addRect(rect) : lit.addRect(rect)
      } else {
        ghost.addRect(rect)
      }
    }
    ctx.fill(ghost, with: .color(palette.ghost.color))
    ctx.glowing(palette.glow, radius: 2).fill(lit, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2).fill(hot, with: .color(palette.amber.color))
    ctx.fill(
      Path(CGRect(x: 0, y: rect.maxY - 1, width: rect.width * fraction, height: 1)),
      with: .color(palette.dim.color))
  }
}
