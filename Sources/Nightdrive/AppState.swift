import Observation
import SwiftUI

enum SidebarItem: Hashable {
  case library
  case artists
  case albums
  case genres
  case audiobooks
  case upNext
  case playlists
  case listening
  case suggestions
  case podcasts
  case device(URL)

  /// The View-menu order. Each item's ⌘-number shortcut derives from its
  /// position here, so inserting a view renumbers everything after it.
  static let commandOrder: [SidebarItem] = [
    .library, .artists, .albums, .genres, .audiobooks, .podcasts,
    .upNext, .listening, .suggestions,
  ]

  var commandShortcutDigit: Character? {
    guard let index = Self.commandOrder.firstIndex(of: self), index < 9 else { return nil }
    return Character("\(index + 1)")
  }

  var commandShortcutLabel: String? {
    commandShortcutDigit.map { "⌘\($0)" }
  }

  /// The View-menu title, shared with the Help ▸ Controls window so the
  /// documented navigation order can't drift from the menu.
  var menuTitle: String {
    switch self {
    case .library: String(localized: "Music")
    case .artists: String(localized: "Artists")
    case .albums: String(localized: "Albums")
    case .genres: String(localized: "Genres")
    case .audiobooks: String(localized: "Audiobooks")
    case .upNext: String(localized: "Up Next")
    case .playlists: String(localized: "All Playlists")
    case .listening: String(localized: "Listening")
    case .suggestions: String(localized: "Suggestions")
    case .podcasts: String(localized: "Podcasts")
    case .device: ""
    }
  }
}

enum SyncState {
  case idle
  case syncing(SyncProgress)
  case finished(SyncResult)
  case failed(String)

  var isSyncing: Bool {
    if case .syncing = self { return true }
    return false
  }
}

private struct AppSyncPreparationError: LocalizedError, Sendable {
  let errorDescription: String?

  init(_ message: String) {
    errorDescription = message
  }
}

enum AppOperationKind: Equatable, Sendable {
  case sync
  case repair
}

struct SyncLedgerRecoveryPrompt: Sendable {
  let libraryFolder: URL
  let message: String
  let quarantinePath: String
}

@Observable
@MainActor
final class AppState {
  let library: LibraryStore
  let deviceManager: DeviceManager
  let player: PlayerController
  let recentAudioDocuments: RecentAudioDocuments
  let defaultAudioApp: DefaultAudioAppController
  let visualizers = VisualizerRegistry.shared
  let updater = UpdaterService()
  let visualizerSelection = VisualizerSelection()
  @ObservationIgnored private(set) lazy var deck = DeckPresenter(app: self)
  @ObservationIgnored private(set) lazy var dockIconAnimator = DockIconAnimator(player: player)
  let playlists: PlaylistStore
  let listeningHistory: ListeningHistoryStore
  @ObservationIgnored private let usesLibraryPlaylistPersistence: Bool
  @ObservationIgnored private let usesLibraryHistoryPersistence: Bool
  let mediaController: SystemMediaController
  let onlineServices: OnlineServicesPolicy
  @ObservationIgnored let musicBrainz: any MusicBrainzService
  let musicBrainzSuggestions: MusicBrainzSuggestionStore
  let musicBrainzAutoLookup: MusicBrainzAutoLookupEngine
  let podcasts: PodcastStore
  @ObservationIgnored let intentBridge: NightdriveIntentBridge
  @ObservationIgnored let spotlightSynchronizer: NightdriveSpotlightSynchronizer

  @ObservationIgnored private let playbackPersistence: PlaybackPersistenceCoordinator
  @ObservationIgnored private var pendingPlaybackState: PlaybackPersistenceState?
  @ObservationIgnored private var pendingPodcastBookmarks: [TrackID: Int] = [:]
  @ObservationIgnored private var pendingPodcastBookmarkLibraryIdentity: LibraryResourceIdentity?
  @ObservationIgnored private var podcastBookmarksAppliedToHistory: [TrackID: Int] = [:]
  @ObservationIgnored private let syncPlanner: AppSyncPlanner
  @ObservationIgnored let syncSettingsLedger: SyncSettingsLedger
  @ObservationIgnored let playlistSyncLedgerCache = PlaylistSyncLedgerCache()
  @ObservationIgnored private var pendingAutoSync: [IpodDevice] = []
  @ObservationIgnored private var isResettingSyncLedger = false
  private var activeOperation: AppOperationKind?

