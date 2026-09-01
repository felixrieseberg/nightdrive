import Dispatch
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
final class LibraryTransitionIsolationTests {
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

  private var root: URL!
  private var firstFolder: URL!
  private var secondFolder: URL!

  init() throws {
    root = TestScratch.directory(prefix: "LibraryTransitionIsolation")
    firstFolder = root.appendingPathComponent("first", isDirectory: true)
    secondFolder = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  @Test
  func testSetFolderSynchronouslyPublishesEmptyUnsettledCatalog() async throws {
    try writeTestSong(title: "First", to: firstFolder.appendingPathComponent("first.mp3"))
    try writeTestSong(title: "Second", to: secondFolder.appendingPathComponent("second.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    #expect((library.tracks.map(\.title)) == (["First"]))
    let previousIdentity = library.identityRevision
    let previousDataRevision = library.derivedDataRevision

    try library.setFolder(secondFolder)

    #expect((library.folderURL) == (secondFolder.standardizedFileURL))
    #expect((library.catalog) == (LibraryCatalog()))
    #expect(library.isScanning)
    #expect(!(library.isSettled))
    #expect((library.identityRevision) == (previousIdentity + 1))
    #expect((library.derivedDataRevision) == (previousDataRevision + 1))
    #expect(library.collections(for: .album).isEmpty)

    await library.rescan()
    #expect((library.tracks.map(\.title)) == (["Second"]))
    #expect(library.isSettled)
  }

  @Test
  func testFolderTransitionWaitsForMetadataIOAlreadyInsideBarrier() async throws {
    let oldURL = firstFolder.appendingPathComponent("old.mp3")
    try writeTestSong(title: "Original", to: oldURL)
    try writeTestSong(title: "Current", to: secondFolder.appendingPathComponent("current.mp3"))
    let blocker = FileMutationBlocker()
    let live = LibraryFileMutations.live
    let library = LibraryStore(
      folderURL: firstFolder,
      fileMutations: LibraryFileMutations(
        writeMetadata: { metadata, artworkChange, mediaKindChange, url, expectedGeneration in
          blocker.started.signal()
          blocker.release.wait()
          defer { blocker.finished.signal() }
          try live.writeMetadata(metadata, artworkChange, mediaKindChange, url, expectedGeneration)
        },
        moveToTrash: live.moveToTrash))
    await library.rescan()
    let track = try #require(library.tracks.first)
    var metadata = TrackMetadata(track)
    metadata.title = "Written Before Transition"

    let editTask = Task {
      try await library.updateMetadata(
        for: track, to: metadata, artworkChange: .unchanged)
    }
    let writeStarted = await Task.detached { blocker.waitUntilStarted() }.value
    #expect(writeStarted)

    let transition = TransitionProbe()
    let transitionTask = Task { @MainActor in
      transition.markStarted()
      try library.setFolder(secondFolder)
      transition.markFinished()
    }
    let transitionWaited = await Task.detached {
      transition.release(blocker, afterProvingBlockedFor: .milliseconds(100))
    }.value
    try await transitionTask.value

    #expect(transitionWaited, Comment(rawValue: "setFolder must wait for file I/O holding the barrier"))
    #expect(blocker.hasFinished())
    do {
      try await editTask.value
      Issue.record("The edit completion belongs to the replaced library")
    } catch LibraryStoreError.libraryChanged {
    }
    let writtenTrack = await MetadataLoader.load(url: oldURL)
    #expect((writtenTrack.title) == ("Written Before Transition"))
    await library.rescan()
  }

  @Test
  func testFolderTransitionWaitsForTrashIOAndDropsItsLateAppCompletion() async throws {
    let oldURL = firstFolder.appendingPathComponent("old.mp3")
    try writeTestSong(title: "Original", to: oldURL)
    try writeTestSong(title: "Current", to: secondFolder.appendingPathComponent("current.mp3"))
    let blocker = FileMutationBlocker()
    let live = LibraryFileMutations.live
    let library = LibraryStore(
      folderURL: firstFolder,
      fileMutations: LibraryFileMutations(
        writeMetadata: live.writeMetadata,
        moveToTrash: { url in
          blocker.started.signal()
          blocker.release.wait()
          defer { blocker.finished.signal() }
          try FileManager.default.removeItem(at: url)
        }))
    await library.rescan()
    let track = try #require(library.tracks.first)
    let player = PlayerController()
    let app = AppState(
      library: library,
      player: player,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    player.restore(
      queue: [track], currentID: track.id, position: 0, volume: 1,
      shuffle: false, repeatMode: .off)
    let oldIdentity = library.identityRevision

    let trashTask = Task {
      await app.moveLibraryTracksToTrash(
        [track], expectedLibraryIdentity: oldIdentity)
    }
    let trashStarted = await Task.detached { blocker.waitUntilStarted() }.value
    #expect(trashStarted)

    let transition = TransitionProbe()
    let transitionTask = Task { @MainActor in
      transition.markStarted()
      app.setLibraryFolder(secondFolder)
      transition.markFinished()
    }
    let transitionWaited = await Task.detached {
      transition.release(blocker, afterProvingBlockedFor: .milliseconds(100))
    }.value
    await transitionTask.value

    #expect(transitionWaited, Comment(rawValue: "setFolder must wait for Trash I/O holding the barrier"))
    #expect(blocker.hasFinished())
    let trashResult = await trashTask.value
    #expect(trashResult == nil, Comment(rawValue: "late Trash UI effects must be discarded"))
    #expect(!(FileManager.default.fileExists(atPath: oldURL.path)))
    #expect(player.currentTrack == nil)
    await library.rescan()
  }

  @Test
  func testMetadataEditCapturedFromPreviousLibraryIsRejected() async throws {
    let oldURL = firstFolder.appendingPathComponent("old.mp3")
    try writeTestSong(title: "Original", to: oldURL)
    try writeTestSong(title: "Current", to: secondFolder.appendingPathComponent("current.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    let staleTrack = try #require(library.tracks.first)
    var metadata = TrackMetadata(staleTrack)
    metadata.title = "Wrong Library"

    try library.setFolder(secondFolder)
    await library.rescan()

    do {
      try await library.updateMetadata(
        for: staleTrack, to: metadata, artworkChange: .unchanged)
      Issue.record("Expected a captured edit from the previous library to be rejected")
    } catch LibraryStoreError.libraryChanged {
    }
    let unchangedTrack = await MetadataLoader.load(url: oldURL)
    #expect((unchangedTrack.title) == ("Original"))
  }

  @Test
  func testTrashRequestCapturedFromPreviousLibraryIsRejected() async throws {
    let oldURL = firstFolder.appendingPathComponent("old.mp3")
    try writeTestSong(title: "Original", to: oldURL)
    try writeTestSong(title: "Current", to: secondFolder.appendingPathComponent("current.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    let staleTrack = try #require(library.tracks.first)

    try library.setFolder(secondFolder)
    await library.rescan()
    let result = await library.moveToTrash([staleTrack])

    #expect(result.succeeded.isEmpty)
    #expect((result.failed.map(\.track)) == ([staleTrack]))
    #expect(FileManager.default.fileExists(atPath: oldURL.path))
  }

  @Test
  func testOldIDsCannotContaminateReboundSidecars() async throws {
    try writeTestSong(title: "Old", to: firstFolder.appendingPathComponent("old.mp3"))
    try writeTestSong(title: "New", to: secondFolder.appendingPathComponent("new.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    let oldID = try #require(library.tracks.first).id
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))

    app.setLibraryFolder(secondFolder)
    #expect(app.libraryMutationsDisabled)
    await library.rescan()
    let playlistID = try app.playlists.create(name: "New Library")

    #expect(throws: (any Error).self) { try app.setFavorite(true, for: [oldID]) }
    #expect(throws: (any Error).self) { try app.setRating(5, for: [oldID]) }
    #expect(throws: (any Error).self) { try app.addToPlaylist([oldID], playlistID: playlistID) }
    #expect(app.listeningHistory.metadataByID[oldID] == nil)
    #expect((app.playlists.playlist(withID: playlistID)?.trackIDs) == ([]))
  }

  @Test
  func testFolderTransitionClearsCapturedUIPlaybackAndDelayedHistoryCallback() async throws {
    try writeTestSong(title: "Old", to: firstFolder.appendingPathComponent("old.mp3"))
    try writeTestSong(title: "New", to: secondFolder.appendingPathComponent("new.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    let oldTrack = try #require(library.tracks.first)
    let player = PlayerController()
    let app = AppState(
      library: library,
      player: player,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    player.restore(
      queue: [oldTrack], currentID: oldTrack.id, position: 0, volume: 1,
      shuffle: false, repeatMode: .off)
    app.selectedTrackIDs = [oldTrack.id]
    let previousDismissRequest = app.editInfoDismissRequest

    app.setLibraryFolder(secondFolder)

    #expect(app.selectedTrackIDs.isEmpty)
    #expect((app.editInfoDismissRequest) == (previousDismissRequest + 1))
    #expect(player.currentTrack == nil)
    #expect(player.playbackQueue.isEmpty)
    player.onTrackQualifiedAsPlayed?(oldTrack)
    #expect(app.listeningHistory.metadataByID[oldTrack.id] == nil)

    await library.rescan()
    player.onTrackQualifiedAsPlayed?(oldTrack)
    #expect(app.listeningHistory.metadataByID[oldTrack.id] == nil)
    let currentTrack = try #require(library.tracks.first)
    player.onTrackQualifiedAsPlayed?(currentTrack)
    #expect((app.listeningHistory.playCount(for: currentTrack.id)) == (1))
  }

  @Test
  func testFolderTransitionInvalidatesBlockedMusicBrainzPassAndStaleDismiss() async throws {
    try writeTestSong(title: "Old", to: firstFolder.appendingPathComponent("old.mp3"))
    try writeTestSong(title: "New", to: secondFolder.appendingPathComponent("new.mp3"))
    let library = LibraryStore(folderURL: firstFolder)
    await library.rescan()
    let oldTrack = try #require(library.tracks.first)
    let policy = OnlineServicesPolicy(persistence: MemoryPersistence())
    policy.setConsent(.enabled)
    let service = BlockingMusicBrainzService()
    let suggestions = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
    let suggestion = makeSuggestion(for: oldTrack)
    suggestions.add(suggestion)
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()),
      onlineServices: policy,
      musicBrainz: service,
      musicBrainzSuggestions: suggestions)
    let oldIdentity = library.identityRevision

    app.musicBrainzAutoLookup.refresh()
    let searchStarted = await waitUntil(timeout: .seconds(2)) {
      await service.firstSearchDidStart()
    }
    #expect(searchStarted)
    guard searchStarted else { return }
    app.setLibraryFolder(secondFolder)

    #expect(!(app.musicBrainzAutoLookup.isRunning))
    #expect(app.musicBrainzAutoLookup.lastError == nil)
    #expect(suggestions.suggestions.isEmpty)
    #expect(throws: (any Error).self) {
      try app.dismissMusicBrainzSuggestion(
        suggestion, expectedLibraryIdentity: oldIdentity)
    }
    #expect(!(suggestions.isDismissed(albumKey: suggestion.id)))

    await library.rescan()
    await service.resumeFirstSearch()
    await app.musicBrainzAutoLookup.waitUntilIdle()

    #expect(suggestions.suggestions.isEmpty)
    #expect(!(suggestions.isDismissed(albumKey: suggestion.id)))
    #expect(app.musicBrainzAutoLookup.lastError == nil)
    let releaseFetches = await service.releaseFetches
    #expect(releaseFetches.isEmpty)
  }

  private func makeSuggestion(for track: LibraryTrack) -> MusicBrainzAlbumSuggestion {
    let current = TrackMetadata(track)
    var proposed = current
    proposed.title = "Suggested Old Title"
    return MusicBrainzAlbumSuggestion(
      id: "stale-card-\(track.id.rawValue)",
      albumTitle: track.album,
      artistName: track.artist,
      releaseID: "old-release",
      releaseTitle: track.album,
      releaseYear: 2026,
      tracks: [
        MusicBrainzTrackSuggestion(
          trackKey: track.id.rawValue,
          displayTitle: track.displayTitle,
          current: current,
          proposed: proposed)
      ])
  }

}

private final class FileMutationBlocker: Sendable {
  let started = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  let finished = DispatchSemaphore(value: 0)

  func waitUntilStarted() -> Bool {
    started.wait(timeout: .now() + 2) == .success
  }

  func hasFinished() -> Bool {
    finished.wait(timeout: .now()) == .success
  }
}

private final class TransitionProbe: Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let finished = DispatchSemaphore(value: 0)

  func markStarted() {
    started.signal()
  }

  func markFinished() {
    finished.signal()
  }

  func release(
    _ blocker: FileMutationBlocker,
    afterProvingBlockedFor interval: DispatchTimeInterval
  ) -> Bool {
    guard started.wait(timeout: .now() + 2) == .success else {
      blocker.release.signal()
      return false
    }
    let finishedEarly = finished.wait(timeout: .now() + interval)
    blocker.release.signal()
    return finishedEarly == .timedOut
  }
}

private actor BlockingMusicBrainzService: MusicBrainzService {
  private(set) var releaseFetches: [String] = []
  private var firstSearchStarted = false
  private var firstSearchContinuation: CheckedContinuation<[MusicBrainzReleaseCandidate], Never>?
  private var searchCount = 0

  func firstSearchDidStart() -> Bool {
    firstSearchStarted
  }

  func resumeFirstSearch() {
    firstSearchContinuation?.resume(
      returning: [
        MusicBrainzReleaseCandidate(
          id: "old-release", score: 100, title: "Album", artistName: "Artist",
          date: "2026", country: "US", trackCount: 1)
      ])
    firstSearchContinuation = nil
  }

  func searchRecordings(
    title: String, artist: String, album: String
  ) async throws -> [MusicBrainzRecordingCandidate] {
    []
  }

  func searchReleases(
    artist: String, releaseTitle: String
  ) async throws -> [MusicBrainzReleaseCandidate] {
    searchCount += 1
    guard searchCount == 1 else { return [] }
    firstSearchStarted = true
    return await withCheckedContinuation { firstSearchContinuation = $0 }
  }

  func release(withID id: String) async throws -> MusicBrainzRelease {
    releaseFetches.append(id)
    throw MusicBrainzError.malformedResponse("A stale pass fetched a release")
  }

  func genreNames() async throws -> Set<String> { [] }
}
