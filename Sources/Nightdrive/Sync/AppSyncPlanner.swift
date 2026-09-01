import Foundation

@MainActor
final class AppSyncPlanner {
  private unowned let library: LibraryStore
  private unowned let playlists: PlaylistStore
  private unowned let listeningHistory: ListeningHistoryStore
  private var cache = SyncPlanCache()

  init(
    library: LibraryStore,
    playlists: PlaylistStore,
    listeningHistory: ListeningHistoryStore
  ) {
    self.library = library
    self.playlists = playlists
    self.listeningHistory = listeningHistory
  }

  /// Builds the potentially expensive device comparison away from the main
  /// actor. The UI can present the device immediately while ledger reads,
  /// signature comparisons, and capacity planning continue in the background.
  func previewAsync(
    device: IpodDevice,
    settings: SyncDeviceSettings,
    transcodeSettings: TranscodeSettings = TranscodeSettings.load()
  ) async -> SyncPlan {
    let libraryTracks = library.tracks
    let libraryRevision = library.derivedDataRevision
    let libraryFolder = library.folderURL
    let localPlaylists = playlists.playlists
    let playlistsRevision = playlists.revision
    let listeningMetadata = listeningHistory.metadataByID

    let factsWorker = Task.detached(priority: .userInitiated) {
      Self.smartRuleFacts(from: listeningMetadata)
    }
    let facts = await withTaskCancellationHandler {
      await factsWorker.value
    } onCancel: {
      factsWorker.cancel()
    }
    let scopeFacts: [String: SmartRuleFacts]
    if case .rules = settings.scope { scopeFacts = facts } else { scopeFacts = [:] }

    if let cached = cache.cachedPlan(
      libraryRevision: libraryRevision,
      playlistsRevision: playlistsRevision,
      transcodeSettings: transcodeSettings,
      deviceSettings: settings,
      scopeFacts: scopeFacts,
      device: device)
    {
      let worker = Task.detached(priority: .userInitiated) {
        Self.finish(
          cached,
          listeningMetadata: listeningMetadata,
          device: device,
          transcodeSettings: transcodeSettings)
      }
      return await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
    }

    let worker = Task.detached(priority: .userInitiated) {
      let plan = Self.compose(
        libraryTracks: libraryTracks,
        deviceTracks: device.tracks,
        libraryFolder: libraryFolder,
        device: device,
        scopeInput: SyncScopeInput(
          scope: settings.scope,
          trackSyncMode: settings.trackSyncMode,
          removesSongsNotInLibrary: settings.removesSongsNotInLibrary,
          removesSongsOutsideSyncScope: settings.removesSongsOutsideSyncScope,
          localPlaylists: localPlaylists,
          listeningFacts: facts),
        localPlaylists: localPlaylists,
        transcodeSettings: transcodeSettings)
      let finished = Self.finish(
        plan,
        listeningMetadata: listeningMetadata,
        device: device,
        transcodeSettings: transcodeSettings)
      return (plan, finished)
    }
    let (plan, finished) = await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
    if !Task.isCancelled {
      cache.store(
        plan,
        libraryRevision: libraryRevision,
        playlistsRevision: playlistsRevision,
        transcodeSettings: transcodeSettings,
        deviceSettings: settings,
        scopeFacts: scopeFacts,
        device: device)
    }
    return finished
  }

  func previewAsync(
    pinnedTo scopeInput: SyncScopeInput,
    device: IpodDevice,
    transcodeSettings: TranscodeSettings = TranscodeSettings.load()
  ) async -> SyncPlan {
    let libraryTracks = library.tracks
    let libraryFolder = library.folderURL
    let localPlaylists = playlists.playlists
    let listeningMetadata = listeningHistory.metadataByID
    let worker = Task.detached(priority: .userInitiated) {
      let plan = Self.compose(
        libraryTracks: libraryTracks,
        deviceTracks: device.tracks,
        libraryFolder: libraryFolder,
        device: device,
        scopeInput: scopeInput,
        localPlaylists: localPlaylists,
        transcodeSettings: transcodeSettings)
      return Self.finish(
        plan,
        listeningMetadata: listeningMetadata,
        device: device,
        transcodeSettings: transcodeSettings)
    }
    return await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
  }

  var smartRuleFacts: [String: SmartRuleFacts] {
    Self.smartRuleFacts(from: listeningHistory)
  }

  func invalidateCache() {
    cache = SyncPlanCache()
  }

  private static func smartRuleFacts(
    from listeningHistory: ListeningHistoryStore
  ) -> [String: SmartRuleFacts] {
    smartRuleFacts(from: listeningHistory.metadataByID)
  }

  nonisolated private static func smartRuleFacts(
    from metadata: [TrackID: TrackListeningMetadata]
  ) -> [String: SmartRuleFacts] {
    Dictionary(
      uniqueKeysWithValues:
        metadata
        .map { ($0.key.rawValue, SmartRuleFacts($0.value)) })
  }

  nonisolated private static func compose(
    libraryTracks: [LibraryTrack],
    deviceTracks: [ITDBTrack],
    libraryFolder: URL?,
    device: IpodDevice,
    scopeInput: SyncScopeInput,
    localPlaylists: [LocalPlaylist],
    transcodeSettings: TranscodeSettings
  ) -> SyncPlan {
    var links: [SyncLink] = []
    var playlistLinks: [SyncPlaylistLink] = []
    var trackLinks = PlaylistTrackLinks()
    if let libraryFolder, let databaseID = device.databaseID {
      let entries = SyncLedgerStore.entries(for: databaseID, libraryFolder: libraryFolder)
      links = SyncLedgerStore.resolveLinks(
        entries: entries,
        library: libraryTracks,
        device: deviceTracks,
        libraryFolder: libraryFolder)
      playlistLinks = SyncLedgerStore.playlistLinks(
        for: databaseID, libraryFolder: libraryFolder)
      trackLinks = PlaylistTrackLinks(entries: entries, libraryFolder: libraryFolder)
    }
    var plan = SyncEngine.makePlan(
      library: libraryTracks,
      device: deviceTracks,
      links: links,
      deviceFamily: device.family,
      transcodeSettings: transcodeSettings,
      scope: scopeInput)
    plan.localPlaylists = localPlaylists
    plan.playlistActions =
      SyncEngine.makePlaylistPlan(
        local: SyncScopeResolver.playlistsForReconciliation(
          localPlaylists, scope: scopeInput.scope),
        device: device.playlists,
        links: playlistLinks,
        trackLinks: trackLinks
      ).allActions
    return plan
  }

  nonisolated private static func finish(
    _ plan: SyncPlan,
    listeningMetadata: [TrackID: TrackListeningMetadata],
    device: IpodDevice,
    transcodeSettings: TranscodeSettings
  ) -> SyncPlan {
    var plan = plan
    plan.localRatings = Dictionary(
      uniqueKeysWithValues:
        listeningMetadata
        .filter { $0.value.rating > 0 }
        .map { ($0.key.rawValue, $0.value.rating) })
    plan.capacityShortfall = SyncCapacity.shortfall(
      plan: plan,
      availableCapacity: device.availableCapacity,
      family: device.family,
      settings: transcodeSettings)
    if let shortfall = plan.capacityShortfall {
      plan.suggestedCapacityTrim = SyncCapacity.suggestedTrim(
        plan: plan, shortfall: shortfall,
        family: device.family, settings: transcodeSettings)
    }
    return plan
  }
}
