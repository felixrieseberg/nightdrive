#if NIGHTDRIVE_PERFORMANCE_BENCHMARK
  import AppKit
  import Foundation

  /// Launch-only control surface for the repository's isolated performance
  /// benchmark. It is inert in ordinary launches and keeps UI automation out of
  /// measurements while still exercising the production app and audio graph.
  enum PerformanceBenchmark {
    static let autoplayEnvironmentKey = "NIGHTDRIVE_PERFORMANCE_BENCHMARK_AUTOPLAY"
    static let readyPathEnvironmentKey = "NIGHTDRIVE_PERFORMANCE_BENCHMARK_READY_PATH"
    static let occlusionPathEnvironmentKey = "NIGHTDRIVE_PERFORMANCE_BENCHMARK_OCCLUSION_PATH"

    @MainActor private static var occlusionReporter: OcclusionReporter?

    @MainActor
    static func startIfRequested(
      app: AppState,
      environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
      guard let readyPath = environment[readyPathEnvironmentKey], !readyPath.isEmpty else { return }
      orderWindowsFront()
      if let occlusionPath = environment[occlusionPathEnvironmentKey], !occlusionPath.isEmpty {
        occlusionReporter = OcclusionReporter(path: occlusionPath)
      }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(100))
        orderWindowsFront()
        occlusionReporter?.writeCurrentState()
      }
      guard environment[autoplayEnvironmentKey] == "1" else { return }

      let status: String
      if let track = app.library.tracks.first {
        app.player.play(track, in: app.library.tracks)
        if app.player.isPlaying {
          status = "ready\n"
        } else {
          status = "error: playback did not start\n"
        }
      } else {
        status = "error: benchmark library is empty\n"
      }
      try? Data(status.utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    }

    @MainActor
    private static func orderWindowsFront() {
      for window in NSApp.windows {
        window.orderFrontRegardless()
      }
    }

    /// Keeps a benchmark-owned file updated with how many on-screen windows
    /// are actually visible versus occluded, so the benchmark script can fail
    /// loudly when desktop state (a stray window over the app, or a cover that
    /// never covered) would silently corrupt a visible or obscured case.
    @MainActor
    private final class OcclusionReporter: NSObject {
      private let url: URL

      init(path: String) {
        url = URL(fileURLWithPath: path)
        super.init()
        for name in [
          NSWindow.didChangeOcclusionStateNotification,
          NSWindow.didMiniaturizeNotification,
          NSWindow.didDeminiaturizeNotification,
          NSWindow.willCloseNotification,
        ] {
          NotificationCenter.default.addObserver(
            self, selector: #selector(windowStateChanged), name: name, object: nil)
        }
        writeCurrentState()
      }

      deinit {
        NotificationCenter.default.removeObserver(self)
      }

      @objc private func windowStateChanged() {
        writeCurrentState()
      }

      func writeCurrentState() {
        // Only the app's real content windows matter: system auxiliaries
        // (text-input UI, pickers) come and go at odd levels and would make
        // the visible/occluded counts meaningless.
        let onScreen = NSApp.windows.filter {
          $0.isVisible && $0.level == .normal && $0.styleMask.contains(.titled)
        }
        let visible = onScreen.filter { WindowVisibility.isVisible($0) }.count
        var lines = ["visible=\(visible) occluded=\(onScreen.count - visible)"]
        for window in onScreen {
          let state = WindowVisibility.isVisible(window) ? "visible" : "occluded"
          lines.append(
            "  \(state) level=\(window.level.rawValue) frame=\(window.frame) "
              + "\(type(of: window)) '\(window.title)'")
        }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
      }
    }
  }
#endif
