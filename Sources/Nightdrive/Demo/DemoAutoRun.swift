#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation

  enum DemoAutoRun {
    static var isArmed: Bool { trackID != nil }

    private static var trackID: String? {
      ProcessInfo.processInfo.environment["NIGHTDRIVE_DEMO_TRACK"]
    }

    @MainActor private static var isArmedForLaunch = false

    /// Arms once per launch. The window's launch task re-runs whenever
    /// AppKit swaps the frame view (restyling the window for recording does
    /// exactly that), and a second arming would restart the track.
    @MainActor
    static func armIfRequested(app: AppState) {
      guard let id = trackID, !isArmedForLaunch else { return }
      isArmedForLaunch = true
      Task { @MainActor in
        guard let track = DemoTracks.all.first(where: { $0.id == id }) else {
          let known = DemoTracks.all.map(\.id).joined(separator: ", ")
          DemoLog.note("unknown track \"\(id)\" — known tracks: \(known)")
          await terminateApplicationAfterFlushing()
          return
        }

        if let window = DemoInput.mainWindow, let screen = window.screen ?? NSScreen.main {
          let size = NSSize(width: 1280, height: 800)
          let visible = screen.visibleFrame
          window.setFrame(
            NSRect(
              x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
              width: size.width, height: size.height),
            display: true)
        }
        // Restyle the window before the waits below so the launch task's
        // re-run (a rescan, integrations) settles before the track starts.
        app.demo.stage.prepareWindowForRecording()

        await app.visualizers.waitUntilReady()
        await wait(timeout: 60) { !app.library.isScanning && app.library.folderURL != nil }

        app.demo.automaticallyRecordsVideo = true
        DemoLog.note("running track \"\(track.id)\"")
        app.demo.run(track)

        await wait(timeout: 10) { app.demo.isRunning }
        await wait(timeout: track.estimatedDuration + 120) { app.demo.isSettled }

        if let error = app.demo.lastRunError {
          DemoLog.note("failed — \(error)")
          RunLoop.main.perform { exit(1) }
          return
        }
        if let url = app.demo.lastRecordingURL {
          DemoLog.note("finished — \(url.path)")
        } else {
          DemoLog.note("finished without a recording (\(app.demo.recorder.statusLabel))")
        }
        await terminateApplicationAfterFlushing()
      }
    }

    @MainActor
    private static func wait(timeout: TimeInterval, _ condition: () -> Bool) async {
      let deadline = Date().addingTimeInterval(timeout)
      while !condition() && Date() < deadline {
        await Task.pause(for: .milliseconds(250))
      }
    }
  }
#endif
