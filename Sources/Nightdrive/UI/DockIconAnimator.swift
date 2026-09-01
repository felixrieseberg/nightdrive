import AppKit

/// Animates the Dock icon while music plays: the committed icon artwork's
/// centre dashes and reflector posts march toward the viewer on a seamless
/// pre-rendered loop. The static icon is restored whenever playback stops.
///
/// Frames live in `Resources/DockIconFrames` and are regenerated with
/// `scripts/make-icon.py --frames 12`.
@MainActor
final class DockIconAnimator {
  private static let frameInterval: TimeInterval = 1.0 / 12.0

  private let player: PlayerController
  private var frames: [NSImage] = []
  private var timer: Timer?
  private var frameIndex = 0

  init(player: PlayerController) {
    self.player = player
  }

  /// Loads the frame loop and begins tracking playback state.
  func start() {
    guard frames.isEmpty else { return }
    frames = Self.loadFrames()
    guard !frames.isEmpty else { return }
    observePlayback()
  }

  static func loadFrames() -> [NSImage] {
    guard
      let urls = Bundle.module.urls(
        forResourcesWithExtension: "png", subdirectory: "DockIconFrames")
    else { return [] }
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { NSImage(contentsOf: $0) }
  }

  private func observePlayback() {
    withObservationTracking {
      _ = player.isPlaying
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.updateAnimationState()
        self.observePlayback()
      }
    }
    updateAnimationState()
  }

  private func updateAnimationState() {
    let shouldAnimate =
      player.isPlaying
      && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    if shouldAnimate {
      startTimer()
    } else {
      stopTimer()
    }
  }

  private func startTimer() {
    guard timer == nil else { return }
    let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] timer in
      let shouldStop = MainActor.assumeIsolated {
        guard let self, self.player.isPlaying else { return true }
        self.advanceFrame()
        return false
      }
      if shouldStop { timer.invalidate() }
    }
    timer.tolerance = Self.frameInterval / 4
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func stopTimer() {
    timer?.invalidate()
    timer = nil
    frameIndex = 0
    // Restore the bundle's static icon.
    NSApp.applicationIconImage = nil
  }

  private func advanceFrame() {
    frameIndex = (frameIndex + 1) % frames.count
    NSApp.applicationIconImage = frames[frameIndex]
  }
}
