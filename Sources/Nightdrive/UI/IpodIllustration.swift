import SwiftUI

enum IpodIllustrationKind {
  case firstOrSecondGeneration
  case thirdGeneration
  case fourthGeneration
  case videoOrClassic
  case mini
  case nanoThin
  case nanoFat
  case nanoCurved
  case shuffleStick
  case shuffleClip
  case shuffleBar

  private static let prefixes: [(Set<String>, IpodIllustrationKind)] = [
    (
      [
        "M8513", "M8541", "M8697", "M8709",  // 1G
        "M8737", "M8740", "M8738", "M8741",  // 2G
      ], .firstOrSecondGeneration
    ),
    (["M8946", "M8948", "M8976", "M9244"], .thirdGeneration),
    (
      [
        "M9160", "M9245", "M9268", "M9282",  // 4G monochrome
        "M9585", "M9586", "M9829", "M9830", "MA079", "MA127",  // photo / color
      ], .fourthGeneration
    ),
    (
      [
        "MA002", "MA003", "MA146", "MA147", "MA444", "MA446", "MA448", "MA450",  // 5G video
        "MB029", "MB035", "MB145", "MB147", "MB150", "MB562", "MB565",  // classic
        "MC293", "MC297",
      ], .videoOrClassic
    ),
    (
      [
        "M9435", "M9436", "M9437",  // mini 1G
        "M9800", "M9801", "M9802", "M9803", "M9804", "M9805", "M9806", "M9807",  // mini 2G
      ], .mini
    ),
    (
      [
        "MA004", "MA005", "MA099", "MA107", "MA350", "MA352",  // nano 1G
        "MA426", "MA428", "MA477", "MA487", "MA489", "MA497",  // nano 2G
      ], .nanoThin
    ),
    (["MA978", "MA980", "MB249", "MB253", "MB257", "MB261", "MB453"], .nanoFat),
    (
      [
        "MB598", "MB732", "MB735", "MB739", "MB742", "MB745", "MB748", "MB754",  // nano 4G
        "MB903", "MB905", "MB907", "MB909", "MB911",
        "MC027", "MC031", "MC034", "MC037", "MC040", "MC046", "MC049", "MC050",  // nano 5G
        "MC060", "MC062", "MC064", "MC066", "MC068", "MC072", "MC075",
      ], .nanoCurved
    ),
    (["M9724", "M9725", "MA133"], .shuffleStick),
    (
      [
        "MA564", "MA947",
        "MB225", "MB227", "MB228", "MB229", "MB233",
        "MB518", "MB520", "MB522", "MB524", "MB526",
        "MC584", "MC585", "MC749", "MC750", "MC751",  // shuffle 4G
        "MD773", "MD774", "MD775", "MD776", "MD777", "MD778", "MD779", "MD780",
        "ME949", "MKM72", "MKM92", "MKME2", "MKMG2", "MKMJ2", "MKML2",
      ], .shuffleClip
    ),
    (
      [
        "MB867", "MC164", "MC303", "MC306", "MC307", "MC323",  // shuffle 3G
        "MC328", "MC331", "MC381", "MC384", "MC387",
      ], .shuffleBar
    ),
  ]

  init(modelNumber: String?, family: IpodDeviceFamily) {
    if let model = modelNumber?.uppercased() {
      for (models, kind) in Self.prefixes where models.contains(where: model.hasPrefix) {
        self = kind
        return
      }
    }
    switch family {
    case .shuffle, .modernShuffle: self = .shuffleClip
    case .firstOrSecondGeneration: self = .firstOrSecondGeneration
    case .thirdGenerationOrLater: self = .fourthGeneration
    }
  }

  var aspectRatio: CGFloat {
    switch self {
    case .firstOrSecondGeneration, .thirdGeneration, .fourthGeneration, .videoOrClassic:
      0.60
    case .mini: 0.57
    case .nanoThin: 0.44
    case .nanoFat: 0.74
    case .nanoCurved: 0.43
    case .shuffleStick: 0.30
    case .shuffleClip: 1.53
    case .shuffleBar: 0.44
    }
  }
}

struct IpodIllustration: View {
  let kind: IpodIllustrationKind

  init(kind: IpodIllustrationKind) {
    self.kind = kind
  }

