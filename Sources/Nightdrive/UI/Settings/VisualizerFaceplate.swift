import SwiftUI

struct VisualizerFaceplate: View {
  let visualizer: (any Visualizer)?
  let modeName: String
  let tubeName: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.windowIsVisible) private var windowIsVisible
  @State private var struckAt = Date()

  private let aspect: CGFloat = 320.0 / 96.0
  private let strikeDuration: TimeInterval = 0.9

  private var visualizerIdentity: ObjectIdentifier? {
    visualizer.map(ObjectIdentifier.init)
  }

  var body: some View {
    VStack(spacing: 7) {
      TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) { timeline in
        let elapsed = timeline.date.timeIntervalSince(struckAt)
        glass(elapsed: elapsed)
      }
      .aspectRatio(aspect, contentMode: .fit)
      .frame(maxWidth: .infinity)

      silkscreen
    }
    .padding(11)
    .background(plate)
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          LinearGradient(
            colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
            startPoint: .top, endPoint: .bottom),
          lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Preview of \(modeName) on the \(tubeName) tube")
    .onAppear { restartPreview() }
    .onChange(of: visualizerIdentity) { _, _ in restartPreview() }
    .onChange(of: tubeName) { _, _ in restartPreview() }
  }

  private func glass(elapsed: TimeInterval) -> some View {
    ZStack {
      VFDGlass()
      Canvas { context, size in
        guard let visualizer else { return }
        var frame = VisualizerSample.frame(
          size: size, at: elapsed + 3, palette: VFDTheme.shared.palette,
          boot: boot(elapsed))
        frame.size = size
        visualizer.draw(frame, into: &context)
      }
      .padding(6)
      .drawingGroup()
      VFDScanlines()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }
  }

  private func boot(_ elapsed: TimeInterval) -> Double? {
    guard !reduceMotion, elapsed < strikeDuration else { return nil }
    return max(0, elapsed / strikeDuration)
  }

  private var silkscreen: some View {
    HStack(spacing: 8) {
      Text(modeName.uppercased())
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 8)
      Text(tubeName)
        .lineLimit(1)
        .layoutPriority(1)
    }
    .font(VFD.label(8.5, weight: .semibold))
    .kerning(1.1)
    .foregroundStyle(Color.white.opacity(0.34))
    .padding(.horizontal, 3)
    .frame(maxWidth: .infinity)
  }

  private var plate: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.165, green: 0.173, blue: 0.180),
            Color(red: 0.086, green: 0.090, blue: 0.098),
          ],
          startPoint: .top, endPoint: .bottom))
  }

  private func restartPreview() {
    visualizer?.reset()
    struckAt = Date()
  }
}

struct TubePicker: View {
  let selectedID: String
  let select: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(
        String(localized: "Tube Color"), subtitle: String(localized: "The inks every mode draws in."))

      HStack(spacing: 10) {
        ForEach(VisualizerColorway.all) { colorway in
          TubeChip(
            colorway: colorway,
            isSelected: colorway.id == selectedID,
            select: { select(colorway.id) })
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Tube color")
  }
}

private struct TubeChip: View {
  let colorway: VisualizerColorway
  let isSelected: Bool
  let select: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      VStack(spacing: 5) {
        glass
        Text(colorway.shortName)
          .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
          .kerning(0.5)
          .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
          .lineLimit(1)
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help(colorway.name)
    .accessibilityLabel(colorway.name)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }

  private var glass: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(red: 0.020, green: 0.028, blue: 0.032))
      TubeInks(palette: colorway.palette)
        .padding(5)
      VFDScanlines()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
    }
    .frame(height: 34)
    .frame(maxWidth: .infinity)
    .overlay {
      RoundedRectangle(cornerRadius: 7.5, style: .continuous)
        .strokeBorder(VFD.accent, lineWidth: isSelected ? 2 : 0)
        .padding(-2)
    }
    .overlay(alignment: .topTrailing) {
      if isSelected {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10))
          .foregroundStyle(VFD.accentInk, VFD.accent)
          .offset(x: 4, y: -4)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .shadow(
      color: colorway.palette.glow.color.opacity(isSelected ? 0.5 : (isHovering ? 0.3 : 0.16)),
      radius: isSelected ? 9 : 6
    )
    .scaleEffect(isHovering && !isSelected ? 1.03 : 1)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSelected)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
  }
}

private struct TubeInks: View {
  let palette: VisualizerPalette

  nonisolated private static let heights: [CGFloat] = [0.75, 1.0, 0.55, 0.85, 0.4, 0.65, 0.3]

  var body: some View {
    Canvas { context, size in
      let count = Self.heights.count
      let gap: CGFloat = 1.5
      let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)

      func bars(into context: inout GraphicsContext) {
        for (index, height) in Self.heights.enumerated() {
          let x = CGFloat(index) * (width + gap)
          let barHeight = size.height * height
          let rect = CGRect(x: x, y: size.height - barHeight, width: width, height: barHeight)
          context.fill(Path(rect), with: .color(palette.glow.color))
          let cap = CGRect(x: x, y: max(0, rect.minY - 3), width: width, height: 1.5)
          context.fill(Path(cap), with: .color(palette.amber.color))
        }
        context.fill(
          Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)),
          with: .color(palette.dim.color))
      }

      var glow = context
      glow.addFilter(.blur(radius: 2.2))
      glow.opacity = 0.85
      glow.drawLayer { bars(into: &$0) }
      bars(into: &context)
    }
    .allowsHitTesting(false)
  }
}
