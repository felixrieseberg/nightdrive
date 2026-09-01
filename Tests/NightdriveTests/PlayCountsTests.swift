import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct PlayCountsFileTests {
  private func file(
    magic: String = "mhdp", headerLength: UInt32 = 16, entryLength: UInt32 = 28,
    entryCount: UInt32? = nil, entries: [[UInt32]] = [], trailingTruncation: Int = 0
  ) -> Data {
    var data = Data(magic.utf8)
    for value in [headerLength, entryLength, UInt32(entryCount ?? UInt32(entries.count))] {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    if headerLength > 16 {
      data.append(Data(count: Int(headerLength) - 16))
    }
    for fields in entries {
      var entry = Data()
      for field in fields {
        withUnsafeBytes(of: field.littleEndian) { entry.append(contentsOf: $0) }
      }
      entry.append(Data(count: max(0, Int(entryLength) - entry.count)))
      data.append(entry.prefix(Int(entryLength)))
    }
    if trailingTruncation > 0 { data.removeLast(trailingTruncation) }
    return data
  }

  private func macTime(unix: Int, shift: Int) -> UInt32 {
    UInt32(unix + Int(ITunesDBWriter.macEpochOffset) + shift)
  }

  @Test
  func testParsesFullTwentyEightByteEntries() throws {
    let shift = 3600
    let played = macTime(unix: 1_100_000_000, shift: shift)
    let skipped = macTime(unix: 1_100_000_500, shift: shift)
    let data = file(entries: [
      [3, played, 1234, 80, 0, 2, skipped],
      [0, 0, 0, 0, 0, 0, 0],
    ])
    let entries = try #require(PlayCountsFile.parse(data, timezoneShift: shift))
    #expect((entries.count) == (2))
    #expect((entries[0].playCount) == (3))
    #expect((entries[0].lastPlayed) == (Date(timeIntervalSince1970: 1_100_000_000)))
    #expect((entries[0].bookmarkMS) == (1234))
    #expect((entries[0].rating) == (80))
    #expect((entries[0].skipCount) == (2))
    #expect((entries[0].lastSkipped) == (Date(timeIntervalSince1970: 1_100_000_500)))
    #expect((entries[1].playCount) == (0))
    #expect(entries[1].lastPlayed == nil)
    #expect(entries[1].lastSkipped == nil)
  }

  @Test
  func testShorterEntryLengthsOnlyCarryCoveredFields() throws {
    let shift = 0
    let played = macTime(unix: 1_000_000_000, shift: shift)
    let twelve = try #require(
      PlayCountsFile.parse(
        file(entryLength: 12, entries: [[5, played, 42]]), timezoneShift: shift))
    #expect((twelve[0].playCount) == (5))
    #expect((twelve[0].lastPlayed) == (Date(timeIntervalSince1970: 1_000_000_000)))
    #expect((twelve[0].bookmarkMS) == (42))
    #expect(twelve[0].rating == nil)
    #expect((twelve[0].skipCount) == (0))

    let sixteen = try #require(
      PlayCountsFile.parse(
        file(entryLength: 16, entries: [[1, played, 0, 100]]), timezoneShift: shift))
    #expect((sixteen[0].rating) == (100))
    #expect((sixteen[0].skipCount) == (0))
    #expect(sixteen[0].lastSkipped == nil)
  }

  @Test
  func testLargerHeaderIsSkipped() throws {
    let data = file(headerLength: 96, entries: [[7, 0, 0, 0, 0, 0, 0]])
    let entries = try #require(PlayCountsFile.parse(data, timezoneShift: 0))
    #expect((entries.count) == (1))
    #expect((entries[0].playCount) == (7))
  }

  @Test
  func testEmptyFileParsesAsNoEntries() {
    #expect((PlayCountsFile.parse(file(entries: []), timezoneShift: 0)) == ([]))
  }

  @Test
  func testMalformedFilesYieldNilInsteadOfThrowing() {
    #expect(PlayCountsFile.parse(file(magic: "mhit"), timezoneShift: 0) == nil)
    #expect(PlayCountsFile.parse(Data("mhdp".utf8), timezoneShift: 0) == nil)
    #expect(PlayCountsFile.parse(file(headerLength: 4096, entries: []).prefix(16), timezoneShift: 0) == nil)
    #expect(
      PlayCountsFile.parse(
        file(entryCount: 50, entries: [[1, 0, 0, 0, 0, 0, 0]]), timezoneShift: 0) == nil)
    #expect(
      PlayCountsFile.parse(
        file(entries: [[1, 0, 0, 0, 0, 0, 0]], trailingTruncation: 4), timezoneShift: 0) == nil)
    #expect(PlayCountsFile.parse(file(entryLength: 0, entryCount: 3), timezoneShift: 0) == nil)
  }

  @Test
  func testTimezoneShiftIsRemovedFromTimestamps() throws {
    let unix = 1_200_000_000
    for shift in [-28800, 0, 3600, 46800] {
      let data = file(entries: [[1, macTime(unix: unix, shift: shift), 0, 0, 0, 0, 0]])
      let entries = try #require(PlayCountsFile.parse(data, timezoneShift: shift))
      #expect(
        (entries[0].lastPlayed) == (Date(timeIntervalSince1970: TimeInterval(unix))),
        Comment(rawValue: "shift \(shift)"))
    }
  }

  @Test
  func testStarRatingConversion() {
    #expect(PlayCountsFile.starRating(fromDeviceRating: 0) == nil)
    #expect((PlayCountsFile.starRating(fromDeviceRating: 20)) == (1))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 40)) == (2))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 60)) == (3))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 80)) == (4))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 100)) == (5))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 7)) == (1))
    #expect((PlayCountsFile.starRating(fromDeviceRating: 240)) == (5))
  }
}

