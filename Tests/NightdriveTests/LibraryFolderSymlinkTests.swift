import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
final class LibraryFolderSymlinkTests {
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
  private var firstTarget: URL!
  private var secondTarget: URL!
  private var alias: URL!

  init() throws {
    root = TestScratch.directory(prefix: "LibraryFolderSymlinks")
    firstTarget = root.appendingPathComponent("first", isDirectory: true)
    secondTarget = root.appendingPathComponent("second", isDirectory: true)
    alias = root.appendingPathComponent("selected-library", isDirectory: true)
    try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondTarget, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  @Test
  func testSelectedDirectorySymlinkScansCanonicalTarget() async throws {
    let song = firstTarget.appendingPathComponent("through-link.mp3")
    try writeTestSong(title: "Through Link", to: song, genre: "Test")
    try pointAlias(at: firstTarget)

    #expect((LibraryStore.findAudioFiles(in: alias)) == ([song.canonicalFileURL]))

    let library = LibraryStore(folderURL: alias)
    #expect((library.folderURL?.path) == (firstTarget.resolvingSymlinksInPath().path))
    await library.rescan()

    #expect((library.tracks.map(\.title)) == (["Through Link"]))
    #expect((library.tracks.first?.url.path) == (song.canonicalFileURL.path))
  }

  @Test
  func testRetargetedAliasKeepsWatcherOnOriginallySelectedDirectory() async throws {
    try writeTestSong(title: "Original", to: firstTarget.appendingPathComponent("original.mp3"), genre: "Test")
    try pointAlias(at: firstTarget)
    let library = LibraryStore(folderURL: alias)
    await library.rescan()
    #expect((library.tracks.map(\.title)) == (["Original"]))
    // Let any straggling watcher events from setup settle before measuring.
    await waitUntil(timeout: .seconds(5)) {
      let revision = library.derivedDataRevision
      return await holds(for: .milliseconds(300)) {
        !library.isScanning && library.derivedDataRevision == revision
      }
    }

    try pointAlias(at: secondTarget)
    let revisionAfterRetarget = library.derivedDataRevision
    try writeTestSong(title: "Wrong Target", to: secondTarget.appendingPathComponent("wrong.mp3"), genre: "Test")
    let retargetIgnored = await holds(for: .milliseconds(750)) {
      library.derivedDataRevision == revisionAfterRetarget
    }

    #expect(retargetIgnored, Comment(rawValue: "the watcher must not follow the retargeted alias"))
    #expect((library.tracks.map(\.title)) == (["Original"]))

    try writeTestSong(title: "Still Watched", to: firstTarget.appendingPathComponent("watched.mp3"), genre: "Test")
    await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(100)) {
      library.tracks.count == 2
    }

    #expect((Set(library.tracks.map(\.title))) == (["Original", "Still Watched"]))
    #expect(!(library.tracks.contains { $0.title == "Wrong Target" }))
    #expect((library.folderURL?.path) == (firstTarget.standardizedFileURL.path))
  }

  @Test
  func testRetargetedAliasCannotRedirectLibrarySidecarWrites() async throws {
    try pointAlias(at: firstTarget)
    let app = AppState(
      library: LibraryStore(folderURL: alias),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))

    try pointAlias(at: secondTarget)
    _ = try app.playlists.create(name: "Pinned to first")
    let trackID = TrackID(url: firstTarget.appendingPathComponent("song.mp3"))
    try app.listeningHistory.setRating(5, for: trackID)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()

