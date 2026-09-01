import CoreImage
import SwiftUI

struct DeckPanel: View {
  static let glassHeight: CGFloat = DeckMechanism.faceHeight
  static let strikeDuration: TimeInterval = 0.16 + 0.05 + 0.08 + 0.05 + 0.07 + 0.09

  @Bindable var app: AppState
  let open: Bool
  let powered: Bool
  var stretchesGlass = false
  var showsStatusColumn = true
  var scalesArtwork = false

  @Environment(\.windowIsVisible) private var windowIsVisible
  private var player: PlayerController { app.player }

  @State private var bootStart: Date?
  @State private var booting = false
  @State private var greeted = false
  @State private var sweepStart: Date?
  @State private var struck = false
  @State private var phosphorArt: NSImage?

  var body: some View {
    panel
      .frame(minHeight: Self.glassHeight, maxHeight: stretchesGlass ? .infinity : Self.glassHeight)
      .contentShape(Rectangle())
      .contextMenu { VisualizerMenuItems(app: app) }
      .onChange(of: powered, initial: true) { _, isPowered in
        if isPowered {
          struck = false
          greeted =
            app.deck.greetedThisLaunch
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
          sweepStart = nil
          bootStart = .now
          booting = true
          app.deck.bootStart = bootStart
        } else {
          bootStart = nil
          booting = false
          struck = false
          greeted = false
          sweepStart = nil
          app.deck.bootStart = nil
        }
      }
      .task(id: bootStart) {
        guard bootStart != nil else { return }
        do {
          try await Task.sleep(for: .seconds(Self.strikeDuration))
        } catch {
          return
        }
        guard !Task.isCancelled, powered else { return }
        struck = true
        if !greeted {
          do {
            try await Task.sleep(for: .seconds(DeckCeremony.greetingDuration))
          } catch {
            return
          }
          guard !Task.isCancelled, powered else { return }
          greeted = true
          app.deck.greetedThisLaunch = true
        }
        sweepStart = .now
        do {
          try await Task.sleep(for: .seconds(1.0))
        } catch {
          return
        }
        guard !Task.isCancelled, powered else { return }
        booting = false
      }
      .onChange(of: player.artwork, initial: true) { _, art in
        phosphorArt = art.flatMap { Self.phosphor($0, tint: VFD.palette.glow) }
      }
      .onChange(of: VFDTheme.shared.colorway) { _, _ in
        phosphorArt = player.artwork.flatMap { Self.phosphor($0, tint: VFD.palette.glow) }
      }
  }

  @ViewBuilder
  private var panel: some View {
    if scalesArtwork {
      GeometryReader { geometry in
        surface(artworkSize: Self.artworkSize(in: geometry.size))
      }
    } else {
      surface(artworkSize: Self.naturalArtworkSize)
    }
  }

  private func surface(artworkSize: CGFloat) -> some View {
    let holdsBrightness = struck
    return ZStack {
      VFDGlass()
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
      content(artworkSize: artworkSize)
        .padding(.horizontal, 24)
        .padding(.vertical, 17)
        .keyframeAnimator(initialValue: 0.0, trigger: bootStart) { view, brightness in
          view.opacity(holdsBrightness ? 1 : brightness)
        } keyframes: { _ in
          KeyframeTrack {
            LinearKeyframe(0.0, duration: 0.16)
            LinearKeyframe(1.0, duration: 0.05)
            LinearKeyframe(0.25, duration: 0.08)
            LinearKeyframe(1.0, duration: 0.05)
            LinearKeyframe(0.6, duration: 0.07)
            LinearKeyframe(1.0, duration: 0.09)
          }
        }
        .opacity(powered ? 1 : 0)
    }
  }

  static let naturalArtworkSize: CGFloat = 80
  static let maximumArtworkSize: CGFloat = 200

