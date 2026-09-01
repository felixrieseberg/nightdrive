import SwiftUI

enum DeckCeremony {
  static let defaultGreeting = "HELLO"
  static let maxLength = 16

  static func display(_ text: String, fallback: String) -> String {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !cleaned.isEmpty else { return fallback }
    return String(cleaned.prefix(maxLength))
  }

  // MARK: - Greeting schedule

  static let igniteDuration: TimeInterval = 0.34
  static let cascadeDuration: TimeInterval = 0.38
  static let assembleDuration: TimeInterval = 1.02
  static let greetingHoldDuration: TimeInterval = 0.82
  static let releaseDuration: TimeInterval = 0.34

  static var greetingDuration: TimeInterval {
    igniteDuration + cascadeDuration + assembleDuration + greetingHoldDuration
      + releaseDuration
  }

  enum GreetingPhase: Equatable {
    case ignite(progress: Double)
    case cascade(progress: Double)
    case assemble(progress: Double)
    case holding(progress: Double)
    case releasing(progress: Double)
    case done
  }

  static func greetingPhase(at elapsed: TimeInterval) -> GreetingPhase {
    guard elapsed >= 0 else { return .ignite(progress: 0) }
    var t = elapsed
    if t < igniteDuration { return .ignite(progress: t / igniteDuration) }
    t -= igniteDuration
    if t < cascadeDuration { return .cascade(progress: t / cascadeDuration) }
    t -= cascadeDuration
    if t < assembleDuration { return .assemble(progress: t / assembleDuration) }
    t -= assembleDuration
    if t < greetingHoldDuration { return .holding(progress: t / greetingHoldDuration) }
    t -= greetingHoldDuration
    if t < releaseDuration { return .releasing(progress: t / releaseDuration) }
    return .done
  }

  // MARK: - Dots and easing

  struct DotCell: Equatable {
    let column: Int
    let row: Int
  }

  static func litDots(_ text: String) -> [DotCell] {
    var dots: [DotCell] = []
    var x = 0
    for character in text {
      let glyph = VFDDotFont.glyph(character)
      for column in 0..<VFDDotFont.glyphWidth {
        let bits = glyph[column]
        for row in 0..<VFDDotFont.glyphHeight where bits & (1 << UInt8(row)) != 0 {
          dots.append(DotCell(column: x + column, row: row))
        }
      }
      x += VFDDotFont.glyphWidth + VFDDotFont.tracking
    }
    return dots
  }

  static func stagger(origin: Double, overlap: Double, progress: Double) -> Double {
    guard overlap > 0 else { return progress >= origin ? 1 : 0 }
    return min(1, max(0, (progress - min(origin, 1 - overlap)) / overlap))
  }

  static func scatter(_ index: Int, salt: Int = 0) -> Double {
    let v = Foundation.sin(Double(index) * 12.9898 + Double(salt) * 78.233) * 43758.5453
    return v - v.rounded(.down)
  }

  static func easeOutCubic(_ t: Double) -> Double {
    let u = 1 - min(1, max(0, t))
    return 1 - u * u * u
  }
}

// MARK: - Shared drawing

private enum CeremonyInk {
  struct Dot {
    var center: CGPoint
    var size: CGFloat
    var alpha: Double
  }

  static func fill(
    _ dots: [Dot], color: VisualizerColor, into ctx: inout GraphicsContext
  ) {
    let buckets = 6
    var paths = [Path](repeating: Path(), count: buckets)
    for dot in dots {
      let alpha = min(1, max(0, dot.alpha))
      guard alpha > 0.02, dot.size > 0.2 else { continue }
      let bucket = min(buckets - 1, Int(alpha * Double(buckets)))
      paths[bucket].addRect(
        CGRect(
          x: dot.center.x - dot.size / 2, y: dot.center.y - dot.size / 2,
          width: dot.size, height: dot.size))
    }
    for (index, path) in paths.enumerated() where !path.isEmpty {
      let alpha = (Double(index) + 0.7) / Double(buckets)
      ctx.glowing(color, radius: 2.5)
        .fill(path, with: .color(color.color.opacity(alpha)))
    }
  }