  func revealLibraryFolder() {
    guard let url = library.folderURL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private static let initialTranscodeSettings = TranscodeSettings.load()

  var transcodeBitrateKbps = AppState.initialTranscodeSettings.bitrateKbps
  {
    didSet {
      NightdriveDefaults.current.set(
        transcodeBitrateKbps, forKey: TranscodeSettings.bitrateDefaultsKey)
    }
  }

  var transcodeCacheCeilingBytes = AppState.initialTranscodeSettings.cacheCeilingBytes
  {
    didSet {
      NightdriveDefaults.current.set(
        transcodeCacheCeilingBytes, forKey: TranscodeSettings.cacheCeilingDefaultsKey)
    }
  }

  private(set) var transcodeCacheSizeBytes: Int64 = 0
  private(set) var transcodeCacheError: String?
  private(set) var isClearingTranscodeCache = false
  @ObservationIgnored private let transcodeCache: any TranscodeCacheMaintenance
  @ObservationIgnored private var transcodeCacheTask: Task<Void, Never>?

  func refreshTranscodeCacheSize() {
    guard !isClearingTranscodeCache else { return }
    transcodeCacheTask?.cancel()
    let cache = transcodeCache
    transcodeCacheTask = Task(priority: .utility) { [weak self] in
      do {
        let size = try await cache.totalSizeBytes()
        try Task.checkCancellation()
        self?.transcodeCacheSizeBytes = size
        self?.transcodeCacheError = nil
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self?.transcodeCacheError = error.localizedDescription
      }
    }
  }

  func clearTranscodeCache() {
    guard !isClearingTranscodeCache else { return }
    transcodeCacheTask?.cancel()
    isClearingTranscodeCache = true
    transcodeCacheError = nil
    let cache = transcodeCache
    transcodeCacheTask = Task(priority: .utility) { [weak self] in
      do {
        try await cache.clear()
        let size = try await cache.totalSizeBytes()
        self?.transcodeCacheSizeBytes = size
      } catch {
        let actualSize = try? await cache.totalSizeBytes()
        if let actualSize { self?.transcodeCacheSizeBytes = actualSize }
        self?.transcodeCacheError = error.localizedDescription
      }
      self?.isClearingTranscodeCache = false
    }
  }

  var settingsTab: SettingsTab = .general

  var visualizerSearch = ""
  var visualizerFilter: VisualizerGroup?

  func openSettings(tab: SettingsTab) {
    settingsTab = tab
    NSApp.activate(ignoringOtherApps: true)
    SettingsWindow.open()
  }

  func openSuggestionsInbox() {
    openSidebarItem(.suggestions)
  }

  func openSidebarItem(_ item: SidebarItem) {
    selection = item
    showMainWindow()
  }

  func showMainWindow() {
    NSApplication.shared.activate()
    openMainWindow?()
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    @ObservationIgnored private(set) lazy var demo = DemoModeController(app: self)
  #endif

  var selection: SidebarItem? = .library
  var selectedPlaylistID: UUID?
  var selectedTrackIDs: Set<TrackID> = []
  /// A one-shot request for the matching browse view to select and scroll to
  /// a collection; the view consumes and clears it.
  var pendingCollectionReveal: LibraryCollectionID?
  /// A one-shot request for the Podcasts view to select a subscribed show.
  var pendingPodcastReveal: URL?
  var editInfoRequest = 0
  var editInfoDismissRequest = 0
  var searchText = ""
  var syncState: SyncState = .idle
  private(set) var syncLedgerRecoveryPrompt: SyncLedgerRecoveryPrompt?
  private(set) var isSyncLedgerRecoveryPromptPresented = false
  private(set) var libraryFolderError: String?
  var syncSettingsError: String? { syncSettingsLedger.error }
  /// A qualified play is already complete when its history sidecar write is
  /// attempted, so persistence failures surface independently from playback.
  private(set) var listeningHistoryError: String?
  private(set) var latestSyncResult: SyncResult?
  var isSyncDetailsPresented = false
  var isFindDuplicatesPresented = false
  var isCleanUpGenresPresented = false
  var isFindMetadataProblemsPresented = false
  var isOrganizeLibraryPresented = false
  var isQuickSearchPresented = false
  var quickSearchQuery = ""

  func toggleQuickSearch() {
    isQuickSearchPresented.toggle()
    if !isQuickSearchPresented { quickSearchQuery = "" }
  }

  func dismissQuickSearch() {
    isQuickSearchPresented = false
    quickSearchQuery = ""
  }

  /// Opens the browse view that owns `collectionID` and asks it to select
  /// that collection, so a quick-search hit lands on Artists/Olivia Rodrigo
  /// rather than just starting playback.
  func revealCollection(_ collectionID: LibraryCollectionID) {
    selectedTrackIDs = []
    pendingCollectionReveal = collectionID
    let item: SidebarItem =
      switch collectionID.kind {
      case .artist: .artists
      case .album: .albums
      case .genre: .genres
      case .audiobook: .audiobooks
      }
    openSidebarItem(item)
  }

  /// Opens the Music view with `track` selected.
  func revealLibraryTrack(_ track: LibraryTrack) {
    searchText = ""
    selectedTrackIDs = [track.id]
    openSidebarItem(.library)
  }

  func performQuickSearchCommand(_ command: QuickSearchCommand.Action) {
    switch command {
    case .navigate(let item): openSidebarItem(item)
    case .navigatePlaylist(let id):
      selectedPlaylistID = id
      openSidebarItem(.playlists)
    case .navigatePodcast(let feedURL):
      pendingPodcastReveal = feedURL
      openSidebarItem(.podcasts)
    case .openSettings(let tab): openSettings(tab: tab)
    case .togglePlayPause: player.togglePlayPause()
    case .nextTrack: player.next()
    case .previousTrack: player.previous()
    case .toggleShuffle: player.toggleShuffle()
    case .cycleRepeatMode: player.cycleRepeatMode()
    case .toggleMute: player.toggleMute()
    case .findDuplicates: isFindDuplicatesPresented = true
    case .cleanUpGenres: isCleanUpGenresPresented = true
    case .findMetadataProblems: isFindMetadataProblemsPresented = true
    case .organizeLibrary: isOrganizeLibraryPresented = true
    case .openAudioFiles: chooseAudioFilesToOpen()
    case .chooseLibraryFolder: chooseLibraryFolder()
    case .rescanLibrary: Task { await library.rescan() }
    case .syncIPod:
      if let device = selectedDevice ?? deviceManager.devices.first {
        sync(device)
      }
    }
  }
  @ObservationIgnored var openMainWindow: (() -> Void)?
  @ObservationIgnored private var audioFileOpenGeneration: UInt64 = 0

  var isDeviceOperationActive: Bool { activeOperation != nil }

  func requestEditInfo(for trackIDs: Set<TrackID>? = nil) {
    if let trackIDs { selectedTrackIDs = trackIDs }
    openMainWindow?()
    editInfoRequest += 1
  }

  func applyGenreCleanup(_ edits: [TrackMetadataEdit]) async throws {
    let guardedEdits = try edits.map { edit in
      guard let expectedGeneration = edit.expectedGeneration ?? edit.track.fileGenerationStamp
      else { throw LibraryStoreError.libraryChanged }
      return TrackMetadataEdit(
        track: edit.track, metadata: edit.metadata, expectedGeneration: expectedGeneration)
    }
    try await library.updateMetadata(applying: guardedEdits)
    replacePlayerTracks(editedBy: guardedEdits)
  }

  private func replacePlayerTracks(editedBy edits: [TrackMetadataEdit]) {
    let editedIDs = Set(edits.map(\.track.id))
    for track in library.tracks where editedIDs.contains(track.id) {
      player.replaceTrack(track)
    }
  }

  /// Builds the file edit that changes a track's media kind, or nil when the
  /// change is impossible: the format has no editable metadata, the track
  /// already has that kind, or the kind is fixed by the extension (`.m4b`).
  nonisolated static func mediaKindEdit(
    for track: LibraryTrack, to kind: LibraryMediaKind
  ) -> TrackMetadataEdit? {
    guard track.mediaKind != kind, track.supportsMetadataEditing,
      let format = track.audioFormat
    else { return nil }
    // Start from the raw file metadata: TrackMetadata(track) substitutes the
    // filename for an empty title, which a media-kind change must not persist.
    var metadata = track.metadata
    switch kind {
    case .audiobook:
      switch format {
      case .mp3:
        // MP3 has no media-kind field; the conventional mark is the genre.
        metadata.genres = GenreMetadata.canonicalValues(
          [GenreMetadata.audiobookGenre] + metadata.genres)
        return TrackMetadataEdit(
          track: track, metadata: metadata,
          expectedGeneration: track.fileGenerationStamp)
      case .m4a:
        return TrackMetadataEdit(
          track: track, metadata: metadata,
          expectedGeneration: track.fileGenerationStamp,
          mediaKindChange: .audiobook)
      default:
        return nil
      }
    case .song:
      guard track.mediaKind == .audiobook, format != .m4b else { return nil }
      metadata.genres = metadata.genres.filter { !GenreMetadata.isAudiobookGenre($0) }
      return TrackMetadataEdit(
        track: track, metadata: metadata,
        expectedGeneration: track.fileGenerationStamp,
        mediaKindChange: format == .m4a ? .song : nil)
    case .podcast:
      return nil
    }
  }

  nonisolated static func canSetMediaKind(
    _ kind: LibraryMediaKind, for track: LibraryTrack
  ) -> Bool {
    mediaKindEdit(for: track, to: kind) != nil
  }

  func setMediaKind(_ kind: LibraryMediaKind, for tracks: [LibraryTrack]) async throws {
    try library.validateCurrentTracks(tracks)
    let edits = tracks.compactMap { Self.mediaKindEdit(for: $0, to: kind) }
    guard !edits.isEmpty else { return }
    try await library.updateMetadata(applying: edits)
    replacePlayerTracks(editedBy: edits)
  }

  var libraryMutationsDisabled: Bool {
    isDeviceOperationActive || !library.isSettled
  }

  @discardableResult
  func toggleFavorite(for trackID: TrackID) throws -> Bool {
    try library.validateCurrentTrackIDs([trackID])
    return try listeningHistory.toggleFavorite(trackID)
  }

  func setFavorite(_ isFavorite: Bool, for trackIDs: [TrackID]) throws {
    try library.validateCurrentTrackIDs(trackIDs)
    try listeningHistory.setFavorite(isFavorite, for: trackIDs)
  }

  func setRating(_ rating: Int, for trackIDs: [TrackID]) throws {
    try library.validateCurrentTrackIDs(trackIDs)
    try listeningHistory.setRating(rating, for: trackIDs)
  }

  func resetListeningStatistics(for trackID: TrackID) throws {
    try library.validateCurrentTrackIDs([trackID])
    try listeningHistory.resetStatistics(for: trackID)
  }

  func addToPlaylist(_ trackIDs: [TrackID], playlistID: UUID) throws {
    try library.validateCurrentTrackIDs(trackIDs)
    try playlists.add(trackIDs, to: playlistID)
  }

  @discardableResult
  func createPlaylist(name: String, tracks: [LibraryTrack]) throws -> UUID {
    try library.validateCurrentTracks(tracks)
    return try playlists.create(name: name, trackIDs: tracks.map(\.id))
  }

  func moveLibraryTracksToTrash(
    _ tracks: [LibraryTrack], expectedLibraryIdentity: UInt64
  ) async -> LibraryTrashResult? {
    let result = await library.moveToTrash(tracks)
    guard library.identityRevision == expectedLibraryIdentity else { return nil }
    for track in result.succeeded {
      player.removeTrack(id: track.id)
    }
    return result
  }

  struct DuplicateResolution: Sendable {
    let keeper: LibraryTrack
    let duplicates: [LibraryTrack]
  }

  struct LibraryMaintenanceOutcome: Sendable {
    var succeededCount: Int
    var failures: [LibraryTrashFailure]
    var sidecarWarning: String?
  }

  /// Trashes duplicate files and folds their playlist memberships and
  /// listening statistics into each group's surviving track. Sidecar
  /// stores are preflighted first so a blocked store aborts before any
  /// file reaches the Trash; the remaps themselves run independently so
  /// one failure never skips the rest.
  func resolveDuplicateTracks(
    _ resolutions: [DuplicateResolution], expectedLibraryIdentity: UInt64
  ) async -> LibraryMaintenanceOutcome? {
    guard !isDeviceOperationActive else { return nil }
    if let blocked = sidecarPreflightError() {
      return LibraryMaintenanceOutcome(
        succeededCount: 0, failures: [], sidecarWarning: blocked)
    }
    let losers = resolutions.flatMap(\.duplicates)
    guard
      let trashResult = await moveLibraryTracksToTrash(
        losers, expectedLibraryIdentity: expectedLibraryIdentity)
    else { return nil }

    let trashedIDs = Set(trashResult.succeeded.map(\.id))
    var mapping: [TrackID: TrackID] = [:]
    for resolution in resolutions {
      for duplicate in resolution.duplicates where trashedIDs.contains(duplicate.id) {
        mapping[duplicate.id] = resolution.keeper.id
      }
    }

    var sidecarErrors: [String] = []
    do { try playlists.remapTrackIDs(mapping) } catch {
      sidecarErrors.append(error.localizedDescription)
    }
    do { try listeningHistory.remapTrackIDs(mapping) } catch {
      sidecarErrors.append(error.localizedDescription)
    }
    return LibraryMaintenanceOutcome(
      succeededCount: trashResult.succeeded.count,
      failures: trashResult.failed,
      sidecarWarning: sidecarErrors.isEmpty ? nil : sidecarErrors.joined(separator: " "))
  }

  struct LibraryRelocationOutcome: Sendable {
    var moved: [LibraryRelocationSuccess]
    var failed: [LibraryRelocationFailure]
    var sidecarWarning: String?
  }

  /// Moves library files to new locations inside the root and retargets
  /// every track reference — podcasts, playlists, listening history, the
  /// sync ledger, and the playback queue — so an organize pass is invisible
  /// to the next sync and to playback. Sidecar stores are preflighted before
  /// any file moves, and each remap runs independently so one failure never
  /// skips the rest.
  func relocateLibraryTracks(
    _ moves: [LibraryRelocationMove], expectedLibraryIdentity: UInt64
  ) async -> LibraryRelocationOutcome? {
    await organizeLibraryTracks(
      LibraryOrganizeChanges(relocations: moves, conflictRemovals: []),
      expectedLibraryIdentity: expectedLibraryIdentity)
  }

  /// Applies an organizer plan, including the optional policy that moves an
  /// out-of-place conflict to Trash. References owned by a removed track fold
  /// onto the track that claimed its destination, including that keeper's new
  /// ID when the same plan also relocates it.
  func organizeLibraryTracks(
    _ changes: LibraryOrganizeChanges, expectedLibraryIdentity: UInt64
  ) async -> LibraryRelocationOutcome? {
    guard !isDeviceOperationActive else { return nil }
    guard library.identityRevision == expectedLibraryIdentity else { return nil }
    if let blocked = sidecarPreflightError() {
      return LibraryRelocationOutcome(moved: [], failed: [], sidecarWarning: blocked)
    }
    let folder = library.folderURL
    let result = await library.relocate(changes.relocations)
    guard library.identityRevision == expectedLibraryIdentity else { return nil }
    let trashResult = await library.trashOrganizerConflicts(changes.conflictRemovals)
    guard library.identityRevision == expectedLibraryIdentity else { return nil }

    var mapping: [TrackID: TrackID] = [:]
    var relativeMoves: [String: String] = [:]
    for move in result.moved {
      mapping[move.track.id] = TrackID(url: move.destination)
      if let folder,
        let source = SyncLedgerStore.relativePath(for: move.track.url, in: folder),
        let destination = SyncLedgerStore.relativePath(for: move.destination, in: folder)
      {
        relativeMoves[source] = destination
      }
    }
    let removalByID = Dictionary(
      uniqueKeysWithValues: changes.conflictRemovals.map { ($0.track.id, $0) })
    var removedReferenceMoves: [String: String] = [:]
    for track in trashResult.succeeded {
      guard let removal = removalByID[track.id] else { continue }
      let keeper = removal.keeper
      mapping[track.id] = mapping[keeper.id] ?? keeper.id
      if let folder,
        let source = SyncLedgerStore.relativePath(for: track.url, in: folder),
        let keeperSource = SyncLedgerStore.relativePath(for: keeper.url, in: folder)
      {
        removedReferenceMoves[source] = relativeMoves[keeperSource] ?? keeperSource
      }
    }

    var sidecarErrors: [String] = []
    if !mapping.isEmpty {
      if let folder, !relativeMoves.isEmpty {
        do { try SyncLedgerStore.remapMovedFiles(relativeMoves, libraryFolder: folder) } catch {
          sidecarErrors.append(error.localizedDescription)
        }
        playlistSyncLedgerCache.invalidate()
      }
      do { try podcasts.remapMovedFiles(relativeMoves.merging(removedReferenceMoves) { move, _ in move }) } catch {
        sidecarErrors.append(error.localizedDescription)
      }
      do { try playlists.remapTrackIDs(mapping) } catch {
        sidecarErrors.append(error.localizedDescription)
      }
      do { try listeningHistory.remapTrackIDs(mapping) } catch {
        sidecarErrors.append(error.localizedDescription)
      }
      do { try await playlists.flushPersistence() } catch {
        sidecarErrors.append(error.localizedDescription)
      }
      do { try await listeningHistory.flushPersistence() } catch {
        sidecarErrors.append(error.localizedDescription)
      }
    }
    if !result.moved.isEmpty || !trashResult.succeeded.isEmpty {
      await library.rescan()
      guard library.identityRevision == expectedLibraryIdentity else { return nil }
    }
    if !mapping.isEmpty {
      player.remapTracks(mapping, catalog: library.catalog)
    }
    let trashFailures = trashResult.failed.map {
      LibraryRelocationFailure(track: $0.track, message: $0.message)
    }
    return LibraryRelocationOutcome(
      moved: result.moved, failed: trashFailures + result.failed,
      sidecarWarning: sidecarErrors.isEmpty ? nil : sidecarErrors.joined(separator: " "))
  }

  /// Checks that sidecar stores can save before destructive
  /// maintenance touches the filesystem. Returns a user-facing message
  /// when either store is blocked.
  private func sidecarPreflightError() -> String? {
    do {
      try playlists.ensurePersistenceWritable()
      try listeningHistory.ensurePersistenceWritable()
      try podcasts.ensureDownloadsPersistenceWritable()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private func recordQualifiedPlay(_ track: LibraryTrack) {
    // A completion from a queue that belonged to the previous library is
    // intentionally ignored; it must not write into the replacement library.
    guard library.containsCurrentTrack(track) else { return }
    do {
      _ = try library.validateAvailableRoot()
      try listeningHistory.recordPlay(of: track.id)
      listeningHistoryError = nil
    } catch {
      listeningHistoryError = error.localizedDescription
    }
  }

  func dismissListeningHistoryError() {
    listeningHistoryError = nil
  }

  func reloadListeningHistoryDiscardingPendingChanges() {
    do {
      try listeningHistory.reloadFromPersistence(discardingPendingChanges: true)
      listeningHistoryError = nil
    } catch {
      listeningHistoryError = error.localizedDescription
    }
  }

  func applyMusicBrainzEdits(_ edits: [TrackMetadataEdit]) async throws {
    let editedIDs = Set(edits.map { $0.track.id })
    try await library.updateMetadata(applying: edits)
    for track in library.tracks where editedIDs.contains(track.id) {
      player.replaceTrack(track)
    }
  }

  /// Applies only corrections the user selected in the metadata-problem
  /// review. Both the library identity and each file generation are checked
  /// again by LibraryStore before any write begins.
  func applyMetadataProblemCorrections(
    _ edits: [TrackMetadataEdit], expectedLibraryIdentity: UInt64
  ) async throws {
    guard !isDeviceOperationActive else { throw LibraryStoreError.libraryChanged }
    try library.validateCurrentIdentity(expectedLibraryIdentity)
    let editedIDs = Set(edits.map { $0.track.id })
    try await library.updateMetadata(applying: edits)
    try library.validateCurrentIdentity(expectedLibraryIdentity)
    for track in library.tracks where editedIDs.contains(track.id) {
      player.replaceTrack(track)
    }
  }

  func dismissMusicBrainzSuggestion(
    _ suggestion: MusicBrainzAlbumSuggestion,
    expectedLibraryIdentity: UInt64
  ) throws {
    try library.validateCurrentIdentity(expectedLibraryIdentity)
    guard musicBrainzSuggestions.suggestion(withID: suggestion.id) == suggestion else {
      throw LibraryStoreError.libraryChanged
    }
    musicBrainzSuggestions.dismiss(albumID: suggestion.id)
  }

  func approveMusicBrainzSuggestion(
    _ suggestion: MusicBrainzAlbumSuggestion,
    expectedLibraryIdentity: UInt64
  ) async throws {
    try library.validateCurrentIdentity(expectedLibraryIdentity)
    let catalog = library.catalog
    let edits = suggestion.tracks.compactMap { track -> TrackMetadataEdit? in
      guard let libraryTrack = catalog[TrackID(rawValue: track.trackKey)],
        TrackMetadata(libraryTrack) == track.current
      else { return nil }
      return TrackMetadataEdit(track: libraryTrack, metadata: track.proposed)
    }
    if !edits.isEmpty {
      try await applyMusicBrainzEdits(edits)
    }
    try library.validateCurrentIdentity(expectedLibraryIdentity)
    guard musicBrainzSuggestions.suggestion(withID: suggestion.id) == suggestion else {
      throw LibraryStoreError.libraryChanged
    }
    musicBrainzSuggestions.remove(albumID: suggestion.id)
  }

  var searchFocusRequest = 0
  var searchFieldFocused = false

  init(
    library: LibraryStore? = nil,
    player: PlayerController? = nil,
    playlists: PlaylistStore? = nil,
    listeningHistory: ListeningHistoryStore? = nil,
    playbackPersistence: PlaybackPersistenceStore? = nil,
    transcodeCache: any TranscodeCacheMaintenance = TranscodeCache(),
    onlineServices: OnlineServicesPolicy? = nil,
    musicBrainz: (any MusicBrainzService)? = nil,
    musicBrainzSuggestions: MusicBrainzSuggestionStore? = nil,
    podcasts: PodcastStore? = nil,
    defaultAudioApp: DefaultAudioAppController? = nil,
    recentAudioDocuments: RecentAudioDocuments? = nil,
    intentBridge: NightdriveIntentBridge = .shared,
    spotlightSynchronizer: NightdriveSpotlightSynchronizer = NightdriveSpotlightSynchronizer(),
    syncSettingsWriter: @escaping AppSyncSettingsWriter = { settings, databaseID, folder in
      try await SyncEngine.writeDeviceSettings(
        settings, databaseID: databaseID, libraryFolder: folder)
    }
  ) {
    let library = library ?? LibraryStore()
    let player = player ?? PlayerController()
    let history = listeningHistory ?? ListeningHistoryStore(libraryFolder: library.folderURL)
    let persistence = playbackPersistence ?? PlaybackPersistenceStore()
    let savedState: PlaybackPersistenceState?
    do {
      savedState = try persistence.load()
    } catch {
      savedState = nil
      NightdriveLog.app.error(
        "Saved playback state could not be loaded; starting fresh: \(error.localizedDescription, privacy: .public)"
      )
    }

    self.library = library
    self.deviceManager = DeviceManager()
    self.player = player
    self.recentAudioDocuments = recentAudioDocuments ?? RecentAudioDocuments()
    self.defaultAudioApp = defaultAudioApp ?? DefaultAudioAppController()
    let playlistStore = playlists ?? PlaylistStore(libraryFolder: library.folderURL)
    self.playlists = playlistStore
    self.listeningHistory = history
    self.transcodeCache = transcodeCache
    self.usesLibraryPlaylistPersistence = playlists == nil
    self.usesLibraryHistoryPersistence = listeningHistory == nil
    self.syncPlanner = AppSyncPlanner(
      library: library, playlists: playlistStore, listeningHistory: history)
    self.syncSettingsLedger = SyncSettingsLedger(library: library, writer: syncSettingsWriter)
    let onlineServices = onlineServices ?? OnlineServicesPolicy()
    self.onlineServices = onlineServices
    let musicBrainz =
      musicBrainz ?? MusicBrainzClient(consent: { await onlineServices.consent })
    self.musicBrainz = musicBrainz
    let suggestions = musicBrainzSuggestions ?? MusicBrainzSuggestionStore()
    self.musicBrainzSuggestions = suggestions
    let autoLookup = MusicBrainzAutoLookupEngine(
      policy: onlineServices,
      store: suggestions,
      service: musicBrainz,
      tracks: { [weak library] in library?.tracks ?? [] })
    self.musicBrainzAutoLookup = autoLookup
    let podcastStore = podcasts ?? PodcastStore()
    podcastStore.libraryFolderProvider = { [weak library] in library?.folderURL }
    podcastStore.episodePlayedProvider = { [weak history] url in
      (history?.playCount(for: TrackID(url: url)) ?? 0) > 0
    }
    self.podcasts = podcastStore
    self.intentBridge = intentBridge
    self.spotlightSynchronizer = spotlightSynchronizer
    self.playbackPersistence = PlaybackPersistenceCoordinator(
      store: persistence, initialState: savedState)
    self.pendingPlaybackState = savedState
    let savedPodcastRecovery = savedState?.podcastBookmarkRecovery
    let currentLibraryIdentity = library.resourceIdentity
    let acceptsSavedPodcastRecovery =
      currentLibraryIdentity == nil
      || savedPodcastRecovery?.libraryIdentity == currentLibraryIdentity
    self.pendingPodcastBookmarkLibraryIdentity =
      acceptsSavedPodcastRecovery ? savedPodcastRecovery?.libraryIdentity : nil
    self.pendingPodcastBookmarks =
      acceptsSavedPodcastRecovery
      ? savedPodcastRecovery?.bookmarks.reduce(into: [:]) {
        bookmarks, entry in
        bookmarks[TrackID(rawValue: entry.key)] = max(0, entry.value)
      } ?? [:]
      : [:]
    if let saved = savedState {
      player.volume = min(max(saved.volume, 0), 1)
      player.isShuffleEnabled = saved.shuffleEnabled
      player.repeatMode = saved.repeatMode
      player.isMuted = saved.isMuted
      player.equalizerPreset = saved.equalizerPreset
    }
    self.mediaController = SystemMediaController(
      player: player,
      feedbackProvider: { track in
        guard library.containsCurrentTrack(track) else { return nil }
        return SystemMediaFeedbackState(
          isFavorite: history.isFavorite(track.id), rating: history.rating(for: track.id))
      },
      setFavorite: { track, isFavorite in
        try library.validateCurrentTracks([track])
        try history.setFavorite(isFavorite, for: [track.id])
      },
      setRating: { track, rating in
        try library.validateCurrentTracks([track])
        try history.setRating(rating, for: track.id)
      })
    player.randomPlaybackSource = { [weak library] in library?.tracks ?? [] }

    player.resumePositionProvider = { [weak self] track in
      self?.podcastResumePosition(for: track)
    }

    player.onPlaybackPositionChanged = { [weak self] track, position, duration in
      self?.recordPodcastBookmark(
        for: track, position: position, duration: duration, force: true)
    }

    player.onTrackQualifiedAsPlayed = { [weak self] track in
      self?.recordQualifiedPlay(track)
    }

    deviceManager.onDevicesConnected = { [weak self] connected in
      self?.autoSyncIfRequested(connected)
    }
    library.onScanCompleted = { [weak self] in
      self?.libraryScanDidComplete()
    }

    if usesLibraryPlaylistPersistence {
      playlistStore.setMutationValidator { [weak library] in
        _ = try library?.validateAvailableRoot()
      }
    }
    if usesLibraryHistoryPersistence {
      history.setMutationValidator { [weak library] in
        _ = try library?.validateAvailableRoot()
      }
    }
    library.onPreparingToInstallScan = { [weak self] returning in
      guard returning, let self else { return nil }
      let playlistSnapshot =
        self.usesLibraryPlaylistPersistence ? self.playlists.stateSnapshot() : nil
      let historySnapshot =
        self.usesLibraryHistoryPersistence ? self.listeningHistory.stateSnapshot() : nil
      let rollback = { @MainActor [weak self] in
        guard let self else { return }
        if let playlistSnapshot {
          self.playlists.restoreState(playlistSnapshot)
        }
        if let historySnapshot {
          self.listeningHistory.restoreState(historySnapshot)
        }
      }
      do {
        if self.usesLibraryPlaylistPersistence {
          try self.playlists.reloadFromPersistence()
        }
        if self.usesLibraryHistoryPersistence {
          try self.listeningHistory.reloadFromPersistence()
        }
      } catch {
        rollback()
        throw error
      }
      self.syncSettingsLedger.invalidateCache(for: self.library.folderURL)
      self.playlistSyncLedgerCache.invalidate()
      return rollback
    }
    intentBridge.install(app: self)
  }

  func updateSearchIntegrations() {
    guard !library.isScanning else { return }
    spotlightSynchronizer.schedule(library.isSettled ? searchCollectionEntities() : [])
    NightdriveShortcuts.updateAppShortcutParameters()
  }

  func openNightdriveURL(_ url: URL) -> Bool {
    guard let id = NightdriveDeepLink.collectionID(from: url) else { return false }
    Task { [intentBridge] in try? await intentBridge.openCollection(id) }
    return true
  }

  /// Consent-gated entry point shared by launch warm-up and the Podcasts
  /// view's fallback task (for example, when podcasts are enabled later).
  func preloadPodcastEpisodes() async {
    guard onlineServices.isPodcastsEnabled else { return }
    await podcasts.preloadEpisodes {
      onlineServices.isPodcastsEnabled
    } refreshSubscriptionsWhile: {
      onlineServices.isPodcastAutoRefreshActive
    }
  }

  var selectedDevice: IpodDevice? {
    guard case .device(let url) = selection else { return nil }
    return deviceManager.devices.first { $0.volumeURL == url }
  }

  func chooseLibraryFolder() {
    guard !isDeviceOperationActive else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.directoryURL = library.folderURL
    panel.prompt = String(localized: "Use as Library")
    panel.message = String(localized: "Choose the folder of audio files to use as your music library.")
    if panel.runModal() == .OK, let url = panel.url {
      setLibraryFolder(url)
    }
  }

  func chooseAudioFilesToOpen() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = AudioFileOpening.contentTypes
    panel.prompt = String(localized: "Open")
    panel.message = String(localized: "Choose one or more audio files to play in Nightdrive.")
    if panel.runModal() == .OK {
      Task { await openAudioFiles(panel.urls) }
    }
  }

  func openAudioFiles(_ urls: [URL]) async {
    let generation = beginAudioFileOpen()
    let tracks = await AudioFileOpening.resolveTracks(urls, library: library)
    playOpenedTracks(tracks, generation: generation)
  }

  func playDroppedAudioFiles(_ urls: [URL]) async {
    let generation = beginAudioFileOpen()
    let tracks = await AudioFileOpening.resolveDroppedTracks(urls, library: library)
    playOpenedTracks(tracks, generation: generation)
  }

  func enqueueDroppedAudioFiles(_ urls: [URL]) async {
    let tracks = await AudioFileOpening.resolveDroppedTracks(urls, library: library)
    recentAudioDocuments.record(tracks.map(\.url))
    for track in tracks { player.addToUpNext(track) }
  }

  private func beginAudioFileOpen() -> UInt64 {
    audioFileOpenGeneration &+= 1
    return audioFileOpenGeneration
  }

  private func playOpenedTracks(_ tracks: [LibraryTrack], generation: UInt64) {
    guard generation == audioFileOpenGeneration, let first = tracks.first else { return }
    recentAudioDocuments.record(tracks.map(\.url))
    pendingPlaybackState = nil
    showMainWindow()
    player.play(first, in: tracks)
  }

  @discardableResult
  func setLibraryFolder(_ url: URL) -> Bool {
    guard !isDeviceOperationActive else { return false }
    let changed: Bool
    do {
      changed = try library.setFolder(url)
      libraryFolderError = nil
    } catch {
      libraryFolderError = error.localizedDescription
      return false
    }
    guard changed, let folder = library.folderURL else { return true }
    syncLedgerRecoveryPrompt = nil
    isSyncLedgerRecoveryPromptPresented = false
    syncSettingsLedger.libraryFolderDidChange()
    playlistSyncLedgerCache.invalidate()
    musicBrainzAutoLookup.stop()
    selectedTrackIDs.removeAll()
    editInfoDismissRequest &+= 1
    pendingPlaybackState = nil
    pendingPodcastBookmarks.removeAll()
    pendingPodcastBookmarkLibraryIdentity = nil
    podcastBookmarksAppliedToHistory.removeAll()
    player.reconcile(with: library.catalog)
    musicBrainzSuggestions.prune(against: { _ in nil })
    if selection == .suggestions { selection = .library }
    if usesLibraryPlaylistPersistence {
      playlists.useLibraryFolder(folder, resourceChanged: true)
    }
    if usesLibraryHistoryPersistence {
      listeningHistory.useLibraryFolder(folder, resourceChanged: true)
    }
    podcasts.libraryFolderDidChange()
    return true
  }

  func dismissLibraryFolderError() {
    libraryFolderError = nil
  }

  func startPlaybackIntegrations() {
    restorePlaybackIfNeeded()
    playbackPersistence.startIntegrations(
      currentState: { [weak self] in self?.currentPlaybackPersistenceState() },
      onTick: { [weak self] in
        self?.updateSystemNowPlaying()
        self?.recordCurrentPodcastBookmark()
      })
    updateSystemNowPlaying()
    dockIconAnimator.start()
  }

  func restorePlaybackIfNeeded() {
    guard library.isSettled else { return }
    restorePendingPlaybackFromLibrary()
  }

  private func restorePendingPlaybackFromLibrary() {
    guard let saved = pendingPlaybackState else { return }
    guard library.isSettled else { return }
    let catalog = library.catalog
    let queue = saved.queueURLs.compactMap { catalog[TrackID(url: $0)] }
    player.restore(
      queue: queue,
      currentID: saved.currentURL.map(TrackID.init(url:)),
      position: saved.position,
      volume: saved.volume,
      shuffle: saved.shuffleEnabled,
      repeatMode: saved.repeatMode)
    pendingPlaybackState = nil
  }

  func libraryContentsDidChange() {
    guard library.isSettled else { return }
    if pendingPlaybackState != nil {
      restorePendingPlaybackFromLibrary()
    } else {
      let externalTracks = player.playbackQueue.filter { !library.isInsideLibraryFolder($0.url) }
      player.reconcile(with: LibraryCatalog(library.tracks + externalTracks))
    }
    refreshSmartPlaylists()
  }

  func refreshSmartPlaylists() {
    guard library.isSettled else { return }
    do {
      try playlists.refreshSmartPlaylists(library: library.tracks, facts: smartRuleFacts)
    } catch {
      NightdriveLog.app.error(
        "Refreshing smart playlists failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func flushPlaybackState() async {
    recordCurrentPodcastBookmark(force: true)
    flushPendingPodcastBookmarks()
    await playbackPersistence.flush(currentPlaybackPersistenceState())
    do {
      try await playlists.flushPersistence()
    } catch {
      NightdriveLog.app.error(
        "Flushing playlist persistence failed: \(error.localizedDescription, privacy: .public)")
    }
    let historyRecoveryCandidates = podcastBookmarksAppliedToHistory
    do {
      try await listeningHistory.flushPersistence()
      clearDurablePodcastBookmarkRecovery(historyRecoveryCandidates)
      await playbackPersistence.flush(currentPlaybackPersistenceState())
    } catch {
      NightdriveLog.app.error(
        "Flushing listening history failed: \(error.localizedDescription, privacy: .public)")
    }
    await syncSettingsLedger.flushWrites()
  }

  private func currentPlaybackPersistenceState() -> PlaybackPersistenceState? {
    let serializedBookmarks = Dictionary(
      uniqueKeysWithValues: pendingPodcastBookmarks.map { ($0.key.rawValue, $0.value) })
    let recovery = pendingPodcastBookmarkLibraryIdentity.flatMap { identity in
      serializedBookmarks.isEmpty
        ? nil
        : PodcastBookmarkRecoveryState(
          libraryIdentity: identity, bookmarks: serializedBookmarks)
    }
    if var saved = pendingPlaybackState {
      saved.podcastBookmarkRecovery = recovery
      return saved
    }
    return PlaybackPersistenceState(
      queueURLs: player.playbackQueue.map(\.url),
      currentURL: player.currentTrack?.url,
      position: player.elapsed,
      volume: player.volume,
      shuffleEnabled: player.isShuffleEnabled,
      repeatMode: player.repeatMode,
      isMuted: player.isMuted,
      equalizerPreset: player.equalizerPreset,
      podcastBookmarkRecovery: recovery)
  }

  private func podcastResumePosition(for track: LibraryTrack) -> TimeInterval? {
    guard track.mediaKind == .podcast else { return nil }
    let recoveredBookmarkMS =
      pendingPodcastBookmarkLibraryIdentity == library.resourceIdentity
      ? pendingPodcastBookmarks[track.id]
      : nil
    let bookmarkMS =
      recoveredBookmarkMS
      ?? listeningHistory.bookmarkMS(for: track.id)
    guard let bookmarkMS, bookmarkMS > 0 else { return nil }
    return TimeInterval(bookmarkMS) / 1_000
  }

  private func recordCurrentPodcastBookmark(force: Bool = false) {
    guard let track = player.currentTrack else { return }
    recordPodcastBookmark(
      for: track, position: player.elapsed, duration: player.duration, force: force)
  }

  private func recordPodcastBookmark(
    for track: LibraryTrack,
    position: TimeInterval,
    duration: TimeInterval,
    force: Bool
  ) {
    guard track.mediaKind == .podcast, position.isFinite, position >= 0
    else { return }
    let bookmarkMS: Int
    if duration.isFinite, duration > 0, position >= duration - 0.25 {
      bookmarkMS = 0
    } else {
      bookmarkMS = Int(min(position * 1_000, Double(Int.max)).rounded())
    }
    let pendingBookmarkMS =
      pendingPodcastBookmarkLibraryIdentity == library.resourceIdentity
      ? pendingPodcastBookmarks[track.id]
      : nil
    let previous = pendingBookmarkMS ?? listeningHistory.bookmarkMS(for: track.id)
    if !force, abs(bookmarkMS - (previous ?? 0)) < 5_000 { return }
    if !library.isSettled || pendingBookmarkMS != nil {
      guard library.containsInstalledTrack(track), let identity = library.resourceIdentity
      else { return }
      if let pendingIdentity = pendingPodcastBookmarkLibraryIdentity,
        pendingIdentity != identity
      {
        pendingPodcastBookmarks.removeAll()
        podcastBookmarksAppliedToHistory.removeAll()
      }
      pendingPodcastBookmarkLibraryIdentity = identity
      pendingPodcastBookmarks[track.id] = bookmarkMS
      podcastBookmarksAppliedToHistory.removeValue(forKey: track.id)
      guard library.isSettled else { return }
    }
    persistPodcastBookmark(for: track, bookmarkMS: bookmarkMS)
  }

  private func flushPendingPodcastBookmarks() {
    guard library.isSettled, !pendingPodcastBookmarks.isEmpty else { return }
    guard pendingPodcastBookmarkLibraryIdentity == library.resourceIdentity else {
      pendingPodcastBookmarks.removeAll()
      pendingPodcastBookmarkLibraryIdentity = nil
      podcastBookmarksAppliedToHistory.removeAll()
      return
    }
    for (trackID, bookmarkMS) in Array(pendingPodcastBookmarks) {
      guard let track = library.catalog[trackID], track.mediaKind == .podcast else {
        pendingPodcastBookmarks.removeValue(forKey: trackID)
        podcastBookmarksAppliedToHistory.removeValue(forKey: trackID)
        continue
      }
      persistPodcastBookmark(for: track, bookmarkMS: bookmarkMS)
    }
  }

  private func persistPodcastBookmark(for track: LibraryTrack, bookmarkMS: Int) {
    guard library.containsCurrentTrack(track) else { return }
    do {
      _ = try library.validateAvailableRoot()
      try listeningHistory.setBookmarkMS(bookmarkMS, for: track.id)
      if pendingPodcastBookmarks[track.id] != nil {
        podcastBookmarksAppliedToHistory[track.id] = bookmarkMS
      }
      listeningHistoryError = nil
    } catch {
      listeningHistoryError = error.localizedDescription
    }
  }

  private func clearDurablePodcastBookmarkRecovery(_ candidates: [TrackID: Int]) {
    for (trackID, bookmarkMS) in candidates
    where pendingPodcastBookmarks[trackID] == bookmarkMS
      && podcastBookmarksAppliedToHistory[trackID] == bookmarkMS
    {
      pendingPodcastBookmarks.removeValue(forKey: trackID)
      podcastBookmarksAppliedToHistory.removeValue(forKey: trackID)
    }
    if pendingPodcastBookmarks.isEmpty {
      pendingPodcastBookmarkLibraryIdentity = nil
    }
  }

  private func updateSystemNowPlaying() {
    guard let track = player.currentTrack else {
      mediaController.clearNowPlaying()
      return
    }
    mediaController.updateNowPlaying(
      track: track,
      isPlaying: player.isPlaying,
      elapsed: player.elapsed,
      duration: player.duration,
      artwork: player.artwork)
  }

  func syncPlanAsync(for device: IpodDevice) async -> SyncPlan {
    await syncPlanner.previewAsync(device: device, settings: syncSettings(for: device))
  }

  private func pinnedSyncPlanAsync(
    for device: IpodDevice,
    scopeInput: SyncScopeInput,
    transcodeSettings: TranscodeSettings = TranscodeSettings.load()
  ) async -> SyncPlan {
    await syncPlanner.previewAsync(
      pinnedTo: scopeInput, device: device, transcodeSettings: transcodeSettings)
  }

  var smartRuleFacts: [String: SmartRuleFacts] {
    syncPlanner.smartRuleFacts
  }

  func syncSettings(for device: IpodDevice) -> SyncDeviceSettings {
    syncSettingsLedger.settings(for: device)
  }

  func updateSyncSettings(for device: IpodDevice, _ mutate: (inout SyncDeviceSettings) -> Void) {
    guard !isResettingSyncLedger else { return }
    syncSettingsLedger.update(for: device, mutate)
  }

  func setDisplayName(_ name: String, for device: IpodDevice) {
    guard !isResettingSyncLedger else { return }
    syncSettingsLedger.setDisplayName(name, for: device)
  }

  func displayName(for device: IpodDevice) -> String {
    syncSettingsLedger.displayName(for: device)
  }

  func autoSyncIfRequested(_ connected: [IpodDevice]) {
    guard syncLedgerRecoveryPrompt == nil else { return }
    for device in connected
    where syncSettings(for: device).autoSyncOnConnect
      && !pendingAutoSync.contains(where: { $0.volumeURL == device.volumeURL })
    {
      pendingAutoSync.append(device)
    }
    drainAutoSyncQueue()
  }

  private func libraryScanDidComplete() {
    flushPendingPodcastBookmarks()
    musicBrainzAutoLookup.refresh()
    updateSearchIntegrations()
    drainAutoSyncQueue()
  }

  private func drainAutoSyncQueue() {
    guard syncLedgerRecoveryPrompt == nil, library.initialScanCompleted, library.isSettled,
      (try? library.validateAvailableRoot()) != nil
    else { return }
    while !isDeviceOperationActive, !pendingAutoSync.isEmpty {
      let queued = pendingAutoSync.removeFirst()
      let device =
        deviceManager.devices.first { $0.volumeURL == queued.volumeURL } ?? queued
      guard syncSettings(for: device).autoSyncOnConnect,
        device.writeError == nil, device.databaseError == nil,
        FileManager.default.fileExists(atPath: device.volumeURL.path)
      else { continue }
      sync(device)
    }
  }

  func repairDatabase(_ device: IpodDevice) async throws -> DatabaseRepair.Outcome {
    guard activeOperation == nil else {
      throw ITunesDBError.notFound(String(localized: "A sync or database repair is already running"))
    }
    activeOperation = .repair
    syncState = .syncing(
      SyncProgress(
        step: 0, totalSteps: 1,
        detail: String(localized: "Repairing \(displayName(for: device))…")))
    let volume = device.volumeURL
    do {
      let outcome = try await Task.detached(priority: .userInitiated) {
        try await DatabaseRepair.rebuild(deviceVolume: volume)
      }.value
      await deviceManager.reload(device)
      syncState = .idle
      activeOperation = nil
      drainAutoSyncQueue()
      return outcome
    } catch {
      await deviceManager.reload(device)
      syncState = .failed(String(localized: "Repair failed: \(error.localizedDescription)"))
      activeOperation = nil
      drainAutoSyncQueue()
      throw error
    }
  }

  func dismissSyncSettingsError() {
    syncSettingsLedger.dismissError()
  }

  func flushSyncSettingsWrites() async {
    await syncSettingsLedger.flushWrites()
  }

  func playlistSyncDisplayStatus(for playlist: LocalPlaylist) -> PlaylistSyncDisplayStatus? {
    guard playlist.syncEnabled else { return .syncDisabled }
    guard library.isSettled, (try? library.validateAvailableRoot()) != nil else { return nil }
    guard let device = deviceManager.devices.first, let databaseID = device.databaseID,
      let folder = library.folderURL
    else { return nil }
    let snapshot = playlistSyncLedgerCache.snapshot(for: databaseID, libraryFolder: folder)
    let deviceIDs = Set(device.playlists.map(\.persistentID))
    guard
      snapshot.playlistLinks.contains(where: {
        $0.localID == playlist.id && deviceIDs.contains($0.persistentID)
      })
    else { return .notOnDevice }
    let unavailable = snapshot.trackLinks.dbids(forTrackIDs: playlist.trackIDs).skipped
    return unavailable > 0 ? .tracksUnavailable(unavailable) : .synced
  }

  func showLatestSyncDetails() {
    guard latestSyncResult != nil else { return }
    isSyncDetailsPresented = true
  }

  var canShowSyncErrorDetails: Bool {
    guard case .failed = syncState, !isSyncLedgerRecoveryPromptPresented,
      let prompt = syncLedgerRecoveryPrompt,
      let folder = library.folderURL
    else { return false }
    return folder.standardizedFileURL == prompt.libraryFolder.standardizedFileURL
  }

  func showSyncErrorDetails() {
    guard canShowSyncErrorDetails else { return }
    isSyncLedgerRecoveryPromptPresented = true
  }

  func dismissSyncLedgerRecoveryPromptPresentation() {
    isSyncLedgerRecoveryPromptPresented = false
  }

  func recordCompletedSync(_ result: SyncResult, presentingDetails: Bool = false) {
    latestSyncResult = result
    if presentingDetails { isSyncDetailsPresented = true }
  }

  struct SyncDispatchOptions: Sendable {
    var confirmRemovals = false
    var applySuggestedTrim = false
    var confirmedScopeInput: SyncScopeInput?
    var confirmedRemovalDbids: Set<UInt64>?
    var confirmedTrimKeys: Set<String>?

    init(
      confirmRemovals: Bool = false, applySuggestedTrim: Bool = false,
      confirmedScopeInput: SyncScopeInput? = nil,
      confirmedRemovalDbids: Set<UInt64>? = nil,
      confirmedTrimKeys: Set<String>? = nil
    ) {
      self.confirmRemovals = confirmRemovals
      self.applySuggestedTrim = applySuggestedTrim
      self.confirmedScopeInput = confirmedScopeInput
      self.confirmedRemovalDbids = confirmedRemovalDbids
      self.confirmedTrimKeys = confirmedTrimKeys
    }
  }

  func sync(_ device: IpodDevice, options: SyncDispatchOptions = SyncDispatchOptions()) {
    guard library.isSettled, (try? library.validateAvailableRoot()) != nil,
      let folder = library.folderURL, activeOperation == nil, syncLedgerRecoveryPrompt == nil
    else { return }
    activeOperation = .sync
    let libraryIdentity = library.identityRevision
    let volume = device.volumeURL
    let localEffects = AppSyncLocalEffects.make(
      library: library, playlists: playlists, listeningHistory: listeningHistory,
      expectedLibraryFolder: folder, expectedLibraryIdentity: libraryIdentity)
    syncState = .syncing(
      SyncProgress(step: 0, totalSteps: 1, detail: String(localized: "Preparing…")))

    Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await SyncWorkflow.execute(
          deviceVolume: volume,
          libraryFolder: folder,
          deviceName: device.name,
          prepare: { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.prepareSyncExecution(
              device: device, options: options, expectedLibraryFolder: folder,
              expectedLibraryIdentity: libraryIdentity)
          },
          localEffects: localEffects
        ) { progress in
          await self.publishSyncProgress(progress)
        }
        await deviceManager.reload(device)
        await library.rescan()
        if syncSettings(for: device).ejectAfterSync {
          await deviceManager.eject(device)
        }
        syncState = .finished(result)
        recordCompletedSync(result)
        // The iPod's play counts just merged into listening history, so
        // subscriptions can now remove finished episodes and top up their
        // automatic downloads.
        if onlineServices.isPodcastsEnabled {
          Task { [weak self] in await self?.podcasts.performMaintenance() }
        }
      } catch let error as SidecarIntegrityError
        where error.path == SyncLedgerStore.url(for: folder).path
      {
        let quarantine = SidecarRecovery.quarantineURL(for: URL(fileURLWithPath: error.path))
        let prompt = SyncLedgerRecoveryPrompt(
          libraryFolder: folder,
          message: error.localizedDescription,
          quarantinePath: quarantine.path)
        syncState = .failed(error.localizedDescription)
        syncLedgerRecoveryPrompt = prompt
        isSyncLedgerRecoveryPromptPresented = true
        pendingAutoSync.removeAll()
      } catch {
        syncState = .failed(error.localizedDescription)
      }
      // A sync run rewrites ledger entries and playlist links even when it
      // ultimately fails, so refresh the display cache on every outcome.
      playlistSyncLedgerCache.invalidate()
      activeOperation = nil
      drainAutoSyncQueue()
    }
  }

  private func publishSyncProgress(_ progress: SyncProgress) {
    syncState = .syncing(progress)
  }

  func abortSyncLedgerRecovery() {
    syncLedgerRecoveryPrompt = nil
    isSyncLedgerRecoveryPromptPresented = false
    pendingAutoSync.removeAll()
    if case .failed = syncState {
      syncState = .idle
    }
    drainAutoSyncQueue()
  }

  func assumeEmptySyncLedger() {
    guard let prompt = syncLedgerRecoveryPrompt, activeOperation == nil,
      let folder = library.folderURL,
      folder.standardizedFileURL == prompt.libraryFolder.standardizedFileURL
    else { return }
    syncLedgerRecoveryPrompt = nil
    isSyncLedgerRecoveryPromptPresented = false
    isResettingSyncLedger = true
    activeOperation = .sync
    syncState = .syncing(
      SyncProgress(step: 0, totalSteps: 1, detail: String(localized: "Preserving damaged sync ledger…")))

    Task { [weak self] in
      guard let self else { return }
      do {
        await syncSettingsLedger.flushWrites()
        let workflowLock = try await ScopedAdvisoryLock.acquire(
          for: folder, namespace: .libraryWorkflow)
        defer { workflowLock.unlock() }
        let ledgerLock = try await ScopedAdvisoryLock.acquire(
          for: folder, namespace: .library)
        defer { ledgerLock.unlock() }
        _ = try SyncLedgerStore.assumeEmptyAfterIntegrityWarning(libraryFolder: folder)
        syncSettingsLedger.invalidateCache(for: folder)
        syncPlanner.invalidateCache()
        playlistSyncLedgerCache.invalidate()
        syncState = .failed(
          String(
            localized:
              "The damaged sync ledger was preserved. Review the refreshed sync settings, then sync again."))
      } catch {
        syncState = .failed(
          String(localized: "The sync ledger could not be preserved: \(error.localizedDescription)"))
      }
      isResettingSyncLedger = false
      activeOperation = nil
      drainAutoSyncQueue()
    }
  }

  private func prepareSyncExecution(
    device: IpodDevice,
    options: SyncDispatchOptions,
    expectedLibraryFolder: URL,
    expectedLibraryIdentity: UInt64
  ) async throws -> SyncWorkflow.PreparedExecution {
    try validateSyncLibrary(
      expectedFolder: expectedLibraryFolder, expectedIdentity: expectedLibraryIdentity)

    await library.rescan()
    _ = try library.validateAvailableRoot()
    try await reconcileSidecarsForSync()
    _ = try SyncLedgerStore.load(libraryFolder: expectedLibraryFolder)
    try validateSyncLibrary(
      expectedFolder: expectedLibraryFolder, expectedIdentity: expectedLibraryIdentity)

    refreshSmartPlaylists()
    let transcodeSettings = TranscodeSettings.load()
    var plan: SyncPlan
    if let pinned = options.confirmedScopeInput {
      plan = await pinnedSyncPlanAsync(
        for: device, scopeInput: pinned, transcodeSettings: transcodeSettings)
    } else {
      plan = await syncPlanner.previewAsync(
        device: device,
        settings: syncSettings(for: device),
        transcodeSettings: transcodeSettings)
    }

    if !options.confirmRemovals && !plan.removeFromDevice.isEmpty {
      plan.notInLibraryOnDevice.append(contentsOf: plan.removeFromDeviceNotInLibrary)
      plan.outOfScopeOnDevice.append(contentsOf: plan.removeFromDeviceOutsideScope)
      plan.removeFromDeviceNotInLibrary = []
      plan.removeFromDeviceOutsideScope = []
      plan.scopeInput.removesSongsNotInLibrary = false
      plan.scopeInput.removesSongsOutsideSyncScope = false
    }
    if options.confirmRemovals {
      let planned = Set(plan.removeFromDevice.map(\.dbid))
      if let confirmed = options.confirmedRemovalDbids, !planned.isSubset(of: confirmed) {
        throw AppSyncPreparationError(
          String(
            localized:
              "The sync plan changed after it was confirmed — nothing was deleted. Review the plan and sync again."))
      }
      plan.scopeInput.confirmedRemovalDbids = options.confirmedRemovalDbids ?? planned
    }
    if let shortfall = plan.capacityShortfall {
      guard options.applySuggestedTrim else {
        throw AppSyncPreparationError(
          String(
            localized:
              "Not enough free space on \(device.name) — the planned copies are \(shortfall.byteText) over. Trim the sync or free up space."
          ))
      }
      let trimmedKeys =
        options.confirmedTrimKeys
        ?? Set(plan.suggestedCapacityTrim.map(\.id.rawValue))
      plan.scopeInput.excludedURLKeys.formUnion(trimmedKeys)
      plan.copyToDevice.removeAll { trimmedKeys.contains($0.id.rawValue) }
      plan.capacityShortfall = SyncCapacity.shortfall(
        plan: plan, availableCapacity: device.availableCapacity,
        family: device.family, settings: transcodeSettings)
      if let stillOver = plan.capacityShortfall {
        throw AppSyncPreparationError(
          String(
            localized:
              "Even after trimming, \(device.name) is \(stillOver.byteText) short. Free up space or narrow the sync scope."
          ))
      }
    }

    return SyncWorkflow.PreparedExecution(
      request: SyncExecutionRequest(plan),
      expectedDatabaseID: device.databaseID,
      transcoding: TranscodeContext(settings: transcodeSettings))
  }

  func reconcileSidecarsForSync() async throws {
    do {
      try await playlists.flushPersistence()
      try playlists.reloadFromPersistence()
    } catch is AppDataDeferredWriteError {
      try playlists.reloadFromPersistence(discardingPendingChanges: true)
    }
    do {
      try await listeningHistory.flushPersistence()
      try listeningHistory.reloadFromPersistence()
    } catch is AppDataDeferredWriteError {
      try listeningHistory.reloadFromPersistence(discardingPendingChanges: true)
    }
  }

  private func validateSyncLibrary(expectedFolder: URL, expectedIdentity: UInt64) throws {
    do {
      guard library.folderURL?.standardizedFileURL == expectedFolder.standardizedFileURL else {
        throw LibraryStoreError.libraryChanged
      }
      try library.validateCurrentIdentity(expectedIdentity)
    } catch {
      throw AppSyncPreparationError(
        String(
          localized:
            "The library folder changed before sync started. Review the new library and sync again."))
    }
  }
}
