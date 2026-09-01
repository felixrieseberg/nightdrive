import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct AppSyncLocalEffectsTests {
  @Test
  func testPlaylistResultIsAppliedToLiveStore() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let library = LibraryStore(folderURL: root)
    let playlists = PlaylistStore(libraryFolder: root)
    let listeningHistory = ListeningHistoryStore(libraryFolder: root)
    let syncedID = try playlists.create(name: "Before sync")
    let previewPlaylists = playlists.playlists
    let effects = AppSyncLocalEffects.make(
      library: library, playlists: playlists, listeningHistory: listeningHistory,
      expectedLibraryFolder: root, expectedLibraryIdentity: library.identityRevision)

    _ = try playlists.create(name: "Created during sync")
    var result = SyncResult()
    result.libraryPlaylistActions = [
      .updateInLibrary(localID: syncedID, name: "From device", trackIDs: [])
    ]

    let outcome = try await effects.applyPlaylists(result, previewPlaylists)

    #expect(outcome.playlists.map(\.name) == ["From device", "Created during sync"])
    #expect(playlists.playlists == outcome.playlists)
    #expect(try LocalPlaylistFile.load(libraryFolder: root) == outcome.playlists)
  }

  @Test
  func testEffectsRejectSyncAfterLibrarySwitch() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let library = LibraryStore(folderURL: first)
    let playlists = PlaylistStore(libraryFolder: first)
    let listeningHistory = ListeningHistoryStore(libraryFolder: first)
    let oldID = try playlists.create(name: "Old library")
    let secondPlaylists = PlaylistStore(libraryFolder: second)
    _ = try secondPlaylists.create(name: "New library")
    try await secondPlaylists.flushPersistence()
    let effects = AppSyncLocalEffects.make(
      library: library, playlists: playlists, listeningHistory: listeningHistory,
      expectedLibraryFolder: first, expectedLibraryIdentity: library.identityRevision)

    try library.setFolder(second)
    playlists.useLibraryFolder(second)
    listeningHistory.useLibraryFolder(second)

    var result = SyncResult()
    result.libraryPlaylistActions = [
      .updateInLibrary(localID: oldID, name: "Stale result", trackIDs: [])
    ]
    do {
      _ = try await effects.applyPlaylists(result, [])
      Issue.record("Expected the stale playlist commit to fail")
    } catch {
      #expect(error as? AppSyncCommitError == .libraryChanged)
    }
    do {
      _ = try await effects.mergePlayback(DevicePlaybackReport())
      Issue.record("Expected the stale playback merge to fail")
    } catch {
      #expect(error as? AppSyncCommitError == .libraryChanged)
    }

    #expect(playlists.playlists.map(\.name) == ["New library"])
    #expect(try LocalPlaylistFile.load(libraryFolder: second).map(\.name) == ["New library"])
    #expect(listeningHistory.metadataByID.isEmpty)
    #expect(listeningHistory.history.isEmpty)
  }

  @Test
  func testEffectsRejectReplacementDirectoryAtSameCanonicalPath() async throws {
    let parent = try makeRoot()
    defer { try? FileManager.default.removeItem(at: parent) }
    let libraryFolder = parent.appendingPathComponent("library", isDirectory: true)
    let movedFolder = parent.appendingPathComponent("moved-library", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
    let library = LibraryStore(folderURL: libraryFolder)
    await library.rescan()
    let playlists = PlaylistStore(libraryFolder: libraryFolder)
    let listeningHistory = ListeningHistoryStore(libraryFolder: libraryFolder)
    let oldID = try playlists.create(name: "Old resource")
    let oldRevision = library.identityRevision
    let effects = AppSyncLocalEffects.make(
      library: library, playlists: playlists, listeningHistory: listeningHistory,
      expectedLibraryFolder: libraryFolder, expectedLibraryIdentity: oldRevision)

    try FileManager.default.moveItem(at: libraryFolder, to: movedFolder)
    try FileManager.default.createDirectory(
      at: libraryFolder, withIntermediateDirectories: false)
    #expect(try library.setFolder(libraryFolder))
    playlists.useLibraryFolder(libraryFolder, resourceChanged: true)
    listeningHistory.useLibraryFolder(libraryFolder, resourceChanged: true)
    _ = try playlists.create(name: "New resource")

    var result = SyncResult()
    result.libraryPlaylistActions = [
      .updateInLibrary(localID: oldID, name: "Stale result", trackIDs: [])
    ]
    do {
      _ = try await effects.applyPlaylists(result, [])
      Issue.record("Expected the captured sync effects to reject the replacement resource")
    } catch {
      #expect(error as? AppSyncCommitError == .libraryChanged)
    }
    #expect(playlists.playlists.map(\.name) == ["New resource"])
  }

  private func makeRoot() throws -> URL {
    let root = TestScratch.directory(prefix: "AppSyncLocalEffects")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
