import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
struct AppStatePlaybackReconciliationTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private final class MemoryPlaybackStorage: RemovableAppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    var data: Data? {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
    func remove() { data = nil }
  }

  private final class MemoryAppPersistence: AppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    var data: Data? {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
  }

  private final class ToggleHistoryPersistence: AppDataPersistence, Sendable {
    private struct State {
      var data: Data?
      var saveError: Error?
      var saveCount = 0
    }

    private let state = Mutex(State())

    var data: Data? {
      get { state.withLock { $0.data } }
      set { state.withLock { $0.data = newValue } }
    }

    var saveError: Error? {
      get { state.withLock { $0.saveError } }
      set { state.withLock { $0.saveError = newValue } }
    }

    var saveCount: Int {
      state.withLock { $0.saveCount }
    }

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
      try state.withLock { state in
        if let saveError = state.saveError { throw saveError }
        state.saveCount += 1
        state.data = data
      }
    }
  }

  private struct ExpectedHistoryFailure: LocalizedError {
    var errorDescription: String? { "The listening-history sidecar is read-only." }
  }

  private func makeApp(
    library: LibraryStore,
    player: PlayerController,
    listeningHistory: ListeningHistoryStore? = nil,
    playbackPersistence: PlaybackPersistenceStore? = nil
  ) -> AppState {
    AppState(
      library: library, player: player,
      playlists: PlaylistStore(persistence: MemoryAppPersistence()),
      listeningHistory: listeningHistory
        ?? ListeningHistoryStore(persistence: MemoryAppPersistence()),
      playbackPersistence: playbackPersistence
        ?? PlaybackPersistenceStore(persistence: MemoryPlaybackStorage()))
  }

  @Test
  func testLibraryChangeRestoresOnceThenReconcilesCurrentMetadata() async throws {
    let folder = scratch
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let trackURL = folder.appendingPathComponent("song.mp3")
    try writeTestSong(title: "Original", to: trackURL, genre: "Genre")

    let library = LibraryStore(folderURL: folder)
    await library.rescan()
    let storage = MemoryPlaybackStorage()
    let persistence = PlaybackPersistenceStore(persistence: storage)
    try persistence.save(
      PlaybackPersistenceState(
        queueURLs: [trackURL],
        currentURL: trackURL,
        position: 0,
        volume: 0.8,
        shuffleEnabled: false,
        repeatMode: .off))
    let player = PlayerController()
    #expect(library.tracks.count == 1)
    #expect(!(library.isScanning))
    #expect(try persistence.load() != nil)
    let app = makeApp(library: library, player: player, playbackPersistence: persistence)

    app.libraryContentsDidChange()
    #expect(player.playbackIssue == nil)
    #expect(player.playbackQueue.count == 1)
    #expect(player.currentTrack?.title == "Original")

    var metadata = TrackMetadata(try #require(library.tracks.first))
    metadata.title = "Edited"
    try MP3MetadataWriter.write(metadata, to: trackURL)
    await library.rescan()
    app.libraryContentsDidChange()

    #expect(player.currentTrack?.title == "Edited")
    #expect(player.playbackQueue.map(\.title) == ["Edited"])
    #expect(!(player.isPlaying))
    player.stop()
  }

  @Test
  func testLibraryChangePreservesQueueOpenedOutsideTheLibrary() async throws {
    let libraryFolder = scratch.appendingPathComponent("library", isDirectory: true)
    let externalFolder = scratch.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
    try writeTestSong(title: "Library", to: libraryFolder.appendingPathComponent("library.mp3"))
    let externalURL = externalFolder.appendingPathComponent("external.mp3")
    try writeTestSong(title: "External", to: externalURL)

    let library = LibraryStore(folderURL: libraryFolder)
    await library.rescan()
    let player = PlayerController()
    let app = makeApp(library: library, player: player)
    let libraryTrack = try #require(library.tracks.first)
    let externalTrack = await MetadataLoader.load(url: externalURL)
    player.play(externalTrack, in: [libraryTrack, externalTrack])

    var metadata = TrackMetadata(libraryTrack)
    metadata.title = "Library (Edited)"
    try MP3MetadataWriter.write(metadata, to: libraryTrack.url)
    await library.rescan()

    app.libraryContentsDidChange()

    #expect(player.currentTrack?.url == externalURL)
    #expect(player.playbackQueue.map(\.url) == [libraryTrack.url, externalURL])
    #expect(player.playbackQueue.map(\.title) == ["Library (Edited)", "External"])
    player.stop()
  }

  @Test
  func testLibraryChangeDropsDeletedLibraryTrackFromMixedQueue() async throws {
    let libraryFolder = scratch.appendingPathComponent("library", isDirectory: true)
    let externalFolder = scratch.appendingPathComponent("external", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalFolder, withIntermediateDirectories: true)
    let retainedURL = libraryFolder.appendingPathComponent("retained.mp3")
    let deletedURL = libraryFolder.appendingPathComponent("deleted.mp3")
    let externalURL = externalFolder.appendingPathComponent("external.mp3")
    try writeTestSong(title: "Retained", to: retainedURL)
    try writeTestSong(title: "Deleted", to: deletedURL)
    try writeTestSong(title: "External", to: externalURL)

    let library = LibraryStore(folderURL: libraryFolder)
    await library.rescan()
    let libraryTracks = library.tracks.sorted { $0.title < $1.title }
    let retainedTrack = try #require(libraryTracks.first { $0.url.lastPathComponent == retainedURL.lastPathComponent })
    let deletedTrack = try #require(libraryTracks.first { $0.url.lastPathComponent == deletedURL.lastPathComponent })
    let externalTrack = await MetadataLoader.load(url: externalURL)
    let player = PlayerController()
    let app = makeApp(library: library, player: player)
    player.play(retainedTrack, in: [retainedTrack, deletedTrack, externalTrack])

    try FileManager.default.removeItem(at: deletedURL)
    await library.rescan()
    app.libraryContentsDidChange()

    #expect(
      player.playbackQueue.map(\.url.lastPathComponent) == [
        retainedURL.lastPathComponent, externalURL.lastPathComponent,
      ])
    #expect(player.currentTrack?.url.lastPathComponent == retainedURL.lastPathComponent)
    player.stop()
  }

  @Test
  func testQualifiedPlayStaysInMemoryWhenDeferredPersistenceFails() async throws {
    let folder = scratch
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeTestSong(title: "Qualified", to: folder.appendingPathComponent("song.mp3"))
    let library = LibraryStore(folderURL: folder)
    await library.rescan()
    let track = try #require(library.tracks.first)
    let storage = ToggleHistoryPersistence()
    let history = ListeningHistoryStore(persistence: storage)
    let player = PlayerController()
    let app = makeApp(library: library, player: player, listeningHistory: history)
    storage.saveError = ExpectedHistoryFailure()

    player.onTrackQualifiedAsPlayed?(track)
    await app.flushPlaybackState()

    #expect(app.listeningHistoryError == nil)
    #expect(history.persistenceError == "The listening-history sidecar is read-only.")
    #expect(history.playCount(for: track.id) == 1)
    #expect(history.history.map(\.trackID) == [track.id])

    storage.saveError = nil
    player.onTrackQualifiedAsPlayed?(track)
    await app.flushPlaybackState()

    #expect(app.listeningHistoryError == nil)
    #expect(history.persistenceError == nil)
    #expect(storage.saveCount == 1)
    #expect(history.playCount(for: track.id) == 2)
    #expect(history.history.map(\.trackID) == [track.id, track.id])
    player.stop()
  }

  @Test
  func testPodcastPlaybackResumesFromAndUpdatesItsPersistentBookmark() async throws {
    let folder = scratch
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let episodeURL = folder.appendingPathComponent("episode.mp3")
    try writeTestSong(
      title: "Episode", to: episodeURL, genre: "Podcast", seconds: 4)
    let library = LibraryStore(folderURL: folder)
    await library.rescan()
    let episode = try #require(library.tracks.first)
    #expect(episode.mediaKind == .podcast)

    let historyStorage = MemoryAppPersistence()
    let seededHistory = ListeningHistoryStore(persistence: historyStorage)
    try seededHistory.setBookmarkMS(1_250, for: episode.id)
    try await seededHistory.flushPersistence()
    let restoredHistory = ListeningHistoryStore(persistence: historyStorage)
    let player = PlayerController(engineStarter: { _ in
      throw CocoaError(.fileReadUnknown)
    })
    let app = makeApp(
      library: library, player: player, listeningHistory: restoredHistory)

    player.play(episode, in: [episode])
    await player.waitForPendingPreparation()

    #expect(abs(player.elapsed - 1.25) < 0.02)
    player.seek(toTime: 2.5)
    #expect(abs(Double(restoredHistory.bookmarkMS(for: episode.id) ?? 0) - 2_500) < 20)
    await app.flushPlaybackState()

    let reloadedHistory = ListeningHistoryStore(persistence: historyStorage)
    #expect(abs(Double(reloadedHistory.bookmarkMS(for: episode.id) ?? 0) - 2_500) < 20)
    player.seek(to: 1)
    #expect(restoredHistory.bookmarkMS(for: episode.id) == 0)
    player.stop()
  }

  @Test
  func testPodcastBookmarkDuringCancelledScanSurvivesTerminationFlush() async throws {
    let folder = scratch
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let episodeURL = folder.appendingPathComponent("episode.mp3")
    try Data([0]).write(to: episodeURL)
    let blockLoads = Mutex(false)
    let loadsStarted = Mutex(0)
    let gate = TestGate()
    let library = LibraryStore(
      folderURL: folder,
      metadataLoader: { url in
        if blockLoads.withLock({ $0 }) {
          loadsStarted.withLock { $0 += 1 }
          await gate.wait()
        }
        var track = LibraryTrack.fixture(
          url: url, title: "Episode", genre: "Podcast", durationMS: 4_000)
        track.mediaKind = .podcast
        return track
      })
    await library.rescan()
    let episode = try #require(library.tracks.first)
    let history = ListeningHistoryStore(persistence: MemoryAppPersistence())
    let playbackStorage = MemoryPlaybackStorage()
    let playbackPersistence = PlaybackPersistenceStore(persistence: playbackStorage)
    let player = PlayerController()
    let app = makeApp(
      library: library, player: player, listeningHistory: history,
      playbackPersistence: playbackPersistence)

    blockLoads.withLock { $0 = true }
    let scan = Task { await library.rescan() }
    #expect(await waitUntil { loadsStarted.withLock { $0 > 0 } && library.isScanning })

    player.onPlaybackPositionChanged?(episode, 2.5, 4)
    #expect(history.bookmarkMS(for: episode.id) == nil)
    let flushFinished = Mutex(false)
    let flush = Task {
      await app.flushPlaybackState()
      flushFinished.withLock { $0 = true }
    }
    let finishedPromptly = await waitUntil(timeout: .seconds(1)) {
      flushFinished.withLock { $0 }
    }
    if finishedPromptly {
      let loaded = try playbackPersistence.load()
      let saved = try #require(loaded)
      #expect(saved.podcastBookmarkRecovery?.bookmarks[episode.id.rawValue] == 2_500)
      #expect(library.isScanning)
    }

    library.cancelScan()
    player.onPlaybackPositionChanged?(episode, 3, 4)
    await app.flushPlaybackState()
    let cancelledLoaded = try playbackPersistence.load()
    #expect(
      try #require(cancelledLoaded).podcastBookmarkRecovery?.bookmarks[episode.id.rawValue]
        == 3_000)
    await gate.signal()
    await flush.value
    await scan.value
    #expect(finishedPromptly)
    #expect(history.bookmarkMS(for: episode.id) == nil)

    let restoredHistoryStorage = ToggleHistoryPersistence()
    restoredHistoryStorage.saveError = ExpectedHistoryFailure()
    let restoredHistory = ListeningHistoryStore(persistence: restoredHistoryStorage)
    let restoredPlayer = PlayerController()
    let restoredApp = makeApp(
      library: library, player: restoredPlayer, listeningHistory: restoredHistory,
      playbackPersistence: playbackPersistence)
    #expect(restoredPlayer.resumePositionProvider?(episode) == 3)

    blockLoads.withLock { $0 = false }
    await library.rescan()
    #expect(restoredHistory.bookmarkMS(for: episode.id) == 3_000)
    await restoredApp.flushPlaybackState()
    let failedHistoryLoaded = try playbackPersistence.load()
    #expect(
      try #require(failedHistoryLoaded).podcastBookmarkRecovery?.bookmarks[episode.id.rawValue]
        == 3_000)

    restoredHistoryStorage.saveError = nil
    await restoredApp.flushPlaybackState()
    let finalLoaded = try playbackPersistence.load()
    #expect(try #require(finalLoaded).podcastBookmarkRecovery == nil)
    player.stop()
  }

  @Test
  func testPodcastBookmarkRecoveryIsScopedToLibraryResource() async throws {
    let currentFolder = scratch.appendingPathComponent("current", isDirectory: true)
    let otherFolder = scratch.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: currentFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
    try writeTestSong(
      title: "Episode", to: currentFolder.appendingPathComponent("episode.mp3"),
      genre: "Podcast", seconds: 4)
    let library = LibraryStore(folderURL: currentFolder)
    await library.rescan()
    let episode = try #require(library.tracks.first)
    let otherLibrary = LibraryStore(folderURL: otherFolder)
    let otherIdentity = try #require(otherLibrary.resourceIdentity)
    let playbackPersistence = PlaybackPersistenceStore(
      persistence: MemoryPlaybackStorage())
    try playbackPersistence.save(
      PlaybackPersistenceState(
        queueURLs: [], currentURL: nil, position: 0, volume: 1,
        shuffleEnabled: false, repeatMode: .off,
        podcastBookmarkRecovery: PodcastBookmarkRecoveryState(
          libraryIdentity: otherIdentity,
          bookmarks: [episode.id.rawValue: 2_500])))
    let player = PlayerController()
    let app = makeApp(
      library: library, player: player, playbackPersistence: playbackPersistence)

    #expect(player.resumePositionProvider?(episode) == nil)
    await app.flushPlaybackState()
    let loaded = try playbackPersistence.load()
    #expect(try #require(loaded).podcastBookmarkRecovery == nil)
  }

  @Test
  func testPodcastBookmarkRecoverySurvivesTemporarilyUnavailableLibrary() async throws {
    let libraryFolder = scratch.appendingPathComponent("library", isDirectory: true)
    let parkedFolder = scratch.appendingPathComponent("parked", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    let episodeURL = libraryFolder.appendingPathComponent("episode.mp3")
    try writeTestSong(title: "Episode", to: episodeURL, genre: "Podcast", seconds: 4)
    let availableLibrary = LibraryStore(folderURL: libraryFolder)
    let identity = try #require(availableLibrary.resourceIdentity)
    let playbackPersistence = PlaybackPersistenceStore(
      persistence: MemoryPlaybackStorage())
    try playbackPersistence.save(
      PlaybackPersistenceState(
        queueURLs: [], currentURL: nil, position: 0, volume: 1,
        shuffleEnabled: false, repeatMode: .off,
        podcastBookmarkRecovery: PodcastBookmarkRecoveryState(
          libraryIdentity: identity,
          bookmarks: [TrackID(url: episodeURL).rawValue: 2_500])))
    try FileManager.default.moveItem(at: libraryFolder, to: parkedFolder)
    let library = LibraryStore(folderURL: libraryFolder)
    #expect(library.resourceIdentity == nil)
    let history = ListeningHistoryStore(persistence: MemoryAppPersistence())
    let player = PlayerController()
    let app = makeApp(
      library: library, player: player, listeningHistory: history,
      playbackPersistence: playbackPersistence)

    await app.flushPlaybackState()
    let unavailableLoaded = try playbackPersistence.load()
    #expect(
      try #require(unavailableLoaded).podcastBookmarkRecovery?.bookmarks[
        TrackID(url: episodeURL).rawValue
      ] == 2_500)

    try FileManager.default.moveItem(at: parkedFolder, to: libraryFolder)
    await library.rescan()
    let episode = try #require(library.tracks.first)
    #expect(player.resumePositionProvider?(episode) == 2.5)
    #expect(history.bookmarkMS(for: episode.id) == 2_500)

    await app.flushPlaybackState()
    let finalLoaded = try playbackPersistence.load()
    #expect(try #require(finalLoaded).podcastBookmarkRecovery == nil)
  }

  @Test
  func testQualifiedPlayFromReplacedLibraryRemainsIgnored() async throws {
    let parent = scratch
    let first = parent.appendingPathComponent("first", isDirectory: true)
    let second = parent.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try writeTestSong(title: "Old", to: first.appendingPathComponent("song.mp3"))
    let library = LibraryStore(folderURL: first)
    await library.rescan()
    let staleTrack = try #require(library.tracks.first)
    let storage = ToggleHistoryPersistence()
    storage.saveError = ExpectedHistoryFailure()
    let history = ListeningHistoryStore(persistence: storage)
    let player = PlayerController()
    let app = makeApp(library: library, player: player, listeningHistory: history)
    #expect(app.setLibraryFolder(second))
    await library.rescan()

    player.onTrackQualifiedAsPlayed?(staleTrack)

    #expect(app.listeningHistoryError == nil)
    #expect(storage.saveCount == 0)
    #expect(history.playCount(for: staleTrack.id) == 0)
    player.stop()
  }

  @Test
  func testQualifiedPlayFromUnavailableCurrentLibraryPublishesFailure() async throws {
    let parent = scratch
    let folder = parent.appendingPathComponent("library", isDirectory: true)
    let parked = parent.appendingPathComponent("parked", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try writeTestSong(title: "Unavailable", to: folder.appendingPathComponent("song.mp3"))
    let library = LibraryStore(folderURL: folder)
    await library.rescan()
    let track = try #require(library.tracks.first)
    let storage = ToggleHistoryPersistence()
    let history = ListeningHistoryStore(persistence: storage)
    let player = PlayerController()
    let app = makeApp(library: library, player: player, listeningHistory: history)
    try FileManager.default.moveItem(at: folder, to: parked)
    #expect(throws: (any Error).self) { try library.validateAvailableRoot() }
    #expect(library.rootAvailability == .unavailable(.missing))

    player.onTrackQualifiedAsPlayed?(track)

    #expect(
      app.listeningHistoryError == "The music library folder is unavailable. Reconnect or restore it, then rescan.")
    #expect(storage.saveCount == 0)
    #expect(history.playCount(for: track.id) == 0)
    #expect(history.history.isEmpty)
    player.stop()
  }

}
