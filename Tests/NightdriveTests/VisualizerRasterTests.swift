import CoreGraphics
import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct VisualizerRasterTests {

  @Test
  func testSmoothNoiseReturnsANeutralValueForUnrepresentablePositions() {
    for position in [
      Double.nan, .infinity, -.infinity, Double.greatestFiniteMagnitude,
      -Double.greatestFiniteMagnitude, Double(Int.max),
    ] {
      #expect(
        DemoNoise.smooth(position, seed: 42) == 0.5,
        Comment(rawValue: "an invalid cell at \(position) must not reach a trapping Int conversion"))
    }
    #expect(
      DemoNoise.smooth(.nan, seed: 42) == DemoNoise.smooth(.nan, seed: 42),
      Comment(rawValue: "the defensive fallback must be deterministic"))
  }

  @Test
  func testSmoothNoiseStillInterpolatesValidPositions() {
    let atCell = DemoNoise.smooth(12, seed: 42)
    let nextCell = DemoNoise.smooth(13, seed: 42)
    #expect(DemoNoise.smooth(12, seed: 42) == atCell)
    #expect(abs((DemoNoise.smooth(12.5, seed: 42)) - ((atCell + nextCell) / 2)) <= 1e-12)
    #expect((0...1).contains(DemoNoise.smooth(-12.25, seed: 42)))
  }

  @Test
  func testPlasmaWorkBuffersOnlyResizeWhenTheRasterShapeChanges() {
    var buffers = PlasmaWorkBuffers()
    var didResize = buffers.configure(width: 20, height: 4)
    #expect(didResize)
    #expect(buffers.rowTerm.count == 4)
    #expect(buffers.columnTerm.count == 20)

    buffers.rowTerm[0] = 123
    buffers.columnU[0] = 456
    didResize = buffers.configure(width: 20, height: 4)
    #expect(!didResize)
    #expect(buffers.rowTerm[0] == 123, Comment(rawValue: "stable frames must keep their row storage"))
    #expect(buffers.columnU[0] == 456, Comment(rawValue: "stable frames must keep their column storage"))

    didResize = buffers.configure(width: 30, height: 4)
    #expect(didResize)
    #expect(buffers.rowTerm[0] == 123, Comment(rawValue: "a width-only resize must keep the row storage"))
    #expect(buffers.columnU == [Double](repeating: 0, count: 30))

    didResize = buffers.configure(width: 30, height: 6)
    #expect(didResize)
    #expect(buffers.rowTerm == [Double](repeating: 0, count: 6))
    #expect(buffers.rowV.count == 6)
    #expect(buffers.columnTerm.count == 30)
    #expect(buffers.columnU == [Double](repeating: 0, count: 30))
  }

  @Test
  func testConfiguringPicksAWideShortGridAndReportsChanges() {
    let raster = VisualizerRaster()
    #expect(raster.isEmpty)

    var didResize = raster.configure(for: CGSize(width: 880, height: 52), rows: 34)
    #expect(didResize)
    #expect(raster.height == 34)
    #expect(abs((Double(raster.width) / 34) - (880.0 / 52)) <= 0.6)
    #expect(!(raster.isEmpty))

    didResize = raster.configure(for: CGSize(width: 880, height: 52), rows: 34)
    #expect(!didResize)
    didResize = raster.configure(for: CGSize(width: 400, height: 52), rows: 34)
    #expect(didResize)
  }

  @Test
  func testAbsurdSizesAreClampedRatherThanAllocated() {
    let raster = VisualizerRaster()
    raster.configure(for: CGSize(width: 100_000, height: 4), rows: 34)
    #expect(raster.width <= 640)
    #expect(raster.width >= 8)

    raster.configure(for: CGSize(width: 0, height: 0), rows: 34)
    #expect(raster.isEmpty)

    raster.configure(for: CGSize(width: -50, height: CGFloat.nan), rows: 34)
    #expect(raster.isEmpty)

    raster.configure(for: CGSize(width: 200, height: 40), rows: 100_000)
    #expect(raster.height <= 160)
  }

  @Test
  func testResizingClearsRatherThanKeepingStaleDots() {
    let raster = VisualizerRaster()
    raster.configure(for: CGSize(width: 200, height: 40), rows: 20)
    raster.hspan(y: 3, from: 0, to: raster.width - 1, 200)
    #expect(raster.value(5, 3) == 200)

    raster.configure(for: CGSize(width: 400, height: 40), rows: 20)
    #expect(raster.value(5, 3) == 0)
  }

  @Test
  func testPlottingSaturatesInsteadOfWrapping() {
    let raster = makeRaster()
    raster.plot(4, 4, 200)
    raster.plot(4, 4, 200)
    #expect(raster.value(4, 4) == 255, Comment(rawValue: "additive plot must clamp, not roll over"))
  }

  @Test
  func testWritesOutsideTheGridAreDroppedNotWrapped() {
    let raster = makeRaster()
    let width = raster.width
    raster.plot(-1, 0, 255)
    raster.plot(width, 0, 255)
    raster.plot(0, -3, 255)
    raster.plot(0, raster.height + 2, 255)
    raster.set(-1, -1, 255)
    #expect(raster.value(width - 1, 0) == 0)
    #expect(raster.value(0, 0) == 0)
    #expect(raster.pixels.allSatisfy { $0 == 0 })
  }

  @Test
  func testSubPixelPlotSpreadsOverTheFourNeighbours() {
    let raster = makeRaster()
    raster.plot(x: 3.5, y: 2.5, value: 200)
    let corners = [
      raster.value(3, 2), raster.value(4, 2), raster.value(3, 3), raster.value(4, 3),
    ]
    #expect(corners.allSatisfy { $0 > 0 }, "a half-way plot must light all four")
    #expect(abs((corners.reduce(0) { $0 + Int($1) }) - (200)) <= 4)
    #expect(abs((Int(corners[0])) - (Int(corners[3]))) <= 2)
  }

  @Test
  func testSpansAreInclusiveAndClipped() {
    let raster = makeRaster()
    raster.hspan(y: 2, from: -10, to: 3, 90)
    #expect(raster.value(0, 2) == 90)
    #expect(raster.value(3, 2) == 90)
    #expect(raster.value(4, 2) == 0)

    raster.vspan(x: 5, from: 1, to: 10_000, 70)
    #expect(raster.value(5, 1) == 70)
    #expect(raster.value(5, raster.height - 1) == 70)
    #expect(raster.value(5, 0) == 0)

    raster.hspan(y: 4, from: 6, to: 2, 50)
    #expect(raster.value(3, 4) == 50)
  }

  @Test
  func testLinesConnectBothEnds() {
    let raster = makeRaster()
    raster.line(from: CGPoint(x: 1, y: 1), to: CGPoint(x: 9, y: 5), 120)
    #expect(raster.value(1, 1) == 120)
    #expect(raster.value(9, 5) == 120)
    for x in 1...9 {
      let lit = (0..<raster.height).contains { raster.value(x, $0) > 0 }
      #expect(lit, Comment(rawValue: "column \(x) must be on the line"))
    }
  }

  @Test
  func testLineWithNonFiniteEndpointsIsDroppedNotTrapped() {
    let raster = makeRaster()
    raster.line(from: CGPoint(x: CGFloat.nan, y: 2), to: CGPoint(x: 8, y: 4), 200)
    raster.line(from: CGPoint(x: 2, y: 2), to: CGPoint(x: CGFloat.infinity, y: 4), 200)
    raster.line(from: CGPoint(x: 2, y: CGFloat.nan), to: CGPoint(x: 8, y: -CGFloat.infinity), 200)
    let anyLit = (0..<raster.height).contains { y in
      (0..<raster.width).contains { raster.value($0, y) > 0 }
    }
    #expect(!(anyLit))
  }

  @Test
  func testSamplingInterpolatesAndClampsAtTheEdges() {
    let raster = makeRaster()
    raster.set(0, 0, 0)
    raster.set(1, 0, 100)
    #expect(abs((Int(raster.sample(x: 0.5, y: 0))) - (50)) <= 1)
    #expect(raster.sample(x: 0, y: 0) == 0)
    #expect(raster.sample(x: 1, y: 0) == 100)
    #expect(raster.sample(x: -20, y: -20) == 0)
    #expect(raster.sample(x: 1e9, y: 1e9) == raster.value(raster.width - 1, raster.height - 1))
  }

  @Test
  func testSamplingNonFiniteCoordinatesReturnsZeroNotTrap() {
    let raster = makeRaster()
    raster.set(0, 0, 90)
    #expect(raster.sample(x: Double.nan, y: 0) == 0)
    #expect(raster.sample(x: 0, y: Double.nan) == 0)
    #expect(raster.sample(x: Double.infinity, y: -Double.infinity) == 0)
  }

  @Test
  func testDecayFadesTowardsBlackAndGetsThere() {
    let raster = makeRaster()
    raster.hspan(y: 0, from: 0, to: raster.width - 1, 255)
    raster.decay(0.5, drop: 0)
    #expect(raster.value(0, 0) == 127)

    raster.set(0, 0, 1)
    raster.decay(0.99, drop: 2)
    #expect(raster.value(0, 0) == 0)
  }

  @Test
  func testDecayWithNonFiniteScaleFadesToBlackNotTrap() {
    let raster = makeRaster()
    raster.hspan(y: 0, from: 0, to: raster.width - 1, 255)
    raster.decay(Double.nan)
    #expect(raster.value(0, 0) == 0)

    raster.hspan(y: 0, from: 0, to: raster.width - 1, 255)
    raster.decay(Double.infinity)
    #expect(raster.value(0, 0) == 0)
  }

  @Test
  func testConvectionMovesHeatUpAndCools() {
    let raster = makeRaster()
    let bottom = raster.height - 1
    raster.hspan(y: bottom, from: 0, to: raster.width - 1, 255)
    raster.convectUp(cooling: 4, sway: 0, jitter: 0, salt: 1)

    #expect(raster.value(3, bottom - 1) > 0, Comment(rawValue: "heat must rise"))
    #expect(raster.value(3, bottom - 1) < 255, Comment(rawValue: "and lose energy doing it"))
    #expect(raster.value(3, bottom) == 255, Comment(rawValue: "the seed row is never consumed"))

    let expected = UInt8(255 - 4)
    for x in 0..<raster.width {
      #expect(raster.value(x, bottom - 1) == expected)
      #expect(raster.value(x, 0) == 0, Comment(rawValue: "heat has not reached the top in one pass"))
    }
  }

  @Test
  func testBloomSpreadsLightWithoutOverflow() {
    let raster = makeRaster()
    raster.set(5, 3, 255)
    raster.bloom(amount: 0.9)
    #expect(raster.value(4, 3) > 0)
    #expect(raster.value(6, 3) > 0)
    #expect(raster.pixels.allSatisfy { $0 <= 255 })
  }

  @Test
  func testDitherQuantisesToTheRequestedLevels() {
    let allowed: Set<UInt8> = [0, 85, 170, 255]
    for value in stride(from: 0, through: 255, by: 5) {
      for x in 0..<8 {
        for y in 0..<8 {
          let out = VisualizerRaster.dither(UInt8(value), x: x, y: y, levels: 4)
          #expect(allowed.contains(out), Comment(rawValue: "\(value) at \(x),\(y) produced \(out)"))
        }
      }
    }
  }

  @Test
  func testDitherAveragesBackToTheInputAcrossTheMatrix() {
    for value in [30, 64, 120, 200, 240] {
      var total = 0
      for x in 0..<8 {
        for y in 0..<8 { total += Int(VisualizerRaster.dither(UInt8(value), x: x, y: y, levels: 4)) }
      }
      #expect(abs((Double(total) / 64) - (Double(value))) <= 6)
    }
  }

  @Test
  func testDitherIsStableAndHandlesDegenerateLevels() {
    #expect(VisualizerRaster.dither(123, x: 2, y: 5, levels: 6) == VisualizerRaster.dither(123, x: 2, y: 5, levels: 6))
    #expect(throws: Never.self) { VisualizerRaster.dither(123, x: -3, y: -9, levels: 4) }
    #expect(VisualizerRaster.dither(200, x: 0, y: 0, levels: 1) == 200)
    #expect(VisualizerRaster.dither(200, x: 0, y: 0, levels: 0) == 200)
    #expect(VisualizerRaster.dither(200, x: 0, y: 0, levels: -4) == 200)
  }

  @Test
  func testInkRampInterpolatesBetweenStops() {
    let palette = VisualizerPalette.vfd
    let ramp = VisualizerInkRamp.heat(palette)
    #expect(abs((ramp.color(at: 0).alpha) - (0)) <= 0.001)
    #expect(ramp.color(at: 1) == palette.amber)
    var previous = 0.0
    for step in 0...16 {
      let alpha = ramp.color(at: Double(step) / 16).alpha
      #expect(alpha + 0.001 >= previous)
      previous = alpha
    }
    #expect(ramp.color(at: -5) == ramp.color(at: 0))
    #expect(ramp.color(at: 5) == ramp.color(at: 1))
  }

  @Test
  func testImageIsProducedForAnyReasonableGrid() {
    let raster = VisualizerRaster()
    raster.configure(for: CGSize(width: 880, height: 52), rows: 34)
    raster.hspan(y: 10, from: 0, to: raster.width - 1, 255)
    let image = raster.image(ramp: .phosphor(.vfd), levels: 4)
    #expect(image?.width == raster.width)
    #expect(image?.height == raster.height)

    let empty = VisualizerRaster()
    #expect(empty.image(ramp: .phosphor(.vfd), levels: 4) == nil)
  }

  private func makeRaster() -> VisualizerRaster {
    let raster = VisualizerRaster()
    raster.configure(for: CGSize(width: 160, height: 80), cell: 4)
    #expect(!(raster.isEmpty))
    raster.clear()
    return raster
  }
}