@MainActor
struct DevicePlaybackMergeTests {
  private final class InMemoryPersistence: AppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    var data: Data? {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
  }

  private func track(_ name: String) -> URL {
    URL(fileURLWithPath: "/library/\(name).mp3")
  }

  private func trackID(_ name: String) -> TrackID {
    TrackID(url: track(name))
  }

  @Test
  func testMergeAddsDeltasHistoryAndRating() throws {
    let store = ListeningHistoryStore(persistence: InMemoryPersistence())
    let url = track("a")
    try store.recordPlay(of: TrackID(url: url), at: Date(timeIntervalSince1970: 100))
    let played = Date(timeIntervalSince1970: 500)
    let report = DevicePlaybackReport(entries: [
      .init(dbid: 1, localURL: url, playCountDelta: 3, lastPlayed: played, deviceRating: 4)
    ])
    #expect((try store.merge(report)) == (3))
    #expect((store.playCount(for: TrackID(url: url))) == (4))
    #expect((store.lastPlayedAt(for: TrackID(url: url))) == (played))
    #expect((store.rating(for: TrackID(url: url))) == (4))
    let deviceEntries = store.history.filter { $0.source == .device }
    #expect((deviceEntries.count) == (3))
    #expect(deviceEntries.allSatisfy { $0.playedAt == played })
    #expect((store.history.filter { $0.source == .local }.count) == (1))
  }

  @Test
  func testMergeAppliesEachReportExactlyOnce() throws {
    let store = ListeningHistoryStore(persistence: InMemoryPersistence())
    let url = track("a")
    let skipped = Date(timeIntervalSince1970: 400)
    let report = DevicePlaybackReport(entries: [
      .init(
        dbid: 1, localURL: url, playCountDelta: 2, skipCountDelta: 3,
        lastPlayed: Date(), bookmarkMS: 2_345, lastSkipped: skipped)
    ])
    #expect((try store.merge(report)) == (2))
    #expect((try store.merge(report)) == (0), Comment(rawValue: "replaying the same report id must be a no-op"))
    #expect((store.playCount(for: TrackID(url: url))) == (2))
    #expect((store.metadata(for: TrackID(url: url)).skipCount) == (3))
    #expect((store.metadata(for: TrackID(url: url)).bookmarkMS) == (2_345))
    #expect((store.metadata(for: TrackID(url: url)).lastSkippedAt) == (skipped))
    #expect((store.history.count) == (2))
  }

