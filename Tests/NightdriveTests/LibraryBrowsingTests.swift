import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
final class LibraryBrowsingTests {
  private var folder: URL!

  init() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveLibraryBrowsingTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  @Test
  func testCollectionsGroupAlbumsByArtistAndProvideUnknownBuckets() async throws {
    try writeSong(
      "one.mp3", title: "One", artist: "The Apples", album: "Greatest", genre: "Rock")
    try writeSong(
      "two.mp3", title: "Two", artist: "The Apples", album: "Greatest", genre: "Rock")
    try writeSong(
      "three.mp3", title: "Three", artist: "The Bananas", album: "Greatest", genre: "Pop")
    try writeSong(
      "unknown.mp3", title: "Mystery", artist: "", album: "", genre: "")

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let albums = store.collections(for: .album)
    #expect((albums.count) == (3))
    #expect((albums.filter { $0.title == "Greatest" }.map(\.tracks.count).sorted()) == ([1, 2]))
    #expect((albums.first { $0.title == "Unknown Album" }?.subtitle) == ("Unknown Artist · 1 song"))

    #expect(
      (store.collections(for: .artist).map(\.title))
        == ([
          "The Apples", "The Bananas", "Unknown Artist",
        ]))
    #expect(
      (store.collections(for: .genre).map(\.title))
        == ([
          "Pop", "Rock", "Unknown Genre",
        ]))

    let apples = try #require(store.collections(for: .artist).first { $0.title == "The Apples" })
    let pop = try #require(store.collections(for: .genre).first { $0.title == "Pop" })
    let rock = try #require(store.collections(for: .genre).first { $0.title == "Rock" })
    #expect(
      (LibraryCollection.combinedTracks(from: [apples, pop, rock]).map(\.displayTitle)) == (["One", "Two", "Three"]))

    let artists = store.collections(for: .artist)
    let selectedTrackIDs = Set(
      ["One", "Three"].compactMap { title in
        store.tracks.first { $0.displayTitle == title }?.id
      })
    let projectedArtistIDs = LibraryCollection.ids(
      containingAny: selectedTrackIDs, in: artists)
    #expect((artists.filter { projectedArtistIDs.contains($0.id) }.map(\.title)) == (["The Apples", "The Bananas"]))
  }

  @Test
  func testCollectionCachesSurviveSwitchingBrowseKinds() async throws {
    try writeSong(
      "one.mp3", title: "One", artist: "Artist", album: "Album", genre: "Rock")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let firstArtists = store.collections(for: .artist)
    _ = store.collections(for: .album)
    _ = store.collections(for: .genre)
    let revisitedArtists = store.collections(for: .artist)

    #expect((revisitedArtists) == (firstArtists))
    #expect((store.browserIndexFallbackBuildCount) == (0))
  }

  @Test
  func testSongWithMultipleGenresAppearsInEveryGenreCollection() async throws {
    try writeSong(
      "one.mp3", title: "One", artist: "Artist", album: "Album",
      genre: "Indie Folk; Dream Pop")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let genres = store.collections(for: .genre)
    #expect((genres.map(\.title)) == (["Dream Pop", "Indie Folk"]))
    #expect(genres.allSatisfy { $0.tracks.map(\.displayTitle) == ["One"] })

    let trackID = try #require(store.tracks.first?.id)
    #expect((store.collectionIDs(containingAny: [trackID], for: .genre)) == (Set(genres.map(\.id))))
  }

  @Test
  func testBrowseIndexesResolveSharedSelectionsAndCollectionRows() async throws {
    try writeSong(
      "one.mp3", title: "One", artist: "Artist A", album: "Album A", genre: "Rock")
    try writeSong(
      "two.mp3", title: "Two", artist: "Artist B", album: "Album B", genre: "Pop")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let selectedTrackIDs = Set(store.tracks.map(\.id))

    for kind in LibraryBrowseKind.allCases {
      let collections = store.collections(for: kind)
      let expectedIDs = LibraryCollection.ids(
        containingAny: selectedTrackIDs, in: collections)
      let indexedIDs = store.collectionIDs(containingAny: selectedTrackIDs, for: kind)

      #expect((indexedIDs) == (expectedIDs))
      #expect(
        (store.collections(for: kind, matching: indexedIDs)) == (collections.filter { indexedIDs.contains($0.id) }))
      #expect(indexedIDs.allSatisfy { store.containsCollection($0, for: kind) })
    }
  }

  @Test
  func testAudiobookCollectionsGroupBooksAndExcludeSongs() async throws {
    try writeSong(
      "chapter-2.mp3", title: "Chapter 2", artist: "Narrator", album: "The Book",
      genre: "Audiobook", trackNumber: 2)
    try writeSong(
      "chapter-1.mp3", title: "Chapter 1", artist: "Narrator", album: "The Book",
      genre: "Audiobook", trackNumber: 1)
    try writeSong(
      "song.mp3", title: "Song", artist: "Band", album: "Record", genre: "Rock")

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let books = store.collections(for: .audiobook)
    #expect((books.map(\.title)) == (["The Book"]))
    #expect((books.first?.subtitle) == ("Narrator · 2 songs"))
    #expect((books.first?.tracks.map(\.displayTitle)) == (["Chapter 1", "Chapter 2"]))
    #expect(store.collections(for: .album).map(\.title).contains("Record"))
  }

  @Test
  func testFolderWatcherAutomaticallyFindsAddedSong() async throws {
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    #expect(store.tracks.isEmpty)
    var fullScanInstalls = 0
    store.onPreparingToInstallScan = { _ in
      fullScanInstalls += 1
      return nil
    }

    let nested = folder.appendingPathComponent("New Album", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try writeSong(
      "New Album/arrived.mp3",
      title: "Arrived",
      artist: "Watcher",
      album: "Changes",
      genre: "Test")

    let arrived = await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(100)) {
      !store.tracks.isEmpty
    }
    #expect(arrived, Comment(rawValue: "the watcher never picked up the added song"))

    #expect((store.tracks.map(\.displayTitle)) == (["Arrived"]))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "ordinary additions must stay incremental"))

    let renamed = nested.appendingPathComponent("renamed.mp3")
    try FileManager.default.moveItem(
      at: nested.appendingPathComponent("arrived.mp3"),
      to: renamed)
    await waitUntil(timeout: .seconds(8), pollInterval: .milliseconds(100)) {
      store.tracks.first?.url.lastPathComponent == "renamed.mp3"
    }
    #expect((store.tracks.first?.url.lastPathComponent) == ("renamed.mp3"))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "paired rename events must stay incremental"))

    let caseRenamed = nested.appendingPathComponent("RENAMED.mp3")
    try FileManager.default.moveItem(at: renamed, to: caseRenamed)
    await waitUntil(timeout: .seconds(8), pollInterval: .milliseconds(100)) {
      store.tracks.count == 1 && store.tracks.first?.url.lastPathComponent == "RENAMED.mp3"
    }
    #expect((store.tracks.count) == (1), Comment(rawValue: "a case-only rename must not duplicate the track"))
    #expect((store.tracks.first?.url.lastPathComponent) == ("RENAMED.mp3"))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "case-only renames with a stable identity stay incremental"))

    try FileManager.default.removeItem(at: caseRenamed)
    await waitUntil(timeout: .seconds(8), pollInterval: .milliseconds(100)) {
      store.tracks.isEmpty
    }
    #expect(store.tracks.isEmpty)
    #expect((fullScanInstalls) == (0), Comment(rawValue: "ordinary deletions must stay incremental"))
  }

  @Test
  func testFolderWatcherClassifiesAudioExtensionDirectoriesByTheirFlag() async throws {
    let misleadingDirectory = folder.appendingPathComponent("Album.mp3", isDirectory: true)
    try FileManager.default.createDirectory(
      at: misleadingDirectory, withIntermediateDirectories: true)
    try writeSong(
      "Album.mp3/song.mp3", title: "Nested", artist: "Artist", album: "Album", genre: "Test")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    #expect((store.tracks.map(\.title)) == (["Nested"]))

    try FileManager.default.removeItem(at: misleadingDirectory)

    let observedRemoval = await waitUntil(
      timeout: .seconds(4), pollInterval: .milliseconds(100)
    ) {
      store.tracks.isEmpty
    }
    #expect(observedRemoval, Comment(rawValue: "a directory name must not be classified as an audio file"))
  }

  @Test
  func testFolderWatcherCoalescesBurstOfNestedChanges() async throws {
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let initialRevision = store.derivedDataRevision
    var fullScanInstalls = 0
    store.onPreparingToInstallScan = { _ in
      fullScanInstalls += 1
      return nil
    }

    let nested = folder.appendingPathComponent("Incoming/Album", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 1...3 {
      try writeSong(
        "Incoming/Album/track-\(index).mp3",
        title: "Track \(index)",
        artist: "Watcher",
        album: "Burst",
        genre: "Test")
    }

    await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(100)) {
      store.tracks.count == 3
    }
    let coalesced = await holds(for: .milliseconds(500)) {
      store.tracks.count == 3 && store.derivedDataRevision == initialRevision + 1
    }

    #expect(coalesced, Comment(rawValue: "the burst must land as a single coalesced snapshot"))
    #expect((store.tracks.count) == (3))
    #expect((store.derivedDataRevision) == (initialRevision + 1))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "a created subtree must not scan the entire library"))
  }

  @Test
  func testFolderWatcherReconcilesRemovedDirectoryWithoutScanningSiblings() async throws {
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("Keep", isDirectory: true),
      withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: folder.appendingPathComponent("Remove", isDirectory: true),
      withIntermediateDirectories: true)
    try writeSong(
      "Keep/one.mp3", title: "Keep", artist: "Artist", album: "One", genre: "Test")
    try writeSong(
      "Remove/two.mp3", title: "Remove", artist: "Artist", album: "Two", genre: "Test")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    var fullScanInstalls = 0
    store.onPreparingToInstallScan = { _ in
      fullScanInstalls += 1
      return nil
    }

    try FileManager.default.removeItem(
      at: folder.appendingPathComponent("Remove", isDirectory: true))

    let reconciled = await waitUntil(
      timeout: .seconds(4), pollInterval: .milliseconds(100)
    ) {
      store.tracks.map(\.title) == ["Keep"]
    }
    #expect(reconciled, Comment(rawValue: "the removed subtree must leave the catalog"))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "a removed subtree must not scan its siblings"))
  }

  @Test
  func testFolderWatcherPersistsIncrementalCacheUpdatesAndDeletes() async throws {
    try writeSong(
      "one.mp3", title: "One", artist: "Artist", album: "Album", genre: "Test")
    let appData = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveLibraryBrowsingCache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: appData) }
    let cache = LibraryIndexCache(directoryURL: appData)
    let store = LibraryStore(folderURL: folder, indexCache: cache)
    await store.rescan()
    await waitUntil(pollInterval: .milliseconds(20)) {
      cache.loadEntries(for: self.folder).count == 1
    }
    var fullScanInstalls = 0
    store.onPreparingToInstallScan = { _ in
      fullScanInstalls += 1
      return nil
    }

    try writeSong(
      "two.mp3", title: "Two", artist: "Artist", album: "Album", genre: "Test")
    let added = await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(50)) {
      store.tracks.count == 2 && cache.loadEntries(for: self.folder).count == 2
    }
    #expect(added, Comment(rawValue: "the added track must reach both the catalog and cache"))

    try writeSong(
      "one.mp3", title: "Edited", artist: "Artist", album: "Album", genre: "Test")
    let edited = await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(50)) {
      store.tracks.contains { $0.title == "Edited" }
        && cache.loadEntries(for: self.folder).values.contains { $0.track.title == "Edited" }
    }
    #expect(edited, Comment(rawValue: "the changed track must replace its cached entry"))

    try FileManager.default.removeItem(at: folder.appendingPathComponent("two.mp3"))
    let removed = await waitUntil(timeout: .seconds(4), pollInterval: .milliseconds(50)) {
      store.tracks.count == 1 && cache.loadEntries(for: self.folder).count == 1
    }
    #expect(removed, Comment(rawValue: "the deleted track must leave both the catalog and cache"))
    #expect((fullScanInstalls) == (0), Comment(rawValue: "cache maintenance must not require full scans"))
  }

  @Test
  func testFolderWatcherIgnoresOwnedSidecarsAndIrrelevantFiles() async throws {
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let initialRevision = store.derivedDataRevision

    for filename in [
      ListeningHistoryFile.filename,
      LocalPlaylistFile.filename,
      PendingPlaybackReportStore.filename,
      SyncLedgerStore.filename,
    ] {
      try Data("{}".utf8).write(
        to: folder.appendingPathComponent(filename), options: .atomic)
    }
    try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
    let artwork = folder.appendingPathComponent("Artwork", isDirectory: true)
    try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
    try Data([0, 1, 2]).write(to: artwork.appendingPathComponent("cover.jpg"))

    let stayedIdle = await holds(for: .seconds(1)) {
      store.derivedDataRevision == initialRevision && !store.isScanning
    }
    #expect(stayedIdle, Comment(rawValue: "sidecars and non-audio files must not rescan the library"))
  }

  @Test
  func testFolderWatcherSuppressesReflectedMetadataWritesOnly() async throws {
    try writeSong(
      "edited.mp3", title: "Original", artist: "Artist", album: "Album", genre: "Test")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let original = try #require(store.tracks.first)
    let initialRevision = store.derivedDataRevision
    var metadata = TrackMetadata(original)
    metadata.title = "Edited in Nightdrive"

    try await store.updateMetadata(for: original, to: metadata, artworkChange: .unchanged)

    #expect((store.tracks.first?.title) == ("Edited in Nightdrive"))
    let avoidedDuplicateScan = await holds(for: .seconds(1)) {
      store.derivedDataRevision == initialRevision + 1 && !store.isScanning
    }
    #expect(avoidedDuplicateScan, Comment(rawValue: "the reflected metadata write must not trigger a rescan"))

    try writeSong(
      "edited.mp3", title: "Edited Elsewhere", artist: "Artist", album: "Album", genre: "Test")
    let observedExternalEdit = await waitUntil(
      timeout: .seconds(4), pollInterval: .milliseconds(100)
    ) {
      store.tracks.first?.title == "Edited Elsewhere"
    }
    #expect(observedExternalEdit, Comment(rawValue: "a later external edit must invalidate the suppression"))
  }

  @Test
  func testFolderWatcherDoesNotRepeatAnExplicitRescan() async throws {
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let initialRevision = store.derivedDataRevision
    try writeSong(
      "synced.mp3", title: "Synced", artist: "Artist", album: "Album", genre: "Test")

    await store.rescan()

    #expect((store.tracks.map(\.title)) == (["Synced"]))
    let avoidedDuplicateScan = await holds(for: .seconds(1)) {
      store.derivedDataRevision == initialRevision + 1 && !store.isScanning
    }
    #expect(avoidedDuplicateScan, Comment(rawValue: "events reflected by a full scan must not repeat it"))
  }

  @Test
  func testOverlappingRescansCoalesceAndInstallOneSnapshot() async throws {
    try writeSong(
      "coalesced.mp3", title: "Coalesced", artist: "Scanner", album: "One", genre: "Test")
    let store = LibraryStore(folderURL: folder)

    async let first: Void = store.rescan()
    async let second: Void = store.rescan()
    await first
    await second

    #expect(!(store.isScanning))
    #expect((store.tracks.map(\.displayTitle)) == (["Coalesced"]))
    #expect((store.derivedDataRevision) == (1))
  }

  @Test
  func testOverlappingTargetedRefreshesPreserveBothUpdates() async throws {
    for index in 0..<8 {
      try writeSong(
        "track-\(index).mp3",
        title: "Old \(index)",
        artist: "Artist",
        album: "Album",
        genre: "Test",
        trackNumber: index + 1)
    }
    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    try writeSong(
      "track-0.mp3",
      title: "New First",
      artist: "Artist",
      album: "Album",
      genre: "Test",
      trackNumber: 1)
    try writeSong(
      "track-7.mp3",
      title: "New Last",
      artist: "Artist",
      album: "Album",
      genre: "Test",
      trackNumber: 8)

    let folder = try #require(folder)
    async let first: Void = store.refreshTracks(
      at: [folder.appendingPathComponent("track-0.mp3")])
    async let last: Void = store.refreshTracks(
      at: [folder.appendingPathComponent("track-7.mp3")])
    await first
    await last

    #expect((store.catalog[TrackID(url: folder.appendingPathComponent("track-0.mp3"))]?.title) == ("New First"))
    #expect((store.catalog[TrackID(url: folder.appendingPathComponent("track-7.mp3"))]?.title) == ("New Last"))
  }

  @Test
  func testCompilationAlbumsUseVariousArtistsAndDiscTrackOrder() async throws {
    try writeSong(
      "disc-two.mp3",
      title: "Finale",
      artist: "Singer B",
      album: "Soundtrack",
      genre: "Soundtrack",
      trackNumber: 1,
      discNumber: 2,
      compilation: true)
    try writeSong(
      "second.mp3",
      title: "Second",
      artist: "Singer A",
      album: "Soundtrack",
      genre: "Soundtrack",
      trackNumber: 2,
      discNumber: 1,
      compilation: true)
    try writeSong(
      "first.mp3",
      title: "First",
      artist: "Singer C",
      album: "Soundtrack",
      genre: "Soundtrack",
      trackNumber: 1,
      discNumber: 1,
      compilation: true)

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let album = try #require(store.collections(for: .album).first)
    #expect((album.subtitle) == ("Various Artists · 3 songs"))
    #expect((album.tracks.map(\.displayTitle)) == (["First", "Second", "Finale"]))
  }

  @Test
  func testUntaggedMultiArtistAlbumInOneFolderStaysASingleAlbum() async throws {
    let nested = folder.appendingPathComponent("Bravo Hits 46", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for (index, artist) in ["Outkast", "Britney Spears", "Blue"].enumerated() {
      try writeSong(
        "Bravo Hits 46/track-\(index).mp3",
        title: "Song \(index)",
        artist: artist,
        album: "Bravo Hits 46",
        genre: "Pop",
        trackNumber: index + 1)
    }

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let albums = store.collections(for: .album)
    #expect((albums.count) == (1))
    #expect((albums[0].subtitle) == ("Various Artists · 3 songs"))
  }

  @Test
  func testPartiallyTaggedAlbumArtistAdoptsUntaggedTracks() async throws {
    try writeSong(
      "one.mp3",
      title: "Come Together",
      artist: "The Beatles",
      album: "Abbey Road",
      genre: "Rock",
      trackNumber: 1,
      albumArtist: "The Beatles")
    try writeSong(
      "two.mp3",
      title: "Something",
      artist: "The Beatles feat. Billy Preston",
      album: "Abbey Road",
      genre: "Rock",
      trackNumber: 2)

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let albums = store.collections(for: .album)
    #expect((albums.count) == (1))
    #expect((albums[0].subtitle) == ("The Beatles · 2 songs"))
  }

  @Test
  func testSameTitledAlbumsInOneFolderStaySeparate() async throws {
    try writeSong(
      "queen.mp3",
      title: "We Will Rock You",
      artist: "Queen",
      album: "Greatest Hits",
      genre: "Rock",
      trackNumber: 1)
    try writeSong(
      "abba.mp3",
      title: "Waterloo",
      artist: "ABBA",
      album: "Greatest Hits",
      genre: "Pop",
      trackNumber: 1)

    let store = LibraryStore(folderURL: folder)
    await store.rescan()

    let albums = store.collections(for: .album)
    #expect((albums.count) == (2))
    #expect((albums.map(\.subtitle).sorted()) == (["ABBA · 1 song", "Queen · 1 song"]))
  }

  @Test
  func testCollectionIDsRemainDistinctWhenMetadataContainsDelimiter() async throws {
    try writeSong(
      "first.mp3",
      title: "First",
      artist: "Artist",
      album: "A|B",
      genre: "Test",
      albumArtist: "C")
    try writeSong(
      "second.mp3",
      title: "Second",
      artist: "Artist",
      album: "A",
      genre: "Test",
      albumArtist: "B|C")

    let albums = LibraryStore(folderURL: folder)
    await albums.rescan()
    let collections = albums.collections(for: .album)

    #expect((collections.count) == (2))
    #expect((Set(collections.map(\.id)).count) == (2))
  }

  @Test
  func testCollectionGroupingKeepsPriorCaseDiacriticAndWidthSemantics() async throws {
    try writeSong(
      "accented.mp3",
      title: "Accented",
      artist: "Beyoncé",
      album: "Album",
      genre: "Test")
    try writeSong(
      "case-and-diacritic.mp3",
      title: "Folded",
      artist: "BEYONCE",
      album: "Album",
      genre: "Test")
    try writeSong(
      "full-width.mp3",
      title: "Wide",
      artist: "ＢＥＹＯＮＣＥ",
      album: "Album",
      genre: "Test")

    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let artists = store.collections(for: .artist)

    #expect((artists.count) == (2))
    #expect((artists.map(\.tracks.count).sorted()) == ([1, 2]))
    #expect(artists.contains { $0.title == "ＢＥＹＯＮＣＥ" && $0.tracks.count == 1 })
  }

  @Test
  func testDerivedCollectionsAndURLIndexRefreshAfterRescan() async throws {
    try writeSong(
      "first.mp3",
      title: "First",
      artist: "Original Artist",
      album: "Original Album",
      genre: "Rock")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let firstURL = folder.appendingPathComponent("first.mp3")
    let firstRevision = store.derivedDataRevision

    #expect((store.collections(for: .artist).map(\.title)) == (["Original Artist"]))
    #expect((store.catalog[TrackID(url: firstURL)]?.title) == ("First"))
    #expect((store.derivedDataRevision) == (firstRevision))

    try FileManager.default.removeItem(at: firstURL)
    try writeSong(
      "second.mp3",
      title: "Second",
      artist: "Replacement Artist",
      album: "Replacement Album",
      genre: "Jazz")
    await store.rescan()

    #expect((store.derivedDataRevision) > (firstRevision))
    #expect((store.collections(for: .artist).map(\.title)) == (["Replacement Artist"]))
    #expect((store.collections(for: .album).map(\.title)) == (["Replacement Album"]))
    #expect((store.collections(for: .genre).map(\.title)) == (["Jazz"]))
    #expect(store.catalog[TrackID(url: firstURL)] == nil)
    #expect((store.catalog[TrackID(url: folder.appendingPathComponent("second.mp3"))]?.title) == ("Second"))
  }

  @Test
  func testTotalStatsAreInstalledWithEachLibraryRevision() async throws {
    try writeSong(
      "first.mp3", title: "First", artist: "Artist", album: "Album", genre: "Test")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let firstRevision = store.derivedDataRevision
    let firstStats = store.totalStats

    #expect((firstStats.count) == (1))
    #expect((firstStats.durationMS) > (0))
    #expect((firstStats.sizeBytes) > (0))
    #expect((store.totalStats.count) == (firstStats.count))
    #expect((store.totalStats.durationMS) == (firstStats.durationMS))
    #expect((store.totalStats.sizeBytes) == (firstStats.sizeBytes))
    #expect((store.derivedDataRevision) == (firstRevision))

    try writeSong(
      "second.mp3", title: "Second", artist: "Artist", album: "Album", genre: "Test")
    await store.rescan()
    let secondStats = store.totalStats

    #expect((store.derivedDataRevision) > (firstRevision))
    #expect((secondStats.count) == (2))
    #expect((secondStats.durationMS) > (firstStats.durationMS))
    #expect((secondStats.sizeBytes) > (firstStats.sizeBytes))
  }

  @Test
  func testBulkTrashReportsPartialSuccess() async throws {
    try writeSong(
      "kept.mp3", title: "Kept", artist: "Artist", album: "Album", genre: "Test")
    try writeSong(
      "already-gone.mp3",
      title: "Already Gone",
      artist: "Artist",
      album: "Album",
      genre: "Test")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let tracks = store.tracks
    let missing = try #require(tracks.first { $0.displayTitle == "Already Gone" })
    try FileManager.default.removeItem(at: missing.url)

    let result = await store.moveToTrash(tracks)

    #expect((result.succeeded.map(\.displayTitle)) == (["Kept"]))
    #expect((result.failed.map(\.track.displayTitle)) == (["Already Gone"]))
    #expect(store.tracks.isEmpty)
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
}
