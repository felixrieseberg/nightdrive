import CoreGraphics
import Foundation
import SwiftUI

@MainActor
class RasterVisualizer: Visualizer {
  enum BootEffect {
    case strike
    case wipe
  }

  let descriptor: VisualizerDescriptor
  let raster = VisualizerRaster()
  let energy = AudioEnergy()

  /// Available to `updateRaster`; fixed-step modes retain it through the first
  /// `advanceRaster` call that consumes the beat.
  private(set) var didBeat = false

  private let rows: Int
  private let levels: Int
  private let bootEffect: BootEffect
  private let step: TimeInterval?
  private let maximumCatchUp: (TimeInterval) -> TimeInterval
  private let makeRamp: (VisualizerPalette) -> VisualizerInkRamp
  private var accumulator = 0.0
  private var cachedRamp: (VisualizerPalette, VisualizerInkRamp)?

  init(
    id: String, name: String? = nil, rows: Int, levels: Int,
    bootEffect: BootEffect = .strike, step: TimeInterval? = nil,
    maximumCatchUp: @escaping (TimeInterval) -> TimeInterval = { _ in 1 },
    ramp: @escaping (VisualizerPalette) -> VisualizerInkRamp = VisualizerInkRamp.phosphor
  ) {
    descriptor = VisualizerDescriptor(
      id: id, name: name ?? id.uppercased(), wantsContinuousRedraw: true)
    self.rows = rows
    self.levels = levels
    self.bootEffect = bootEffect
    self.step = step
    self.maximumCatchUp = maximumCatchUp
    makeRamp = ramp
  }

  final func reset() {
    energy.reset()
    accumulator = 0
    didBeat = false
    resetRaster()
    raster.clear()
    raster.forget()
  }

  final func draw(_ frame: VisualizerFrame, into context: inout GraphicsContext) {
    let rect = CGRect(origin: .zero, size: frame.size)
    // Each new width costs two buffer reallocations plus a full regeneration,
    // so a drag stretches the picture on hand and resumes on mouse up.
    if frame.isLiveResizing, raster.blitLast(into: &context, in: rect) { return }

    let deltaTime = energy.update(frame)
    didBeat = didBeat || energy.didBeat
    let resized = raster.configure(for: frame.size, rows: rows)
    guard !raster.isEmpty else { return }
    updateRaster(frame, dt: deltaTime, resized: resized)
    if let step {
      accumulator = min(accumulator + deltaTime, maximumCatchUp(deltaTime))
      while accumulator >= step {
        accumulator -= step
        advanceRaster(frame)
        didBeat = false
      }
    } else {
      didBeat = false
    }
    composeRaster(frame)

    if let boot = frame.boot {
      switch bootEffect {
      case .strike: raster.strike(boot)
      case .wipe: raster.wipe(boot)
      }
    }
    raster.blit(into: &context, in: rect, ramp: inkRamp(frame.palette), levels: levels)
  }

  func resetRaster() {}

  func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {}

  func advanceRaster(_ frame: VisualizerFrame) {}
  func composeRaster(_ frame: VisualizerFrame) {}

  private func inkRamp(_ palette: VisualizerPalette) -> VisualizerInkRamp {
    if let cachedRamp, cachedRamp.0 == palette { return cachedRamp.1 }
    let ramp = makeRamp(palette)
    cachedRamp = (palette, ramp)
    return ramp
  }
}

/// Frees the buffer an image was built from. Core Graphics calls this on
/// whichever thread drops the last reference, so it must stay off the actor.
private nonisolated func releaseRasterPixels(
  _ info: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer, _ size: Int
) {
  UnsafeMutableRawPointer(mutating: data).deallocate()
}

@MainActor
final class VisualizerRaster {
  private(set) var width = 0
  private(set) var height = 0

  private(set) var pixels: [UInt8] = []

  private var scratch: [UInt8] = []
  private var lut = InkLUT(ramp: .init(stops: []), table: [])
  /// The most recent blit, kept so a drag can stretch it.
  private var lastImage: CGImage?
  private let colorSpace = CGColorSpaceCreateDeviceRGB()

