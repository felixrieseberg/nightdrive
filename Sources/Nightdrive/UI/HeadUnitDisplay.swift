import SwiftUI

enum VFD {
  @MainActor static var palette: VisualizerPalette { VFDTheme.shared.palette }
  @MainActor static var glow: Color { palette.glow.color }
  @MainActor static var amber: Color { palette.amber.color }
  @MainActor static var dim: Color { palette.dim.color }
  @MainActor static var ghost: Color { palette.ghost.color }

  static let maskInk = VisualizerColor(red: 0.03, green: 0.04, blue: 0.05)
  static let mask = maskInk.color

  @MainActor static var accent: Color { glow }

  @MainActor static var accentInk: Color { ink(on: palette.glow).color }

  static func ink(on fill: VisualizerColor) -> VisualizerColor {
    let paper = VisualizerColor(red: 1, green: 1, blue: 1)
    return fill.contrastRatio(against: maskInk) >= fill.contrastRatio(against: paper)
      ? maskInk : paper
  }

  static func label(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  static func timeText(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

struct LitButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Key(configuration: configuration)
  }

  private struct Key: View {
    let configuration: LitButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 7, style: .continuous) }

    var body: some View {
      configuration.label
        .fontWeight(.semibold)
        .foregroundStyle(isEnabled ? VFD.accentInk : Color.white.opacity(0.35))
        .padding(.horizontal, 13)
        .padding(.vertical, 5)
        .background {
          shape
            .fill(isEnabled ? VFD.accent : Color.white.opacity(0.14))
            .overlay {
              shape.fill(
                LinearGradient(
                  colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
            }
            .shadow(color: isEnabled ? VFD.accent.opacity(0.35) : .clear, radius: 6, y: 1)
        }
        .brightness(configuration.isPressed ? -0.12 : 0)
        .contentShape(shape)
    }
  }
}

extension ButtonStyle where Self == LitButtonStyle {
  static var lit: LitButtonStyle { LitButtonStyle() }
}

struct HeadUnitDisplay: View {
  let player: PlayerController
  let syncState: SyncState
  var deckOpen = false
  var showSyncErrorDetails: (() -> Void)?

  @State private var faceplateWidth: CGFloat = 0

  var body: some View {
    interactiveDisplay
      .coordinateSpace(name: "faceplate")
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { faceplateWidth = $0 }
      .notWindowDraggable()
      .gesture(
        seekGesture,
        isEnabled: showSyncErrorDetails == nil && player.currentTrack != nil && player.duration > 0
      )
      .frame(minWidth: 200)
      .frame(height: 44)
  }

  @ViewBuilder
  private var interactiveDisplay: some View {
    if let showSyncErrorDetails {
      Button(action: showSyncErrorDetails) {
        display
      }
      .buttonStyle(.plain)
      .help("Show Sync Error Details")
      .accessibilityLabel("Show Sync Error Details")
    } else {
      display
    }
  }

