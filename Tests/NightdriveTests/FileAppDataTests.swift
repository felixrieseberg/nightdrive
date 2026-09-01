import Foundation
import Testing

@testable import Nightdrive

struct FileAppDataTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  private func persistence(filename: String) -> FileDataPersistence {
    FileDataPersistence(fileURL: scratch.appendingPathComponent(filename))
  }

  @Test
  func testRoundTripAndFileIsolation() throws {
    let first = persistence(filename: "alpha.json")
    let second = persistence(filename: "beta.json")
    #expect(try first.load() == nil)

    try first.save(Data("alpha payload".utf8))
    try second.save(Data("beta payload".utf8))
    #expect((try first.load()) == (Data("alpha payload".utf8)))
    #expect((try second.load()) == (Data("beta payload".utf8)))

    try first.save(Data("alpha replaced".utf8))
    #expect((try first.load()) == (Data("alpha replaced".utf8)))
    #expect((try second.load()) == (Data("beta payload".utf8)))

    #expect((try persistence(filename: "alpha.json").load()) == (Data("alpha replaced".utf8)))
  }

  @Test
  func testLoadWithoutFileCreatesNothing() throws {
    let file = persistence(filename: "missing.json")
    #expect(try file.load() == nil)
    #expect(!(FileManager.default.fileExists(atPath: file.fileURL.path)))
  }

  @Test
  func testAppDataDirectoryHonorsEnvironmentOverride() {
    let url = NightdriveAppData.directoryURL(
      environment: [NightdriveAppData.directoryEnvironmentKey: scratch.path])
    #expect((url.path) == (scratch.standardizedFileURL.path))

    let fallback = NightdriveAppData.directoryURL(environment: [:])
    #expect(fallback.path.contains("Application Support"))
    #expect((fallback.lastPathComponent) == ("Nightdrive"))
  }

  @MainActor
  @Test
  func testPlaylistStoreUsesLibrarySidecarSharedWithFileHelper() async throws {
    let library = scratch.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let source = PlaylistStore(libraryFolder: library)
    let id = try source.create(
      name: "Roadtrip", trackURLs: [URL(fileURLWithPath: "/library/a.mp3")])
    try await source.flushPersistence()

    let reloaded = PlaylistStore(libraryFolder: library)
    #expect(reloaded.persistenceError == nil)
    #expect((reloaded.playlists.map(\.id)) == ([id]))
    #expect((reloaded.playlists.first?.name) == ("Roadtrip"))
    #expect((try LocalPlaylistFile.load(libraryFolder: library).map(\.id)) == ([id]))
  }

  @Test
  func testLoadOutcomeDistinguishesAbsentEmptyCorruptUnreadableAndValid() throws {
    let file = persistence(filename: "outcome.json")
    guard case .missing = file.loadOutcome([String].self) else {
      Issue.record("an absent file must load as missing")
      return
    }

    try Data().write(to: file.fileURL)
    guard case .missing = file.loadOutcome([String].self) else {
      Issue.record("a zero-length file must load as missing, not malformed")
      return
    }

    try Data("[\"trunc".utf8).write(to: file.fileURL)
    guard case .malformed = file.loadOutcome([String].self) else {
      Issue.record("truncated JSON must load as malformed")
      return
    }

    try Data("not json".utf8).write(to: file.fileURL)
    guard case .malformed = file.loadOutcome([String].self) else {
      Issue.record("non-JSON bytes must load as malformed")
      return
    }

    try Data("[\"ok\"]".utf8).write(to: file.fileURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: file.fileURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: file.fileURL.path)
    }
    guard case .unreadable = file.loadOutcome([String].self) else {
      Issue.record("a permission-denied read must load as unreadable, not malformed")
      return
    }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: file.fileURL.path)
    guard case .loaded(let value) = file.loadOutcome([String].self), value == ["ok"] else {
      Issue.record("valid JSON must load")
      return
    }
  }

  @MainActor
  @Test
  func testZeroLengthSidecarsBehaveAsMissingAndDoNotBlock() async throws {
    try Data().write(to: LocalPlaylistFile.url(for: scratch))
    try Data().write(to: ListeningHistoryFile.url(for: scratch))

    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    #expect(playlists.persistenceError == nil)
    #expect(history.persistenceError == nil)

    let id = try playlists.create(name: "Fresh start")
    let trackID = TrackID(url: scratch.appendingPathComponent("song.mp3"))
    try history.setRating(3, for: trackID)
    try await playlists.flushPersistence()
    try await history.flushPersistence()
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).map(\.id)) == ([id]))
    #expect((try ListeningHistoryFile.loadRatings(libraryFolder: scratch)[trackID.rawValue]) == (3))
  }

  @MainActor
  @Test
  func testUnreadableSidecarsBlockWritesWithoutClaimingCorruption() async throws {
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let historyURL = ListeningHistoryFile.url(for: scratch)
    let seededPlaylists = PlaylistStore(libraryFolder: scratch)
    let seededID = try seededPlaylists.create(name: "Original")
    let seededHistory = ListeningHistoryStore(libraryFolder: scratch)
    let trackID = TrackID(url: scratch.appendingPathComponent("original.mp3"))
    try seededHistory.setRating(4, for: trackID)
    try await seededPlaylists.flushPersistence()
    try await seededHistory.flushPersistence()
    let validPlaylists = try Data(contentsOf: playlistURL)
    let validHistory = try Data(contentsOf: historyURL)

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: playlistURL.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: historyURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: playlistURL.path)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: historyURL.path)
    }

    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    #expect(playlists.persistenceError != nil)
    #expect(history.persistenceError != nil)
    #expect((playlists.persistenceError?.contains("could not be read")) == (true))
    #expect((playlists.persistenceError?.contains("damaged")) == (false))
    #expect(throws: (any Error).self) { try playlists.create(name: "Must not overwrite") }
    #expect(throws: (any Error).self) { try history.setRating(5, for: trackID) }
    #expect(throws: (any Error).self) { try LocalPlaylistFile.load(libraryFolder: scratch) }
    #expect(throws: (any Error).self) { try ListeningHistoryFile.loadPayload(libraryFolder: scratch) }

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: playlistURL.path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: historyURL.path)
    #expect((try Data(contentsOf: playlistURL)) == (validPlaylists))
    #expect((try Data(contentsOf: historyURL)) == (validHistory))
    try playlists.reloadFromPersistence()
    try history.reloadFromPersistence()
    #expect(playlists.persistenceError == nil)
    #expect(history.persistenceError == nil)
    #expect((playlists.playlists.map(\.id)) == ([seededID]))
    #expect((history.rating(for: trackID)) == (4))
    _ = try playlists.create(name: "Recovered")
    try history.setRating(5, for: trackID)
  }

  @MainActor
  @Test
  func testWriteBlipSurfacesAtFlushAndDoesNotStickOnceAccessReturns() async throws {
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let playlists = PlaylistStore(libraryFolder: scratch)
    let originalID = try playlists.create(name: "Original")
    try await playlists.flushPersistence()

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: playlistURL.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: playlistURL.path)
    }
    let duringBlipID = try playlists.create(name: "Kept during blip")
    do {
      try await playlists.flushPersistence()
      Issue.record("Expected the durable flush to report the inaccessible sidecar")
    } catch {}

    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: playlistURL.path)
    let recoveredID = try playlists.create(name: "After blip")
    try await playlists.flushPersistence()
    #expect(
      (try LocalPlaylistFile.load(libraryFolder: scratch).map(\.id)) == ([originalID, duringBlipID, recoveredID]))
  }

  @MainActor
  @Test
  func testNewLibraryCorruptSidecarsStartEmptyAndBlockWrites() throws {
    let corrupt = Data("not json".utf8)
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let historyURL = ListeningHistoryFile.url(for: scratch)
    try corrupt.write(to: playlistURL)
    try corrupt.write(to: historyURL)

    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    #expect(playlists.playlists.isEmpty)
    #expect(history.history.isEmpty)
    #expect(playlists.persistenceError != nil)
    #expect(history.persistenceError != nil)
    #expect(throws: (any Error).self) { try playlists.create(name: "Must not overwrite") }
    #expect(throws: (any Error).self) {
      try history.setRating(
        5, for: TrackID(url: scratch.appendingPathComponent("must-not-overwrite.mp3")))
    }
    #expect(throws: (any Error).self) { try LocalPlaylistFile.load(libraryFolder: scratch) }
    #expect(throws: (any Error).self) { try ListeningHistoryFile.loadPayload(libraryFolder: scratch) }
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))
  }

  @MainActor
  @Test
  func testMalformedReloadRetainsLiveSnapshotAndBlocksUntilValidRewrite() async throws {
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let historyURL = ListeningHistoryFile.url(for: scratch)
    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    let originalPlaylistID = try playlists.create(name: "Original")
    let originalTrack = TrackID(url: scratch.appendingPathComponent("original.mp3"))
    try history.setRating(4, for: originalTrack)
    try await playlists.flushPersistence()
    try await history.flushPersistence()
    let validPlaylists = try Data(contentsOf: playlistURL)
    let validHistory = try Data(contentsOf: historyURL)

    let corrupt = Data("not json".utf8)
    try corrupt.write(to: playlistURL)
    try corrupt.write(to: historyURL)
    #expect(throws: (any Error).self) { try playlists.reloadFromPersistence() }
    #expect(throws: (any Error).self) { try history.reloadFromPersistence() }
    #expect((playlists.playlists.map(\.id)) == ([originalPlaylistID]))
    #expect((history.rating(for: originalTrack)) == (4))
    #expect(playlists.persistenceError != nil)
    #expect(history.persistenceError != nil)

    #expect(throws: (any Error).self) { try playlists.create(name: "Replacement") }
    #expect(throws: (any Error).self) {
      try history.setRating(
        5, for: TrackID(url: scratch.appendingPathComponent("replacement.mp3")))
    }
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))

    try validPlaylists.write(to: playlistURL, options: .atomic)
    try validHistory.write(to: historyURL, options: .atomic)
    try playlists.reloadFromPersistence()
    try history.reloadFromPersistence()
    #expect(playlists.persistenceError == nil)
    #expect(history.persistenceError == nil)
    _ = try playlists.create(name: "Recovered")
    try history.setRating(5, for: originalTrack)
    try await playlists.flushPersistence()
    try await history.flushPersistence()
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).count) == (2))
    #expect((try ListeningHistoryFile.loadRatings(libraryFolder: scratch)[originalTrack.rawValue]) == (5))
  }

  @MainActor
  @Test
  func testFlushDetectsSidecarCorruptionAndForcedReloadRecovers() async throws {
    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    _ = try playlists.create(name: "Original")
    let trackID = TrackID(url: scratch.appendingPathComponent("original.mp3"))
    try history.setRating(4, for: trackID)
    try await playlists.flushPersistence()
    try await history.flushPersistence()

    let corrupt = Data("not json".utf8)
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let historyURL = ListeningHistoryFile.url(for: scratch)
    try corrupt.write(to: playlistURL)
    try corrupt.write(to: historyURL)

    _ = try playlists.create(name: "Held in memory")
    try history.setRating(5, for: trackID)
    do {
      try await playlists.flushPersistence()
      Issue.record("Expected the durable flush to reject the replaced playlist sidecar")
    } catch {}
    do {
      try await history.flushPersistence()
      Issue.record("Expected the durable flush to reject the replaced history sidecar")
    } catch {}
    #expect((playlists.playlists.map(\.name)) == (["Original", "Held in memory"]))
    #expect((history.rating(for: trackID)) == (5))
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))

    let externalPlaylist = LocalPlaylist(name: "External repair")
    try LocalPlaylistFile.save([externalPlaylist], libraryFolder: scratch)
    let externalMetadata = TrackListeningMetadata(trackID: trackID, rating: 2)
    try SidecarJSONFile.save(
      ListeningHistoryPayload(
        metadataByID: [trackID.rawValue: externalMetadata], history: []),
      to: historyURL)

    try playlists.reloadFromPersistence()
    try history.reloadFromPersistence()
    #expect((playlists.playlists.map(\.name)) == (["Original", "Held in memory"]))
    #expect((history.rating(for: trackID)) == (5))
    #expect(playlists.canReloadDiscardingPendingChanges)
    #expect(history.canReloadDiscardingPendingChanges)

    try playlists.reloadFromPersistence(discardingPendingChanges: true)
    try history.reloadFromPersistence(discardingPendingChanges: true)
    #expect((playlists.playlists.map(\.id)) == ([externalPlaylist.id]))
    #expect((history.rating(for: trackID)) == (2))
    #expect(!(playlists.canReloadDiscardingPendingChanges))
    #expect(!(history.canReloadDiscardingPendingChanges))

    _ = try playlists.create(name: "After recovery")
    try history.setRating(3, for: trackID)
    try await playlists.flushPersistence()
    try await history.flushPersistence()
    #expect(
      (try LocalPlaylistFile.load(libraryFolder: scratch).map(\.name)) == (["External repair", "After recovery"]))
    #expect((try ListeningHistoryFile.loadRatings(libraryFolder: scratch)[trackID.rawValue]) == (3))
  }

  @MainActor
  @Test
  func testMutationAfterSidecarRemovalRecreatesLiveSnapshot() async throws {
    let playlists = PlaylistStore(libraryFolder: scratch)
    let history = ListeningHistoryStore(libraryFolder: scratch)
    let originalPlaylistID = try playlists.create(name: "Original")
    let trackID = TrackID(url: scratch.appendingPathComponent("original.mp3"))
    try history.setRating(4, for: trackID)
    try await playlists.flushPersistence()
    try await history.flushPersistence()

    try FileManager.default.removeItem(at: LocalPlaylistFile.url(for: scratch))
    try FileManager.default.removeItem(at: ListeningHistoryFile.url(for: scratch))

    _ = try playlists.create(name: "After removal")
    try history.setRating(5, for: trackID)
    try await playlists.flushPersistence()
    try await history.flushPersistence()
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).map(\.id).first) == (originalPlaylistID))
    #expect((try ListeningHistoryFile.loadRatings(libraryFolder: scratch)[trackID.rawValue]) == (5))
  }

  @MainActor
  @Test
  func testDeferredWritesRefuseAReplacementLibraryRoot() async throws {
    let root = scratch.appendingPathComponent("library", isDirectory: true)
    let parked = scratch.appendingPathComponent("parked", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let playlists = PlaylistStore(libraryFolder: root, persistenceDebounce: .seconds(30))
    let history = ListeningHistoryStore(
      libraryFolder: root, persistenceDebounce: .seconds(30))
    _ = try playlists.create(name: "Held in memory")
    let trackID = TrackID(url: root.appendingPathComponent("song.mp3"))
    try history.setRating(5, for: trackID)

    try FileManager.default.moveItem(at: root, to: parked)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

    do {
      try await playlists.flushPersistence()
      Issue.record("Expected the playlist flush to reject the replacement library")
    } catch {}
    do {
      try await history.flushPersistence()
      Issue.record("Expected the history flush to reject the replacement library")
    } catch {}
    #expect((try FileManager.default.contentsOfDirectory(atPath: root.path)) == ([]))
    #expect(!(FileManager.default.fileExists(atPath: LocalPlaylistFile.url(for: parked).path)))
    #expect(!(FileManager.default.fileExists(atPath: ListeningHistoryFile.url(for: parked).path)))
  }

  @Test
  func testMissingCLISidecarsUseEmptyDefaultsButMalformedSidecarsThrow() throws {
    switch LocalPlaylistFile.loadOutcome(libraryFolder: scratch) {
    case .missing:
      break
    default:
      Issue.record("A missing playlist sidecar must remain distinguishable")
    }
    switch ListeningHistoryFile.loadOutcome(libraryFolder: scratch) {
    case .missing:
      break
    default:
      Issue.record("A missing history sidecar must remain distinguishable")
    }
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch)) == ([]))
    #expect(try ListeningHistoryFile.loadPayload(libraryFolder: scratch).history.isEmpty)
    #expect(try ListeningHistoryFile.loadRatings(libraryFolder: scratch).isEmpty)

    let corrupt = Data("not json".utf8)
    let playlistURL = LocalPlaylistFile.url(for: scratch)
    let historyURL = ListeningHistoryFile.url(for: scratch)
    try corrupt.write(to: playlistURL)
    try corrupt.write(to: historyURL)
    #expect(throws: (any Error).self) { try LocalPlaylistFile.load(libraryFolder: scratch) }
    #expect(throws: (any Error).self) { try ListeningHistoryFile.loadPayload(libraryFolder: scratch) }
    #expect(throws: (any Error).self) { try ListeningHistoryFile.loadRatings(libraryFolder: scratch) }
    let report = DevicePlaybackReport(entries: [
      .init(
        dbid: 1, localURL: scratch.appendingPathComponent("song.mp3"), playCountDelta: 2)
    ])
    #expect(throws: (any Error).self) { try ListeningHistoryFile.merge(report, libraryFolder: scratch) }
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))
  }

  @MainActor
  @Test
  func testLibraryDataCannotBeSilentlyMutatedBeforeChoosingAFolder() {
    let playlists = PlaylistStore(libraryFolder: nil)
    let history = ListeningHistoryStore(libraryFolder: nil)

    #expect(throws: (any Error).self) { try playlists.create(name: "Nowhere") }
    #expect(throws: (any Error).self) {
      try history.setRating(5, for: TrackID(url: URL(fileURLWithPath: "/nowhere.mp3")))
    }
    #expect(playlists.playlists.isEmpty)
    #expect(history.metadataByID.isEmpty)
  }

  @MainActor
  @Test
  func testAppStateHonorsAnInjectedPlaylistStore() throws {
    let injected = PlaylistStore(persistence: persistence(filename: "playlists.json"))
    let app = AppState(
      library: LibraryStore(folderURL: scratch),
      playlists: injected,
      listeningHistory: ListeningHistoryStore(
        persistence: persistence(filename: "history.json")))
    #expect(app.playlists === injected)
  }

  @MainActor
  @Test
  func testAppStateLoadsTheSelectedLibrarySidecarsByDefault() async throws {
    let stored = PlaylistStore(libraryFolder: scratch)
    let playlistID = try stored.create(name: "Library playlist")
    let trackID = TrackID(url: scratch.appendingPathComponent("song.mp3"))
    let storedHistory = ListeningHistoryStore(libraryFolder: scratch)
    try storedHistory.setRating(4, for: trackID)
    try await stored.flushPersistence()
    try await storedHistory.flushPersistence()

    let app = AppState(library: LibraryStore(folderURL: scratch))
    #expect((app.playlists.playlists.map(\.id)) == ([playlistID]))
    #expect((app.listeningHistory.rating(for: trackID)) == (4))
  }

  @MainActor
  @Test
  func testSwitchingLibraryFoldersReloadsIndependentPayloads() async throws {
    let first = scratch.appendingPathComponent("first", isDirectory: true)
    let second = scratch.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let firstPlaylists = PlaylistStore(libraryFolder: first)
    let firstID = try firstPlaylists.create(name: "First library")
    try await firstPlaylists.flushPersistence()
    let secondID = UUID()
    try LocalPlaylistFile.save(
      [LocalPlaylist(id: secondID, name: "Second library")], libraryFolder: second)

    firstPlaylists.useLibraryFolder(second)
    #expect((firstPlaylists.playlists.map(\.id)) == ([secondID]))
    firstPlaylists.useLibraryFolder(first)
    #expect((firstPlaylists.playlists.map(\.id)) == ([firstID]))

    let firstHistory = ListeningHistoryStore(libraryFolder: first)
    let firstTrack = TrackID(url: first.appendingPathComponent("a.mp3"))
    try firstHistory.setRating(5, for: firstTrack)
    let secondHistory = ListeningHistoryStore(libraryFolder: second)
    let secondTrack = TrackID(url: second.appendingPathComponent("b.mp3"))
    try secondHistory.setRating(3, for: secondTrack)
    try await firstHistory.flushPersistence()
    try await secondHistory.flushPersistence()

    firstHistory.useLibraryFolder(second)
    #expect((firstHistory.rating(for: firstTrack)) == (0))
    #expect((firstHistory.rating(for: secondTrack)) == (3))
  }
}
