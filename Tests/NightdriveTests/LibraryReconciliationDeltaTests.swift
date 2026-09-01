import Foundation
import Testing

@testable import Nightdrive

/// Incremental reconciliation must be observably identical to a full rescan:
/// the same catalog order, totals, browse collections, and membership
/// indexes, for every browse kind.
@MainActor
@Suite(.serialized)
final class LibraryReconciliationDeltaTests {
  private var folder: URL!

  init() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveLibraryReconciliationDeltaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  private func writeSong(
    _ name: String,
    title: String,
    artist: String,
    album: String,
    genre: String,
    trackNumber: Int = 1,
    discNumber: Int = 0,
    albumArtist: String = "",
    compilation: Bool = false
  ) throws {
    let tags = MP3Builder.Tags(
      title: title,
      artist: artist,
      album: album,
      genre: genre,
      trackNumber: trackNumber,
      year: 2026,
      discNumber: discNumber,
      albumArtist: albumArtist,
      compilation: compilation)
    try MP3Builder.build(tags: tags, seconds: 0.1)
      .write(to: folder.appendingPathComponent(name))
  }

  private func seedLibrary() throws {
    try writeSong(
      "apples-1.mp3", title: "One", artist: "The Apples", album: "Greatest", genre: "Rock",
      trackNumber: 1)
    try writeSong(
      "apples-2.mp3", title: "Two", artist: "The Apples", album: "Greatest", genre: "Rock",
      trackNumber: 2)
    try writeSong(
      "bananas.mp3", title: "Three", artist: "The Bananas", album: "Greatest", genre: "Pop",
      trackNumber: 1)
    try writeSong(
      "cherry.mp3", title: "Four", artist: "Cherry", album: "Orchard", genre: "Folk",
      trackNumber: 1, albumArtist: "Cherry")
    try writeSong(
      "chapter-1.mp3", title: "Chapter 1", artist: "Narrator", album: "The Book",
      genre: "Audiobook", trackNumber: 1)
    try writeSong(
      "chapter-2.mp3", title: "Chapter 2", artist: "Narrator", album: "The Book",
      genre: "Audiobook", trackNumber: 2)
    try writeSong(
      "mix-1.mp3", title: "Opener", artist: "Singer A", album: "Soundtrack",
      genre: "Soundtrack", trackNumber: 1, compilation: true)
    try writeSong(
      "mix-2.mp3", title: "Closer", artist: "Singer B", album: "Soundtrack",
      genre: "Soundtrack", trackNumber: 2, compilation: true)
    try writeSong(
      "deleted.mp3", title: "Doomed", artist: "The Apples", album: "Leftovers", genre: "Rock",
      trackNumber: 1)
  }

  private func materializeBrowsers(_ store: LibraryStore) {
    for kind in LibraryBrowseKind.allCases {
      _ = store.collections(for: kind)
    }
  }