  static func pixelCenter(
    origin: CGPoint, column: Int, row: Int, dot: CGFloat
  ) -> CGPoint {
    let size = DotMatrix.pixelSize(dot: dot)
    return CGPoint(
      x: origin.x + CGFloat(column) * dot + size / 2,
      y: origin.y + CGFloat(row) * dot + size / 2)
  }

  static func scanline(
    y: CGFloat, centerX: CGFloat, width: CGFloat, alpha: Double,
    color: VisualizerColor, into ctx: inout GraphicsContext
  ) {
    guard width > 0.5, alpha > 0.02 else { return }
    let soft = CGRect(x: centerX - width / 2, y: y - 2.6, width: width, height: 5.2)
    ctx.fill(
      Path(roundedRect: soft, cornerRadius: 2.6),
      with: .color(color.color.opacity(alpha * 0.28)))
    let core = CGRect(x: centerX - width / 2, y: y - 1.1, width: width, height: 2.2)
    ctx.glowing(color, radius: 4)
      .fill(Path(roundedRect: core, cornerRadius: 1.1), with: .color(color.color.opacity(alpha)))
  }

  static func caption(
    _ text: String, centerX: CGFloat, y: CGFloat, alpha: Double,
    color: VisualizerColor, into ctx: inout GraphicsContext
  ) {
    guard alpha > 0.02 else { return }
    let dot: CGFloat = 1.7
    let width = DotMatrix.width(of: text, dot: dot)
    var path = Path()
    DotMatrix.draw(text, at: CGPoint(x: centerX - width / 2, y: y), dot: dot, into: &path)
    ctx.glowing(color, radius: 1.5)
      .fill(path, with: .color(color.color.opacity(alpha)))
  }

  static func ghostBand(
    origin: CGPoint, columns: Int, dot: CGFloat, alpha: Double,
    color: VisualizerColor, into ctx: inout GraphicsContext
  ) {
    guard alpha > 0.02 else { return }
    var path = Path()
    DotMatrix.ghostGrid(
      in: CGRect(
        x: origin.x, y: origin.y, width: CGFloat(columns) * dot,
        height: DotMatrix.height(dot: dot)),
      dot: dot, into: &path)
    ctx.fill(path, with: .color(color.color.opacity(alpha)))
  }

  static func brackets(
    in rect: CGRect, alpha: Double, color: VisualizerColor,
    into ctx: inout GraphicsContext
  ) {
    guard alpha > 0.02 else { return }
    let arm: CGFloat = 16
    var path = Path()
    for (x, dx): (CGFloat, CGFloat) in [(rect.minX, 1), (rect.maxX, -1)] {
      for (y, dy): (CGFloat, CGFloat) in [(rect.minY, 1), (rect.maxY, -1)] {
        path.move(to: CGPoint(x: x + dx * arm, y: y))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: x, y: y + dy * arm))
      }
    }
    ctx.glowing(color, radius: 1.5)
      .stroke(path, with: .color(color.color.opacity(alpha)), lineWidth: 1.5)
  }

  static func layout(_ text: String, in size: CGSize) -> (origin: CGPoint, dot: CGFloat) {
    let cells = max(1, VFDDotFont.width(of: text))
    let dot = max(
      2,
      min(
        (size.height * 0.52 / CGFloat(VFDDotFont.glyphHeight) * 2).rounded(.down) / 2,
        (size.width * 0.88 / CGFloat(cells) * 2).rounded(.down) / 2))
    let width = DotMatrix.width(of: text, dot: dot)
    let height = DotMatrix.height(dot: dot)
    return (
      CGPoint(
        x: ((size.width - width) / 2).rounded(),
        y: ((size.height - height) / 2 - size.height * 0.08).rounded()),
      dot
    )
  }
}

// MARK: - Greeting overlay

