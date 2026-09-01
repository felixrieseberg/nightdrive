import Darwin
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
final class SyncRobustnessTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  private actor AcquisitionState {
    private(set) var acquired = false

    func markAcquired() { acquired = true }
  }

  private struct ExternalLockStartError: Error {}

  private func startExternalLock(at lockURL: URL) throws -> (Process, FileHandle) {
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = [
      "-c",
      """
      import fcntl, sys
      lock_file = open(sys.argv[1], "a+")
      fcntl.lockf(lock_file, fcntl.LOCK_EX)
      sys.stdout.write("ready\\n")
      sys.stdout.flush()
      sys.stdin.read(1)
      """,
      lockURL.path,
    ]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    let ready = try output.fileHandleForReading.read(upToCount: 6)
    guard ready == Data("ready\n".utf8) else {
      if process.isRunning { process.terminate() }
      process.waitUntilExit()
      throw ExternalLockStartError()
    }
    return (process, input.fileHandleForWriting)
  }

  deinit {
    let itunesDir = ipodDir.appendingPathComponent("iPod_Control/iTunes")
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: itunesDir.path)
  }

  @Test
  func testOutboundSnapshotAreaScavengesCrashOrphan() throws {
    let seed = try OutboundSnapshotArea.create(libraryFolder: libraryDir)
    let workspaceRoot = seed.directory.deletingLastPathComponent()
    let canonicalLibrary = libraryDir.resolvingSymlinksInPath().standardizedFileURL
    #expect(
      !(workspaceRoot.path.hasPrefix(canonicalLibrary.path + "/")),
      Comment(rawValue: "normal snapshot churn must stay outside the recursively watched library"))
    var libraryStatus = stat()
    var workspaceStatus = stat()
    #expect((Darwin.lstat(canonicalLibrary.path, &libraryStatus)) == (0))
    #expect((Darwin.lstat(workspaceRoot.path, &workspaceStatus)) == (0))
    #expect(
      (workspaceStatus.st_dev) == (libraryStatus.st_dev),
      Comment(rawValue: "the sibling workspace must remain clone-compatible with the library"))
    seed.remove()

    let orphan = workspaceRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
    try Data("orphaned snapshot bytes".utf8).write(
      to: orphan.appendingPathComponent("source.mp3"))
    try Data().write(to: orphan.appendingPathComponent("lock"))

    let area = try OutboundSnapshotArea.create(libraryFolder: libraryDir)
    #expect(
      !(FileManager.default.fileExists(atPath: orphan.path)),
      Comment(rawValue: "the next workspace must reclaim an unlocked hard-crash orphan"))

    try Data("not library input".utf8).write(
      to: area.directory.appendingPathComponent("watcher-noise.mp3"))
    #expect(
      !(LibraryStore.findAudioFiles(in: libraryDir).contains {
        $0.lastPathComponent == "watcher-noise.mp3"
      }))

    area.remove()
    #expect(!(FileManager.default.fileExists(atPath: area.directory.path)))
  }

  @Test
  func testOutboundSnapshotAreaPreservesAnotherLiveDirectWorkspace() throws {
    let first = try OutboundSnapshotArea.create(libraryFolder: libraryDir)
    defer { first.remove() }
    let marker = first.directory.appendingPathComponent("live-source.mp3")
    try Data("live snapshot bytes".utf8).write(to: marker)

    let second = try OutboundSnapshotArea.create(libraryFolder: libraryDir)
    defer { second.remove() }

    #expect(
      FileManager.default.fileExists(atPath: marker.path),
      Comment(rawValue: "a direct concurrent engine workspace must not be scavenged as an orphan"))
  }

  @Test
  func testFallbackSnapshotRejectsStatInvisibleInPlaceReplacement() async throws {
    let source = libraryDir.appendingPathComponent("coarse-filesystem-source.bin")
    let original = Data(repeating: 0x19, count: 2_000_000)
    let replacement = Data(repeating: 0xE7, count: original.count)
    try original.write(to: source)
    let originalModified = try #require(
      try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date)

    let copyAttempts = Mutex(0)
    let seam = OutboundSourceSnapshot.FallbackTestSeam(
      ignoreTimestampChanges: true,
      afterCopy: { attempt in
        copyAttempts.withLock { $0 += 1 }
        guard attempt == 0 else { return }
        do {
          let handle = try FileHandle(forWritingTo: source)
          defer { try? handle.close() }
          try handle.seek(toOffset: 0)
          try handle.write(contentsOf: replacement)
          try handle.truncate(atOffset: UInt64(replacement.count))
          try handle.synchronize()
        }
        try FileManager.default.setAttributes(
          [.modificationDate: originalModified], ofItemAtPath: source.path)
      })

    let area = try OutboundSnapshotArea.create(libraryFolder: libraryDir)
    defer { area.remove() }
    let snapshot = try OutboundSourceSnapshot.create(
      from: source, in: libraryDir, area: area, fallbackTestSeam: seam)
    defer { snapshot.remove() }

    #expect((copyAttempts.withLock { $0 }) == (2), Comment(rawValue: "content mismatch must force a clean retry"))
    #expect((try Data(contentsOf: source)) == (replacement))
    #expect((try Data(contentsOf: snapshot.url)) == (replacement))
    #expect((snapshot.contentSHA256) == (try SyncSignature.fileSHA256(url: source)))
  }

  private func rawUntaggedMP3() -> Data {
    let frame = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 413)
    return (0..<80).reduce(into: Data()) { data, _ in data.append(frame) }
  }

  @Test
  func testCopyFromIpodTagsUntaggedFileAndStaysIdempotent() async throws {

    let dest = try fs.destinationForNewFile(extension: "mp3")
    let audio = rawUntaggedMP3()
    try audio.write(to: dest)
    var deviceTrack = ITDBTrack()
    deviceTrack.title = "Device Gem"
    deviceTrack.artist = "Tagless Artist"
    deviceTrack.album = "Bare Album"
    deviceTrack.ipodPath = fs.ipodPath(for: dest)
    deviceTrack.sizeBytes = UInt32(audio.count)
    deviceTrack.lengthMS = 2000
    var db = ITunesDatabase()
    db.tracks = [deviceTrack]
    try fs.writeDatabase(db)

    let plan = SyncEngine.makePlan(library: [], device: db.tracks)
    #expect((plan.copyToFolder.count) == (1))
    let result = try await runSync(plan)
    #expect((result.copiedToFolder) == (1))
    #expect((result.failures) == ([]))

    let copied = libraryDir.appendingPathComponent("Tagless Artist - Device Gem.mp3")
    let head = try Data(contentsOf: copied).prefix(3)
    #expect((head) == (Data("ID3".utf8)))
    let loaded = await MetadataLoader.load(url: copied)
    #expect((loaded.title) == ("Device Gem"))
    #expect((loaded.artist) == ("Tagless Artist"))

    let taggedOnce = try Data(contentsOf: copied)
    let oldModificationDate = Date(timeIntervalSince1970: 946_684_800)
    try FileManager.default.setAttributes(
      [.modificationDate: oldModificationDate], ofItemAtPath: copied.path)
    try await SyncEngine.addTagsIfMissing(to: copied, from: deviceTrack)
    #expect((try Data(contentsOf: copied)) == (taggedOnce))
    #expect(
      (try #require(FileManager.default.attributesOfItem(atPath: copied.path)[.modificationDate] as? Date))
        == (oldModificationDate), Comment(rawValue: "identical reconciled tags should not replace the file"))

    let plan2 = SyncEngine.makePlan(library: [loaded], device: db.tracks)
    #expect(plan2.isEmpty, Comment(rawValue: "tagged copy must not re-sync: \(plan2)"))
  }

  @Test
  func testCopyFromIpodReconcilesStaleExistingID3Identity() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Embedded Title", artist: "Embedded Artist", album: "Embedded Album",
        genre: "Rock", trackNumber: 1, year: 2001),
      seconds: 2
    ).write(to: source)
    let embeddedTrack = await MetadataLoader.load(url: source)
    var fileMetadata = TrackMetadata(embeddedTrack)
    fileMetadata.grouping = "Suite II"
    fileMetadata.bpm = 123
    fileMetadata.lyrics = "File-only lyrics"
    try MP3MetadataWriter.write(fileMetadata, to: source)
    var deviceTrack = ITDBTrack()
    deviceTrack.title = "Database Title"
    deviceTrack.artist = "Database Artist"
    deviceTrack.album = "Database Album"
    deviceTrack.trackNumber = 4
    deviceTrack.year = 2004
    deviceTrack.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [deviceTrack]
    try fs.writeDatabase(database)

    let plan = SyncEngine.makePlan(library: [], device: try fs.readDatabase().tracks)
    let result = try await runSync(plan)

    #expect((result.copiedToFolder) == (1))
    let copied = libraryDir.appendingPathComponent("Database Artist - Database Title.mp3")
    let loaded = await MetadataLoader.load(url: copied)
    #expect((loaded.title) == ("Database Title"))
    #expect((loaded.artist) == ("Database Artist"))
    #expect((loaded.album) == ("Database Album"))
    #expect((loaded.trackNumber) == (4))
    #expect((loaded.grouping) == ("Suite II"))
    #expect((loaded.bpm) == (123))
    #expect((loaded.lyrics) == ("File-only lyrics"))
    #expect(SyncEngine.makePlan(library: [loaded], device: [deviceTrack]).isEmpty)
  }

  @Test
  func testTaggingFailureKeepsCopiedAudioAndRetriesMetadataUntilSuccessful() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    let audio = rawUntaggedMP3()
    try audio.write(to: source)
    var track = ITDBTrack()
    track.title = "Must Fail"
    track.artist = "Failure"
    track.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let plan = SyncEngine.makePlan(library: [], device: try fs.readDatabase().tracks)

    struct InitialTagFailure: Error {}
    let firstResult = try await runSync(
      request: SyncExecutionRequest(plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in throw InitialTagFailure() }))

    let copied = libraryDir.appendingPathComponent("Failure - Must Fail.mp3")
    #expect((firstResult.copiedToFolder) == (1))
    #expect((firstResult.failures.count) == (1))
    #expect((firstResult.failures[0].operation) == (.reconstructMetadata))
    #expect(firstResult.failures[0].reason.contains("Copied without reconstructed tags"))
    #expect((try Data(contentsOf: copied)) == (audio))
    #expect((LibraryStore.findAudioFiles(in: libraryDir)) == ([copied.canonicalFileURL]))
    #expect((try fs.readDatabase().tracks.count) == (1))

    var entries = SyncLedgerStore.entries(
      for: database.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries[0].dbid) == (track.dbid))
    #expect((entries[0].needsMetadataReconstruction) == (true))

    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copied.path)
    var retryPlan = try await makePlan()
    #expect((retryPlan.updateInFolder.count) == (1))
    #expect(retryPlan.updateOnDevice.isEmpty)
    #expect(retryPlan.copyToDevice.isEmpty)
    #expect(retryPlan.copyToFolder.isEmpty)

    let outOfScopeRetry = try await makePlan(
      scope: SyncScopeInput(
        scope: .playlists([]), removesSongsOutsideSyncScope: true,
        confirmedRemovalDbids: [track.dbid]))
    #expect((outOfScopeRetry.updateInFolder.count) == (1))
    #expect((outOfScopeRetry.outOfScopeOnDevice.count) == (1))
    #expect(outOfScopeRetry.removeFromDevice.isEmpty)
    #expect(outOfScopeRetry.updateOnDevice.isEmpty)
    #expect(outOfScopeRetry.copyToDevice.isEmpty)
    #expect(outOfScopeRetry.copyToFolder.isEmpty)

    struct RetryTagFailure: Error {}
    let failedRetry = try await runSync(
      request: SyncExecutionRequest(retryPlan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in throw RetryTagFailure() },
        metadataWriter: { _, _ in throw RetryTagFailure() }))
    #expect((failedRetry.updatedInFolder) == (0))
    #expect((failedRetry.failures.map(\.operation)) == ([.updateInFolder]))
    #expect((failedRetry.copiedToDevice + failedRetry.copiedToFolder) == (0))
    #expect((failedRetry.updatedOnDevice) == (0))

    entries = SyncLedgerStore.entries(
      for: database.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries[0].needsMetadataReconstruction) == (true))
    retryPlan = try await makePlan()
    #expect((retryPlan.updateInFolder.count) == (1))
    #expect(retryPlan.updateOnDevice.isEmpty)
    #expect(retryPlan.copyToDevice.isEmpty)
    #expect(retryPlan.copyToFolder.isEmpty)

    let unreadableRetry = try await runSync(
      request: SyncExecutionRequest(retryPlan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in throw RetryTagFailure() },
        metadataWriter: { _, url in
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.path)
        }))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: copied.path)
    #expect((unreadableRetry.updatedInFolder) == (0))
    #expect((unreadableRetry.failures.map(\.operation)) == ([.updateInFolder]))
    entries = SyncLedgerStore.entries(
      for: database.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries[0].needsMetadataReconstruction) == (true))
    retryPlan = try await makePlan()
    #expect((retryPlan.updateInFolder.count) == (1))
    #expect(retryPlan.updateOnDevice.isEmpty)

    let deviceDatabaseBeforeRetry = try Data(contentsOf: fs.databaseURL)
    let successfulRetry = try await runSync(request: SyncExecutionRequest(retryPlan))
    #expect((successfulRetry.updatedInFolder) == (1))
    #expect((successfulRetry.failures) == ([]))
    #expect((successfulRetry.copiedToDevice + successfulRetry.copiedToFolder) == (0))
    #expect((successfulRetry.updatedOnDevice) == (0))
    #expect((try Data(contentsOf: fs.databaseURL)) == (deviceDatabaseBeforeRetry))

    let reconstructed = await MetadataLoader.load(url: copied)
    #expect((reconstructed.title) == ("Must Fail"))
    #expect((reconstructed.artist) == ("Failure"))
    entries = SyncLedgerStore.entries(
      for: database.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries[0].needsMetadataReconstruction) != (true))
    #expect((LibraryStore.findAudioFiles(in: libraryDir)) == ([copied.canonicalFileURL]))
    #expect((try fs.readDatabase().tracks.count) == (1))

    let settledPlan = try await makePlan()
    #expect(settledPlan.isEmpty)
    let settled = try await runSync(request: SyncExecutionRequest(settledPlan))
    #expect((settled.copiedToDevice + settled.copiedToFolder) == (0))
    #expect((settled.updatedOnDevice + settled.updatedInFolder) == (0))
    #expect((LibraryStore.findAudioFiles(in: libraryDir)) == ([copied.canonicalFileURL]))
  }

  @Test
  func testInitialTagFailureKeepsMarkedIdentityWhenCopiedFileCannotBeRead() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    let audio = rawUntaggedMP3()
    try audio.write(to: source)
    var track = ITDBTrack()
    track.title = "Needs Tags"
    track.artist = "Device Artist"
    track.album = "Device Album"
    track.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let storedTrack = try #require(try fs.readDatabase().tracks.first)

    struct InjectedFailure: Error {}
    let result = try await runSync(
      request: SyncExecutionRequest(
        SyncEngine.makePlan(library: [], device: [storedTrack])),
      effects: SyncEngineEffects(
        tagWriter: { url, _ in
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: url.path)
          throw InjectedFailure()
        }))

    let copied = libraryDir.appendingPathComponent("Device Artist - Needs Tags.mp3")
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: copied.path)
    }
    #expect((result.copiedToFolder) == (1))
    #expect((result.failures.map(\.operation)) == ([.reconstructMetadata]))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: copied.path)
    #expect((try Data(contentsOf: copied)) == (audio))

    let entries = SyncLedgerStore.entries(
      for: try fs.readDatabase().databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1), Comment(rawValue: "the copied file must retain its durable identity"))
    #expect((entries.first?.dbid) == (storedTrack.dbid))
    #expect((entries.first?.needsMetadataReconstruction) == (true))

    let library = await LibraryStore.loadTracks(at: [copied])
    let links = SyncLedgerStore.resolveLinks(
      entries: entries, library: library, device: [storedTrack], libraryFolder: libraryDir)
    let retry = SyncEngine.makePlan(library: library, device: [storedTrack], links: links)
    #expect((retry.updateInFolder.count) == (1))
    #expect(retry.copyToFolder.isEmpty)
    #expect(retry.copyToDevice.isEmpty)
    #expect(retry.updateOnDevice.isEmpty)
  }

  @Test
  func testInitialTaggingRequiresReadbackBeforeRecordingReconciledLink() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    try rawUntaggedMP3().write(to: source)
    var track = ITDBTrack()
    track.title = "Needs Tags"
    track.artist = "Device Artist"
    track.album = "Device Album"
    track.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let storedTrack = try #require(try fs.readDatabase().tracks.first)

    let result = try await runSync(
      request: SyncExecutionRequest(
        SyncEngine.makePlan(library: [], device: [storedTrack])),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in }))

    let copied = libraryDir.appendingPathComponent("Device Artist - Needs Tags.mp3")
    #expect((result.copiedToFolder) == (1))
    #expect((result.failures.map(\.operation)) == ([.reconstructMetadata]))
    let stillUntagged = await MetadataLoader.load(url: copied)
    #expect((stillUntagged.title) == (""))
    #expect((stillUntagged.artist) == (""))

    let entries = SyncLedgerStore.entries(
      for: try fs.readDatabase().databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries.first?.needsMetadataReconstruction) == (true))
    let links = SyncLedgerStore.resolveLinks(
      entries: entries, library: [stillUntagged], device: [storedTrack],
      libraryFolder: libraryDir)
    let retry = SyncEngine.makePlan(
      library: [stillUntagged], device: [storedTrack], links: links)
    #expect((retry.updateInFolder.count) == (1))
    #expect(retry.copyToFolder.isEmpty)
    #expect(retry.copyToDevice.isEmpty)
    #expect(retry.updateOnDevice.isEmpty)
  }

  @Test
  func testMetadataRetryRequiresReadbackBeforeClearingMarker() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    try rawUntaggedMP3().write(to: source)
    var track = ITDBTrack()
    track.title = "Needs Tags"
    track.artist = "Device Artist"
    track.album = "Device Album"
    track.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let storedTrack = try #require(try fs.readDatabase().tracks.first)

    struct InjectedFailure: Error {}
    _ = try await runSync(
      request: SyncExecutionRequest(
        SyncEngine.makePlan(library: [], device: [storedTrack])),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in throw InjectedFailure() }))

    let copied = libraryDir.appendingPathComponent("Device Artist - Needs Tags.mp3")
    let library = await LibraryStore.loadTracks(at: [copied])
    var entries = SyncLedgerStore.entries(
      for: try fs.readDatabase().databaseID, libraryFolder: libraryDir)
    let links = SyncLedgerStore.resolveLinks(
      entries: entries, library: library, device: [storedTrack], libraryFolder: libraryDir)
    let retry = SyncEngine.makePlan(library: library, device: [storedTrack], links: links)
    #expect((retry.updateInFolder.count) == (1))

    let result = try await runSync(
      request: SyncExecutionRequest(retry),
      effects: SyncEngineEffects(
        tagWriter: { url, track in try await SyncEngine.addTagsIfMissing(to: url, from: track) },
        metadataWriter: { _, _ in }))
    #expect((result.updatedInFolder) == (0))
    #expect((result.failures.map(\.operation)) == ([.updateInFolder]))

    let stillUntagged = await MetadataLoader.load(url: copied)
    #expect((stillUntagged.title) == (""))
    #expect((stillUntagged.artist) == (""))
    entries = SyncLedgerStore.entries(
      for: try fs.readDatabase().databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries.first?.needsMetadataReconstruction) == (true))

    let retryLinks = SyncLedgerStore.resolveLinks(
      entries: entries, library: [stillUntagged], device: [storedTrack],
      libraryFolder: libraryDir)
    let stillPending = SyncEngine.makePlan(
      library: [stillUntagged], device: [storedTrack], links: retryLinks)
    #expect((stillPending.updateInFolder.count) == (1))
    #expect(stillPending.copyToFolder.isEmpty)
    #expect(stillPending.copyToDevice.isEmpty)
    #expect(stillPending.updateOnDevice.isEmpty)
  }

  @Test
  func testFolderCopyRacePreservesDestinationCreatedByAnotherWriter() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    try rawUntaggedMP3().write(to: source)
    var track = ITDBTrack()
    track.title = "Contested"
    track.artist = "Race"
    track.ipodPath = fs.ipodPath(for: source)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let destination = libraryDir.appendingPathComponent("Race - Contested.mp3")
    let winner = Data("other writer won".utf8)
    let libraryFolder = libraryDir

    let result = try await runSync(
      request: SyncExecutionRequest(
        SyncEngine.makePlan(library: [], device: try fs.readDatabase().tracks)),
      effects: SyncEngineEffects(
        tagWriter: { stagedURL, _ in
          #expect((stagedURL.deletingLastPathComponent()) != (libraryFolder))
          try winner.write(to: destination)
        }))

    #expect((result.copiedToFolder) == (0))
    #expect((result.failures.count) == (1))
    #expect((try Data(contentsOf: destination)) == (winner))
  }

  @Test
  func testFailedDatabaseWriteRemovesCopiedFiles() async throws {
    let track = try makeLibraryMP3(title: "Doomed", artist: "Band", album: "LP")
    let plan = SyncEngine.makePlan(library: [track], device: [])
    #expect((plan.copyToDevice.count) == (1))

    struct InjectedDatabaseFailure: Error {}

    var thrown: Error?
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { _, _ in throw InjectedDatabaseFailure() }))
    } catch {
      thrown = error
    }
    #expect(thrown != nil, Comment(rawValue: "execute must rethrow the database write failure"))

    let musicDir = ipodDir.appendingPathComponent("iPod_Control/Music")
    let leftovers =
      FileManager.default
      .enumerator(at: musicDir, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "mp3" } ?? []
    #expect((leftovers) == ([]), Comment(rawValue: "copied files must be cleaned up on DB write failure"))
  }

  @Test
  func testWhitespaceTitleKeepsMatchKeyThroughDBConversion() {
    let track = LibraryTrack(
      url: URL(fileURLWithPath: "/lib/Real Stem.mp3"), title: "   ", artist: "Spacey", durationMS: 1000,
      sizeBytes: 1000, bitrate: 128, samplerate: 44100)
    let dbTrack = SyncEngine.makeDBTrack(
      from: track, ipodPath: ":iPod_Control:Music:F00:QQQQ.mp3")
    #expect((dbTrack.title) == ("Real Stem"), Comment(rawValue: "title must fall back to the filename stem"))
    #expect((TrackMatcher.key(for: track)) == (TrackMatcher.key(for: dbTrack)))
  }

  @Test
  func testTrackMatcherDoesNotCollideWhenMetadataContainsDelimiters() {
    let local = LibraryTrack(
      url: URL(fileURLWithPath: "/lib/local.mp3"), title: "A|B", artist: "C", album: "Album", trackNumber: 1,
      discNumber: 1, durationMS: 1_000, sizeBytes: 1_000, bitrate: 128, samplerate: 44_100)
    var device = ITDBTrack()
    device.title = "A"
    device.artist = "B|C"
    device.album = "Album"
    device.trackNumber = 1
    device.discNumber = 1

    let plan = SyncEngine.makePlan(library: [local], device: [device])

    #expect((plan.copyToDevice.count) == (1))
    #expect((plan.copyToFolder.count) == (1))
  }

  @Test
  func testTitlelessDevicePathUsesColonDelimitedFilenameFallback() {
    let local = LibraryTrack(
      url: URL(fileURLWithPath: "/lib/ABCD.mp3"), title: "",
      durationMS: 0, sizeBytes: 0, bitrate: 0, samplerate: 44_100)
    var device = ITDBTrack()
    device.ipodPath = ":iPod_Control:Music:F00:ABCD.mp3"

    #expect((TrackMatcher.key(for: local)) == (TrackMatcher.key(for: device)))
  }

  @Test
  func testTitlelessDeviceCopyReconstructsFallbackTitleAndStaysIdempotent() async throws {
    let source = try fs.destinationForNewFile(extension: "mp3")
    try rawUntaggedMP3().write(to: source)
    var device = ITDBTrack()
    device.artist = "Ghost Artist"
    device.album = "Mystery Album"
    device.ipodPath = fs.ipodPath(for: source)
    device.lengthMS = 2_000
    var database = ITunesDatabase()
    database.tracks = [device]
    try fs.writeDatabase(database)

    let result = try await runSync(SyncEngine.makePlan(library: [], device: try fs.readDatabase().tracks))
    #expect((result.copiedToFolder) == (1))
    let copy = libraryDir.appendingPathComponent(source.lastPathComponent)
    let loaded = await MetadataLoader.load(url: copy)
    #expect((loaded.title) == (source.deletingPathExtension().lastPathComponent))
    #expect((loaded.artist) == ("Ghost Artist"))
    #expect((loaded.album) == ("Mystery Album"))
    #expect(SyncEngine.makePlan(library: [loaded], device: [device]).isEmpty)
  }

  @Test
  func testPlanPreservesVariantsAndDuplicateMultiplicity() throws {
    let studio = try makeLibraryMP3(title: "Anthem", artist: "Band", album: "Studio")
    var liveDevice = ITDBTrack()
    liveDevice.title = "Anthem"
    liveDevice.artist = "Band"
    liveDevice.album = "Live"
    liveDevice.trackNumber = 1

    let variants = SyncEngine.makePlan(library: [studio], device: [liveDevice])
    #expect((variants.copyToDevice.count) == (1))
    #expect((variants.copyToFolder.count) == (1))

    let matchingDevice = SyncEngine.makeDBTrack(
      from: studio, ipodPath: ":iPod_Control:Music:F00:ONEA.mp3")
    let duplicates = SyncEngine.makePlan(library: [studio, studio], device: [matchingDevice])
    #expect((duplicates.copyToDevice.count) == (1))
    #expect(duplicates.copyToFolder.isEmpty)
  }

  @Test
  func testConcurrentExecutionsReplanAfterTakingDeviceLock() async throws {
    let track = try makeLibraryMP3(title: "Once", artist: "Only", album: "One")
    try fs.writeDatabase(ITunesDatabase())
    let stalePlan = SyncEngine.makePlan(library: [track], device: [])
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir

    async let first = SyncEngine.execute(
      plan: stalePlan, deviceVolume: deviceVolume, libraryFolder: libraryFolder,
      progress: { _ in })
    async let second = SyncEngine.execute(
      plan: stalePlan, deviceVolume: deviceVolume, libraryFolder: libraryFolder,
      progress: { _ in })
    let results = try await (first, second)

    #expect((results.0.copiedToDevice + results.1.copiedToDevice) == (1))
    #expect((try fs.readDatabase().tracks.count) == (1))
  }

  @Test
  func testInitiallyMatchingFileEditedBeforeExecutionIsReplannedBothWays() async throws {
    let scanned = try makeLibraryMP3(title: "Old", artist: "Artist", album: "Album")
    let deviceURL = try fs.destinationForNewFile(extension: "mp3")
    try FileManager.default.copyItem(at: scanned.url, to: deviceURL)
    let deviceTrack = SyncEngine.makeDBTrack(
      from: scanned, ipodPath: fs.ipodPath(for: deviceURL))
    var database = ITunesDatabase()
    database.tracks = [deviceTrack]
    try fs.writeDatabase(database)
    let initiallyEmpty = SyncEngine.makePlan(library: [scanned], device: [deviceTrack])
    #expect(initiallyEmpty.isEmpty)

    try MP3Builder.build(
      tags: .init(
        title: "New", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2
    ).write(to: scanned.url)

    let result = try await runSync(initiallyEmpty)

    #expect((result.copiedToFolder) == (1))
    #expect((result.copiedToDevice) == (1))
    #expect((Set(try fs.readDatabase().tracks.compactMap(\.title))) == (Set(["Old", "New"])))
  }

  @Test
  func testInboundReplanUnderLibraryLockSeesCopyFromAnotherProcess() async throws {
    let deviceURL = try fs.destinationForNewFile(extension: "mp3")
    let bytes = MP3Builder.build(
      tags: .init(
        title: "Shared", artist: "Artist", album: "Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2)
    try bytes.write(to: deviceURL)
    let deviceTrack = LibraryTrack(
      url: deviceURL, title: "Shared", artist: "Artist", album: "Album", genre: "Rock", trackNumber: 1, year: 2004,
      durationMS: 2_000, sizeBytes: bytes.count, bitrate: 128, samplerate: 44_100)
    let stored = SyncEngine.makeDBTrack(
      from: deviceTrack, ipodPath: fs.ipodPath(for: deviceURL))
    var database = ITunesDatabase()
    database.tracks = [stored]
    try fs.writeDatabase(database)
    let stalePlan = SyncEngine.makePlan(library: [], device: [stored])

    let heldLibraryLock = try await ScopedAdvisoryLock.acquire(
      for: libraryDir, namespace: .library)
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir
    let task = Task {
      try await SyncEngine.execute(
        plan: stalePlan, deviceVolume: deviceVolume, libraryFolder: libraryFolder,
        progress: { _ in })
    }
    try bytes.write(to: libraryDir.appendingPathComponent("Artist - Shared.mp3"))
    heldLibraryLock.unlock()

    let result = try await task.value
    #expect((result.copiedToFolder) == (0))
    #expect((result.copiedToDevice) == (0))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).map(\.lastPathComponent)) == (["Artist - Shared.mp3"]))
  }

  @Test
  func testSyncRejectsDifferentDeviceMountedAtExpectedPath() async throws {
    var original = ITunesDatabase()
    original.databaseID = 0x1111
    try fs.writeDatabase(original)
    let heldLock = try await ScopedAdvisoryLock.acquire(for: ipodDir, namespace: .device)
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir
    let expectedDatabaseID = original.databaseID
    let task = Task {
      try await SyncEngine.execute(
        plan: SyncEngine.makePlan(library: [], device: []), deviceVolume: deviceVolume,
        libraryFolder: libraryFolder,
        expectedDatabaseID: expectedDatabaseID, progress: { _ in })
    }
    var replacement = ITunesDatabase()
    replacement.databaseID = 0x2222
    try fs.writeDatabase(replacement)
    heldLock.unlock()

    do {
      _ = try await task.value
      Issue.record("sync must reject a different device incarnation")
    } catch {
      #expect(error.localizedDescription.contains("changed"))
    }
    #expect((try fs.readDatabase().databaseID) == (replacement.databaseID))
  }

  @Test
  func testScopedAdvisoryLockSerializesSameLibrary() async throws {
    let libraryFolder = libraryDir
    let first = try await ScopedAdvisoryLock.acquire(for: libraryFolder, namespace: .library)
    let state = AcquisitionState()
    let secondTask = Task {
      let second = try await ScopedAdvisoryLock.acquire(
        for: libraryFolder, namespace: .library)
      await state.markAcquired()
      second.unlock()
    }
    let heldWhileLocked = await holds(for: .milliseconds(50)) {
      !(await state.acquired)
    }
    #expect(heldWhileLocked, Comment(rawValue: "the second acquire must wait for the first holder"))

    first.unlock()
    try await secondTask.value
    let acquiredAfterRelease = await state.acquired
    #expect(acquiredAfterRelease)
  }

  @Test
  func testCancelledInProcessLockWaiterExitsWithoutLeakingTheScope() async throws {
    let libraryFolder = libraryDir
    let first = try await ScopedAdvisoryLock.acquire(
      for: libraryFolder, namespace: .library)
    let cancelledState = AcquisitionState()
    let cancelledWaiter = Task {
      let lock = try await ScopedAdvisoryLock.acquire(
        for: libraryFolder, namespace: .library)
      await cancelledState.markAcquired()
      lock.unlock()
    }
    _ = await holds(for: .milliseconds(40)) { !(await cancelledState.acquired) }

    let failsafeUnlock = Task {
      try? await Task.sleep(for: .seconds(1))
      if !Task.isCancelled { first.unlock() }
    }
    defer {
      failsafeUnlock.cancel()
      first.unlock()
    }
    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    cancelledWaiter.cancel()
    var threwCancellation = false
    do {
      try await cancelledWaiter.value
    } catch is CancellationError {
      threwCancellation = true
    } catch {
      Issue.record("unexpected lock-wait error: \(error)")
    }
    let cancellationDuration = cancellationStarted.duration(to: clock.now)
    let cancelledWaiterAcquired = await cancelledState.acquired
    #expect(threwCancellation)
    #expect((cancellationDuration) < (.milliseconds(500)))
    #expect(!(cancelledWaiterAcquired))
    guard threwCancellation, cancellationDuration < .milliseconds(500) else { return }

    let nextState = AcquisitionState()
    let nextWaiter = Task {
      let lock = try await ScopedAdvisoryLock.acquire(
        for: libraryFolder, namespace: .library)
      await nextState.markAcquired()
      lock.unlock()
    }
    let nextWaiterHeldOut = await holds(for: .milliseconds(40)) {
      !(await nextState.acquired)
    }
    #expect(nextWaiterHeldOut, Comment(rawValue: "the original holder still owns the scope"))
    first.unlock()
    try await nextWaiter.value
    let nextWaiterAcquired = await nextState.acquired
    let cancelledWaiterAcquiredLater = await cancelledState.acquired
    #expect(nextWaiterAcquired)
    #expect(!(cancelledWaiterAcquiredLater), Comment(rawValue: "the cancelled waiter must never acquire later"))
  }

  @Test
  func testCancelledCrossProcessLockWaiterReleasesItsInProcessScope() async throws {
    let libraryFolder = libraryDir
    let lockURL = ScopedAdvisoryLock.lockFileURL(
      for: libraryFolder, namespace: .library)
    let (externalProcess, externalRelease) = try startExternalLock(at: lockURL)
    var externalWasReleased = false
    defer {
      if !externalWasReleased {
        try? externalRelease.write(contentsOf: Data([0x0A]))
      }
      try? externalRelease.close()
      if externalProcess.isRunning { externalProcess.terminate() }
      externalProcess.waitUntilExit()
    }

    let cancelledState = AcquisitionState()
    let cancelledWaiter = Task {
      let lock = try await ScopedAdvisoryLock.acquire(
        for: libraryFolder, namespace: .library)
      await cancelledState.markAcquired()
      lock.unlock()
    }
    _ = await holds(for: .milliseconds(40)) { !(await cancelledState.acquired) }

    let failsafeRelease = Task {
      try? await Task.sleep(for: .seconds(1))
      if !Task.isCancelled {
        try? externalRelease.write(contentsOf: Data([0x0A]))
      }
    }
    defer { failsafeRelease.cancel() }
    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    cancelledWaiter.cancel()
    var threwCancellation = false
    do {
      try await cancelledWaiter.value
    } catch is CancellationError {
      threwCancellation = true
    } catch {
      Issue.record("unexpected cross-process lock-wait error: \(error)")
    }
    let cancellationDuration = cancellationStarted.duration(to: clock.now)
    let cancelledWaiterAcquired = await cancelledState.acquired
    #expect(threwCancellation)
    #expect((cancellationDuration) < (.milliseconds(500)))
    #expect(!(cancelledWaiterAcquired))
    guard threwCancellation, cancellationDuration < .milliseconds(500) else { return }
    failsafeRelease.cancel()

    let nextState = AcquisitionState()
    let nextWaiter = Task {
      let lock = try await ScopedAdvisoryLock.acquire(
        for: libraryFolder, namespace: .library)
      await nextState.markAcquired()
      lock.unlock()
    }
    let nextWaiterHeldOut = await holds(for: .milliseconds(40)) {
      !(await nextState.acquired)
    }
    #expect(nextWaiterHeldOut)
    try externalRelease.write(contentsOf: Data([0x0A]))
    externalWasReleased = true
    externalProcess.waitUntilExit()
    try await nextWaiter.value
    let nextWaiterAcquired = await nextState.acquired
    let cancelledWaiterAcquiredLater = await cancelledState.acquired
    #expect(nextWaiterAcquired)
    #expect(!(cancelledWaiterAcquiredLater), Comment(rawValue: "the cancelled waiter must never acquire later"))
  }

  @Test
  func testInterruptedCopyTransactionRemovesOnlyUncommittedDestinations() throws {
    let source = libraryDir.appendingPathComponent("source.mp3")
    try rawUntaggedMP3().write(to: source)

    let abandonedDestination = try fs.destinationForNewFile(extension: "mp3")
    let abandoned = try IpodCopyTransaction(fileSystem: fs)
    let staged = try abandoned.stage(source: source, destination: abandonedDestination)
    try abandoned.publishJournal()
    try FileManager.default.moveItem(at: staged, to: abandonedDestination)
    try fs.recoverInterruptedSyncCopies(database: ITunesDatabase())
    #expect(!(FileManager.default.fileExists(atPath: abandonedDestination.path)))

    let committedDestination = try fs.destinationForNewFile(extension: "mp3")
    let committed = try IpodCopyTransaction(fileSystem: fs)
    let committedStaging = try committed.stage(source: source, destination: committedDestination)
    try committed.publishJournal()
    try FileManager.default.moveItem(at: committedStaging, to: committedDestination)
    var track = ITDBTrack()
    track.ipodPath = fs.ipodPath(for: committedDestination)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.recoverInterruptedSyncCopies(database: database)
    #expect(FileManager.default.fileExists(atPath: committedDestination.path))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testSyncReservesDestinationsBeforePublishingStagedCopies() async throws {
    let onlyMusicDirectory = fs.musicDir.appendingPathComponent("F00", isDirectory: true)
    try FileManager.default.createDirectory(
      at: onlyMusicDirectory, withIntermediateDirectories: true)

    let firstTrack = try makeLibraryMP3(title: "First", artist: "Collision", album: "Test")
    let secondTrack = try makeLibraryMP3(title: "Second", artist: "Collision", album: "Test")
    let firstDestination = onlyMusicDirectory.appendingPathComponent("SAME.mp3")
    let secondDestination = onlyMusicDirectory.appendingPathComponent("NEXT.mp3")
    let reservedFirstDestination = firstDestination.standardizedFileURL

    let result = try await runSync(
      request: SyncExecutionRequest(
        SyncEngine.makePlan(library: [firstTrack, secondTrack], device: [])),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        destinationAllocator: { _, fileExtension, reservedDestinations in
          #expect((fileExtension) == ("mp3"))
          if reservedDestinations.contains(reservedFirstDestination) {
            return secondDestination
          }
          return firstDestination
        }))

    #expect((result.copiedToDevice) == (2))
    #expect((result.failures) == ([]))
    #expect((try Data(contentsOf: firstDestination)) == (try Data(contentsOf: firstTrack.url)))
    #expect((try Data(contentsOf: secondDestination)) == (try Data(contentsOf: secondTrack.url)))
    #expect(
      (Set(try fs.readDatabase().tracks.compactMap(\.ipodPath)))
        == (Set([fs.ipodPath(for: firstDestination), fs.ipodPath(for: secondDestination)])))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testCancellationMidCopyLeavesDeviceUntouchedAndNextSyncSucceeds() async throws {
    let first = try makeLibraryMP3(title: "First", artist: "Cancel", album: "Test")
    let second = try makeLibraryMP3(title: "Second", artist: "Cancel", album: "Test")

    let box = Mutex<Task<SyncResult, Error>?>(nil)
    let taskPublished = DispatchSemaphore(value: 0)
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir

    let task = Task {
      try await SyncEngine.execute(
        request: SyncExecutionRequest(SyncEngine.makePlan(library: [first, second], device: [])),
        deviceVolume: deviceVolume,
        libraryFolder: libraryFolder,
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          destinationAllocator: { fileSystem, fileExtension, reserved in
            _ = taskPublished.wait(timeout: .now() + 10)
            box.withLock { $0?.cancel() }
            return try fileSystem.destinationForNewFile(
              extension: fileExtension, excluding: reserved)
          }),
        progress: { _ in })
    }
    box.withLock { $0 = task }
    taskPublished.signal()

    do {
      _ = try await task.value
      Issue.record("expected the sync to be cancelled")
    } catch is CancellationError {
    }

    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
    let leftoverAudio = (FileManager.default.subpaths(atPath: fs.musicDir.path) ?? [])
      .filter { $0.lowercased().hasSuffix(".mp3") }
    #expect((leftoverAudio) == ([]))
    #expect(!(FileManager.default.fileExists(atPath: fs.databaseURL.path)))
    #expect(!(FileManager.default.fileExists(atPath: fs.compressedDatabaseURL.path)))

    let result = try await runSync(SyncEngine.makePlan(library: [first, second], device: []))
    #expect((result.copiedToDevice) == (2))
    #expect((result.failures) == ([]))
    #expect((try fs.readDatabase().tracks.count) == (2))
  }

  @Test
  func testCancellationIsHonoredWhenOnlyAdoptedLinkingRemains() async throws {
    let first = try makeLibraryMP3(title: "First", artist: "Adopt", album: "Test")
    let second = try makeLibraryMP3(title: "Second", artist: "Adopt", album: "Test")
    _ = try await runSync(SyncEngine.makePlan(library: [first, second], device: []))

    let plan = SyncEngine.makePlan(
      library: [first, second], device: try fs.readDatabase().tracks)
    #expect((plan.adoptedPairs.count) == (2))
    #expect(plan.copyToDevice.isEmpty)
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir

    let task = Task {
      try await SyncEngine.execute(
        plan: plan, deviceVolume: deviceVolume, libraryFolder: libraryFolder
      ) { _ in }
    }
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("expected the sync to be cancelled")
    } catch is CancellationError {
    }

    #expect(!(FileManager.default.fileExists(atPath: fs.databaseBackupURL.path)))

    let result = try await runSync(
      SyncEngine.makePlan(
        library: [first, second], device: try fs.readDatabase().tracks))
    #expect((result.copiedToDevice) == (0))
    #expect((result.failures) == ([]))
  }

  @Test
  func testCopyTransactionRejectsDuplicateJournalDestination() throws {
    let source = libraryDir.appendingPathComponent("source.mp3")
    try rawUntaggedMP3().write(to: source)
    let destination = fs.musicDir.appendingPathComponent("F00/SAME.mp3")

    let transaction = try IpodCopyTransaction(fileSystem: fs)
    defer { transaction.finish() }
    _ = try transaction.stage(source: source, destination: destination)
    #expect(throws: (any Error).self) { try transaction.stage(source: source, destination: destination) }
    #expect((transaction.entries.count) == (1))
  }

  @Test
  func testSyncRejectsInboundAndOutboundSymlinkEscapes() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let outside = scratch.appendingPathComponent("outside.mp3")
    try rawUntaggedMP3().write(to: outside)

    let outboundLink = libraryDir.appendingPathComponent("escape.mp3")
    try FileManager.default.createSymbolicLink(at: outboundLink, withDestinationURL: outside)
    let outboundTrack = LibraryTrack(
      url: outboundLink, title: "Escape", durationMS: 0, sizeBytes: 1, bitrate: 0, samplerate: 44_100)
    #expect(throws: (any Error).self) { try SyncEngine.validatedLibraryFile(outboundTrack.url, in: libraryDir) }

    let deviceLink = fs.musicDir.appendingPathComponent("F00/EVIL.mp3")
    try FileManager.default.createDirectory(
      at: deviceLink.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: deviceLink, withDestinationURL: outside)
    var inboundTrack = ITDBTrack()
    inboundTrack.title = "Inbound Escape"
    inboundTrack.ipodPath = fs.ipodPath(for: deviceLink)
    var database = ITunesDatabase()
    database.tracks = [inboundTrack]
    try fs.writeDatabase(database)
    let inbound = try await runSync(SyncEngine.makePlan(library: [], device: try fs.readDatabase().tracks))
    #expect((inbound.copiedToFolder) == (0))
    #expect((inbound.failures.count) == (1))
  }

  @Test
  func testNewDestinationRejectsSymlinkedFNNDirectory() throws {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    let outside = scratch.appendingPathComponent("outside-directory", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fs.musicDir.appendingPathComponent("F00", isDirectory: true),
      withDestinationURL: outside)

    #expect(throws: (any Error).self) { try fs.destinationForNewFile(extension: "mp3") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test
  func testInboundValidationRejectsSymlinkedMusicRoot() throws {
    let hostileVolume = scratch.appendingPathComponent("HOSTILE", isDirectory: true)
    let hostileControl = hostileVolume.appendingPathComponent("iPod_Control", isDirectory: true)
    try FileManager.default.createDirectory(at: hostileControl, withIntermediateDirectories: true)
    let outsideMusic = scratch.appendingPathComponent("outside-music/F00", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideMusic, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: outsideMusic.appendingPathComponent("EVIL.mp3"))
    try FileManager.default.createSymbolicLink(
      at: hostileControl.appendingPathComponent("Music", isDirectory: true),
      withDestinationURL: outsideMusic.deletingLastPathComponent())

    #expect(throws: (any Error).self) {
      try IpodFileSystem(volumeURL: hostileVolume)
        .validatedMusicFileURL(forIpodPath: ":iPod_Control:Music:F00:EVIL.mp3")
    }
  }

  @Test
  func testDatabaseWriteRejectsEscapingITunesSymlinkBeforeMutation() throws {
    try FileManager.default.removeItem(at: fs.itunesDir)
    let outside = scratch.appendingPathComponent("outside-itunes", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: fs.itunesDir, withDestinationURL: outside)

    #expect(throws: (any Error).self) { try fs.writeDatabase(ITunesDatabase()) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
  }

  @Test
  func testMusicDirectoryCreationRejectsEscapingControlSymlinkBeforeMutation() throws {
    let hostileVolume = scratch.appendingPathComponent("HOSTILE-CONTROL", isDirectory: true)
    let outsideControl = scratch.appendingPathComponent("outside-control", isDirectory: true)
    try FileManager.default.createDirectory(at: hostileVolume, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideControl, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: hostileVolume.appendingPathComponent("iPod_Control", isDirectory: true),
      withDestinationURL: outsideControl)

    let hostile = IpodFileSystem(volumeURL: hostileVolume)
    #expect(!(IpodFileSystem.isIpodVolume(hostileVolume)))
    #expect(throws: (any Error).self) { try hostile.musicSubdirectories() }
    #expect(!(FileManager.default.fileExists(atPath: hostile.musicDir.path)))
  }

  @Test
  func testOutboundSyncReloadsMetadataFromCurrentSourceBytes() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let scanned = try makeLibraryMP3(title: "Old Title", artist: "Artist", album: "Old Album")
    let plan = SyncEngine.makePlan(library: [scanned], device: [])
    try MP3Builder.build(
      tags: .init(
        title: "New Title", artist: "Artist", album: "New Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2
    ).write(to: scanned.url)

    let result = try await runSync(plan)

    #expect((result.copiedToDevice) == (1))
    let stored = try #require(fs.readDatabase().tracks.first)
    #expect((stored.title) == ("New Title"))
    #expect((stored.album) == ("New Album"))
    let current = await MetadataLoader.load(url: scanned.url)
    #expect(SyncEngine.makePlan(library: [current], device: [stored]).isEmpty)
  }

  @Test
  func testUnicodeTagsRoundTripThroughMetadataLoader() async throws {
    let title = "Ágætis byrjun — 日本語"
    let artist = "Сигур Рос"
    let data = MP3Builder.build(
      tags: .init(
        title: title, artist: artist, album: "Álbum",
        genre: "Post-Rock", trackNumber: 1, year: 1999),
      seconds: 2)
    let url = libraryDir.appendingPathComponent("unicode.mp3")
    try data.write(to: url)
    let loaded = await MetadataLoader.load(url: url)
    #expect((loaded.title) == (title))
    #expect((loaded.artist) == (artist))
    #expect((loaded.album) == ("Álbum"))
  }

  @Test
  func testFailedDatabaseBackupAbortsTheWrite() throws {
    var original = ITunesDatabase()
    var track = ITDBTrack()
    track.title = "Original"
    original.tracks = [track]
    try fs.writeDatabase(original)

    let blocker = fs.databaseBackupURL.appendingPathComponent("lock", isDirectory: true)
    try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: blocker.appendingPathComponent("keep"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: blocker.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: blocker.path)
    }

    var replacement = ITunesDatabase()
    var newTrack = ITDBTrack()
    newTrack.title = "Replacement"
    replacement.tracks = [newTrack]
    #expect(throws: (any Error).self, Comment(rawValue: "a write without a fresh backup must be refused")) {
      try fs.writeDatabase(replacement)
    }
    #expect(
      (try fs.readDatabase().tracks.map(\.title)) == (["Original"]),
      Comment(rawValue: "the database must be untouched when the backup could not be made"))
  }

  @Test
  func testDatabaseWriteUsesFullDurabilityBarrierForBackupBeforeLiveDatabase() throws {
    var original = ITunesDatabase()
    var originalTrack = ITDBTrack()
    originalTrack.title = "Original"
    original.tracks = [originalTrack]
    try fs.writeDatabase(original)
    let originalData = try Data(contentsOf: fs.databaseURL)

    var replacement = ITunesDatabase()
    var replacementTrack = ITDBTrack()
    replacementTrack.title = "Replacement"
    replacement.tracks = [replacementTrack]

    var writtenURLs: [URL] = []
    var barriers: [Bool] = []
    try fs.writeDatabase(
      replacement,
      databaseFileWriter: { data, url, barrier in
        writtenURLs.append(url.standardizedFileURL)
        barriers.append(barrier)
        try DurableIO.write(data, to: url, barrier: barrier)
      })

    #expect(
      writtenURLs == [fs.databaseBackupURL, fs.databaseURL].map(\.standardizedFileURL),
      Comment(rawValue: "the durable backup must be published before the live database"))
    #expect(
      barriers == [true, true],
      Comment(rawValue: "both database generations must reach the device write cache"))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == originalData)
    #expect((try fs.readDatabase().tracks.map(\.title)) == ["Replacement"])
  }

  @Test
  func testSanitizeProducesValidFAT32Names() {
    #expect((SyncEngine.sanitize("a<b>c|d\"e?f*g")) == ("a-b-c-d-e-f-g"))
    #expect((SyncEngine.sanitize("Song...")) == ("Song"))
    #expect((SyncEngine.sanitize("Song . ")) == ("Song"))
    for name in ["CON", "con", "Prn", "AUX", "NUL", "COM1", "com9", "LPT1", "lpt9"] {
      #expect((SyncEngine.sanitize(name)) == ("_" + name), Comment(rawValue: "\(name) must be escaped"))
    }
    #expect((SyncEngine.sanitize("con.mp3")) == ("_con.mp3"))
    #expect((SyncEngine.sanitize("Consolation")) == ("Consolation"))
    #expect((SyncEngine.sanitize("COM10")) == ("COM10"))
    #expect((SyncEngine.sanitize("NULLIFY")) == ("NULLIFY"))
  }

  @Test
  func testFailedWriteBackRecordsCurrentStateAndRetriesNextSync() async throws {
    let local = try makeLibraryMP3(title: "Linked", artist: "Band", album: "Old Album")
    let originalHash = try SyncSignature.fileSHA256(url: local.url)

    var device = SyncEngine.makeDBTrack(
      from: local, ipodPath: ":iPod_Control:Music:F00:LNKD.mp3")
    let staleSignature = SyncSignature.deviceSignature(for: device)
    device.album = "New Album"
    var database = ITunesDatabase()
    database.tracks = [device]
    try fs.writeDatabase(database)
    let storedDB = try fs.readDatabase()
    let stored = try #require(storedDB.tracks.first)

    let attributes = try FileManager.default.attributesOfItem(atPath: local.url.path)
    let generationStamp = try #require(FileGenerationStamp(url: local.url))
    let entry = SyncLedgerEntry(
      relativePath: local.url.lastPathComponent,
      dbid: stored.dbid,
      fileSize: try #require(attributes[.size] as? Int),
      fileModifiedAt: try #require(attributes[.modificationDate] as? Date)
        .timeIntervalSince1970,
      fileGenerationStamp: generationStamp,
      contentSHA256: originalHash,
      deviceSignature: staleSignature)
    try SyncLedgerStore.replaceEntries(
      [entry], for: storedDB.databaseID, libraryFolder: libraryDir)

    func plan() async -> SyncPlan {
      let library = [await MetadataLoader.load(url: local.url)]
      let links = SyncLedgerStore.resolveLinks(
        entries: SyncLedgerStore.entries(
          for: storedDB.databaseID, libraryFolder: libraryDir),
        library: library, device: storedDB.tracks, libraryFolder: libraryDir)
      return SyncEngine.makePlan(library: library, device: storedDB.tracks, links: links)
    }
    let initialPlan = await plan()
    #expect((initialPlan.updateInFolder.count) == (1))

    struct InjectedFailure: Error {}
    let corrupted = MP3Builder.build(
      tags: .init(
        title: "Half Written", artist: "Band", album: "New Album",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 1)
    let result = try await runSync(
      request: SyncExecutionRequest(initialPlan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        metadataWriter: { _, url in
          try corrupted.write(to: url)
          throw InjectedFailure()
        }))

    #expect((result.updatedInFolder) == (0))
    #expect((result.failures.map(\.operation)) == ([.updateInFolder]))

    let entries = SyncLedgerStore.entries(
      for: storedDB.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries[0].contentSHA256) == (try SyncSignature.fileSHA256(url: local.url)))
    #expect((entries[0].contentSHA256) != (originalHash))
    #expect((entries[0].deviceSignature) == (staleSignature))
    #expect((entries[0].deviceSignature) != (SyncSignature.deviceSignature(for: stored)))

    let rescanned = await MetadataLoader.load(url: local.url)
    let retryLinks = SyncLedgerStore.resolveLinks(
      entries: entries, library: [rescanned], device: storedDB.tracks,
      libraryFolder: libraryDir)
    let retryPlan = SyncEngine.makePlan(
      library: [rescanned], device: storedDB.tracks, links: retryLinks)
    #expect((retryPlan.updateInFolder.count) == (1), Comment(rawValue: "the write-back must be retried"))
    #expect(retryPlan.updateOnDevice.isEmpty)
    #expect(retryPlan.copyToDevice.isEmpty)
    #expect(retryPlan.copyToFolder.isEmpty)
  }

  private func drifted(_ stamp: FileGenerationStamp) -> FileGenerationStamp {
    FileGenerationStamp(
      deviceID: stamp.deviceID &+ 1, inode: stamp.inode, sizeBytes: stamp.sizeBytes,
      modificationSeconds: stamp.modificationSeconds,
      modificationNanoseconds: stamp.modificationNanoseconds,
      changeSeconds: stamp.changeSeconds, changeNanoseconds: stamp.changeNanoseconds,
      generation: stamp.generation)
  }

  @Test
  func testRemountedVolumeDeviceIDDriftDoesNotClassifyLibraryAsChanged() async throws {
    let local = try makeLibraryMP3(title: "Steady", artist: "Band", album: "Album")
    var database = ITunesDatabase()
    database.tracks = [
      SyncEngine.makeDBTrack(from: local, ipodPath: ":iPod_Control:Music:F00:STDY.mp3")
    ]
    try fs.writeDatabase(database)
    let storedDB = try fs.readDatabase()
    let stored = try #require(storedDB.tracks.first)

    let stamp = try #require(FileGenerationStamp(url: local.url))
    let entry = SyncLedgerEntry(
      relativePath: local.url.lastPathComponent,
      dbid: stored.dbid,
      fileSize: stamp.sizeBytes,
      fileModifiedAt: stamp.modificationDate.timeIntervalSince1970,
      fileGenerationStamp: drifted(stamp),
      contentSHA256: try SyncSignature.fileSHA256(url: local.url),
      deviceSignature: SyncSignature.deviceSignature(for: stored))
    try SyncLedgerStore.replaceEntries(
      [entry], for: storedDB.databaseID, libraryFolder: libraryDir)

    let plan = try await makePlan()
    #expect(plan.updateOnDevice.isEmpty)
    #expect(plan.updateInFolder.isEmpty)
    #expect((plan.generationStampRevalidations.count) == (1))

    let databaseBytes = try Data(contentsOf: fs.databaseURL)
    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.updatedOnDevice) == (0))
    #expect((try Data(contentsOf: fs.databaseURL)) == (databaseBytes))

    let settled = try #require(SyncLedgerStore.entries(for: storedDB.databaseID, libraryFolder: libraryDir).first)
    #expect(
      (settled.fileGenerationStamp) == (stamp),
      Comment(rawValue: "the hash comparison settles the stamp onto the current device number"))

    let followup = try await makePlan()
    #expect(followup.isEmpty)
  }

  @Test
  func testRemountedVolumeDeviceIDDriftStillRoutesDeviceEditToWriteBack() async throws {
    let local = try makeLibraryMP3(title: "Edited", artist: "Band", album: "Old Album")

    var device = SyncEngine.makeDBTrack(
      from: local, ipodPath: ":iPod_Control:Music:F00:EDTD.mp3")
    let staleSignature = SyncSignature.deviceSignature(for: device)
    device.album = "New Album"
    var database = ITunesDatabase()
    database.tracks = [device]
    try fs.writeDatabase(database)
    let storedDB = try fs.readDatabase()
    let stored = try #require(storedDB.tracks.first)

    let stamp = try #require(FileGenerationStamp(url: local.url))
    let entry = SyncLedgerEntry(
      relativePath: local.url.lastPathComponent,
      dbid: stored.dbid,
      fileSize: stamp.sizeBytes,
      fileModifiedAt: stamp.modificationDate.timeIntervalSince1970,
      fileGenerationStamp: drifted(stamp),
      contentSHA256: try SyncSignature.fileSHA256(url: local.url),
      deviceSignature: staleSignature)
    try SyncLedgerStore.replaceEntries(
      [entry], for: storedDB.databaseID, libraryFolder: libraryDir)

    let plan = try await makePlan()
    #expect(plan.updateOnDevice.isEmpty)
    #expect((plan.updateInFolder.count) == (1), Comment(rawValue: "a device edit must win over a device-number drift"))
  }

  @Test
  func testFolderDestinationCollisionSuffixesAndSanitization() throws {
    var track = ITDBTrack()
    track.title = "Song"
    track.artist = "Artist"
    let source = URL(fileURLWithPath: "/tmp/a.mp3")

    try Data().write(to: libraryDir.appendingPathComponent("Artist - Song.mp3"))
    try Data().write(to: libraryDir.appendingPathComponent("Artist - Song 2.mp3"))
    let dest = SyncEngine.folderDestination(for: track, source: source, in: libraryDir)
    #expect((dest.lastPathComponent) == ("Artist - Song 3.mp3"))

    #expect((SyncEngine.sanitize("AC/DC: Back in Black")) == ("AC-DC- Back in Black"))
    let traversal = SyncEngine.sanitize("../../etc/passwd")
    #expect(!(traversal.contains("/")))
    #expect(!(traversal.hasPrefix(".")))

    track.title = "AC/DC: Back in Black"
    track.artist = "../../etc/passwd"
    let hostile = SyncEngine.folderDestination(for: track, source: source, in: libraryDir)
    #expect(hostile.standardizedFileURL.path.hasPrefix(libraryDir.path + "/"))
  }
}
