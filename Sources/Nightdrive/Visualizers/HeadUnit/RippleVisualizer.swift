import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class RippleVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "ripple", name: "RIPPLE", wantsContinuousRedraw: true)

  private struct Ring {
    var origin: Double
    var born: TimeInterval
  }

  private var beat = BeatDetector()
  private var rings = [Ring](reservingCapacity: 4)
  private var swell = 0.0
  private var lastTime: TimeInterval = -1

  func reset() {
    beat.reset()
    rings.removeAll(keepingCapacity: true)
    swell = 0
    lastTime = -1
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    guard size.width > 40, size.height > 16 else { return }
    let palette = frame.palette

    let time = frame.time.isFinite ? frame.time : max(lastTime, 0)
    let step = FrameClock.clampedDelta(now: time, last: lastTime)
    lastTime = time

    if beat.update(frame, at: time) {
      let side = beat.count.isMultiple(of: 2) ? 0.3 : 0.7
      let jitter = (Double(beat.count % 7) / 7 - 0.5) * 0.2
      rings.append(Ring(origin: side + jitter, born: time))
      if rings.count > 4 { rings.removeFirst(rings.count - 4) }
    }
    rings.removeAll { time - $0.born > 2.2 }

    let bass = frame.energy(from: 0, to: 0.25)
    let mid = frame.energy(from: 0.25, to: 0.6)
    let air = frame.energy(from: 0.6, to: 1)
    let target = frame.isPlaying || frame.boot != nil ? bass : 0.04
    swell += (target - swell) * min(1, step * (target > swell ? 9 : 2.4))

    let pitch: CGFloat = max(3, min(5, size.width / 190))
    let rows = max(4, Int(size.height * 0.72 / pitch))
    let baseline = CGFloat(rows) * pitch
    let mirrorRows = max(1, Int((size.height - baseline) / pitch))
    let columns = max(8, Int(size.width / pitch))
    let rest = Double(rows) * 0.34
    let travel = Double(rows) * 0.6

    func surface(_ fraction: Double) -> Double {
      var wave =
        sin(fraction * 7.5 - time * 2.1) * (0.30 + swell * 0.70)
        + sin(fraction * 15.5 + time * 1.35) * (0.12 + mid * 0.42)
        + sin(fraction * 31 - time * 3.4) * (0.05 + air * 0.20)
      wave /= 1.7
      for ring in rings {
        let age = max(0, time - ring.born)
        let distance = abs(fraction - ring.origin)
        let front = age * 0.45
        let envelope = exp(-pow((distance - front) * 8, 2)) * exp(-age * 1.6)
        wave += cos((distance - front) * 22) * envelope * 0.9
      }
      if let boot = frame.boot {
        wave += max(0, 1 - abs(fraction - (boot * 1.4 - 0.2)) * 5) * 1.4
      }
      return rest + swell * Double(rows) * 0.2 + wave * travel
    }

    var crest = Path()
    var hotCrest = Path()
    var body = Path()
    var deep = Path()
    var mirror = Path()
    var ghost = Path()
    let dot = max(1.6, pitch - 1.2)

    for column in 0..<columns {
      let x = CGFloat(column) * pitch
      let rawHeight = surface(Double(column) / Double(max(1, columns - 1)))
      let height = rawHeight.isFinite ? rawHeight : 0
      let cells = max(0, min(rows, Int(height.rounded())))

      for row in 0..<rows {
        let y = baseline - CGFloat(row + 1) * pitch
        let cell = CGRect(x: x, y: y, width: dot, height: dot)
        if row == cells - 1 {
          row >= rows - 3 ? hotCrest.addRect(cell) : crest.addRect(cell)
        } else if row < cells {
          row < 2 ? deep.addRect(cell) : body.addRect(cell)
        } else {
          ghost.addRect(cell)
        }
      }

      let reflected = min(mirrorRows, Int((height * 0.5).rounded()))
      for row in 0..<mirrorRows {
        let y = baseline + CGFloat(row) * pitch + 2
        let cell = CGRect(x: x, y: y, width: dot, height: dot)
        if row < reflected {
          mirror.addRect(cell)
        } else {
          ghost.addRect(cell)
        }
      }
    }

    ctx.fill(ghost, with: .color(palette.ghost.color))
    ctx.fill(mirror, with: .color(palette.glow.opacity(0.38).color))
    ctx.glowing(palette.glow, radius: 1.2)
      .fill(body, with: .color(palette.glow.opacity(0.62).color))
    ctx.glowing(palette.glow, radius: 2).fill(deep, with: .color(palette.glow.color))
    ctx.glowing(palette.glow, radius: 3.5).fill(crest, with: .color(palette.glow.color))
    ctx.glowing(palette.amber, radius: 3.5).fill(hotCrest, with: .color(palette.amber.color))

    let lit = 0.3 + beat.pulse * 0.7
    ctx.glowing(palette.glow, radius: 2).fill(
      Path(CGRect(x: 0, y: baseline + 0.5, width: size.width, height: 1)),
      with: .color(palette.glow.opacity(lit).color))
  }
}