    #expect(FileManager.default.fileExists(atPath: LocalPlaylistFile.url(for: firstTarget).path))
    #expect(FileManager.default.fileExists(atPath: ListeningHistoryFile.url(for: firstTarget).path))
    #expect(!(FileManager.default.fileExists(atPath: LocalPlaylistFile.url(for: secondTarget).path)))
    #expect(!(FileManager.default.fileExists(atPath: ListeningHistoryFile.url(for: secondTarget).path)))
    #expect((app.library.folderURL?.path) == (firstTarget.standardizedFileURL.path))
  }

  @Test
  func testAliasesToSameResourceDoNotTransitionOrReloadSidecars() throws {
    let secondAlias = root.appendingPathComponent("same-library-again", isDirectory: true)
    try pointAlias(at: firstTarget)
    try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: firstTarget)
    let app = AppState(
      library: LibraryStore(folderURL: alias),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let playlistID = try app.playlists.create(name: "Preserved")
    let identityRevision = app.library.identityRevision
    let dataRevision = app.library.derivedDataRevision

    #expect(app.setLibraryFolder(secondAlias))

    #expect((app.library.identityRevision) == (identityRevision))
    #expect((app.library.derivedDataRevision) == (dataRevision))
    #expect((app.library.folderURL?.path) == (firstTarget.standardizedFileURL.path))
    #expect((app.playlists.playlists.map(\.id)) == ([playlistID]))
    #expect(app.libraryFolderError == nil)
  }

  @Test
  func testMovedSelectedDirectoryRebindsToItsNewCanonicalPath() async throws {
    let suiteName = "Nightdrive.LibraryFolderMovedTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let originalSong = firstTarget.appendingPathComponent("original.mp3")
    try writeTestSong(title: "Original", to: originalSong, genre: "Test")
    let library = LibraryStore(folderURL: firstTarget, folderDefaults: defaults)
    let app = AppState(
      library: library,
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    _ = try app.playlists.create(name: "Before move")
    try await app.playlists.flushPersistence()
    await library.rescan()
    let identityRevision = library.identityRevision
    let dataRevision = library.derivedDataRevision
    let movedTarget = root.appendingPathComponent("moved", isDirectory: true)

    try FileManager.default.moveItem(at: firstTarget, to: movedTarget)

    #expect(app.setLibraryFolder(movedTarget))
    #expect((library.folderURL) == (movedTarget.standardizedFileURL))
    #expect((library.identityRevision) == (identityRevision + 1))
    #expect((library.derivedDataRevision) > (dataRevision))
    #expect((defaults.string(forKey: "libraryFolderPath")) == (movedTarget.path))
    #expect((app.playlists.playlists.map(\.name)) == (["Before move"]))
    await library.rescan()

    _ = try app.playlists.create(name: "After move")
    let movedTrackID = TrackID(url: movedTarget.appendingPathComponent("original.mp3"))
    try app.listeningHistory.setRating(5, for: movedTrackID)
    try await app.playlists.flushPersistence()
    try await app.listeningHistory.flushPersistence()
    #expect(!(FileManager.default.fileExists(atPath: firstTarget.path)))
    #expect((PlaylistStore(libraryFolder: movedTarget).playlists.map(\.name)) == (["Before move", "After move"]))
    #expect((ListeningHistoryStore(libraryFolder: movedTarget).rating(for: movedTrackID)) == (5))

    let addedSong = movedTarget.appendingPathComponent("added.mp3")
    try writeTestSong(title: "Added", to: addedSong, genre: "Test")
    await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(100)) {
      library.tracks.count == 2
    }

    #expect((Set(library.tracks.map(\.title))) == (["Original", "Added"]))
    #expect(!(FileManager.default.fileExists(atPath: firstTarget.path)))
  }

  @Test
  func testCanonicalTargetIsPersistedInsteadOfSelectedAlias() throws {
    let suiteName = "Nightdrive.LibraryFolderSymlinkTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try pointAlias(at: secondTarget)
    let library = LibraryStore(folderURL: firstTarget, folderDefaults: defaults)

    #expect(try library.setFolder(alias))

    #expect((defaults.string(forKey: "libraryFolderPath")) == (secondTarget.path))
    #expect((library.folderURL?.path) == (secondTarget.path))
  }

  @Test
  func testConfiguredSymlinkIsCanonicalizedAndRewrittenOnLoad() throws {
    let suiteName = "Nightdrive.LibraryFolderSymlinkLoadTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try pointAlias(at: firstTarget)
    defaults.set(alias.path, forKey: "libraryFolderPath")

    let library = LibraryStore(
      indexCache: nil, folderDefaults: defaults, environment: [:])

    #expect((library.folderURL?.path) == (firstTarget.path))
    #expect((defaults.string(forKey: "libraryFolderPath")) == (firstTarget.path))
  }

  @Test
  func testBrokenAndCyclicSymlinksAreRejectedWithoutReplacingLibrary() throws {
    let app = AppState(
      library: LibraryStore(folderURL: firstTarget),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let playlistID = try app.playlists.create(name: "Keep me")
    let identityRevision = app.library.identityRevision
    let broken = root.appendingPathComponent("broken", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: broken, withDestinationURL: root.appendingPathComponent("missing"))

    #expect(!(app.setLibraryFolder(broken)))
    #expect(app.libraryFolderError?.contains("broken or cyclic") == true)
    #expect((app.library.folderURL?.path) == (firstTarget.path))
    #expect((app.library.identityRevision) == (identityRevision))
    #expect((app.playlists.playlists.map(\.id)) == ([playlistID]))

    app.dismissLibraryFolderError()
    let firstLink = root.appendingPathComponent("cycle-a", isDirectory: true)
    let secondLink = root.appendingPathComponent("cycle-b", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: firstLink, withDestinationURL: secondLink)
    try FileManager.default.createSymbolicLink(at: secondLink, withDestinationURL: firstLink)

    #expect(!(app.setLibraryFolder(firstLink)))
    #expect(app.libraryFolderError?.contains("broken or cyclic") == true)
    #expect((app.library.folderURL?.path) == (firstTarget.path))
    #expect((app.library.identityRevision) == (identityRevision))
    #expect((app.playlists.playlists.map(\.id)) == ([playlistID]))
  }

  @Test
  func testReplacingCanonicalPathCannotAuthorizeCapturedMutations() async throws {
    try writeTestSong(title: "Captured", to: firstTarget.appendingPathComponent("captured.mp3"), genre: "Test")
    let library = LibraryStore(folderURL: firstTarget)
    await library.rescan()
    let captured = try #require(library.tracks.first)
    let movedTarget = root.appendingPathComponent("moved-first", isDirectory: true)

    try FileManager.default.moveItem(at: firstTarget, to: movedTarget)
    try FileManager.default.createDirectory(at: firstTarget, withIntermediateDirectories: false)

    do {
      let caughtError = #expect(throws: (any Error).self) { try library.validateCurrentTrackIDs([captured.id]) }
      if let caughtError {
        guard case LibraryStoreError.libraryChanged = caughtError else {
          Issue.record("Expected libraryChanged, got \(caughtError)")
          return
        }
      }
    }
  }

  private func pointAlias(at target: URL) throws {
    if FileManager.default.fileExists(atPath: alias.path)
      || (try? alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    {
      try FileManager.default.removeItem(at: alias)
    }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
  }

}
