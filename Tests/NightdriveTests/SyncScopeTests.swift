import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct SyncScopeTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }

  private struct LinkedRemovalFixture {
    let databaseID: UInt64
    let dbid: UInt64
    let ipodPath: String
    let libraryURL: URL
    let fileURL: URL
    let fileData: Data
    let plan: SyncPlan
  }

  private struct InjectedDirectorySyncFailure: LocalizedError {
    let point: IpodDeleteTransactionSyncPoint
    var errorDescription: String? { "Injected \(point) synchronization failure" }
  }

  private func scopeInput(
    _ scope: SyncScope, trackSyncMode: TrackSyncMode = .twoWay,
    allowsRemovals: Bool = false,
    facts: [String: SmartRuleFacts] = [:]
  ) -> SyncScopeInput {
    SyncScopeInput(
      scope: scope, trackSyncMode: trackSyncMode,
      removesSongsNotInLibrary: allowsRemovals,
      removesSongsOutsideSyncScope: allowsRemovals,
      localPlaylists: localPlaylists, listeningFacts: facts)
  }

  private func makePlan(scope: SyncScopeInput = SyncScopeInput()) async throws -> SyncPlan {
    try await makePlan(scope: scope, localPlaylists: localPlaylists)
  }

  private func makeLinkedRemovalFixture() async throws -> LinkedRemovalFixture {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    let remove = try writeLibraryMP3(filename: "remove.mp3", title: "Remove")
    var deviceTrack = try putTrackOnIpod(
      title: "Diverged Device Title", artist: "Different Artist", trackNumber: 7)
    deviceTrack.album = "Different Album"
    var database = ITunesDatabase()
    database.tracks = [deviceTrack]
    try fs.writeDatabase(database)
    database = try fs.readDatabase()
    let storedTrack = try #require(database.tracks.first)
    let ipodPath = try #require(storedTrack.ipodPath)
    let fileURL = try fs.validatedMusicFileURL(forIpodPath: ipodPath)
    let attributes = try FileManager.default.attributesOfItem(atPath: remove.path)
    let generationStamp = try #require(FileGenerationStamp(url: remove))
    let entry = SyncLedgerEntry(
      relativePath: remove.lastPathComponent,
      dbid: storedTrack.dbid,
      fileSize: try #require(attributes[.size] as? Int),
      fileModifiedAt: try #require(attributes[.modificationDate] as? Date)
        .timeIntervalSince1970,
      fileGenerationStamp: generationStamp,
      contentSHA256: try SyncSignature.fileSHA256(url: remove),
      deviceSignature: SyncSignature.deviceSignature(for: storedTrack))
    try SyncLedgerStore.replaceEntries(
      [entry], for: database.databaseID, libraryFolder: libraryDir)
    let plan = try await makePlan(
      scope: scopeInput(
        .playlists([]), trackSyncMode: .libraryToIpod, allowsRemovals: true))
    #expect((plan.removeFromDevice.map(\.dbid)) == ([storedTrack.dbid]))
    return LinkedRemovalFixture(
      databaseID: database.databaseID,
      dbid: storedTrack.dbid,
      ipodPath: ipodPath,
      libraryURL: remove,
      fileURL: fileURL,
      fileData: try Data(contentsOf: fileURL),
      plan: plan)
  }

  private func assertFailedRemovalRetained(
    _ result: SyncResult,
    fixture: LinkedRemovalFixture
  ) throws {
    #expect((result.removedFromDevice) == (0))
    #expect((result.failures.count) == (1))
    #expect((result.failures.first?.operation) == (.removeFromDevice))
    #expect((result.failures.first?.path) == (fixture.ipodPath))
    #expect(try fs.readDatabase().tracks.contains { $0.dbid == fixture.dbid })
    #expect(
      SyncLedgerStore.entries(for: fixture.databaseID, libraryFolder: libraryDir)
        .contains { $0.dbid == fixture.dbid })
  }

  private func assertDirectorySyncFailureRetainsMarkerAndRecovers(
    at failurePoint: IpodDeleteTransactionSyncPoint
  ) async throws {
    let fixture = try await makeLinkedRemovalFixture()

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard
            try transaction.stageMusicFileIfPresent(
              dbid: dbid,
              ipodPath: ipodPath,
              synchronizeDirectory: { descriptor, point in
                if point == failurePoint {
                  throw InjectedDirectorySyncFailure(point: point)
                }
                try DurableIO.synchronize(descriptor: descriptor)
              })
          else { return nil }
          return transaction
        }
      ))

    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect(result.failures[0].reason.contains("Injected"))
    #expect(!(FileManager.default.fileExists(atPath: fixture.fileURL.path)))
    #expect(
      FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path),
      Comment(rawValue: "the durable journal must remain after \(failurePoint)"))

    try fs.recoverInterruptedDeletions(database: fs.readDatabase())

    #expect((try Data(contentsOf: fixture.fileURL)) == (fixture.fileData))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testRemovalOnlySyncValidatesDatabaseBeforeStagingDeletion() async throws {
    let fixture = try await makeLinkedRemovalFixture()
    var unsupportedDatabase = try Data(contentsOf: fs.databaseURL)
    unsupportedDatabase[48] = 2
    unsupportedDatabase[49] = 0
    try unsupportedDatabase.write(to: fs.databaseURL)
    let removalStarted = Mutex(false)

    do {
      _ = try await runSync(
        request: SyncExecutionRequest(fixture.plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          removalStager: { _, _, _ in
            removalStarted.withLock { $0 = true }
            return nil
          }))
      Issue.record("expected the unsupported database format to reject the sync")
    } catch {
      guard case ITunesDBError.unsupportedDevice = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect(!(removalStarted.withLock { $0 }))
    #expect((try Data(contentsOf: fixture.fileURL)) == (fixture.fileData))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @discardableResult
  private func sync(scope: SyncScopeInput = SyncScopeInput()) async throws -> SyncResult {
    let result = try await runSync(try await makePlan(scope: scope))
    #expect((result.failures) == ([]))
    try await applyLocalPlaylistSyncEffects(result)
    return result
  }

  private func deviceMusicFiles() throws -> [URL] {
    let musicDir = ipodDir.appendingPathComponent("iPod_Control/Music")
    guard FileManager.default.fileExists(atPath: musicDir.path) else { return [] }
    var files: [URL] = []
    let enumerator = FileManager.default.enumerator(
      at: musicDir, includingPropertiesForKeys: nil)
    while let item = enumerator?.nextObject() as? URL {
      if item.pathExtension.lowercased() == "mp3" { files.append(item) }
    }
    return files
  }

  private func track(
    title: String, artist: String = "Artist", album: String = "Album",
    genre: String = "Rock", year: Int = 2004,
    ext: String = "mp3", sizeBytes: Int = 100_000, durationMS: Int = 2000
  ) -> LibraryTrack {
    LibraryTrack(
      url: libraryDir.appendingPathComponent("\(title).\(ext)"), title: title, artist: artist, album: album,
      genre: genre, trackNumber: 1, year: year, durationMS: durationMS, sizeBytes: sizeBytes, bitrate: 128,
      samplerate: 44100, modificationDate: Date())
  }

  @Test
  func testPlaylistScopeFiltersPlan() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "skip1.mp3", title: "Skip One")
    try writeLibraryMP3(filename: "skip2.mp3", title: "Skip Two")
    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]

    let plan = try await makePlan(scope: scopeInput(.playlists([chosen.id])))
    #expect((plan.copyToDevice.map(\.title)) == (["Keep"]))
    #expect((Set(plan.excludedByScope.map(\.title))) == (["Skip One", "Skip Two"]))
    #expect(plan.removeFromDevice.isEmpty)
    #expect(plan.outOfScopeOnDevice.isEmpty)
  }

  @Test
  func testRulesScopeFiltersPlan() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "rock.mp3", title: "Rock Song", genre: "Rock")
    try writeLibraryMP3(filename: "jazz.mp3", title: "Jazz Song", genre: "Jazz")

    let rule = SmartPlaylistRule(predicates: [.genreContains("Rock")])
    let plan = try await makePlan(scope: scopeInput(.rules(rule)))
    #expect((plan.copyToDevice.map(\.title)) == (["Rock Song"]))
    #expect((plan.excludedByScope.map(\.title)) == (["Jazz Song"]))
  }

  @Test
  func testOutOfScopeDeviceTracksPreservedWhenRemovalsOff() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "skip1.mp3", title: "Skip One")
    try writeLibraryMP3(filename: "skip2.mp3", title: "Skip Two")
    try await sync()
    #expect((try fs.readDatabase().tracks.count) == (3))

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    let scope = scopeInput(.playlists([chosen.id]), allowsRemovals: false)
    let plan = try await makePlan(scope: scope)
    #expect(plan.removeFromDevice.isEmpty)
    #expect((plan.outOfScopeOnDevice.count) == (2))
    #expect((Set(plan.excludedByScope.map(\.title))) == (["Skip One", "Skip Two"]))

    let result = try await sync(scope: scope)
    #expect((result.removedFromDevice) == (0))
    #expect((result.scopeNotes.count) == (1))
    #expect((try fs.readDatabase().tracks.count) == (3))
    #expect((try deviceMusicFiles().count) == (3))
  }

  @Test
  func testTwoWayNeverRemovesOutOfScopeDeviceTracks() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "skip.mp3", title: "Skip")
    try await sync()

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    var scope = scopeInput(.playlists([chosen.id]))
    scope.removesSongsNotInLibrary = true
    scope.removesSongsOutsideSyncScope = true

    let plan = try await makePlan(scope: scope)
    #expect((plan.scopeInput.trackSyncMode) == (.twoWay))
    #expect(plan.removeFromDevice.isEmpty)
    #expect((plan.outOfScopeOnDevice.map(\.title)) == (["Skip"]))

    let result = try await sync(scope: scope)
    #expect((result.removedFromDevice) == (0))
    #expect((try fs.readDatabase().tracks.count) == (2))
    #expect((try deviceMusicFiles().count) == (2))
  }

  @Test
  func testLibraryRemovalPoliciesAreIndependent() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "outside.mp3", title: "Outside Scope")
    try await sync()

    let deviceOnly = try putTrackOnIpod(
      title: "Not In Library", artist: "Device Artist", trackNumber: 1)
    var database = try fs.readDatabase()
    database.tracks.append(deviceOnly)
    try fs.writeDatabase(database)

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    var policy = scopeInput(.playlists([chosen.id]), trackSyncMode: .libraryToIpod)

    policy.removesSongsNotInLibrary = true
    var plan = try await makePlan(scope: policy)
    #expect((plan.removeFromDeviceNotInLibrary.map(\.title)) == (["Not In Library"]))
    #expect(plan.removeFromDeviceOutsideScope.isEmpty)
    #expect((plan.outOfScopeOnDevice.map(\.title)) == (["Outside Scope"]))

    policy.removesSongsNotInLibrary = false
    policy.removesSongsOutsideSyncScope = true
    plan = try await makePlan(scope: policy)
    #expect(plan.removeFromDeviceNotInLibrary.isEmpty)
    #expect((plan.removeFromDeviceOutsideScope.map(\.title)) == (["Outside Scope"]))
    #expect((plan.notInLibraryOnDevice.map(\.title)) == (["Not In Library"]))
  }

  @Test
  func testOutOfScopeDeviceTracksRemovedWhenConfirmed() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "skip1.mp3", title: "Skip One")
    try writeLibraryMP3(filename: "skip2.mp3", title: "Skip Two")
    try await sync()
    #expect((try fs.readDatabase().tracks.count) == (3))
    #expect((try deviceMusicFiles().count) == (3))

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    let scope = scopeInput(
      .playlists([chosen.id]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let plan = try await makePlan(scope: scope)
    #expect((plan.removeFromDevice.count) == (2))
    #expect(plan.outOfScopeOnDevice.isEmpty)

    let result = try await sync(scope: scope)
    #expect((result.removedFromDevice) == (2))
    let db = try fs.readDatabase()
    #expect((db.tracks.map(\.title)) == (["Keep"]))
    #expect((try deviceMusicFiles().count) == (1))
    let remainingDbids = Set(db.tracks.map(\.dbid))
    for playlist in db.playlists {
      #expect(Set(playlist.memberDbids).isSubset(of: remainingDbids))
    }
    #expect(FileManager.default.fileExists(atPath: keep.path))
    #expect(
      FileManager.default.fileExists(
        atPath: libraryDir.appendingPathComponent("skip1.mp3").path))

    let secondPlan = try await makePlan(scope: scope)
    #expect(secondPlan.isEmpty, Comment(rawValue: "\(secondPlan.removeFromDevice.map(\.title))"))
    #expect(secondPlan.removeFromDevice.isEmpty)
  }

  @Test
  func testRemovalValidationFailureKeepsRowFileAndPlaylistMembership() async throws {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "unsafe.mp3", title: "Unsafe")
    try writeLibraryMP3(filename: "stale.mp3", title: "Stale")

    func deviceTrack(_ title: String) throws -> ITDBTrack {
      var track = try putTrackOnIpod(title: title, artist: "Artist", trackNumber: 1)
      track.album = "Album"
      return track
    }
    var database = ITunesDatabase()
    database.tracks = try [deviceTrack("Keep"), deviceTrack("Unsafe"), deviceTrack("Stale")]
    try fs.writeDatabase(database)
    let unsafeIndex = try #require(database.tracks.firstIndex { $0.title == "Unsafe" })
    let staleIndex = try #require(database.tracks.firstIndex { $0.title == "Stale" })
    let unsafeDbid = database.tracks[unsafeIndex].dbid
    let staleDbid = database.tracks[staleIndex].dbid
    let unsafeIpodPath = try #require(database.tracks[unsafeIndex].ipodPath)
    let unsafeURL = try fs.validatedMusicFileURL(forIpodPath: unsafeIpodPath)
    let unsafeAudio = try Data(contentsOf: unsafeURL)
    let outsideURL = scratch.appendingPathComponent("outside-device-audio.mp3")
    try FileManager.default.moveItem(at: unsafeURL, to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: unsafeURL, withDestinationURL: outsideURL)

    // An iPod path that now resolves outside Music is unsafe to delete. A
    // genuinely pathless database row is stale and remains safe to prune.
    database.tracks[staleIndex].ipodPath = nil
    database.playlists = [
      ITDBPlaylist(
        name: "Removal Candidates", isMaster: false,
        memberDbids: [unsafeDbid, staleDbid])
    ]
    try fs.writeDatabase(database)

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    let scope = scopeInput(
      .playlists([chosen.id]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let plan = try await makePlan(scope: scope)
    #expect((Set(plan.removeFromDevice.map(\.dbid))) == ([unsafeDbid, staleDbid]))

    let result = try await runSync(plan)

    #expect((result.removedFromDevice) == (1))
    let failure = try #require(result.failures.first)
    #expect((result.failures.count) == (1))
    #expect((failure.operation) == (.removeFromDevice))
    #expect((failure.path) == (unsafeIpodPath))
    #expect(failure.reason.contains("symbolic link"), Comment(rawValue: failure.reason))

    let repaired = try fs.readDatabase()
    #expect(repaired.tracks.contains { $0.dbid == unsafeDbid })
    #expect(!(repaired.tracks.contains { $0.dbid == staleDbid }))
    #expect(
      repaired.playlists.allSatisfy { !$0.memberDbids.contains(staleDbid) },
      Comment(rawValue: "the stale row must leave every playlist"))
    #expect(
      (repaired.playlists.first { $0.name == "Removal Candidates" }?.memberDbids) == ([unsafeDbid]),
      Comment(rawValue: "the row whose file could not be validated must remain in its playlist"))
    #expect((try Data(contentsOf: outsideURL)) == (unsafeAudio))
    #expect(FileManager.default.fileExists(atPath: unsafeURL.path))
  }

  @Test
  func testRemovalValidationRejectsInTreeLeafSymlink() throws {
    let directory = fs.musicDir.appendingPathComponent("F00", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("TARGET.mp3")
    let link = directory.appendingPathComponent("LINK.mp3")
    let audio = Data("target audio".utf8)
    try audio.write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: (any Error).self) { try fs.validatedMusicFileURLIfPresent(forIpodPath: fs.ipodPath(for: link)) }
    #expect((try Data(contentsOf: target)) == (audio))
  }

  @Test
  func testRemovalValidationRejectsSymlinkedParent() throws {
    let realParent = fs.musicDir.appendingPathComponent("F01", isDirectory: true)
    let linkedParent = fs.musicDir.appendingPathComponent("F02", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    let target = realParent.appendingPathComponent("TARGET.mp3")
    try Data("target audio".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: linkedParent, withDestinationURL: realParent)

    let recorded = linkedParent.appendingPathComponent("TARGET.mp3")
    #expect(throws: (any Error).self) { try fs.validatedMusicFileURLIfPresent(forIpodPath: fs.ipodPath(for: recorded)) }
  }

  @Test
  func testRemovalValidationRejectsDanglingSymlinkedParent() throws {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    let linkedParent = fs.musicDir.appendingPathComponent("F03", isDirectory: true)
    let missingParent = fs.musicDir.appendingPathComponent("MISSING", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: linkedParent, withDestinationURL: missingParent)

    let recorded = linkedParent.appendingPathComponent("MISSING.mp3")
    #expect(throws: (any Error).self) { try fs.validatedMusicFileURLIfPresent(forIpodPath: fs.ipodPath(for: recorded)) }
  }

  @Test
  func testUnsafeLinkedRemovalRetainsIdentityAndRetries() async throws {
    let fixture = try await makeLinkedRemovalFixture()

    let outsideURL = scratch.appendingPathComponent("outside-linked-audio.mp3")
    try FileManager.default.moveItem(at: fixture.fileURL, to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: fixture.fileURL, withDestinationURL: outsideURL)

    let scope = scopeInput(
      .playlists([]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let failed = try await runSync(fixture.plan)
    #expect((failed.removedFromDevice) == (0))
    #expect((failed.failures.map(\.operation)) == ([.removeFromDevice]))
    #expect(try fs.readDatabase().tracks.contains { $0.dbid == fixture.dbid })

    let retained = SyncLedgerStore.entries(
      for: fixture.databaseID, libraryFolder: libraryDir
    )
    #expect(
      (retained.first { $0.dbid == fixture.dbid }?.relativePath)
        == (fixture.libraryURL.lastPathComponent))

    // Divergent tags cannot recover this pairing by tag matching. The
    // retained ledger identity is what keeps the next plan on the removal path.
    let retryPlan = try await makePlan(scope: scope)
    #expect((retryPlan.removeFromDevice.map(\.dbid)) == ([fixture.dbid]))
    #expect(!(retryPlan.copyToFolder.contains { $0.dbid == fixture.dbid }))

    // Once the unsafe link is removed, the same retained identity retries;
    // the now-safe missing device path is stale and can be pruned.
    try FileManager.default.removeItem(at: fixture.fileURL)
    let retried = try await runSync(retryPlan)
    #expect((retried.removedFromDevice) == (1))
    #expect((retried.failures) == ([]))
    #expect(!(try fs.readDatabase().tracks.contains { $0.dbid == fixture.dbid }))
    #expect(
      !(SyncLedgerStore.entries(for: fixture.databaseID, libraryFolder: libraryDir)
        .contains { $0.dbid == fixture.dbid }))
    #expect(FileManager.default.fileExists(atPath: outsideURL.path))
  }

  @Test
  func testLinkedRemovalStageFailureRetainsIdentityForRetry() async throws {
    struct InjectedFailure: Error {}

    let fixture = try await makeLinkedRemovalFixture()

    let scope = scopeInput(
      .playlists([]), trackSyncMode: .libraryToIpod, allowsRemovals: true)

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { _, _, _ in throw InjectedFailure() }
      ))
    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect((try Data(contentsOf: fixture.fileURL)) == (fixture.fileData))

    let retryPlan = try await makePlan(scope: scope)
    #expect((retryPlan.removeFromDevice.map(\.dbid)) == ([fixture.dbid]))
    #expect(!(retryPlan.copyToFolder.contains { $0.dbid == fixture.dbid }))
  }

  @Test
  func testRemovalParentSwapCannotRedirectStageOutsideMusic() async throws {
    let fixture = try await makeLinkedRemovalFixture()

    let recordedParent = fixture.fileURL.deletingLastPathComponent()
    let parkedParent = scratch.appendingPathComponent("parked-device-parent", isDirectory: true)
    let outsideParent = scratch.appendingPathComponent("outside-parent", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideParent, withIntermediateDirectories: true)
    let outsideURL = outsideParent.appendingPathComponent(fixture.fileURL.lastPathComponent)
    let outsideAudio = Data("outside audio must survive".utf8)
    try outsideAudio.write(to: outsideURL)

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          guard try fileSystem.validatedMusicFileURLIfPresent(forIpodPath: ipodPath) != nil else {
            throw ITunesDBError.notFound("race fixture is missing its validated source")
          }
          try FileManager.default.moveItem(at: recordedParent, to: parkedParent)
          try FileManager.default.createSymbolicLink(
            at: recordedParent, withDestinationURL: outsideParent)
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard try transaction.stageMusicFileIfPresent(dbid: dbid, ipodPath: ipodPath) else {
            throw ITunesDBError.notFound("race fixture unexpectedly became safely missing")
          }
          return transaction
        }
      ))

    #expect((result.removedFromDevice) == (0))
    let failure = try #require(result.failures.first)
    #expect((result.failures.count) == (1))
    #expect((failure.operation) == (.removeFromDevice))
    #expect((failure.path) == (fixture.ipodPath))
    #expect(failure.reason.contains("symbolic link"), Comment(rawValue: failure.reason))
    #expect((try Data(contentsOf: outsideURL)) == (outsideAudio))
    #expect(
      (try Data(contentsOf: parkedParent.appendingPathComponent(fixture.fileURL.lastPathComponent)))
        == (fixture.fileData))
    #expect(try fs.readDatabase().tracks.contains { $0.dbid == fixture.dbid })
    #expect(
      SyncLedgerStore.entries(for: fixture.databaseID, libraryFolder: libraryDir)
        .contains { $0.dbid == fixture.dbid })
  }

  @Test
  func testRemovalRegularFileSubstitutionAfterStatIsRestoredAndRejected() async throws {
    let fixture = try await makeLinkedRemovalFixture()
    let parkedOriginal = scratch.appendingPathComponent("parked-original.mp3")
    let substituteData = Data("substitute audio must survive".utf8)

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard
            try transaction.stageMusicFileIfPresent(
              dbid: dbid,
              ipodPath: ipodPath,
              afterSourceStat: {
                try FileManager.default.moveItem(at: fixture.fileURL, to: parkedOriginal)
                try substituteData.write(to: fixture.fileURL)
              })
          else { return nil }
          return transaction
        }
      ))

    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect(result.failures[0].reason.contains("changed"), Comment(rawValue: result.failures[0].reason))
    #expect((try Data(contentsOf: parkedOriginal)) == (fixture.fileData))
    #expect((try Data(contentsOf: fixture.fileURL)) == (substituteData))
  }

  @Test
  func testRemovalDirectorySubstitutionAfterStatPreservesItsTreeAndIsRejected() async throws {
    let fixture = try await makeLinkedRemovalFixture()
    let parkedOriginal = scratch.appendingPathComponent("parked-original.mp3")
    let nestedName = "nested/keep.txt"
    let nestedData = Data("substitute tree must survive".utf8)

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard
            try transaction.stageMusicFileIfPresent(
              dbid: dbid,
              ipodPath: ipodPath,
              afterSourceStat: {
                try FileManager.default.moveItem(at: fixture.fileURL, to: parkedOriginal)
                let nested = fixture.fileURL.appendingPathComponent(nestedName)
                try FileManager.default.createDirectory(
                  at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
                try nestedData.write(to: nested)
              })
          else { return nil }
          return transaction
        }
      ))

    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect(result.failures[0].reason.contains("changed"), Comment(rawValue: result.failures[0].reason))
    #expect((try Data(contentsOf: parkedOriginal)) == (fixture.fileData))
    #expect((try Data(contentsOf: fixture.fileURL.appendingPathComponent(nestedName))) == (nestedData))
  }

  @Test
  func testRemovalTransactionDirectorySwapCannotRedirectJournalOrStage() async throws {
    let fixture = try await makeLinkedRemovalFixture()
    let parkedTransaction = scratch.appendingPathComponent("parked-transaction", isDirectory: true)
    let outside = scratch.appendingPathComponent("outside-transaction-target", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let outsideJournal = outside.appendingPathComponent("journal.json")
    let sentinel = Data("outside journal sentinel".utf8)
    try sentinel.write(to: outsideJournal)

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard
            try transaction.stageMusicFileIfPresent(
              dbid: dbid,
              ipodPath: ipodPath,
              afterSourceStat: {
                try FileManager.default.moveItem(
                  at: transaction.directory, to: parkedTransaction)
                try FileManager.default.createSymbolicLink(
                  at: transaction.directory, withDestinationURL: outside)
              })
          else { return nil }
          return transaction
        }
      ))

    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect(
      result.failures[0].reason.contains("transaction directory changed"), Comment(rawValue: result.failures[0].reason))
    #expect((try Data(contentsOf: fixture.fileURL)) == (fixture.fileData))
    #expect((try Data(contentsOf: outsideJournal)) == (sentinel))
    #expect(
      FileManager.default.fileExists(
        atPath: parkedTransaction.appendingPathComponent("journal.json").path))
  }

  @Test
  func testRemovalSourceDirectorySyncFailureRetainsMarkerAndRecovers() async throws {
    try await assertDirectorySyncFailureRetainsMarkerAndRecovers(
      at: .sourceDirectoryAfterRename)
  }

  @Test
  func testRemovalTransactionDirectorySyncFailureRetainsMarkerAndRecovers() async throws {
    try await assertDirectorySyncFailureRetainsMarkerAndRecovers(
      at: .transactionDirectoryAfterRename)
  }

  @Test
  func testRemovalJournalDirectorySyncFailureDoesNotMoveTrackOrReportSuccess() async throws {
    let fixture = try await makeLinkedRemovalFixture()

    let result = try await runSync(
      request: SyncExecutionRequest(fixture.plan),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        removalStager: { fileSystem, dbid, ipodPath in
          let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
          guard
            try transaction.stageMusicFileIfPresent(
              dbid: dbid,
              ipodPath: ipodPath,
              synchronizeDirectory: { descriptor, point in
                if point == .journalDirectory {
                  throw InjectedDirectorySyncFailure(point: point)
                }
                try DurableIO.synchronize(descriptor: descriptor)
              })
          else { return nil }
          return transaction
        }
      ))

    try assertFailedRemovalRetained(result, fixture: fixture)
    #expect(result.failures[0].reason.contains("Injected"))
    #expect((try Data(contentsOf: fixture.fileURL)) == (fixture.fileData))
  }

  @Test
  func testPathfulMissingRemovalPrunesStaleRowAndPlaylistMembership() async throws {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "missing.mp3", title: "Missing")

    func deviceTrack(_ title: String) throws -> ITDBTrack {
      var track = try putTrackOnIpod(title: title, artist: "Artist", trackNumber: 1)
      track.album = "Album"
      return track
    }
    var database = ITunesDatabase()
    database.tracks = try [deviceTrack("Keep"), deviceTrack("Missing")]
    let missingIndex = try #require(database.tracks.firstIndex { $0.title == "Missing" })
    let missingDbid = database.tracks[missingIndex].dbid
    let missingIpodPath = try #require(database.tracks[missingIndex].ipodPath)
    database.playlists = [
      ITDBPlaylist(name: "Stale Rows", isMaster: false, memberDbids: [missingDbid])
    ]
    try fs.writeDatabase(database)
    let missingURL = try fs.validatedMusicFileURL(forIpodPath: missingIpodPath)
    try FileManager.default.removeItem(at: missingURL)

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    let scope = scopeInput(
      .playlists([chosen.id]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let plan = try await makePlan(scope: scope)
    #expect((plan.removeFromDevice.map(\.dbid)) == ([missingDbid]))

    let result = try await runSync(plan)
    #expect((result.removedFromDevice) == (1))
    #expect((result.failures) == ([]))

    let repaired = try fs.readDatabase()
    #expect(!(repaired.tracks.contains { $0.dbid == missingDbid }))
    #expect(repaired.playlists.allSatisfy { !$0.memberDbids.contains(missingDbid) })
    #expect(!(FileManager.default.fileExists(atPath: missingURL.path)))
  }

  @Test
  func testUnmatchedOnTheGoFileIsConsumedWhenSyncRemovesTracks() async throws {
    try fs.writeDatabase(ITunesDatabase())
    var urlsByTitle: [String: URL] = [:]
    for (index, title) in ["Song A", "Song B", "Song C"].enumerated() {
      urlsByTitle[title] = try writeLibraryMP3(
        filename: "song\(index).mp3", title: title, trackNumber: index + 1)
    }
    try await sync()
    let db = try fs.readDatabase()
    #expect((db.tracks.count) == (3))

    let removedTitle = try #require(db.tracks[0].title)
    let lastTitle = try #require(db.tracks[2].title)
    let keptURLs = db.tracks[1...].compactMap { $0.title.flatMap { urlsByTitle[$0] } }
    let chosen = LocalPlaylist(name: "Chosen", trackIDs: keptURLs.map(TrackID.init(url:)))
    localPlaylists = [chosen]

    let otgURL = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try otgData(indices: [0, 2]).write(to: otgURL)

    let scope = scopeInput(
      .playlists([chosen.id]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let result = try await sync(scope: scope)
    #expect((result.removedFromDevice) == (1))
    #expect(
      result.playlistNotes.contains { $0.contains("track order") }, Comment(rawValue: "got \(result.playlistNotes)"))
    #expect(
      !(FileManager.default.fileExists(atPath: otgURL.path)),
      Comment(rawValue: "the unmatchable On-The-Go file must be consumed, not retried against a reordered database"))
    #expect((result.onTheGoImports.count) == (1))
    #expect((result.onTheGoImports.first?.trackIDs) == ([TrackID(url: try #require(urlsByTitle[lastTitle]))]))

    let again = try await sync(scope: scope)
    #expect(again.onTheGoImports.isEmpty, Comment(rawValue: "\(again.onTheGoImports)"))
    let imported = localPlaylists.filter { $0.name.hasPrefix("On-The-Go") }
    #expect((imported.count) == (1))
    #expect(
      !(imported[0].trackIDs
        .contains(TrackID(url: try #require(urlsByTitle[removedTitle])))),
      Comment(rawValue: "the removed track's slot must never resolve to another song"))
  }

  @Test
  func testCapacityShortfallMath() throws {
    var plan = SyncPlan(librarySnapshot: [])
    plan.copyToDevice = [
      track(title: "A", sizeBytes: 1_000_000),
      track(title: "B", sizeBytes: 2_000_000),
    ]
    let settings = TranscodeSettings()
    let needed = 3_000_000 + 2 * SyncCapacity.artworkBytesPerTrack

    #expect(
      SyncCapacity.shortfall(
        plan: plan, availableCapacity: needed + SyncCapacity.reserveBytes + 1,
        family: .thirdGenerationOrLater, settings: settings) == nil)
    #expect(
      (SyncCapacity.shortfall(
        plan: plan, availableCapacity: needed + SyncCapacity.reserveBytes - 12_345,
        family: .thirdGenerationOrLater, settings: settings)) == (12_345))
    #expect(
      SyncCapacity.shortfall(
        plan: SyncPlan(librarySnapshot: []), availableCapacity: 0,
        family: .thirdGenerationOrLater, settings: settings) == nil)
  }

  @Test
  func testTrimCannotRecoverAnUpdateOnlyShortfall() throws {
    let settings = TranscodeSettings()
    let family = IpodDeviceFamily.thirdGenerationOrLater
    let updated = track(title: "Updated", sizeBytes: 5_000_000)
    let entry = SyncLedgerEntry(
      relativePath: "updated.mp3", dbid: 1, fileSize: 1, fileModifiedAt: 0,
      fileGenerationStamp: FileGenerationStamp(
        deviceID: 1, inode: 1, sizeBytes: 1, modificationSeconds: 0,
        modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0, generation: nil),
      contentSHA256: "abc", deviceSignature: "sig")
    var plan = SyncPlan(librarySnapshot: [])
    plan.updateOnDevice = [SyncDeviceUpdate(local: updated, device: ITDBTrack(), entry: entry)]
    let available = SyncCapacity.reserveBytes + 1_000_000

    #expect(
      SyncCapacity.shortfall(
        plan: plan, availableCapacity: available, family: family, settings: settings)
        == 4_000_000)
    #expect(
      !SyncCapacity.trimCanRecover(
        plan: plan, availableCapacity: available, family: family, settings: settings),
      Comment(rawValue: "dropping zero copies can never recover an update-only shortfall"))

    plan.copyToDevice = [track(title: "New", sizeBytes: 2_000_000)]
    #expect(
      !SyncCapacity.trimCanRecover(
        plan: plan, availableCapacity: available, family: family, settings: settings),
      Comment(rawValue: "copies that fit alongside an oversized update do not help"))

    plan.updateOnDevice = []
    #expect(
      SyncCapacity.trimCanRecover(
        plan: plan, availableCapacity: available, family: family, settings: settings))
    #expect(
      SyncCapacity.trimCanRecover(
        plan: plan, availableCapacity: 0, family: family, settings: settings),
      Comment(rawValue: "leaving every copy out always fits when nothing else is planned"))
  }

  @Test
  func testTranscodeEstimateUsesBitrateTimesDuration() throws {
    let settings = TranscodeSettings()
    let flac = track(title: "Big", ext: "flac", sizeBytes: 50_000_000, durationMS: 60_000)
    #expect(
      (SyncCapacity.estimatedBytes(
        for: flac, family: .thirdGenerationOrLater, settings: settings))
        == (Int64(settings.aacProfile.bitrateKbps) * 60_000 / 8))
    let mp3 = track(title: "Small", sizeBytes: 123_456)
    #expect(
      (SyncCapacity.estimatedBytes(
        for: mp3, family: .thirdGenerationOrLater, settings: settings)) == (123_456))
  }

  @Test
  func testSuggestedTrimOrdering() throws {
    let loved = track(title: "Loved", sizeBytes: 1_000_000)
    let stale = track(title: "Stale", sizeBytes: 1_000_000)
    let unplayed = track(title: "Unplayed", sizeBytes: 1_000_000)
    var plan = SyncPlan(librarySnapshot: [])
    plan.copyToDevice = [loved, stale, unplayed]
    plan.scopeInput.listeningFacts = [
      loved.id.rawValue: SmartRuleFacts(
        rating: 5, playCount: 40, lastPlayedAt: Date()),
      stale.id.rawValue: SmartRuleFacts(
        rating: 1, playCount: 2, lastPlayedAt: Date(timeIntervalSinceNow: -86_400)),
      unplayed.id.rawValue: SmartRuleFacts(rating: 1, playCount: 0),
    ]
    let settings = TranscodeSettings()

    let all = SyncCapacity.suggestedTrim(
      plan: plan, shortfall: .max, family: .thirdGenerationOrLater, settings: settings)
    #expect((all.map(\.title)) == (["Unplayed", "Stale", "Loved"]))

    let one = SyncCapacity.suggestedTrim(
      plan: plan, shortfall: 500_000, family: .thirdGenerationOrLater, settings: settings)
    #expect((one.map(\.title)) == (["Unplayed"]))
  }

  @Test
  func testSmartRulePredicates() throws {
    let rock = track(
      title: "Anthem", artist: "The Kinks", album: "Arthur", genre: "Rock", year: 1969)
    let now = Date()
    func matches(
      _ predicate: SmartPlaylistPredicate, track: LibraryTrack = rock,
      facts: SmartRuleFacts = SmartRuleFacts(), dateAdded: Date? = nil
    ) -> Bool {
      SmartPlaylistEvaluator.matches(
        SmartPlaylistRule(predicates: [predicate]),
        track: track, facts: facts, dateAdded: dateAdded, now: now)
    }

    #expect(matches(.artistContains("kinks")))
    #expect(!(matches(.artistContains("beatles"))))
    #expect(matches(.albumContains("ARTHUR")))
    #expect(!(matches(.albumContains("Abbey"))))
    #expect(matches(.genreContains("rock")))
    #expect(!(matches(.genreContains("Jazz"))))
    #expect(matches(.yearBetween(minimum: 1960, maximum: 1970)))
    #expect(matches(.yearBetween(minimum: nil, maximum: 1969)))
    #expect(matches(.yearBetween(minimum: 1969, maximum: nil)))
    #expect(!(matches(.yearBetween(minimum: 1970, maximum: nil))))
    #expect(!(matches(.yearBetween(minimum: nil, maximum: nil), track: track(title: "NoYear", year: 0))))
    #expect(matches(.ratingAtLeast(3), facts: SmartRuleFacts(rating: 4)))
    #expect(!(matches(.ratingAtLeast(3), facts: SmartRuleFacts(rating: 2))))
    #expect(matches(.playCountAtLeast(10), facts: SmartRuleFacts(playCount: 10)))
    #expect(!(matches(.playCountAtLeast(10), facts: SmartRuleFacts(playCount: 9))))
    #expect(matches(.addedWithinDays(7), dateAdded: now.addingTimeInterval(-3 * 86_400)))
    #expect(!(matches(.addedWithinDays(7), dateAdded: now.addingTimeInterval(-8 * 86_400))))
    #expect(!(matches(.addedWithinDays(7), dateAdded: nil)))
    #expect(matches(.favorite, facts: SmartRuleFacts(isFavorite: true)))
    #expect(!(matches(.favorite, facts: SmartRuleFacts(isFavorite: false))))
    #expect(matches(.format(.mp3)))
    #expect(!(matches(.format(.flac))))

    #expect(
      SmartPlaylistEvaluator.matches(
        SmartPlaylistRule(predicates: [.artistContains("Kinks"), .genreContains("Rock")]),
        track: rock, facts: SmartRuleFacts(), dateAdded: nil, now: now))
    #expect(
      !(SmartPlaylistEvaluator.matches(
        SmartPlaylistRule(predicates: [.artistContains("Kinks"), .genreContains("Jazz")]),
        track: rock, facts: SmartRuleFacts(), dateAdded: nil, now: now)))
    #expect(
      SmartPlaylistEvaluator.matches(
        SmartPlaylistRule(), track: rock, facts: SmartRuleFacts(), dateAdded: nil, now: now))
  }

  @Test
  func testSmartRuleEvaluationIsDeterministicAndStableOrdered() throws {
    let tracks = [
      track(title: "Zeta", artist: "Band B", album: "Later"),
      track(title: "Alpha", artist: "Band A", album: "First"),
      track(title: "Beta", artist: "Band A", album: "First"),
      track(title: "Gamma", artist: "Band A", album: "Second"),
    ]
    let rule = SmartPlaylistRule(predicates: [.genreContains("Rock")])
    let sorted = SmartPlaylistEvaluator.evaluate(rule, library: tracks, facts: [:])
    #expect((sorted.map(\.title)) == (["Alpha", "Beta", "Gamma", "Zeta"]))
    for _ in 0..<5 {
      let shuffled = SmartPlaylistEvaluator.evaluate(
        rule, library: tracks.shuffled(), facts: [:])
      #expect((shuffled.map(\.title)) == (sorted.map(\.title)))
    }
  }

  @Test
  func testSmartPlaylistMaterializesOntoDeviceAndUpdates() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "rock1.mp3", title: "Rock One", genre: "Rock")
    try writeLibraryMP3(filename: "jazz.mp3", title: "Jazz Song", genre: "Jazz")

    let rule = SmartPlaylistRule(predicates: [.genreContains("Rock")])
    var smart = LocalPlaylist(name: "Rockers", trackIDs: [], smartRule: rule)
    smart.trackIDs = SmartPlaylistEvaluator.evaluate(
      rule, library: await scanLibrary(), facts: [:]
    ).map(\.id)
    localPlaylists = [smart]

    try await sync()
    var db = try fs.readDatabase()
    var devicePlaylist = try #require(db.playlists.first { $0.name == "Rockers" })
    #expect((devicePlaylist.memberDbids.count) == (1))
    #expect((localPlaylists.first?.smartRule) == (rule))

    try writeLibraryMP3(filename: "rock2.mp3", title: "Rock Two", genre: "Rock")
    let refreshed = SmartPlaylistEvaluator.refresh(
      localPlaylists, library: await scanLibrary(), facts: [:])
    #expect(refreshed.changed)
    localPlaylists = refreshed.playlists

    try await sync()
    db = try fs.readDatabase()
    devicePlaylist = try #require(db.playlists.first { $0.name == "Rockers" })
    #expect((devicePlaylist.memberDbids.count) == (2))

    let again = SmartPlaylistEvaluator.refresh(
      localPlaylists, library: await scanLibrary(), facts: [:])
    #expect(!(again.changed))
  }

  @Test
  func testUnchangedLibraryIsZeroWriteWithRulesScope() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "rock1.mp3", title: "Rock One", genre: "Rock")
    try writeLibraryMP3(filename: "rock2.mp3", title: "Rock Two", genre: "Rock")
    try writeLibraryMP3(filename: "jazz.mp3", title: "Jazz Song", genre: "Jazz")

    let rule = SmartPlaylistRule(predicates: [.genreContains("Rock")])
    let first = try await sync(scope: scopeInput(.rules(rule)))
    #expect((first.copiedToDevice) == (2))

    let dbURL = fs.databaseURL
    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    let dbBefore = try modificationDate(of: dbURL)
    let ledgerBefore = try Data(contentsOf: ledgerURL)

    let plan = try await makePlan(scope: scopeInput(.rules(rule)))
    #expect(plan.isEmpty)
    #expect((plan.excludedByScope.map(\.title)) == (["Jazz Song"]))

    let second = try await sync(scope: scopeInput(.rules(rule)))
    #expect((second.copiedToDevice) == (0))
    #expect((second.removedFromDevice) == (0))
    #expect((try modificationDate(of: dbURL)) == (dbBefore), Comment(rawValue: "database rewritten on no-op sync"))
    #expect((try Data(contentsOf: ledgerURL)) == (ledgerBefore), Comment(rawValue: "ledger rewritten on no-op sync"))
  }

  @Test
  func testDeviceSettingsRoundTrip() throws {
    let databaseID: UInt64 = 0xDEAD_BEEF
    var settings = SyncDeviceSettings()

    let playlistID = UUID()
    settings = SyncDeviceSettings(
      scope: .playlists([playlistID]), trackSyncMode: .libraryToIpod,
      removesSongsNotInLibrary: true, removesSongsOutsideSyncScope: false)
    try SyncLedgerStore.replaceDeviceSettings(
      settings, for: databaseID, libraryFolder: libraryDir)
    #expect((SyncLedgerStore.deviceSettings(for: databaseID, libraryFolder: libraryDir)) == (settings))

    let rule = SmartPlaylistRule(predicates: [
      .genreContains("Rock"), .ratingAtLeast(3), .yearBetween(minimum: 1990, maximum: nil),
    ])
    settings = SyncDeviceSettings(scope: .rules(rule), trackSyncMode: .ipodToLibrary)
    try SyncLedgerStore.replaceDeviceSettings(
      settings, for: databaseID, libraryFolder: libraryDir)
    #expect((SyncLedgerStore.deviceSettings(for: databaseID, libraryFolder: libraryDir)) == (settings))

    try SyncLedgerStore.replaceDeviceSettings(
      SyncDeviceSettings(), for: databaseID, libraryFolder: libraryDir)
  }

  @Test
  func testLibraryToIpodModeReplacesUnlinkedLegacyTrackWithoutImportingIt() async throws {
    let oldDeviceTrack = try putTrackOnIpod(
      title: "Original", artist: "Artist", trackNumber: 1)
    var database = ITunesDatabase()
    database.tracks = [oldDeviceTrack]
    try fs.writeDatabase(database)
    try writeLibraryMP3(
      filename: "Artist - Original.mp3", title: "Corrected", artist: "Correct Artist")

    var mode = SyncScopeInput(trackSyncMode: .libraryToIpod)
    let safePlan = try await makePlan(scope: mode)
    #expect((safePlan.copyToDevice.map(\.title)) == (["Corrected"]))
    #expect(safePlan.copyToFolder.isEmpty)
    #expect(safePlan.removeFromDevice.isEmpty)
    #expect((safePlan.notInLibraryOnDevice.count) == (1))

    mode.removesSongsNotInLibrary = true
    let mirrorPlan = try await makePlan(scope: mode)
    #expect((mirrorPlan.copyToDevice.map(\.title)) == (["Corrected"]))
    #expect(mirrorPlan.copyToFolder.isEmpty)
    #expect((mirrorPlan.removeFromDevice.count) == (1))

    let result = try await runSync(mirrorPlan)
    #expect((result.copiedToDevice) == (1))
    #expect((result.copiedToFolder) == (0))
    #expect((result.removedFromDevice) == (1))
    #expect((result.failures) == ([]))
    #expect((try fs.readDatabase().tracks.map(\.title)) == (["Corrected"]))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).count) == (1))
  }

  @Test
  func testLibraryToIpodModeRestoresLinkedDeviceMetadata() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "song.mp3", title: "Library Title", artist: "Artist")
    _ = try await runSync(try await makePlan())

    var database = try fs.readDatabase()
    let dbid = try #require(database.tracks.first).dbid
    database.tracks[0].title = "Edited On iPod"
    try fs.writeDatabase(database)

    let mode = SyncScopeInput(trackSyncMode: .libraryToIpod)
    let plan = try await makePlan(scope: mode)
    #expect((plan.updateOnDevice.count) == (1))
    #expect(plan.updateInFolder.isEmpty)
    #expect(plan.copyToFolder.isEmpty)

    let result = try await runSync(plan)
    #expect((result.updatedOnDevice) == (1))
    #expect((result.updatedInFolder) == (0))
    #expect((result.failures) == ([]))
    let restored = try #require(try fs.readDatabase().tracks.first)
    #expect((restored.dbid) == (dbid))
    #expect((restored.title) == ("Library Title"))
  }

  @Test
  func testIpodToLibraryModeImportsDeviceOnlyAndKeepsLibraryOnlyTracks() async throws {
    let deviceTrack = try putTrackOnIpod(
      title: "From iPod", artist: "Device Artist", trackNumber: 1)
    var database = ITunesDatabase()
    database.tracks = [deviceTrack]
    try fs.writeDatabase(database)
    try writeLibraryMP3(filename: "local.mp3", title: "Library Only", artist: "Local Artist")
    let databaseBefore = try Data(contentsOf: fs.databaseURL)

    let mode = SyncScopeInput(
      trackSyncMode: .ipodToLibrary, removesSongsNotInLibrary: true,
      removesSongsOutsideSyncScope: true)
    let plan = try await makePlan(scope: mode)
    #expect((plan.copyToFolder.map(\.title)) == (["From iPod"]))
    #expect((plan.localOnlyInLibrary.map(\.title)) == (["Library Only"]))
    #expect(plan.copyToDevice.isEmpty)
    #expect(plan.updateOnDevice.isEmpty)
    #expect(plan.removeFromDevice.isEmpty)

    let result = try await runSync(plan)
    #expect((result.copiedToFolder) == (1))
    #expect((result.copiedToDevice) == (0))
    #expect((result.updatedOnDevice) == (0))
    #expect((result.removedFromDevice) == (0))
    #expect((result.failures) == ([]))
    #expect((try Data(contentsOf: fs.databaseURL)) == (databaseBefore))
    #expect((LibraryStore.findAudioFiles(in: libraryDir).count) == (2))

    let followUp = try await makePlan(scope: mode)
    #expect(followUp.isEmpty)
    #expect((followUp.localOnlyInLibrary.map(\.title)) == (["Library Only"]))
  }

  @Test
  func testIpodToLibraryModeRestoresLinkedLibraryMetadata() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let localURL = try writeLibraryMP3(
      filename: "song.mp3", title: "iPod Title", artist: "Artist")
    _ = try await runSync(try await makePlan())
    let databaseBefore = try Data(contentsOf: fs.databaseURL)

    var metadata = TrackMetadata(await MetadataLoader.load(url: localURL))
    metadata.title = "Edited In Library"
    try MP3MetadataWriter.write(metadata, artworkChange: .unchanged, to: localURL)

    let mode = SyncScopeInput(trackSyncMode: .ipodToLibrary)
    let plan = try await makePlan(scope: mode)
    #expect((plan.updateInFolder.count) == (1))
    #expect(plan.updateOnDevice.isEmpty)
    #expect(plan.copyToDevice.isEmpty)
    #expect(plan.removeFromDevice.isEmpty)

    let result = try await runSync(plan)
    #expect((result.updatedInFolder) == (1))
    #expect((result.updatedOnDevice) == (0))
    #expect((result.failures) == ([]))
    let restoredMetadata = await MetadataLoader.load(url: localURL)
    #expect((restoredMetadata.title) == ("iPod Title"))
    #expect((try Data(contentsOf: fs.databaseURL)) == (databaseBefore))
  }

  @Test
  func testConfirmedRemovalPinRestrictsRemovals() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let keep = try writeLibraryMP3(filename: "keep.mp3", title: "Keep")
    try writeLibraryMP3(filename: "skip1.mp3", title: "Skip One")
    try writeLibraryMP3(filename: "skip2.mp3", title: "Skip Two")
    try await sync()

    let chosen = LocalPlaylist(name: "Chosen", trackIDs: [TrackID(url: keep)])
    localPlaylists = [chosen]
    var scope = scopeInput(
      .playlists([chosen.id]), trackSyncMode: .libraryToIpod, allowsRemovals: true)
    let unrestricted = try await makePlan(scope: scope)
    #expect((unrestricted.removeFromDevice.count) == (2))

    let confirmed = try #require(unrestricted.removeFromDevice.first)
    scope.confirmedRemovalDbids = [confirmed.dbid]
    let pinned = try await makePlan(scope: scope)
    #expect((pinned.removeFromDevice.map(\.dbid)) == ([confirmed.dbid]))
    #expect((pinned.outOfScopeOnDevice.count) == (1))

    let result = try await sync(scope: scope)
    #expect((result.removedFromDevice) == (1))
    let db = try fs.readDatabase()
    #expect((db.tracks.count) == (2))
    #expect(!(db.tracks.map(\.dbid).contains(confirmed.dbid)))
    #expect((try deviceMusicFiles().count) == (2))
  }

  @Test
  func testSyncAbortsWhenConfirmedRemovalsNoLongerCoverThePlan() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try writeLibraryMP3(filename: "two.mp3", title: "Two")
    try await sync()

    try await Self.assertSyncAbortsWhenConfirmedRemovalsChange(
      libraryFolder: libraryDir,
      deviceVolume: ipodDir)
  }

  @MainActor
  private static func assertSyncAbortsWhenConfirmedRemovalsChange(
    libraryFolder: URL, deviceVolume: URL
  ) async throws {
    let library = LibraryStore(folderURL: libraryFolder)
    await library.rescan()
    let app = AppState(
      library: library,
      playlists: PlaylistStore(persistence: MemoryPersistence()),
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    let fs = IpodFileSystem(volumeURL: deviceVolume)
    let db = try fs.readDatabase()
    let device = IpodDevice(
      volumeURL: deviceVolume, databaseID: db.databaseID, name: "Test iPod",
      modelDescription: "iPod mini", totalCapacity: 4_000_000_000,
      availableCapacity: 1_000_000_000, tracks: db.tracks)
    app.updateSyncSettings(for: device) {
      $0.scope = .rules(SmartPlaylistRule(predicates: [.artistContains("Nobody")]))
      $0.trackSyncMode = .libraryToIpod
    }
    app.updateSyncSettings(for: device) { $0.removesSongsOutsideSyncScope = true }
    let plan = await app.syncPlanAsync(for: device)
    #expect((plan.removeFromDevice.count) == (2))

    let confirmedOne: Set<UInt64> = [plan.removeFromDevice[0].dbid]
    app.sync(
      device,
      options: AppState.SyncDispatchOptions(
        confirmRemovals: true,
        confirmedScopeInput: plan.scopeInput,
        confirmedRemovalDbids: confirmedOne))
    await waitUntil { !app.syncState.isSyncing }
    guard case .failed(let message) = app.syncState else {
      Issue.record("expected the sync to refuse, got \(app.syncState)")
      return
    }
    #expect(message.contains("changed after it was confirmed"), Comment(rawValue: message))
    #expect((try fs.readDatabase().tracks.count) == (2))
    #expect((try deviceMusicFiles(at: deviceVolume).count) == (2))
  }

  private static func deviceMusicFiles(at deviceVolume: URL) throws -> [URL] {
    let musicDirectory = deviceVolume.appendingPathComponent("iPod_Control/Music")
    guard FileManager.default.fileExists(atPath: musicDirectory.path) else { return [] }
    let enumerator = FileManager.default.enumerator(
      at: musicDirectory, includingPropertiesForKeys: nil)
    var files: [URL] = []
    while let item = enumerator?.nextObject() as? URL {
      if item.pathExtension.lowercased() == "mp3" { files.append(item) }
    }
    return files
  }

  @MainActor
  @Test
  func testQuickSuccessiveSettingsMutationsBothPersist() async throws {
    let library = LibraryStore(folderURL: libraryDir)
    let app = AppState(
      library: library,
      playlists: PlaylistStore(persistence: MemoryPersistence()),
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    let databaseID: UInt64 = 0xFEED_F00D
    let device = IpodDevice(
      volumeURL: ipodDir, databaseID: databaseID, name: "Test iPod",
      modelDescription: "iPod mini", totalCapacity: 4_000_000_000,
      availableCapacity: 1_000_000_000)
    let chosen = UUID()

    app.updateSyncSettings(for: device) { $0.scope = .playlists([chosen]) }
    app.updateSyncSettings(for: device) { $0.removesSongsNotInLibrary = true }
    app.updateSyncSettings(for: device) { $0.removesSongsOutsideSyncScope = true }

    let expected = SyncDeviceSettings(
      scope: .playlists([chosen]), removesSongsNotInLibrary: true,
      removesSongsOutsideSyncScope: true)
    #expect((app.syncSettings(for: device)) == (expected))
    await app.flushSyncSettingsWrites()
    #expect((SyncLedgerStore.deviceSettings(for: databaseID, libraryFolder: libraryDir)) == (expected))
  }

  private final class MemoryPersistence: AppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    var data: Data? {
      get { stored.withLock { $0 } }
      set { stored.withLock { $0 = newValue } }
    }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
  }
}
