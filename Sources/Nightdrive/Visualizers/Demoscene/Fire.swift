import Foundation

final class FireVisualizer: RasterVisualizer {
  private var noise = DemoNoise(seed: 0x5EED_F17E)
  private var fuel: [Double] = []
  private var draught = 0.0

  private static let stepsPerSecond = 24.0
  private static let step = 1.0 / stepsPerSecond
  private static let stallThreshold = 0.2
  private static let catchUpWindow = 3.0 * step

  init() {
    super.init(
      id: "fire", rows: 40, levels: 9, step: Self.step,
      maximumCatchUp: { $0 > Self.stallThreshold ? Self.catchUpWindow : 1 },
      ramp: VisualizerInkRamp.flame)
  }

  override func resetRaster() {
    noise = DemoNoise(seed: 0x5EED_F17E)
    fuel.removeAll()
    draught = 0
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    if fuel.count != raster.width { fuel = [Double](repeating: 0, count: raster.width) }
  }

  override func advanceRaster(_ frame: VisualizerFrame) {
    let width = raster.width
    let height = raster.height

    let idle = frame.isPlaying ? 0.0 : 0.22 + 0.06 * VFDTrig.sin(energy.flow * 0.3)

    for x in 0..<width {
      let target = max(idle, pow(energy.band(frame, x, of: width), 0.6))
      fuel[x] += (target - fuel[x]) * (target > fuel[x] ? 0.55 : 0.14)
    }

    let flash = energy.beat * 0.4
    let seedRow = height - 1
    let drift = draught * 0.16
    for x in 0..<width {
      let coarse = DemoNoise.smooth(Double(x) / 13 + drift, seed: 0x9E37)
      let fine = DemoNoise.smooth(Double(x) / 4.5 - drift * 1.7, seed: 0x2545)
      let flicker = 0.10 + 0.80 * coarse + 0.42 * fine + 0.14 * noise.unit()
      let heat = min(1, (fuel[x] + 0.06 + flash) * max(0.05, flicker))
      raster.set(x, seedRow, UInt8(heat * 255))
      raster.set(x, seedRow - 1, UInt8(min(255, heat * 240)))
    }

    draught += 1
    let sway = Int((VFDTrig.sin(draught * 0.0021) * 1.7).rounded())
    let cooling = max(3, Int(9.0 - energy.level * 3.5 - energy.bass * 2.0))
    raster.convectUp(
      cooling: cooling, sway: sway, jitter: 1, salt: UInt32(truncatingIfNeeded: Int(draught)))
  }
}
