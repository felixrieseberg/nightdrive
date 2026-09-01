import CoreGraphics
import Foundation

final class RotozoomVisualizer: RasterVisualizer {
  private var spin = 0.0
  private var drift = CGPoint.zero
  private var zoom = 1.0
  private var zoomVelocity = 0.0
  private var flip = false

  private static let tile = 64
  private static let texture: [UInt8] = makeTexture()

  init() {
    super.init(id: "rotozoom", rows: 34, levels: 6, bootEffect: .wipe)
  }

  override func resetRaster() {
    spin = 0
    drift = .zero
    zoom = 1
    zoomVelocity = 0
    flip = false
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    if didBeat {
      zoomVelocity += 5.5
      if energy.beatCount % 4 == 0 { flip.toggle() }
    }
    let rest = 1.5 - energy.bass * 0.55
    zoomVelocity += (rest - zoom) * 26 * dt - zoomVelocity * 6.5 * dt
    zoom = min(6, max(0.35, zoom + zoomVelocity * dt))

    spin += dt * (flip ? -1 : 1) * (0.05 + energy.mid * 0.28) * (frame.isPlaying ? 1 : 0.25)
    drift.x += CGFloat(dt * 9 * (0.4 + energy.level))
    drift.y += CGFloat(dt * 3.5 * VFDTrig.sin(energy.flow * 0.13))

    let width = raster.width
    let height = raster.height
    let scale = zoom * Double(Self.tile) / (Double(height) * 3.0)
    let cosine = VFDTrig.cos(spin) * scale
    let sine = VFDTrig.sin(spin) * scale
    let cx = Double(width - 1) / 2
    let cy = Double(height - 1) / 2

    var rowU = -cx * cosine + cy * sine + Double(drift.x)
    var rowV = -cx * sine - cy * cosine + Double(drift.y)
    let mask = Self.tile - 1

    for y in 0..<height {
      var u = rowU
      var v = rowV
      for x in 0..<width {
        let tu = Int(u.rounded(.down)) & mask
        let tv = Int(v.rounded(.down)) & mask
        raster.set(x, y, Self.texture[tv * Self.tile + tu])
        u += cosine
        v += sine
      }
      rowU -= sine
      rowV += cosine
    }

    vignette()
  }

  private func vignette() {
    let width = raster.width
    let height = raster.height
    let cx = Double(width - 1) / 2
    let falloff = max(1, cx * 0.92)
    for x in 0..<width {
      let distance = abs(Double(x) - cx) / falloff
      guard distance > 0.55 else { continue }
      let keep = max(0.0, 1 - (distance - 0.55) / 0.45)
      for y in 0..<height {
        raster.set(x, y, UInt8(Double(raster.value(x, y)) * keep))
      }
    }
  }

  private static func makeTexture() -> [UInt8] {
    var texture = [UInt8](repeating: 0, count: tile * tile)
    let cell = 32.0
    for v in 0..<tile {
      for u in 0..<tile {
        let fu = Double(u)
        let fv = Double(v)
        let cellU = (fu / cell).rounded(.down)
        let cellV = (fv / cell).rounded(.down)
        let rivet = (Int(cellU) + Int(cellV)) & 1 == 0

        let lu = (fu - (cellU * cell + cell / 2)) / (cell / 2)
        let lv = (fv - (cellV * cell + cell / 2)) / (cell / 2)

        var value: Double
        if rivet {
          let radius = (lu * lu + lv * lv).squareRoot()
          let ring = max(0, 1 - abs(radius - 0.60) / 0.18)
          let core = max(0, 1 - radius / 0.20)
          value = 0.07 + ring * 0.58 + core * 0.45
        } else {
          let box = max(abs(lu), abs(lv))
          let body = max(0, 1 - pow(min(1, box / 0.84), 8))
          let cross = max(0, 1 - min(abs(lu), abs(lv)) / 0.14)
          value = 0.05 + body * 0.50 + cross * body * 0.46
        }

        let gu = fu.truncatingRemainder(dividingBy: cell)
        let gv = fv.truncatingRemainder(dividingBy: cell)
        let grid = max(max(0, 1 - gu / 1.6), max(0, 1 - gv / 1.6))
        value = max(value, grid * 0.92)
        texture[v * tile + u] = UInt8(min(255, max(0, value * 255)))
      }
    }
    return texture
  }
}
