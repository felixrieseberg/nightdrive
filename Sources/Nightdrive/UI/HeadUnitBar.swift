import CoreAudio
import SwiftUI

struct HeadUnitBar: View {
  @Bindable var app: AppState
  var toggleSidebar: () -> Void = {}

  static let height: CGFloat = 44 + 10 + 9

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Color.clear
          .frame(width: 84)
          .fixedSize()
          .allowsHitTesting(false)
        DeckButton(label: String(localized: "Toggle Sidebar"), symbol: "sidebar.left") {
          toggleSidebar()
        }
        HStack(spacing: 5) {
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
          .demoTarget("headunit.play") { app.player.togglePlayPause() }
          DeckButton(label: String(localized: "Next"), symbol: "forward.fill") {
            app.player.next()
          }
          DeckButton(
            label: app.player.isShuffleEnabled
              ? String(localized: "Shuffle On") : String(localized: "Shuffle Off"),
            symbol: "shuffle",
            active: app.player.isShuffleEnabled
          ) {
            app.player.toggleShuffle()
          }
          DeckButton(
            label: app.player.repeatMode.label,
            symbol: app.player.repeatMode.systemImage,
            active: app.player.repeatMode != .off
          ) {
            app.player.cycleRepeatMode()
          }
        }
        HeadUnitDisplay(
          player: app.player,
          syncState: app.syncState,
          deckOpen: app.deck.isExpanded,
          showSyncErrorDetails: app.canShowSyncErrorDetails
            ? { app.showSyncErrorDetails() } : nil
        )
        .frame(maxWidth: .infinity)
        if app.player.playbackIssue != nil {
          PlaybackIssueIndicator(player: app.player)
        }
        if let result = app.latestSyncResult {
          DeckButton(
            label: String(localized: "Show Latest Sync Details"),
            symbol: result.failures.isEmpty
              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
            active: !result.failures.isEmpty
          ) {
            app.showLatestSyncDetails()
          }
        }
        DeckOutputPicker(player: app.player)
        DeckVolume(player: app.player)
        DeckSearchField(app: app)
        DeckButton(
          label: app.deck.isDetached
            ? String(localized: "Reattach Faceplate") : String(localized: "Detach Faceplate"),
          symbol: app.deck.isDetached ? "pip.exit" : "pip.enter",
          active: app.deck.isDetached
        ) {
          app.deck.isDetached ? app.deck.attach() : app.deck.detach()
        }
        .demoTarget("headunit.detach") {
          app.deck.isDetached ? app.deck.attach() : app.deck.detach()
        }
        DeckButton(
          label: app.deck.isExpanded
            ? String(localized: "Close Deck Display") : String(localized: "Open Deck Display"),
          symbol: app.deck.isExpanded ? "chevron.up" : "chevron.down",
          active: app.deck.isExpanded
        ) {
          app.deck.toggle()
        }
        .demoTarget("headunit.deck") { app.deck.toggle() }
      }
      .padding(.trailing, ChassisMetrics.edgeInset)
      .padding(.top, 10)
      .padding(.bottom, 9)

      DeckAssembly(app: app)
        .allowsHitTesting(app.deck.isExpanded)

      Bodywork.cavity
        .frame(height: DeckMechanism.contentSpacing(app.deck.progress))
        .allowsHitTesting(false)
    }
    .background {
      Self.faceplate
        .windowDraggable()
    }
  }

  static var faceplate: some View {
    LinearGradient(
      colors: [Bodywork.faceplateTop, Bodywork.faceplateBottom],
      startPoint: .top, endPoint: .bottom
    )
    .overlay(alignment: .top) {
      Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
    }
    .overlay(alignment: .bottom) {
      Self.seam
    }
    .overlay(
      Canvas { ctx, size in
        var y: CGFloat = 0
        while y < size.height {
          ctx.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
            with: .color(.white.opacity(0.015)))
          y += 2
        }
      }
      .allowsHitTesting(false))
  }

  private static var seam: some View {
    Rectangle()
      .fill(.black.opacity(0.55))
      .frame(height: 1)
      .allowsHitTesting(false)
  }
}

struct DeckAwareTopPadding: ViewModifier, @MainActor Animatable {
  var progress: CGFloat

  var animatableData: CGFloat {
    get { progress }
    set { progress = newValue }
  }

