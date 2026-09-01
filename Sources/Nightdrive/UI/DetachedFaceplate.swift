import AppKit
import SwiftUI

// MARK: - Security LED

enum SecurityLED {
  static let period: TimeInterval = 1.2
  static let flash: TimeInterval = 0.25
  static let decay: TimeInterval = 0.35

  static func intensity(at elapsed: TimeInterval) -> Double {
    guard elapsed >= 0 else { return 0 }
    let phase = elapsed.truncatingRemainder(dividingBy: period)
    if phase < flash { return 1 }
    let tail = phase - flash
    guard tail < decay else { return 0 }
    return 1 - tail / decay
  }
}

private struct SecurityLEDView: View {
  let since: Date?

  @Environment(\.windowIsVisible) private var windowIsVisible
  private static let red = Color(red: 1, green: 0.16, blue: 0.10)

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !windowIsVisible)) { timeline in
      let elapsed = since.map { timeline.date.timeIntervalSince($0) } ?? 0
      let glow = SecurityLED.intensity(at: elapsed)
      Circle()
        .fill(Self.red.opacity(0.14 + 0.86 * glow))
        .overlay(
          Circle()
            .fill(.white.opacity(0.10 + 0.25 * glow))
            .frame(width: 2, height: 2)
            .offset(x: -1, y: -1)
        )
        .overlay(Circle().strokeBorder(.black.opacity(0.85), lineWidth: 1))
        .shadow(color: Self.red.opacity(0.8 * glow), radius: 5)
        .frame(width: 8, height: 8)
    }
    .accessibilityHidden(true)
  }
}

// MARK: - naked chassis

struct ChassisBayView: View {
  @Bindable var app: AppState

  var body: some View {
    ZStack {
      cavity
      hardware
    }
    .padding(.top, 2)
    .padding(.bottom, 3)
    .padding(.horizontal, DeckMechanism.sideInset)
    .frame(height: DeckMechanism.openHeight, alignment: .top)
    .contentShape(Rectangle())
    .onTapGesture { app.deck.attach() }
    .notWindowDraggable()
    .accessibilityElement()
    .accessibilityLabel("Faceplate removed, security system active")
    .accessibilityHint("Activate to reattach the faceplate")
    .accessibilityAddTraits(.isButton)
    .help("Faceplate removed — click to reattach")
  }

  private var cavity: some View {
    RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius)
      .fill(
        LinearGradient(
          colors: [Bodywork.grey(0.030), Bodywork.grey(0.012)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius)
          .fill(
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0.6), location: 0),
                .init(color: .clear, location: 0.30),
              ],
              startPoint: .top, endPoint: .bottom))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius)
          .strokeBorder(.black.opacity(0.9), lineWidth: 1.5))
  }

  private var hardware: some View {
    HStack(spacing: 0) {
      connector
        .padding(.leading, 22)
      Spacer(minLength: 12)
      stencil
      Spacer(minLength: 12)
      securityCluster
        .padding(.trailing, 26)
    }
    .overlay(alignment: .topLeading) { hingeStub.padding(.top, 7).padding(.leading, 46) }
    .overlay(alignment: .topTrailing) { hingeStub.padding(.top, 7).padding(.trailing, 46) }
    .overlay(alignment: .leading) { dockingPost.padding(.leading, 7) }
    .overlay(alignment: .trailing) { dockingPost.padding(.trailing, 7) }
  }

  private var connector: some View {
    VStack(spacing: 3) {
      ForEach(0..<2, id: \.self) { _ in
        HStack(spacing: 3) {
          ForEach(0..<8, id: \.self) { _ in
            RoundedRectangle(cornerRadius: 0.8)
              .fill(Color(red: 0.62, green: 0.50, blue: 0.20))
              .frame(width: 4, height: 9)
          }
        }
      }
    }
    .padding(6)
    .background(
      RoundedRectangle(cornerRadius: 3)
        .fill(Bodywork.grey(0.070))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.8), lineWidth: 1))
    )
  }

  private var stencil: some View {
    VStack(spacing: 5) {
      Text("FACEPLATE REMOVED")
        .font(VFD.label(11, weight: .bold))
        .kerning(3)
        .foregroundStyle(.white.opacity(0.26))
      Text("ANTI-THEFT SYSTEM ACTIVE · DOCK FACEPLATE TO RESUME")
        .font(VFD.label(7))
        .kerning(1.4)
        .foregroundStyle(.white.opacity(0.15))
      Text("CW-9940X")
        .font(VFD.label(6))
        .kerning(1.2)
        .foregroundStyle(.white.opacity(0.10))
    }
    .lineLimit(1)
    .allowsHitTesting(false)
  }

  private var securityCluster: some View {
    VStack(spacing: 4) {
      SecurityLEDView(since: app.deck.detachedAt)
      Text("SEC")
        .font(VFD.label(6, weight: .bold))
        .kerning(1)
        .foregroundStyle(.white.opacity(0.18))
    }
  }

  private var hingeStub: some View {
    RoundedRectangle(cornerRadius: 2)
      .fill(Bodywork.grey(0.10))
      .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.7), lineWidth: 1))
      .frame(width: 26, height: 6)
  }

  private var dockingPost: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [Bodywork.grey(0.16), Bodywork.grey(0.06)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(Circle().strokeBorder(.black.opacity(0.8), lineWidth: 1))
      .overlay(Circle().fill(Bodywork.grey(0.03)).frame(width: 4, height: 4))
      .frame(width: 11, height: 11)
  }
}

