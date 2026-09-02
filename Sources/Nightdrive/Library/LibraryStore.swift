import CoreServices
import Foundation
import Observation
import Synchronization

enum LibraryStoreError: LocalizedError {
  case metadataEditingUnsupported(String)
  case bulkMetadataUpdateFailed(count: Int, firstFilename: String, message: String)
  case invalidLibraryFolder(String)
  case libraryChanged
  case libraryUnavailable

  var errorDescription: String? {
    switch self {
    case .metadataEditingUnsupported(let format):
      String(
        localized:
          "Metadata editing is available for MP3 and MPEG-4 (M4A/M4B) files, not \(format).")
    case .bulkMetadataUpdateFailed(let count, let firstFilename, let message):
      if count == 1 {
        String(localized: "1 song couldn’t be updated. “\(firstFilename)” failed: \(message)")
      } else {
        String(
          localized:
            "\(count) songs couldn’t be updated. “\(firstFilename)” failed: \(message)")
      }
    case .invalidLibraryFolder(let path):
      String(
        localized:
          "The selected library folder is unavailable or is reached through a broken or cyclic symbolic link: \(path)")
    case .libraryChanged:
      String(
        localized:
          "The music library changed. Wait for the new folder to finish scanning, then try again.")
    case .libraryUnavailable:
      String(
        localized:
          "The music library folder is unavailable. Reconnect or restore it, then rescan.")
    }
  }
}

enum LibraryBrowseKind: String, CaseIterable, Hashable, Sendable {
  case artist
  case album
  case genre
  case audiobook
}

enum LibraryScanPhase: Equatable, Sendable {
  case discoveringFiles
  case checkingCache
  case loadingMetadata
  case buildingIndex
  case savingIndex

  fileprivate var order: Int {
    switch self {
    case .discoveringFiles: 0
    case .checkingCache: 1
    case .loadingMetadata: 2
    case .buildingIndex: 3
    case .savingIndex: 4
    }
  }
}

struct LibraryScanProgress: Equatable, Sendable {
  let phase: LibraryScanPhase
  let completed: Int
  let total: Int?

  init(phase: LibraryScanPhase, completed: Int = 0, total: Int? = nil) {
    self.phase = phase
    self.completed = max(0, completed)
    self.total = total.map { max(0, $0) }
  }

  var fractionCompleted: Double? {
    guard let total, total > 0 else { return nil }
    return min(1, Double(completed) / Double(total))
  }

  var statusText: String {
    switch phase {
    case .discoveringFiles:
      completed == 0
        ? String(localized: "Discovering music files…")
        : String(localized: "Discovering music files… \(completed) items checked")
    case .checkingCache:
      countText(
        singular: String(localized: "Checking 1 cached song…"),
        plural: String(localized: "Checking \(completed) of \(total ?? 0) cached songs…"))
    case .loadingMetadata:
      countText(
        singular: String(localized: "Reading metadata for 1 song…"),
        plural: String(localized: "Reading metadata for \(completed) of \(total ?? 0) songs…"))
    case .buildingIndex:
      String(localized: "Building library index… \(completed) of \(total ?? 0) steps")
    case .savingIndex:
      String(localized: "Saving library index…")
    }
  }

  private func countText(singular: String, plural: String) -> String {
    total == 1 ? singular : plural
  }
}

enum LibraryScanState: Equatable, Sendable {
  case idle
  case scanning(LibraryScanProgress)
  case cancelled

  var progress: LibraryScanProgress? {
    guard case .scanning(let progress) = self else { return nil }
    return progress
  }

  var isScanning: Bool { progress != nil }
}

struct LibraryCollectionID: Hashable, Sendable {
  let kind: LibraryBrowseKind
  let primary: String
  let secondary: String
}

struct LibraryCollection: Identifiable, Hashable, Sendable {
  let id: LibraryCollectionID
  let title: String
  let subtitle: String
  let tracks: [LibraryTrack]

  var artworkTrackURL: URL? { tracks.first?.url }
  var durationMS: Int { tracks.reduce(0) { $0 + $1.durationMS } }

  static func combinedTracks(from collections: [LibraryCollection]) -> [LibraryTrack] {
    var seen = Set<TrackID>()
    return collections.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
  }

  static func ids(
    containingAny selectedTrackIDs: Set<TrackID>, in collections: [LibraryCollection]
  ) -> Set<LibraryCollectionID> {
    guard !selectedTrackIDs.isEmpty else { return [] }
    return Set(
      collections.lazy.filter { collection in
        collection.tracks.contains { selectedTrackIDs.contains($0.id) }
      }.map(\.id))
  }
}

struct LibraryResolvedAlbum: Equatable, Sendable {
  let title: String
  let albumArtist: String
  let tracks: [LibraryTrack]
}

struct LibraryTrashFailure: Equatable, Sendable {
  let track: LibraryTrack
  let message: String
}

struct TrackMetadataEdit: Sendable {
  let track: LibraryTrack
  let metadata: TrackMetadata
  let expectedGeneration: FileGenerationStamp?
  /// When set, also rewrite the file's media-kind marker (the MP4 `stik`
  /// atom). MP3 carries the mark in the genre list inside `metadata`.
  let mediaKindChange: LibraryMediaKind?

  init(
    track: LibraryTrack, metadata: TrackMetadata,
    expectedGeneration: FileGenerationStamp? = nil,
    mediaKindChange: LibraryMediaKind? = nil
  ) {
    self.track = track
    self.metadata = metadata
    self.expectedGeneration = expectedGeneration
    self.mediaKindChange = mediaKindChange
  }
}

struct LibraryTrashResult: Equatable, Sendable {
  let succeeded: [LibraryTrack]
  let failed: [LibraryTrashFailure]
}

struct LibraryFileMutations: Sendable {
  var writeMetadata:
    @Sendable (
      _ metadata: TrackMetadata, _ artworkChange: ArtworkChange,
      _ mediaKindChange: LibraryMediaKind?, _ url: URL,
      _ expectedGeneration: FileGenerationStamp?
    ) throws -> Void
  var moveToTrash: @Sendable (_ url: URL) throws -> Void
  var moveItem: @Sendable (_ source: URL, _ destination: URL) throws -> Void = { source, destination in
    try FileManager.default.moveItem(at: source, to: destination)
  }

  static let live = LibraryFileMutations(
    writeMetadata: { metadata, artworkChange, mediaKindChange, url, expectedGeneration in
      try TrackFileMetadataWriter.write(
        metadata, artworkChange: artworkChange, mediaKindChange: mediaKindChange, to: url,
        expectedGeneration: expectedGeneration)
    },
    moveToTrash: { url in
      var resultingURL: NSURL?
      try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    })
}

struct LibraryRelocationMove: Equatable, Sendable {
  let track: LibraryTrack
  let destination: URL

  init(track: LibraryTrack, destination: URL) {
    self.track = track
    self.destination = destination.standardizedFileURL
  }
}

struct LibraryRelocationSuccess: Equatable, Sendable {
  let track: LibraryTrack
  let destination: URL
}

struct LibraryRelocationFailure: Equatable, Sendable {
  let track: LibraryTrack
  let message: String
}

struct LibraryRelocationResult: Equatable, Sendable {
  let moved: [LibraryRelocationSuccess]
  let failed: [LibraryRelocationFailure]
}

enum LibraryRelocationError: LocalizedError {
  case destinationOutsideLibrary
  case destinationExists
  case sameLocation

  var errorDescription: String? {
    switch self {
    case .destinationOutsideLibrary:
      String(localized: "The destination is outside the library folder.")
    case .destinationExists:
      String(localized: "A file already exists at the destination.")
    case .sameLocation:
      String(localized: "The file is already at the destination.")
    }
  }
}

enum LibraryOrganizeConflictError: LocalizedError {
  case keeperChanged

  var errorDescription: String? {
    String(localized: "The file at the conflicting destination changed.")
  }
}

/// Folder transitions are synchronous while metadata and Trash operations run
/// off the main actor, so a generation check alone is too late — the old file
/// may already be changing. This lock makes them exclusive; a waiter holding
/// the old generation loses if the transition takes the lock first.
private final class LibraryMutationTransitionBarrier: Sendable {
  struct Token: Equatable, Sendable {
    fileprivate let generation: UInt64
  }

  private let generation = Mutex<UInt64>(0)

  func token() -> Token {
    Token(generation: generation.withLock { $0 })
  }

  func beginTransition() {
    generation.withLock { $0 &+= 1 }
  }

  func perform<T>(for token: Token, _ operation: () throws -> T) throws -> T {
    try generation.withLock { generation in
      guard token.generation == generation else { throw LibraryStoreError.libraryChanged }
      return try operation()
    }
  }
}

private struct DerivedLibraryTrack: Sendable {
  struct GenreMembership: Sendable {
    let title: String
    let groupKey: String
  }

  let track: LibraryTrack
  let originalIndex: Int
  let artistTitle: String
  let albumTitle: String
  let genreMemberships: [GenreMembership]
  let albumCollectionArtist: String
  let artistGroupKey: String
  let albumGroupKey: String
  let albumCollectionArtistGroupKey: String
  let artistSortKey: String
  let albumSortKey: String
  let titleSortKey: String

  init(track: LibraryTrack, originalIndex: Int) {
    self.track = track
    self.originalIndex = originalIndex
    artistTitle = LibraryStore.displayValue(
      track.artist, fallback: String(localized: "Unknown Artist"))
    albumTitle = LibraryStore.displayValue(
      track.album, fallback: String(localized: "Unknown Album"))
    let genres = track.genres.isEmpty ? [String(localized: "Unknown Genre")] : track.genres
    genreMemberships = genres.map {
      GenreMembership(title: $0, groupKey: LibraryStore.normalizedCollectionKey($0))
    }
    albumCollectionArtist = LibraryStore.taggedAlbumArtist(for: track)
    artistGroupKey = LibraryStore.normalizedCollectionKey(artistTitle)
    albumGroupKey = LibraryStore.normalizedCollectionKey(albumTitle)
    albumCollectionArtistGroupKey = LibraryStore.normalizedCollectionKey(albumCollectionArtist)
    artistSortKey = track.artist.lowercased()
    albumSortKey = track.album.lowercased()
    titleSortKey = track.displayTitle.lowercased()
  }
}

private struct PreparedLibrary: Sendable {
  let derivedTracks: [DerivedLibraryTrack]
  let catalog: LibraryCatalog
  let totalCount: Int
  let totalDurationMS: Int
  let totalSizeBytes: Int
  let musicTracks: [LibraryTrack]
  let musicCount: Int
  let musicDurationMS: Int
  let musicSizeBytes: Int
  let browsers: [LibraryBrowseKind: LibraryBrowserIndex]
  let tracksByPathKey: [String: LibraryTrack]
}

/// The already-prepared state an incremental delta starts from: the sorted
/// derived tracks and whichever browser indexes are currently materialized.
private struct LibraryDerivedSnapshot: Sendable {
  let derivedTracks: [DerivedLibraryTrack]
  let browsers: [LibraryBrowseKind: LibraryBrowserIndex]
}

private struct LibraryDeltaResult: Sendable {
  let prepared: PreparedLibrary
  let removedTracks: [LibraryTrack]
}

private struct LibraryBrowserIndex: Sendable {
  let collections: [LibraryCollection]
  let positionsByID: [LibraryCollection.ID: Int]
  let collectionIDsByTrackID: [TrackID: Set<LibraryCollection.ID>]
}

private struct LibraryFolderMutationSuppression: Sendable {
  enum ExpectedState: Sendable {
    case pending
    case present(FileGenerationStamp)
    case missing
  }

  let url: URL
  var expectedState: ExpectedState
  var expiresAt: Date
}

private struct LibraryFolderRescanSnapshot: Sendable {
  let installedTracks: [String: LibraryTrack]
  let suppressions: [String: LibraryFolderMutationSuppression]
}

private struct LibraryFolderReconciliationPlan: Sendable {
  let urlsToLoad: [URL]
  let removedPathKeys: Set<String>
  let discoverySucceeded: Bool

