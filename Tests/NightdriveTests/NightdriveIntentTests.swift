import AppKit
import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct NightdriveIntentTests {
  @Test
  func injectableBridgeDispatchesActionsAndPreservesEntityQueryOrder() async throws {
    let recorder = IntentRecorder()
    let bridge = NightdriveIntentBridge(operations: recorder.operations)

    try await bridge.togglePlayback()
    try await bridge.next()
    try await bridge.previous()
    try await bridge.playCollection("album")
    try await bridge.openCollection("artist")
    try bridge.openUpNext()
    let entities = try await bridge.entities(identifiedBy: ["artist", "album", "missing"])

    #expect(recorder.actions == ["toggle", "next", "previous", "play:album", "open:artist", "up-next"])
    #expect(entities.map(\.id) == ["artist", "album"])
  }

  @Test
  func collectionIdentifiersStayStableAcrossDisplayMetadataChanges() throws {
    let id = LibraryCollectionID(kind: .album, primary: "album-key", secondary: "artist-key")
    let first = try #require(
      NightdriveCollectionEntity.libraryCollection(
        LibraryCollection(id: id, title: "First Title", subtitle: "Artist · 2 songs", tracks: [])))
    let renamed = try #require(
      NightdriveCollectionEntity.libraryCollection(
        LibraryCollection(id: id, title: "Renamed", subtitle: "Artist · 2 songs", tracks: [])))

    #expect(first.id == renamed.id)
    #expect(first != renamed)
  }

  @Test
  func collectionDeepLinksRoundTripAndRejectForeignURLs() {
    let id = "album:Y29sb25zOuepug:YXJ0aXN0"
    let url = NightdriveDeepLink.url(forCollectionID: id)

    #expect(NightdriveDeepLink.collectionID(from: url) == id)
    #expect(NightdriveDeepLink.collectionID(from: URL(string: "https://example.com")!) == nil)
    #expect(NightdriveDeepLink.collectionID(from: URL(string: "nightdrive://open")!) == nil)
    #expect(
      NightdriveDeepLink.collectionID(
        from: URL(string: "nightdrive://open/path?collection=album")!) == nil)
    #expect(
      NightdriveDeepLink.collectionID(
        from: URL(string: "nightdrive://open?collection=album&collection=artist")!) == nil)
    #expect(
      NightdriveDeepLink.collectionID(
        from: URL(string: "nightdrive://user@open?collection=album")!) == nil)
  }

  @Test
  func applicationDelegateBuffersDeepLinksAndKeepsThemOutOfAudioOpening() {
    let delegate = NightdriveApplicationDelegate { _, _ in }
    let deepLink = NightdriveDeepLink.url(forCollectionID: "artist:test")
    let audio = URL(fileURLWithPath: "/Music/Test.mp3")
    var openedDeepLinks: [URL] = []
    var openedAudio: [[URL]] = []

    delegate.application(NSApplication.shared, open: [deepLink, audio])
    delegate.openAudioFiles = { openedAudio.append($0) }
    delegate.openNightdriveURL = {
      openedDeepLinks.append($0)
      return true
    }

    #expect(openedDeepLinks == [deepLink])
    #expect(openedAudio == [[audio]])
  }

  @Test
  func spotlightSynchronizationReplacesOnceThenWritesOnlyDeltas() async {
    let writer = RecordingSpotlightWriter()
    let snapshots = MemorySpotlightSnapshotStore()
    let synchronizer = NightdriveSpotlightSynchronizer(
      writer: writer, snapshotStore: snapshots)
    let artist = entity(id: "artist", title: "Artist")
    let album = entity(id: "album", title: "Album")

    await synchronizer.synchronize([artist, album])
    await synchronizer.synchronize([artist, album])
    await synchronizer.synchronize([entity(id: "artist", title: "Renamed")])

    #expect(writer.deleteAllCount == 1)
    #expect(writer.indexed.map { $0.map(\.id) } == [["album", "artist"], ["artist"]])
    #expect(writer.deleted == [["album"]])
    #expect(snapshots.saveCount == 2)

    let relaunchedWriter = RecordingSpotlightWriter()
    let relaunched = NightdriveSpotlightSynchronizer(
      writer: relaunchedWriter, snapshotStore: snapshots)
    await relaunched.synchronize([entity(id: "artist", title: "Renamed")])
    #expect(relaunchedWriter.deleteAllCount == 0)
    #expect(relaunchedWriter.indexed.isEmpty)
    #expect(relaunchedWriter.deleted.isEmpty)
  }

  @Test
  func spotlightSynchronizationSerializesOverlappingRunsAndRecomputesDeltas() async {
    let writer = BlockingSpotlightWriter()
    let snapshots = MemorySpotlightSnapshotStore()
    let synchronizer = NightdriveSpotlightSynchronizer(
      writer: writer, snapshotStore: snapshots)
    let artist = entity(id: "artist", title: "Artist")
    let album = entity(id: "album", title: "Album")

    let first = Task { await synchronizer.synchronize([artist]) }
    await writer.firstDeleteStarted.wait()
    let second = Task { await synchronizer.synchronize([album]) }

    #expect(await holds(for: .milliseconds(50)) { writer.deleteAllCount == 1 })
    await writer.releaseFirstDelete.signal()
    await first.value
    await second.value

    #expect(writer.deleteAllCount == 1)
    #expect(writer.indexed == [[artist], [album]])
    #expect(writer.deleted == [[artist.id]])
    #expect(snapshots.entities == [album.id: album])
    #expect(snapshots.saveCount == 2)
  }

  @Test
  func spotlightDeduplicatesEntitiesAndRetriesAfterSnapshotFailure() async {
    let writer = RecordingSpotlightWriter()
    let snapshots = FailingSpotlightSnapshotStore()
    let synchronizer = NightdriveSpotlightSynchronizer(
      writer: writer, snapshotStore: snapshots)
    let original = entity(id: "artist", title: "Original")

    await synchronizer.synchronize([original, entity(id: "artist", title: "Duplicate")])
    await synchronizer.synchronize([original])

    #expect(writer.deleteAllCount == 2)
    #expect(writer.indexed == [[original], [original]])
    #expect(snapshots.entities == [original.id: original])
  }

  private func entity(id: String, title: String) -> NightdriveCollectionEntity {
    NightdriveCollectionEntity(id: id, kind: .artist, title: title, subtitle: "1 song")
  }
}