// MARK: - faceplate in the hand

struct DetachedFaceplateView: View {
  @Bindable var app: AppState

  static let naturalSize = CGSize(
    width: 510,
    height: 12 + DeckPanel.glassHeight + 7 + 30 + 9)
  static let minScale: CGFloat = 0.5

  var body: some View {
    GeometryReader { geo in
      let scale = min(
        1,
        geo.size.width / Self.naturalSize.width,
        geo.size.height / Self.naturalSize.height)
      faceplate
        .frame(width: geo.size.width / scale, height: geo.size.height / scale)
        .scaleEffect(scale, anchor: .topLeading)
    }
  }

  private var faceplate: some View {
    VStack(spacing: 7) {
      DeckPanel(
        app: app,
        open: app.deck.isDetached,
        powered: app.deck.isDetached,
        stretchesGlass: true,
        showsStatusColumn: false,
        scalesArtwork: true)
      transport
    }
    .padding(.horizontal, 12)
    .padding(.top, 12)
    .padding(.bottom, 9)
    .background { slab.windowDraggable() }
  }

  private var transport: some View {
    HStack(spacing: 10) {
      HStack(spacing: 7) {
        DeckButton(label: String(localized: "Previous"), symbol: "backward.fill") {
          app.player.previous()
        }
        DeckButton(
          label: app.player.isPlaying ? String(localized: "Pause") : String(localized: "Play"),
          symbol: app.player.isPlaying ? "pause.fill" : "play.fill",
          wide: true
        ) {
          app.player.togglePlayPause()
        }
        DeckButton(label: String(localized: "Next"), symbol: "forward.fill") {
          app.player.next()
        }
      }
      DeckOutputPicker(player: app.player)
      DeckVolume(player: app.player)
      Text("NIGHTDRIVE")
        .font(VFD.label(11, weight: .bold))
        .kerning(2)
        .foregroundStyle(.white.opacity(0.14))
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .contentShape(Rectangle())
        .windowDraggable()
      DeckButton(label: String(localized: "Reattach Faceplate"), symbol: "pip.enter") {
        app.deck.attach()
      }
    }
  }