  static func artworkSize(in panelSize: CGSize) -> CGFloat {
    let availableHeight = max(0, panelSize.height - 42)
    let availableWidth = max(0, panelSize.width - 48)
    return min(maximumArtworkSize, availableHeight, availableWidth / 4)
  }

  /// One CIContext for all phosphor renders; creating a context per track
  /// change transiently grows the GPU surface pool by tens of megabytes.
  private static let phosphorContext = CIContext()

  /// The artwork tile draws at up to 200 pt in the resized mini player;
  /// rendering the monochrome filter at that pixel size instead of the cover's
  /// full resolution keeps both the kept image and the render transient small.
  private static let phosphorMaxPixels = maximumArtworkSize

  private static func phosphor(_ image: NSImage, tint: VisualizerColor) -> NSImage? {
    guard var ci = ciImage(from: image),
      let filter = CIFilter(name: "CIColorMonochrome")
    else { return nil }
    let longestSide = max(ci.extent.width, ci.extent.height)
    if longestSide > phosphorMaxPixels {
      let scale = phosphorMaxPixels / longestSide
      ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
    filter.setValue(ci, forKey: kCIInputImageKey)
    filter.setValue(
      CIColor(red: tint.red, green: tint.green, blue: tint.blue), forKey: kCIInputColorKey)
    filter.setValue(1.0, forKey: kCIInputIntensityKey)
    guard let output = filter.outputImage,
      let cg = phosphorContext.createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: cg, size: image.size)
  }

