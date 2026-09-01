#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation
  import SwiftUI

  @MainActor
  enum DemoTracks {
    static var primary: [DemoTrack] { [sizzle] }

    static var sizzleSections: [DemoTrack] {
      SizzleSection.allCases.map { section in
        DemoTrack(
          id: "sizzle-\(section.rawValue)", title: section.title,
          estimatedDuration: section.estimatedDuration, phases: [section.title]
        ) { demo in
          try await run(section, demo: demo)
        }
      }
    }

    static var all: [DemoTrack] { primary + sizzleSections }

    // MARK: Sizzle track

    static let sizzle = DemoTrack(
      id: "sizzle", title: "Nightdrive Sizzle (~45s)", estimatedDuration: 46,
      phases: SizzleSection.allCases.filter { $0 != .visualizers }.map(\.title)
    ) { demo in
      try await runSizzle(demo)
    }

    enum SizzleSection: String, CaseIterable {
      case opening, playback, visualizers, browse, podcasts, ipod, finale

      var title: String {
        switch self {
        case .opening: "Opening"
        case .playback: "Playback"
        case .visualizers: "Visualizers"
        case .browse: "Browse"
        case .podcasts: "Podcasts"
        case .ipod: "iPod"
        case .finale: "Finale"
        }
      }

      var estimatedDuration: Double {
        switch self {
        case .opening: 10
        case .playback: 6
        case .visualizers: 22
        case .browse: 6
        case .podcasts: 10
        case .ipod: 9
        case .finale: 8
        }
      }
    }

    /// The tour opens and closes on Nightdrive; the demo deliberately leaves
    /// it selected when the reel ends.
    private static let sizzleVisualizerTour = [
      "nightdrive", "marquee", "tunnel", "vu", "nightdrive",
    ]

    private static func runSizzle(_ demo: DemoScriptContext) async throws {
      demo.phase(SizzleSection.opening.title)
      try await stageBase(demo)
      try await runOpening(demo)

      demo.phase(SizzleSection.playback.title)
      try await runPlayback(demo)

      // The visualizer tour runs on a parallel track: the deck keeps
      // switching modes at its usual cadence while the script walks the
      // rest of the app.
      let app = demo.app
      let cycler = Task { @MainActor in
        for id in sizzleVisualizerTour.dropFirst() {
          try await Task.sleep(for: .seconds(4))
          guard app.visualizers.descriptors.contains(where: { $0.id == id }) else { continue }
          app.visualizerSelection.selectVisualizer(id)
        }
      }
      do {
        demo.phase(SizzleSection.browse.title)
        try await runBrowse(demo)

        demo.phase(SizzleSection.podcasts.title)
        try await runPodcasts(demo)

        demo.phase(SizzleSection.ipod.title)
        try await runIpod(demo)
      } catch {
        cycler.cancel()
        throw error
      }
      cycler.cancel()

      demo.phase(SizzleSection.finale.title)
      try await runFinale(demo) {
        await runPendingCleanups()
      }
    }

    // MARK: Section runner

    static func run(_ section: SizzleSection, demo: DemoScriptContext) async throws {
      demo.phase(section.title)
      try await stageBase(demo)
      try await stage(for: section, demo: demo)
      switch section {
      case .opening:
        try await runOpening(demo)
      case .playback:
        try await runPlayback(demo)
      case .visualizers:
        let restore = demo.app.visualizerSelection.visualizerID
        try await runVisualizers(demo)
        demo.app.visualizerSelection.selectVisualizer(restore)
      case .browse:
        try await runBrowse(demo)
      case .podcasts:
        try await runPodcasts(demo)
      case .ipod:
        try await runIpod(demo)
      case .finale:
        try await runFinale(demo)
      }
    }

    private static func stageBase(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      await connectDemoIpod(app: app)
      try await demo.cut {
        app.selection = .library
        app.selectedTrackIDs = []
        if app.deck.isDetached { app.deck.attach() }
      }
      try await demo.waitUntil(timeout: 30, description: "the library scan") {
        !app.library.isScanning && !app.library.tracks.isEmpty
      }
      await app.visualizers.waitUntilReady()
    }

    /// The classic iPod the reel shows is connected before the first frame.
    /// An older, near-empty staging is reseeded so the device carries enough
    /// songs for its track table to scroll on camera.
    private static func connectDemoIpod(app: AppState) async {
      guard demoDevice(in: app) == nil else { return }
      let url = DevelopmentDevices.root.appendingPathComponent("My iPod", isDirectory: true)
      let songs = DemoSeeder.ipodOnlySongs + DemoSeeder.demoIpodFillerSongs
      if IpodFileSystem.isIpodVolume(url), DevelopmentSafety.isFakeVolume(url),
        ((try? IpodFileSystem(volumeURL: url).readDatabase())?.tracks.count ?? 0) < songs.count
      {
        try? FileManager.default.removeItem(at: url)
      }
      if !IpodFileSystem.isIpodVolume(url) {
        do {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          try DemoSeeder.seedIpod(
            at: url, model: "M9585", name: "My iPod",
            songs: songs, playlists: true)
        } catch {
          DemoLog.note("could not stage the demo iPod: \(error.localizedDescription)")
          return
        }
      }
      await app.deviceManager.addDevelopmentScanRoot(url)
      registerCleanup {
        await DevelopmentDevices.unmountAll(app: app)
      }
    }

    private static func stage(for section: SizzleSection, demo: DemoScriptContext) async throws {
      let app = demo.app
      switch section {
      case .opening, .finale:
        return
      case .playback:
        try await seatDeck(demo)
      case .visualizers:
        try await seatDeck(demo)
        if app.visualizers.descriptors.contains(where: { $0.id == sizzleVisualizerTour[0] }) {
          app.visualizerSelection.selectVisualizer(sizzleVisualizerTour[0])
        }
        try await startPlayback(demo)
      case .browse, .podcasts, .ipod:
        try await seatDeck(demo)
        try await startPlayback(demo)
      }
    }

    private static func seatDeck(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      guard !app.deck.isExpanded else { return }
      app.deck.present(progress: 1, seated: true)
      try await demo.hold(2.4)
    }

    private static func startPlayback(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      guard !app.player.isPlaying else { return }
      if let track = app.library.tracks.first {
        app.player.play(track, in: app.library.tracks)
      }
      try await demo.hold(0.6)
    }

    // MARK: Chapters

    /// Keeps the frame alive where a hold would sit still: glides the
    /// cursor to a window-relative point and slowly scrolls whatever is
    /// under it for the duration.
    private static func drift(
      _ demo: DemoScriptContext, atX x: Double, y: Double,
      by pixels: Double, over seconds: Double
    ) async throws {
      guard let window = DemoInput.mainWindow else {
        try await demo.hold(seconds)
        return
      }
      let point = CGPoint(x: window.frame.width * x, y: window.frame.height * y)
      if demo.cursor.visible {
        try await demo.moveCursor(to: point)
      } else {
        demo.cursor.position = point
      }
      try await demo.scroll(by: pixels, duration: seconds)
    }

    private static func runOpening(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      try await demo.cut {
        if app.deck.isExpanded { app.deck.close() }
        // A launch-restored open deck may have greeted before recording
        // began; resetting the flag replays the HELLO ceremony on camera.
        app.deck.greetedThisLaunch = false
      }
      if app.visualizers.descriptors.contains(where: { $0.id == sizzleVisualizerTour[0] }) {
        app.visualizerSelection.selectVisualizer(sizzleVisualizerTour[0])
      }
      // Music starts right away; the greeting plays over it as the deck
      // opens.
      if !app.player.isPlaying {
        app.player.togglePlayPause()
      }
      try await demo.hold(1.2)
      app.deck.open()
      try await demo.waitUntil(timeout: 10, description: "the deck greeting") {
        app.deck.greetedThisLaunch
          || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      }
      try await demo.hold(2.0)
    }

    private static func runPlayback(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      if !app.player.isPlaying {
        app.player.togglePlayPause()
      }
      // The library list drifts beneath the playing deck.
      try await drift(demo, atX: 0.55, y: 0.6, by: 140, over: 2.85)
    }

    private static func runVisualizers(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      let tour = sizzleVisualizerTour.filter { id in
        app.visualizers.descriptors.contains { $0.id == id }
      }
      try await demo.moveCursor(to: "deck.glass", at: UnitPoint(x: 0.62, y: 0.55))
      try await demo.hold(2.4)
      for (index, id) in tour.dropFirst().enumerated() {
        try await demo.click("deck.glass", at: UnitPoint(x: 0.62, y: 0.55)) {
          app.visualizerSelection.selectVisualizer(id)
        }
        // Once the tour lands back on Nightdrive the next section starts
        // immediately; the returning glass plays on behind the albums view.
        let isLast = index == tour.count - 2
        try await demo.hold(isLast ? 0.4 : 4.0)
      }
    }

    private static func runBrowse(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      try await demo.cut { app.selection = .albums }
      try await demo.hold(0.7)
      // The albums view is a split: the album list sits directly right of
      // the app sidebar, so anchor the scroll point off the sidebar row
      // rather than a window fraction (which lands in the track table).
      if let window = DemoInput.mainWindow,
        let sidebarEdge = demo.point(of: "sidebar.albums", at: UnitPoint(x: 1, y: 0.5))
      {
        demo.cursor.position = CGPoint(
          x: sidebarEdge.x + 130, y: window.frame.height * 0.55)
        // One continuous gesture: consecutive eased segments would sag to a
        // stop between them.
        try await demo.scroll(by: 500, duration: 3.2)
      } else {
        try await demo.hold(3.2)
      }
      try await demo.cut { app.selection = .suggestions }
      try await drift(demo, atX: 0.55, y: 0.58, by: 200, over: 2.4)
    }

    /// Cleanups registered by sections that mutate app or on-disk state, run
    /// after the end card (or on stop) so restores never appear on camera.
    private static var pendingCleanups: [@MainActor () async -> Void] = []

    private static func registerCleanup(_ cleanup: @escaping @MainActor () async -> Void) {
      pendingCleanups.append(cleanup)
    }

    static func runPendingCleanups() async {
      let cleanups = pendingCleanups
      pendingCleanups = []
      for cleanup in cleanups.reversed() {
        await cleanup()
      }
    }

    // MARK: Podcasts

    /// The podcasts beat runs on real data: the first subscription is
    /// selected explicitly, or — with no subscriptions — the first show of
    /// the live popular chart once it loads.
    private static func runPodcasts(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      try await demo.cut { app.selection = .podcasts }
      if let show = app.podcasts.subscriptions.first {
        app.pendingPodcastReveal = show.feedURL
      } else {
        try? await demo.waitUntil(timeout: 8, description: "the popular chart") {
          !app.podcasts.popular.isEmpty
        }
        if let first = app.podcasts.popular.first {
          app.pendingPodcastReveal = first.feedURL
        }
      }
      // Motion never stops: the episode list drifts while the feed shows,
      // then eases back around the expanded show notes.
      try await drift(demo, atX: 0.62, y: 0.52, by: 150, over: 3.0)
      try await demo.hold(0.3)
      // Expand the first visible episode's More button, if any row offers
      // one on screen.
      if try await demo.clickFirstVisible("podcast.episode.more") {
        try await drift(demo, atX: 0.62, y: 0.55, by: -110, over: 2.4)
      } else {
        try await drift(demo, atX: 0.62, y: 0.55, by: 120, over: 2.0)
      }
      try await demo.hold(0.8)
    }

    /// Selects the fake iPod in the sidebar and lingers on the device view.
    /// No sync runs — the beat flips the songs mode from two-way to
    /// one-way (iPod to Library), flashing the dropdown open on the way.
    private static func runIpod(_ demo: DemoScriptContext) async throws {
      let app = demo.app
      guard let device = demoDevice(in: app) else {
        throw DemoScriptError(message: "No demo iPod is connected.")
      }
      try await demo.click("sidebar.device.\(device.volumeURL.lastPathComponent)")
      try await drift(demo, atX: 0.6, y: 0.68, by: 170, over: 2.0)
      let previousMode = app.syncSettings(for: device).trackSyncMode
      registerCleanup {
        app.updateSyncSettings(for: device) { $0.trackSyncMode = previousMode }
      }
      try await demo.flashMenu(
        "device.songsMode", linger: 0.6, selecting: "One-way (iPod to Library)")
      // Belt and braces: if the menu action didn't land, apply the switch
      // directly so the label still changes on camera.
      if app.syncSettings(for: device).trackSyncMode != .ipodToLibrary {
        app.updateSyncSettings(for: device) {
          $0.trackSyncMode = .ipodToLibrary
          $0.removesSongsNotInLibrary = false
          $0.removesSongsOutsideSyncScope = false
        }
      }
      try await drift(demo, atX: 0.6, y: 0.68, by: -140, over: 2.4)
    }

    private static func runFinale(
      _ demo: DemoScriptContext, behindCard: (@MainActor () async -> Void)? = nil
    ) async throws {
      try await demo.showEndCard()
      await behindCard?()
      try await demo.hold(6.0)
    }

    static func demoDevice(in app: AppState) -> IpodDevice? {
      var roots = Set(
        (ProcessInfo.processInfo.environment["NIGHTDRIVE_EXTRA_VOLUMES"] ?? "")
          .split(separator: ":")
          .map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path })
      roots.formUnion(
        app.deviceManager.developmentScanRootURLs.map(\.standardizedFileURL.path))
      guard !roots.isEmpty else { return nil }
      return app.deviceManager.devices.first { device in
        roots.contains(device.volumeURL.standardizedFileURL.path)
          && DevelopmentSafety.isFakeVolume(device.volumeURL)
      }
    }
  }
#endif
