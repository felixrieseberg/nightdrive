import AppKit
import ImageIO

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
  private var frames: [CGImage] = []
  private var iconView: DockIconView?
  private var timer: Timer?
  private var frameIndex = 0
  private var isWindowResizing = false
  private var liveResizeObservers: [any NSObjectProtocol] = []

  init(player: PlayerController) {
    self.player = player
  }

  /// Loads the frame loop and begins tracking playback state.
  func start() {
    guard frames.isEmpty else { return }
    frames = Self.loadDecodedFrames()
    guard !frames.isEmpty else { return }
    observeLiveResize()
    observePlayback()
  }

  static func loadFrames() -> [NSImage] {
    loadDecodedFrames().map { frame in
      let image = NSImage(size: NSSize(width: frame.width, height: frame.height))
      image.addRepresentation(NSBitmapImageRep(cgImage: frame))
      return image
    }
  }

  /// ImageIO otherwise leaves PNG decompression until a frame is first drawn,
  /// putting twelve small decode stalls in the first animation cycle.
  private static func loadDecodedFrames() -> [CGImage] {
    guard
      let bundle = Bundle.nightdriveResources,
      let urls = bundle.urls(forResourcesWithExtension: "png", subdirectory: "DockIconFrames")
    else { return [] }
    return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(
          source, 0,
          [
            kCGImageSourceShouldCache: true,
            kCGImageSourceShouldCacheImmediately: true,
          ] as CFDictionary)
      }
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

  /// The timer runs in `.common` mode so the icon keeps marching while a menu
  /// tracks, which also means it fires all through a window drag — where each
  /// frame costs AppKit an icon conversion on the main thread.
  private func observeLiveResize() {
    for (name, resizing) in [
      (NSWindow.willStartLiveResizeNotification, true),
      (NSWindow.didEndLiveResizeNotification, false),
    ] {
      let observer = NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.isWindowResizing != resizing else { return }
          self.isWindowResizing = resizing
          self.updateAnimationState()
        }
      }
      liveResizeObservers.append(observer)
    }
  }

  isolated deinit {
    for observer in liveResizeObservers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func updateAnimationState() {
    let shouldAnimate =
      player.isPlaying
      && !isWindowResizing
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
    // A resize pause resumes where it stopped; only a real halt rewinds.
    guard !isWindowResizing else { return }
    frameIndex = 0
    if iconView != nil {
      NSApp.dockTile.contentView = nil
      NSApp.dockTile.display()
      iconView = nil
    }
  }

  private func advanceFrame() {
    frameIndex = (frameIndex + 1) % frames.count
    let dockTile = NSApp.dockTile
    let iconView: DockIconView
    if let existing = self.iconView {
      iconView = existing
    } else {
      iconView = DockIconView(frame: NSRect(origin: .zero, size: dockTile.size))
      dockTile.contentView = iconView
      self.iconView = iconView
    }
    if iconView.frame.size != dockTile.size {
      iconView.frame.size = dockTile.size
    }
    iconView.image = frames[frameIndex]
    dockTile.display()
  }
}

/// Supplying the animation as Dock-tile content avoids changing the
/// application's icon on every tick. `applicationIconImage` makes AppKit
/// rebuild an icon representation each time; this view draws an already
/// decoded CGImage straight into the tile instead.
private final class DockIconView: NSView {
  var image: CGImage? {
    didSet { needsDisplay = true }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
  }
}
