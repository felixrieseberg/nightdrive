import Foundation

final class PlasmaVisualizer: RasterVisualizer {
  private var rings = [Double](reservingCapacity: 3)
  private var work = PlasmaWorkBuffers()

  init() {
    super.init(
      id: "plasma", rows: 34, levels: 6,
      ramp: { .heat($0, ghostAt: 0.2, dimAt: 0.5, glowAt: 0.88) })
  }

  override func resetRaster() {
    rings.removeAll(keepingCapacity: true)
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    if didBeat {
      rings.append(0)
      if rings.count > 3 { rings.removeFirst(rings.count - 3) }
    }
    for index in rings.indices { rings[index] += dt * 0.42 }
    rings.removeAll { $0 > 0.8 }

    let width = raster.width
    let height = raster.height
    work.configure(width: width, height: height)
    let time = energy.flow
    let tighten = 1 + energy.bass * 0.85
    let acrossX = 7.5 * tighten
    let acrossY = 2.3 * tighten
    let cx = 0.5 + 0.32 * VFDTrig.sin(time * 0.11)
    let cy = 0.5 + 0.30 * VFDTrig.sin(time * 0.17)

    for y in 0..<height {
      let v = Double(y) / Double(max(1, height - 1))
      work.rowV[y] = v
      work.rowTerm[y] = VFDTrig.sin(v * acrossY + time * 0.63)
    }
    for x in 0..<width {
      let u = Double(x) / Double(max(1, width - 1))
      work.columnU[x] = u
      work.columnTerm[x] = VFDTrig.sin(u * acrossX + time * 0.41)
    }

    let squash = 0.22
    for y in 0..<height {
      let dy = (work.rowV[y] - cy) * squash
      let dySquared = dy * dy
      let row = work.rowTerm[y]
      let diagonalRow = work.rowV[y] * acrossY * 0.8
      for x in 0..<width {
        let dx = work.columnU[x] - cx
        let distance = (dx * dx + dySquared).squareRoot()
        let value =
          work.columnTerm[x] + row
          + VFDTrig.sin(work.columnU[x] * acrossX * 0.6 + diagonalRow + time * 0.29)
          + VFDTrig.sin(distance * 5.5 * tighten - time * 0.47)
        var shock = 0.0
        for ring in rings {
          let offset = (distance - ring) * 26
          if abs(offset) < 3 { shock += exp(-offset * offset) }
        }
        let cycled = VFDTrig.wave(value * 0.13 + time * 0.35) * 0.78
        raster.set(x, y, UInt8(min(255, (cycled + shock * 0.5) * 255)))
      }
    }
  }

}

struct PlasmaWorkBuffers {
  var rowTerm: [Double] = []
  var rowV: [Double] = []
  var columnTerm: [Double] = []
  var columnU: [Double] = []

  @discardableResult
  mutating func configure(width: Int, height: Int) -> Bool {
    let rowCount = max(0, height)
    let columnCount = max(0, width)
    var changed = false
    if rowTerm.count != rowCount {
      rowTerm = [Double](repeating: 0, count: rowCount)
      rowV = [Double](repeating: 0, count: rowCount)
      changed = true
    }
    if columnTerm.count != columnCount {
      columnTerm = [Double](repeating: 0, count: columnCount)
      columnU = [Double](repeating: 0, count: columnCount)
      changed = true
    }
    return changed
  }
}