  private var display: some View {
    ZStack {
      VFDGlass()
      content
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
  }

  // MARK: - Content states

  @ViewBuilder
  private var content: some View {
    switch syncState {
    case .syncing(let progress):
      syncing(progress)
    case .failed(let message):
      twoLine(
        top: Marquee(text: "SYNC ERROR", color: VFD.amber),
        topRight: BlinkingText(text: "ERR", color: VFD.amber),
        bottom: AnyView(
          Marquee(text: message.uppercased(), color: VFD.amber.opacity(0.7), size: 8.5)))
    default:
      if let track = player.currentTrack {
        playing(track)
      } else if case .finished(let result) = syncState {
        twoLine(
          top: Marquee(text: "SYNC COMPLETE", color: VFD.glow),
          topRight: Text("OK")
            .font(VFD.label(11, weight: .bold))
            .kerning(2)
            .foregroundStyle(VFD.glow)
            .vfdGlow(),
          bottom: AnyView(
            Text(summary(result))
              .font(VFD.label(8.5))
              .kerning(1)
              .foregroundStyle(VFD.dim)
              .lineLimit(1)
              .frame(maxWidth: .infinity, alignment: .leading)))
      } else {
        idle
      }
    }
  }

  private func playing(_ track: LibraryTrack) -> some View {
    let title = [track.displayTitle, track.artist]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
      .uppercased()
    return VStack(spacing: 3) {
      HStack(alignment: .center, spacing: 10) {
        Marquee(text: title, color: VFD.glow, scrolling: player.isPlaying)
        if deckOpen {
          SevenSegmentClock(blinking: player.isPlaying)
        } else {
          RemainingTimeReadout(player: player)
        }
      }
      HStack(spacing: 8) {
        Text(String(format: "TRK %02d", player.currentTrackNumber ?? 0))
          .font(VFD.label(8))
          .kerning(1)
          .foregroundStyle(VFD.dim)
        Text(track.url.pathExtension.uppercased())
          .font(VFD.label(7, weight: .bold))
          .foregroundStyle(VFD.mask)
          .padding(.horizontal, 3)
          .padding(.vertical, 0.5)
          .background(VFD.dim, in: RoundedRectangle(cornerRadius: 2))
        LiveSpectrumBars(player: player)
      }
    }
  }

  private var idle: some View {
    VStack(spacing: 3) {
      HStack(spacing: 10) {
        Text("NIGHTDRIVE")
          .font(VFD.label(11))
          .kerning(3)
          .foregroundStyle(VFD.glow)
          .vfdGlow()
        Spacer(minLength: 0)
        SevenSegmentClock(blinking: false)
      }
      HStack(spacing: 8) {
        Text("READY")
          .font(VFD.label(8))
          .kerning(1)
          .foregroundStyle(VFD.dim)
        LiveSpectrumBars(player: player, active: false)
      }
    }
  }

  private func syncing(_ progress: SyncProgress) -> some View {
    VStack(spacing: 3) {
      HStack(spacing: 10) {
        Marquee(text: progress.detail.uppercased(), color: VFD.glow)
        Text(verbatim: "\(progress.step)/\(progress.totalSteps)")
          .font(VFD.label(10))
          .foregroundStyle(VFD.glow)
          .vfdGlow()
      }
      HStack(spacing: 8) {
        BlinkingText(text: "SYNC", color: VFD.glow, size: 8)
        BlockProgressBar(fraction: progress.fraction)
      }
    }
  }

  private func twoLine(top: Marquee, topRight: some View, bottom: AnyView) -> some View {
    VStack(spacing: 3) {
      HStack(spacing: 10) {
        top
        topRight
      }
      bottom
    }
  }

  // MARK: - Helpers

  private var seekGesture: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("faceplate"))
      .onChanged { value in
        guard faceplateWidth > 0 else { return }
        player.seek(to: (value.location.x - 12) / (faceplateWidth - 24))
      }
  }

  private func summary(_ result: SyncResult) -> String {
    SyncDetailsModel(result: result).headUnitSummary
  }
}

/// Leaf views that confine the player's fast-changing observations (elapsed
/// at 2 Hz, spectrum at 24 Hz) to the smallest possible subtree. Reading them
/// in a large body re-commits that body's whole layer tree at playback rate,
/// which keeps over a hundred MiB of window render surfaces resident.
///
/// While the window is hidden they switch to untracked reads: with no live
/// observation the window stops re-rendering altogether, letting the system
/// reclaim its render surfaces. The `windowIsVisible` flip re-renders the
/// view with fresh values when the window reappears.
struct RemainingTimeReadout: View {
  let player: PlayerController

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    let elapsed = windowIsVisible ? player.elapsed : player.untrackedElapsed
    let remaining = max(player.duration - elapsed, 0)
    SevenSegmentText(text: "-" + VFD.timeText(remaining), color: VFD.glow, height: 13)
  }
}

struct LiveSpectrumBars: View {
  let player: PlayerController
  var active = true

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    let playing = active && player.isPlaying
    let spectrum = windowIsVisible ? player.spectrum : player.untrackedSpectrum
    let peaks = windowIsVisible ? player.spectrumPeaks : player.untrackedSpectrumPeaks
    SpectrumBars(
      spectrum: DemoSimulation.spectrum(spectrum, active: playing),
      peaks: DemoSimulation.peaks(peaks, active: playing),
      active: playing)
  }
}

