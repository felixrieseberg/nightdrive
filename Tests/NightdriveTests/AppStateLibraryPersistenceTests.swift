import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
struct AppStateLibraryPersistenceTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private final class MemoryPersistence: RemovableAppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    var data: Data? {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func remove() { data = nil }
  }

  private actor SettingsWriteGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private(set) var completedSettings: SyncDeviceSettings?

    func write(_ settings: SyncDeviceSettings) async {
      started = true
      let waiters = startWaiters
      startWaiters.removeAll()
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { releaseContinuation = $0 }
      completedSettings = settings
    }

    func waitUntilStarted() async {
      guard !started else { return }
      await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
      releaseContinuation?.resume()
      releaseContinuation = nil
    }
  }

  @Test
  func testDefaultStoresRebindButInjectedStoresRemainOwnedByCaller() async throws {
    let root = scratch
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let firstTrack = TrackID(url: first.appendingPathComponent("first.mp3"))
    let secondTrack = TrackID(url: second.appendingPathComponent("second.mp3"))
    let firstPlaylists = PlaylistStore(libraryFolder: first)
    let secondPlaylists = PlaylistStore(libraryFolder: second)
    _ = try firstPlaylists.create(name: "First", trackIDs: [firstTrack])
    _ = try secondPlaylists.create(name: "Second", trackIDs: [secondTrack])
    let firstHistory = ListeningHistoryStore(libraryFolder: first)
    let secondHistory = ListeningHistoryStore(libraryFolder: second)
    try firstHistory.setRating(1, for: firstTrack)
    try secondHistory.setRating(5, for: secondTrack)
    try await firstPlaylists.flushPersistence()
    try await secondPlaylists.flushPersistence()
    try await firstHistory.flushPersistence()
    try await secondHistory.flushPersistence()

    let library = LibraryStore(folderURL: first)
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let defaultPlaylists = app.playlists
    let defaultHistory = app.listeningHistory

    app.setLibraryFolder(second)
    await library.rescan()

    #expect(app.playlists === defaultPlaylists)
    #expect(app.listeningHistory === defaultHistory)
    #expect(app.playlists.playlists.map(\.name) == ["Second"])
    #expect(app.listeningHistory.rating(for: secondTrack) == 5)
    #expect(app.listeningHistory.rating(for: firstTrack) == 0)

    let injectedPlaylists = PlaylistStore(persistence: MemoryPersistence())
    _ = try injectedPlaylists.create(name: "Injected", trackIDs: [firstTrack])
    let injectedHistory = ListeningHistoryStore(persistence: MemoryPersistence())
    try injectedHistory.setRating(3, for: firstTrack)
    let injectedApp = AppState(
      library: LibraryStore(folderURL: first),
      playlists: injectedPlaylists,
      listeningHistory: injectedHistory,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))

    injectedApp.setLibraryFolder(second)
    await injectedApp.library.rescan()

    #expect(injectedApp.playlists === injectedPlaylists)
    #expect(injectedApp.listeningHistory === injectedHistory)
    #expect(injectedApp.playlists.playlists.map(\.name) == ["Injected"])
    #expect(injectedApp.listeningHistory.rating(for: firstTrack) == 3)
  }

  @Test
  func testSyncReconciliationReloadsExternallyChangedSidecars() async throws {
    let root = scratch
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let trackID = TrackID(url: root.appendingPathComponent("song.mp3"))
    _ = try app.playlists.create(name: "Original")
    try app.listeningHistory.setRating(1, for: trackID)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()

    _ = try app.playlists.create(name: "Pending")
    try app.listeningHistory.setRating(5, for: trackID)
    let externalPlaylist = LocalPlaylist(name: "External")
    try LocalPlaylistFile.save([externalPlaylist], libraryFolder: root)
    let externalMetadata = TrackListeningMetadata(trackID: trackID, rating: 3)
    try SidecarJSONFile.save(
      ListeningHistoryPayload(
        metadataByID: [trackID.rawValue: externalMetadata], history: []),
      to: ListeningHistoryFile.url(for: root))

    try await app.reconcileSidecarsForSync()

    #expect(app.playlists.playlists.map(\.id) == [externalPlaylist.id])
    #expect(app.listeningHistory.rating(for: trackID) == 3)
    #expect(!(app.playlists.canReloadDiscardingPendingChanges))
    #expect(!(app.listeningHistory.canReloadDiscardingPendingChanges))
  }

  @Test
  func testOldLibrarySettingsFailureCannotSurfaceAfterFolderSwitch() async throws {
    let root = scratch
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: SyncLedgerStore.url(for: first), withIntermediateDirectories: true)

    let app = AppState(
      library: LibraryStore(folderURL: first),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let device = IpodDevice(
      volumeURL: root.appendingPathComponent("device"), databaseID: 42,
      name: "Test iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000)
    let ledgerLock = try await ScopedAdvisoryLock.acquire(for: first, namespace: .library)
    defer { ledgerLock.unlock() }

    app.setDisplayName("Old Library Name", for: device)
    #expect(app.setLibraryFolder(second))
    ledgerLock.unlock()
    await app.flushSyncSettingsWrites()

    #expect(app.library.folderURL == second.standardizedFileURL)
    #expect(
      app.syncSettingsError == nil,
      Comment(rawValue: "a late failure from the replaced library must not populate its successor's alert"))
  }

  @Test
  func testRejectedSettingsMutationCannotBeClearedByOlderPendingWrite() async throws {
    let parent = scratch
    let libraryFolder = parent.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: libraryFolder, withIntermediateDirectories: true)
    let library = LibraryStore(folderURL: libraryFolder)
    await library.rescan()
    let gate = SettingsWriteGate()
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()),
      syncSettingsWriter: { settings, _, _ in await gate.write(settings) })
    let device = IpodDevice(
      volumeURL: parent.appendingPathComponent("device"), databaseID: 42,
      name: "Test iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000)
    app.setDisplayName("Saved Name", for: device)
    await gate.waitUntilStarted()
    try FileManager.default.removeItem(at: libraryFolder)
    app.setDisplayName("Rejected Name", for: device)
    #expect(app.syncSettingsError == "The music library folder is unavailable. Reconnect or restore it, then rescan.")
    await gate.release()
    await app.flushSyncSettingsWrites()

    #expect(app.syncSettingsError == "The music library folder is unavailable. Reconnect or restore it, then rescan.")
    #expect(app.displayName(for: device) == "Saved Name")
    let completed = await gate.completedSettings
    #expect(completed?.displayName == "Saved Name")
  }
}