  var isEmpty: Bool { urlsToLoad.isEmpty && removedPathKeys.isEmpty }
}

private struct LibraryFolderReconciliationLoad: Sendable {
  let pathKey: String
  let track: LibraryTrack?
  let stable: Bool
}

@Observable
@MainActor
final class LibraryStore {
  /// Called just before a returning library publishes its catalog. App-owned
  /// sidecars reload here so the catalog observation cannot build smart
  /// playlists from stale values; the returned rollback runs if the root check
  /// then fails.
  @ObservationIgnored var onPreparingToInstallScan: (@MainActor (_ returning: Bool) throws -> (@MainActor () -> Void)?)?
  @ObservationIgnored var onScanCompleted: (@MainActor () -> Void)?
  @ObservationIgnored var onScanProgress: (@MainActor (LibraryScanProgress) -> Void)?
  private(set) var folderURL: URL?
  private(set) var catalog = LibraryCatalog()
  private(set) var scanState: LibraryScanState = .idle
  private(set) var initialScanCompleted = false
  private(set) var rootAvailability: LibraryRootAvailability = .notConfigured
  private(set) var derivedDataRevision: UInt64 = 0
  private(set) var identityRevision: UInt64 = 0

  var isSettled: Bool {
    scanState == .idle && folderIdentity != nil && rootAvailability == .available
  }

  var isScanning: Bool { scanState.isScanning }
  var scanProgress: LibraryScanProgress? { scanState.progress }
  var resourceIdentity: LibraryResourceIdentity? { folderIdentity?.resourceIdentity }

  var tracks: [LibraryTrack] { catalog.tracks }

  func track(at url: URL) -> LibraryTrack? {
    tracksByCanonicalPath[Self.pathKey(url)]
  }

  func isInsideLibraryFolder(_ url: URL) -> Bool {
    guard let folderURL else { return false }
    return Self.contains(url, in: folderURL)
  }

  private static let folderDefaultsKey = "libraryFolderPath"
  nonisolated private static let ownedLibraryFilenames: Set<String> = [
    ListeningHistoryFile.filename,
    LocalPlaylistFile.filename,
    PendingPlaybackReportStore.filename,
    SyncLedgerStore.filename,
  ]
  private static let mutationSuppressionLifetime: TimeInterval = 30
  @ObservationIgnored private var folderIdentity: LibraryFolderIdentity?
  @ObservationIgnored private var folderWatcher: RecursiveFolderWatcher?
  @ObservationIgnored private var folderRescanDebounceTask: Task<Void, Never>?
  @ObservationIgnored private var folderRescanEvents: [RecursiveFolderWatcher.Event] = []
  @ObservationIgnored private var watchedFolderURL: URL?
  @ObservationIgnored private var folderRescanPending = false
  @ObservationIgnored private var folderMutationSuppressions: [String: LibraryFolderMutationSuppression] = [:]
  @ObservationIgnored private var scanTask: Task<Bool, Never>?
  @ObservationIgnored private var trackRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var trackRefreshSequence = 0
  @ObservationIgnored private var indexCacheSaveTask: Task<Void, Never>?
  @ObservationIgnored private var scanningFolderURL: URL?
  @ObservationIgnored private let indexCache: LibraryIndexCache?
  @ObservationIgnored private let fileMutations: LibraryFileMutations
  @ObservationIgnored private let folderDefaults: UserDefaults?
  @ObservationIgnored private let rootInspector: LibraryRootInspector
  @ObservationIgnored private let metadataLoader: @Sendable (URL) async -> LibraryTrack
  @ObservationIgnored private var rootToken: LibraryRootToken?
  @ObservationIgnored private let mutationBarrier = LibraryMutationTransitionBarrier()
  @ObservationIgnored private var derivedTracks: [DerivedLibraryTrack] = []
  @ObservationIgnored private var tracksByCanonicalPath: [String: LibraryTrack] = [:]
  @ObservationIgnored private var cachedTotalStats = (count: 0, durationMS: 0, sizeBytes: 0)
  @ObservationIgnored private var cachedMusicTracks: [LibraryTrack] = []
  @ObservationIgnored private var cachedMusicStats = (count: 0, durationMS: 0, sizeBytes: 0)
  @ObservationIgnored private var browserCache: [LibraryBrowseKind: LibraryBrowserIndex] = [:]
  #if DEBUG
    @ObservationIgnored private(set) var browserIndexFallbackBuildCount = 0
  #endif

  init(
    indexCache: LibraryIndexCache? = LibraryIndexCache(),
    fileMutations: LibraryFileMutations = .live,
    folderDefaults: UserDefaults = NightdriveDefaults.current,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    rootInspector: @escaping LibraryRootInspector = LibraryRootPreflight.liveInspector,
    metadataLoader: @escaping @Sendable (URL) async -> LibraryTrack = {
      await MetadataLoader.load(url: $0)
    }
  ) {
    self.indexCache = indexCache
    self.fileMutations = fileMutations
    self.folderDefaults = folderDefaults
    self.rootInspector = rootInspector
    self.metadataLoader = metadataLoader
    var shouldPersistResolvedFolder = false
    var configuredURL: URL?
    if let override = environment["NIGHTDRIVE_LIBRARY"] {
      configuredURL = URL(fileURLWithPath: override, isDirectory: true)
    } else if let path = folderDefaults.string(forKey: Self.folderDefaultsKey) {
      configuredURL = URL(fileURLWithPath: path, isDirectory: true)
      shouldPersistResolvedFolder = true
    }
    if let configuredURL, let identity = try? LibraryFolderIdentity.resolve(configuredURL) {
      folderIdentity = identity
      folderURL = identity.url
      if shouldPersistResolvedFolder {
        folderDefaults.set(identity.url.path, forKey: Self.folderDefaultsKey)
      }
    } else {
      folderURL = configuredURL?.standardizedFileURL
    }
    identityRevision = folderURL == nil ? 0 : 1
    inspectConfiguredRoot()
  }

  init(
    folderURL: URL,
    indexCache: LibraryIndexCache? = nil,
    fileMutations: LibraryFileMutations = .live,
    folderDefaults: UserDefaults? = nil,
    rootInspector: @escaping LibraryRootInspector = LibraryRootPreflight.liveInspector,
    metadataLoader: @escaping @Sendable (URL) async -> LibraryTrack = {
      await MetadataLoader.load(url: $0)
    }
  ) {
    self.indexCache = indexCache
    self.fileMutations = fileMutations
    self.folderDefaults = folderDefaults
    self.rootInspector = rootInspector
    self.metadataLoader = metadataLoader
    if let identity = try? LibraryFolderIdentity.resolve(folderURL) {
      self.folderIdentity = identity
      self.folderURL = identity.url
      self.identityRevision = 1
    } else {
      self.folderURL = folderURL.standardizedFileURL
      self.identityRevision = 1
    }
    inspectConfiguredRoot()
  }

  @discardableResult
  func setFolder(_ url: URL) throws -> Bool {
    let identity = try LibraryFolderIdentity.resolve(url)
    if let folderIdentity, folderIdentity.stillReferencesSelectedResource(),
      identity.referencesSameResource(as: folderIdentity)
    {
      if let folderURL {
        folderDefaults?.set(folderURL.path, forKey: Self.folderDefaultsKey)
      }
      return false
    }
    mutationBarrier.beginTransition()
    stopWatchingFolder()
    cancelScan(markCancelled: false)
    identityRevision &+= 1
    folderIdentity = identity
    folderURL = identity.url
    initialScanCompleted = false
    rootToken = nil
    inspectConfiguredRoot()
    installEmptyCatalog()
    if rootAvailability == .available {
      publishScanProgress(LibraryScanProgress(phase: .discoveringFiles))
    } else {
      scanState = .idle
    }
    folderDefaults?.set(identity.url.path, forKey: Self.folderDefaultsKey)
    Task { await rescan() }
    return true
  }

  func collections(for kind: LibraryBrowseKind) -> [LibraryCollection] {
    _ = derivedDataRevision
    return browserIndex(for: kind).collections
  }

  func collections(
    for kind: LibraryBrowseKind, matching ids: Set<LibraryCollection.ID>
  ) -> [LibraryCollection] {
    _ = derivedDataRevision
    guard !ids.isEmpty else { return [] }
    let browser = browserIndex(for: kind)
    return ids.compactMap { browser.positionsByID[$0] }
      .sorted()
      .map { browser.collections[$0] }
  }

  func collectionIDs(
    containingAny trackIDs: Set<TrackID>, for kind: LibraryBrowseKind
  ) -> Set<LibraryCollection.ID> {
    _ = derivedDataRevision
    guard !trackIDs.isEmpty else { return [] }
    let idsByTrack = browserIndex(for: kind).collectionIDsByTrackID
    return Set(trackIDs.flatMap { idsByTrack[$0] ?? [] })
  }

  func containsCollection(_ id: LibraryCollection.ID, for kind: LibraryBrowseKind) -> Bool {
    _ = derivedDataRevision
    return browserIndex(for: kind).positionsByID[id] != nil
  }

  private func browserIndex(for kind: LibraryBrowseKind) -> LibraryBrowserIndex {
    if let browser = browserCache[kind] { return browser }
    #if DEBUG
      browserIndexFallbackBuildCount += 1
    #endif
    guard let browser = try? Self.makeBrowserIndex(for: kind, from: derivedTracks) else {
      // makeBrowserIndex throws only for cancellation, but an empty index
      // here would silently blank the browse UI, so record it.
      NightdriveLog.library.error("Building a fallback browser index failed; browse lists may be empty")
      return LibraryBrowserIndex(
        collections: [], positionsByID: [:], collectionIDsByTrackID: [:])
    }
    browserCache[kind] = browser
    return browser
  }

  var totalStats: (count: Int, durationMS: Int, sizeBytes: Int) {
    _ = derivedDataRevision
    return cachedTotalStats
  }

  /// The library minus podcast episodes, in library order. Podcast downloads
  /// browse under Podcasts, so the Music list and its stats leave them out.
  var musicTracks: [LibraryTrack] {
    _ = derivedDataRevision
    return cachedMusicTracks
  }

  var musicStats: (count: Int, durationMS: Int, sizeBytes: Int) {
    _ = derivedDataRevision
    return cachedMusicStats
  }

  private var scanGeneration = 0

  private struct MutationContext: Equatable {
    let identityRevision: UInt64
    let scanGeneration: Int
    let root: LibraryFolderIdentity
    let rootToken: LibraryRootToken
    let barrierToken: LibraryMutationTransitionBarrier.Token
  }

  @discardableResult
  func validateAvailableRoot() throws -> LibraryRootToken {
    guard rootAvailability == .available,
      let rootURL = folderURL?.standardizedFileURL,
      let root = folderIdentity,
      root.url == rootURL,
      let expected = rootToken
    else {
      throw LibraryStoreError.libraryUnavailable
    }
    switch LibraryRootPreflight.validate(expected, using: rootInspector) {
    case .success(let current):
      guard current.url == rootURL, root.stillReferencesSelectedResource() else {
        markRootUnavailable(.replaced)
        throw LibraryStoreError.libraryUnavailable
      }
      return current
    case .failure(let error):
      markRootUnavailable(error.reason)
      throw LibraryStoreError.libraryUnavailable
    }
  }

  func validateCurrentTrackIDs(_ trackIDs: [TrackID]) throws {
    let context = try mutationContext()
    for trackID in trackIDs {
      guard let track = catalog[trackID] else { throw LibraryStoreError.libraryChanged }
      try validate(track, in: context)
    }
  }

  func validateCurrentTracks(_ tracks: [LibraryTrack]) throws {
    _ = try mutationContext(for: tracks)
  }

  /// Whether a callback's track still belongs to the installed catalog.
  /// This deliberately does not inspect the live root: callers that treat a
  /// replaced-library callback as stale can then surface current-root access
  /// failures separately instead of silently classifying both as staleness.
  func containsCurrentTrack(_ track: LibraryTrack) -> Bool {
    scanState == .idle && containsInstalledTrack(track)
  }