@MainActor
private final class IntentRecorder {
  var actions: [String] = []
  let entities = [
    NightdriveCollectionEntity(id: "album", kind: .album, title: "Album", subtitle: "1 song"),
    NightdriveCollectionEntity(id: "artist", kind: .artist, title: "Artist", subtitle: "1 song"),
  ]

  var operations: NightdriveIntentOperations {
    NightdriveIntentOperations(
      togglePlayback: { [weak self] in self?.actions.append("toggle") },
      next: { [weak self] in self?.actions.append("next") },
      previous: { [weak self] in self?.actions.append("previous") },
      entities: { [weak self] in self?.entities ?? [] },
      playCollection: { [weak self] in self?.actions.append("play:\($0)") },
      openCollection: { [weak self] in self?.actions.append("open:\($0)") },
      openUpNext: { [weak self] in self?.actions.append("up-next") })
  }
}

@MainActor
private final class RecordingSpotlightWriter: NightdriveSpotlightWriting {
  var deleteAllCount = 0
  var indexed: [[NightdriveCollectionEntity]] = []
  var deleted: [[String]] = []

  func index(_ entities: [NightdriveCollectionEntity]) async throws {
    indexed.append(entities)
  }

  func delete(identifiers: [String]) async throws {
    deleted.append(identifiers)
  }

  func deleteAll() async throws {
    deleteAllCount += 1
  }
}

@MainActor
private final class BlockingSpotlightWriter: NightdriveSpotlightWriting {
  let firstDeleteStarted = TestGate()
  let releaseFirstDelete = TestGate()
  var deleteAllCount = 0
  var indexed: [[NightdriveCollectionEntity]] = []
  var deleted: [[String]] = []

  func index(_ entities: [NightdriveCollectionEntity]) async throws {
    indexed.append(entities)
  }

  func delete(identifiers: [String]) async throws {
    deleted.append(identifiers)
  }

  func deleteAll() async throws {
    deleteAllCount += 1
    guard deleteAllCount == 1 else { return }
    await firstDeleteStarted.signal()
    await releaseFirstDelete.wait()
  }
}

@MainActor
private final class MemorySpotlightSnapshotStore: NightdriveSpotlightSnapshotStoring {
  var entities: [String: NightdriveCollectionEntity]?
  var saveCount = 0

  func load() -> [String: NightdriveCollectionEntity]? { entities }
  func save(_ entities: [String: NightdriveCollectionEntity]) throws {
    self.entities = entities
    saveCount += 1
  }
}

@MainActor
private final class FailingSpotlightSnapshotStore: NightdriveSpotlightSnapshotStoring {
  var entities: [String: NightdriveCollectionEntity]?
  private var shouldFail = true

  func load() -> [String: NightdriveCollectionEntity]? { entities }

  func save(_ entities: [String: NightdriveCollectionEntity]) throws {
    if shouldFail {
      shouldFail = false
      throw CocoaError(.fileWriteUnknown)
    }
    self.entities = entities
  }
}
