import Foundation

enum SyncWorkflow {
  struct PreparedExecution: Sendable {
    var request: SyncExecutionRequest
    var expectedDatabaseID: UInt64?
    var transcoding: TranscodeContext

    init(
      request: SyncExecutionRequest,
      expectedDatabaseID: UInt64? = nil,
      transcoding: TranscodeContext = TranscodeContext()
    ) {
      self.request = request
      self.expectedDatabaseID = expectedDatabaseID
      self.transcoding = transcoding
    }
  }

  struct LocalEffects: Sendable {
    var applyPlaylists: @Sendable (SyncResult, [LocalPlaylist]) async throws -> PlaylistSyncApplier.Outcome
    var mergePlayback: @Sendable (DevicePlaybackReport) async throws -> Int

    init(
      applyPlaylists:
        @escaping @Sendable (SyncResult, [LocalPlaylist]) async throws
        -> PlaylistSyncApplier.Outcome,
      mergePlayback: @escaping @Sendable (DevicePlaybackReport) async throws -> Int
    ) {
      self.applyPlaylists = applyPlaylists
      self.mergePlayback = mergePlayback
    }
  }

  typealias EngineExecutor =
    @Sendable (
      _ prepared: PreparedExecution,
      _ deviceVolume: URL,
      _ libraryFolder: URL,
      _ progress: @escaping @Sendable (SyncProgress) async -> Void
    ) async throws -> SyncResult

  private static let defaultEngine: EngineExecutor = {
    prepared, deviceVolume, libraryFolder, progress in
    try await SyncEngine.execute(
      request: prepared.request,
      deviceVolume: deviceVolume,
      libraryFolder: libraryFolder,
      expectedDatabaseID: prepared.expectedDatabaseID,
      transcoding: prepared.transcoding,
      progress: progress)
  }

  static func execute(
    deviceVolume: URL,
    libraryFolder: URL,
    deviceName: String,
    prepare: @escaping @Sendable () async throws -> PreparedExecution,
    localEffects: LocalEffects,
    beforePlaybackMerge: @escaping @Sendable () async throws -> Void = {},
    engine: @escaping EngineExecutor = defaultEngine,
    progress: @escaping @Sendable (SyncProgress) async -> Void
  ) async throws -> SyncResult {
    let workflowLock = try await ScopedAdvisoryLock.acquire(
      for: libraryFolder, namespace: .libraryWorkflow)
    defer { workflowLock.unlock() }

    let prepared = try await prepare()
    let result = try await engine(prepared, deviceVolume, libraryFolder, progress)
    return await finish(
      result: result, initialPlaylists: prepared.request.localPlaylists,
      deviceVolume: deviceVolume, libraryFolder: libraryFolder,
      deviceName: deviceName, localEffects: localEffects,
      beforePlaybackMerge: beforePlaybackMerge)
  }

  static func finish(
    result: SyncResult,
    initialPlaylists: [LocalPlaylist],
    deviceVolume: URL,
    libraryFolder: URL,
    deviceName: String,
    localEffects: LocalEffects,
    beforePlaybackMerge: @escaping @Sendable () async throws -> Void = {}
  ) async -> SyncResult {
    var result = result

    if result.syncedPlaylists {
      do {
        let outcome = try await localEffects.applyPlaylists(result, initialPlaylists)
        if let databaseID = result.databaseID {
          try await SyncEngine.writePlaylistLinks(
            outcome.links, databaseID: databaseID, libraryFolder: libraryFolder)
        }
        await SyncEngine.removeOnTheGoFiles(
          result.onTheGoFilesToDelete, deviceVolume: deviceVolume)
      } catch {
        result.playlistNotes.append(
          String(
            localized:
              "Playlist changes could not be fully saved: \(error.localizedDescription)"))
        result.fail(
          .savePlaylists, libraryFolder.path,
          String(
            localized:
              "Playlist changes were kept for the next sync (\(error.localizedDescription))."))
      }
    }

    guard result.playbackReport != nil || !result.playCountsFilesToDelete.isEmpty else {
      return result
    }

    do {
      try await beforePlaybackMerge()
    } catch {
      result.failures.append(playbackFailure(error, libraryFolder: libraryFolder))
      return result
    }

    if let report = result.playbackReport {
      do {
        let merged = try await localEffects.mergePlayback(report)
        if merged > 0 {
          result.devicePlaysMerged = merged
          result.devicePlaybackNote =
            merged == 1
            ? String(localized: "Picked up 1 play from \(deviceName)")
            : String(localized: "Picked up \(merged) plays from \(deviceName)")
        }
      } catch {
        result.failures.append(playbackFailure(error, libraryFolder: libraryFolder))
        return result
      }
    }

    // Delete device inputs only after local changes are durable.
    await SyncEngine.finalizeDevicePlaybackMerge(
      playCountsFiles: result.playCountsFilesToDelete,
      libraryFolder: libraryFolder, deviceVolume: deviceVolume,
      databaseID: result.databaseID)
    return result
  }

  private static func playbackFailure(_ error: Error, libraryFolder: URL) -> SyncFailure {
    SyncFailure(
      operation: .mergePlayCounts,
      path: PendingPlaybackReportStore.url(for: libraryFolder).path,
      reason: String(
        localized: "Device plays were kept for the next sync (\(error.localizedDescription))."))
  }
}
