import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class VUVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "vu", name: "VU", wantsContinuousRedraw: true)

  private var left = NeedleBallistics()
  private var right = NeedleBallistics()
  private var leftPeakUntil: TimeInterval = -1
  private var rightPeakUntil: TimeInterval = -1
  private var balance: Double = 0
  private var balanceTime: TimeInterval = -1

  private static let marks: [(db: Int?, at: Double, major: Bool)] = [
    (-20, 0.00, true), (nil, 0.14, false), (-10, 0.28, true),
    (nil, 0.39, false), (-5, 0.47, true), (nil, 0.56, false),
    (nil, 0.63, false), (0, 0.71, true), (nil, 0.79, false),
    (nil, 0.90, false), (3, 1.00, true),
  ]

  private static let calibration: [(at: Double, db: Double)] =
    marks.compactMap { mark in mark.db.map { (mark.at, Double($0)) } }

  private static let redZone = 0.71

  func reset() {
    left.reset()
    right.reset()
    leftPeakUntil = -1
    rightPeakUntil = -1
    balance = 0
    balanceTime = -1
  }

  // MARK: - Scale reading

  static func decibels(at value: Double) -> Double {
    guard let last = calibration.last else { return 0 }
    let clamped = min(max(value, 0), 1)
    guard let index = calibration.firstIndex(where: { $0.at >= clamped }), index > 0 else {
      return clamped >= last.at ? last.db : calibration[0].db
    }
    let low = calibration[index - 1]
    let high = calibration[index]
    let span = high.at - low.at
    guard span > 0 else { return low.db }
    return low.db + (high.db - low.db) * (clamped - low.at) / span
  }

  static func reading(_ value: Double) -> String {
    let db = Int(decibels(at: value).rounded())
    return db > 0 ? "+\(db)" : "\(db)"
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 120, size.height > 24 else { return }

    var faceWidth = min(size.height * 5.6, size.width * 0.36)
    if size.width - 2 * faceWidth < 96 { faceWidth = max(52, (size.width - 96) / 2) }
    guard faceWidth > 36 else { return }

    let bass = frame.energy(from: 0, to: 0.34)
    let treble = frame.energy(from: 0.34, to: 1)
    var leftTarget = min(1.05, frame.level * 0.7 + bass * 0.66)
    var rightTarget = min(1.05, frame.level * 0.7 + treble * 0.7)
    if let boot = frame.boot {
      leftTarget = boot < 0.55 ? 1.1 : 0
      rightTarget = leftTarget
    } else if !frame.isPlaying {
      leftTarget = 0
      rightTarget = 0
    }

    let leftValue = left.step(toward: leftTarget, at: frame.time)
    let rightValue = right.step(toward: rightTarget, at: frame.time)
    if leftValue > Self.redZone + 0.2 { leftPeakUntil = frame.time + 0.5 }
    if rightValue > Self.redZone + 0.2 { rightPeakUntil = frame.time + 0.5 }

    let step = FrameClock.clampedDelta(now: frame.time, last: balanceTime)
    balanceTime = frame.time
    let sum = max(0, leftValue) + max(0, rightValue)
    let lean = sum > 0.02 ? min(1, max(-1, (rightValue - leftValue) / sum)) : 0
    balance += (lean - balance) * min(1, step * 3)

    meter(
      in: CGRect(x: 0, y: 0, width: faceWidth, height: size.height),
      value: leftValue, channel: "L", peak: frame.time < leftPeakUntil,
      frame: frame, into: &ctx)
    meter(
      in: CGRect(x: size.width - faceWidth, y: 0, width: faceWidth, height: size.height),
      value: rightValue, channel: "R", peak: frame.time < rightPeakUntil,
      frame: frame, into: &ctx)
    bridge(
      in: CGRect(x: faceWidth, y: 0, width: size.width - faceWidth * 2, height: size.height),
      left: leftValue, right: rightValue, frame: frame, into: &ctx)
  }

  // MARK: - Meter face

  private func meter(
    in rect: CGRect, value: Double, channel: String, peak: Bool,
    frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    let palette = frame.palette
    let inset = rect.insetBy(dx: 5, dy: 3)
    let numeralHeight = DotMatrix.height(dot: 1)

    let apex = inset.minY + numeralHeight + 2
    let halfWidth = inset.width * 0.42
    let drop = max(6, inset.maxY - 6 - apex)
    var radius = (halfWidth * halfWidth + drop * drop) / (2 * drop)
    var sweep = asin(min(1, halfWidth / radius))
    if sweep > 0.9 {
      sweep = 0.9
      radius = halfWidth / sin(sweep)
    }
    let pivot = CGPoint(x: inset.midX, y: apex + radius)

    func point(_ fraction: Double, radius r: CGFloat) -> CGPoint {
      let angle = (fraction * 2 - 1) * sweep
      return CGPoint(x: pivot.x + r * sin(angle), y: pivot.y - r * cos(angle))
    }

    func arc(from start: Double, to end: Double, radius r: CGFloat) -> Path {
      var path = Path()
      let steps = 40
      for step in 0...steps {
        let point = point(start + (end - start) * Double(step) / Double(steps), radius: r)
        step == 0 ? path.move(to: point) : path.addLine(to: point)
      }
      return path
    }

    let window = Path(roundedRect: inset.insetBy(dx: -1, dy: -1), cornerRadius: 3)
    ctx.fill(window, with: .color(palette.ghost.opacity(0.8).color))
    ctx.stroke(window, with: .color(palette.ghost.color), lineWidth: 1)

    ctx.glowing(palette.glow, radius: 1.5).stroke(
      arc(from: 0, to: 1, radius: radius),
      with: .color(palette.glow.opacity(0.5).color), lineWidth: 1.4)
    ctx.glowing(palette.amber, radius: 2).stroke(
      arc(from: Self.redZone, to: 1, radius: radius + 2.5),
      with: .color(palette.amber.opacity(0.9).color), lineWidth: 1.8)

    let channelText = String(localized: "VU \(channel)")
    let peakText = inset.width > 92 ? String(localized: "PEAK") : String(localized: "PK")
    let furnitureY = inset.minY
    let channelBox = CGRect(
      x: inset.minX + 3, y: furnitureY,
      width: DotMatrix.width(of: channelText, dot: 1), height: numeralHeight)
    let peakWidth = DotMatrix.width(of: peakText, dot: 1)
    let peakBox = CGRect(
      x: inset.maxX - peakWidth - 8, y: furnitureY,
      width: peakWidth + 8, height: numeralHeight)

    var ticks = Path()
    var hotTicks = Path()
    var numerals = Path()
    let roomForNumerals = inset.width > 92
    for mark in Self.marks {
      let length: CGFloat = mark.major ? 5.5 : 3
      var tick = Path()
      tick.move(to: point(mark.at, radius: radius - 0.5))
      tick.addLine(to: point(mark.at, radius: radius - length))
      if mark.at >= Self.redZone {
        hotTicks.addPath(tick)
      } else {
        ticks.addPath(tick)
      }
      guard roomForNumerals, let db = mark.db else { continue }
      let label = db > 0 ? "+\(db)" : "\(db)"
      let anchor = point(mark.at, radius: radius + 7)
      let labelWidth = DotMatrix.width(of: label, dot: 1)
      let x = min(
        max(anchor.x - labelWidth / 2, inset.minX + 2), inset.maxX - labelWidth - 2)
      let y = min(
        max(anchor.y - numeralHeight / 2, inset.minY + 1), inset.maxY - numeralHeight - 1)
      let box = CGRect(x: x - 2, y: y, width: labelWidth + 4, height: numeralHeight)
      guard !box.intersects(channelBox), !box.intersects(peakBox) else { continue }
      DotMatrix.draw(label, at: CGPoint(x: x, y: y), dot: 1, into: &numerals)
    }
    ctx.stroke(ticks, with: .color(palette.dim.color), lineWidth: 1)
    ctx.stroke(hotTicks, with: .color(palette.amber.opacity(0.75).color), lineWidth: 1)
    ctx.fill(numerals, with: .color(palette.dim.opacity(0.95).color))

    let clamped = min(max(value, 0), 1.08)
    let tip = point(clamped, radius: radius + 1.5)
    let root = point(clamped, radius: radius - inset.height * 1.25)
    let across = CGVector(dx: tip.y - root.y, dy: root.x - tip.x)
    let length = max(1, sqrt(across.dx * across.dx + across.dy * across.dy))
    let unit = CGVector(dx: across.dx / length, dy: across.dy / length)
    var needle = Path()
    needle.move(to: CGPoint(x: tip.x + unit.dx * 0.55, y: tip.y + unit.dy * 0.55))
    needle.addLine(to: CGPoint(x: root.x + unit.dx * 3.4, y: root.y + unit.dy * 3.4))
    needle.addLine(to: CGPoint(x: root.x - unit.dx * 3.4, y: root.y - unit.dy * 3.4))
    needle.addLine(to: CGPoint(x: tip.x - unit.dx * 0.55, y: tip.y - unit.dy * 0.55))
    needle.closeSubpath()
    let ink = clamped > Self.redZone ? palette.amber : palette.glow
    var needleContext = ctx
    needleContext.clip(to: Path(roundedRect: inset, cornerRadius: 2))
    needleContext.glowing(ink, radius: 3.5).fill(needle, with: .color(ink.color))
    needleContext.glowing(ink, radius: 4).fill(
      Path(ellipseIn: CGRect(x: tip.x - 1.6, y: tip.y - 1.6, width: 3.2, height: 3.2)),
      with: .color(ink.color))

    var furniture = Path()
    DotMatrix.draw(
      channelText, at: CGPoint(x: channelBox.minX, y: furnitureY), dot: 1, into: &furniture)
    ctx.fill(furniture, with: .color(palette.dim.opacity(0.85).color))

    var lamp = Path()
    DotMatrix.draw(
      peakText, at: CGPoint(x: peakBox.minX, y: furnitureY), dot: 1, into: &lamp)
    lamp.addRect(CGRect(x: inset.maxX - 6, y: furnitureY, width: 4, height: 5))
    if peak {
      ctx.glowing(palette.amber, radius: 2.5).fill(lamp, with: .color(palette.amber.color))
    } else {
      ctx.fill(lamp, with: .color(palette.dim.opacity(0.3).color))
    }
  }

  // MARK: - bridge between the meters

  private func bridge(
    in rect: CGRect, left: Double, right: Double, frame: VisualizerFrame,
    into ctx: inout GraphicsContext
  ) {
    let palette = frame.palette
    let width = min(rect.width - 12, 240)
    guard width > 54 else { return }
    let inset = CGRect(
      x: rect.midX - width / 2, y: rect.minY + 3, width: width, height: rect.height - 6)
    guard inset.height >= 12 else { return }

    let lineHeight = DotMatrix.height(dot: 1)
    let gap: CGFloat = 3
    let gutter: CGFloat = 8

    func fitted(_ texts: (String, String)) -> CGFloat {
      let widest = max(
        DotMatrix.width(of: texts.0, dot: 1), DotMatrix.width(of: texts.1, dot: 1))
      guard widest > 0 else { return 0 }
      return min((inset.width - gutter * 2) / (2 * widest), max(1, inset.height / 22), 1.7)
    }
    var digits = ("L " + Self.reading(left), "R " + Self.reading(right))
    var digitDot = fitted(digits)
    if digitDot < 1.1 {
      digits = (Self.reading(left), Self.reading(right))
      digitDot = fitted(digits)
    }
    guard digitDot >= 0.85 else { return }
    let digitHeight = DotMatrix.height(dot: digitDot)

    var rows = 3
    func stackHeight(_ rows: Int) -> CGFloat {
      let ladder = rows >= 2 ? gap + lineHeight : 0
      let header = rows >= 3 ? lineHeight + gap : 0
      return header + digitHeight + ladder
    }
    while rows > 1, stackHeight(rows) > inset.height { rows -= 1 }

    var etched = Path()
    var dim = Path()
    var bright = Path()
    var marker = Path()
    var y = inset.midY - stackHeight(rows) / 2

    if rows >= 3 {
      let title = "STEREO"
      let titleWidth = DotMatrix.width(of: title, dot: 1)
      let origin = CGPoint(x: inset.midX - titleWidth / 2, y: y)
      if frame.isPlaying {
        DotMatrix.draw(title, at: origin, dot: 1, into: &dim)
      } else {
        DotMatrix.draw(title, at: origin, dot: 1, into: &etched)
      }
      let ruleY = y + lineHeight / 2
      let ruleEnd = inset.midX - titleWidth / 2 - 5
      let ruleStart = inset.midX + titleWidth / 2 + 5
      etched.addRect(
        CGRect(x: inset.minX, y: ruleY, width: max(0, ruleEnd - inset.minX), height: 1))
      etched.addRect(
        CGRect(x: ruleStart, y: ruleY, width: max(0, inset.maxX - ruleStart), height: 1))
      y += lineHeight + gap
    }

    var hot = Path()
    let leftOrigin = CGPoint(
      x: inset.midX - gutter - DotMatrix.width(of: digits.0, dot: digitDot), y: y)
    let rightOrigin = CGPoint(x: inset.midX + gutter, y: y)
    if left > Self.redZone {
      DotMatrix.draw(digits.0, at: leftOrigin, dot: digitDot, into: &hot)
    } else {
      DotMatrix.draw(digits.0, at: leftOrigin, dot: digitDot, into: &bright)
    }
    if right > Self.redZone {
      DotMatrix.draw(digits.1, at: rightOrigin, dot: digitDot, into: &hot)
    } else {
      DotMatrix.draw(digits.1, at: rightOrigin, dot: digitDot, into: &bright)
    }
    etched.addRect(CGRect(x: inset.midX - 0.5, y: y, width: 1, height: digitHeight))
    y += digitHeight + gap

    if rows >= 2 {
      let endWidth = DotMatrix.width(of: "L", dot: 1)
      let midY = y + lineHeight / 2
      let trackStart = inset.minX + endWidth + 4
      let trackEnd = inset.maxX - endWidth - 4
      if trackEnd - trackStart > 24 {
        DotMatrix.draw("L", at: CGPoint(x: inset.minX, y: y), dot: 1, into: &dim)
        DotMatrix.draw(
          "R", at: CGPoint(x: inset.maxX - endWidth, y: y), dot: 1, into: &dim)
        etched.addRect(
          CGRect(x: trackStart, y: midY - 0.5, width: trackEnd - trackStart, height: 1))
        for detent in 0...4 {
          let x = trackStart + (trackEnd - trackStart) * CGFloat(detent) / 4
          let height: CGFloat = detent == 2 ? 5 : 3
          etched.addRect(CGRect(x: x - 0.5, y: midY - height / 2, width: 1, height: height))
        }
        let markerX = trackStart + (trackEnd - trackStart) * CGFloat(balance + 1) / 2
        marker.move(to: CGPoint(x: markerX, y: midY - 3.2))
        marker.addLine(to: CGPoint(x: markerX + 2.6, y: midY))
        marker.addLine(to: CGPoint(x: markerX, y: midY + 3.2))
        marker.addLine(to: CGPoint(x: markerX - 2.6, y: midY))
        marker.closeSubpath()
      }
    }

    ctx.fill(etched, with: .color(palette.dim.opacity(0.4).color))
    ctx.fill(dim, with: .color(palette.dim.color))
    ctx.glowing(palette.glow, radius: 2).fill(marker, with: .color(palette.glow.color))
    ctx.glowing(palette.glow, radius: 1.5).fill(bright, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 2).fill(hot, with: .color(palette.amber.color))
  }
}