  var isEmpty: Bool { width <= 0 || height <= 0 }

  // MARK: - Size

  @discardableResult
  func configure(for size: CGSize, cell: CGFloat = 3.4) -> Bool {
    guard let usable = Self.usable(size) else { return blank() }
    let step = max(1, cell)
    return resize(
      width: Int((usable.width / step).rounded()), height: Int((usable.height / step).rounded()))
  }

  @discardableResult
  func configure(for size: CGSize, rows: Int) -> Bool {
    guard let usable = Self.usable(size) else { return blank() }
    let height = max(1, rows)
    let aspect = usable.width / usable.height
    return resize(width: Int((CGFloat(height) * aspect).rounded()), height: height)
  }

  private static func usable(_ size: CGSize) -> CGSize? {
    guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
      return nil
    }
    return size
  }

  private func blank() -> Bool {
    guard width != 0 || height != 0 else { return false }
    width = 0
    height = 0
    pixels = []
    scratch = []
    lastImage = nil
    return true
  }

  @discardableResult
  private func resize(width w: Int, height h: Int) -> Bool {
    let w = Self.clamp(w, 8, 640)
    let h = Self.clamp(h, 4, 160)
    guard w != width || h != height else { return false }
    width = w
    height = h
    let count = w * h
    pixels = [UInt8](repeating: 0, count: count)
    scratch = [UInt8](repeating: 0, count: count)
    return true
  }

  /// Drops the held image so a drag cannot stretch a picture belonging to a
  /// mode the deck has moved on from.
  func forget() {
    lastImage = nil
  }

  // MARK: - Writing

  func clear(_ value: UInt8 = 0) {
    guard !pixels.isEmpty else { return }
    for index in pixels.indices { pixels[index] = value }
  }

  func value(_ x: Int, _ y: Int) -> UInt8 {
    guard x >= 0, y >= 0, x < width, y < height else { return 0 }
    return pixels[y * width + x]
  }

  func set(_ x: Int, _ y: Int, _ value: UInt8) {
    guard x >= 0, y >= 0, x < width, y < height else { return }
    pixels[y * width + x] = value
  }

  func plot(_ x: Int, _ y: Int, _ value: UInt8) {
    guard x >= 0, y >= 0, x < width, y < height, value > 0 else { return }
    let index = y * width + x
    pixels[index] = UInt8(min(255, Int(pixels[index]) + Int(value)))
  }

  func plot(x: Double, y: Double, value: Double) {
    guard value > 0, x > -1, y > -1, x < Double(width), y < Double(height) else { return }
    let x0 = Int(x.rounded(.down))
    let y0 = Int(y.rounded(.down))
    let fx = x - Double(x0)
    let fy = y - Double(y0)
    let amount = min(255, max(0, value))
    plot(x0, y0, UInt8(amount * (1 - fx) * (1 - fy)))
    plot(x0 + 1, y0, UInt8(amount * fx * (1 - fy)))
    plot(x0, y0 + 1, UInt8(amount * (1 - fx) * fy))
    plot(x0 + 1, y0 + 1, UInt8(amount * fx * fy))
  }

  func hspan(y: Int, from x0: Int, to x1: Int, _ value: UInt8) {
    guard y >= 0, y < height else { return }
    let lo = max(0, min(x0, x1))
    let hi = min(width - 1, max(x0, x1))
    guard lo <= hi else { return }
    let row = y * width
    for x in lo...hi { pixels[row + x] = value }
  }

  func vspan(x: Int, from y0: Int, to y1: Int, _ value: UInt8) {
    guard x >= 0, x < width else { return }
    let lo = max(0, min(y0, y1))
    let hi = min(height - 1, max(y0, y1))
    guard lo <= hi else { return }
    for y in lo...hi { pixels[y * width + x] = value }
  }

  func line(from a: CGPoint, to b: CGPoint, _ value: UInt8) {
    guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return }
    var x0 = Int(a.x.rounded())
    var y0 = Int(a.y.rounded())
    let x1 = Int(b.x.rounded())
    let y1 = Int(b.y.rounded())
    let dx = abs(x1 - x0)
    let dy = -abs(y1 - y0)
    let sx = x0 < x1 ? 1 : -1
    let sy = y0 < y1 ? 1 : -1
    var error = dx + dy
    for _ in 0..<(width + height) * 2 {
      plot(x0, y0, value)
      if x0 == x1 && y0 == y1 { return }
      let doubled = error * 2
      if doubled >= dy {
        error += dy
        x0 += sx
      }
      if doubled <= dx {
        error += dx
        y0 += sy
      }
    }
  }

  // MARK: - Reading

  func sample(x: Double, y: Double) -> UInt8 {
    guard !isEmpty else { return 0 }
    guard x.isFinite, y.isFinite else { return 0 }
    let cx = min(max(x, 0), Double(width - 1))
    let cy = min(max(y, 0), Double(height - 1))
    let x0 = Int(cx)
    let y0 = Int(cy)
    let x1 = min(width - 1, x0 + 1)
    let y1 = min(height - 1, y0 + 1)
    let fx = cx - Double(x0)
    let fy = cy - Double(y0)
    let top =
      Double(pixels[y0 * width + x0]) * (1 - fx) + Double(pixels[y0 * width + x1]) * fx
    let bottom =
      Double(pixels[y1 * width + x0]) * (1 - fx) + Double(pixels[y1 * width + x1]) * fx
    return UInt8(min(255, max(0, top * (1 - fy) + bottom * fy)))
  }

  // MARK: - Feedback passes

  func decay(_ scale: Double, drop: UInt8 = 0) {
    guard !pixels.isEmpty else { return }
    let factor = scale.isFinite ? min(max(scale, 0), 1) : 0
    for index in pixels.indices {
      let faded = Int(Double(pixels[index]) * factor) - Int(drop)
      pixels[index] = UInt8(max(0, faded))
    }
  }

  func convectUp(cooling: Int, sway: Int = 0, jitter: Int = 0, salt: UInt32 = 0) {
    guard width > 0, height > 1 else { return }
    let spread = max(0, jitter)
    for y in 0..<(height - 1) {
      let row = y * width
      let below = (y + 1) * width
      for x in 0..<width {
        var offset = sway
        if spread > 0 {
          offset += Int(Self.hash(x: x, y: y, salt: salt) % UInt32(spread * 2 + 1)) - spread
        }
        let source = Self.clamp(x + offset, 0, width - 1)
        let left = below + max(0, source - 1)
        let right = below + min(width - 1, source + 1)
        let sum = Int(pixels[left]) + Int(pixels[below + source]) * 6 + Int(pixels[right])
        scratch[row + x] = UInt8(max(0, sum / 8 - cooling))
      }
    }
    let last = (height - 1) * width
    for x in 0..<width { scratch[last + x] = pixels[last + x] }
    swap(&pixels, &scratch)
  }

  nonisolated static func hash(x: Int, y: Int, salt: UInt32) -> UInt32 {
    var h = UInt32(truncatingIfNeeded: x) &* 0x1656_67B1
    h &+= UInt32(truncatingIfNeeded: y) &* 0x27D4_EB2D
    h ^= salt &* 0x85EB_CA6B
    h ^= h >> 13
    h = h &* 0x4C95_7F2D
    h ^= h >> 16
    return h
  }

  func bloom(amount: Double = 0.55) {
    guard width > 2, height > 2, amount > 0 else { return }
    for y in 0..<height {
      let row = y * width
      for x in 0..<width {
        let left = pixels[row + max(0, x - 1)]
        let right = pixels[row + min(width - 1, x + 1)]
        scratch[row + x] = UInt8((Int(left) + Int(pixels[row + x]) * 2 + Int(right)) / 4)
      }
    }
    for y in 0..<height {
      let row = y * width
      let up = max(0, y - 1) * width
      let down = min(height - 1, y + 1) * width
      for x in 0..<width {
        let blurred = (Int(scratch[up + x]) + Int(scratch[row + x]) * 2 + Int(scratch[down + x])) / 4
        let lit = Int(pixels[row + x]) + Int(Double(blurred) * amount)
        pixels[row + x] = UInt8(min(255, lit))
      }
    }
  }

  // MARK: - Blitting

  func blit(
    into ctx: inout GraphicsContext, in rect: CGRect, ramp: VisualizerInkRamp,
    levels: Int = 0, opacity: Double = 1
  ) {
    guard !isEmpty, rect.width > 0, rect.height > 0, let image = image(ramp: ramp, levels: levels)
    else { return }
    lastImage = image
    Self.draw(image, into: &ctx, in: rect, opacity: opacity)
  }

  /// Redraws the last blitted image at a new size without touching the raster.
  /// False when nothing is held yet, so callers fall back to a full frame.
  func blitLast(into ctx: inout GraphicsContext, in rect: CGRect, opacity: Double = 1) -> Bool {
    guard let lastImage, rect.width > 0, rect.height > 0 else { return false }
    Self.draw(lastImage, into: &ctx, in: rect, opacity: opacity)
    return true
  }

  private static func draw(
    _ image: CGImage, into ctx: inout GraphicsContext, in rect: CGRect, opacity: Double
  ) {
    var layer = ctx
    if opacity < 1 { layer.opacity = opacity }
    layer.draw(Image(decorative: image, scale: 1).interpolation(.none), in: rect)
  }

  func image(ramp: VisualizerInkRamp, levels: Int = 0) -> CGImage? {
    guard !isEmpty else { return nil }
    // The unchecked writes below index the table by intensity, so the sentinel
    // empty LUT has to be rebuilt even if its ramp happens to match.
    if lut.ramp != ramp || lut.table.count < 256 * 4 { lut = InkLUT(ramp: ramp) }
    let count = width * height * 4
    // The provider owns this and frees it when the image goes, so a frame
    // writes its pixels once instead of staging them in an array to copy.
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
    let quantize = levels >= 2
    lut.table.withUnsafeBufferPointer { table in
      pixels.withUnsafeBufferPointer { source in
        var index = 0
        for y in 0..<height {
          let row = y * width
          for x in 0..<width {
            let raw = source[row + x]
            let intensity =
              quantize ? Int(Self.dither(raw, x: x, y: y, levels: levels)) : Int(raw)
            let entry = intensity * 4
            out[index] = table[entry]
            out[index + 1] = table[entry + 1]
            out[index + 2] = table[entry + 2]
            out[index + 3] = table[entry + 3]
            index += 4
          }
        }
      }
    }

    guard
      let provider = CGDataProvider(
        dataInfo: nil, data: out, size: count, releaseData: releaseRasterPixels)
    else {
      out.deallocate()
      return nil
    }
    return CGImage(
      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  // MARK: - Dither

  static let bayer: [Int] = [
    0, 32, 8, 40, 2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44, 4, 36, 14, 46, 6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
    3, 35, 11, 43, 1, 33, 9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47, 7, 39, 13, 45, 5, 37,
    63, 31, 55, 23, 61, 29, 53, 21,
  ]

  static func dither(_ value: UInt8, x: Int, y: Int, levels: Int) -> UInt8 {
    guard levels >= 2 else { return value }
    let steps = Double(levels - 1)
    let scaled = Double(value) / 255 * steps
    let base = scaled.rounded(.down)
    let threshold = (Double(bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64
    let level = min(steps, base + (scaled - base > threshold ? 1 : 0))
    return UInt8((level / steps * 255).rounded())
  }

  private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
    min(high, max(low, value))
  }
}

// MARK: - Ink

struct VisualizerInkStop: Hashable, Sendable {
  var at: Double
  var color: VisualizerColor
}

struct VisualizerInkRamp: Hashable, Sendable {
  var stops: [VisualizerInkStop]

  static func phosphor(_ palette: VisualizerPalette) -> VisualizerInkRamp {
    VisualizerInkRamp(stops: [
      VisualizerInkStop(at: 0, color: palette.glow.opacity(0)),
      VisualizerInkStop(at: 0.16, color: palette.ghost),
      VisualizerInkStop(at: 0.42, color: palette.dim),
      VisualizerInkStop(at: 1, color: palette.glow),
    ])
  }

  static func heat(
    _ palette: VisualizerPalette, ghostAt: Double = 0.14, dimAt: Double = 0.38,
    glowAt: Double = 0.72
  ) -> VisualizerInkRamp {
    VisualizerInkRamp(stops: [
      VisualizerInkStop(at: 0, color: palette.glow.opacity(0)),
      VisualizerInkStop(at: ghostAt, color: palette.ghost),
      VisualizerInkStop(at: dimAt, color: palette.dim),
      VisualizerInkStop(at: glowAt, color: palette.glow),
      VisualizerInkStop(at: 1, color: palette.amber),
    ])
  }

  static func flame(_ palette: VisualizerPalette) -> VisualizerInkRamp {
    VisualizerInkRamp(stops: [
      VisualizerInkStop(at: 0, color: palette.glow.opacity(0)),
      VisualizerInkStop(at: 0.07, color: palette.glow.opacity(0.30)),
      VisualizerInkStop(at: 0.30, color: palette.glow.opacity(0.72)),
      VisualizerInkStop(at: 0.62, color: palette.glow),
      VisualizerInkStop(at: 0.86, color: palette.amber),
      VisualizerInkStop(at: 1, color: palette.amber),
    ])
  }

  /// Returns a palette-parameterized ramp, matching `RasterVisualizer`'s
  /// `ramp:` parameter so cinematic modes can pass it directly.
  static func cinematic(
    low: (at: Double, opacity: Double), mid: (at: Double, opacity: Double),
    high: (at: Double, opacity: Double), solidAt: Double
  ) -> (VisualizerPalette) -> VisualizerInkRamp {
    { palette in
      VisualizerInkRamp(stops: [
        VisualizerInkStop(at: 0, color: palette.glow.opacity(0)),
        VisualizerInkStop(at: low.at, color: palette.glow.opacity(low.opacity)),
        VisualizerInkStop(at: mid.at, color: palette.glow.opacity(mid.opacity)),
        VisualizerInkStop(at: high.at, color: palette.glow.opacity(high.opacity)),
        VisualizerInkStop(at: solidAt, color: palette.glow),
        VisualizerInkStop(at: 1, color: palette.amber),
      ])
    }
  }

  func color(at position: Double) -> VisualizerColor {
    guard let first = stops.first else { return VisualizerColor(red: 0, green: 0, blue: 0, alpha: 0) }
    let t = min(max(position, 0), 1)
    if t <= first.at { return first.color }
    for index in 1..<stops.count {
      let hi = stops[index]
      guard t <= hi.at else { continue }
      let lo = stops[index - 1]
      let span = hi.at - lo.at
      let mix = span <= 0 ? 0 : (t - lo.at) / span
      return VisualizerColor(
        red: lo.color.red + (hi.color.red - lo.color.red) * mix,
        green: lo.color.green + (hi.color.green - lo.color.green) * mix,
        blue: lo.color.blue + (hi.color.blue - lo.color.blue) * mix,
        alpha: lo.color.alpha + (hi.color.alpha - lo.color.alpha) * mix)
    }
    return stops[stops.count - 1].color
  }
}

private struct InkLUT {
  let ramp: VisualizerInkRamp
  let table: [UInt8]

  init(ramp: VisualizerInkRamp, table: [UInt8]) {
    self.ramp = ramp
    self.table = table
  }

  init(ramp: VisualizerInkRamp) {
    self.ramp = ramp
    var table = [UInt8](repeating: 0, count: 256 * 4)
    for index in 0..<256 {
      let ink = ramp.color(at: Double(index) / 255)
      let alpha = min(max(ink.alpha, 0), 1)
      table[index * 4] = UInt8(min(255, max(0, ink.red * alpha * 255)))
      table[index * 4 + 1] = UInt8(min(255, max(0, ink.green * alpha * 255)))
      table[index * 4 + 2] = UInt8(min(255, max(0, ink.blue * alpha * 255)))
      table[index * 4 + 3] = UInt8(alpha * 255)
    }
    self.table = table
  }
}