  /// Scans keep the previous catalog installed until the replacement is
  /// ready. Playback can safely retain a pending update for one of those
  /// tracks, then validate it against the new catalog after the scan.
  func containsInstalledTrack(_ track: LibraryTrack) -> Bool {
    guard let root = folderIdentity,
      let current = catalog[track.id],
      current.url.standardizedFileURL == track.url.standardizedFileURL,
      Self.contains(track.url, in: root.url)
    else { return false }
    return true
  }

  func validateCurrentIdentity(_ expectedIdentityRevision: UInt64) throws {
    guard identityRevision == expectedIdentityRevision else {
      throw LibraryStoreError.libraryChanged
    }
    _ = try mutationContext()
  }

  private func mutationContext(for tracks: [LibraryTrack] = []) throws -> MutationContext {
    guard isSettled, let root = folderIdentity else {
      throw LibraryStoreError.libraryChanged
    }
    let rootToken: LibraryRootToken
    do {
      rootToken = try validateAvailableRoot()
    } catch LibraryStoreError.libraryUnavailable {
      throw LibraryStoreError.libraryChanged
    }
    let context = MutationContext(
      identityRevision: identityRevision,
      scanGeneration: scanGeneration,
      root: root,
      rootToken: rootToken,
      barrierToken: mutationBarrier.token())
    for track in tracks { try validate(track, in: context) }
    return context
  }

  private func validate(_ track: LibraryTrack, in context: MutationContext) throws {
    guard context.identityRevision == identityRevision,
      context.scanGeneration == scanGeneration,
      isSettled,
      folderIdentity == context.root
    else {
      throw LibraryStoreError.libraryChanged
    }
    try validateRoot(context.rootToken)
    guard
      context.root.stillReferencesSelectedResource(),
      let current = catalog[track.id],
      current.url.standardizedFileURL == track.url.standardizedFileURL,
      Self.contains(track.url, in: context.root.url)
    else {
      throw LibraryStoreError.libraryChanged
    }
  }

  private func isCurrent(_ context: MutationContext) -> Bool {
    context.identityRevision == identityRevision
      && context.scanGeneration == scanGeneration
      && isSettled
      && folderIdentity == context.root
      && context.root.stillReferencesSelectedResource()
      && (try? validateRoot(context.rootToken)) != nil
  }

  private func validateRoot(_ token: LibraryRootToken) throws {
    switch LibraryRootPreflight.validate(token, using: rootInspector) {
    case .success:
      return
    case .failure(let error):
      markRootUnavailable(error.reason)
      throw LibraryStoreError.libraryUnavailable
    }
  }

  nonisolated private static func contains(_ url: URL, in rootURL: URL) -> Bool {
    let root = canonicalPathComponents(rootURL)
    let candidate = canonicalPathComponents(url)
    return candidate.count > root.count && candidate.prefix(root.count).elementsEqual(root)
  }

  nonisolated private static func canonicalPathComponents(_ url: URL) -> [String] {
    var components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    if components.count > 2, components[1] == "private",
      ["etc", "tmp", "var"].contains(components[2])
    {
      components.remove(at: 1)
    }
    return components
  }

  func rescan() async {
    guard let configuredURL = folderURL?.standardizedFileURL else { return }
    let root: LibraryFolderIdentity
    if let selectedRoot = folderIdentity {
      root = selectedRoot
    } else {
      guard let resolvedRoot = try? LibraryFolderIdentity.resolve(configuredURL) else {
        switch rootInspector(configuredURL) {
        case .success:
          markRootUnavailable(.unreadable)
        case .failure(let error):
          markRootUnavailable(error.reason)
        }
        return
      }
      root = resolvedRoot
      folderIdentity = resolvedRoot
      folderURL = resolvedRoot.url
      folderDefaults?.set(resolvedRoot.url.path, forKey: Self.folderDefaultsKey)
    }
    let normalizedFolder = root.url
    if scanningFolderURL == normalizedFolder, let scanTask {
      _ = await scanTask.value
      return
    }

    let returningFromUnavailable: Bool
    if case .unavailable = rootAvailability {
      returningFromUnavailable = true
    } else {
      returningFromUnavailable = false
    }
    let initialToken: LibraryRootToken
    switch inspectRoot(at: normalizedFolder) {
    case .success(let token):
      initialToken = token
    case .failure(let error):
      markRootUnavailable(error.reason)
      return
    }
    startWatchingFolderIfNeeded(root)

    scanTask?.cancel()
    scanGeneration &+= 1
    let generation = scanGeneration
    publishScanProgress(LibraryScanProgress(phase: .discoveringFiles))
    rootAvailability = .checking
    scanningFolderURL = normalizedFolder

    let task = Task { @MainActor [weak self] in
      guard let self else { return false }
      return await performScan(
        root: root, normalizedFolder: normalizedFolder, initialToken: initialToken,
        returningFromUnavailable: returningFromUnavailable, generation: generation)
    }
    scanTask = task
    let installed = await task.value
    if generation == scanGeneration {
      scanTask = nil
      scanningFolderURL = nil
      scanState = .idle
      if installed { initialScanCompleted = true }
      if installed, folderRescanPending {
        folderRescanPending = false
        await rescan()
      } else if installed {
        onScanCompleted?()
      } else {
        folderRescanPending = false
      }
    }
  }

  private func performScan(
    root: LibraryFolderIdentity, normalizedFolder: URL,
    initialToken: LibraryRootToken, returningFromUnavailable: Bool,
    generation: Int
  ) async -> Bool {
    let cache = indexCache
    let loader = metadataLoader
    let reportProgress: @Sendable (LibraryScanProgress) -> Void = { [weak self] progress in
      Task { @MainActor [weak self] in
        guard let self, generation == self.scanGeneration,
          self.scanningFolderURL == normalizedFolder
        else { return }
        self.publishScanProgress(progress)
      }
    }
    let discoveryTask = Task.detached(priority: .utility) {
      try Self.discoverAudioFiles(in: normalizedFolder) { completed in
        reportProgress(
          LibraryScanProgress(phase: .discoveringFiles, completed: completed))
      }
    }
    let discovery: AudioFileDiscovery
    do {
      discovery = try await withTaskCancellationHandler {
        try await discoveryTask.value
      } onCancel: {
        discoveryTask.cancel()
      }
    } catch {
      return false
    }
    guard !Task.isCancelled else { return false }
    guard discovery.succeeded else {
      markRootUnavailable(.unreadable)
      return false
    }
    reportProgress(
      LibraryScanProgress(
        phase: .checkingCache, completed: 0, total: discovery.urls.count))
    let cacheTask = Task.detached(priority: .utility) {
      cache?.loadEntries(for: root) ?? [:]
    }
    let cached = await withTaskCancellationHandler {
      await cacheTask.value
    } onCancel: {
      cacheTask.cancel()
    }
    guard !Task.isCancelled else { return false }
    let scan: (tracks: [LibraryTrack], entries: [String: LibraryIndexCacheEntry])
    do {
      scan = try await Self.scanTracksReportingProgress(
        at: discovery.urls, consulting: cached, loader: loader,
        progress: reportProgress)
    } catch {
      return false
    }
    guard !Task.isCancelled else { return false }
    let preparationTask = Task.detached(priority: .userInitiated) {
      try await Self.prepareLibrary(scan.tracks) { completed, total in
        reportProgress(
          LibraryScanProgress(
            phase: .buildingIndex, completed: completed, total: total))
      }
    }
    let preparedLibrary: PreparedLibrary
    do {
      preparedLibrary = try await withTaskCancellationHandler {
        try await preparationTask.value
      } onCancel: {
        preparationTask.cancel()
      }
    } catch is CancellationError {
      return false
    } catch {
      return false
    }
    guard !Task.isCancelled, generation == scanGeneration,
      folderIdentity == root,
      folderURL?.standardizedFileURL == normalizedFolder
    else { return false }
    switch LibraryRootPreflight.validate(initialToken, using: rootInspector) {
    case .success:
      break
    case .failure(let error):
      markRootUnavailable(error.reason)
      return false
    }
    reportProgress(LibraryScanProgress(phase: .savingIndex, completed: 0, total: 1))
    let cacheSaveTask = scheduleIndexCacheSave(scan.entries, for: root)
    await withTaskCancellationHandler {
      await cacheSaveTask.value
    } onCancel: {
      cacheSaveTask.cancel()
    }
    guard !Task.isCancelled, generation == scanGeneration,
      folderIdentity == root,
      folderURL?.standardizedFileURL == normalizedFolder
    else { return false }
    switch LibraryRootPreflight.validate(initialToken, using: rootInspector) {
    case .success:
      break
    case .failure(let error):
      markRootUnavailable(error.reason)
      return false
    }
    publishScanProgress(
      LibraryScanProgress(phase: .savingIndex, completed: 1, total: 1))
    let rollbackSidecars: (@MainActor () -> Void)?
    do {
      rollbackSidecars = try onPreparingToInstallScan?(returningFromUnavailable)
    } catch {
      markRootUnavailable(.unreadable)
      return false
    }
    switch LibraryRootPreflight.validate(initialToken, using: rootInspector) {
    case .success:
      break
    case .failure(let error):
      rollbackSidecars?()
      markRootUnavailable(error.reason)
      return false
    }
    rootToken = initialToken
    rootAvailability = .available
    install(preparedLibrary)
    finishPendingFolderMutationSuppressions()
    return true
  }

  private func inspectConfiguredRoot() {
    guard let root = folderURL?.standardizedFileURL else {
      rootToken = nil
      rootAvailability = .notConfigured
      return
    }
    switch rootInspector(root) {
    case .success(let token):
      rootToken = token
      rootAvailability = .available
    case .failure(let error):
      rootAvailability = .unavailable(error.reason)
    }
  }

  private func inspectRoot(
    at root: URL
  ) -> Result<LibraryRootToken, LibraryRootPreflightError> {
    switch rootInspector(root) {
    case .success(let current):
      guard rootToken == nil || rootToken?.identity == current.identity else {
        return .failure(LibraryRootPreflightError(reason: .replaced))
      }
      return .success(current)
    case .failure(let error):
      return .failure(error)
    }
  }

  private func markRootUnavailable(_ reason: LibraryRootUnavailableReason) {
    rootAvailability = .unavailable(reason)
    scanState = .idle
    stopWatchingFolder()
  }

  private func publishScanProgress(_ progress: LibraryScanProgress) {
    if let current = scanProgress {
      guard
        progress.phase.order > current.phase.order
          || (progress.phase == current.phase && progress.completed >= current.completed)
      else { return }
    }
    scanState = .scanning(progress)
    onScanProgress?(progress)
  }

  /// Runs `body` behind the mutation transition barrier on a detached task,
  /// preflighting the library root first. Every file mutation goes through
  /// this kernel so barrier and preflight ordering stay uniform.
  private func performBarrieredMutation(
    in context: MutationContext,
    _ body: @escaping @Sendable () throws -> Void
  ) async throws {
    let mutationBarrier = mutationBarrier
    let rootInspector = rootInspector
    try await Task.detached(priority: .userInitiated) {
      try mutationBarrier.perform(for: context.barrierToken) {
        _ = try LibraryRootPreflight.validate(
          context.rootToken, using: rootInspector
        ).get()
        try body()
      }
    }.value
  }

