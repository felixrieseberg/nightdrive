import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct SyncLedgerTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  @discardableResult
  private func sync() async throws -> SyncResult {
    try await runSync(try await makePlan())
  }

  private func ledgerEntries() throws -> [SyncLedgerEntry] {
    let db = try fs.readDatabase()
    return SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
  }

  @Test
  func testSyncRecordsLinksForCopiedAndMatchedTracks() async throws {
    var initialDB = ITunesDatabase()
    let deviceOnly = try putTrackOnIpod(title: "Device Song", artist: "Ipod Artist", trackNumber: 2)
    var shared = try putTrackOnIpod(title: "Shared Song", artist: "Both Artist", trackNumber: 2)
    shared.album = "Album"
    shared.trackNumber = 1
    initialDB.tracks = [deviceOnly, shared]
    try fs.writeDatabase(initialDB)
    try writeLibraryMP3(
      filename: "shared.mp3", title: "Shared Song", artist: "Both Artist")
    try writeLibraryMP3(filename: "local.mp3", title: "Local Song", artist: "Local Artist")

    let result = try await sync()
    #expect((result.copiedToDevice) == (1))
    #expect((result.copiedToFolder) == (1))
    #expect((result.failures) == ([]))

    let entries = try ledgerEntries()
    #expect((entries.count) == (3))
    let db = try fs.readDatabase()
    #expect((Set(entries.map(\.dbid))) == (Set(db.tracks.map(\.dbid))))
    for entry in entries {
      let url = libraryDir.appendingPathComponent(entry.relativePath)
      #expect(FileManager.default.fileExists(atPath: url.path), Comment(rawValue: entry.relativePath))
      #expect((try SyncSignature.fileSHA256(url: url)) == (entry.contentSHA256))
    }

    let mtime = try databaseModificationDate()
    let plan = try await makePlan()
    #expect(plan.isEmpty)
    let second = try await sync()
    #expect((second.copiedToDevice + second.copiedToFolder) == (0))
    #expect((try databaseModificationDate()) == (mtime))
  }

  @Test
  func testLocalTagEditUpdatesDeviceInPlace() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(filename: "song.mp3", title: "Original", artist: "Artist")
    try await sync()

    var db = try fs.readDatabase()
    #expect((db.tracks.count) == (1))
    let dbid = db.tracks[0].dbid
    db.tracks[0].playCount = 5
    db.tracks[0].rating = 80
    try fs.writeDatabase(db)
    try await sync()

    var metadata = TrackMetadata(await MetadataLoader.load(url: url))
    metadata.title = "Renamed"
    try MP3MetadataWriter.write(metadata, artworkChange: .unchanged, to: url)

    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))
    #expect(plan.copyToDevice.isEmpty)
    #expect(plan.copyToFolder.isEmpty)

    let result = try await sync()
    #expect((result.updatedOnDevice) == (1))
    #expect((result.copiedToDevice) == (0))
    #expect((result.copiedToFolder) == (0))
    #expect((result.failures) == ([]))

    let after = try fs.readDatabase()
    #expect((after.tracks.count) == (1))
    #expect((after.tracks[0].dbid) == (dbid))
    #expect((after.tracks[0].title) == ("Renamed"))
    #expect((after.tracks[0].playCount) == (5))
    #expect((after.tracks[0].rating) == (80))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).count) == (1))

    let followUp = try await makePlan()
    #expect(followUp.isEmpty)
  }

  @Test
  func testLocalAudioReplacementReplacesDeviceFile() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 2)
    try await sync()
    let before = try fs.readDatabase()
    let oldPath = try #require(before.tracks[0].ipodPath)
    let oldURL = try fs.validatedMusicFileURL(forIpodPath: oldPath)

    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 5)

    let result = try await sync()
    #expect((result.updatedOnDevice) == (1))
    #expect((result.failures) == ([]))

    let after = try fs.readDatabase()
    #expect((after.tracks.count) == (1))
    #expect((after.tracks[0].dbid) == (before.tracks[0].dbid))
    let newPath = try #require(after.tracks[0].ipodPath)
    #expect((newPath) != (oldPath))
    let newURL = try fs.validatedMusicFileURL(forIpodPath: newPath)
    #expect(
      (try Data(contentsOf: newURL)) == (try Data(contentsOf: url)),
      Comment(rawValue: "device file must carry the replacement audio"))
    #expect(
      !(FileManager.default.fileExists(atPath: oldURL.path)),
      Comment(rawValue: "superseded device file must be removed"))
  }

  @Test
  func testSameStatInPlaceRewriteUpdatesDeviceAudioAndMetadata() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(
      filename: "same-stat.mp3", title: "Initial", artist: "Artist", seconds: 2)
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: url.path)
    try await sync()

    let beforeStamp = try #require(FileGenerationStamp(url: url))
    let beforeEntry = try #require(try ledgerEntries().first)
    #expect((beforeEntry.fileGenerationStamp) == (beforeStamp))

    var replacement = MP3Builder.build(
      tags: .init(
        title: "Updated", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2)
    replacement[replacement.index(before: replacement.endIndex)] = 1
    try replacement.write(to: url)

    let afterStamp = try pinnedGenerationStamp(
      at: url, distinctFrom: beforeStamp, modificationDate: pinnedDate)
    #expect((afterStamp.inode) == (beforeStamp.inode))
    #expect((afterStamp.sizeBytes) == (beforeStamp.sizeBytes))
    #expect((afterStamp.modificationSeconds) == (beforeStamp.modificationSeconds))
    #expect((afterStamp.modificationNanoseconds) == (beforeStamp.modificationNanoseconds))
    #expect((afterStamp) != (beforeStamp))

    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))
    #expect((plan.updateOnDevice.first?.local.title) == ("Updated"))
    let result = try await sync()
    #expect((result.updatedOnDevice) == (1))
    #expect((result.failures) == ([]))

    let row = try #require(fs.readDatabase().tracks.first)
    #expect((row.title) == ("Updated"))
    let deviceURL = try fs.validatedMusicFileURL(forIpodPath: try #require(row.ipodPath))
    #expect((try Data(contentsOf: deviceURL)) == (replacement))
    #expect((try #require(try ledgerEntries().first).fileGenerationStamp) == (afterStamp))
    let followUp = try await makePlan()
    #expect(followUp.isEmpty)
  }

  @Test
  func testLocalAudioReplacementPreservesClassicPlaybackState() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 2)
    try await sync()

    var db = try fs.readDatabase()
    let lastSkipped = Date(timeIntervalSince1970: 1_300_000_000)
    db.tracks[0].bookmarkMS = 88_000
    db.tracks[0].skipCount = 91
    db.tracks[0].lastSkipped = lastSkipped
    try fs.writeDatabase(db)

    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 5)
    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))

    let result = try await sync()
    #expect((result.updatedOnDevice) == (1))
    #expect((result.failures) == ([]))

    let replacement = try #require(fs.readDatabase().tracks.first)
    #expect((replacement.bookmarkMS) == (88_000))
    #expect((replacement.skipCount) == (91))
    #expect((replacement.lastSkipped) == (lastSkipped))
  }

  @Test
  func testDirectUpdatePublishesAndRecordsOneCapturedGeneration() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 2)
    try await sync()

    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 5)
    let generationB = try Data(contentsOf: url)
    let generationBHash = try SyncSignature.fileSHA256(url: url)
    let updatePlan = try await makePlan()
    #expect((updatePlan.updateOnDevice.count) == (1))

    let generationC = MP3Builder.build(
      tags: .init(
        title: "Same Title", artist: "Same Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 7)
    let mutation = OneShotFileMutation(url: url, replacement: generationC)
    let result = try await SyncEngine.execute(
      request: SyncExecutionRequest(updatePlan),
      deviceVolume: ipodDir, libraryFolder: libraryDir,
      progress: { progress in
        if progress.detail.hasPrefix("Updating on iPod:") { mutation.perform() }
      })

    #expect(mutation.failureDescription() == nil)
    #expect((result.failures) == ([]))
    #expect((result.updatedOnDevice) == (1))
    #expect((try Data(contentsOf: url)) == (generationC))

    let db = try fs.readDatabase()
    let row = try #require(db.tracks.first)
    let deviceURL = try fs.validatedMusicFileURL(forIpodPath: try #require(row.ipodPath))
    #expect(
      (try Data(contentsOf: deviceURL)) == (generationB),
      Comment(rawValue: "the payload must come from the same generation that was hashed"))
    let entry = try #require(try ledgerEntries().first)
    #expect((entry.contentSHA256) == (generationBHash))
    #expect((entry.fileSize) == (generationB.count))

    let retry = try await makePlan()
    #expect((retry.updateOnDevice.count) == (1), Comment(rawValue: "generation C must remain pending"))
  }

  @Test
  func testDeviceTagEditWritesBackToLibrary() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(filename: "song.mp3", title: "Original", artist: "Artist")
    try await sync()

    var db = try fs.readDatabase()
    db.tracks[0].title = "Edited On Device"
    try fs.writeDatabase(db)

    let plan = try await makePlan()
    #expect((plan.updateInFolder.count) == (1))
    #expect(plan.copyToFolder.isEmpty)

    let result = try await sync()
    #expect((result.updatedInFolder) == (1))
    #expect((result.copiedToFolder) == (0))
    #expect((result.failures) == ([]))

    let local = await MetadataLoader.load(url: url)
    #expect((local.title) == ("Edited On Device"))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).count) == (1))
    #expect((try fs.readDatabase().tracks.count) == (1))

    let followUp = try await makePlan()
    #expect(followUp.isEmpty)
  }

  @Test
  func testTouchedFileWithoutByteChangesLeavesDeviceAlone() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(filename: "song.mp3", title: "Song", artist: "Artist")
    try await sync()

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))

    let mtime = try databaseModificationDate()
    let result = try await sync()
    #expect((result.updatedOnDevice) == (0))
    #expect((result.failures) == ([]))
    #expect((try databaseModificationDate()) == (mtime))

    let followUp = try await makePlan()
    #expect(followUp.isEmpty)
  }

  @Test
  func testFailedDeviceUpdateRetainsLedgerLink() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 2)
    try await sync()
    let linkedEntries = try ledgerEntries()
    #expect((linkedEntries.count) == (1))

    try writeLibraryMP3(
      filename: "song.mp3", title: "Same Title", artist: "Same Artist", seconds: 5)
    let result = try await runSync(
      request: SyncExecutionRequest(try await makePlan()),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        destinationAllocator: { _, _, _ in throw CocoaError(.fileWriteNoPermission) }))
    #expect((result.updatedOnDevice) == (0))
    #expect((result.failures.count) == (1))
    #expect(
      (try ledgerEntries()) == (linkedEntries),
      Comment(rawValue: "a failed update must keep the stale link so the change is retried"))

    let retry = try await makePlan()
    #expect((retry.updateOnDevice.count) == (1))
    #expect(retry.copyToDevice.isEmpty)
    #expect(retry.copyToFolder.isEmpty)
  }

  @Test
  func testCorruptLedgerAbortsBeforeSyncAndIsLeftUnchanged() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = try writeLibraryMP3(filename: "song.mp3", title: "Original", artist: "Artist")
    try await sync()

    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: ledgerURL)
    var metadata = TrackMetadata(await MetadataLoader.load(url: url))
    metadata.title = "Renamed"
    try MP3MetadataWriter.write(metadata, artworkChange: .unchanged, to: url)

    do {
      _ = try await sync()
      Issue.record("A malformed ledger must abort the sync")
    } catch {
      #expect(error is SidecarIntegrityError, Comment(rawValue: "\(error)"))
    }
    #expect((try Data(contentsOf: ledgerURL)) == (corrupt))
    #expect((try fs.readDatabase().tracks.count) == (1))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).count) == (1))
  }

  @Test
  func testConfirmedEmptyLedgerPreservesCorruptFileBeforeRetry() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "song.mp3", title: "Original", artist: "Artist")
    try await sync()

    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: ledgerURL)
    let quarantine = try #require(
      try SyncLedgerStore.assumeEmptyAfterIntegrityWarning(libraryFolder: libraryDir))

    #expect(!(FileManager.default.fileExists(atPath: ledgerURL.path)))
    #expect((try Data(contentsOf: quarantine)) == (corrupt))
    #expect((try SyncLedgerStore.load(libraryFolder: libraryDir)) == (SyncLedger()))
  }

  @Test
  func testUnreadableLedgerThrowsAndCanBeExplicitlyPreserved() throws {
    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: false)

    #expect(throws: SidecarIntegrityError.self) {
      try SyncLedgerStore.load(libraryFolder: libraryDir)
    }
    let quarantine = try #require(
      try SyncLedgerStore.assumeEmptyAfterIntegrityWarning(libraryFolder: libraryDir))
    #expect(quarantine.lastPathComponent.hasSuffix(".corrupt"))
    #expect(FileManager.default.fileExists(atPath: quarantine.path))
    #expect((try SyncLedgerStore.load(libraryFolder: libraryDir)) == (SyncLedger()))
  }

  /// A ledger written before `needsMetadataReconstruction` and the other
  /// post-release entry fields existed must keep decoding with defaults
  /// instead of aborting every sync with an integrity error.
  @Test
  func testLedgerFromOlderReleaseWithoutNewerEntryFieldsStillLoads() throws {
    let legacy = """
      {"devices":{"d0abbf8f2b58bb22":[{
        "relativePath":"Artist - Song.mp3",
        "dbid":2499017073116394407,
        "fileSize":1000,
        "fileModifiedAt":1755400000.5,
        "fileGenerationStamp":{
          "deviceID":16777231,"inode":74935078,"sizeBytes":1000,
          "modificationSeconds":1755400000,"modificationNanoseconds":0,
          "changeSeconds":1786869261,"changeNanoseconds":909057749},
        "contentSHA256":"abc","deviceSignature":"def","lastSyncedRating":3}]},
       "playlists":{"d0abbf8f2b58bb22":[{
        "localID":"AA85E68C-4E22-4E5B-B285-3B29C9CF56C6",
        "persistentID":7,"name":"Mix","memberDbids":[2499017073116394407]}]},
       "settings":{"d0abbf8f2b58bb22":{
        "scope":{"everything":{}},"trackSyncMode":"libraryToIpod",
        "removesSongsNotInLibrary":false,"removesSongsOutsideSyncScope":false,
        "autoSyncOnConnect":false,"ejectAfterSync":false}}}
      """
    try Data(legacy.utf8).write(to: SyncLedgerStore.url(for: libraryDir))

    let ledger = try SyncLedgerStore.load(libraryFolder: libraryDir)
    let entry = try #require(ledger.devices["d0abbf8f2b58bb22"]?.first)
    #expect((entry.relativePath) == ("Artist - Song.mp3"))
    #expect(!(entry.needsMetadataReconstruction))
    #expect((entry.lastSyncedRating) == (3))
    #expect((entry.artworkSHA256) == (nil))
    #expect((entry.transcodeProfile) == (nil))
    #expect((ledger.playlists["d0abbf8f2b58bb22"]?.count) == (1))
    #expect(
      (ledger.settings["d0abbf8f2b58bb22"]?.trackSyncMode) == (TrackSyncMode.libraryToIpod))

    // A round trip through the current writer keeps the entry equivalent.
    try SyncLedgerStore.replaceEntries(
      ledger.devices["d0abbf8f2b58bb22"] ?? [], for: 0xd0ab_bf8f_2b58_bb22,
      libraryFolder: libraryDir)
    let rewritten = try SyncLedgerStore.load(libraryFolder: libraryDir)
    #expect((rewritten.devices["d0abbf8f2b58bb22"]?.first) == (entry))
  }

  private func databaseModificationDate() throws -> Date {
    try #require(
      FileManager.default.attributesOfItem(atPath: fs.databaseURL.path)[.modificationDate]
        as? Date)
  }
}

private final class OneShotFileMutation: Sendable {
  private struct State {
    var attempted = false
    var failure: String?
  }

  private let url: URL
  private let replacement: Data
  private let state = Mutex(State())

  init(url: URL, replacement: Data) {
    self.url = url
    self.replacement = replacement
  }

  func perform() {
    state.withLock { state in
      guard !state.attempted else { return }
      state.attempted = true
      do {
        try replacement.write(to: url, options: .atomic)
      } catch {
        state.failure = error.localizedDescription
      }
    }
  }

  func failureDescription() -> String? {
    state.withLock { $0.failure }
  }
}