extension View {
  @MainActor func vfdGlow(_ color: Color? = nil) -> some View {
    shadow(color: (color ?? VFD.glow).opacity(0.8), radius: 2.5)
  }
}

// MARK: - Glass

struct VFDGlass: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.030, green: 0.040, blue: 0.045),
            Color(red: 0.012, green: 0.018, blue: 0.022),
          ],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .fill(
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0.55), location: 0),
                .init(color: .clear, location: 0.28),
              ],
              startPoint: .top, endPoint: .bottom))
      )
      .overlay(VFDScanlines().clipShape(RoundedRectangle(cornerRadius: 8)))
      .overlay(
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(Color.black.opacity(0.95), lineWidth: 1.5)
      )
      .background(
        RoundedRectangle(cornerRadius: 9)
          .fill(Color.white.opacity(0.10))
          .offset(y: 1.2)
          .blur(radius: 0.4))
  }
}

struct VFDScanlines: View {
  var body: some View {
    Canvas { ctx, size in
      var y: CGFloat = 1
      while y < size.height {
        ctx.fill(
          Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
          with: .color(.black.opacity(0.14)))
        y += 3
      }
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Marquee

struct Marquee: View {
  let text: String
  let color: Color
  var size: CGFloat = 11
  var scrolling = true

  @Environment(\.windowIsVisible) private var windowIsVisible
  @State private var textWidth: CGFloat = 0

  private var label: some View {
    Text(text)
      .font(VFD.label(size))
      .kerning(1.2)
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(color)
      .vfdGlow(color)
  }

  var body: some View {
    GeometryReader { geo in
      let gap: CGFloat = 48
      if textWidth > geo.size.width {
        TimelineView(
          .animation(
            minimumInterval: 1.0 / 30.0,
            paused: !scrolling || !windowIsVisible)
        ) { timeline in
          let period = textWidth + gap
          let offset = (timeline.date.timeIntervalSinceReferenceDate * 24)
            .truncatingRemainder(dividingBy: period)
          HStack(spacing: gap) {
            label
            label
          }
          .offset(x: -offset)
        }
        .frame(width: geo.size.width, alignment: .leading)
        .clipped()
        .mask(
          HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
              .frame(width: 6)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
              .frame(width: 6)
          })
      } else {
        label.frame(width: geo.size.width, alignment: .leading)
      }
    }
    .frame(height: size + 4)
    .background(
      label.hidden()
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { width in
          textWidth = width
        }
        .frame(width: 0)
        .clipped()
    )
  }
}

// MARK: - Seven-segment digits

struct SevenSegmentText: View {
  let text: String
  let color: Color
  var height: CGFloat = 13
  var colonLit = true

  private static let segments: [Character: Set<Int>] = [
    "0": [0, 1, 2, 3, 4, 5], "1": [1, 2], "2": [0, 1, 6, 4, 3],
    "3": [0, 1, 6, 2, 3], "4": [5, 6, 1, 2], "5": [0, 5, 6, 2, 3],
    "6": [0, 5, 6, 4, 2, 3], "7": [0, 1, 2], "8": [0, 1, 2, 3, 4, 5, 6],
    "9": [0, 1, 2, 3, 5, 6], "-": [6],
  ]

  var body: some View {
    let ghost = VFD.ghost
    return Canvas { ctx, size in
      let inset = size.height * 0.08
      let h = size.height - inset * 2
      let digitW = h * 0.58
      let thickness = h * 0.13
      let colonW = h * 0.28
      let spacing = h * 0.22
      var x: CGFloat = inset

      // Lit and unlit geometry accumulate into two paths so each frame
      // needs a single glow-filtered layer instead of one per segment.
      var litShapes = Path()
      var ghostShapes = Path()

      func segmentPath(_ index: Int, at originX: CGFloat) -> Path {
        let w = digitW
        let points: [(CGPoint, CGPoint)] = [
          (CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0)),  // top
          (CGPoint(x: w, y: 0), CGPoint(x: w, y: h / 2)),  // top-right
          (CGPoint(x: w, y: h / 2), CGPoint(x: w, y: h)),  // bottom-right
          (CGPoint(x: 0, y: h), CGPoint(x: w, y: h)),  // bottom
          (CGPoint(x: 0, y: h / 2), CGPoint(x: 0, y: h)),  // bottom-left
          (CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h / 2)),  // top-left
          (CGPoint(x: 0, y: h / 2), CGPoint(x: w, y: h / 2)),  // middle
        ]
        let (a, b) = points[index]
        func slanted(_ p: CGPoint) -> CGPoint {
          CGPoint(x: originX + p.x + (h - p.y) * 0.12, y: p.y + inset)
        }
        var path = Path()
        path.move(to: slanted(a))
        path.addLine(to: slanted(b))
        return path.strokedPath(StrokeStyle(lineWidth: thickness, lineCap: .round))
      }

      for char in text {
        if char == ":" {
          let cx = x + colonW / 2
          for dotY in [h * 0.3, h * 0.72] {
            let dot = CGRect(
              x: cx + (h - dotY) * 0.12 - thickness / 2,
              y: dotY + inset - thickness / 2,
              width: thickness, height: thickness)
            if colonLit {
              litShapes.addEllipse(in: dot)
            } else {
              ghostShapes.addEllipse(in: dot)
            }
          }
          x += colonW + spacing
          continue
        }
        let lit = Self.segments[char] ?? []
        for index in 0..<7 {
          let path = segmentPath(index, at: x)
          if lit.contains(index) {
            litShapes.addPath(path)
          } else {
            ghostShapes.addPath(path)
          }
        }
        x += digitW + h * 0.12 + spacing
      }

      ctx.fill(ghostShapes, with: .color(ghost))
      if !litShapes.isEmpty {
        var glow = ctx
        glow.addFilter(.shadow(color: color.opacity(0.8), radius: 2))
        glow.fill(litShapes, with: .color(color))
      }
    }
    .frame(width: width, height: height)
  }