  private static func ciImage(from image: NSImage) -> CIImage? {
    if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
      return CIImage(cgImage: cg)
    }
    guard let tiff = image.tiffRepresentation else { return nil }
    return CIImage(data: tiff)
  }

  @ViewBuilder
  private func content(artworkSize: CGFloat) -> some View {
    if !greeted, let bootStart {
      DeckGreetingView(
        text: greetingText, start: bootStart.addingTimeInterval(Self.strikeDuration))
    } else if let track = player.currentTrack {
      playing(track, artworkSize: artworkSize)
    } else {
      idle(artworkSize: artworkSize)
    }
  }

  private var greetingText: String {
    DeckCeremony.display(app.deck.greeting, fallback: DeckCeremony.defaultGreeting)
  }

  private func playing(_ track: LibraryTrack, artworkSize: CGFloat) -> some View {
    let byline = [track.artist, track.album]
      .filter { !$0.isEmpty }
      .joined(separator: " · ")
      .uppercased()
    return HStack(alignment: .center, spacing: 16) {
      artworkTile(size: artworkSize)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Marquee(
            text: track.displayTitle.uppercased(), color: VFD.glow, size: 13,
            scrolling: open && powered && player.isPlaying && windowIsVisible)
          modeBadge
        }
        Marquee(
          text: byline, color: VFD.dim, size: 9,
          scrolling: open && powered && player.isPlaying && windowIsVisible
        )
        visualizer
        seekBar
      }
      .frame(maxWidth: .infinity)
      if showsStatusColumn {
        VStack(alignment: .trailing, spacing: 7) {
          DeckTimeReadout(player: player)
          Spacer(minLength: 0)
          HStack(spacing: 5) {
            deckBadge("DSP", lit: true)
            deckBadge("S-BASS", lit: true)
            deckBadge("HI-FI", lit: player.isPlaying)
          }
        }
      }
    }
  }

  private func idle(artworkSize: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 16) {
      artworkTile(size: artworkSize)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
          Text("NIGHTDRIVE")
            .font(VFD.label(15))
            .kerning(4)
            .foregroundStyle(VFD.glow)
            .vfdGlow()
          Spacer(minLength: 0)
          modeBadge
        }
        Text("STANDBY · INSERT DISC")
          .font(VFD.label(8))
          .kerning(1.5)
          .foregroundStyle(VFD.dim)
        visualizer
        BlockProgressBar(fraction: 0, cells: 48, height: 5)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if showsStatusColumn {
        VStack(alignment: .trailing, spacing: 7) {
          SevenSegmentClock(height: 24, blinking: false)
          Spacer(minLength: 0)
          HStack(spacing: 5) {
            deckBadge("DSP", lit: false)
            deckBadge("S-BASS", lit: false)
            deckBadge("RDY", lit: true)
          }
        }
      }
    }
  }

  private var modeBadge: some View {
    VisualizerModeBadge(descriptor: app.visualizerSelection.currentVisualizer.descriptor)
  }

  private var visualizer: some View {
    VisualizerView(
      app: app, player: player, active: open && powered, bootStart: sweepStart, booting: booting
    )
    .frame(maxHeight: .infinity)
  }

  private func artworkTile(size: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.55))
      if let art = phosphorArt {
        Image(nsImage: art)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: size, height: size)
          .clipShape(RoundedRectangle(cornerRadius: 5))
          .opacity(0.9)
          .overlay(VFDScanlines().clipShape(RoundedRectangle(cornerRadius: 5)))
      } else if player.currentTrack != nil {
        TimelineView(
          .animation(
            minimumInterval: 1.0 / 12.0,
            paused: !player.isPlaying || !windowIsVisible)
        ) {
          timeline in
          Image(systemName: "opticaldisc")
            .font(.system(size: 30))
            .foregroundStyle(VFD.dim)
            .rotationEffect(
              .degrees(
                timeline.date.timeIntervalSinceReferenceDate
                  .truncatingRemainder(dividingBy: 12) * 30))
        }
      } else {
        VStack(spacing: 5) {
          Image(systemName: "opticaldisc")
            .font(.system(size: 24))
            .foregroundStyle(VFD.ghost)
          Text("NO DISC")
            .font(VFD.label(7))
            .kerning(1)
            .foregroundStyle(VFD.ghost)
        }
      }
    }
    .frame(width: size, height: size)
    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.06), lineWidth: 1))
  }

  private var seekBar: some View {
    GeometryReader { geo in
      DeckSeekBar(player: player)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            player.seek(to: value.location.x / geo.size.width)
          },
          isEnabled: player.duration > 0)
    }
    .frame(height: 5)
    .notWindowDraggable()
  }

  private func deckBadge(_ label: String, lit: Bool) -> some View {
    Text(label)
      .font(VFD.label(7, weight: .bold))
      .kerning(0.5)
      .foregroundStyle(lit ? VFD.mask : VFD.ghost)
      .padding(.horizontal, 3)
      .padding(.vertical, 0.5)
      .background(
        lit ? AnyShapeStyle(VFD.dim) : AnyShapeStyle(.clear),
        in: RoundedRectangle(cornerRadius: 2))
  }
}

/// Leaf views that keep the deck panel's elapsed-time observation (2 Hz) out
/// of the panel's large body; see the matching note in HeadUnitDisplay. They
/// read untracked values while the window is hidden so a covered deck stops
/// re-rendering and releases its render surfaces.
private struct DeckTimeReadout: View {
  let player: PlayerController

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    let position = windowIsVisible ? player.elapsed : player.untrackedElapsed
    let remaining = max(player.duration - position, 0)
    SevenSegmentText(text: VFD.timeText(position), color: VFD.glow, height: 24)
    HStack(spacing: 6) {
      Text("REMAIN")
        .font(VFD.label(7))
        .kerning(1)
        .foregroundStyle(VFD.dim)
      SevenSegmentText(text: "-" + VFD.timeText(remaining), color: VFD.amber, height: 11)
    }
  }
}

private struct DeckSeekBar: View {
  let player: PlayerController

  @Environment(\.windowIsVisible) private var windowIsVisible

  var body: some View {
    let elapsed = windowIsVisible ? player.elapsed : player.untrackedElapsed
    BlockProgressBar(
      fraction: player.duration > 0 ? elapsed / player.duration : 0,
      cells: 48, height: 5)
  }
}
