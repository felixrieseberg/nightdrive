import SwiftUI

/// The deck keeps drifting when nothing is playing — the modes all have an
/// idle pace built in — but it does so on a slower clock, so a silent deck
/// costs a fraction of a playing one instead of a whole core.
enum VisualizerHeartbeat {
  static let playing: TimeInterval = 1.0 / 24.0
  static let idle: TimeInterval = 1.0 / 8.0

  static func interval(isPlaying: Bool, booting: Bool) -> TimeInterval {
    isPlaying || booting ? playing : idle
  }

  /// How fast the visualizers' virtual clock runs relative to wall time.
  /// At rest the clock slows by the same ratio as the heartbeat, so each
  /// rendered frame advances exactly one simulation step: the deck drifts
  /// lazily instead of stuttering through skipped steps.
  static func timeScale(isPlaying: Bool, booting: Bool) -> Double {
    isPlaying || booting ? 1 : playing / idle
  }
}

/// Accumulates a virtual timeline that can run slower than wall time.
/// A plain reference type: advancing it during render must not invalidate
/// the view.
final class VisualizerClock {
  private var virtualTime: TimeInterval = 0
  private var lastReal: Date?

  func advance(to now: Date, scale: Double) -> TimeInterval {
    if let lastReal {
      virtualTime += max(0, now.timeIntervalSince(lastReal)) * scale
    }
    lastReal = now
    return virtualTime
  }

  func reset() {
    virtualTime = 0
    lastReal = nil
  }
}

struct VisualizerView: View {
  @Bindable var app: AppState
  let player: PlayerController
  let active: Bool
  let bootStart: Date?
  let booting: Bool

  @Environment(\.windowIsVisible) private var windowIsVisible

  @State private var clock = VisualizerClock()

  private static let selfTestDuration: TimeInterval = 0.95

  var body: some View {
    let visualizer = app.visualizerSelection.currentVisualizer
    let descriptor = visualizer.descriptor

    Group {
      if descriptor.wantsContinuousRedraw || booting {
        TimelineView(
          .animation(
            minimumInterval: VisualizerHeartbeat.interval(
              isPlaying: player.isPlaying, booting: booting),
            paused: !active || !windowIsVisible)
        ) { timeline in
          canvas(visualizer, now: timeline.date)
        }
      } else {
        canvas(visualizer, now: .now)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { app.visualizerSelection.cycleVisualizer() }
    .demoTarget("deck.glass") { app.visualizerSelection.cycleVisualizer() }
    .notWindowDraggable()
    .help("\(descriptor.name) — click to change visualizer")
    .accessibilityElement()
    .accessibilityLabel("Visualizer, \(descriptor.name)")
    .accessibilityHint("Activate to switch to the next visualizer")
    .accessibilityAddTraits(.isButton)
    .onChange(of: descriptor.id) {
      visualizer.reset()
      clock.reset()
    }
    .onChange(of: booting) { _, isBooting in
      if isBooting {
        visualizer.reset()
        clock.reset()
      }
    }
  }

  private func canvas(_ visualizer: any Visualizer, now: Date) -> some View {
    // A hidden window reads untracked values so it stops re-rendering and
    // releases its render surfaces; the windowIsVisible flip refreshes it.
    var frame = VisualizerFrame(
      size: .zero,
      time: clock.advance(
        to: now,
        scale: VisualizerHeartbeat.timeScale(isPlaying: player.isPlaying, booting: booting)),
      spectrum: windowIsVisible ? player.spectrum : player.untrackedSpectrum,
      peaks: windowIsVisible ? player.spectrumPeaks : player.untrackedSpectrumPeaks,
      waveform: windowIsVisible ? player.waveform : player.untrackedWaveform,
      level: windowIsVisible ? player.meterLevel : player.untrackedMeterLevel,
      elapsed: windowIsVisible ? player.elapsed : player.untrackedElapsed,
      duration: player.duration,
      isPlaying: player.isPlaying && active && windowIsVisible,
      title: player.currentTrack?.displayTitle ?? "",
      artist: player.currentTrack?.artist ?? "",
      album: player.currentTrack?.album ?? "",
      boot: selfTest(at: now),
      palette: VFDTheme.shared.palette)
    DemoSimulation.excite(&frame)

    return Canvas { context, size in
      frame.size = size
      visualizer.draw(frame, into: &context)
    }
  }

  private func selfTest(at now: Date) -> Double? {
    guard booting, let bootStart else { return nil }
    let elapsed = now.timeIntervalSince(bootStart)
    guard elapsed >= 0, elapsed < Self.selfTestDuration else { return nil }
    return elapsed / Self.selfTestDuration
  }

}

struct VisualizerModeBadge: View {
  let descriptor: VisualizerDescriptor

  var body: some View {
    HStack(spacing: 3) {
      if descriptor.isPlugin {
        Image(systemName: "puzzlepiece.extension.fill")
          .font(.system(size: 6))
          .foregroundStyle(VFD.ghost)
      }
      Text(descriptor.name)
        .font(VFD.label(7, weight: .bold))
        .kerning(1)
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(VFD.dim.opacity(0.75))
    }
    .frame(maxWidth: 86, alignment: .trailing)
    .fixedSize(horizontal: true, vertical: false)
    .allowsHitTesting(false)
    .accessibilityHidden(true)  // The glass is labelled.
  }
}

struct VisualizerMenuItems: View {
  @Bindable var app: AppState
  var includeShortcuts = false

  var body: some View {
    ForEach(app.visualizerSelection.enabledVisualizers) { descriptor in
      Button {
        app.visualizerSelection.selectVisualizer(descriptor.id)
      } label: {
        let title = descriptor.isPlugin ? "\(descriptor.name) (plugin)" : descriptor.name
        if descriptor.id == app.visualizerSelection.visualizerID {
          Label(title, systemImage: "checkmark")
        } else {
          Text(title)
        }
      }
    }
    Divider()
    Menu("Tube Color") {
      ForEach(VisualizerColorway.all) { colorway in
        Button {
          app.visualizerSelection.selectColorway(colorway.id)
        } label: {
          if colorway.id == app.visualizerSelection.colorwayID {
            Label(colorway.name, systemImage: "checkmark")
          } else {
            Text(colorway.name)
          }
        }
      }
    }
    Divider()
    Button("Next Visualizer") { app.visualizerSelection.cycleVisualizer() }
      .modifier(OptionalShortcut(enabled: includeShortcuts, shortcut: AppShortcuts.nextVisualizer))
    Button("Choose Visualizers…") { app.openSettings(tab: .visualizers) }
    Divider()
    Button("Reload Plugins") { app.visualizers.reloadPlugins() }
    Button("Open Visualizers Folder…") { app.visualizerSelection.openVisualizersFolder() }
    if !app.visualizers.issues.isEmpty {
      Divider()
      ForEach(app.visualizers.issues) { issue in
        Text("⚠ \(issue.source): \(issue.message)")
      }
    }
  }
}

private struct OptionalShortcut: ViewModifier {
  let enabled: Bool
  let shortcut: KeyboardShortcut

  func body(content: Content) -> some View {
    if enabled {
      content.keyboardShortcut(shortcut)
    } else {
      content
    }
  }
}