  private var width: CGFloat {
    let inset = height * 0.08
    let h = height - inset * 2
    var w: CGFloat = inset * 2
    for char in text {
      w += char == ":" ? h * 0.28 + h * 0.22 : h * 0.58 + h * 0.12 + h * 0.22
    }
    return max(w - h * 0.22, 1)
  }
}

struct SevenSegmentClock: View {
  var height: CGFloat = 13

  /// Whether the colon blinks at 1 Hz. Any recurring redraw of a visible
  /// window — however small the invalidated region — keeps roughly 130 MiB
  /// of window render surfaces resident, so callers enable blinking only
  /// while something else (spectrum, marquee, visualizer) is already
  /// animating the window. A still window ticks once per minute with a
  /// steady colon, and the system reclaims the surfaces between ticks.
  var blinking = true

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    Group {
      if windowIsVisible && blinking {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          clock(at: timeline.date, blinking: true)
        }
      } else if windowIsVisible {
        TimelineView(.everyMinute) { timeline in
          clock(at: timeline.date, blinking: false)
        }
      } else {
        clock(at: .now, blinking: false)
      }
    }
  }

  private func clock(at date: Date, blinking: Bool) -> some View {
    let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
    return SevenSegmentText(
      text: String(format: "%d:%02d", comps.hour ?? 0, comps.minute ?? 0),
      color: VFD.glow, height: height,
      colonLit: !blinking || (comps.second ?? 0).isMultiple(of: 2))
  }
}

// MARK: - Spectrum bars

func sampledBand(_ values: [Float], bar: Int, of barCount: Int, active: Bool) -> Double {
  guard active, values.count > 1, barCount > 1 else { return 0 }
  let pos = Double(bar) * Double(values.count - 1) / Double(barCount - 1)
  let lo = Int(pos)
  let hi = min(values.count - 1, lo + 1)
  let frac = pos - Double(lo)
  return Double(values[lo]) * (1 - frac) + Double(values[hi]) * frac
}

struct SpectrumBars: View {
  let spectrum: [Float]
  let peaks: [Float]
  let active: Bool

