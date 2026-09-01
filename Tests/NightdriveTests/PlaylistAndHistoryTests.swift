import Foundation
import Synchronization
import Testing

@testable import Nightdrive

private final class MemoryAppDataPersistence: AppDataPersistence, Sendable {
  private struct State {
    var data: Data?
    var error: Error?
    var loadCount = 0
    var saveCount = 0
  }

  private let state = Mutex(State())

  var data: Data? {
    get { state.withLock { $0.data } }
    set { state.withLock { $0.data = newValue } }
  }

  var error: Error? {
    get { state.withLock { $0.error } }
    set { state.withLock { $0.error = newValue } }
  }

  var saveCount: Int {
    state.withLock { $0.saveCount }
  }

  var loadCount: Int {
    state.withLock { $0.loadCount }
  }

  func load() throws -> Data? {
    try state.withLock { state in
      state.loadCount += 1
      if let error = state.error { throw error }
      return state.data
    }
  }

  func save(_ data: Data) throws {
    try state.withLock { state in
      if let error = state.error { throw error }
      state.saveCount += 1
      state.data = data
    }
  }
}

private final class GatedFailingPersistence: AppDataPersistence, @unchecked Sendable {
  private let started = Mutex(false)
  private let release = DispatchSemaphore(value: 0)

  var saveStarted: Bool { started.withLock { $0 } }

  func load() -> Data? { nil }

  func save(_: Data) throws {
    started.withLock { $0 = true }
    release.wait()
    throw ExpectedPersistenceFailure()
  }

  func releaseSave() {
    release.signal()
  }
}

private struct ExpectedPersistenceFailure: LocalizedError {
  var errorDescription: String? { "Expected persistence failure" }
}

@MainActor
struct PlaylistAndHistoryTests {
  @Test
  func testSnapshotWriterWillNotOverwriteANewerGeneration() async throws {
    let persistence = MemoryAppDataPersistence()
    let writer = AppDataSnapshotWriter<[String]>(persistence: persistence)

    try await writer.save(["newer"], generation: 2)
    try await writer.save(["stale"], generation: 1)

    let data = try #require(persistence.data)
    #expect(try JSONDecoder().decode([String].self, from: data) == ["newer"])
    #expect(persistence.saveCount == 1)
  }

  @Test
  func testFlushDrainsRetiredWritesBeforeCheckingCurrentWritability() async throws {
    let root = TestScratch.directory(prefix: "NightdriveRetiredSidecarWrite")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: LocalPlaylistFile.url(for: root))

    let persistence = GatedFailingPersistence()
    defer { persistence.releaseSave() }
    let store = PlaylistStore(
      persistence: persistence, persistenceDebounce: .seconds(30))
    _ = try store.create(name: "Previous library edit")
    store.useLibraryFolder(root)
    while !persistence.saveStarted { await Task.yield() }

    let began = Mutex(false)
    let finished = Mutex(false)
    let flush = Task { @MainActor in
      began.withLock { $0 = true }
      defer { finished.withLock { $0 = true } }
      do {
        try await store.flushPersistence()
        return false
      } catch {
        return error is AppDataRetiredWriteError
      }
    }
    while !began.withLock({ $0 }) { await Task.yield() }
    await Task.yield()
    #expect(!(finished.withLock { $0 }))

