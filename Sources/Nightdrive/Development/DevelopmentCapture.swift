#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation

  @MainActor
  enum DevelopmentCapture {
    static let screenshotSize = CGSize(width: 1440, height: 900)

    static func resizeMainWindowForScreenshots() {
      guard let window = mainWindow else { return }
      var frame = window.frame
      let chrome = frame.height - window.contentLayoutRect.height
      frame.size = CGSize(
        width: screenshotSize.width, height: screenshotSize.height + chrome)
      window.setFrame(frame, display: true, animate: false)
      window.center()
    }

    static func saveScreenshot() {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "nightdrive.png"
      panel.allowedContentTypes = [.png]
      panel.message = "Where to write the window capture."
      guard panel.runModal() == .OK, let url = panel.url else { return }
      DebugSnapshot.captureFrontWindow(to: url)
    }

    static func runSnapshotTour(app: AppState) async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.prompt = "Write Snapshots Here"
      panel.message = "Where the tour should write its PNGs."
      guard panel.runModal() == .OK, let directory = panel.url else { return }
      guard
        DevelopmentAlert.confirm(
          title: "Run the snapshot tour?",
          message: """
            The tour drives the window through every pane and quits the app \
            when it is done. PNGs land in \(directory.path).
            """,
          proceedTitle: "Run")
      else { return }
      await DebugSnapshot.runTourFromMenu(app: app, directory: directory)
    }

    static func renderVisualizerPreviews() {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.prompt = "Render Here"
      panel.message = "Where to write one preview per visualizer mode."
      guard panel.runModal() == .OK, let directory = panel.url else { return }
      _ = VisualizerReport.run(
        folder: .default, renderTo: directory, colorways: VisualizerColorway.all,
        size: VisualizerSample.defaultPreviewSize)
      NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    private static var mainWindow: NSWindow? {
      NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        ?? NSApp.windows.first { $0.isVisible }
    }
  }
#endif
