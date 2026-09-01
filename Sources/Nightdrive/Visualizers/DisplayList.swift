import CoreGraphics
import Foundation
import SwiftUI

struct DisplayList: Sendable, Equatable {
  var ops: [Double] = []
  var texts: [String] = []

  var isEmpty: Bool { ops.isEmpty }

  enum Op: Double {
    case rect = 0
    case line = 1
    case path = 2
    case ellipse = 3
    case text = 4
    case dots = 5
    case segments = 6
  }

  static let batchLimit = 20_000

  func render(into ctx: inout GraphicsContext) {
    var i = 0

    func next() -> Double? {
      guard i < ops.count else { return nil }
      defer { i += 1 }
      return ops[i]
    }

    func take(_ count: Int) -> [Double]? {
      guard i + count <= ops.count else { return nil }
      defer { i += count }
      return Array(ops[i..<(i + count)])
    }

    while let raw = next() {
      guard let op = Op(rawValue: raw) else { return }
      switch op {
      case .rect:
        guard let a = take(9) else { return }
        let rect = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        guard rect.width.isFinite, rect.height.isFinite else { continue }
        layer(&ctx, ink(a, at: 4), glow: a[8])
          .fill(Path(rect), with: .color(ink(a, at: 4).color))

      case .line:
        guard let a = take(10) else { return }
        var path = Path()
        path.move(to: CGPoint(x: a[0], y: a[1]))
        path.addLine(to: CGPoint(x: a[2], y: a[3]))
        layer(&ctx, ink(a, at: 5), glow: a[9])
          .stroke(
            path, with: .color(ink(a, at: 5).color),
            style: StrokeStyle(lineWidth: width(a[4]), lineCap: .round, lineJoin: .round))

      case .path:
        guard let countValue = next(), let count = whole(countValue),
          count >= 2, count <= Self.batchLimit, let coords = take(count * 2),
          let a = take(8)
        else { return }
        var path = Path()
        for point in 0..<count {
          let cgPoint = CGPoint(x: coords[point * 2], y: coords[point * 2 + 1])
          guard cgPoint.x.isFinite, cgPoint.y.isFinite else { continue }
          point == 0 ? path.move(to: cgPoint) : path.addLine(to: cgPoint)
        }
        let closed = a[6] != 0
        if closed { path.closeSubpath() }
        let target = layer(&ctx, ink(a, at: 1), glow: a[5])
        if a[7] != 0 {
          target.fill(path, with: .color(ink(a, at: 1).color))
        } else {
          target.stroke(
            path, with: .color(ink(a, at: 1).color),
            style: StrokeStyle(lineWidth: width(a[0]), lineCap: .round, lineJoin: .round))
        }

      case .ellipse:
        guard let a = take(10) else { return }
        let rect = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        guard rect.width.isFinite, rect.height.isFinite else { continue }
        let path = Path(ellipseIn: rect)
        let target = layer(&ctx, ink(a, at: 4), glow: a[8])
        if a[9] != 0 {
          target.fill(path, with: .color(ink(a, at: 4).color))
        } else {
          target.stroke(path, with: .color(ink(a, at: 4).color), lineWidth: 1)
        }

      case .text:
        guard let a = take(10) else { return }
        guard let index = whole(a[9]), index >= 0, index < texts.count else { continue }
        let size = a[2].isFinite ? min(max(a[2], 4), 200) : 10
        let anchor: UnitPoint =
          switch a[8] {
          case 1: .center
          case 2: .trailing
          default: .leading
          }
        layer(&ctx, ink(a, at: 3), glow: a[7])
          .draw(
            Text(texts[index])
              .font(VFD.label(size))
              .foregroundStyle(ink(a, at: 3).color),
            at: CGPoint(x: a[0], y: a[1]), anchor: anchor)

      case .dots:
        guard let countValue = next(), let count = whole(countValue),
          count >= 1, count <= Self.batchLimit, let coords = take(count * 2),
          let a = take(7)
        else { return }
        let size = min(max(a[0].isFinite ? a[0] : 1, 0.1), 64)
        let round = a[6] != 0
        var dots = Path()
        for dot in 0..<count {
          let x = coords[dot * 2]
          let y = coords[dot * 2 + 1]
          guard x.isFinite, y.isFinite else { continue }
          let box = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
          round ? dots.addEllipse(in: box) : dots.addRect(box)
        }
        layer(&ctx, ink(a, at: 1), glow: a[5])
          .fill(dots, with: .color(ink(a, at: 1).color))

      case .segments:
        guard let countValue = next(), let count = whole(countValue),
          count >= 1, count <= Self.batchLimit, let coords = take(count * 4),
          let a = take(6)
        else { return }
        var strokes = Path()
        for segment in 0..<count {
          let from = CGPoint(x: coords[segment * 4], y: coords[segment * 4 + 1])
          let to = CGPoint(x: coords[segment * 4 + 2], y: coords[segment * 4 + 3])
          guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite else { continue }
          strokes.move(to: from)
          strokes.addLine(to: to)
        }
        layer(&ctx, ink(a, at: 1), glow: a[5])
          .stroke(
            strokes, with: .color(ink(a, at: 1).color),
            style: StrokeStyle(lineWidth: width(a[0]), lineCap: .round, lineJoin: .round))
      }
    }
  }

  private func whole(_ value: Double) -> Int? {
    guard value.isFinite, value.magnitude < 1e9 else { return nil }
    return Int(value)
  }

  private func ink(_ args: [Double], at offset: Int) -> VisualizerColor {
    VisualizerColor(
      red: clamp(args[offset]), green: clamp(args[offset + 1]),
      blue: clamp(args[offset + 2]), alpha: clamp(args[offset + 3]))
  }

  private func clamp(_ value: Double) -> Double {
    value.isFinite ? min(max(value, 0), 1) : 0
  }

  private func width(_ value: Double) -> CGFloat {
    value.isFinite ? min(max(value, 0.1), 40) : 1
  }

  private func layer(
    _ ctx: inout GraphicsContext, _ color: VisualizerColor, glow: Double
  ) -> GraphicsContext {
    guard glow.isFinite, glow > 0 else { return ctx }
    return ctx.glowing(color, radius: min(glow, 12))
  }
}
