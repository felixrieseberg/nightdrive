import Foundation

final class TunnelVisualizer: RasterVisualizer {
  private var depth: [Double] = []
  private var angle: [Double] = []
  private var shade: [Double] = []
  private var detail: [Double] = []

  private var travel = 0.0
  private var roll = 0.0
  private var rings = [Double](reservingCapacity: 4)

  private static let ringDensity = 5.0
  private static let staveCount = 16.0

  init() {
    super.init(
      id: "tunnel", rows: 34, levels: 7,
      ramp: { .heat($0, ghostAt: 0.14, dimAt: 0.45, glowAt: 0.86) })
  }

  override func resetRaster() {
    travel = 0
    roll = 0
    rings.removeAll(keepingCapacity: true)
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    if resized || depth.count != raster.width * raster.height { buildTables() }

    let speed = frame.isPlaying ? 0.55 + energy.level * 2.6 + energy.beat * 2.2 : 0.18
    travel += dt * speed
    roll += dt * (0.035 + energy.mid * 0.22) * (frame.isPlaying ? 1 : 0.3)

    if didBeat {
      rings.append(travel + 3.2)
      if rings.count > 4 { rings.removeFirst(rings.count - 4) }
    }
    rings.removeAll { $0 - travel < -0.2 }

    let width = raster.width
    let height = raster.height
    let stave = Self.staveCount * (1 + energy.treble * 0.6)

    for y in 0..<height {
      let row = y * width
      for x in 0..<width {
        let index = row + x
        let z = depth[index] + travel
        let a = angle[index] + roll
        let ring = z * Self.ringDensity
        let rib = a * stave + ring.rounded(.down) * 0.5
        let texture = VFDTrig.wave(ring) * (0.46 + 0.54 * VFDTrig.wave(rib))

        let crisp = detail[index]
        var value = shade[index] * (0.10 + 0.90 * (texture * crisp + 0.30 * (1 - crisp)))
        for marker in rings {
          let distance = abs(z - marker)
          if distance < 0.4 { value += (1 - distance / 0.4) * 0.85 }
        }
        raster.set(x, y, UInt8(min(255, max(0, value * 255))))
      }
    }
  }

  private func buildTables() {
    let width = raster.width
    let height = raster.height
    guard width > 0, height > 0 else { return }
    let count = width * height
    depth = [Double](repeating: 0, count: count)
    angle = [Double](repeating: 0, count: count)
    shade = [Double](repeating: 0, count: count)
    detail = [Double](repeating: 0, count: count)

    let cx = Double(width - 1) / 2
    let cy = Double(height - 1) / 2
    let squash = max(1.4, Double(width) / Double(height) / 4.2)
    let throat = Double(width) * 0.17
    let nominalStave = Self.staveCount * 1.3

    for y in 0..<height {
      let dy = (Double(y) - cy) * squash
      for x in 0..<width {
        let dx = Double(x) - cx
        let r = max(1.2, (dx * dx + dy * dy).squareRoot())
        let index = y * width + x
        let z = throat / r
        depth[index] = z
        angle[index] = atan2(dy, dx) / (2 * .pi)
        shade[index] = min(0.62, pow(r / (Double(width) * 0.34), 0.8)) + 0.14
        let radial = Self.ringDensity * z / r
        let around = nominalStave / (2 * .pi * r)
        let ratio = max(radial, around) / 0.20
        detail[index] = min(1, max(0, 1 - ratio * ratio))
      }
    }
  }
}