  var body: some View {
    let (glowInk, amberInk, dimInk, ghostInk) = (VFD.glow, VFD.amber, VFD.dim, VFD.ghost)
    return Canvas { ctx, size in
      let barCount = max(14, Int(size.width / 14))
      let cellRows = 5
      let gap: CGFloat = 2
      let barWidth = (size.width - CGFloat(barCount - 1) * gap) / CGFloat(barCount)
      let cellHeight = (size.height - CGFloat(cellRows - 1)) / CGFloat(cellRows)

      // One path per ink so the whole board needs at most two filtered
      // layers per frame; a filter layer per cell grows the GPU surface
      // pool by hundreds of megabytes during playback.
      var ghostCells = Path()
      var glowCells = Path()
      var amberCells = Path()
      var peakMarks = Path()

      for bar in 0..<barCount {
        let x = CGFloat(bar) * (barWidth + gap)
        let v = sampledBand(spectrum, bar: bar, of: barCount, active: active)
        let litRows = Int((v * Double(cellRows)).rounded())
        let peak = sampledBand(peaks, bar: bar, of: barCount, active: active)
        let peakRow = Int((peak * Double(cellRows)).rounded())

        for row in 0..<cellRows {
          let y = size.height - CGFloat(row + 1) * cellHeight - CGFloat(row)
          let cell = CGRect(x: x, y: y, width: barWidth, height: cellHeight)
          if row < litRows {
            if row == cellRows - 1 {
              amberCells.addRect(cell)
            } else {
              glowCells.addRect(cell)
            }
          } else {
            ghostCells.addRect(cell)
          }
        }
        if peakRow > litRows, peakRow > 0 {
          let y = size.height - CGFloat(peakRow) * cellHeight - CGFloat(peakRow - 1) - 1
          peakMarks.addRect(CGRect(x: x, y: y, width: barWidth, height: 1.5))
        }
      }

      ctx.fill(ghostCells, with: .color(ghostInk))
      if !glowCells.isEmpty {
        var glow = ctx
        glow.addFilter(.shadow(color: glowInk.opacity(0.7), radius: 1.5))
        glow.fill(glowCells, with: .color(glowInk))
      }
      if !amberCells.isEmpty {
        var glow = ctx
        glow.addFilter(.shadow(color: glowInk.opacity(0.7), radius: 1.5))
        glow.fill(amberCells, with: .color(amberInk))
      }
      ctx.fill(peakMarks, with: .color(dimInk))
    }
    .frame(height: 12)
  }
}

// MARK: - Small pieces

struct BlinkingText: View {
  let text: String
  let color: Color
  var size: CGFloat = 10

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    Group {
      if windowIsVisible {
        TimelineView(.periodic(from: .now, by: 0.6)) { timeline in
          label(at: timeline.date)
        }
      } else {
        label(at: .now)
      }
    }
  }

  private func label(at date: Date) -> some View {
    let on = Int(date.timeIntervalSinceReferenceDate / 0.6).isMultiple(of: 2)
    return Text(text)
      .font(VFD.label(size, weight: .bold))
      .kerning(1.5)
      .foregroundStyle(on ? color : color.opacity(0.25))
      .vfdGlow(on ? color : .clear)
  }
}

struct BlockProgressBar: View {
  let fraction: Double
  var cells = 24
  var height: CGFloat = 8

  var body: some View {
    let (glowInk, ghostInk) = (VFD.glow, VFD.ghost)
    return Canvas { ctx, size in
      let cells = self.cells
      let gap: CGFloat = 2
      let cellWidth = (size.width - CGFloat(cells - 1) * gap) / CGFloat(cells)
      let lit = Int((fraction * Double(cells)).rounded())
      for i in 0..<cells {
        let rect = CGRect(
          x: CGFloat(i) * (cellWidth + gap), y: 0, width: cellWidth, height: size.height)
        if i < lit {
          var glow = ctx
          glow.addFilter(.shadow(color: glowInk.opacity(0.7), radius: 1.5))
          glow.fill(Path(rect), with: .color(glowInk))
        } else {
          ctx.fill(Path(rect), with: .color(ghostInk))
        }
      }
    }
    .frame(height: height)
  }
}
