#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation

  @MainActor
  enum DevelopmentDeckTools {
    static let poses: [(name: String, progress: CGFloat)] = [
      ("Early", 0.12), ("Half", 0.5), ("Overshoot", 1.08), ("Seated", 1),
    ]

    static func resetGreeting(app: AppState) {
      app.deck.greetedThisLaunch = false
    }

    static func replayCeremony(app: AppState) async {
      if app.deck.isExpanded {
        app.deck.close()
        await Task.pause(for: .milliseconds(700))
      }
      app.deck.greetedThisLaunch = false
      app.deck.open()
    }

    static func pin(to progress: CGFloat, seated: Bool, app: AppState) {
      app.deck.present(progress: progress, seated: seated)
    }

    // MARK: - Visualizer plugins

    static func resetApprovals(app: AppState) {
      guard
        DevelopmentAlert.confirm(
          title: "Forget every plugin approval?",
          message: """
            Scripts in the plugins folder go back to pending and have to be \
            approved again before they run.
            """,
          proceedTitle: "Forget")
      else { return }
      VisualizerApprovalStore().save(VisualizerApprovals())
      app.visualizers.reloadPlugins()
    }

    static let brokenPluginFileName = "zz-develop-broken.js"

    static var brokenPluginURL: URL {
      VisualizerPluginFolder.default.url.appendingPathComponent(brokenPluginFileName)
    }

    static func loadBrokenPlugin(app: AppState) async {
      let url = brokenPluginURL
      guard
        DevelopmentAlert.confirm(
          title: "Write a deliberately broken plugin?",
          message: """
            \(url.path) will be created so the failed-plugin state shows up. \
            Remove it again with Develop ▸ Visualizers ▸ Remove Broken Plugin.
            """,
          proceedTitle: "Write It")
      else { return }
      let source = """
        nightdrive.register({ id: "broken", name: "BROKEN" , draw( {
        """
      do {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        DevelopmentAlert.report(error, doing: "write \(url.lastPathComponent)")
        return
      }
      await app.visualizers.reloadPluginsAndWait()
      app.openSettings(tab: .visualizers)
    }

    static func removeBrokenPlugin(app: AppState) async {
      do {
        try DevelopmentFileRemoval.removeItemIfPresent(at: brokenPluginURL)
      } catch {
        DevelopmentAlert.report(error, doing: "remove \(brokenPluginFileName)")
        return
      }
      await app.visualizers.reloadPluginsAndWait()
    }
  }
#endif