struct DeckGreetingView: View {
  let text: String
  let start: Date
  var frozen: TimeInterval? = nil

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    Group {
      if let frozen {
        canvas(at: frozen)
      } else {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) {
          timeline in
          canvas(at: timeline.date.timeIntervalSince(start))
        }
      }
    }
    .allowsHitTesting(false)
  }

  private func canvas(at elapsed: TimeInterval) -> some View {
    let palette = VFD.palette
    return Canvas { ctx, size in
      Self.draw(text: text, elapsed: elapsed, palette: palette, size: size, into: &ctx)
    }
  }

  private static func draw(
    text: String, elapsed: TimeInterval, palette: VisualizerPalette, size: CGSize,
    into ctx: inout GraphicsContext
  ) {
    guard size.width > 60, size.height > 30 else { return }
    let glow = palette.glow
    let centerY = (size.height / 2).rounded()
    let centerX = size.width / 2

    switch DeckCeremony.greetingPhase(at: elapsed) {
    case .ignite(let p):
      let flicker = p < 0.5 ? 0.5 + 0.5 * abs(Foundation.sin(elapsed * 34)) : 1
      let width = CGFloat(DeckCeremony.easeOutCubic(p)) * size.width
      CeremonyInk.scanline(
        y: centerY, centerX: centerX, width: max(width, 3), alpha: flicker,
        color: glow, into: &ctx)
      let flare = CGFloat(1 - p) * 3.5 + 1.5
      ctx.glowing(glow, radius: 6).fill(
        Path(
          ellipseIn: CGRect(
            x: centerX - flare, y: centerY - flare, width: flare * 2, height: flare * 2)),
        with: .color(glow.color))

    case .cascade(let p):
      CeremonyInk.scanline(
        y: centerY, centerX: centerX, width: size.width, alpha: 1, color: glow, into: &ctx)
      let front = DeckCeremony.easeOutCubic(p) * (Double(centerX) + 60)
      let pitch: CGFloat = 9
      let rowPitch: CGFloat = 6
      let maxRows = max(2, Int((size.height / 2 - 10) / rowPitch))
      var cells: [CeremonyInk.Dot] = []
      var column = 0
      while CGFloat(column) * pitch <= centerX {
        defer { column += 1 }
        let distance = Double(CGFloat(column) * pitch)
        let crest = exp(-pow((distance - front) / 60, 2))
        let swell = 0.3 * exp(-pow((distance - front * 0.5) / 90, 2))
        let rows = Int((Double(maxRows) * min(1, crest + swell)).rounded())
        guard rows > 0 else { continue }
        for side: CGFloat in (column == 0 ? [1] : [-1, 1]) {
          let x = centerX + side * CGFloat(column) * pitch
          for row in 0..<rows {
            let fade = 1 - Double(row) / Double(maxRows) * 0.45
            let y = CGFloat(row + 1) * rowPitch
            cells.append(
              .init(
                center: CGPoint(x: x, y: centerY - 3 - y), size: 4.2,
                alpha: crest * fade + 0.15))
            cells.append(
              .init(
                center: CGPoint(x: x, y: centerY + 3 + y), size: 4.2,
                alpha: crest * fade + 0.15))
          }
        }
      }
      CeremonyInk.fill(cells, color: glow, into: &ctx)

    case .assemble(let p):
      let (origin, dot) = CeremonyInk.layout(text, in: size)
      CeremonyInk.scanline(
        y: centerY, centerX: centerX, width: size.width,
        alpha: max(0, 1 - p * 1.9), color: glow, into: &ctx)
      CeremonyInk.ghostBand(
        origin: origin, columns: VFDDotFont.width(of: text), dot: dot,
        alpha: min(1, p * 1.4), color: palette.ghost, into: &ctx)

      let litDots = DeckCeremony.litDots(text)
      let count = max(1, litDots.count - 1)
      var dots: [CeremonyInk.Dot] = []
      dots.reserveCapacity(litDots.count)
      let pixelSize = DotMatrix.pixelSize(dot: dot)
      for (index, cell) in litDots.enumerated() {
        let q = DeckCeremony.stagger(
          origin: Double(index) / Double(count) * 0.55, overlap: 0.45, progress: p)
        guard q > 0 else { continue }
        let eased = DeckCeremony.easeOutCubic(q)
        let final = CeremonyInk.pixelCenter(
          origin: origin, column: cell.column, row: cell.row, dot: dot)
        let launchX = centerX + CGFloat(DeckCeremony.scatter(index) * 2 - 1) * centerX * 0.95
        dots.append(
          .init(
            center: CGPoint(
              x: launchX + (final.x - launchX) * CGFloat(eased),
              y: centerY + (final.y - centerY) * CGFloat(eased)),
            size: pixelSize * (0.55 + 0.45 * CGFloat(eased)),
            alpha: 0.3 + 0.7 * eased))
      }
      CeremonyInk.fill(dots, color: glow, into: &ctx)
      CeremonyInk.caption(
        "NIGHTDRIVE HI-FI SYSTEM", centerX: centerX,
        y: origin.y + DotMatrix.height(dot: dot) + 12,
        alpha: max(0, (p - 0.72) / 0.28) * 0.8, color: palette.dim, into: &ctx)

    case .holding(let p):
      let (origin, dot) = CeremonyInk.layout(text, in: size)
      let textWidth = DotMatrix.width(of: text, dot: dot)
      CeremonyInk.ghostBand(
        origin: origin, columns: VFDDotFont.width(of: text), dot: dot, alpha: 1,
        color: palette.ghost, into: &ctx)

      let sweep = (p * 2).truncatingRemainder(dividingBy: 1)
      let sweepX = Double(origin.x) + (Double(textWidth) + 160) * sweep - 80
      var dots: [CeremonyInk.Dot] = []
      let pixelSize = DotMatrix.pixelSize(dot: dot)
      for cell in DeckCeremony.litDots(text) {
        let center = CeremonyInk.pixelCenter(
          origin: origin, column: cell.column, row: cell.row, dot: dot)
        let x = center.x
        let highlight = exp(-pow((Double(x) - sweepX) / 60, 2))
        dots.append(
          .init(
            center: center, size: pixelSize, alpha: 0.72 + 0.28 * highlight))
      }
      CeremonyInk.fill(dots, color: glow, into: &ctx)

      let underlineWidth = CGFloat(DeckCeremony.easeOutCubic(min(1, p * 2.4))) * textWidth
      CeremonyInk.scanline(
        y: origin.y + DotMatrix.height(dot: dot) + 6, centerX: centerX,
        width: underlineWidth, alpha: 0.9, color: glow, into: &ctx)
      CeremonyInk.caption(
        "NIGHTDRIVE HI-FI SYSTEM", centerX: centerX,
        y: origin.y + DotMatrix.height(dot: dot) + 12, alpha: 0.8,
        color: palette.dim, into: &ctx)
      CeremonyInk.brackets(
        in: CGRect(x: 3, y: 2, width: size.width - 6, height: size.height - 4),
        alpha: min(1, p * 3), color: palette.dim, into: &ctx)

    case .releasing(let p):
      let (origin, dot) = CeremonyInk.layout(text, in: size)
      let textWidth = DotMatrix.width(of: text, dot: dot)
      let residue = 1 - p
      let barX = CGFloat(p) * (size.width + 90) - 45
      CeremonyInk.ghostBand(
        origin: origin, columns: VFDDotFont.width(of: text), dot: dot, alpha: residue,
        color: palette.ghost, into: &ctx)
      var dots: [CeremonyInk.Dot] = []
      let pixelSize = DotMatrix.pixelSize(dot: dot)
      for cell in DeckCeremony.litDots(text) {
        let center = CeremonyInk.pixelCenter(
          origin: origin, column: cell.column, row: cell.row, dot: dot)
        let x = center.x
        let wiped = x < barX ? max(0, 1 - Double(barX - x) / 60) : 1
        dots.append(
          .init(center: center, size: pixelSize, alpha: wiped))
      }
      CeremonyInk.fill(dots, color: glow, into: &ctx)
      CeremonyInk.scanline(
        y: origin.y + DotMatrix.height(dot: dot) + 6, centerX: centerX,
        width: textWidth, alpha: 0.9 * Double(residue), color: glow, into: &ctx)
      CeremonyInk.caption(
        "NIGHTDRIVE HI-FI SYSTEM", centerX: centerX,
        y: origin.y + DotMatrix.height(dot: dot) + 12, alpha: 0.8 * Double(residue),
        color: palette.dim, into: &ctx)
      CeremonyInk.brackets(
        in: CGRect(x: 3, y: 2, width: size.width - 6, height: size.height - 4),
        alpha: Double(residue), color: palette.dim, into: &ctx)
      ctx.fill(
        Path(CGRect(x: barX - 9, y: 0, width: 18, height: size.height)),
        with: .color(glow.color.opacity(0.22 * Double(residue) + 0.1)))
      ctx.glowing(glow, radius: 6).fill(
        Path(CGRect(x: barX - 1.6, y: 0, width: 3.2, height: size.height)),
        with: .color(glow.color.opacity(0.95)))

    case .done:
      break
    }
  }
}