  /// Applies `mutate` to each item in order behind the mutation barrier.
  /// When the root becomes unavailable or the library changes, the current
  /// item and then every remaining item are recorded as failures before
  /// iteration stops; that fill-remaining-then-break ordering is what keeps
  /// re-running the same mutation a no-op. Other errors fail only their item.
  private func performFailFastMutations<Item: Sendable, Success, Failure>(
    over items: [Item],
    in context: MutationContext,
    urls: (Item) -> [URL],
    prepare: (Item) throws -> Void,
    mutate: @escaping @Sendable (Item) throws -> Void,
    success: (Item) -> Success,
    failure: (Item, String) -> Failure
  ) async -> (succeeded: [Success], failed: [Failure]) {
    var succeeded: [Success] = []
    var failed: [Failure] = []
    for item in items {
      let suppressedURLs = urls(item)
      do {
        try prepare(item)
        beginSuppressingFolderEvents(at: suppressedURLs)
        try await performBarrieredMutation(in: context) { try mutate(item) }
        succeeded.append(success(item))
      } catch let error as LibraryRootPreflightError {
        cancelFolderEventSuppressions(at: suppressedURLs)
        markRootUnavailable(error.reason)
        let message = LibraryStoreError.libraryUnavailable.localizedDescription
        failed.append(failure(item, message))
        failed.append(
          contentsOf: items.dropFirst(succeeded.count + failed.count).map { failure($0, message) })
        break
      } catch {
        cancelFolderEventSuppressions(at: suppressedURLs)
        failed.append(failure(item, error.localizedDescription))
        if error is LibraryStoreError {
          let message = LibraryStoreError.libraryChanged.localizedDescription
          failed.append(
            contentsOf: items.dropFirst(succeeded.count + failed.count).map { failure($0, message) }
          )
          break
        }
      }
    }
    return (succeeded, failed)
  }

  func updateMetadata(
    for track: LibraryTrack,
    to metadata: TrackMetadata,
    artworkChange: ArtworkChange
  ) async throws {
    guard track.supportsMetadataEditing else {
      throw LibraryStoreError.metadataEditingUnsupported(
        track.url.pathExtension.uppercased())
    }
    let context = try mutationContext(for: [track])
    let url = track.url
    let fileMutations = fileMutations
    beginSuppressingFolderEvents(at: [url])
    do {
      try await performBarrieredMutation(in: context) {
        try fileMutations.writeMetadata(metadata, artworkChange, nil, url, nil)
      }
    } catch let error as LibraryRootPreflightError {
      cancelFolderEventSuppressions(at: [url])
      markRootUnavailable(error.reason)
      throw LibraryStoreError.libraryUnavailable
    } catch {
      cancelFolderEventSuppressions(at: [url])
      throw error
    }
    guard isCurrent(context) else {
      cancelFolderEventSuppressions(at: [url])
      throw LibraryStoreError.libraryChanged
    }
    await refreshTracks(at: [url])
  }

  func updateMetadata(
    for tracks: [LibraryTrack], applying changes: TrackMetadataChanges
  ) async throws {
    guard !changes.isEmpty else { return }
    try await performBatchEdits(
      tracks.map { TrackMetadataEdit(track: $0, metadata: changes.applying(to: TrackMetadata($0))) }
    )
  }

  func updateMetadata(applying edits: [TrackMetadataEdit]) async throws {
    guard !edits.isEmpty else { return }
    try await performBatchEdits(edits)
  }

  private func performBatchEdits(_ edits: [TrackMetadataEdit]) async throws {
    if let unsupported = edits.first(where: { !$0.track.supportsMetadataEditing }) {
      throw LibraryStoreError.metadataEditingUnsupported(
        unsupported.track.url.pathExtension.uppercased())
    }

    let context = try mutationContext(for: edits.map(\.track))

    var failures: [(filename: String, message: String)] = []
    var cancelled = false
    var writtenURLs: [URL] = []
    let fileMutations = fileMutations
    for edit in edits {
      if Task.isCancelled {
        cancelled = true
        break
      }
      do {
        try validate(edit.track, in: context)
        beginSuppressingFolderEvents(at: [edit.track.url])
        try await performBarrieredMutation(in: context) {
          try fileMutations.writeMetadata(
            edit.metadata, .unchanged, edit.mediaKindChange, edit.track.url,
            edit.expectedGeneration)
        }
        writtenURLs.append(edit.track.url)
      } catch LibraryStoreError.libraryChanged {
        cancelFolderEventSuppressions(at: [edit.track.url])
        if isCurrent(context) { await refreshTracks(at: writtenURLs) }
        throw LibraryStoreError.libraryChanged
      } catch LibraryStoreError.libraryUnavailable {
        cancelFolderEventSuppressions(at: [edit.track.url])
        throw LibraryStoreError.libraryUnavailable
      } catch let error as LibraryRootPreflightError {
        cancelFolderEventSuppressions(at: [edit.track.url])
        markRootUnavailable(error.reason)
        throw LibraryStoreError.libraryUnavailable
      } catch {
        cancelFolderEventSuppressions(at: [edit.track.url])
        failures.append((edit.track.url.lastPathComponent, error.localizedDescription))
      }
    }
    guard isCurrent(context) else {
      cancelFolderEventSuppressions(at: writtenURLs)
      throw LibraryStoreError.libraryChanged
    }
    await refreshTracks(at: writtenURLs)
    if cancelled { throw CancellationError() }
    if let first = failures.first {
      throw LibraryStoreError.bulkMetadataUpdateFailed(
        count: failures.count, firstFilename: first.filename, message: first.message)
    }
  }

  func refreshTracks(at urls: [URL]) async {
    guard !urls.isEmpty else { return }
    beginSuppressingFolderEvents(at: urls)
    let generation = scanGeneration
    let previousRefresh = trackRefreshTask
    trackRefreshSequence &+= 1
    let sequence = trackRefreshSequence

    let refresh = Task { @MainActor [weak self] in
      await previousRefresh?.value
      guard let self, generation == self.scanGeneration else {
        self?.cancelFolderEventSuppressions(at: urls)
        return
      }
      if await self.performTrackRefresh(at: urls, generation: generation) {
        self.finishFolderEventSuppressions(at: urls)
      } else {
        self.cancelFolderEventSuppressions(at: urls)
      }
    }
    trackRefreshTask = refresh
    await refresh.value
    if sequence == trackRefreshSequence {
      trackRefreshTask = nil
    }
  }

  private func performTrackRefresh(at urls: [URL], generation: Int) async -> Bool {
    guard let rootToken = try? validateAvailableRoot() else { return false }
    guard !tracks.isEmpty, scanTask == nil else {
      await rescan()
      return isSettled
    }
    let loaded = await Task.detached(priority: .userInitiated) {
      await Self.loadTracks(at: urls)
    }.value
    guard generation == scanGeneration else { return false }
    let snapshot = LibraryDerivedSnapshot(
      derivedTracks: derivedTracks, browsers: browserCache)
    let delta = await Task.detached(priority: .userInitiated) {
      try? await Self.applyLibraryDelta(
        removingPathKeys: [], addingTracks: loaded, to: snapshot)
    }.value
    guard generation == scanGeneration, let delta,
      (try? validateRoot(rootToken)) != nil
    else { return false }
    install(delta.prepared)
    return true
  }

  func moveToTrash(_ tracks: [LibraryTrack]) async -> LibraryTrashResult {
    await moveToTrash(tracks, rescanAfter: true)
  }

  /// Trashes organizer conflicts only while the exact keeper that justified
  /// each removal owns its destination. The catalog is not rescanned here:
  /// the app first remaps references for both relocations and removals, then
  /// installs their combined filesystem state with one scan.
  func trashOrganizerConflicts(
    _ removals: [LibraryOrganizeConflictRemoval]
  ) async -> LibraryTrashResult {
    let byID = Dictionary(uniqueKeysWithValues: removals.map { ($0.track.id, $0) })
    return await moveToTrash(removals.map(\.track), rescanAfter: false) { track in
      byID[track.id].map { ($0.keeper, $0.occupiedDestination) }
    }
  }

  private func moveToTrash(
    _ tracks: [LibraryTrack],
    rescanAfter: Bool,
    keeperAtDestination:
      @escaping @Sendable (LibraryTrack) -> (
        keeper: LibraryTrack, destination: URL
      )? = { _ in nil }
  ) async -> LibraryTrashResult {
    guard !tracks.isEmpty else { return LibraryTrashResult(succeeded: [], failed: []) }
    let context: MutationContext
    do {
      context = try mutationContext(for: tracks)
    } catch {
      return LibraryTrashResult(
        succeeded: [],
        failed: tracks.map { LibraryTrashFailure(track: $0, message: error.localizedDescription) })
    }

    let fileMutations = fileMutations
    let root = context.root.url
    let (succeeded, failed) = await performFailFastMutations(
      over: tracks,
      in: context,
      urls: { track in
        [track.url] + (keeperAtDestination(track).map { [$0.destination] } ?? [])
      },
      prepare: { track in
        try validate(track, in: context)
        if let (_, destination) = keeperAtDestination(track),
          !Self.contains(destination, in: root)
        {
          throw LibraryRelocationError.destinationOutsideLibrary
        }
      },
      mutate: { track in
        if let (keeper, destination) = keeperAtDestination(track) {
          guard let expected = keeper.fileGenerationStamp,
            let actual = FileGenerationStamp(url: destination),
            actual.deviceID == expected.deviceID, actual.inode == expected.inode
          else {
            throw LibraryOrganizeConflictError.keeperChanged
          }
        }
        try fileMutations.moveToTrash(track.url)
      },
      success: { $0 },
      failure: { LibraryTrashFailure(track: $0, message: $1) })
    if rescanAfter {
      if isCurrent(context) {
        await rescan()
      } else {
        cancelFolderEventSuppressions(at: succeeded.map(\.url))
      }
    } else {
      await removeEmptyDirectories(vacatedBy: succeeded, in: context)
    }
    return LibraryTrashResult(succeeded: succeeded, failed: failed)
  }

  /// Moves library files to new locations inside the library root. The
  /// catalog is not rescanned here: callers must remap sidecar references
  /// first, then trigger a rescan so the new catalog never observes stale
  /// IDs. Successful moves deliberately leave their watcher suppressions
  /// pending; that required rescan settles them against the installed catalog.
  func relocate(_ moves: [LibraryRelocationMove]) async -> LibraryRelocationResult {
    guard !moves.isEmpty else { return LibraryRelocationResult(moved: [], failed: []) }
    let context: MutationContext
    do {
      context = try mutationContext(for: moves.map(\.track))
    } catch {
      return LibraryRelocationResult(
        moved: [],
        failed: moves.map {
          LibraryRelocationFailure(track: $0.track, message: error.localizedDescription)
        })
    }

    let fileMutations = fileMutations
    let root = context.root.url
    let (moved, failed) = await performFailFastMutations(
      over: moves,
      in: context,
      urls: { [$0.track.url.standardizedFileURL, $0.destination] },
      prepare: { move in
        try validate(move.track, in: context)
        guard Self.contains(move.destination, in: root) else {
          throw LibraryRelocationError.destinationOutsideLibrary
        }
        guard move.destination.path != move.track.url.standardizedFileURL.path else {
          throw LibraryRelocationError.sameLocation
        }
      },
      mutate: { move in
        let source = move.track.url.standardizedFileURL
        let destination = move.destination
        let fm = FileManager.default
        // A case-only rename reports the source as existing at the
        // destination; FileManager handles that rename directly.
        if fm.fileExists(atPath: destination.path),
          destination.path.lowercased() != source.path.lowercased()
        {
          throw LibraryRelocationError.destinationExists
        }
        try fm.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true)
        try fileMutations.moveItem(source, destination)
      },
      success: { LibraryRelocationSuccess(track: $0.track, destination: $0.destination) },
      failure: { LibraryRelocationFailure(track: $0.track, message: $1) })