  private func expectMatchesFullRescan(_ store: LibraryStore) async throws {
    let fresh = LibraryStore(folderURL: folder)
    await fresh.rescan()
    #expect((store.tracks) == (fresh.tracks))
    #expect((store.totalStats.count) == (fresh.totalStats.count))
    #expect((store.totalStats.durationMS) == (fresh.totalStats.durationMS))
    #expect((store.totalStats.sizeBytes) == (fresh.totalStats.sizeBytes))
    let allTrackIDs = Set(fresh.tracks.map(\.id))
    for kind in LibraryBrowseKind.allCases {
      let incremental = store.collections(for: kind)
      let rebuilt = fresh.collections(for: kind)
      #expect((incremental) == (rebuilt), Comment(rawValue: "collections for \(kind) diverged"))
      #expect(
        (store.collectionIDs(containingAny: allTrackIDs, for: kind))
          == (fresh.collectionIDs(containingAny: allTrackIDs, for: kind)),
        Comment(rawValue: "track membership index for \(kind) diverged"))
      for (position, collection) in rebuilt.enumerated() {
        #expect(
          (store.collections(for: kind, matching: [collection.id])) == ([rebuilt[position]]),
          Comment(rawValue: "collection positions for \(kind) diverged"))
      }
    }
  }

  @Test
  func testWatcherDrivenReconciliationMatchesFullRescanAndUpdatesCacheIncrementally()
    async throws
  {
    try seedLibrary()
    let persistence = MemoryKeyedPersistence()
    let cache = LibraryIndexCache { persistence.persistence(forKey: $0) }
    let store = LibraryStore(folderURL: folder, indexCache: cache)
    await store.rescan()
    materializeBrowsers(store)
    #expect((store.totalStats.count) == (9))
    let folder = try #require(folder)
    await waitUntil { cache.loadEntries(for: folder).count == 9 }

    // External changes behind the store's back: an added album, a retagged
    // file that moves genre and album, and a deletion.
    try writeSong(
      "added.mp3", title: "Fresh", artist: "The Bananas", album: "Second Harvest",
      genre: "Pop", trackNumber: 1)
    try writeSong(
      "bananas.mp3", title: "Three Redux", artist: "The Bananas", album: "Reissue",
      genre: "Electronic", trackNumber: 1)
    try FileManager.default.removeItem(at: folder.appendingPathComponent("deleted.mp3"))

    let retagURL = folder.appendingPathComponent("bananas.mp3")
    let reconciled = await waitUntil(timeout: .seconds(30)) {
      store.totalStats.count == 9
        && store.track(at: retagURL)?.album == "Reissue"
        && store.track(at: folder.appendingPathComponent("added.mp3")) != nil
        && store.track(at: folder.appendingPathComponent("deleted.mp3")) == nil
    }
    #expect(reconciled, Comment(rawValue: "the folder watcher never installed the changes"))

    try await expectMatchesFullRescan(store)
    #expect(
      (store.browserIndexFallbackBuildCount) == (0),
      Comment(rawValue: "reconciliation must refresh materialized browse indexes in the background"))

    // The persisted index cache follows the delta without a full rewrite.
    // Keys may differ in symlink form between scan and watcher events, so
    // assert on entry contents rather than exact paths.
    let cacheSettled = await waitUntil(timeout: .seconds(10)) {
      let tracks = cache.loadEntries(for: folder).values.map(\.track)
      return tracks.count == 9
        && tracks.contains { $0.title == "Three Redux" && $0.album == "Reissue" }
        && tracks.contains { $0.title == "Fresh" }
        && !tracks.contains { $0.title == "Doomed" }
        && !tracks.contains { $0.title == "Three" }
    }
    #expect(cacheSettled, Comment(rawValue: "the cache delta never persisted"))
  }

  @Test
  func testTargetedRefreshRegroupsAlbumsLikeAFullRescan() async throws {
    try seedLibrary()
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    materializeBrowsers(store)

    // Splitting a shared-title album by retagging one member's album artist
    // exercises album-artist re-resolution across the whole title bucket.
    try writeSong(
      "bananas.mp3", title: "Three", artist: "The Bananas", album: "Greatest", genre: "Pop",
      trackNumber: 1, albumArtist: "The Bananas Band")
    // A genre move plus an audiobook demotion in one refresh.
    try writeSong(
      "chapter-2.mp3", title: "Chapter 2", artist: "Narrator", album: "The Book",
      genre: "Spoken Word", trackNumber: 2)

    let folder = try #require(folder)
    await store.refreshTracks(at: [
      folder.appendingPathComponent("bananas.mp3").canonicalFileURL,
      folder.appendingPathComponent("chapter-2.mp3").canonicalFileURL,
    ])

    try await expectMatchesFullRescan(store)
  }

  @Test
  func testTargetedRefreshOfNewFileAppendsLikeAFullRescan() async throws {
    try seedLibrary()
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    materializeBrowsers(store)

    try writeSong(
      "appended.mp3", title: "Appendix", artist: "Zebra", album: "Stripes", genre: "Jazz",
      trackNumber: 1)
    let folder = try #require(folder)
    await store.refreshTracks(at: [folder.appendingPathComponent("appended.mp3").canonicalFileURL])

    #expect((store.totalStats.count) == (10))
    try await expectMatchesFullRescan(store)
  }

  @Test
  func testDeltaLeavesUntouchedGenresOfMultiGenreBystandersIntact() async throws {
    // "bridge.mp3" shares Rock with the changed track and also belongs to
    // Jazz, which no delta touches. Rebuilding Rock must not emit a spurious
    // partial Jazz collection alongside the retained one.
    try writeSong(
      "bridge.mp3", title: "Bridge", artist: "Fusion", album: "Crossings",
      genre: "Rock; Jazz")
    try writeSong(
      "purist.mp3", title: "Purist", artist: "Quartet", album: "Standards", genre: "Jazz")
    try writeSong(
      "rocker.mp3", title: "Rocker", artist: "Amp", album: "Loud", genre: "Rock")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    materializeBrowsers(store)

    try writeSong(
      "rocker.mp3", title: "Rocker Redux", artist: "Amp", album: "Loud", genre: "Rock")
    let folder = try #require(folder)
    await store.refreshTracks(at: [folder.appendingPathComponent("rocker.mp3").canonicalFileURL])

    let genres = store.collections(for: .genre)
    #expect((genres.map(\.title)) == (["Jazz", "Rock"]))
    #expect(
      (genres.first { $0.title == "Jazz" }?.tracks.map(\.displayTitle)) == (["Bridge", "Purist"]))
    try await expectMatchesFullRescan(store)
  }
}
