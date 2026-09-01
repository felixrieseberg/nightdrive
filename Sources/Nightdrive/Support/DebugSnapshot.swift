import AppKit
import SceneKit
import SwiftUI

enum DebugSnapshot {
  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    @MainActor private static var repeatingCaptureTimer: Timer?
  #endif

  enum Scope: String, CaseIterable, Sendable {
    case library
    case playback
    case deck
    case faceplate
    case visualizers
    case settings
    case colorways
    case maintenance
  }

  static var isDrivingTour: Bool {
    ProcessInfo.processInfo.environment["NIGHTDRIVE_SNAPSHOT_DIR"] != nil
  }

  static func requestedScopes(
    _ value: String? = ProcessInfo.processInfo.environment["NIGHTDRIVE_SNAPSHOT_SCOPE"]
  ) -> [Scope] {
    let names = Set(
      (value ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty })
    if names.isEmpty || names.contains("full") { return Scope.allCases }
    let ordered = Scope.allCases.filter { names.contains($0.rawValue) }
    return ordered.isEmpty ? Scope.allCases : ordered
  }

  /// The slice of the visualizer sweep this launch owns, `index/count`
  /// counting from one. Anything unparseable takes the lot.
  static func shard<T>(
    _ items: [T],
    _ value: String? = ProcessInfo.processInfo.environment["NIGHTDRIVE_SNAPSHOT_SHARD"]
  ) -> [T] {
    let parts = (value ?? "").split(separator: "/")
    guard parts.count == 2,
      let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
      let count = Int(parts[1].trimmingCharacters(in: .whitespaces)),
      count > 0, index >= 1, index <= count
    else { return items }
    // Round-robin keeps the slices within one item of each other.
    return items.enumerated().filter { $0.offset % count == index - 1 }.map(\.element)
  }

  @MainActor
  static func armIfRequested(app: AppState) {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      let env = ProcessInfo.processInfo.environment

      if let dir = env["NIGHTDRIVE_SNAPSHOT_DIR"] {
        Task { @MainActor in
          await runTour(app: app, directory: URL(fileURLWithPath: dir, isDirectory: true))
        }
        return
      }

      guard let path = env["NIGHTDRIVE_SNAPSHOT"] else { return }

      if env["NIGHTDRIVE_AUTOPLAY"] == "1" {
        Task { @MainActor in
          await Task.pause(for: .seconds(3))
          if let track = app.library.tracks.first {
            app.player.play(track, in: app.library.tracks)
          }
        }
      }
      if env["NIGHTDRIVE_SELECT"] == "device" {
        Task { @MainActor in
          await Task.pause(for: .seconds(2))
          if let device = snapshotDevice(in: app) {
            app.selection = .device(device.volumeURL)
          }
        }
      }

      repeatingCaptureTimer?.invalidate()
      repeatingCaptureTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        Task { @MainActor in
          capture(to: URL(fileURLWithPath: path))
        }
      }
    #endif
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    @MainActor
    static func captureFrontWindow(to url: URL) {
      capture(to: url)
    }

    @MainActor
    static func runTourFromMenu(app: AppState, directory: URL) async {
      await runTour(app: app, directory: directory)
    }
  #endif

  @MainActor
  private static func runTour(app: AppState, directory: URL) async {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    await app.visualizers.waitUntilReady()

    for scope in requestedScopes() {
      switch scope {
      case .library: await tourLibrary(app: app, directory: directory)
      case .playback: await tourPlayback(app: app, directory: directory)
      case .deck: await tourDeck(app: app, directory: directory)
      case .faceplate: await tourFaceplate(app: app, directory: directory)
      case .visualizers: await tourVisualizers(app: app, directory: directory)
      case .settings: await tourSettings(app: app, directory: directory)
      case .colorways: await tourColorways(app: app, directory: directory)
      case .maintenance: await tourMaintenance(app: app, directory: directory)
      }
    }

    await terminateApplicationAfterFlushing()
  }

  /// The instruments read live audio, so the deck scopes need a track already
  /// past its fade-in or the display reads as almost empty.
  @MainActor
  @discardableResult
  private static func waitForLibrary(app: AppState, playingFrom: Double? = nil) async
    -> LibraryTrack?
  {
    await waitUntil(timeout: 20) { !app.library.isScanning && app.library.folderURL != nil }
    await Task.pause(for: .seconds(1))  // let the table settle
    guard let track = app.library.tracks.first else { return nil }
    if let playingFrom {
      app.player.play(track, in: app.library.tracks)
      app.player.seek(to: playingFrom)
    }
    return track
  }

