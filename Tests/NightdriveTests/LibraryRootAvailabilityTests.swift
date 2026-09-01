import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
struct LibraryRootAvailabilityTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private final class MemoryPersistence: RemovableAppDataPersistence, Sendable {
    private let stored: Mutex<Data?>

    init(_ data: Data? = nil) { stored = Mutex(data) }

    func load() -> Data? { stored.withLock { $0 } }
    func save(_ data: Data) { stored.withLock { $0 = data } }
    func remove() { stored.withLock { $0 = nil } }
  }

  private final class InspectorToggle: Sendable {
    private let unreadable = Mutex(false)

    func setUnreadable() { unreadable.withLock { $0 = true } }

    func inspect(_ url: URL) -> Result<LibraryRootToken, LibraryRootPreflightError> {
      if unreadable.withLock({ $0 }) {
        return .failure(LibraryRootPreflightError(reason: .unreadable))
      }
      return LibraryRootPreflight.inspect(url)
    }
  }

  @Test
  func testMissingStartupRootNeverSettlesInstallsOrCallsCompletion() async {
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    let store = LibraryStore(folderURL: root)
    var completions = 0
    store.onScanCompleted = { completions += 1 }

    await store.rescan()

    #expect((store.rootAvailability) == (.unavailable(.missing)))
    #expect(!(store.isSettled))
    #expect(!(store.isScanning))
    #expect(store.tracks.isEmpty)
    #expect((completions) == (0))
    #expect(!(FileManager.default.fileExists(atPath: root.path)))
  }

  @Test
  func testAccessibleEmptyRootIsAValidSettledLibrary() async throws {
    let root = scratch
    let store = LibraryStore(folderURL: root)
    var completions = 0
    store.onScanCompleted = { completions += 1 }

    await store.rescan()

    #expect((store.rootAvailability) == (.available))
    #expect(store.isSettled)
    #expect(store.tracks.isEmpty)
    #expect((completions) == (1))
  }

  @Test
  func testMissingStartupRootKeepsPlaybackPendingUntilFirstSuccessfulScan() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let trackURL = root.appendingPathComponent("song.mp3")
    let playbackStorage = MemoryPersistence()
    let playbackPersistence = PlaybackPersistenceStore(persistence: playbackStorage)
    try playbackPersistence.save(
      PlaybackPersistenceState(
        queueURLs: [trackURL], currentURL: trackURL, position: 0.5, volume: 0.8,
        shuffleEnabled: false, repeatMode: .off))
    let library = LibraryStore(folderURL: root)
    let app = AppState(library: library, playbackPersistence: playbackPersistence)

    app.restorePlaybackIfNeeded()
    #expect(app.player.playbackQueue.isEmpty)
    #expect(!(library.isSettled))

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeTestSong(title: "Returned", to: trackURL, seconds: 0.1)
    await library.rescan()
    app.libraryContentsDidChange()

    #expect(library.isSettled)
    #expect((app.player.playbackQueue.map(\.id)) == ([TrackID(url: trackURL)]))
    #expect((app.player.currentTrack?.id) == (TrackID(url: trackURL)))
  }

  @Test
  func testLiveDisappearancePreservesCatalogPlaybackSelectionAndSidecarsUntilAtomicReturn()
    async throws
  {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let parked = parent.appendingPathComponent("parked", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let trackURL = root.appendingPathComponent("song.mp3")
    try writeTestSong(title: "Kept", to: trackURL, seconds: 0.1)

    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let track = try #require(library.tracks.first)
    let playbackStorage = MemoryPersistence()
    let playbackPersistence = PlaybackPersistenceStore(persistence: playbackStorage)
    try playbackPersistence.save(
      PlaybackPersistenceState(
        queueURLs: [trackURL], currentURL: trackURL, position: 0.25, volume: 0.7,
        shuffleEnabled: false, repeatMode: .off))
    let app = AppState(library: library, playbackPersistence: playbackPersistence)
    app.libraryContentsDidChange()
    app.selectedTrackIDs = [track.id]
    let smartID = try app.playlists.createSmart(
      name: "Everything", rule: SmartPlaylistRule(),
      library: library.tracks, facts: app.smartRuleFacts)
    try app.listeningHistory.setRating(2, for: track.id)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()
    let smartBytesBefore = try Data(contentsOf: LocalPlaylistFile.url(for: root))
    var completions = 0
    library.onScanCompleted = { completions += 1 }

    try FileManager.default.moveItem(at: root, to: parked)
    await library.rescan()
    app.libraryContentsDidChange()
    app.refreshSmartPlaylists()

    #expect((library.rootAvailability) == (.unavailable(.missing)))
    #expect(!(library.isSettled))
    #expect((library.tracks.map(\.id)) == ([track.id]))
    #expect((app.selectedTrackIDs) == ([track.id]))
    #expect((app.player.playbackQueue.map(\.id)) == ([track.id]))
    #expect((app.player.currentTrack?.id) == (track.id))
    #expect((app.playlists.playlist(withID: smartID)?.trackIDs) == ([track.id]))
    #expect((app.listeningHistory.rating(for: track.id)) == (2))
    #expect((completions) == (0))
    #expect(
      (try Data(contentsOf: LocalPlaylistFile.url(for: parked))) == (smartBytesBefore),
      Comment(rawValue: "a failed scan must not materialize the smart playlist against an empty catalog"))

    #expect(throws: (any Error).self) { try app.playlists.create(name: "Blocked") }
    #expect(throws: (any Error).self) { try app.listeningHistory.setRating(5, for: track.id) }
    let device = testDevice(in: parent)
    app.setDisplayName("Blocked", for: device)
    await app.flushSyncSettingsWrites()
    app.sync(device)
    if case .idle = app.syncState {} else { Issue.record("unavailable library must not start sync") }
    #expect(!(FileManager.default.fileExists(atPath: root.path)))

    let restoredPlaylist = LocalPlaylist(name: "Restored", trackIDs: [track.id])
    try LocalPlaylistFile.save([restoredPlaylist], libraryFolder: parked)
    let parkedHistory = ListeningHistoryStore(libraryFolder: parked)
    try parkedHistory.setRating(5, for: track.id)
    try await parkedHistory.flushPersistence()
    try FileManager.default.moveItem(at: parked, to: root)

    await library.rescan()

    #expect((library.rootAvailability) == (.available))
    #expect(library.isSettled)
    #expect((completions) == (1))
    #expect((app.playlists.playlists.map(\.name)) == (["Restored"]))
    #expect((app.listeningHistory.rating(for: track.id)) == (5))
    app.libraryContentsDidChange()
    #expect(
      (try LocalPlaylistFile.load(libraryFolder: root).map(\.name)) == (["Restored"]),
      Comment(rawValue: "returning sidecars must reload before catalog observers may materialize rules"))
  }

  @Test
  func testRootReplacementDuringSidecarReloadRollsBackWholePublication() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let parked = parent.appendingPathComponent("parked", isDirectory: true)
    let departed = parent.appendingPathComponent("departed", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let trackURL = root.appendingPathComponent("song.mp3")
    try writeTestSong(title: "Kept", to: trackURL, seconds: 0.1)

    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let previousCatalog = library.catalog
    let trackID = try #require(previousCatalog.tracks.first?.id)
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    _ = try app.playlists.create(name: "Original", trackIDs: [trackID])
    try app.listeningHistory.setRating(2, for: trackID)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()

    try FileManager.default.moveItem(at: root, to: parked)
    await library.rescan()
    #expect((library.rootAvailability) == (.unavailable(.missing)))

    try LocalPlaylistFile.save(
      [LocalPlaylist(name: "Reloaded", trackIDs: [trackID])], libraryFolder: parked)
    let reloadedHistory = ListeningHistoryStore(libraryFolder: parked)
    try reloadedHistory.setRating(5, for: trackID)
    try await reloadedHistory.flushPersistence()
    try FileManager.default.moveItem(at: parked, to: root)
    let playlistBytes = try Data(contentsOf: LocalPlaylistFile.url(for: root))
    let historyBytes = try Data(contentsOf: ListeningHistoryFile.url(for: root))

    let appPreparation = library.onPreparingToInstallScan
    library.onPreparingToInstallScan = { returning in
      let rollback = try appPreparation?(returning)
      do {
        try FileManager.default.moveItem(at: root, to: departed)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      } catch {
        rollback?()
        throw error
      }
      return rollback
    }
    var completions = 0
    library.onScanCompleted = { completions += 1 }

    await library.rescan()

    #expect((library.rootAvailability) == (.unavailable(.replaced)))
    #expect(!(library.isSettled))
    #expect((library.catalog) == (previousCatalog))
    #expect((app.playlists.playlists.map(\.name)) == (["Original"]))
    #expect((app.listeningHistory.rating(for: trackID)) == (2))
    #expect((completions) == (0))
    #expect((try Data(contentsOf: LocalPlaylistFile.url(for: departed))) == (playlistBytes))
    #expect((try Data(contentsOf: ListeningHistoryFile.url(for: departed))) == (historyBytes))
    #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)) == ([]))
  }

  @Test
  func testSidecarReloadFailurePreservesPriorTransactionState() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let parked = parent.appendingPathComponent("parked", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let trackURL = root.appendingPathComponent("song.mp3")
    try writeTestSong(title: "Kept", to: trackURL, seconds: 0.1)

    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let previousCatalog = library.catalog
    let trackID = try #require(previousCatalog.tracks.first?.id)
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    _ = try app.playlists.create(name: "Original", trackIDs: [trackID])
    try app.listeningHistory.setRating(2, for: trackID)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()

    try FileManager.default.moveItem(at: root, to: parked)
    await library.rescan()
    try Data("{malformed".utf8).write(to: LocalPlaylistFile.url(for: parked))
    try FileManager.default.moveItem(at: parked, to: root)
    let playlistBytes = try Data(contentsOf: LocalPlaylistFile.url(for: root))
    let historyBytes = try Data(contentsOf: ListeningHistoryFile.url(for: root))
    var completions = 0
    library.onScanCompleted = { completions += 1 }

    await library.rescan()

    #expect((library.rootAvailability) == (.unavailable(.unreadable)))
    #expect(!(library.isSettled))
    #expect((library.catalog) == (previousCatalog))
    #expect((app.playlists.playlists.map(\.name)) == (["Original"]))
    #expect((app.listeningHistory.rating(for: trackID)) == (2))
    #expect((completions) == (0))
    #expect((try Data(contentsOf: LocalPlaylistFile.url(for: root))) == (playlistBytes))
    #expect((try Data(contentsOf: ListeningHistoryFile.url(for: root))) == (historyBytes))
  }

  @Test
  func testReplacedFileAndUnreadableRootsPreserveInstalledCatalog() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let original = parent.appendingPathComponent("original", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeTestSong(title: "Original", to: root.appendingPathComponent("song.mp3"), seconds: 0.1)
    let store = LibraryStore(folderURL: root)
    await store.rescan()
    let catalog = store.catalog

    try FileManager.default.moveItem(at: root, to: original)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    await store.rescan()
    #expect((store.rootAvailability) == (.unavailable(.replaced)))
    #expect((store.catalog) == (catalog))

    try FileManager.default.removeItem(at: root)
    try Data("not a directory".utf8).write(to: root)
    await store.rescan()
    #expect((store.rootAvailability) == (.unavailable(.notDirectory)))
    #expect((store.catalog) == (catalog))

    try FileManager.default.removeItem(at: root)
    try FileManager.default.moveItem(at: original, to: root)
    let toggle = InspectorToggle()
    let unreadableStore = LibraryStore(
      folderURL: root, rootInspector: { toggle.inspect($0) })
    await unreadableStore.rescan()
    let unreadableCatalog = unreadableStore.catalog
    toggle.setUnreadable()
    await unreadableStore.rescan()
    #expect((unreadableStore.rootAvailability) == (.unavailable(.unreadable)))
    #expect((unreadableStore.catalog) == (unreadableCatalog))
  }

  @Test
  func testLibrarySidecarAndSettingsWritesNeverRecreateMissingRoot() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    let trackID = TrackID(url: root.appendingPathComponent("song.mp3"))

    let playlists = PlaylistStore(libraryFolder: root)
    let history = ListeningHistoryStore(libraryFolder: root)
    _ = try playlists.create(name: "Nope")
    try history.setRating(3, for: trackID)
    do {
      try await playlists.flushPersistence()
      Issue.record("Expected the durable flush to reject the missing library root")
    } catch {}
    do {
      try await history.flushPersistence()
      Issue.record("Expected the durable flush to reject the missing library root")
    } catch {}
    #expect(throws: (any Error).self) { try LocalPlaylistFile.save([LocalPlaylist(name: "Nope")], libraryFolder: root) }
    #expect(throws: (any Error).self) {
      try ListeningHistoryFile.merge(
        DevicePlaybackReport(databaseID: 1, entries: []), libraryFolder: root)
    }
    #expect(throws: (any Error).self) {
      try PendingPlaybackReportStore.save(
        DevicePlaybackReport(databaseID: 1, entries: []), libraryFolder: root)
    }
    var settings = SyncDeviceSettings()
    settings.displayName = "Nope"
    #expect(throws: (any Error).self) {
      try SyncLedgerStore.replaceDeviceSettings(settings, for: 1, libraryFolder: root)
    }

    let app = AppState(
      library: LibraryStore(folderURL: root),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let device = testDevice(in: parent)
    app.setDisplayName("Nope", for: device)
    await app.flushSyncSettingsWrites()

    #expect(!(FileManager.default.fileExists(atPath: root.path)))
    #expect(
      (app.syncSettingsError) == ("The music library folder is unavailable. Reconnect or restore it, then rescan."))
    #expect((app.displayName(for: device)) == (device.name))
  }

  @Test
  func testAvailableLibraryRootPersistsSyncSettingsWithoutError() async throws {
    let parent = scratch
    let root = parent.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let device = testDevice(in: parent)

    app.setDisplayName("Road iPod", for: device)
    await app.flushSyncSettingsWrites()

    #expect(app.syncSettingsError == nil)
    #expect((app.displayName(for: device)) == ("Road iPod"))
    #expect((SyncLedgerStore.deviceSettings(for: 1, libraryFolder: root).displayName) == ("Road iPod"))
  }

  private func testDevice(in parent: URL) -> IpodDevice {
    IpodDevice(
      volumeURL: parent.appendingPathComponent("device", isDirectory: true),
      databaseID: 1, name: "Test iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000)
  }
}

@Suite(.tags(.fakeIpod))
struct LibraryRootSyncAvailabilityTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  @Test
  func testSyncRefusesPreviewWhenLibraryDisappearsWithoutRecreatingIt() async throws {
    var deviceTrack = try putTrackOnIpod(title: "Device Only", artist: "Artist")
    deviceTrack.dbid = 77
    var database = ITunesDatabase()
    database.tracks = [deviceTrack]
    try fs.writeDatabase(database)
    let plan = SyncEngine.makePlan(library: [], device: database.tracks)
    #expect((plan.copyToFolder.count) == (1))
    let parked = scratch.appendingPathComponent("parked-library", isDirectory: true)
    try FileManager.default.moveItem(at: libraryDir, to: parked)

    do {
      _ = try await runSync(plan)
      Issue.record("sync must reject a library that disappeared after preview")
    } catch let error as LibraryRootPreflightError {
      #expect((error.reason) == (.missing))
    }

    #expect(!(FileManager.default.fileExists(atPath: libraryDir.path)))
    #expect((try fs.readDatabase().tracks.map(\.dbid)) == ([77]))
  }
}