  init(device: IpodDevice) {
    self.init(kind: IpodIllustrationKind(modelNumber: device.modelNumber, family: device.family))
  }

  var body: some View {
    let palette = VFD.palette
    let kind = kind
    Canvas { ctx, size in
      let aspect = kind.aspectRatio
      var body = CGRect(origin: .zero, size: size)
      if body.width / body.height > aspect {
        let width = body.height * aspect
        body = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: body.height)
      } else {
        let height = body.width / aspect
        body = CGRect(x: 0, y: (size.height - height) / 2, width: body.width, height: height)
      }
      var wire = IpodWireframe(body: body, palette: palette)
      wire.draw(kind, in: &ctx)
    }
    .accessibilityHidden(true)
  }
}

private struct IpodWireframe {
  let body: CGRect
  let palette: VisualizerPalette

  private var stroke: CGFloat { max(1, body.width / 60) }

  private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: body.minX + x * body.width, y: body.minY + y * body.height)
  }

  private func rect(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat) -> CGRect {
    CGRect(
      x: body.minX + x0 * body.width,
      y: body.minY + y0 * body.height,
      width: (x1 - x0) * body.width,
      height: (y1 - y0) * body.height)
  }

  private func circle(center: CGPoint, radius: CGFloat) -> Path {
    Path(
      ellipseIn: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
  }

  private func outline(_ path: Path, in ctx: inout GraphicsContext) {
    ctx.fill(path, with: .color(palette.ghost.color))
    ctx.glowing(palette.glow, radius: 2)
      .stroke(path, with: .color(palette.glow.color.opacity(0.9)), lineWidth: stroke)
  }

  private func detail(_ path: Path, in ctx: inout GraphicsContext) {
    ctx.stroke(path, with: .color(palette.dim.color), lineWidth: stroke)
  }

  private func chassis(cornerFraction: CGFloat, in ctx: inout GraphicsContext) {
    let path = Path(roundedRect: body, cornerRadius: cornerFraction * body.width)
    outline(path, in: &ctx)
  }

  private func screen(x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, in ctx: inout GraphicsContext) {
    let frame = rect(x0: x0, y0: y0, x1: x1, y1: y1)
    let path = Path(roundedRect: frame, cornerRadius: body.width * 0.02)
    ctx.glowing(palette.glow, radius: 1.5)
      .stroke(path, with: .color(palette.glow.color.opacity(0.9)), lineWidth: stroke)
    var lines = Path()
    let inset = frame.insetBy(dx: frame.width * 0.14, dy: frame.height * 0.22)
    for index in 0..<3 {
      let y = inset.minY + inset.height * CGFloat(index) / 2
      lines.move(to: CGPoint(x: inset.minX, y: y))
      lines.addLine(to: CGPoint(x: inset.minX + inset.width * (index == 0 ? 1.0 : 0.7), y: y))
    }
    ctx.stroke(lines, with: .color(palette.dim.color), lineWidth: stroke * 0.8)
  }

  private func wheel(
    center: CGPoint, radius: CGFloat, marks: Bool = true, in ctx: inout GraphicsContext
  ) {
    ctx.glowing(palette.glow, radius: 2)
      .stroke(
        circle(center: center, radius: radius),
        with: .color(palette.glow.color.opacity(0.9)), lineWidth: stroke)
    detail(circle(center: center, radius: radius * 0.36), in: &ctx)
    guard marks else { return }
    var dots = Path()
    let markRadius = radius * 0.72
    let dot = stroke * 0.9
    for angle in stride(from: 0.0, to: 360.0, by: 90.0) {
      let radians = angle * .pi / 180
      let point = CGPoint(
        x: center.x + markRadius * CGFloat(cos(radians)),
        y: center.y + markRadius * CGFloat(sin(radians)))
      dots.addEllipse(
        in: CGRect(x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2))
    }
    ctx.fill(dots, with: .color(palette.dim.color))
  }

  mutating func draw(_ kind: IpodIllustrationKind, in ctx: inout GraphicsContext) {
    switch kind {
    case .firstOrSecondGeneration:
      chassis(cornerFraction: 0.12, in: &ctx)
      screen(x0: 0.16, y0: 0.09, x1: 0.84, y1: 0.36, in: &ctx)
      let center = point(0.5, 0.68)
      detail(circle(center: center, radius: 0.40 * body.width), in: &ctx)
      wheel(center: center, radius: 0.27 * body.width, marks: false, in: &ctx)
    case .thirdGeneration:
      chassis(cornerFraction: 0.12, in: &ctx)
      screen(x0: 0.16, y0: 0.09, x1: 0.84, y1: 0.36, in: &ctx)
      var buttons = Path()
      for index in 0..<4 {
        let x = 0.20 + 0.60 * CGFloat(index) / 3
        let center = point(x, 0.445)
        let r = body.width * 0.045
        buttons.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
      }
      detail(buttons, in: &ctx)
      wheel(center: point(0.5, 0.72), radius: 0.26 * body.width, marks: false, in: &ctx)
    case .fourthGeneration:
      chassis(cornerFraction: 0.12, in: &ctx)
      screen(x0: 0.15, y0: 0.09, x1: 0.85, y1: 0.38, in: &ctx)
      wheel(center: point(0.5, 0.70), radius: 0.30 * body.width, in: &ctx)
    case .videoOrClassic:
      chassis(cornerFraction: 0.10, in: &ctx)
      screen(x0: 0.11, y0: 0.08, x1: 0.89, y1: 0.45, in: &ctx)
      wheel(center: point(0.5, 0.735), radius: 0.29 * body.width, in: &ctx)
    case .mini:
      chassis(cornerFraction: 0.26, in: &ctx)
      screen(x0: 0.15, y0: 0.12, x1: 0.85, y1: 0.34, in: &ctx)
      wheel(center: point(0.5, 0.67), radius: 0.33 * body.width, in: &ctx)
    case .nanoThin:
      chassis(cornerFraction: 0.16, in: &ctx)
      screen(x0: 0.14, y0: 0.08, x1: 0.86, y1: 0.32, in: &ctx)
      wheel(center: point(0.5, 0.65), radius: 0.36 * body.width, in: &ctx)
    case .nanoFat:
      chassis(cornerFraction: 0.14, in: &ctx)
      screen(x0: 0.10, y0: 0.09, x1: 0.90, y1: 0.52, in: &ctx)
      wheel(center: point(0.5, 0.765), radius: 0.20 * body.width, in: &ctx)
    case .nanoCurved:
      chassis(cornerFraction: 0.12, in: &ctx)
      screen(x0: 0.13, y0: 0.08, x1: 0.87, y1: 0.42, in: &ctx)
      wheel(center: point(0.5, 0.685), radius: 0.34 * body.width, in: &ctx)
    case .shuffleStick:
      chassis(cornerFraction: 0.16, in: &ctx)
      wheel(center: point(0.5, 0.32), radius: 0.38 * body.width, in: &ctx)
      var seam = Path()
      seam.move(to: point(0.08, 0.70))
      seam.addLine(to: point(0.92, 0.70))
      detail(seam, in: &ctx)
      detail(
        Path(
          roundedRect: rect(x0: 0.38, y0: 0.84, x1: 0.62, y1: 0.90),
          cornerRadius: body.width * 0.04),
        in: &ctx)
    case .shuffleClip:
      chassis(cornerFraction: 0.06, in: &ctx)
      var clip = Path()
      clip.move(to: point(0.08, 0.15))
      clip.addLine(to: point(0.92, 0.15))
      detail(clip, in: &ctx)
      wheel(
        center: point(0.5, 0.56), radius: 0.36 * body.height, in: &ctx)
    case .shuffleBar:
      chassis(cornerFraction: 0.10, in: &ctx)
      // Three-position switch on the face near the top edge.
      detail(
        Path(
          roundedRect: rect(x0: 0.34, y0: 0.035, x1: 0.66, y1: 0.065),
          cornerRadius: body.width * 0.02),
        in: &ctx)
      // The clip covers most of the front of the buttonless 3G,
      // with an oblong slot cut out near its top.
      detail(
        Path(
          roundedRect: rect(x0: 0.12, y0: 0.10, x1: 0.88, y1: 0.96),
          cornerRadius: body.width * 0.08),
        in: &ctx)
      detail(
        Path(
          roundedRect: rect(x0: 0.24, y0: 0.135, x1: 0.76, y1: 0.185),
          cornerRadius: body.width * 0.05),
        in: &ctx)
    }
  }
}