  @Test
  func testMergeSurvivesReload() async throws {
    let persistence = InMemoryPersistence()
    let url = track("a")
    let report = DevicePlaybackReport(entries: [
      .init(dbid: 1, localURL: url, playCountDelta: 1, lastPlayed: Date())
    ])
    let original = ListeningHistoryStore(persistence: persistence)
    try original.merge(report)
    try await original.flushPersistence()
    let reloaded = ListeningHistoryStore(persistence: persistence)
    #expect((reloaded.playCount(for: TrackID(url: url))) == (1))
    #expect((try reloaded.merge(report)) == (0), Comment(rawValue: "dedup ids must persist across reloads"))
  }

  @Test
  func testMergeSaturatesSkipsReplacesBookmarkAndKeepsNewestSkipDate() throws {
    let store = ListeningHistoryStore(persistence: InMemoryPersistence())
    let url = track("a")
    let newer = Date(timeIntervalSince1970: 500)
    #expect(
      (try store.merge(
        DevicePlaybackReport(entries: [
          .init(
            dbid: 1, localURL: url, skipCountDelta: Int.max - 1,
            bookmarkMS: 4_000, lastSkipped: newer)
        ]))) == (0))
    let second = DevicePlaybackReport(entries: [
      .init(
        dbid: 1, localURL: url, skipCountDelta: 10,
        bookmarkMS: 0, lastSkipped: Date(timeIntervalSince1970: 100))
    ])
    #expect((try store.merge(second)) == (0))
    #expect((try store.merge(second)) == (0), Comment(rawValue: "replayed metadata must not apply twice"))

    let metadata = store.metadata(for: trackID("a"))
    #expect((metadata.skipCount) == (Int.max))
    #expect((metadata.bookmarkMS) == (0))
    #expect((metadata.lastSkippedAt) == (newer))
  }

  @Test
  func testMergeSkipsUnlinkedTracksAndKeepsNewerLocalDate() throws {
    let store = ListeningHistoryStore(persistence: InMemoryPersistence())
    let url = track("a")
    let newer = Date(timeIntervalSince1970: 900)
    try store.recordPlay(of: TrackID(url: url), at: newer)
    let report = DevicePlaybackReport(entries: [
      .init(dbid: 1, localURL: nil, playCountDelta: 5, lastPlayed: Date()),
      .init(dbid: 2, localURL: url, playCountDelta: 1, lastPlayed: Date(timeIntervalSince1970: 10)),
    ])
    #expect((try store.merge(report)) == (1))
    #expect(
      (store.lastPlayedAt(for: TrackID(url: url))) == (newer), Comment(rawValue: "older device play must not regress"))
    #expect((store.playCount(for: TrackID(url: url))) == (2))
  }

}

@Suite(.tags(.fakeIpod))
struct PlayCountsSyncTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  private func makeLinkedPair() throws -> LibraryTrack {
    let dest = try fs.destinationForNewFile(extension: "mp3")
    let deviceData = MP3Builder.build(
      tags: .init(
        title: "Device Song", artist: "Ipod Artist", album: "Device Album",
        genre: "Pop", trackNumber: 2, year: 2003),
      seconds: 2)
    try deviceData.write(to: dest)
    var deviceTrack = ITDBTrack()
    deviceTrack.title = "Device Song"
    deviceTrack.artist = "Ipod Artist"
    deviceTrack.album = "Device Album"
    deviceTrack.ipodPath = fs.ipodPath(for: dest)
    deviceTrack.sizeBytes = UInt32(deviceData.count)
    deviceTrack.lengthMS = 2000
    deviceTrack.trackNumber = 2
    var db = ITunesDatabase()
    db.tracks = [deviceTrack]
    try fs.writeDatabase(db)