  func body(content: Content) -> some View {
    content.padding(
      .top,
      HeadUnitBar.height + DeckMechanism.reservedHeight(progress)
        + DeckMechanism.contentSpacing(progress))
  }
}

extension EnvironmentValues {
  @Entry var deckContentSpacing: CGFloat = 0
}

extension View {
  func windowDraggable() -> some View {
    gesture(WindowDragGesture())
  }

  func notWindowDraggable() -> some View {
    background(NonDraggableRegion())
  }
}

private struct NonDraggableRegion: NSViewRepresentable {
  final class BlockingView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
  }

  func makeNSView(context: Context) -> BlockingView { BlockingView() }
  func updateNSView(_ view: BlockingView, context: Context) {}
}

struct DeckButton: View {
  let label: String
  let symbol: String
  var wide = false
  var active = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
    }
    .buttonStyle(DeckButtonStyle(wide: wide, active: active))
    .notWindowDraggable()
    .accessibilityLabel(label)
    .help(label)
  }
}

struct DeckButtonStyle: ButtonStyle {
  var wide: Bool
  var active: Bool

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed
    configuration.label
      .font(.system(size: 11, weight: .bold))
      .foregroundStyle(pressed || active ? VFD.glow : VFD.dim)
      .vfdGlow(pressed || active ? VFD.glow : .clear)
      .frame(width: wide ? 48 : 36, height: 30)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            LinearGradient(
              colors: pressed
                ? [
                  Color(red: 0.06, green: 0.07, blue: 0.08),
                  Color(red: 0.11, green: 0.12, blue: 0.13),
                ]
                : [
                  Color(red: 0.16, green: 0.17, blue: 0.19),
                  Color(red: 0.09, green: 0.10, blue: 0.11),
                ],
              startPoint: .top, endPoint: .bottom)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(.black.opacity(0.8), lineWidth: 1)
          )
          .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 5)
              .strokeBorder(.white.opacity(pressed ? 0.03 : 0.09), lineWidth: 1)
              .padding(1)
              .mask(
                LinearGradient(
                  colors: [.white, .clear], startPoint: .top, endPoint: .center))
          }
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
  }
}

struct DeckOutputPicker: View {
  let player: PlayerController

  private var isRouted: Bool { player.audioOutput.selectedDeviceUID != nil }

  private var helpText: String {
    let output = player.audioOutput
    if let issue = output.issue {
      return String(localized: "Audio Output: \(issue)")
    }
    if output.selectedDeviceIsMissing {
      return String(localized: "Audio Output: selected device unavailable")
    }
    if let uid = output.selectedDeviceUID,
      let device = output.devices.first(where: { $0.uid == uid })
    {
      return String(localized: "Audio Output: \(device.name)")
    }
    return String(localized: "Audio Output: System Default")
  }

  var body: some View {
    let output = player.audioOutput
    Menu {
      Picker(String(localized: "Audio Output"), selection: selection) {
        Text("System Default").tag(AudioOutputController.systemDefaultSelectionID)
        if !output.devices.isEmpty {
          Divider()
        }
        ForEach(output.devices) { device in
          Label(device.displayName, systemImage: Self.symbol(for: device))
            .tag(device.uid)
        }
        if output.selectedDeviceIsMissing, let uid = output.selectedDeviceUID {
          Label(String(localized: "Selected Device (Unavailable)"), systemImage: "questionmark")
            .tag(uid)
        }
      }
      .pickerStyle(.inline)
      .labelsHidden()
    } label: {
      Image(systemName: "airplay.audio")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(isRouted ? VFD.glow : VFD.dim)
        .vfdGlow(isRouted ? VFD.glow : .clear)
        .opacity(output.selectedDeviceIsMissing || output.issue != nil ? 0.45 : 1)
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel(String(localized: "Audio Output"))
    .help(helpText)
    .notWindowDraggable()
  }

  private var selection: Binding<String> {
    Binding(
      get: { player.audioOutput.selectionID },
      set: { player.selectAudioOutput($0) })
  }

  private static func symbol(for device: AudioOutputDevice) -> String {
    switch device.transportType {
    case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
    case kAudioDeviceTransportTypeAirPlay: "airplay.audio"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      "wave.3.right.circle"
    default: "hifispeaker"
    }
  }
}

struct DeckVolume: View {
  let player: PlayerController

