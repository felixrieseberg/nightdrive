import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct PlaylistSyncLedgerCacheTests {
  private final class LoadCounter {
    var loads = 0
  }

  private static func makeLedger(databaseID: UInt64) -> SyncLedger {
    var ledger = SyncLedger()
    let key = SyncLedger.deviceKey(databaseID)
    ledger.devices[key] = [
      SyncLedgerEntry(
        relativePath: "a.mp3", dbid: 11, fileSize: 1, fileModifiedAt: 0,
        fileGenerationStamp: FileGenerationStamp(
          deviceID: 1, inode: 1, sizeBytes: 1, modificationSeconds: 0,
          modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0,
          generation: nil),
        contentSHA256: "", deviceSignature: "")
    ]
    ledger.playlists[key] = [
      SyncPlaylistLink(localID: UUID(), persistentID: 7, name: "Road Trip", memberDbids: [11])
    ]
    return ledger
  }

  @Test
  func testSnapshotMemoizesLedgerLoadsPerFolderAndDevice() throws {
    let folder = URL(fileURLWithPath: "/Library/Music", isDirectory: true)
    let counter = LoadCounter()
    let cache = PlaylistSyncLedgerCache { _ in
      counter.loads += 1
      return Self.makeLedger(databaseID: 42)
    }

    let first = cache.snapshot(for: 42, libraryFolder: folder)
    let second = cache.snapshot(for: 42, libraryFolder: folder)
    #expect((counter.loads) == (1))
    #expect((first.playlistLinks.map(\.name)) == (["Road Trip"]))
    #expect((second.playlistLinks) == (first.playlistLinks))
    let trackID = TrackID(url: folder.appendingPathComponent("a.mp3"))
    #expect((first.trackLinks.dbids(forTrackIDs: [trackID]).dbids) == ([11]))

    _ = cache.snapshot(for: 43, libraryFolder: folder)
    #expect((counter.loads) == (2))
    let other = cache.snapshot(for: 43, libraryFolder: folder)
    #expect((counter.loads) == (2))
    #expect((other.playlistLinks) == ([]))

    let otherFolder = URL(fileURLWithPath: "/Library/Other", isDirectory: true)
    _ = cache.snapshot(for: 42, libraryFolder: otherFolder)
    #expect((counter.loads) == (3))
  }

  @Test
  func testInvalidateBumpsRevisionAndReloadsTheLedger() throws {
    let folder = URL(fileURLWithPath: "/Library/Music", isDirectory: true)
    let counter = LoadCounter()
    let cache = PlaylistSyncLedgerCache { _ in
      counter.loads += 1
      return counter.loads == 1 ? SyncLedger() : Self.makeLedger(databaseID: 42)
    }

    #expect((cache.snapshot(for: 42, libraryFolder: folder).playlistLinks) == ([]))
    let before = cache.revision
    cache.invalidate()
    #expect((cache.revision) == (before &+ 1))
    let refreshed = cache.snapshot(for: 42, libraryFolder: folder)
    #expect((counter.loads) == (2))
    #expect((refreshed.playlistLinks.map(\.name)) == (["Road Trip"]))
  }

  @Test
  func testDefaultLoaderFallsBackToAnEmptySnapshotForACorruptLedger() throws {
    let folder = TestScratch.directory(prefix: "NightdrivePlaylistSyncCache")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("{not json".utf8).write(to: SyncLedgerStore.url(for: folder))

    let cache = PlaylistSyncLedgerCache()
    let snapshot = cache.snapshot(for: 42, libraryFolder: folder)
    #expect((snapshot.playlistLinks) == ([]))
    #expect((snapshot.trackLinks.dbids(forTrackIDs: []).skipped) == (0))
  }

  @Test
  func testSettingTheLibraryFolderInvalidatesTheCache() async throws {
    let root = TestScratch.directory(prefix: "NightdrivePlaylistSyncCacheFolders")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let library = LibraryStore(folderURL: first)
    let app = AppState(library: library)
    let before = app.playlistSyncLedgerCache.revision
    #expect(app.setLibraryFolder(second))
    #expect((app.playlistSyncLedgerCache.revision) == (before &+ 1))
    await library.rescan()
  }
}