    await removeEmptyDirectories(vacatedBy: moved.map(\.track), in: context)
    return LibraryRelocationResult(moved: moved, failed: failed)
  }

  private func removeEmptyDirectories(
    vacatedBy tracks: [LibraryTrack], in context: MutationContext
  ) async {
    guard !tracks.isEmpty, isCurrent(context) else { return }
    let directories = Set(tracks.map { $0.url.deletingLastPathComponent() })
    let root = context.root.url
    await Task.detached(priority: .utility) {
      Self.removeEmptyDirectories(directories, root: root)
    }.value
  }

  /// Removes directories left empty by file mutations, walking up toward (but
  /// never including) the library root. A directory holding only Finder
  /// metadata (.DS_Store) counts as empty.
  nonisolated private static func removeEmptyDirectories(_ directories: Set<URL>, root: URL) {
    let fm = FileManager.default
    for directory in directories {
      var current = directory.standardizedFileURL
      while Self.contains(current, in: root) {
        guard
          let contents = try? fm.contentsOfDirectory(
            at: current, includingPropertiesForKeys: nil,
            options: [])
        else { break }
        let removable = contents.allSatisfy { $0.lastPathComponent == ".DS_Store" }
        guard removable, (try? fm.removeItem(at: current)) != nil else { break }
        current = current.deletingLastPathComponent().standardizedFileURL
      }
    }
  }

  nonisolated static func displayValue(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  nonisolated private static func songCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
  }

  nonisolated static func taggedAlbumArtist(for track: LibraryTrack) -> String {
    track.albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The album artist to file a track under when no tag says otherwise —
  /// the single source of truth shared by browsing and the organizer.
  nonisolated static func fallbackAlbumArtist(for track: LibraryTrack) -> String {
    if track.compilation { return variousArtists }
    return displayValue(track.artist, fallback: String(localized: "Unknown Artist"))
  }

  nonisolated static let variousArtists = String(localized: "Various Artists")

  nonisolated private static func resolveAlbumArtists(
    in bucket: [DerivedLibraryTrack]
  ) -> [(artist: String, entries: [DerivedLibraryTrack])] {
    let tagged = bucket.filter { !Self.taggedAlbumArtist(for: $0.track).isEmpty }
    let distinctTags = Set(tagged.map(\.albumCollectionArtistGroupKey))

    if distinctTags.count == 1, let first = tagged.first {
      return [(Self.taggedAlbumArtist(for: first.track), bucket)]
    }
    if distinctTags.count > 1 {
      var groups: [String: [DerivedLibraryTrack]] = [:]
      var names: [String: String] = [:]
      for entry in bucket {
        let tag = Self.taggedAlbumArtist(for: entry.track)
        let name = tag.isEmpty ? Self.fallbackAlbumArtist(for: entry.track) : tag
        let key = Self.normalizedCollectionKey(name)
        groups[key, default: []].append(entry)
        names[key] = name
      }
      return groups.map { (names[$0.key] ?? "", $0.value) }
    }

    var byFolder: [String: [DerivedLibraryTrack]] = [:]
    for entry in bucket {
      let folder = entry.track.url.deletingLastPathComponent().standardizedFileURL.path
      byFolder[folder, default: []].append(entry)
    }
    return byFolder.values.flatMap(Self.resolveUntaggedFolder)
  }

  nonisolated private static func resolveUntaggedFolder(
    _ entries: [DerivedLibraryTrack]
  ) -> [(artist: String, entries: [DerivedLibraryTrack])] {
    if entries.contains(where: { $0.track.compilation }) {
      return [(Self.variousArtists, entries)]
    }
    let artists = Set(entries.map(\.artistGroupKey))
    if artists.count <= 1 {
      return [(entries[0].artistTitle, entries)]
    }
    var positions = Set<Int>()
    var collides = false
    for entry in entries {
      let position = entry.track.discNumber << 16 | entry.track.trackNumber
      if !positions.insert(position).inserted { collides = true }
    }
    if !collides {
      return [(Self.variousArtists, entries)]
    }
    var groups: [String: [DerivedLibraryTrack]] = [:]
    for entry in entries { groups[entry.artistGroupKey, default: []].append(entry) }
    return groups.values.map { ($0[0].artistTitle, $0) }
  }

  static func resolveAlbums(in tracks: [LibraryTrack]) -> [LibraryResolvedAlbum] {
    let derived = tracks.enumerated()
      .map { DerivedLibraryTrack(track: $0.element, originalIndex: $0.offset) }
    var byTitle: [String: [DerivedLibraryTrack]] = [:]
    for entry in derived { byTitle[entry.albumGroupKey, default: []].append(entry) }
    var albums: [LibraryResolvedAlbum] = []
    for bucket in byTitle.values {
      for (artist, entries) in Self.resolveAlbumArtists(in: bucket) {
        albums.append(
          LibraryResolvedAlbum(
            title: entries[0].albumTitle,
            albumArtist: artist,
            tracks: entries.sorted(by: Self.albumTrackSort).map(\.track)))
      }
    }
    return albums.sorted {
      let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
      if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
      return $0.albumArtist.localizedCaseInsensitiveCompare($1.albumArtist) == .orderedAscending
    }
  }

  nonisolated fileprivate static func normalizedCollectionKey(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current)
  }

  nonisolated private static func libraryTrackSort(
    _ lhs: DerivedLibraryTrack, _ rhs: DerivedLibraryTrack
  ) -> Bool {
    if lhs.artistSortKey != rhs.artistSortKey { return lhs.artistSortKey < rhs.artistSortKey }
    if lhs.albumSortKey != rhs.albumSortKey { return lhs.albumSortKey < rhs.albumSortKey }
    if lhs.track.discNumber != rhs.track.discNumber {
      return lhs.track.discNumber < rhs.track.discNumber
    }
    if lhs.track.trackNumber != rhs.track.trackNumber {
      return lhs.track.trackNumber < rhs.track.trackNumber
    }
    if lhs.titleSortKey != rhs.titleSortKey { return lhs.titleSortKey < rhs.titleSortKey }
    return lhs.originalIndex < rhs.originalIndex
  }

  nonisolated private static func albumTrackSort(
    _ lhs: DerivedLibraryTrack, _ rhs: DerivedLibraryTrack
  ) -> Bool {
    if lhs.track.discNumber != rhs.track.discNumber {
      return lhs.track.discNumber < rhs.track.discNumber
    }
    if lhs.track.trackNumber != rhs.track.trackNumber {
      return lhs.track.trackNumber < rhs.track.trackNumber
    }
    if lhs.titleSortKey != rhs.titleSortKey { return lhs.titleSortKey < rhs.titleSortKey }
    if lhs.artistSortKey != rhs.artistSortKey { return lhs.artistSortKey < rhs.artistSortKey }
    return lhs.originalIndex < rhs.originalIndex
  }

  nonisolated private static func prepareLibrary(
    _ loaded: [LibraryTrack],
    progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
  ) async throws -> PreparedLibrary {
    let progressTotal = 2 + LibraryBrowseKind.allCases.count
    progress?(0, progressTotal)
    try Task.checkCancellation()
    var derived: [DerivedLibraryTrack] = []
    derived.reserveCapacity(loaded.count)
    for (offset, track) in loaded.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      derived.append(DerivedLibraryTrack(track: track, originalIndex: offset))
    }
    let sortedDerived = derived.sorted(by: Self.libraryTrackSort)
    progress?(1, progressTotal)
    try Task.checkCancellation()
    let sortedTracks = sortedDerived.map(\.track)
    let totalStats = try makeTotalStats(for: sortedTracks)
    let musicPartition = try makeMusicPartition(for: sortedTracks)
    progress?(2, progressTotal)
    let browsers = try await withThrowingTaskGroup(
      of: (LibraryBrowseKind, LibraryBrowserIndex).self,
      returning: [LibraryBrowseKind: LibraryBrowserIndex].self
    ) { group in
      for kind in LibraryBrowseKind.allCases {
        group.addTask {
          try Task.checkCancellation()
          return (kind, try Self.makeBrowserIndex(for: kind, from: sortedDerived))
        }
      }
      var browsers: [LibraryBrowseKind: LibraryBrowserIndex] = [:]
      browsers.reserveCapacity(LibraryBrowseKind.allCases.count)
      for try await (kind, browser) in group {
        browsers[kind] = browser
        progress?(2 + browsers.count, progressTotal)
      }
      return browsers
    }
    var tracksByPathKey: [String: LibraryTrack] = [:]
    tracksByPathKey.reserveCapacity(sortedTracks.count)
    for (offset, track) in sortedTracks.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      tracksByPathKey[pathKey(track.url)] = track
    }
    return PreparedLibrary(
      derivedTracks: sortedDerived,
      catalog: LibraryCatalog(sortedTracks),
      totalCount: totalStats.count,
      totalDurationMS: totalStats.durationMS,
      totalSizeBytes: totalStats.sizeBytes,
      musicTracks: musicPartition.tracks,
      musicCount: musicPartition.stats.count,
      musicDurationMS: musicPartition.stats.durationMS,
      musicSizeBytes: musicPartition.stats.sizeBytes,
      browsers: browsers,
      tracksByPathKey: tracksByPathKey)
  }

  nonisolated private static func makeTotalStats(
    for sortedTracks: [LibraryTrack]
  ) throws -> (count: Int, durationMS: Int, sizeBytes: Int) {
    var totalStats = (count: sortedTracks.count, durationMS: 0, sizeBytes: 0)
    for (offset, track) in sortedTracks.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      totalStats.durationMS += track.durationMS
      totalStats.sizeBytes += track.sizeBytes
    }
    return totalStats
  }

  /// The podcast-free slice of the library plus its stats, derived once per
  /// prepared library so the Music list doesn't filter on every table rebuild.
  nonisolated private static func makeMusicPartition(
    for sortedTracks: [LibraryTrack]
  ) throws -> (tracks: [LibraryTrack], stats: (count: Int, durationMS: Int, sizeBytes: Int)) {
    var tracks: [LibraryTrack] = []
    tracks.reserveCapacity(sortedTracks.count)
    var stats = (count: 0, durationMS: 0, sizeBytes: 0)
    for (offset, track) in sortedTracks.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      guard track.mediaKind != .podcast else { continue }
      tracks.append(track)
      stats.count += 1
      stats.durationMS += track.durationMS
      stats.sizeBytes += track.sizeBytes
    }
    return (tracks, stats)
  }

  /// Applies a small set of removed and reloaded tracks to an
  /// already-prepared library without re-deriving sort keys, re-sorting, or
  /// re-indexing the unaffected majority. Produces the same catalog and
  /// browser state as running `prepareLibrary` over the merged track list.
  nonisolated private static func applyLibraryDelta(
    removingPathKeys removedPathKeys: Set<String>,
    addingTracks loadedTracks: [LibraryTrack],
    to snapshot: LibraryDerivedSnapshot
  ) async throws -> LibraryDeltaResult {
    // Keep the last load per path, mirroring targeted refreshes where a later
    // reload of the same file wins.
    var addedTracks: [LibraryTrack] = []
    addedTracks.reserveCapacity(loadedTracks.count)
    var addedPathKeys = Set<String>()
    addedPathKeys.reserveCapacity(loadedTracks.count)
    for track in loadedTracks.reversed()
    where addedPathKeys.insert(pathKey(track.url)).inserted {
      addedTracks.append(track)
    }
    addedTracks.reverse()
    var affectedPathKeys = removedPathKeys
    affectedPathKeys.formUnion(addedPathKeys)

    var survivors: [DerivedLibraryTrack] = []
    survivors.reserveCapacity(snapshot.derivedTracks.count)
    var removedEntries: [DerivedLibraryTrack] = []
    var tracksByPathKey: [String: LibraryTrack] = [:]
    tracksByPathKey.reserveCapacity(snapshot.derivedTracks.count + addedTracks.count)
    var nextOriginalIndex = 0
    for (offset, entry) in snapshot.derivedTracks.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      nextOriginalIndex = max(nextOriginalIndex, entry.originalIndex + 1)
      let entryPathKey = pathKey(entry.track.url)
      if affectedPathKeys.contains(entryPathKey) {
        removedEntries.append(entry)
      } else {
        survivors.append(entry)
        tracksByPathKey[entryPathKey] = entry.track
      }
    }
    for track in addedTracks {
      tracksByPathKey[pathKey(track.url)] = track
    }

    // New tracks take original indexes above every survivor, matching a full
    // rebuild where reloaded tracks append after the retained catalog and
    // sort ties therefore resolve identically.
    var addedEntries: [DerivedLibraryTrack] = []
    addedEntries.reserveCapacity(addedTracks.count)
    for track in addedTracks {
      addedEntries.append(DerivedLibraryTrack(track: track, originalIndex: nextOriginalIndex))
      nextOriginalIndex += 1
    }
    addedEntries.sort(by: Self.libraryTrackSort)
    let merged = try mergeSorted(survivors, addedEntries, by: Self.libraryTrackSort)

    let sortedTracks = merged.map(\.track)
    let totalStats = try makeTotalStats(for: sortedTracks)
    let musicPartition = try makeMusicPartition(for: sortedTracks)

    var browsers: [LibraryBrowseKind: LibraryBrowserIndex] = [:]
    browsers.reserveCapacity(snapshot.browsers.count)
    for (kind, index) in snapshot.browsers {
      browsers[kind] = try updateBrowserIndex(
        index, for: kind,
        removedEntries: removedEntries, addedEntries: addedEntries,
        mergedTracks: merged)
    }

    return LibraryDeltaResult(
      prepared: PreparedLibrary(
        derivedTracks: merged,
        catalog: LibraryCatalog(sortedTracks),
        totalCount: totalStats.count,
        totalDurationMS: totalStats.durationMS,
        totalSizeBytes: totalStats.sizeBytes,
        musicTracks: musicPartition.tracks,
        musicCount: musicPartition.stats.count,
        musicDurationMS: musicPartition.stats.durationMS,
        musicSizeBytes: musicPartition.stats.sizeBytes,
        browsers: browsers,
        tracksByPathKey: tracksByPathKey),
      removedTracks: removedEntries.map(\.track))
  }

  /// Rebuilds only the collections whose group membership a delta touched and
  /// merges them into the otherwise-unchanged sorted index.
  nonisolated private static func updateBrowserIndex(
    _ index: LibraryBrowserIndex,
    for kind: LibraryBrowseKind,
    removedEntries: [DerivedLibraryTrack],
    addedEntries: [DerivedLibraryTrack],
    mergedTracks: [DerivedLibraryTrack]
  ) throws -> LibraryBrowserIndex {
    var affectedKeys = affectedGroupKeys(for: kind, in: removedEntries)
    affectedKeys.formUnion(affectedGroupKeys(for: kind, in: addedEntries))
    guard !affectedKeys.isEmpty else { return index }

    var members: [DerivedLibraryTrack] = []
    for (offset, entry) in mergedTracks.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      if entryBelongs(entry, toGroupKeys: affectedKeys, for: kind) {
        members.append(entry)
      }
    }
    // A member can also belong to untouched groups (a multi-genre track);
    // those groups' membership cannot have changed, so keep only the rebuilt
    // collections for affected keys and let the retained ones stand.
    let replacements = try makeCollections(for: kind, from: members)
      .filter { affectedKeys.contains($0.id.primary) }

    var retained: [LibraryCollection] = []
    retained.reserveCapacity(index.collections.count)
    var dropped: [LibraryCollection] = []
    for collection in index.collections {
      if affectedKeys.contains(collection.id.primary) {
        dropped.append(collection)
      } else {
        retained.append(collection)
      }
    }
    let collections = try mergeSorted(retained, replacements, by: Self.collectionSort)

    var positionsByID: [LibraryCollection.ID: Int] = [:]
    positionsByID.reserveCapacity(collections.count)
    for (position, collection) in collections.enumerated() {
      if position.isMultiple(of: 256) { try Task.checkCancellation() }
      positionsByID[collection.id] = position
    }

    var collectionIDsByTrackID = index.collectionIDsByTrackID
    for collection in dropped {
      for track in collection.tracks {
        guard var ids = collectionIDsByTrackID[track.id] else { continue }
        ids.remove(collection.id)
        if ids.isEmpty {
          collectionIDsByTrackID.removeValue(forKey: track.id)
        } else {
          collectionIDsByTrackID[track.id] = ids
        }
      }
    }
    for collection in replacements {
      for track in collection.tracks {
        collectionIDsByTrackID[track.id, default: []].insert(collection.id)
      }
    }

    return LibraryBrowserIndex(
      collections: collections,
      positionsByID: positionsByID,
      collectionIDsByTrackID: collectionIDsByTrackID)
  }

  nonisolated private static func affectedGroupKeys(
    for kind: LibraryBrowseKind, in entries: [DerivedLibraryTrack]
  ) -> Set<String> {
    var keys = Set<String>()
    for entry in entries {
      switch kind {
      case .artist:
        keys.insert(entry.artistGroupKey)
      case .album, .audiobook:
        keys.insert(entry.albumGroupKey)
      case .genre:
        for membership in entry.genreMemberships { keys.insert(membership.groupKey) }
      }
    }
    return keys
  }

  nonisolated private static func entryBelongs(
    _ entry: DerivedLibraryTrack, toGroupKeys keys: Set<String>, for kind: LibraryBrowseKind
  ) -> Bool {
    switch kind {
    case .artist:
      keys.contains(entry.artistGroupKey)
    case .album, .audiobook:
      keys.contains(entry.albumGroupKey)
    case .genre:
      entry.genreMemberships.contains { keys.contains($0.groupKey) }
    }
  }

  nonisolated private static func mergeSorted<Element>(
    _ first: [Element], _ second: [Element],
    by areInIncreasingOrder: (Element, Element) -> Bool
  ) throws -> [Element] {
    if second.isEmpty { return first }
    if first.isEmpty { return second }
    var merged: [Element] = []
    merged.reserveCapacity(first.count + second.count)
    var firstIndex = 0
    var secondIndex = 0
    while firstIndex < first.count, secondIndex < second.count {
      if merged.count.isMultiple(of: 256) { try Task.checkCancellation() }
      if areInIncreasingOrder(second[secondIndex], first[firstIndex]) {
        merged.append(second[secondIndex])
        secondIndex += 1
      } else {
        merged.append(first[firstIndex])
        firstIndex += 1
      }
    }
    merged.append(contentsOf: first[firstIndex...])
    merged.append(contentsOf: second[secondIndex...])
    return merged
  }

  private func install(_ prepared: PreparedLibrary) {
    derivedTracks = prepared.derivedTracks
    cachedTotalStats = (
      prepared.totalCount,
      prepared.totalDurationMS,
      prepared.totalSizeBytes
    )
    cachedMusicTracks = prepared.musicTracks
    cachedMusicStats = (
      prepared.musicCount,
      prepared.musicDurationMS,
      prepared.musicSizeBytes
    )
    browserCache = prepared.browsers
    catalog = prepared.catalog
    tracksByCanonicalPath = prepared.tracksByPathKey
    derivedDataRevision &+= 1
  }

  private func installEmptyCatalog() {
    derivedTracks = []
    cachedTotalStats = (count: 0, durationMS: 0, sizeBytes: 0)
    cachedMusicTracks = []
    cachedMusicStats = (count: 0, durationMS: 0, sizeBytes: 0)
    browserCache = [:]
    catalog = LibraryCatalog()
    tracksByCanonicalPath = [:]
    derivedDataRevision &+= 1
  }

  @discardableResult
  private func scheduleIndexCacheSave(
    _ entries: [String: LibraryIndexCacheEntry], for root: LibraryFolderIdentity
  ) -> Task<Void, Never> {
    guard let indexCache else {
      return Task {}
    }
    let previousSave = indexCacheSaveTask
    let task = Task.detached(priority: .utility) {
      await previousSave?.value
      guard !Task.isCancelled else { return }
      indexCache.saveEntries(entries, for: root)
    }
    indexCacheSaveTask = task
    return task
  }

  /// Persists a small entry delta by rewriting only the cache shards it
  /// touches, serialized behind any in-flight full save.
  @discardableResult
  private func scheduleIndexCacheDelta(
    updating updated: [String: LibraryIndexCacheEntry],
    removingPaths removedPaths: Set<String>,
    for root: LibraryFolderIdentity
  ) -> Task<Void, Never> {
    guard let indexCache, !(updated.isEmpty && removedPaths.isEmpty) else {
      return Task {}
    }
    let previousSave = indexCacheSaveTask
    let task = Task.detached(priority: .utility) {
      await previousSave?.value
      guard !Task.isCancelled else { return }
      indexCache.applyEntryDelta(updating: updated, removingPaths: removedPaths, for: root)
    }
    indexCacheSaveTask = task
    return task
  }

  nonisolated private static func cacheEntries(
    for tracks: [LibraryTrack]
  ) -> [String: LibraryIndexCacheEntry] {
    tracks.reduce(into: [:]) { entries, track in
      guard let stamp = track.fileGenerationStamp else { return }
      entries[track.url.standardizedFileURL.path] = LibraryIndexCacheEntry(
        stamp: stamp, track: track)
    }
  }

  /// Cache keys are `standardizedFileURL.path` values captured while a file
  /// existed. Standardization strips `/private` only for paths that resolve,
  /// so the same file yields the other form once it is deleted; cover both.
  nonisolated private static func cacheRemovalPaths(for url: URL) -> [String] {
    let path = url.standardizedFileURL.path
    let strippablePrefixes = ["/var/", "/tmp/", "/etc/"]
    if path.hasPrefix("/private/") {
      let stripped = String(path.dropFirst("/private".count))
      if strippablePrefixes.contains(where: stripped.hasPrefix) { return [path, stripped] }
    } else if strippablePrefixes.contains(where: path.hasPrefix) {
      return [path, "/private" + path]
    }
    return [path]
  }

  nonisolated private static func makeCollections(
    for kind: LibraryBrowseKind, from derivedTracks: [DerivedLibraryTrack]
  ) throws -> [LibraryCollection] {
    struct GroupKey: Hashable {
      let primary: String
      let secondary: String
    }

    // Audiobooks browse like albums: one collection per book, restricted to
    // tracks marked as audiobooks.
    let groupsAsAlbums = kind == .album || kind == .audiobook
    let derivedTracks = derivedTracks.filter { browses($0, in: kind) }

    var grouped: [GroupKey: [DerivedLibraryTrack]] = [:]
    var albumArtists: [GroupKey: String] = [:]
    var genreTitles: [GroupKey: String] = [:]
    if groupsAsAlbums {
      var byTitle: [String: [DerivedLibraryTrack]] = [:]
      for (offset, entry) in derivedTracks.enumerated() {
        if offset.isMultiple(of: 256) { try Task.checkCancellation() }
        byTitle[entry.albumGroupKey, default: []].append(entry)
      }
      for (titleKey, bucket) in byTitle {
        try Task.checkCancellation()
        for (artist, entries) in Self.resolveAlbumArtists(in: bucket) {
          let key = GroupKey(
            primary: titleKey,
            secondary: Self.normalizedCollectionKey(artist))
          grouped[key, default: []].append(contentsOf: entries)
          albumArtists[key] = artist
        }
      }
    } else if kind == .artist {
      for (offset, entry) in derivedTracks.enumerated() {
        if offset.isMultiple(of: 256) { try Task.checkCancellation() }
        let key = GroupKey(primary: entry.artistGroupKey, secondary: "")
        grouped[key, default: []].append(entry)
      }
    } else {
      for (offset, entry) in derivedTracks.enumerated() {
        if offset.isMultiple(of: 256) { try Task.checkCancellation() }
        for membership in entry.genreMemberships {
          let key = GroupKey(primary: membership.groupKey, secondary: "")
          grouped[key, default: []].append(entry)
          genreTitles[key] = genreTitles[key] ?? membership.title
        }
      }
    }

    var collections: [LibraryCollection] = []
    collections.reserveCapacity(grouped.count)
    for (offset, element) in grouped.enumerated() {
      if offset.isMultiple(of: 256) { try Task.checkCancellation() }
      let (key, entries) = element
      let first = entries[0]
      let title: String
      let subtitle: String
      switch kind {
      case .artist:
        title = first.artistTitle
        subtitle = Self.songCountText(entries.count)
      case .album, .audiobook:
        title = first.albumTitle
        let artist = albumArtists[key] ?? first.artistTitle
        subtitle = "\(artist) · \(Self.songCountText(entries.count))"
      case .genre:
        title = genreTitles[key] ?? String(localized: "Unknown Genre")
        subtitle = Self.songCountText(entries.count)
      }
      let orderedEntries =
        groupsAsAlbums ? entries.sorted(by: Self.albumTrackSort) : entries
      collections.append(
        LibraryCollection(
          id: LibraryCollectionID(
            kind: kind,
            primary: key.primary,
            secondary: key.secondary),
          title: title,
          subtitle: subtitle,
          tracks: orderedEntries.map(\.track)))
    }
    try Task.checkCancellation()
    return collections.sorted(by: Self.collectionSort)
  }

  /// Which tracks a browse list groups. Audiobooks list only tracks marked as
  /// audiobooks; every other list leaves out podcast episodes, which browse
  /// under Podcasts instead.
  nonisolated private static func browses(
    _ entry: DerivedLibraryTrack, in kind: LibraryBrowseKind
  ) -> Bool {
    switch kind {
    case .audiobook: entry.track.mediaKind == .audiobook
    case .artist, .album, .genre: entry.track.mediaKind != .podcast
    }
  }

  nonisolated private static func collectionSort(
    _ lhs: LibraryCollection, _ rhs: LibraryCollection
  ) -> Bool {
    let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
    return lhs.subtitle.localizedCaseInsensitiveCompare(rhs.subtitle) == .orderedAscending
  }

  nonisolated private static func makeBrowserIndex(
    for kind: LibraryBrowseKind, from derivedTracks: [DerivedLibraryTrack]
  ) throws -> LibraryBrowserIndex {
    let collections = try makeCollections(for: kind, from: derivedTracks)
    var positionsByID: [LibraryCollection.ID: Int] = [:]
    positionsByID.reserveCapacity(collections.count)
    var collectionIDsByTrackID: [TrackID: Set<LibraryCollection.ID>] = [:]
    collectionIDsByTrackID.reserveCapacity(derivedTracks.count)
    for (position, collection) in collections.enumerated() {
      if position.isMultiple(of: 256) { try Task.checkCancellation() }
      positionsByID[collection.id] = position
      for track in collection.tracks {
        collectionIDsByTrackID[track.id, default: []].insert(collection.id)
      }
    }
    return LibraryBrowserIndex(
      collections: collections,
      positionsByID: positionsByID,
      collectionIDsByTrackID: collectionIDsByTrackID)
  }

  private func startWatchingFolderIfNeeded(_ root: LibraryFolderIdentity) {
    let normalizedURL = root.url
    guard watchedFolderURL != normalizedURL || folderWatcher == nil else { return }
    stopWatchingFolder()
    guard
      let watcher = RecursiveFolderWatcher(
        folderURL: normalizedURL,
        onChange: { [weak self] events in
          Task { @MainActor [weak self] in
            self?.scheduleFolderRescan(for: root, events: events)
          }
        })
    else { return }
    folderWatcher = watcher
    watchedFolderURL = normalizedURL
  }

  private func scheduleFolderRescan(
    for root: LibraryFolderIdentity, events: [RecursiveFolderWatcher.Event]
  ) {
    let normalizedURL = root.url
    guard folderIdentity == root else { return }
    let candidates = events.filter { isPotentialLibraryChange($0, in: normalizedURL) }
    guard !candidates.isEmpty else { return }
    folderRescanEvents.append(contentsOf: candidates)
    folderRescanDebounceTask?.cancel()
    folderRescanDebounceTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        return
      }
      guard !Task.isCancelled, let self, self.folderIdentity == root else { return }
      self.folderRescanDebounceTask = nil
      let events = self.folderRescanEvents
      self.folderRescanEvents = []
      let capturedAt = Date()
      self.folderMutationSuppressions = self.folderMutationSuppressions.filter {
        $0.value.expiresAt > capturedAt
      }
      guard self.folderIdentity == root else { return }
      if self.scanningFolderURL == normalizedURL {
        if events.contains(where: Self.requiresFullRescan) {
          self.folderRescanPending = true
          return
        }
        let snapshot = LibraryFolderRescanSnapshot(
          installedTracks: self.tracksByCanonicalPath,
          suppressions: self.folderMutationSuppressions)
        let plan = await Task.detached(priority: .utility) {
          Self.makeFolderReconciliationPlan(
            events: events, root: root.url, snapshot: snapshot)
        }.value
        guard self.folderIdentity == root else { return }
        self.folderRescanPending =
          self.folderRescanPending || !plan.discoverySucceeded || !plan.isEmpty
        return
      }
      if events.contains(where: Self.requiresFullRescan) {
        await self.rescan()
      } else {
        await self.reconcileFolderEvents(events, for: root)
      }
    }
  }

  private func isPotentialLibraryChange(
    _ event: RecursiveFolderWatcher.Event, in root: URL
  ) -> Bool {
    if Self.isUrgentFolderEvent(event.flags) { return true }
    if Self.isOwnedLibraryURL(event.url, root: root) { return false }
    let isDirectoryChange =
      Self.hasFlag(event.flags, kFSEventStreamEventFlagItemIsDir)
      && Self.isDirectoryStructureChange(event.flags)
    if !isDirectoryChange { return LibraryAudioFormat(url: event.url) != nil }
    // File-events streams can report the watched root itself alongside a
    // child mutation. The child path carries the useful classification; do
    // not turn the root notification into another recursive discovery.
    if Self.pathKey(event.url) == Self.pathKey(root) { return false }
    return true
  }

  nonisolated private static func requiresFullRescan(
    _ event: RecursiveFolderWatcher.Event
  ) -> Bool {
    isUrgentFolderEvent(event.flags)
      || (hasFlag(event.flags, kFSEventStreamEventFlagItemIsDir)
        && hasFlag(event.flags, kFSEventStreamEventFlagItemRenamed))
  }

  private func reconcileFolderEvents(
    _ events: [RecursiveFolderWatcher.Event], for root: LibraryFolderIdentity
  ) async {
    let previousRefresh = trackRefreshTask
    trackRefreshSequence &+= 1
    let sequence = trackRefreshSequence
    let refresh = Task { @MainActor [weak self] in
      await previousRefresh?.value
      guard let self, self.folderIdentity == root, self.scanTask == nil else { return }
      let generation = self.scanGeneration
      guard let rootToken = try? self.validateAvailableRoot() else { return }
      let snapshot = LibraryFolderRescanSnapshot(
        installedTracks: self.tracksByCanonicalPath,
        suppressions: self.folderMutationSuppressions)
      let plan = await Task.detached(priority: .utility) {
        Self.makeFolderReconciliationPlan(
          events: events, root: root.url, snapshot: snapshot)
      }.value
      guard generation == self.scanGeneration, self.folderIdentity == root else { return }
      guard plan.discoverySucceeded else {
        await self.rescan()
        return
      }
      guard !plan.isEmpty else { return }
      let loads = await Task.detached(priority: .utility) {
        await Self.loadFolderReconciliationTracks(at: plan.urlsToLoad)
      }.value
      guard generation == self.scanGeneration, self.folderIdentity == root else { return }
      guard loads.allSatisfy(\.stable) else {
        await self.rescan()
        return
      }
      let derivedSnapshot = LibraryDerivedSnapshot(
        derivedTracks: self.derivedTracks, browsers: self.browserCache)
      var removedPathKeys = plan.removedPathKeys
      removedPathKeys.formUnion(loads.map(\.pathKey))
      let loadedTracks = loads.compactMap(\.track)
      let delta = await Task.detached(priority: .userInitiated) {
        try? await Self.applyLibraryDelta(
          removingPathKeys: removedPathKeys, addingTracks: loadedTracks,
          to: derivedSnapshot)
      }.value
      guard generation == self.scanGeneration, self.folderIdentity == root,
        let delta, (try? self.validateRoot(rootToken)) != nil
      else { return }
      self.scanGeneration &+= 1
      self.install(delta.prepared)
      self.scheduleIndexCacheDelta(
        updating: Self.cacheEntries(for: loadedTracks),
        removingPaths: Set(delta.removedTracks.flatMap { Self.cacheRemovalPaths(for: $0.url) }),
        for: root)
      self.onScanCompleted?()
    }
    trackRefreshTask = refresh
    await refresh.value
    if sequence == trackRefreshSequence {
      trackRefreshTask = nil
    }
  }

  nonisolated private static func makeFolderReconciliationPlan(
    events: [RecursiveFolderWatcher.Event], root: URL,
    snapshot: LibraryFolderRescanSnapshot
  ) -> LibraryFolderReconciliationPlan {
    var urlsToLoad: [String: URL] = [:]
    var removedPathKeys = Set<String>()
    var discoverySucceeded = true
    let renameDestinations: [FileGenerationStamp] = events.compactMap { event in
      guard !hasFlag(event.flags, kFSEventStreamEventFlagItemIsDir),
        hasFlag(event.flags, kFSEventStreamEventFlagItemRenamed),
        isRegularAudioFile(event.url, inside: root)
      else { return nil }
      return FileGenerationStamp(url: event.url)
    }

    func isSameFile(_ lhs: FileGenerationStamp, _ rhs: FileGenerationStamp) -> Bool {
      lhs.deviceID == rhs.deviceID && lhs.inode == rhs.inode
    }

    func inspectAudioFile(
      _ url: URL, isRename: Bool = false, isRemoval: Bool = false
    ) {
      let key = pathKey(url)
      guard !isFolderEventSuppressed(at: url, snapshot: snapshot) else { return }
      let installedTrack = snapshot.installedTracks[key]
      guard isRegularAudioFile(url, inside: root), let stamp = FileGenerationStamp(url: url)
      else {
        if let installedTrack {
          removedPathKeys.insert(key)
          if isRename && !isRemoval {
            if let installedStamp = installedTrack.fileGenerationStamp {
              if !renameDestinations.contains(where: { isSameFile($0, installedStamp) }) {
                discoverySucceeded = false
              }
            } else {
              discoverySucceeded = false
            }
          }
        }
        urlsToLoad.removeValue(forKey: key)
        return
      }
      if isRename {
        let destinationPath = url.standardizedFileURL.path
        for (installedKey, candidate) in snapshot.installedTracks
        where installedKey != key {
          guard let installedStamp = candidate.fileGenerationStamp,
            isSameFile(stamp, installedStamp)
          else { continue }
          let oldPathIsMissing = FileGenerationStamp(url: candidate.url) == nil
          let isCaseOnlyRename =
            candidate.url.standardizedFileURL.path.caseInsensitiveCompare(destinationPath)
            == .orderedSame
          if oldPathIsMissing || isCaseOnlyRename {
            removedPathKeys.insert(installedKey)
          }
        }
      }
      guard installedTrack?.fileGenerationStamp != stamp else { return }
      urlsToLoad[key] = url
      removedPathKeys.remove(key)
    }

    for event in events {
      if hasFlag(event.flags, kFSEventStreamEventFlagItemIsDir) {
        guard isDirectoryStructureChange(event.flags),
          pathKey(event.url) != pathKey(root), contains(event.url, in: root)
        else { continue }
        let directoryPrefix = pathKey(event.url) + "/"
        for (key, track) in snapshot.installedTracks where key.hasPrefix(directoryPrefix) {
          inspectAudioFile(track.url)
        }
        guard FileManager.default.fileExists(atPath: event.url.path) else { continue }
        guard let discovery = try? discoverAudioFiles(in: event.url) else {
          discoverySucceeded = false
          continue
        }
        discoverySucceeded = discoverySucceeded && discovery.succeeded
        for audioURL in discovery.urls { inspectAudioFile(audioURL) }
      } else if LibraryAudioFormat(url: event.url) != nil {
        inspectAudioFile(
          event.url,
          isRename: hasFlag(event.flags, kFSEventStreamEventFlagItemRenamed),
          isRemoval: hasFlag(event.flags, kFSEventStreamEventFlagItemRemoved))
      }
    }
    return LibraryFolderReconciliationPlan(
      urlsToLoad: Array(urlsToLoad.values),
      removedPathKeys: removedPathKeys,
      discoverySucceeded: discoverySucceeded)
  }

  nonisolated private static func isRegularAudioFile(_ url: URL, inside root: URL) -> Bool {
    guard LibraryAudioFormat(url: url) != nil, contains(url, in: root),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    else { return false }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  nonisolated private static func loadFolderReconciliationTracks(
    at urls: [URL]
  ) async -> [LibraryFolderReconciliationLoad] {
    await mapConcurrently(over: urls, maximumConcurrentTasks: 8) { url in
      let track = await MetadataLoader.load(url: url)
      let finalStamp = FileGenerationStamp(url: url)
      return LibraryFolderReconciliationLoad(
        pathKey: pathKey(url),
        track: finalStamp == nil ? nil : track,
        stable: finalStamp == track.fileGenerationStamp)
    }
  }

  nonisolated private static func hasFlag(
    _ flags: FSEventStreamEventFlags, _ flag: Int
  ) -> Bool {
    flags & FSEventStreamEventFlags(flag) != 0
  }

  nonisolated private static func isDirectoryStructureChange(
    _ flags: FSEventStreamEventFlags
  ) -> Bool {
    hasFlag(flags, kFSEventStreamEventFlagItemCreated)
      || hasFlag(flags, kFSEventStreamEventFlagItemRemoved)
      || hasFlag(flags, kFSEventStreamEventFlagItemRenamed)
  }

  nonisolated private static func isUrgentFolderEvent(
    _ flags: FSEventStreamEventFlags
  ) -> Bool {
    hasFlag(flags, kFSEventStreamEventFlagMustScanSubDirs)
      || hasFlag(flags, kFSEventStreamEventFlagUserDropped)
      || hasFlag(flags, kFSEventStreamEventFlagKernelDropped)
      || hasFlag(flags, kFSEventStreamEventFlagEventIdsWrapped)
      || hasFlag(flags, kFSEventStreamEventFlagRootChanged)
      || hasFlag(flags, kFSEventStreamEventFlagMount)
      || hasFlag(flags, kFSEventStreamEventFlagUnmount)
  }

  nonisolated private static func isOwnedLibraryURL(_ url: URL, root: URL) -> Bool {
    ownedLibraryFilenames.contains(url.lastPathComponent)
      && pathKey(url.deletingLastPathComponent()) == pathKey(root)
  }

  private func beginSuppressingFolderEvents(at urls: [URL]) {
    let now = Date()
    folderMutationSuppressions = folderMutationSuppressions.filter { $0.value.expiresAt > now }
    let expiration = Date().addingTimeInterval(Self.mutationSuppressionLifetime)
    for url in urls {
      folderMutationSuppressions[Self.pathKey(url)] = LibraryFolderMutationSuppression(
        url: url, expectedState: .pending, expiresAt: expiration)
    }
  }

  private func finishFolderEventSuppressions(at urls: [URL]) {
    let expiration = Date().addingTimeInterval(Self.mutationSuppressionLifetime)
    for url in urls {
      let key = Self.pathKey(url)
      guard folderMutationSuppressions[key] != nil else { continue }
      let state: LibraryFolderMutationSuppression.ExpectedState
      if let installedTrack = tracksByCanonicalPath[key],
        let installedStamp = installedTrack.fileGenerationStamp
      {
        state = .present(installedStamp)
      } else if tracksByCanonicalPath[key] != nil {
        // A failed load can leave a placeholder track without a generation
        // stamp. Its filesystem state was not reliably reflected.
        folderMutationSuppressions.removeValue(forKey: key)
        continue
      } else if FileGenerationStamp(url: url) == nil {
        state = .missing
      } else {
        // A file that exists but is not in the installed catalog was not
        // reflected by the targeted refresh or full scan.
        folderMutationSuppressions.removeValue(forKey: key)
        continue
      }
      folderMutationSuppressions[key] = LibraryFolderMutationSuppression(
        url: url, expectedState: state, expiresAt: expiration)
    }
  }

  private func finishPendingFolderMutationSuppressions() {
    let urls = folderMutationSuppressions.compactMap { _, suppression -> URL? in
      guard case .pending = suppression.expectedState else { return nil }
      return suppression.url
    }
    finishFolderEventSuppressions(at: urls)
  }

  private func cancelFolderEventSuppressions(at urls: [URL]) {
    for url in urls { folderMutationSuppressions.removeValue(forKey: Self.pathKey(url)) }
  }

  nonisolated private static func isFolderEventSuppressed(
    at url: URL, snapshot: LibraryFolderRescanSnapshot
  ) -> Bool {
    let key = Self.pathKey(url)
    guard let suppression = snapshot.suppressions[key],
      suppression.expiresAt > Date()
    else { return false }
    switch suppression.expectedState {
    case .pending:
      return true
    case .present(let expected):
      return FileGenerationStamp(url: url) == expected
    case .missing:
      return FileGenerationStamp(url: url) == nil
    }
  }

  nonisolated private static func pathKey(_ url: URL) -> String {
    canonicalPathComponents(url).joined(separator: "/")
  }

  private func stopWatchingFolder() {
    folderRescanDebounceTask?.cancel()
    folderRescanDebounceTask = nil
    folderRescanEvents = []
    folderRescanPending = false
    folderMutationSuppressions = [:]
    folderWatcher = nil
    watchedFolderURL = nil
  }

  func cancelScan() {
    cancelScan(markCancelled: true)
  }

  private func cancelScan(markCancelled: Bool) {
    scanGeneration &+= 1
    scanTask?.cancel()
    scanTask = nil
    trackRefreshTask?.cancel()
    trackRefreshTask = nil
    scanningFolderURL = nil
    folderRescanPending = false
    scanState = markCancelled ? .cancelled : .idle
  }

  nonisolated static func loadTracks(at urls: [URL]) async -> [LibraryTrack] {
    await loadTracks(
      at: urls, maximumConcurrentTasks: 8,
      loader: { await MetadataLoader.load(url: $0) })
  }

  nonisolated static func loadTracks(
    at urls: [URL],
    maximumConcurrentTasks: Int,
    loader: @escaping @Sendable (URL) async -> LibraryTrack
  ) async -> [LibraryTrack] {
    await mapConcurrently(
      over: urls, maximumConcurrentTasks: maximumConcurrentTasks, transform: loader)
  }

  nonisolated static func scanTracks(
    at urls: [URL],
    consulting cache: [String: LibraryIndexCacheEntry],
    loader: @escaping @Sendable (URL) async -> LibraryTrack = {
      await MetadataLoader.load(url: $0)
    }
  ) async -> (tracks: [LibraryTrack], entries: [String: LibraryIndexCacheEntry]) {
    (try? await scanTracksReportingProgress(
      at: urls, consulting: cache, loader: loader, progress: nil)) ?? ([], [:])
  }

  nonisolated static func scanTracksReportingProgress(
    at urls: [URL],
    consulting cache: [String: LibraryIndexCacheEntry],
    maximumConcurrentTasks: Int = 8,
    loader: @escaping @Sendable (URL) async -> LibraryTrack = {
      await MetadataLoader.load(url: $0)
    },
    progress: (@Sendable (LibraryScanProgress) -> Void)?
  ) async throws -> (tracks: [LibraryTrack], entries: [String: LibraryIndexCacheEntry]) {
    struct Result: Sendable {
      let track: LibraryTrack
      let entry: LibraryIndexCacheEntry?
    }
    struct Miss: Sendable {
      let index: Int
      let url: URL
      let stamp: FileGenerationStamp?
    }

    var results = [Result?](repeating: nil, count: urls.count)
    var misses: [Miss] = []
    misses.reserveCapacity(urls.count)
    progress?(LibraryScanProgress(phase: .checkingCache, completed: 0, total: urls.count))
    for (index, url) in urls.enumerated() {
      try Task.checkCancellation()
      let key = url.standardizedFileURL.path
      let stamp = FileGenerationStamp(url: url)
      if let stamp, let entry = cache[key], entry.stamp == stamp {
        results[index] = Result(track: entry.track, entry: entry)
      } else {
        misses.append(Miss(index: index, url: url, stamp: stamp))
      }
      if (index + 1).isMultiple(of: 64) || index + 1 == urls.count {
        progress?(
          LibraryScanProgress(
            phase: .checkingCache, completed: index + 1, total: urls.count))
      }
    }

    progress?(
      LibraryScanProgress(phase: .loadingMetadata, completed: 0, total: misses.count))
    try await withThrowingTaskGroup(of: (Int, Result).self) { group in
      var nextMiss = 0
      var inFlight = 0
      var completed = 0
      func addNext() {
        guard !Task.isCancelled, nextMiss < misses.count else { return }
        let miss = misses[nextMiss]
        nextMiss += 1
        group.addTask {
          try Task.checkCancellation()
          var track = await loader(miss.url)
          try Task.checkCancellation()
          track.fileGenerationStamp = miss.stamp
          if let stamp = miss.stamp {
            track.sizeBytes = stamp.sizeBytes
            track.modificationDate = stamp.modificationDate
          }
          return (
            miss.index,
            Result(
              track: track,
              entry: miss.stamp.map { LibraryIndexCacheEntry(stamp: $0, track: track) })
          )
        }
        inFlight += 1
      }
      for _ in 0..<min(max(1, maximumConcurrentTasks), misses.count) { addNext() }
      while inFlight > 0 {
        try Task.checkCancellation()
        guard let (index, result) = try await group.next() else { break }
        inFlight -= 1
        results[index] = result
        completed += 1
        if completed.isMultiple(of: 64) || completed == misses.count {
          progress?(
            LibraryScanProgress(
              phase: .loadingMetadata, completed: completed, total: misses.count))
        }
        addNext()
      }
    }
    try Task.checkCancellation()

    var tracks: [LibraryTrack] = []
    tracks.reserveCapacity(results.count)
    var entries: [String: LibraryIndexCacheEntry] = [:]
    entries.reserveCapacity(results.count)
    for optionalResult in results {
      guard let result = optionalResult else { throw CancellationError() }
      tracks.append(result.track)
      if let entry = result.entry {
        entries[result.track.url.standardizedFileURL.path] = entry
      }
    }
    return (tracks, entries)
  }

  private nonisolated static func mapConcurrently<T: Sendable>(
    over urls: [URL],
    maximumConcurrentTasks: Int,
    transform: @escaping @Sendable (URL) async -> T
  ) async -> [T] {
    var loaded = [T?](repeating: nil, count: urls.count)
    await withTaskGroup(of: (index: Int, value: T).self) { group in
      var nextIndex = 0
      var inFlight = 0
      func addNext() {
        guard !Task.isCancelled, nextIndex < urls.count else { return }
        let index = nextIndex
        let url = urls[index]
        nextIndex += 1
        group.addTask { (index, await transform(url)) }
        inFlight += 1
      }
      for _ in 0..<min(max(1, maximumConcurrentTasks), urls.count) { addNext() }
      while inFlight > 0 {
        guard let result = await group.next() else { break }
        inFlight -= 1
        if !Task.isCancelled {
          loaded[result.index] = result.value
          addNext()
        } else {
          group.cancelAll()
        }
      }
    }
    return loaded.compactMap(\.self)
  }

  nonisolated static func findAudioFiles(in folder: URL) -> [URL] {
    (try? discoverAudioFiles(in: folder).urls) ?? []
  }

  private struct AudioFileDiscovery: Sendable {
    let urls: [URL]
    let succeeded: Bool
  }

  nonisolated private static func discoverAudioFiles(
    in folder: URL, progress: (@Sendable (Int) -> Void)? = nil
  ) throws -> AudioFileDiscovery {
    var results: [URL] = []
    var succeeded = true
    var itemsChecked = 0
    let root = folder.resolvingSymlinksInPath().standardizedFileURL
    let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, _ in
        succeeded = false
        return false
      })
    guard let enumerator else { return AudioFileDiscovery(urls: [], succeeded: false) }
    while let item = enumerator.nextObject() as? URL {
      itemsChecked += 1
      if itemsChecked.isMultiple(of: 128) {
        try Task.checkCancellation()
        progress?(itemsChecked)
      }
      guard LibraryAudioFormat(url: item) != nil,
        let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true, values.isSymbolicLink != true
      else { continue }
      let resolved = item.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.isContained(in: root, allowRoot: false) else { continue }
      results.append(item)
    }
    try Task.checkCancellation()
    progress?(itemsChecked)
    return AudioFileDiscovery(
      urls: results.sorted { $0.path < $1.path }, succeeded: succeeded)
  }
}