  var body: some View {
    HStack(spacing: 6) {
      Button {
        player.toggleMute()
      } label: {
        Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.fill")
          .font(.system(size: 9))
          .foregroundStyle(player.isMuted ? VFD.glow : VFD.dim)
          .vfdGlow(player.isMuted ? VFD.glow : .clear)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(
        player.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
      )
      .help(player.isMuted ? String(localized: "Unmute") : String(localized: "Mute"))
      GeometryReader { geo in
        let fraction = CGFloat(player.volume)
        ZStack(alignment: .leading) {
          Capsule()
            .fill(.black.opacity(0.75))
            .overlay(Capsule().strokeBorder(.white.opacity(0.06), lineWidth: 0.5))
            .frame(height: 5)
          Capsule()
            .fill(VFD.glow.opacity(player.isMuted ? 0.22 : 0.8))
            .frame(width: max(5, (geo.size.width - 10) * fraction + 5), height: 5)
            .vfdGlow()
          Circle()
            .fill(
              LinearGradient(
                colors: [
                  Color(red: 0.22, green: 0.23, blue: 0.25),
                  Color(red: 0.10, green: 0.11, blue: 0.12),
                ],
                startPoint: .top, endPoint: .bottom)
            )
            .overlay(Circle().strokeBorder(.black.opacity(0.8), lineWidth: 1))
            .frame(width: 12, height: 12)
            .offset(x: (geo.size.width - 12) * fraction)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { value in
            player.volume = Float(min(max(value.location.x / geo.size.width, 0), 1))
          })
      }
      .frame(width: 72, height: 16)
      Image(systemName: "speaker.wave.3.fill")
        .font(.system(size: 8))
        .foregroundStyle(player.isMuted ? VFD.ghost : VFD.dim)
    }
    .notWindowDraggable()
  }
}

private struct PlaybackIssueIndicator: View {
  let player: PlayerController
  @State private var isShowingDetails = false

  var body: some View {
    Button {
      isShowingDetails.toggle()
    } label: {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.orange)
    }
    .buttonStyle(.plain)
    .notWindowDraggable()
    .accessibilityLabel("Playback issue")
    .help(player.playbackIssue?.message ?? String(localized: "Playback issue"))
    .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          player.playbackIssue?.title ?? String(localized: "Playback Issue"),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.headline)
        .foregroundStyle(.orange)
        Text(player.playbackIssue?.message ?? "")
          .font(.callout)
          .frame(maxWidth: 320, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Dismiss") {
            player.dismissPlaybackIssue()
            isShowingDetails = false
          }
        }
      }
      .padding()
      .frame(width: 360)
    }
  }
}

struct DeckSearchField: View {
  @Bindable var app: AppState
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 5) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(VFD.dim)
      ZStack(alignment: .leading) {
        if app.searchText.isEmpty {
          Text("SEARCH")
            .foregroundStyle(VFD.ghost)
            .allowsHitTesting(false)
        }
        TextField(String(), text: $app.searchText)
          .textFieldStyle(.plain)
          .foregroundStyle(VFD.glow)
          .tint(VFD.glow)
          .focused($focused)
          .accessibilityLabel("Search")
      }
      .font(VFD.label(10))
      .kerning(0.5)
      if !app.searchText.isEmpty {
        Button {
          app.searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 9))
            .foregroundStyle(VFD.dim)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
      }
    }
    .onChange(of: app.searchFocusRequest) { focused = true }
    .onChange(of: app.isQuickSearchPresented) {
      if app.isQuickSearchPresented { focused = false }
    }
    .onChange(of: focused) { app.searchFieldFocused = focused }
    .task {
      await Task.pause(for: .milliseconds(400))
      if focused {
        (NSApp.keyWindow ?? NSApp.windows.first)?.makeFirstResponder(nil)
      }
    }
    .padding(.horizontal, 8)
    .frame(minWidth: 80, idealWidth: 130, maxWidth: 150)
    .frame(height: 26)
    .notWindowDraggable()
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(.black.opacity(0.72))
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              focused ? VFD.glow.opacity(0.45) : .white.opacity(0.07),
              lineWidth: 1)))
  }
}