  @MainActor
  private static func tourLibrary(app: AppState, directory: URL) async {
    await waitForLibrary(app: app)
    capture(to: directory.appendingPathComponent("library.png"))

    if app.library.tracks.count >= 2 {
      app.selectedTrackIDs = Set(app.library.tracks.prefix(2).map(\.id))
      await Task.pause(for: .milliseconds(400))
      capture(to: directory.appendingPathComponent("selection.png"))

      app.requestEditInfo()
      await captureInfoEditor(
        app: app, to: directory.appendingPathComponent("bulk-editor.png"))
      app.selectedTrackIDs.removeAll()
    }

    if let track = app.library.tracks.first {
      app.requestEditInfo(for: Set([track.id]))
      await captureInfoEditor(
        app: app, to: directory.appendingPathComponent("single-editor.png"),
        genreCaptures: (
          empty: directory.appendingPathComponent("single-editor-genre-empty.png"),
          oneCharacter: directory.appendingPathComponent(
            "single-editor-genre-one-character.png"),
          typed: directory.appendingPathComponent("single-editor-genre-typed.png"),
          submitted: directory.appendingPathComponent("single-editor-genre-submitted.png")
        ))
      app.selectedTrackIDs.removeAll()
    }

    if let first = app.library.tracks.first {
      let second =
        app.library.tracks.first {
          $0.artist != first.artist && $0.album != first.album && $0.genre != first.genre
        } ?? app.library.tracks.dropFirst().first
      var selectedTracks = [first]
      if let second { selectedTracks.append(second) }
      app.selectedTrackIDs = Set(selectedTracks.map(\.id))
    }

    for (selection, filename) in [
      (SidebarItem.artists, "artists.png"),
      (.albums, "albums.png"),
      (.genres, "genres.png"),
      (.audiobooks, "audiobooks.png"),
    ] {
      app.selection = selection
      await Task.pause(for: .milliseconds(500))
      capture(to: directory.appendingPathComponent(filename))
    }
    app.selectedTrackIDs.removeAll()
    app.selection = .library
    app.searchText = "no song is called this"
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("search-no-results.png"))
    app.searchText = ""
    // Only shoot the palette with the deck closed: compositeSceneContent
    // repaints SceneKit last, so over an open deck the capture would invert
    // the palette's real z-order and lose the backdrop dim on the glass.
    if let artist = app.library.collections(for: .artist).first {
      app.isQuickSearchPresented = true
      app.quickSearchQuery = ""
      await Task.pause(for: .milliseconds(500))
      capture(to: directory.appendingPathComponent("command-palette.png"))
      app.quickSearchQuery = String(artist.title.prefix(4))
      await Task.pause(for: .milliseconds(500))
      capture(to: directory.appendingPathComponent("quick-search.png"))
      app.dismissQuickSearch()
    }
    app.selection = .suggestions
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("suggestions-disabled.png"))
    // Podcast consent defaults on, but tours must stay offline: turning it
    // off here only touches the tour's disposable defaults suite, and the
    // consent-off pane is itself a state worth shooting.
    app.onlineServices.setPodcastsConsent(.disabled)
    app.selection = .podcasts
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("podcasts.png"))
    if let feedURL = writeSamplePodcastFeed() {
      await app.podcasts.subscribe(feedURL: feedURL)
      await Task.pause(for: .milliseconds(800))
      capture(to: directory.appendingPathComponent("podcasts-show.png"))
      if let subscription = app.podcasts.subscriptions.first(where: { $0.feedURL == feedURL }) {
        app.podcasts.unsubscribe(subscription)
      }
      try? FileManager.default.removeItem(at: feedURL)
    }
    app.selection = .library
    app.selectedTrackIDs.removeAll()
  }

  /// A local file feed so the podcast tour can render a populated show pane
  /// without any network access. Enclosure URLs are parsed but never fetched.
  @MainActor
  private static func writeSamplePodcastFeed() -> URL? {
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
      <channel>
        <title>Nightdrive Radio Hour</title>
        <itunes:author>Nightdrive</itunes:author>
        <description>A show about long drives and longer songs.</description>
        <item>
          <title>Coastal Highways After Dark</title>
          <guid>nightdrive-sample-3</guid>
          <pubDate>Fri, 21 Aug 2026 06:00:00 +0000</pubDate>
          <itunes:duration>52:10</itunes:duration>
          <itunes:episode>3</itunes:episode>
          <description>Sodium lamps, sea fog, and the best exits to nowhere. This week the crew maps a route from the last gas station before the bridge to the first diner that opens before dawn, and argues about which coastline actually sounds better after midnight.</description>
          <enclosure url="https://example.invalid/nightdrive-3.mp3" type="audio/mpeg" length="49000000"/>
        </item>
        <item>
          <title>The Glovebox Tape</title>
          <guid>nightdrive-sample-2</guid>
          <pubDate>Fri, 14 Aug 2026 06:00:00 +0000</pubDate>
          <itunes:duration>47:33</itunes:duration>
          <itunes:episode>2</itunes:episode>
          <description>Every car has one cassette it refuses to explain. Tape submissions: https://example.com/glovebox</description>
          <enclosure url="https://example.invalid/nightdrive-2.mp3" type="audio/mpeg" length="45000000"/>
        </item>
        <item>
          <title>Dashboard Glow</title>
          <guid>nightdrive-sample-1</guid>
          <pubDate>Fri, 07 Aug 2026 06:00:00 +0000</pubDate>
          <itunes:duration>44:05</itunes:duration>
          <itunes:episode>1</itunes:episode>
          <description>Why every good night drive starts at the on-ramp.</description>
          <enclosure url="https://example.invalid/nightdrive-1.mp3" type="audio/mpeg" length="42000000"/>
        </item>
      </channel>
      </rss>
      """
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("nightdrive-snapshot-podcast-\(ProcessInfo.processInfo.processIdentifier).xml")
    do {
      try xml.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      return nil
    }
  }

  @MainActor
  private static func tourPlayback(app: AppState, directory: URL) async {
    guard let track = await waitForLibrary(app: app) else { return }

    await waitUntil(timeout: 10) { !app.deviceManager.devices.isEmpty }
    if let device = snapshotDevice(in: app) {
      let originalSettings = app.syncSettings(for: device)
      defer { app.updateSyncSettings(for: device) { $0 = originalSettings } }
      app.updateSyncSettings(for: device) {
        $0.trackSyncMode = .libraryToIpod
        $0.removesSongsNotInLibrary = true
        $0.removesSongsOutsideSyncScope = false
      }
      app.selection = .device(device.volumeURL)
      await Task.pause(for: .seconds(2))
      capture(to: directory.appendingPathComponent("device.png"))
      app.selection = .library
    }

    app.player.play(track, in: app.library.tracks)
    await Task.pause(for: .seconds(2))
    capture(to: directory.appendingPathComponent("playing.png"))

    app.selection = .upNext
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("up-next.png"))

    app.selection = .playlists
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("playlists.png"))

    try? app.setFavorite(true, for: [track.id])
    app.player.onTrackQualifiedAsPlayed?(track)
    app.selection = .listening
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("listening.png"))

    app.selection = .library
    let snapshotResult = SyncResult(
      copiedToDevice: 2,
      copiedToFolder: 1,
      failures: [
        SyncFailure(
          operation: .copyToDevice,
          path: "Artist/Album/Unreadable Track.flac",
          reason: "The audio file could not be read."),
        SyncFailure(
          operation: .reconstructMetadata,
          path: "iPod_Control/Music/F03/LOSTSONG.MP3",
          reason: "Copied without reconstructed tags because the tag was malformed."),
      ])
    app.recordCompletedSync(snapshotResult, presentingDetails: true)
    await captureSyncDetails(
      app: app, to: directory.appendingPathComponent("sync-details-failures.png"))
  }

  @MainActor
  private static func tourDeck(app: AppState, directory: URL) async {
    await waitForLibrary(app: app, playingFrom: 0.25)
    app.deck.open()
    // Absolute deadlines from the glass's own boot, so neither capture cost
    // nor a loaded machine can slide a shot into the next phase.
    await waitUntil(timeout: 10) { app.deck.bootStart != nil }
    guard let boot = app.deck.bootStart else { return }
    let strike = DeckPanel.strikeDuration

    // The transformer cycle spends its first beats on the latch and linkage;
    // past those, the powered hinge is in motion.
    await sleep(until: boot.addingTimeInterval(0.54))
    capture(to: directory.appendingPathComponent("deck-opening.png"))
    // Mid-hold: ignite, cascade and assemble are done, so the finished line is
    // on the glass with its underline drawn and brackets framing it.
    let hold =
      DeckCeremony.igniteDuration + DeckCeremony.cascadeDuration
      + DeckCeremony.assembleDuration + DeckCeremony.greetingHoldDuration / 2
    await sleep(until: boot.addingTimeInterval(strike + hold))
    capture(to: directory.appendingPathComponent("deck-hello.png"))
    // Past the release wipe and the self-test sweep: the deck at rest with
    // live signal on the glass.
    await sleep(until: boot.addingTimeInterval(strike + DeckCeremony.greetingDuration + 1.6))
    capture(to: directory.appendingPathComponent("deck.png"))

    app.selection = .upNext
    await Task.pause(for: .milliseconds(500))
    capture(to: directory.appendingPathComponent("deck-up-next.png"))
    app.selection = .library
  }

  private static func sleep(until deadline: Date) async {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else { return }
    await Task.pause(for: .seconds(remaining))
  }

  /// The mechanism held still, and the faceplate pulled off the chassis.
  /// Needs no greeting: every shot pins the door at an exact value, which
  /// cancels whatever the motor was doing.
  @MainActor
  private static func tourFaceplate(app: AppState, directory: URL) async {
    await waitForLibrary(app: app, playingFrom: 0.25)
    // The poses pin the door but nothing warms the SceneKit view, which only
    // reports ready after it has rendered once. Seat the deck first so the
    // glass is live by the time a pose is shot.
    await seatDeck(app: app)

    // An animated frame depends on capture timing; these pin the door at exact
    // travel values — barely out of the slot, halfway through its arc, flexing
    // past the end stop — so the geometry can be judged frame by frame.
    for (name, pose) in [
      ("deck-pose-early", CGFloat(0.12)), ("deck-pose-half", 0.5), ("deck-pose-overshoot", 1.08),
    ] {
      app.deck.present(progress: pose, seated: false)
      await Task.pause(for: .milliseconds(450))
      capture(to: directory.appendingPathComponent("\(name).png"))
    }
    await seatDeck(app: app)

    // Both windows are captured explicitly — with the panel up, "first visible
    // window" stops being a safe way to find either.
    let mainWindow = NSApp.windows.first { $0.isVisible }
    app.deck.presentDetached()
    await Task.pause(for: .seconds(1.4))  // panel tube restrike + LED flash
    capture(mainWindow, to: directory.appendingPathComponent("deck-detached.png"))
    let panel = NSApp.windows.first {
      $0.identifier == FaceplatePanelController.windowIdentifier && $0.isVisible
    }
    capture(panel, to: directory.appendingPathComponent("faceplate.png"))
    // Stretched well past natural size to prove the glass reflows, then shrunk
    // to the floor to prove the faceplate scales instead of clipping.
    if let panel {
      panel.setContentSize(NSSize(width: 900, height: 300))
      await Task.pause(for: .milliseconds(600))
      capture(panel, to: directory.appendingPathComponent("faceplate-resized.png"))
      panel.setContentSize(FaceplatePanelController.floorSize)
      await Task.pause(for: .milliseconds(600))
      capture(panel, to: directory.appendingPathComponent("faceplate-mini.png"))
    }
    app.deck.present(progress: 1, seated: true)
    await Task.pause(for: .seconds(1.3))
    app.deck.close()
    await Task.pause(for: .seconds(1.1))
  }

  /// Every registered visualizer in turn, plugins included, so a display
  /// mode can be judged without driving the app by hand. The tour shares the
  /// real preferences domain, so the user's own choice goes back afterwards.
  @MainActor
  private static func tourVisualizers(app: AppState, directory: URL) async {
    await waitForLibrary(app: app, playingFrom: 0.35)
    await seatDeck(app: app)

    let chosen = app.visualizerSelection.visualizerID
    for descriptor in shard(app.visualizers.descriptors) {
      app.visualizerSelection.selectVisualizer(descriptor.id)
      await Task.pause(for: .seconds(1))
      capture(to: directory.appendingPathComponent("deck-\(descriptor.id).png"))
    }
    app.visualizerSelection.selectVisualizer(chosen)
  }

  /// Pins the door open and waits for live instruments. The greeting is
  /// marked as played first: it belongs to the deck scope's own shots, and a
  /// scope that only wants a lit deck should not have to sit through it.
  @MainActor
  private static func seatDeck(app: AppState) async {
    app.deck.greetedThisLaunch = true
    app.deck.present(progress: 1, seated: true)
    // Only the strike and the self-test sweep left before the glass is live.
    await Task.pause(for: .seconds(2.0))
  }

  /// The Settings window: every pane, a plugin previewing, a search that
  /// matches nothing, and a plugin that failed to load. This scope also owns
  /// the compact About window because both are application-level utilities.
  @MainActor
  private static func tourSettings(app: AppState, directory: URL) async {
    guard let settings = await openSettings(app: app) else { return }

    // The Visualizers pane follows the deck. Put it back to the first mode so
    // the pane shot is the same on every run.
    let restoreMode = app.visualizerSelection.visualizerID
    defer { app.visualizerSelection.selectVisualizer(restoreMode) }
    if let first = app.visualizers.descriptors.first?.id { app.visualizerSelection.selectVisualizer(first) }

    for tab in SettingsTab.allCases {
      app.settingsTab = tab
      await Task.pause(for: .seconds(0.9))
      capture(settings, to: directory.appendingPathComponent("settings-\(tab.rawValue).png"))
    }
    app.settingsTab = .visualizers

    // Once more with the last registered mode showing — a plugin, when the
    // folder has any — since previews run every mode through their own
    // instance of the registry, plugins included.
    if let last = app.visualizers.descriptors.last?.id {
      app.visualizerSelection.selectVisualizer(last)
      await Task.pause(for: .seconds(1.5))
      capture(settings, to: directory.appendingPathComponent("settings-visualizers-last.png"))
      app.visualizerSelection.selectVisualizer(app.visualizers.descriptors.first?.id ?? last)
    }

    // A few modes out of the rotation, so the empty pip is on the record
    // next to the filled one. The tail of the list, because that is where
    // the previous shot left the list scrolled to.
    let parked = app.visualizers.descriptors.suffix(3).map(\.id)
    for id in parked { app.visualizerSelection.setVisualizerEnabled(false, for: id) }
    await Task.pause(for: .seconds(0.7))
    capture(settings, to: directory.appendingPathComponent("settings-visualizers-off.png"))
    for id in parked { app.visualizerSelection.setVisualizerEnabled(true, for: id) }
    await Task.pause(for: .seconds(0.4))

    app.visualizerSearch = "zzzz"
    await Task.pause(for: .seconds(0.7))
    capture(settings, to: directory.appendingPathComponent("settings-visualizers-nomatch.png"))
    app.visualizerSearch = ""

    await captureBrokenPlugin(app: app, window: settings, directory: directory)

    let about = AboutWindowPresenter.show()
    await Task.pause(for: .seconds(0.9))
    capture(about, to: directory.appendingPathComponent("about.png"))
    AboutWindowPresenter.close()

    let controls = ControlsWindowPresenter.show()
    await Task.pause(for: .seconds(0.9))
    capture(controls, to: directory.appendingPathComponent("controls.png"))
    ControlsWindowPresenter.close()

    settings.close()
  }

  /// Every tube, because the colourway picker is only as good as the colours
  /// it promises. Its own scope: a sweep the rest of the Settings tour has no
  /// bearing on, and long enough to be worth a process.
  @MainActor
  private static func tourColorways(app: AppState, directory: URL) async {
    guard let settings = await openSettings(app: app) else { return }
    let restoreColorway = app.visualizerSelection.colorwayID
    if let first = app.visualizers.descriptors.first?.id { app.visualizerSelection.selectVisualizer(first) }
    app.settingsTab = .visualizers
    await Task.pause(for: .seconds(0.9))

    for colorway in VisualizerColorway.all {
      app.visualizerSelection.selectColorway(colorway.id)
      await Task.pause(for: .seconds(0.7))
      capture(
        settings, to: directory.appendingPathComponent("settings-colorway-\(colorway.id).png"))
    }
    app.visualizerSelection.selectColorway(restoreColorway)
    settings.close()
  }

  /// The window belongs to the SwiftUI `Settings` scene, so it is opened the
  /// way the menu item opens it and identified as the window that became
  /// visible. A closed settings window stays in `NSApp.windows` and reopens
  /// with the same number, so visibility rather than existence is the test.
  @MainActor
  private static func openSettings(app: AppState) async -> NSWindow? {
    let before = Set(NSApp.windows.filter(\.isVisible).map(\.windowNumber))
    app.settingsTab = .general
    let opened = SettingsWindow.open()

    var settings: NSWindow?
    await waitUntil(timeout: 6) {
      settings = NSApp.windows.first { $0.isVisible && !before.contains($0.windowNumber) }
      return settings != nil
    }
    if settings == nil {
      let titles = NSApp.windows.map { "\($0.title) visible=\($0.isVisible)" }.joined(
        separator: ", ")
      FileHandle.standardError.write(
        Data("snapshot: settings window did not open (sent=\(opened); windows: \(titles))\n".utf8))
    }
    return settings
  }

  /// The failed-plugin state, made real rather than faked: drop a script
  /// that cannot parse into the plugins folder, reload, shoot it, and take
  /// it away again. Only ever runs against a redirected folder, so an
  /// automated run can never write into the user's own plugins.
  @MainActor
  private static func captureBrokenPlugin(
    app: AppState, window: NSWindow, directory: URL
  ) async {
    let env = ProcessInfo.processInfo.environment
    guard let override = env["NIGHTDRIVE_VISUALIZER_DIR"], !override.isEmpty else { return }
    let file = URL(fileURLWithPath: override, isDirectory: true)
      .appendingPathComponent("zz-snapshot-broken.js")
    let source = """
      // Deliberately broken: the snapshot tour uses this to shoot the
      // failed-plugin state, then deletes it again.
      nightdrive.register({ id: "broken", name: "BROKEN" , draw( {
      """
    guard (try? source.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
    defer {
      FileManager.default.bestEffortRemoveItem(at: file)
      app.visualizers.reloadPlugins()
    }
    await app.visualizers.reloadPluginsAndWait()
    capture(window, to: directory.appendingPathComponent("settings-visualizers-issue.png"))
  }

  @MainActor
  /// The poll interval is pure latency — nothing here decides what a shot
  /// contains — so it sits well below the shortest thing worth noticing.
  private static func waitUntil(
    timeout: TimeInterval, pollEvery poll: Duration = .milliseconds(10),
    _ condition: () -> Bool
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      await Task.pause(for: poll)
    }
  }

  @MainActor
  private static func captureInfoEditor(
    app: AppState, to url: URL,
    genreCaptures: (empty: URL, oneCharacter: URL, typed: URL, submitted: URL)? = nil
  ) async {
    var editor: NSWindow?
    await waitUntil(timeout: 4) {
      editor = NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }
      return editor != nil
    }
    guard let editor else { return }
    await Task.pause(for: .milliseconds(400))
    capture(editor, to: url)
    if let genreCaptures,
      let contentView = editor.contentView,
      let field = editableTextField(
        in: contentView, accessibilityIdentifier: "genre-autocomplete-field")
    {
      editor.makeFirstResponder(field)
      await Task.pause(for: .milliseconds(150))
      capture(editor, to: genreCaptures.empty)
      if let fieldEditor = field.currentEditor() as? NSTextView {
        fieldEditor.setSelectedRange(NSRange(location: 0, length: fieldEditor.string.utf16.count))
        fieldEditor.insertText("E", replacementRange: fieldEditor.selectedRange())
        await Task.pause(for: .milliseconds(400))
        capture(editor, to: genreCaptures.oneCharacter)
        fieldEditor.insertText("lectronic", replacementRange: fieldEditor.selectedRange())
        await Task.pause(for: .milliseconds(400))
        capture(editor, to: genreCaptures.typed)
        fieldEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await Task.pause(for: .milliseconds(400))
        capture(editor, to: genreCaptures.submitted)
      }
    }
    app.editInfoDismissRequest += 1
    await waitUntil(timeout: 2) {
      !NSApp.windows.contains { $0.isVisible && $0.sheetParent != nil }
    }
  }

  @MainActor
  private static func editableTextField(
    in root: NSView, accessibilityIdentifier: String
  ) -> NSTextField? {
    var queue = [root]
    var emptyEditableFields: [NSTextField] = []
    var index = 0
    while index < queue.count {
      let view = queue[index]
      if let field = view as? NSTextField, field.isEditable, field.stringValue.isEmpty {
        emptyEditableFields.append(field)
      }
      if view.accessibilityIdentifier() == accessibilityIdentifier {
        if let field = view as? NSTextField, field.isEditable { return field }
        var descendants = view.subviews
        var descendantIndex = 0
        while descendantIndex < descendants.count {
          let descendant = descendants[descendantIndex]
          if let field = descendant as? NSTextField, field.isEditable { return field }
          descendants.append(contentsOf: descendant.subviews)
          descendantIndex += 1
        }
      }
      queue.append(contentsOf: view.subviews)
      index += 1
    }
    return emptyEditableFields.min { $0.frame.width < $1.frame.width }
  }

  @MainActor
  private static func captureSyncDetails(app: AppState, to url: URL) async {
    var details: NSWindow?
    await waitUntil(timeout: 4) {
      details = NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }
      return details != nil
    }
    guard let details else { return }
    await Task.pause(for: .milliseconds(400))
    capture(details, to: url)
    app.isSyncDetailsPresented = false
    await waitUntil(timeout: 2) {
      !NSApp.windows.contains { $0.isVisible && $0.sheetParent != nil }
    }
  }

  /// The maintenance sheets scan or plan against the library before they
  /// have anything to show, so switch to a deliberately messy copy of the
  /// demo library first and give each sheet a beat to finish its pass.
  /// The copy is seeded into a uniquely named folder inside the output
  /// directory so the tour never deletes a path it does not own.
  @MainActor
  private static func tourMaintenance(app: AppState, directory: URL) async {
    let messy = directory.appendingPathComponent(
      "messy-library-\(UUID().uuidString)", isDirectory: true)
    guard (try? DemoSeeder.seedMessyLibrary(at: messy)) != nil else { return }
    let restoreFolder = app.library.folderURL
    defer { if let restoreFolder { app.setLibraryFolder(restoreFolder) } }
    app.setLibraryFolder(messy)
    await waitForLibrary(app: app)

    let sheets: [(ReferenceWritableKeyPath<AppState, Bool>, String)] = [
      (\.isFindDuplicatesPresented, "find-duplicates.png"),
      (\.isCleanUpGenresPresented, "clean-up-genres.png"),
      (\.isFindMetadataProblemsPresented, "find-metadata-problems.png"),
      (\.isOrganizeLibraryPresented, "organize-library.png"),
    ]
    for (flag, filename) in sheets {
      app[keyPath: flag] = true
      await captureMaintenanceSheet(
        to: directory.appendingPathComponent(filename),
        dismiss: { app[keyPath: flag] = false })
    }
  }

  @MainActor
  private static func captureMaintenanceSheet(to url: URL, dismiss: () -> Void) async {
    var sheet: NSWindow?
    await waitUntil(timeout: 4) {
      sheet = NSApp.windows.first { $0.isVisible && $0.sheetParent != nil }
      return sheet != nil
    }
    guard let sheet else { return }
    await Task.pause(for: .seconds(2))  // let the scan or plan finish
    capture(sheet, to: url)
    dismiss()
    await waitUntil(timeout: 2) {
      !NSApp.windows.contains { $0.isVisible && $0.sheetParent != nil }
    }
  }

  /// The device the tour is allowed to open.
  ///
  /// `NIGHTDRIVE_EXTRA_VOLUMES` adds the checkout's fake iPod to the list,
  /// but it does not remove real ones: plug an iPod into the machine
  /// running `make snapshots` and `devices.first` can just as easily be
  /// that. The playback scope temporarily persists removal-enabled sync
  /// settings, so a crash before their restoration must never leave a real
  /// device armed for deletion. When the harness names its own volumes,
  /// only fake volumes among those paths are eligible.
  @MainActor
  private static func snapshotDevice(in app: AppState) -> IpodDevice? {
    snapshotDevice(
      from: app.deviceManager.devices,
      extraVolumes: ProcessInfo.processInfo.environment["NIGHTDRIVE_EXTRA_VOLUMES"])
  }

  static func snapshotDevice(
    from devices: [IpodDevice],
    extraVolumes: String?
  ) -> IpodDevice? {
    let roots = (extraVolumes ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0), isDirectory: true).standardizedFileURL.path }
    guard !roots.isEmpty else {
      return devices.first { DevelopmentSafety.isFakeVolume($0.volumeURL) }
    }
    return devices.first { device in
      roots.contains(device.volumeURL.standardizedFileURL.path)
        && DevelopmentSafety.isFakeVolume(device.volumeURL)
    }
  }

  /// Renders a window to PNG. Defaults to the app's own window; the tour
  /// passes the Settings window explicitly, since by then it is the one in
  /// front and the main window still has to be shot from behind it.
  @MainActor
  private static func capture(
    _ window: NSWindow? = nil, to url: URL
  ) {
    guard let window = window ?? NSApp.windows.first(where: { $0.isVisible }),
      // The frame view (contentView's superview) includes the
      // title bar and toolbar, not just the content.
      let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    view.cacheDisplay(in: view.bounds, to: rep)
    compositeSceneContent(of: view, into: rep)
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: url)
    }
  }

  /// `cacheDisplay` walks the AppKit drawing machinery, which cannot read
  /// Metal-backed layers: SceneKit content comes out blank. Any SCNView in
  /// the captured hierarchy is therefore re-rendered through its own
  /// `snapshot()` — which does go through Metal — and composited into the
  /// bitmap at its place and clipping in the window.
  @MainActor
  private static func compositeSceneContent(of view: NSView, into rep: NSBitmapImageRep) {
    var sceneViews: [SCNView] = []
    func collect(_ candidate: NSView) {
      if let scene = candidate as? SCNView { sceneViews.append(scene) }
      candidate.subviews.forEach(collect)
    }
    collect(view)
    guard !sceneViews.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    for sceneView in sceneViews where !sceneView.isHiddenOrHasHiddenAncestor {
      // visibleRect honours the ancestors' frame clipping; the deck slot's
      // SwiftUI clip is a layer mask AppKit can't see, so the deck view
      // reports how much of itself is really showing.
      var visible = sceneView.visibleRect
      if let deck = sceneView as? DeckSCNView {
        let slot = NSRect(
          x: 0, y: sceneView.bounds.height - deck.contentClipHeight,
          width: sceneView.bounds.width, height: deck.contentClipHeight)
        visible = visible.intersection(slot)
      }
      guard !visible.isEmpty, sceneView.bounds.width > 0 else { continue }
      let image = sceneView.snapshot()
      func contextRect(_ rect: NSRect) -> NSRect {
        var converted = view.convert(rect, from: sceneView)
        if view.isFlipped {
          converted.origin.y = view.bounds.height - converted.maxY
        }
        return converted
      }
      let target = contextRect(visible)
      let scale = image.size.width / sceneView.bounds.width
      let source = NSRect(
        x: visible.minX * scale, y: visible.minY * scale,
        width: visible.width * scale, height: visible.height * scale)
      NSGraphicsContext.saveGraphicsState()
      if let cutout = (sceneView as? DeckSCNView)?.overlayCutout,
        let first = cutout.first
      {
        // The door's live display sits above the scene in the view hierarchy,
        // so the flattened capture already holds it; clip its projected
        // quadrilateral out rather than painting the Metal snapshot over it.
        let clip = NSBezierPath(rect: target)
        func contextPoint(_ point: NSPoint) -> NSPoint {
          var converted = view.convert(point, from: sceneView)
          if view.isFlipped {
            converted.y = view.bounds.height - converted.y
          }
          return converted
        }
        let display = NSBezierPath()
        display.move(to: contextPoint(first))
        for point in cutout.dropFirst() {
          display.line(to: contextPoint(point))
        }
        display.close()
        clip.append(display)
        clip.windingRule = .evenOdd
        clip.addClip()
      }
      image.draw(in: target, from: source, operation: .sourceOver, fraction: 1)
      NSGraphicsContext.restoreGraphicsState()
    }
  }
}