    persistence.releaseSave()
    let reportedRetiredFailure = await flush.value
    #expect(reportedRetiredFailure)
  }

  @Test
  func testBurstMutationsUseOneDecodedSnapshotAndOneDurableWrite() async throws {
    let persistence = MemoryAppDataPersistence()
    let store = ListeningHistoryStore(
      persistence: persistence, persistenceDebounce: .seconds(30))

    for index in 0..<100 {
      try store.setRating(
        index % 6,
        for: TrackID(url: URL(fileURLWithPath: "/Music/Track-\(index).mp3")))
    }

    #expect(persistence.loadCount == 1, Comment(rawValue: "mutations must not reread the sidecar"))
    #expect(persistence.saveCount == 0, Comment(rawValue: "the burst should remain debounced"))

    try await store.flushPersistence()

    #expect(persistence.loadCount == 1)
    #expect(persistence.saveCount == 1, Comment(rawValue: "the flush should persist only the newest snapshot"))
  }

  @Test
  func testPlaylistLifecycleOrderAndPersistence() async throws {
    let persistence = MemoryAppDataPersistence()
    let store = PlaylistStore(persistence: persistence)
    let playlistID = try store.create(name: "  Road Trip  ")
    let first = URL(fileURLWithPath: "/Music/Album/../First.mp3")
    let normalizedFirst = URL(fileURLWithPath: "/Music/First.mp3")
    let second = URL(fileURLWithPath: "/Music/Second.mp3")

    try store.add([first, second, normalizedFirst].map(TrackID.init(url:)), to: playlistID)
    #expect(store.playlist(withID: playlistID)?.name == "Road Trip")
    #expect(store.playlist(withID: playlistID)?.trackIDs == [normalizedFirst, second].map(TrackID.init(url:)))
    #expect(store.contains(TrackID(url: first), in: playlistID))

    try store.move(from: IndexSet(integer: 1), to: 0, in: playlistID)
    try store.rename(playlistID, to: "Driving")
    try await store.flushPersistence()

    let restored = PlaylistStore(persistence: persistence)
    #expect(restored.playlist(withID: playlistID)?.name == "Driving")
    #expect(restored.playlist(withID: playlistID)?.trackIDs == [second, normalizedFirst].map(TrackID.init(url:)))

    try restored.remove(TrackID(url: normalizedFirst), from: playlistID)
    #expect(restored.playlist(withID: playlistID)?.trackIDs == [TrackID(url: second)])
    try restored.delete(playlistID)
    #expect(restored.playlists.isEmpty)
  }

  @Test
  func testPlaylistResolvesCurrentTracksWithoutDiscardingMissingMembers() throws {
    let store = PlaylistStore(persistence: MemoryAppDataPersistence())
    let playlistID = try store.create(name: "Mix")
    let missingURL = URL(fileURLWithPath: "/Music/Missing.mp3")
    let second = makeTrack(path: "/Music/Second.mp3", title: "Second")
    let first = makeTrack(path: "/Music/First.mp3", title: "First")

    try store.add([second.url, missingURL, first.url].map(TrackID.init(url:)), to: playlistID)
    #expect(store.tracks(in: playlistID, from: LibraryCatalog([first, second])).map(\.title) == ["Second", "First"])
    #expect(store.playlist(withID: playlistID)?.trackIDs.count == 3)
  }

  @Test
  func testLibraryCatalogPreservesOrderStandardizesURLsAndToleratesCollisions() {
    let first = makeTrack(path: "/Music/First.mp3", title: "First")
    let duplicate = makeTrack(path: "/Music/Album/../First.mp3", title: "Duplicate")
    let second = makeTrack(path: "/Music/Second.mp3", title: "Second")
    let missing = URL(fileURLWithPath: "/Music/Missing.mp3")
    let catalog = LibraryCatalog([first, duplicate, second])

    #expect(
      catalog.tracks(for: [second.url, missing, duplicate.url].map(TrackID.init(url:)))
        .map(\.title) == ["Second", "First"])
    #expect(catalog[duplicate.id]?.title == "First")
    #expect(
      catalog.tracksInLibraryOrder(
        for: Set([second.url, duplicate.url, missing].map(TrackID.init(url:)))
      ).map(\.title) == ["First", "Second"])
  }

  @Test
  func testLibraryCatalogLooksUpByRenormalizedID() {
    let first = makeTrack(path: "/Music/First.mp3", title: "First")
    let second = makeTrack(path: "/Music/Second.mp3", title: "Second")
    let catalog = LibraryCatalog([first, second])

    #expect(catalog[second.id]?.title == "Second")
    #expect(catalog[TrackID(url: URL(fileURLWithPath: "/Music/x/../First.mp3"))]?.title == "First")
    #expect(catalog[TrackID(rawValue: "/Music/First.mp3")] == nil)
  }

  @Test
  func testTrackIDsAreStableAcrossEquivalentSpellings() {
    let plain = URL(fileURLWithPath: "/Music/Songs/One.mp3")
    let indirect = URL(fileURLWithPath: "/Music/Songs/Album/../One.mp3")
    let other = URL(fileURLWithPath: "/Music/Songs/Two.mp3")

    #expect(TrackID(url: plain) == TrackID(url: indirect))
    #expect(TrackID(url: plain) == TrackID(url: plain))
    #expect(TrackID(url: plain) != TrackID(url: other))
  }

  @Test
  func testListeningLookupsCollapseEquivalentURLSpellings() throws {
    let store = ListeningHistoryStore(persistence: MemoryAppDataPersistence())
    let rated = URL(fileURLWithPath: "/Music/Rated.mp3")
    let indirect = URL(fileURLWithPath: "/Music/Album/../Rated.mp3")
    let untouched = URL(fileURLWithPath: "/Music/Untouched.mp3")
    try store.setRating(4, for: TrackID(url: rated))
    _ = try store.toggleFavorite(TrackID(url: rated))

    #expect(store.rating(for: TrackID(url: indirect)) == 4)
    #expect(store.isFavorite(TrackID(url: indirect)))
    #expect(store.rating(for: TrackID(url: untouched)) == 0)
    #expect(!(store.isFavorite(TrackID(url: untouched))))
  }

  @Test
  func testLastPlayedTextUsesCalendarDayBuckets() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let locale = Locale(identifier: "en_US")
    let now = try date(2026, 8, 5, hour: 8, calendar: calendar)

    #expect(
      lastPlayedText(
        for: try date(2026, 8, 5, hour: 1, calendar: calendar),
        relativeTo: now, calendar: calendar, locale: locale) == "Last played today")
    #expect(
      lastPlayedText(
        for: try date(2026, 8, 4, hour: 23, calendar: calendar),
        relativeTo: now, calendar: calendar, locale: locale) == "Last played yesterday")
    #expect(
      lastPlayedText(
        for: try date(2026, 8, 3, calendar: calendar),
        relativeTo: now, calendar: calendar, locale: locale) == "Last played on Monday")
    #expect(
      lastPlayedText(
        for: try date(2026, 4, 15, calendar: calendar),
        relativeTo: now, calendar: calendar, locale: locale) == "Last played on April 15")
    #expect(
      lastPlayedText(
        for: try date(2025, 12, 15, calendar: calendar),
        relativeTo: now, calendar: calendar, locale: locale) == "Last played on December 15, 2025")
  }

  @Test
  func testLargeCatalogResolvesSparsePlaylistInPlaylistOrder() {
    let library = (0..<10_000).map {
      makeTrack(path: "/Music/Track-\($0).mp3", title: "Track \($0)")
    }
    let requested = stride(from: 9_999, through: 0, by: -997).map {
      TrackID(url: URL(fileURLWithPath: "/Music/Folder/../Track-\($0).mp3"))
    }
    let expectedTitles = stride(from: 9_999, through: 0, by: -997).map { "Track \($0)" }

    #expect(LibraryCatalog(library).tracks(for: requested).map(\.title) == expectedTitles)
  }

  @Test
  func testPlaylistMutationRemainsAuthoritativeWhenDeferredPersistenceFails() async throws {
    let persistence = MemoryAppDataPersistence()
    let store = PlaylistStore(persistence: persistence)
    let playlistID = try store.create(name: "Original")
    persistence.error = ExpectedPersistenceFailure()

    try store.rename(playlistID, to: "Changed")
    #expect(store.playlist(withID: playlistID)?.name == "Changed")
    do {
      try await store.flushPersistence()
      Issue.record("Expected the durable flush to report the write failure")
    } catch {}
    #expect(store.persistenceError != nil)
  }

  @Test
  func testBulkPlaylistRemovalIsAtomicInMemoryWhenPersistenceFails() async throws {
    let persistence = MemoryAppDataPersistence()
    let store = PlaylistStore(persistence: persistence)
    let urls = [
      URL(fileURLWithPath: "/Music/First.mp3"),
      URL(fileURLWithPath: "/Music/Second.mp3"),
      URL(fileURLWithPath: "/Music/Third.mp3"),
    ]
    let playlistID = try store.create(name: "Mix", trackURLs: urls)
    let ids = urls.map(TrackID.init(url:))

    try store.remove([ids[0], ids[2]], from: playlistID)
    #expect(store.playlist(withID: playlistID)?.trackIDs == [ids[1]])

    try store.add([ids[0], ids[2]], to: playlistID)
    let beforeFailure = store.playlist(withID: playlistID)?.trackIDs
    persistence.error = ExpectedPersistenceFailure()

    try store.remove([ids[0], ids[1]], from: playlistID)
    #expect(store.playlist(withID: playlistID)?.trackIDs != beforeFailure)
    #expect(store.playlist(withID: playlistID)?.trackIDs == [ids[2]])
    do {
      try await store.flushPersistence()
      Issue.record("Expected the durable flush to report the write failure")
    } catch {}
    #expect(store.persistenceError != nil)
  }

  @Test
  func testPickerAdditionsPreserveLibraryOrderAndExcludeExistingTracks() {
    let first = makeTrack(path: "/Music/First.mp3", title: "First")
    let second = makeTrack(path: "/Music/Second.mp3", title: "Second")
    let third = makeTrack(path: "/Music/Third.mp3", title: "Third")

    let additions = orderedPlaylistPickerAdditions(
      library: [third, first, second],
      selection: [second.id, first.id, third.id],
      initiallySelected: [first.id])

    #expect(additions == [third.id, second.id])
  }

  @Test
  func testCreateWithTracksIsAtomicAndDeduplicatesNormalizedURLs() throws {
    let store = PlaylistStore(persistence: MemoryAppDataPersistence())
    let original = URL(fileURLWithPath: "/Music/Album/../First.mp3")
    let duplicate = URL(fileURLWithPath: "/Music/First.mp3")
    let second = URL(fileURLWithPath: "/Music/Second.mp3")

    let playlistID = try store.create(
      name: "Queue",
      trackURLs: [original, second, duplicate])

    #expect(store.playlist(withID: playlistID)?.trackIDs == [duplicate, second].map(TrackID.init(url:)))
  }

  @Test
  func testM3UImportResolvesRelativeAndAbsoluteLocalEntries() throws {
    let store = PlaylistStore(persistence: MemoryAppDataPersistence())
    let directory = URL(fileURLWithPath: "/Users/test/Music/Playlists", isDirectory: true)
    let contents = """
      #EXTM3U
      #EXTINF:123,Artist - One
      ../Album/One%20Song.mp3
      file:///Users/test/Music/Two%20Words.mp3
      file://localhost/Users/test/Music/Localhost.mp3
      /Users/test/Music/Três.mp3

      """

    let playlistID = try store.importM3U(
      Data(contents.utf8),
      named: "Imported",
      relativeTo: directory)

    #expect(
      store.playlist(withID: playlistID)?.trackIDs
        == [
          URL(fileURLWithPath: "/Users/test/Music/Album/One Song.mp3"),
          URL(fileURLWithPath: "/Users/test/Music/Two Words.mp3"),
          URL(fileURLWithPath: "/Users/test/Music/Localhost.mp3"),
          URL(fileURLWithPath: "/Users/test/Music/Três.mp3"),
        ].map(TrackID.init(url:)))
  }

  @Test
  func testM3UExportRoundTripsPlaylistOrderAndUnicode() throws {
    let source = PlaylistStore(persistence: MemoryAppDataPersistence())
    let urls = [
      URL(fileURLWithPath: "/Music/Two Words.mp3"),
      URL(fileURLWithPath: "/Music/Três.mp3"),
    ]
    let sourceID = try source.create(name: "Source", trackURLs: urls)

    let exported = try source.exportM3U(sourceID)
    #expect(String(decoding: exported, as: UTF8.self).hasPrefix("#EXTM3U\n"))

    let destination = PlaylistStore(persistence: MemoryAppDataPersistence())
    let importedID = try destination.importM3U(
      exported,
      named: "Round Trip",
      relativeTo: URL(fileURLWithPath: "/tmp", isDirectory: true))
    #expect(destination.playlist(withID: importedID)?.trackIDs == urls.map(TrackID.init(url:)))
  }

  @Test
  func testM3UImportRejectsRemoteAndEmptyPlaylists() throws {
    let store = PlaylistStore(persistence: MemoryAppDataPersistence())
    let base = URL(fileURLWithPath: "/Music", isDirectory: true)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try store.importM3U(
          Data("https://example.com/song.mp3\n".utf8),
          named: "Remote",
          relativeTo: base)
      }
      if let caughtError {
        #expect(caughtError as? PlaylistStoreError == .unsupportedM3UEntry("https://example.com/song.mp3"))
      }
    }

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try store.importM3U(
          Data("#EXTM3U\n# Just comments\n".utf8),
          named: "Empty",
          relativeTo: base)
      }
      if let caughtError {
        #expect(caughtError as? PlaylistStoreError == .noImportableTracks)
      }
    }
    #expect(store.playlists.isEmpty)
  }

  @Test
  func testM3UImportRejectsOpaqueAndRemoteAuthorityFileURLs() throws {
    let store = PlaylistStore(persistence: MemoryAppDataPersistence())
    let base = URL(fileURLWithPath: "/Music", isDirectory: true)
    let unsupportedEntries = [
      "file:relative.mp3",
      "file://music-server/Music/Song.mp3",
      "file://user@localhost/Music/Song.mp3",
    ]

    for entry in unsupportedEntries {
      do {
        let caughtError = #expect(throws: (any Error).self) {
          try store.importM3U(
            Data("\(entry)\n".utf8),
            named: "Unsafe",
            relativeTo: base)
        }
        if let caughtError {
          #expect(caughtError as? PlaylistStoreError == .unsupportedM3UEntry(entry))
        }
      }
    }
    #expect(store.playlists.isEmpty)
  }

  @Test
  func testRatingsFavoritesHistoryAndPersistence() async throws {
    let persistence = MemoryAppDataPersistence()
    let first = TrackID(url: URL(fileURLWithPath: "/Music/First.mp3"))
    let second = TrackID(url: URL(fileURLWithPath: "/Music/Second.mp3"))
    let store = ListeningHistoryStore(persistence: persistence, historyLimit: 2)
    let firstDate = Date(timeIntervalSince1970: 100)
    let secondDate = Date(timeIntervalSince1970: 200)
    let thirdDate = Date(timeIntervalSince1970: 300)

    try store.setRating(9, for: first)
    #expect(store.rating(for: first) == 5)
    #expect(try store.toggleFavorite(first))
    try store.recordPlay(of: first, at: firstDate)
    try store.recordPlay(of: second, at: secondDate)
    try store.recordPlay(of: first, at: thirdDate)

    #expect(store.metadata(for: first).playCount == 2)
    #expect(store.metadata(for: first).lastPlayedAt == thirdDate)
    #expect(store.history.map(\.playedAt) == [thirdDate, secondDate])
    try await store.flushPersistence()

    let restored = ListeningHistoryStore(persistence: persistence, historyLimit: 2)
    #expect(restored.rating(for: first) == 5)
    #expect(restored.isFavorite(first))
    #expect(restored.metadata(for: first).playCount == 2)
    #expect(restored.history.map(\.playedAt) == [thirdDate, secondDate])

    try restored.clearHistory()
    #expect(restored.history.isEmpty)
    #expect(restored.metadata(for: first).playCount == 2)
  }

  @Test
  func testPlaybackBookmarkPersistsAndAvoidsNoOpWrites() async throws {
    let persistence = MemoryAppDataPersistence()
    let trackID = TrackID(url: URL(fileURLWithPath: "/Music/Episode.mp3"))
    let store = ListeningHistoryStore(persistence: persistence)

    try store.setBookmarkMS(42_500, for: trackID)
    try store.setBookmarkMS(42_500, for: trackID)
    try await store.flushPersistence()

    #expect(persistence.saveCount == 1)
    #expect(store.bookmarkMS(for: trackID) == 42_500)
    let restored = ListeningHistoryStore(persistence: persistence)
    #expect(restored.bookmarkMS(for: trackID) == 42_500)

    try restored.setBookmarkMS(0, for: trackID)
    try await restored.flushPersistence()
    #expect(ListeningHistoryStore(persistence: persistence).bookmarkMS(for: trackID) == 0)
  }

  @Test
  func testListeningHistoryMutationActionsSurfaceCallbackFailures() {
    enum CallbackFailure: String, LocalizedError {
      case favorite, rating, reset

      var errorDescription: String? { "Expected \(rawValue) callback failure" }
    }

    let trackID = TrackID(url: URL(fileURLWithPath: "/Music/First.mp3"))
    let store = ListeningHistoryStore(persistence: MemoryAppDataPersistence())
    let errors = ListeningHistoryMutationErrors()
    var favoriteCalls: [TrackID] = []
    var ratingCalls: [(Int, TrackID)] = []
    var resetCalls: [TrackID] = []
    let actions = ListeningHistoryMutationActions(
      store: store,
      errors: errors,
      onToggleFavorite: {
        favoriteCalls.append($0)
        throw CallbackFailure.favorite
      },
      onSetRating: {
        ratingCalls.append(($0, $1))
        throw CallbackFailure.rating
      },
      onResetStatistics: {
        resetCalls.append($0)
        throw CallbackFailure.reset
      })

    actions.toggleFavorite(trackID)
    #expect(errors.message == "Expected favorite callback failure")

    actions.setRating(4, for: trackID)
    #expect(errors.message == "Expected rating callback failure")

    actions.resetStatistics(for: trackID)
    #expect(errors.message == "Expected reset callback failure")

    #expect(favoriteCalls == [trackID])
    #expect(ratingCalls.count == 1)
    #expect(ratingCalls.first?.0 == 4)
    #expect(ratingCalls.first?.1 == trackID)
    #expect(resetCalls == [trackID])
    #expect(!(store.isFavorite(trackID)))
    #expect(store.rating(for: trackID) == 0)
    #expect(store.playCount(for: trackID) == 0)
  }

  @Test
  func testListeningHistoryMutationActionsUseDirectStoreFallbacks() async throws {
    let persistence = MemoryAppDataPersistence()
    let trackID = TrackID(url: URL(fileURLWithPath: "/Music/First.mp3"))
    let store = ListeningHistoryStore(persistence: persistence)
    let errors = ListeningHistoryMutationErrors()
    let actions = ListeningHistoryMutationActions(store: store, errors: errors)
    try store.recordPlay(of: trackID)
    try await store.flushPersistence()
    persistence.error = ExpectedPersistenceFailure()

    actions.toggleFavorite(trackID)
    #expect(errors.message == nil)
    #expect(store.isFavorite(trackID))
    do {
      try await store.flushPersistence()
      Issue.record("Expected the durable flush to report the write failure")
    } catch {}
    #expect(store.persistenceError != nil)
    persistence.error = nil

    actions.setRating(4, for: trackID)
    actions.resetStatistics(for: trackID)
    try await store.flushPersistence()

    #expect(errors.message == nil)
    #expect(store.rating(for: trackID) == 4)
    #expect(store.isFavorite(trackID))
    #expect(store.playCount(for: trackID) == 0)
    #expect(store.history.isEmpty)
    #expect(persistence.saveCount == 2)
  }

  @Test
  func testListeningHistoryMutationErrorsDismissAndClearAfterRecovery() {
    let trackID = TrackID(url: URL(fileURLWithPath: "/Music/First.mp3"))
    let store = ListeningHistoryStore(persistence: MemoryAppDataPersistence())
    let errors = ListeningHistoryMutationErrors()
    var shouldFail = true
    let actions = ListeningHistoryMutationActions(
      store: store,
      errors: errors,
      onSetRating: { rating, id in
        if shouldFail { throw ExpectedPersistenceFailure() }
        try store.setRating(rating, for: id)
      })

    actions.setRating(4, for: trackID)
    #expect(errors.message == "Expected persistence failure")
    errors.dismiss()
    #expect(errors.message == nil)

    actions.setRating(4, for: trackID)
    #expect(errors.message == "Expected persistence failure")
    shouldFail = false
    actions.setRating(4, for: trackID)

    #expect(errors.message == nil)
    #expect(store.rating(for: trackID) == 4)
  }

  @Test
  func testMalformedListeningMetadataIsClampedAndPlayCountSaturates() throws {
    struct PersistedMetadata: Codable {
      let trackID: TrackID
      let rating: Int
      let isFavorite: Bool
      let playCount: Int
      var lastPlayedAt: Date? = nil
      var skipCount = 0
      var bookmarkMS: Int? = nil
      var lastSkippedAt: Date? = nil
    }
    struct PersistedValue: Codable {
      let metadataByID: [String: PersistedMetadata]
      var history: [ListeningHistoryEntry] = []
      var appliedDeviceReportIDs: [UUID] = []
    }

    let persistence = MemoryAppDataPersistence()
    let maximum = URL(fileURLWithPath: "/Music/Maximum.mp3")
    let negative = URL(fileURLWithPath: "/Music/Negative.mp3")
    persistence.data = try JSONEncoder().encode(
      PersistedValue(metadataByID: [
        TrackID(url: maximum).rawValue: PersistedMetadata(
          trackID: TrackID(url: maximum), rating: 99, isFavorite: false, playCount: Int.max),
        TrackID(url: negative).rawValue: PersistedMetadata(
          trackID: TrackID(url: negative), rating: -4, isFavorite: false, playCount: -20),
      ]))

    let store = ListeningHistoryStore(persistence: persistence)
    #expect(store.rating(for: TrackID(url: maximum)) == 5)
    #expect(store.metadata(for: TrackID(url: negative)).rating == 0)
    #expect(store.metadata(for: TrackID(url: negative)).playCount == 0)
    #expect(store.metadata(for: TrackID(url: maximum)).skipCount == 0)
    #expect(store.metadata(for: TrackID(url: maximum)).bookmarkMS == nil)
    #expect(store.metadata(for: TrackID(url: maximum)).lastSkippedAt == nil)

    try store.recordPlay(of: TrackID(url: maximum))
    try store.recordPlay(of: TrackID(url: negative))
    #expect(store.metadata(for: TrackID(url: maximum)).playCount == Int.max)
    #expect(store.metadata(for: TrackID(url: negative)).playCount == 1)
  }

  @Test
  func testBatchRatingsAndFavoritesAreAtomic() async throws {
    let persistence = MemoryAppDataPersistence()
    let store = ListeningHistoryStore(persistence: persistence)
    let first = TrackID(url: URL(fileURLWithPath: "/Music/First.mp3"))
    let second = TrackID(url: URL(fileURLWithPath: "/Music/Second.mp3"))

    try store.setRating(4, for: [first, second, first])
    try await store.flushPersistence()
    #expect(persistence.saveCount == 1)
    #expect(store.rating(for: first) == 4)
    #expect(store.rating(for: second) == 4)

    try store.setFavorite(true, for: [first, second])
    try await store.flushPersistence()
    #expect(persistence.saveCount == 2)
    #expect(store.isFavorite(first))
    #expect(store.isFavorite(second))

    persistence.error = ExpectedPersistenceFailure()
    try store.setRating(1, for: [first, second])
    try store.setFavorite(false, for: [first, second])
    do {
      try await store.flushPersistence()
      Issue.record("Expected the durable flush to report the write failure")
    } catch {}
    #expect(store.rating(for: first) == 1)
    #expect(store.rating(for: second) == 1)
    #expect(!(store.isFavorite(first)))
    #expect(!(store.isFavorite(second)))
  }

  @Test
  func testListeningLookupsResolveFavoritesAndRepeatedRecentTracks() throws {
    let store = ListeningHistoryStore(
      persistence: MemoryAppDataPersistence(), historyLimit: 10)
    let first = makeTrack(path: "/Music/First.mp3", title: "First")
    let second = makeTrack(path: "/Music/Second.mp3", title: "Second")

    _ = try store.toggleFavorite(second.id)
    try store.recordPlay(of: first.id, at: Date(timeIntervalSince1970: 10))
    try store.recordPlay(of: second.id, at: Date(timeIntervalSince1970: 20))
    try store.recordPlay(of: first.id, at: Date(timeIntervalSince1970: 30))

    let catalog = LibraryCatalog([first, second])
    #expect(store.favoriteTracks(from: catalog.tracks).map(\.title) == ["Second"])
    #expect(store.recentTracks(from: catalog).map(\.title) == ["First", "Second", "First"])
    #expect(store.recentTracks(from: catalog, limit: 2).map(\.title) == ["First", "Second"])
  }

  private func makeTrack(path: String, title: String) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: path), title: title, genre: "Rock", trackNumber: 1,
      trackCount: 1, discNumber: 1, year: 2026, durationMS: 180_000, bitrate: 256)
  }

  private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 12,
    calendar: Calendar
  ) throws -> Date {
    try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }
}
