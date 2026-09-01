import Foundation

final class MetaballVisualizer: RasterVisualizer {
  private static let ballCount = 5
  private var charge = [Double](repeating: 0.3, count: MetaballVisualizer.ballCount)
  private var x = [Double](repeating: 0, count: MetaballVisualizer.ballCount)
  private var y = [Double](repeating: 0, count: MetaballVisualizer.ballCount)
  private var strength = [Double](repeating: 0, count: MetaballVisualizer.ballCount)
  private var softness = [Double](repeating: 0, count: MetaballVisualizer.ballCount)

  init() {
    super.init(
      id: "metaballs", rows: 20, levels: 5,
      ramp: { .heat($0, ghostAt: 0.24, dimAt: 0.52, glowAt: 0.82) })
  }

  override func resetRaster() {
    charge = [Double](repeating: 0.3, count: Self.ballCount)
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    let width = raster.width
    let height = raster.height
    let time = energy.flow
    let cy = Double(height - 1) / 2
    let span = Double(width - 1)

    for index in 0..<Self.ballCount {
      let phase = Double(index) / Double(Self.ballCount)
      let target = energy.band(frame, index, of: Self.ballCount)
      charge[index] += (target - charge[index]) * (target > charge[index] ? 0.45 : 0.11)
      x[index] = span * (0.5 + 0.44 * VFDTrig.sin(time * (0.07 + phase * 0.05) + phase))
      y[index] = cy + cy * 0.85 * VFDTrig.sin(time * (0.11 + phase * 0.09) + phase * 0.37)
      let radius = (2.0 + charge[index] * 3.2 + energy.beat * 0.7) * Double(height) * 0.11
      strength[index] = radius * radius
      softness[index] = strength[index] * 0.78
    }

    let stretch = 0.46
    for row in 0..<height {
      let fy = Double(row)
      for column in 0..<width {
        let fx = Double(column)
        var field = 0.0
        for index in 0..<Self.ballCount {
          let dx = (fx - x[index]) * stretch
          let dy = fy - y[index]
          field += strength[index] / (dx * dx + dy * dy + softness[index])
        }
        let f = field * 0.62
        let body = min(1, f)
        let rings = VFDTrig.wave(f * 0.62 - 0.25)
        let value = min(1, max(0, body * (0.58 + 0.42 * rings)))
        raster.set(column, row, UInt8(value * 255))
      }
    }
  }

}
