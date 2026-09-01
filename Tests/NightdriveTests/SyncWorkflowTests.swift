import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct SyncWorkflowTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  private enum TestError: Error {
    case persistenceFailed
  }

  private func effects(
    applyPlaylists:
      @escaping @Sendable (SyncResult, [LocalPlaylist]) async throws
      -> PlaylistSyncApplier.Outcome = { result, playlists in
        PlaylistSyncApplier.apply(result: result, to: playlists)
      },
    mergePlayback: @escaping @Sendable (DevicePlaybackReport) async throws -> Int = { _ in 0 }
  ) -> SyncWorkflow.LocalEffects {
    SyncWorkflow.LocalEffects(
      applyPlaylists: applyPlaylists, mergePlayback: mergePlayback)
  }

  @Test
  func testEngineAwaitsProgressDeliveryBeforeReturning() async throws {
    let progressStarted = WorkflowLatch()
    let releaseProgress = WorkflowLatch()
    let events = WorkflowEvents()
    let engine: SyncWorkflow.EngineExecutor = { _, _, _, progress in
      await events.append("engine-start")
      await progress(SyncProgress(step: 1, totalSteps: 1, detail: "Done"))
      await events.append("engine-finished")
      return SyncResult()
    }
    let deviceVolume = ipodDir
    let libraryFolder = libraryDir
    let localEffects = effects()

    let execution = Task {
      try await SyncWorkflow.execute(
        deviceVolume: deviceVolume,
        libraryFolder: libraryFolder,
        deviceName: "Test iPod",
        prepare: {
          SyncWorkflow.PreparedExecution(
            request: SyncExecutionRequest(librarySnapshot: []))
        },
        localEffects: localEffects,
        engine: engine
      ) { _ in
        await events.append("progress-start")
        await progressStarted.open()
        await releaseProgress.wait()
        await events.append("progress-finished")
      }
    }

    await progressStarted.wait()
    let blockedEvents = await events.values
    #expect((blockedEvents) == (["engine-start", "progress-start"]))
    await releaseProgress.open()
    _ = try await execution.value
    let completedEvents = await events.values
    #expect((completedEvents) == (["engine-start", "progress-start", "progress-finished", "engine-finished"]))
  }

  @Test
  func testPlaylistPersistenceFailureKeepsLinksAndOnTheGoSourceForRetry() async throws {
    let onTheGo = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try Data([0]).write(to: onTheGo)
    let playlist = LocalPlaylist(name: "Imported", trackIDs: [])
    let link = SyncPlaylistLink(
      localID: playlist.id, persistentID: 42, name: playlist.name, memberDbids: [])
    var engineResult = SyncResult()
    engineResult.syncedPlaylists = true
    engineResult.databaseID = 9
    engineResult.libraryPlaylistActions = [
      .updateInLibrary(localID: playlist.id, name: "Renamed", trackIDs: [])
    ]
    engineResult.playlistLinks = [link]
    engineResult.onTheGoFilesToDelete = [onTheGo]

    let result = await SyncWorkflow.finish(
      result: engineResult, initialPlaylists: [playlist],
      deviceVolume: ipodDir, libraryFolder: libraryDir, deviceName: "Test iPod",
      localEffects: effects(applyPlaylists: { _, _ in throw TestError.persistenceFailed }))

    #expect(FileManager.default.fileExists(atPath: onTheGo.path))
    #expect((SyncLedgerStore.playlistLinks(for: 9, libraryFolder: libraryDir)) == ([]))
    #expect(result.playlistNotes.last?.contains("could not be fully saved") == true)
    #expect((result.failures.count) == (1))
    #expect((result.failures[0].operation) == (.savePlaylists))
  }

  @Test
  func testPlaybackMergeFailureLeavesPendingAndDeviceFilesForRetry() async throws {
    let playCounts = fs.itunesDir.appendingPathComponent(PlayCountsFile.filename)
    try Data([0]).write(to: playCounts)
    let report = DevicePlaybackReport(databaseID: 17, entries: [])
    try PendingPlaybackReportStore.save(report, libraryFolder: libraryDir)
    var engineResult = SyncResult()
    engineResult.databaseID = 17
    engineResult.playbackReport = report
    engineResult.playCountsFilesToDelete = [playCounts]

    let result = await SyncWorkflow.finish(
      result: engineResult, initialPlaylists: [],
      deviceVolume: ipodDir, libraryFolder: libraryDir, deviceName: "Test iPod",
      localEffects: effects(mergePlayback: { _ in throw TestError.persistenceFailed }))

    #expect(FileManager.default.fileExists(atPath: playCounts.path))
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) != nil)
    #expect((result.failures.count) == (1))
    #expect((result.failures[0].operation) == (.mergePlayCounts))
  }

  @Test
  func testSuccessfulPlaybackMergeFinalizesFilesAndResult() async throws {
    let playCounts = fs.itunesDir.appendingPathComponent(PlayCountsFile.filename)
    try Data([0]).write(to: playCounts)
    let report = DevicePlaybackReport(databaseID: 23, entries: [])
    try PendingPlaybackReportStore.save(report, libraryFolder: libraryDir)
    var engineResult = SyncResult()
    engineResult.databaseID = 23
    engineResult.playbackReport = report
    engineResult.playCountsFilesToDelete = [playCounts]

    let result = await SyncWorkflow.finish(
      result: engineResult, initialPlaylists: [],
      deviceVolume: ipodDir, libraryFolder: libraryDir, deviceName: "Test iPod",
      localEffects: effects(mergePlayback: { _ in 2 }))

    #expect(!(FileManager.default.fileExists(atPath: playCounts.path)))
    #expect(try PendingPlaybackReportStore.load(libraryFolder: libraryDir) == nil)
    #expect((result.devicePlaysMerged) == (2))
    #expect((result.devicePlaybackNote) == ("Picked up 2 plays from Test iPod"))
    #expect((result.failures) == ([]))
  }

  @Test
  func testMalformedCLISidecarsStopWorkflowBeforeEngineMutation() async throws {
    let corrupt = Data("not json".utf8)
    let libraryFolder = libraryDir
    let deviceVolume = ipodDir
    let localEffects = effects()
    let calls = WorkflowEngineCalls()
    let engine: SyncWorkflow.EngineExecutor = { _, _, _, _ in
      await calls.record()
      return SyncResult()
    }
    let execute: @Sendable () async throws -> SyncResult = {
      try await SyncWorkflow.execute(
        deviceVolume: deviceVolume,
        libraryFolder: libraryFolder,
        deviceName: "Test iPod",
        prepare: {
          let playlists = try LocalPlaylistFile.load(libraryFolder: libraryFolder)
          _ = try ListeningHistoryFile.loadPayload(libraryFolder: libraryFolder)
          return SyncWorkflow.PreparedExecution(
            request: SyncExecutionRequest(librarySnapshot: [], localPlaylists: playlists))
        },
        localEffects: localEffects, engine: engine, progress: { _ in })
    }

    let playlistURL = LocalPlaylistFile.url(for: libraryFolder)
    try corrupt.write(to: playlistURL)
    do {
      _ = try await execute()
      Issue.record("Malformed playlists must stop CLI preparation")
    } catch {
      #expect(error is SidecarIntegrityError)
    }
    let callsAfterPlaylistFailure = await calls.count
    #expect((callsAfterPlaylistFailure) == (0))
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))

    try FileManager.default.removeItem(at: playlistURL)
    let historyURL = ListeningHistoryFile.url(for: libraryFolder)
    try corrupt.write(to: historyURL)
    do {
      _ = try await execute()
      Issue.record("Malformed history must stop CLI preparation")
    } catch {
      #expect(error is SidecarIntegrityError)
    }
    let callsAfterHistoryFailure = await calls.count
    #expect((callsAfterHistoryFailure) == (0))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))
  }

  @Test
  func testMalformedCLISidecarsAlsoBlockLateLocalEffectsWithoutOverwrite() async throws {
    let corrupt = Data("not json".utf8)
    let libraryFolder = libraryDir
    let deviceVolume = ipodDir
    let playlistURL = LocalPlaylistFile.url(for: libraryFolder)
    try corrupt.write(to: playlistURL)
    var playlistResult = SyncResult()
    playlistResult.syncedPlaylists = true
    playlistResult.databaseID = 0x41
    playlistResult.libraryPlaylistActions = [
      .createInLibrary(name: "Must not overwrite", trackIDs: [], persistentID: 0x51)
    ]
    let fileEffects = SyncWorkflow.LocalEffects(
      applyPlaylists: { result, playlists in
        let outcome = PlaylistSyncApplier.apply(result: result, to: playlists)
        if outcome.changedLibrary {
          _ = try LocalPlaylistFile.load(libraryFolder: libraryFolder)
          try LocalPlaylistFile.save(outcome.playlists, libraryFolder: libraryFolder)
        }
        return outcome
      },
      mergePlayback: { report in
        try ListeningHistoryFile.merge(report, libraryFolder: libraryFolder)
      })
    let blockedPlaylists = await SyncWorkflow.finish(
      result: playlistResult, initialPlaylists: [],
      deviceVolume: deviceVolume, libraryFolder: libraryFolder, deviceName: "Test iPod",
      localEffects: fileEffects)
    #expect((blockedPlaylists.failures.map(\.operation)) == ([.savePlaylists]))
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))

    let historyURL = ListeningHistoryFile.url(for: libraryFolder)
    try corrupt.write(to: historyURL)
    let playCountsURL = PlayCountsFile.url(in: fs)
    try Data([0]).write(to: playCountsURL)
    let report = DevicePlaybackReport(databaseID: 0x61, entries: [])
    try PendingPlaybackReportStore.save(report, libraryFolder: libraryFolder)
    var playbackResult = SyncResult()
    playbackResult.databaseID = report.databaseID
    playbackResult.playbackReport = report
    playbackResult.playCountsFilesToDelete = [playCountsURL]
    let blockedHistory = await SyncWorkflow.finish(
      result: playbackResult, initialPlaylists: [],
      deviceVolume: deviceVolume, libraryFolder: libraryFolder, deviceName: "Test iPod",
      localEffects: fileEffects)
    #expect((blockedHistory.failures.map(\.operation)) == ([.mergePlayCounts]))
    #expect((try Data(contentsOf: historyURL)) == (corrupt))
    #expect((try PendingPlaybackReportStore.load(libraryFolder: libraryFolder)) == (report))
    #expect(FileManager.default.fileExists(atPath: playCountsURL.path))
  }

  @Test
  func testDifferentDeviceWorkflowsRefreshWaiterAndPreserveAllLibrarySidecars() async throws {
    let libraryFolder = libraryDir
    let firstVolume = ipodDir
    let secondVolume = scratch.appendingPathComponent("SECOND-FAKEPOD", isDirectory: true)
    try FileManager.default.createDirectory(at: secondVolume, withIntermediateDirectories: true)

    let firstDatabaseID: UInt64 = 0xA001
    let secondDatabaseID: UInt64 = 0xB002
    let firstTrackURL = libraryFolder.appendingPathComponent("first-history.mp3")
    let secondTrackURL = libraryFolder.appendingPathComponent("second-history.mp3")
    let firstEngineStarted = WorkflowLatch()
    let releaseFirstEngine = WorkflowLatch()
    let observations = WorkflowPreparationObservations()

    let prepare: @Sendable (UInt64) async throws -> SyncWorkflow.PreparedExecution = {
      databaseID in
      let playlists = try LocalPlaylistFile.load(libraryFolder: libraryFolder)
      let history = try ListeningHistoryFile.loadPayload(libraryFolder: libraryFolder)
      await observations.record(
        databaseID: databaseID,
        playlistNames: playlists.map(\.name),
        appliedReportCount: history.appliedDeviceReportIDs.count)
      return SyncWorkflow.PreparedExecution(
        request: SyncExecutionRequest(librarySnapshot: [], localPlaylists: playlists),
        expectedDatabaseID: databaseID)
    }
    let engine: SyncWorkflow.EngineExecutor = {
      prepared, _, _, _ in
      let databaseID = try #require(prepared.expectedDatabaseID)
      if databaseID == firstDatabaseID {
        await firstEngineStarted.open()
        await releaseFirstEngine.wait()
      }

      let isFirst = databaseID == firstDatabaseID
      let name = isFirst ? "From first iPod" : "From second iPod"
      let persistentID: UInt64 = isFirst ? 0x101 : 0x202
      let localURL = isFirst ? firstTrackURL : secondTrackURL
      var result = SyncResult()
      result.syncedPlaylists = true
      result.databaseID = databaseID
      result.libraryPlaylistActions = [
        .createInLibrary(name: name, trackIDs: [], persistentID: persistentID)
      ]
      result.pendingPlaylistLinks = [
        SyncPlaylistLink(
          localID: UUID(), persistentID: persistentID, name: name, memberDbids: [])
      ]
      result.playbackReport = DevicePlaybackReport(
        databaseID: databaseID,
        entries: [
          DevicePlaybackReport.Entry(
            dbid: persistentID, localURL: localURL, playCountDelta: 1,
            lastPlayed: Date(timeIntervalSince1970: TimeInterval(databaseID)))
        ])
      return result
    }
    let localEffects = SyncWorkflow.LocalEffects(
      applyPlaylists: { result, playlists in
        let outcome = PlaylistSyncApplier.apply(result: result, to: playlists)
        if outcome.changedLibrary {
          try LocalPlaylistFile.save(outcome.playlists, libraryFolder: libraryFolder)
        }
        return outcome
      },
      mergePlayback: { report in
        try ListeningHistoryFile.merge(report, libraryFolder: libraryFolder)
      })

    let firstTask = Task {
      try await SyncWorkflow.execute(
        deviceVolume: firstVolume,
        libraryFolder: libraryFolder,
        deviceName: "first iPod",
        prepare: { try await prepare(firstDatabaseID) },
        localEffects: localEffects,
        engine: engine,
        progress: { _ in })
    }
    await firstEngineStarted.wait()

    let secondTask = Task {
      try await SyncWorkflow.execute(
        deviceVolume: secondVolume,
        libraryFolder: libraryFolder,
        deviceName: "second iPod",
        prepare: { try await prepare(secondDatabaseID) },
        localEffects: localEffects,
        engine: engine,
        progress: { _ in })
    }
    let onlyFirstCaptured = await holds(for: .milliseconds(50)) {
      await observations.databaseIDs == [firstDatabaseID]
    }
    #expect(onlyFirstCaptured, Comment(rawValue: "a waiting workflow must not capture stale library sidecars"))

    await releaseFirstEngine.open()
    let firstResult = try await firstTask.value
    let secondResult = try await secondTask.value
    #expect((firstResult.failures) == ([]))
    #expect((secondResult.failures) == ([]))

    let snapshots = await observations.snapshots
    #expect((snapshots.map(\.databaseID)) == ([firstDatabaseID, secondDatabaseID]))
    #expect((snapshots[0].playlistNames) == ([]))
    #expect((snapshots[0].appliedReportCount) == (0))
    #expect((snapshots[1].playlistNames) == (["From first iPod"]))
    #expect((snapshots[1].appliedReportCount) == (1))

    #expect(
      (Set(try LocalPlaylistFile.load(libraryFolder: libraryFolder).map(\.name)))
        == (Set(["From first iPod", "From second iPod"])))
    #expect(
      (SyncLedgerStore.playlistLinks(
        for: firstDatabaseID, libraryFolder: libraryFolder
      ).map(\.name)) == (["From first iPod"]))
    #expect(
      (SyncLedgerStore.playlistLinks(
        for: secondDatabaseID, libraryFolder: libraryFolder
      ).map(\.name)) == (["From second iPod"]))
    let history = try ListeningHistoryFile.loadPayload(libraryFolder: libraryFolder)
    #expect((history.metadataByID[TrackID(url: firstTrackURL).rawValue]?.playCount) == (1))
    #expect((history.metadataByID[TrackID(url: secondTrackURL).rawValue]?.playCount) == (1))
    #expect((history.appliedDeviceReportIDs.count) == (2))
  }
}

private actor WorkflowLatch {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isOpen else { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let continuations = waiters
    waiters.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

private actor WorkflowPreparationObservations {
  struct Snapshot: Sendable {
    var databaseID: UInt64
    var playlistNames: [String]
    var appliedReportCount: Int
  }

  private(set) var snapshots: [Snapshot] = []
  var databaseIDs: [UInt64] { snapshots.map(\.databaseID) }

  func record(databaseID: UInt64, playlistNames: [String], appliedReportCount: Int) {
    snapshots.append(
      Snapshot(
        databaseID: databaseID,
        playlistNames: playlistNames,
        appliedReportCount: appliedReportCount))
  }
}

private actor WorkflowEvents {
  private(set) var values: [String] = []

  func append(_ value: String) {
    values.append(value)
  }
}

private actor WorkflowEngineCalls {
  private(set) var count = 0

  func record() {
    count += 1
  }
}