    let localData = MP3Builder.build(
      tags: .init(
        title: "Device Song", artist: "Ipod Artist", album: "Device Album",
        genre: "Pop", trackNumber: 2, year: 2003),
      seconds: 2)
    let url = libraryDir.appendingPathComponent("Ipod Artist - Device Song.mp3")
    try localData.write(to: url)
    return LibraryTrack(
      url: url, title: "Device Song", artist: "Ipod Artist", album: "Device Album", genre: "Pop", trackNumber: 2,
      year: 2003, durationMS: 2000, sizeBytes: localData.count, bitrate: 128, samplerate: 44100,
      modificationDate: Date())
  }

  private func writePlayCounts(entries: [[UInt32]]) throws {
    var data = Data("mhdp".utf8)
    for value in [UInt32(16), UInt32(28), UInt32(entries.count)] {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    for fields in entries {
      var padded = fields
      while padded.count < 7 { padded.append(0) }
      for field in padded.prefix(7) {
        withUnsafeBytes(of: field.littleEndian) { data.append(contentsOf: $0) }
      }
    }
    try data.write(to: PlayCountsFile.url(in: fs))
  }

  private func makeSnapshotPlan(library: [LibraryTrack], ratings: [String: Int] = [:]) throws
    -> SyncPlan
  {
    let db = try fs.readDatabase()
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir),
      library: library, device: db.tracks, libraryFolder: libraryDir)
    var plan = SyncEngine.makePlan(library: library, device: db.tracks, links: links)
    plan.localRatings = ratings
    return plan
  }

  @Test
  func testCorruptPendingReportFailsClosedWithoutDoubleCounting() async throws {
    let local = try makeLinkedPair()
    try writePlayCounts(entries: [[3]])
    let pendingURL = PendingPlaybackReportStore.url(for: libraryDir)
    let playCountsURL = PlayCountsFile.url(in: fs)

    let first = try await runSync(try makeSnapshotPlan(library: [local]))
    let firstReport = try #require(first.playbackReport)
    #expect((try ListeningHistoryFile.merge(firstReport, libraryFolder: libraryDir)) == (3))
    #expect((try fs.readDatabase().tracks.first?.playCount) == (3))

    let corrupt = Data("not json".utf8)
    try corrupt.write(to: pendingURL)
    #expect(throws: (any Error).self) { try PendingPlaybackReportStore.load(libraryFolder: libraryDir) }

    do {
      _ = try await runSync(try makeSnapshotPlan(library: [local]))
      Issue.record("A malformed pending report must stop playback processing")
    } catch {
      #expect(error is SidecarIntegrityError)
    }

    #expect((try fs.readDatabase().tracks.first?.playCount) == (3))
    let blockedHistory = try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
    #expect((blockedHistory.metadataByID[local.id.rawValue]?.playCount) == (3))
    #expect((blockedHistory.appliedDeviceReportIDs) == ([firstReport.id]))
    #expect((try Data(contentsOf: pendingURL)) == (corrupt))
    #expect(FileManager.default.fileExists(atPath: playCountsURL.path))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: first.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: first.databaseID)
    #expect((try Data(contentsOf: pendingURL)) == (corrupt))
    #expect(FileManager.default.fileExists(atPath: playCountsURL.path))

    try PendingPlaybackReportStore.save(firstReport, libraryFolder: libraryDir)
    let recovered = try await runSync(try makeSnapshotPlan(library: [local]))
    let replay = try #require(recovered.playbackReport)
    #expect((replay.id) == (firstReport.id))
    #expect((try fs.readDatabase().tracks.first?.playCount) == (3))
    #expect((try ListeningHistoryFile.merge(replay, libraryFolder: libraryDir)) == (0))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: recovered.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: recovered.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: pendingURL.path)))
    #expect(!(FileManager.default.fileExists(atPath: playCountsURL.path)))
  }

  @Test
  func testPlayCountsAreStagedFoldedAndConsumedOnlyAfterFinalize() async throws {
    let local = try makeLinkedPair()
    var db = try fs.readDatabase()
    db.tracks[0].skipCount = UInt32.max - 1
    try fs.writeDatabase(db)
    let macPlayed = UInt32(
      1_300_000_000 + Int(ITunesDBWriter.macEpochOffset) + db.timezoneShift)
    let macSkipped = UInt32(
      1_300_000_500 + Int(ITunesDBWriter.macEpochOffset) + db.timezoneShift)
    try writePlayCounts(entries: [[2, macPlayed, 4_321, 80, 0, 3, macSkipped]])

    let result = try await runSync(try makeSnapshotPlan(library: [local]))
    #expect((result.failures) == ([]))

    let report = try #require(result.playbackReport)
    #expect((report.entries.count) == (1))
    #expect((report.entries[0].playCountDelta) == (2))
    #expect((report.entries[0].skipCountDelta) == (3))
    #expect((report.entries[0].bookmarkMS) == (4_321))
    #expect((report.entries[0].lastSkipped) == (Date(timeIntervalSince1970: 1_300_000_500)))
    #expect((report.entries[0].deviceRating) == (4))
    #expect((report.entries[0].lastPlayed) == (Date(timeIntervalSince1970: 1_300_000_000)))
    #expect((report.entries[0].localURL.map { TrackID(url: $0) }) == (TrackID(url: local.url)))

    #expect((try PendingPlaybackReportStore.load(libraryFolder: libraryDir)?.id) == (report.id))
    #expect(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path))
    #expect((result.playCountsFilesToDelete) == ([PlayCountsFile.url(in: fs)]))

    db = try fs.readDatabase()
    #expect((db.tracks[0].playCount) == (2))
    #expect((db.tracks[0].skipCount) == (UInt32.max))
    #expect((db.tracks[0].bookmarkMS) == (4_321))
    #expect((db.tracks[0].lastSkipped) == (Date(timeIntervalSince1970: 1_300_000_500)))
    #expect((db.tracks[0].rating) == (80))
    #expect((db.tracks[0].timePlayed) == (Date(timeIntervalSince1970: 1_300_000_000)))
    let ledger = SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
    #expect((ledger.first?.lastSyncedRating) == (4))

    #expect((try ListeningHistoryFile.merge(report, libraryFolder: libraryDir)) == (2))
    let metadata = try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
      .metadataByID[local.id.rawValue]
    #expect((metadata?.skipCount) == (3))
    #expect((metadata?.bookmarkMS) == (4_321))
    #expect((metadata?.lastSkippedAt) == (Date(timeIntervalSince1970: 1_300_000_500)))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: result.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: result.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path)))
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) == nil)
    let finalizedTrack = try #require(fs.readDatabase().tracks.first)
    #expect((finalizedTrack.skipCount) == (UInt32.max))
    #expect((finalizedTrack.bookmarkMS) == (4_321))
    #expect((finalizedTrack.lastSkipped) == (Date(timeIntervalSince1970: 1_300_000_500)))
  }

  @Test
  func testBookmarkOnlyEntryProducesDurableReport() async throws {
    let local = try makeLinkedPair()
    try writePlayCounts(entries: [[0, 0, 7_654, 0, 0, 0, 0]])

    let result = try await runSync(try makeSnapshotPlan(library: [local]))
    let report = try #require(result.playbackReport)
    #expect((report.entries.count) == (1))
    #expect((report.entries[0].playCountDelta) == (0))
    #expect((report.entries[0].skipCountDelta) == (0))
    #expect((report.entries[0].bookmarkMS) == (7_654))
    #expect((try fs.readDatabase().tracks[0].bookmarkMS) == (7_654))

    #expect((try ListeningHistoryFile.merge(report, libraryFolder: libraryDir)) == (0))
    #expect(
      (try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
        .metadataByID[local.id.rawValue]?.bookmarkMS) == (7_654))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: result.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: result.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path)))
    #expect((try fs.readDatabase().tracks[0].bookmarkMS) == (7_654))
  }

  @Test
  func testLastSkippedOnlyEntryProducesDurableReport() async throws {
    let local = try makeLinkedPair()
    let db = try fs.readDatabase()
    let skipped = Date(timeIntervalSince1970: 1_300_000_500)
    let macSkipped = UInt32(
      Int(skipped.timeIntervalSince1970) + Int(ITunesDBWriter.macEpochOffset)
        + db.timezoneShift)
    try writePlayCounts(entries: [[0, 0, 0, 0, 0, 0, macSkipped]])

    let result = try await runSync(try makeSnapshotPlan(library: [local]))
    let report = try #require(result.playbackReport)
    #expect((report.entries.count) == (1))
    #expect((report.entries[0].playCountDelta) == (0))
    #expect((report.entries[0].skipCountDelta) == (0))
    #expect((report.entries[0].lastSkipped) == (skipped))
    #expect((try fs.readDatabase().tracks[0].lastSkipped) == (skipped))

    #expect((try ListeningHistoryFile.merge(report, libraryFolder: libraryDir)) == (0))
    #expect(
      (try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
        .metadataByID[local.id.rawValue]?.lastSkippedAt) == (skipped))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: result.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: result.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path)))
    #expect((try fs.readDatabase().tracks[0].lastSkipped) == (skipped))
  }

  @Test
  func testCrashBetweenDatabaseWriteAndMergeReplaysExactlyOnce() async throws {
    let local = try makeLinkedPair()
    try writePlayCounts(entries: [[3, 0, 0, 0, 0, 0, 0]])

    let first = try await runSync(try makeSnapshotPlan(library: [local]))
    let firstReport = try #require(first.playbackReport)
    #expect((try fs.readDatabase().tracks[0].playCount) == (3))

    let second = try await runSync(try makeSnapshotPlan(library: [local]))
    let replayed = try #require(second.playbackReport)
    #expect((replayed.id) == (firstReport.id))
    #expect((try fs.readDatabase().tracks[0].playCount) == (3), Comment(rawValue: "deltas must not fold twice"))
    #expect((second.playCountsFilesToDelete) == ([PlayCountsFile.url(in: fs)]))

    #expect((try ListeningHistoryFile.merge(replayed, libraryFolder: libraryDir)) == (3))
    #expect((try ListeningHistoryFile.merge(replayed, libraryFolder: libraryDir)) == (0))
    let payload = try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
    #expect((payload.metadataByID[local.id.rawValue]?.playCount) == (3))

    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: second.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: second.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path)))
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) == nil)

    let third = try await runSync(try makeSnapshotPlan(library: [local]))
    #expect(third.playbackReport == nil)
    #expect((third.playCountsFilesToDelete) == ([]))
  }

  @Test
  func testPendingReportFromOneDeviceSurvivesSyncsOfAnother() async throws {
    let local = try makeLinkedPair()
    try writePlayCounts(entries: [[3, 0, 0, 0, 0, 0, 0]])

    let crashed = try await runSync(try makeSnapshotPlan(library: [local]))
    let report = try #require(crashed.playbackReport)
    #expect((try fs.readDatabase().tracks[0].playCount) == (3))

    let otherPod = scratch.appendingPathComponent("OTHERPOD", isDirectory: true)
    let otherFS = try makeFakeIpodVolume(at: otherPod)
    try otherFS.writeDatabase(ITunesDatabase())
    #expect((try otherFS.readDatabase().databaseID) != (try fs.readDatabase().databaseID))

    let viaB = try await SyncEngine.execute(
      plan: SyncEngine.makePlan(library: [], device: []),
      deviceVolume: otherPod, libraryFolder: libraryDir
    ) { _ in }
    let reportViaB = try #require(viaB.playbackReport)
    #expect((reportViaB.id) == (report.id))
    #expect((viaB.playCountsFilesToDelete) == ([]))
    #expect((try ListeningHistoryFile.merge(reportViaB, libraryFolder: libraryDir)) == (3))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: viaB.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: otherPod, databaseID: viaB.databaseID)
    #expect(
      try PendingPlaybackReportStore.load(libraryFolder: libraryDir) != nil,
      Comment(rawValue: "another device's sync must not clear a pending report it does not own"))
    #expect(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path))

    let viaBAgain = try await SyncEngine.execute(
      plan: SyncEngine.makePlan(library: [], device: []),
      deviceVolume: otherPod, libraryFolder: libraryDir
    ) { _ in }
    let replayViaB = try #require(viaBAgain.playbackReport)
    #expect((try ListeningHistoryFile.merge(replayViaB, libraryFolder: libraryDir)) == (0))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: viaBAgain.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: otherPod, databaseID: viaBAgain.databaseID)
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) != nil)

    let viaA = try await runSync(try makeSnapshotPlan(library: [local]))
    let replayViaA = try #require(viaA.playbackReport)
    #expect((replayViaA.id) == (report.id))
    #expect((try fs.readDatabase().tracks[0].playCount) == (3), Comment(rawValue: "deltas must not fold twice"))
    #expect((try ListeningHistoryFile.merge(replayViaA, libraryFolder: libraryDir)) == (0))
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: viaA.playCountsFilesToDelete,
      libraryFolder: libraryDir, deviceVolume: ipodDir, databaseID: viaA.databaseID)
    #expect(!(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path)))
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) == nil)

    let payload = try ListeningHistoryFile.loadPayload(libraryFolder: libraryDir)
    #expect((payload.metadataByID[local.id.rawValue]?.playCount) == (3))
    #expect((payload.history.filter { $0.source == .device }.count) == (3))
  }

  @Test
  func testLocalRatingIsPushedToDevice() async throws {
    let local = try makeLinkedPair()
    let ratings = [local.id.rawValue: 5]

    let result = try await runSync(try makeSnapshotPlan(library: [local], ratings: ratings))
    #expect((result.failures) == ([]))
    #expect(result.playbackReport == nil, Comment(rawValue: "a push produces no local-side report"))

    let db = try fs.readDatabase()
    #expect((db.tracks[0].rating) == (100))
    #expect(
      (SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
        .first?.lastSyncedRating) == (5))
  }

  @Test
  func testDeviceRatingWinsWhenItMovedOffTheSyncedBase() async throws {
    let local = try makeLinkedPair()
    _ = try await runSync(
      try makeSnapshotPlan(
        library: [local], ratings: [local.id.rawValue: 5]))

    try writePlayCounts(entries: [[0, 0, 0, 40, 0, 0, 0]])
    let result = try await runSync(
      try makeSnapshotPlan(
        library: [local], ratings: [local.id.rawValue: 5]))
    let report = try #require(result.playbackReport)
    #expect((report.entries.count) == (1))
    #expect((report.entries[0].deviceRating) == (2))
    #expect((report.entries[0].playCountDelta) == (0))

    let db = try fs.readDatabase()
    #expect((db.tracks[0].rating) == (40), Comment(rawValue: "device rating must survive the file's deletion"))
    #expect(
      (SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
        .first?.lastSyncedRating) == (2))

    #expect((try ListeningHistoryFile.merge(report, libraryFolder: libraryDir)) == (0))
    #expect((try ListeningHistoryFile.loadRatings(libraryFolder: libraryDir)[local.id.rawValue]) == (2))
  }

  @Test
  func testMalformedPlayCountsFileIsLeftInPlaceWithANote() async throws {
    let local = try makeLinkedPair()
    try Data("mhdpgarbage".utf8).write(to: PlayCountsFile.url(in: fs))

    let result = try await runSync(try makeSnapshotPlan(library: [local]))
    #expect(result.playbackReport == nil)
    #expect((result.playCountsFilesToDelete) == ([]))
    #expect((result.playbackNotes.count) == (1))
    #expect(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path))
  }

  @Test
  func testEntryCountBeyondDatabaseIsIgnored() async throws {
    let local = try makeLinkedPair()
    try writePlayCounts(entries: [[1], [1], [1]])

    let result = try await runSync(try makeSnapshotPlan(library: [local]))
    #expect(result.playbackReport == nil)
    #expect((result.playCountsFilesToDelete) == ([]))
    #expect((result.playbackNotes.count) == (1))
    #expect(FileManager.default.fileExists(atPath: PlayCountsFile.url(in: fs).path))
  }
}