  private var slab: some View {
    RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius)
      .fill(
        LinearGradient(
          colors: [Bodywork.faceplateTop, Bodywork.faceplateBottom],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(
        RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius - 1)
          .strokeBorder(.white.opacity(0.07), lineWidth: 1)
          .padding(1)
          .mask(
            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
      )
      .overlay(
        RoundedRectangle(cornerRadius: DeckMechanism.cornerRadius)
          .strokeBorder(.black.opacity(0.85), lineWidth: 1)
      )
      .overlay(screws)
  }

  private var screws: some View {
    VStack {
      HStack {
        screw
        Spacer()
        screw.offset(y: 1)
      }
      Spacer()
      HStack {
        screw
        Spacer()
        screw.offset(y: -1)
      }
    }
    .padding(7)
    .allowsHitTesting(false)
  }

  private var screw: some View {
    Circle()
      .fill(
        LinearGradient(
          colors: [Bodywork.grey(0.24), Bodywork.grey(0.08)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(Rectangle().fill(.black.opacity(0.7)).frame(width: 4, height: 1).rotationEffect(.degrees(28)))
      .overlay(Circle().strokeBorder(.black.opacity(0.7), lineWidth: 0.8))
      .frame(width: 5.5, height: 5.5)
  }
}

// MARK: - floating panel

@MainActor
final class FaceplatePanelController: NSObject, NSWindowDelegate {
  enum Presentation: Equatable {
    case foreground
    case backgroundSnapshot
  }

  static let windowIdentifier = NSUserInterfaceItemIdentifier("nightdrive-faceplate")
  private static let frameName = "NightdriveFaceplatePanel"
  static var floorSize: NSSize {
    NSSize(
      width: DetachedFaceplateView.naturalSize.width * DetachedFaceplateView.minScale,
      height: DetachedFaceplateView.naturalSize.height * DetachedFaceplateView.minScale)
  }

  private var panel: NSPanel?
  private var pinned = false
  private let presentation = FaceplatePanelController.presentation()

  nonisolated static func presentation(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> Presentation {
    environment["NIGHTDRIVE_SNAPSHOT_DIR"] == nil ? .foreground : .backgroundSnapshot
  }

  static func configure(_ panel: NSPanel, for presentation: Presentation) {
    if presentation == .foreground {
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    } else {
      panel.isFloatingPanel = false
      panel.level = .normal
      panel.collectionBehavior = []
    }
  }

  static func order(
    _ panel: NSPanel, for presentation: Presentation, relativeTo mainWindow: NSWindow?
  ) {
    switch presentation {
    case .foreground:
      panel.orderFrontRegardless()
    case .backgroundSnapshot:
      if panel.parent == nil, let mainWindow {
        mainWindow.addChildWindow(panel, ordered: .above)
      } else {
        panel.orderFront(nil)
      }
    }
  }

  func show(app: AppState, pinnedToNaturalSize: Bool = false) {
    let panel = self.panel ?? makePanel(app: app)
    self.panel = panel
    pinned = pinnedToNaturalSize
    if pinnedToNaturalSize {
      panel.setContentSize(DetachedFaceplateView.naturalSize)
      position(panel)
    } else if !panel.setFrameUsingName(Self.frameName) {
      position(panel)
    }
    // Snapshot launches are accessory apps whose windows stay behind the app
    // the user is working in. Keep this panel in the same window group as
    // Nightdrive's main window instead of letting its usual floating,
    // all-Spaces behavior escape that background-only contract.
    let main = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })
    Self.order(panel, for: presentation, relativeTo: main)
  }

  func close() {
    guard let panel else { return }
    if !pinned {
      panel.saveFrame(usingName: Self.frameName)
    }
    panel.orderOut(nil)
    panel.contentView = nil
    self.panel = nil
  }

  private func makePanel(app: AppState) -> NSPanel {
    let hosting = NSHostingView(
      rootView: WindowActivity {
        DetachedFaceplateView(app: app)
      })
    hosting.sizingOptions = []
    let natural = DetachedFaceplateView.naturalSize
    hosting.setFrameSize(natural)
    let panel = NSPanel(
      contentRect: hosting.frame,
      styleMask: [.borderless, .nonactivatingPanel, .resizable],
      backing: .buffered,
      defer: false)
    panel.identifier = Self.windowIdentifier
    panel.contentView = hosting
    panel.delegate = self
    Self.configure(panel, for: presentation)
    panel.hidesOnDeactivate = false
    panel.isMovableByWindowBackground = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow
    return panel
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    let floor = Self.floorSize
    return NSSize(
      width: max(frameSize.width, floor.width),
      height: max(frameSize.height, floor.height))
  }

  private func position(_ panel: NSPanel) {
    guard let main = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
      let screen = main.screen ?? NSScreen.main
    else {
      panel.center()
      return
    }
    let size = panel.frame.size
    var origin = NSPoint(
      x: main.frame.midX - size.width / 2,
      y: main.frame.maxY - HeadUnitBar.height - DeckMechanism.openHeight - size.height - 24)
    origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
    origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
    panel.setFrameOrigin(origin)
  }
}
