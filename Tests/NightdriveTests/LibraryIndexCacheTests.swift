import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct LibraryIndexCacheTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  private final class LoadCounter: Sendable {
    private let paths = Mutex<[String]>([])
    func record(_ url: URL) {
      paths.withLock { $0.append(url.lastPathComponent) }
    }
    var loadedFilenames: [String] {
      paths.withLock { $0.sorted() }
    }
    var count: Int {
      paths.withLock { $0.count }
    }
  }

  private func makeTrack(url: URL, title: String) -> LibraryTrack {
    .fixture(url: url, title: title, genre: "Rock", trackNumber: 1, year: 2001, sizeBytes: 0)
  }

  private func writeFile(_ name: String, contents: String) throws -> URL {
    let url = scratch.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func scan(
    _ urls: [URL],
    consulting cache: [String: LibraryIndexCacheEntry],
    counter: LoadCounter
  ) async -> (tracks: [LibraryTrack], entries: [String: LibraryIndexCacheEntry]) {
    await LibraryStore.scanTracks(at: urls, consulting: cache) { [weak counter] url in
      counter?.record(url)
      return LibraryTrack(
        url: url, title: "loaded:\(url.lastPathComponent)", artist: "Artist", album: "Album", genre: "Rock",
        trackNumber: 1, year: 2001, durationMS: 1000, sizeBytes: 0, bitrate: 128, samplerate: 44_100)
    }
  }

  @Test
  func testUnchangedFilesAreServedFromTheCacheWithoutLoading() async throws {
    let first = try writeFile("a.mp3", contents: "aaaa")
    let second = try writeFile("b.mp3", contents: "bbbb")

    let counter = LoadCounter()
    let cold = await scan([first, second], consulting: [:], counter: counter)
    #expect((counter.count) == (2), Comment(rawValue: "a cold scan reads every file"))
    #expect((cold.entries.count) == (2))

    let warmCounter = LoadCounter()
    let warm = await scan([first, second], consulting: cold.entries, counter: warmCounter)
    #expect((warmCounter.count) == (0), Comment(rawValue: "an unchanged library is a zero-read scan"))
    #expect((warm.tracks.map(\.title)) == (cold.tracks.map(\.title)))
    #expect((warm.entries.count) == (2))
  }

  @Test
  func testModificationTimeChangeInvalidatesOnlyThatFile() async throws {
    let first = try writeFile("a.mp3", contents: "aaaa")
    let second = try writeFile("b.mp3", contents: "bbbb")
    let counter = LoadCounter()
    let cold = await scan([first, second], consulting: [:], counter: counter)

    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: first.path)

    let warmCounter = LoadCounter()
    _ = await scan([first, second], consulting: cold.entries, counter: warmCounter)
    #expect((warmCounter.loadedFilenames) == (["a.mp3"]))
  }

  @Test
  func testSizeChangeInvalidatesEvenWithTheOriginalModificationTime() async throws {
    let file = try writeFile("a.mp3", contents: "aaaa")
    let counter = LoadCounter()
    let cold = await scan([file], consulting: [:], counter: counter)
    let originalDate = try #require(
      try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
        as? Date)

    try Data("aaaa-and-more".utf8).write(to: file)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: file.path)

    let warmCounter = LoadCounter()
    _ = await scan([file], consulting: cold.entries, counter: warmCounter)
    #expect((warmCounter.loadedFilenames) == (["a.mp3"]))
  }

  @Test
  func testDeletedFilesFallOutOfTheRefreshedEntries() async throws {
    let first = try writeFile("a.mp3", contents: "aaaa")
    let second = try writeFile("b.mp3", contents: "bbbb")
    let counter = LoadCounter()
    let cold = await scan([first, second], consulting: [:], counter: counter)

    try FileManager.default.removeItem(at: second)
    let warmCounter = LoadCounter()
    let warm = await scan([first], consulting: cold.entries, counter: warmCounter)
    #expect((warmCounter.count) == (0))
    #expect((Array(warm.entries.keys)) == ([first.standardizedFileURL.path]))
  }

  @Test
  func testStatFailureNeverCreatesReusableCacheEntry() async throws {
    let missing = scratch.appendingPathComponent("missing.mp3")
    let counter = LoadCounter()
    let first = await scan([missing], consulting: [:], counter: counter)
    #expect((counter.count) == (1))
    #expect(first.entries.isEmpty)

    let secondCounter = LoadCounter()
    let second = await scan([missing], consulting: first.entries, counter: secondCounter)
    #expect((secondCounter.count) == (1), Comment(rawValue: "a failed stat must fail closed on every scan"))
    #expect(second.tracks.first?.fileGenerationStamp == nil)
    #expect(second.entries.isEmpty)
  }

  @Test
  func testZeroFilesystemGenerationIsTreatedAsUnavailable() {
    let stamp = FileGenerationStamp(
      deviceID: 1, inode: 2, sizeBytes: 3,
      modificationSeconds: 4, modificationNanoseconds: 5,
      changeSeconds: 6, changeNanoseconds: 7, generation: 0)
    #expect(stamp.generation == nil)
  }

  @MainActor
  @Test
  func testSameStatInPlaceRewriteInvalidatesRescanAndRelaunchCache() async throws {
    try MP3Builder.build(
      tags: .init(
        title: "Cached", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1
    ).write(to: scratch.appendingPathComponent("song.mp3"))
    let songURL = scratch.appendingPathComponent("song.mp3")
    let pinnedDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: songURL.path)

    let persistence = MemoryKeyedPersistence()
    let cache = LibraryIndexCache { key in persistence.persistence(forKey: key) }

    let store = LibraryStore(folderURL: scratch, indexCache: cache)
    await store.rescan()
    #expect((store.tracks.map(\.title)) == (["Cached"]))

    let folder = scratch
    await waitUntil(pollInterval: .milliseconds(20)) {
      !cache.loadEntries(for: folder).isEmpty
    }
    let persisted = cache.loadEntries(for: folder)
    #expect((persisted.values.map(\.track.title)) == (["Cached"]))

    let originalStamp = try #require(FileGenerationStamp(url: songURL))
    let edited = MP3Builder.build(
      tags: .init(
        title: "Edited", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1)
    try edited.write(to: songURL)
    let editedStamp = try pinnedGenerationStamp(
      at: songURL, distinctFrom: originalStamp, modificationDate: pinnedDate)
    #expect((editedStamp.inode) == (originalStamp.inode), Comment(rawValue: "the writer must reuse the inode"))
    #expect((editedStamp.sizeBytes) == (originalStamp.sizeBytes))
    #expect((editedStamp.modificationSeconds) == (originalStamp.modificationSeconds))
    #expect((editedStamp.modificationNanoseconds) == (originalStamp.modificationNanoseconds))
    #expect((editedStamp) != (originalStamp))

    let second = LibraryStore(folderURL: folder, indexCache: cache)
    await second.rescan()
    #expect((second.tracks.map(\.title)) == (["Edited"]))

    await waitUntil(pollInterval: .milliseconds(20)) {
      cache.loadEntries(for: folder).values.first?.track.title == "Edited"
    }
    let rescanned = MP3Builder.build(
      tags: .init(
        title: "Rescan", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1)
    try rescanned.write(to: songURL)
    _ = try pinnedGenerationStamp(
      at: songURL, distinctFrom: editedStamp, modificationDate: pinnedDate)

    await second.rescan()
    #expect((second.tracks.map(\.title)) == (["Rescan"]))
  }

  @MainActor
  @Test
  func testSamePathRootReplacementCannotReusePreviousRootMetadata() async throws {
    let libraryFolder = scratch.appendingPathComponent("library", isDirectory: true)
    let movedFolder = scratch.appendingPathComponent("moved-library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: libraryFolder, withIntermediateDirectories: false)
    let songURL = libraryFolder.appendingPathComponent("song.mp3")
    let pinnedDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let firstBytes = MP3Builder.build(
      tags: .init(
        title: "Alpha", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1)
    try firstBytes.write(to: songURL)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: songURL.path)
    let firstStamp = try #require(FileGenerationStamp(url: songURL))

    let persistence = MemoryKeyedPersistence()
    let cache = LibraryIndexCache { key in persistence.persistence(forKey: key) }
    let store = LibraryStore(folderURL: libraryFolder, indexCache: cache)
    await store.rescan()
    #expect((store.tracks.map(\.title)) == (["Alpha"]))

    let firstRoot = try LibraryFolderIdentity.resolve(libraryFolder)
    await waitUntil(pollInterval: .milliseconds(20)) {
      !cache.loadEntries(for: firstRoot).isEmpty
    }
    #expect((cache.loadEntries(for: firstRoot).values.map(\.track.title)) == (["Alpha"]))

    try FileManager.default.moveItem(at: libraryFolder, to: movedFolder)
    try FileManager.default.createDirectory(
      at: libraryFolder, withIntermediateDirectories: false)
    let replacementBytes = MP3Builder.build(
      tags: .init(
        title: "Bravo", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1)
    #expect((replacementBytes.count) == (firstBytes.count))
    try replacementBytes.write(to: songURL)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: songURL.path)
    let replacementStamp = try #require(FileGenerationStamp(url: songURL))
    #expect((replacementStamp.sizeBytes) == (firstStamp.sizeBytes))
    #expect((replacementStamp.modificationSeconds) == (firstStamp.modificationSeconds))
    #expect((replacementStamp.modificationNanoseconds) == (firstStamp.modificationNanoseconds))

    #expect(try store.setFolder(libraryFolder))
    await store.rescan()

    #expect((store.tracks.map(\.title)) == (["Bravo"]))
    let replacementRoot = try LibraryFolderIdentity.resolve(libraryFolder)
    #expect(!(replacementRoot.referencesSameResource(as: firstRoot)))
  }

  @MainActor
  @Test
  func testMetadataEditRefreshesOnlyTheEditedTrack() async throws {
    let editedURL = scratch.appendingPathComponent("edited.mp3")
    let untouchedURL = scratch.appendingPathComponent("untouched.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Before", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 1
    ).write(to: editedURL)
    try MP3Builder.build(
      tags: .init(
        title: "Bystander", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 2, year: 2001),
      seconds: 1
    ).write(to: untouchedURL)

    let store = LibraryStore(folderURL: scratch)
    await store.rescan()
    let edited = try #require(store.tracks.first { $0.url == editedURL.canonicalFileURL })
    let untouchedBefore = try #require(store.tracks.first { $0.url == untouchedURL.canonicalFileURL })

    var metadata = TrackMetadata(edited)
    metadata.title = "After"
    try Data("not an mp3 anymore".utf8).write(to: untouchedURL)
    try await store.updateMetadata(for: edited, to: metadata, artworkChange: .unchanged)

    #expect(
      (store.tracks.first { $0.url == editedURL.canonicalFileURL }?.title) == ("After"),
      Comment(rawValue: "the edited file is re-read from disk"))
    #expect(
      (store.tracks.first { $0.url == untouchedURL.canonicalFileURL }?.title) == (untouchedBefore.title),
      Comment(rawValue: "other tracks keep their previously scanned metadata"))
  }

  private func makeEntry(title: String, generation: UInt32) -> LibraryIndexCacheEntry {
    LibraryIndexCacheEntry(
      stamp: FileGenerationStamp(
        deviceID: 1, inode: 2, sizeBytes: 3,
        modificationSeconds: 4, modificationNanoseconds: 5,
        changeSeconds: 6, changeNanoseconds: 7, generation: generation),
      track: makeTrack(url: URL(fileURLWithPath: "/library/\(title).mp3"), title: title))
  }

  @Test
  func testEntryDeltaUpdatesAndRemovesWhileRewritingOnlyTouchedShards() throws {
    let persistence = MemoryKeyedPersistence()
    let cache = LibraryIndexCache { persistence.persistence(forKey: $0) }
    let root = try LibraryFolderIdentity.resolve(scratch)
    let entries = [
      "/library/a.mp3": makeEntry(title: "A", generation: 1),
      "/library/b.mp3": makeEntry(title: "B", generation: 2),
      "/library/c.mp3": makeEntry(title: "C", generation: 3),
    ]
    cache.saveEntries(entries, for: root)
    #expect((cache.loadEntries(for: root).keys.sorted()) == (entries.keys.sorted()))
    let fullSaveCount = persistence.saveCount

    persistence.resetSaveLog()
    cache.applyEntryDelta(
      updating: ["/library/a.mp3": makeEntry(title: "A Rewritten", generation: 9)],
      removingPaths: ["/library/b.mp3"],
      for: root)

    let loaded = cache.loadEntries(for: root)
    #expect((loaded["/library/a.mp3"]?.track.title) == ("A Rewritten"))
    #expect(loaded["/library/b.mp3"] == nil)
    #expect((loaded["/library/c.mp3"]?.track.title) == ("C"))
    #expect(
      persistence.saveCount <= 2 && persistence.saveCount < fullSaveCount,
      Comment(rawValue: "a two-path delta must not rewrite the whole cache"))
  }

  @Test
  func testLegacySingleFileCacheMigratesToShardsOnFirstDelta() throws {
    struct LegacyPayload: Codable {
      let metadataDerivationVersion: Int
      let entries: [String: LibraryIndexCacheEntry]
    }

    let persistence = MemoryKeyedPersistence()
    let cache = LibraryIndexCache { persistence.persistence(forKey: $0) }
    let root = try LibraryFolderIdentity.resolve(scratch)
    let legacy = LegacyPayload(
      metadataDerivationVersion: 4,
      entries: [
        "/library/a.mp3": makeEntry(title: "A", generation: 1),
        "/library/b.mp3": makeEntry(title: "B", generation: 2),
      ])
    try persistence.persistence(forKey: LibraryIndexCache.persistenceKey(for: root))
      .save(legacy)
    #expect((cache.loadEntries(for: root).count) == (2))

    cache.applyEntryDelta(
      updating: ["/library/c.mp3": makeEntry(title: "C", generation: 3)],
      removingPaths: ["/library/b.mp3"],
      for: root)

    let migrated = cache.loadEntries(for: root)
    #expect((migrated.keys.sorted()) == (["/library/a.mp3", "/library/c.mp3"]))

    // Later deltas take the sharded path and keep reading the same state.
    cache.applyEntryDelta(updating: [:], removingPaths: ["/library/a.mp3"], for: root)
    #expect((cache.loadEntries(for: root).keys.sorted()) == (["/library/c.mp3"]))
  }
}

final class MemoryKeyedPersistence: Sendable {
  private let storage = Mutex<[String: Data]>([:])
  private let saveLog = Mutex<[String]>([])

  func persistence(forKey key: String) -> any AppDataPersistence {
    Backend(owner: self, key: key)
  }

  var saveCount: Int {
    saveLog.withLock { $0.count }
  }

  func resetSaveLog() {
    saveLog.withLock { $0.removeAll() }
  }

  fileprivate func load(_ key: String) -> Data? {
    storage.withLock { $0[key] }
  }

  fileprivate func save(_ data: Data, key: String) {
    saveLog.withLock { $0.append(key) }
    storage.withLock { $0[key] = data }
  }

  private struct Backend: AppDataPersistence {
    let owner: MemoryKeyedPersistence
    let key: String
    func load() throws -> Data? { owner.load(key) }
    func save(_ data: Data) throws { owner.save(data, key: key) }
  }
}
