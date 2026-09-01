import Foundation

struct SyncPlan: Sendable {
  var copyToDevice: [LibraryTrack] = []
  var copyToFolder: [ITDBTrack] = []
  var updateOnDevice: [SyncDeviceUpdate] = []
  var updateInFolder: [SyncFolderUpdate] = []
  var unsupportedForDevice: [LibraryTrack] = []
  var retainedLinks: [SyncLedgerEntry] = []
  var generationStampRevalidations: [SyncGenerationStampRevalidation] = []
  var adoptedPairs: [SyncAdoptedPair] = []
  var librarySnapshot: [LibraryTrack]
  var localPlaylists: [LocalPlaylist] = []
  var playlistActions: [PlaylistSyncAction] = []
  var localRatings: [String: Int] = [:]
  var removeFromDeviceNotInLibrary: [ITDBTrack] = []
  var removeFromDeviceOutsideScope: [ITDBTrack] = []
  var notInLibraryOnDevice: [ITDBTrack] = []
  var outOfScopeOnDevice: [ITDBTrack] = []
  var excludedByScope: [LibraryTrack] = []
  var localOnlyInLibrary: [LibraryTrack] = []
  var capacityShortfall: Int64? = nil
  var suggestedCapacityTrim: [LibraryTrack] = []
  var scopeInput = SyncScopeInput()

  var removeFromDevice: [ITDBTrack] {
    removeFromDeviceOutsideScope + removeFromDeviceNotInLibrary
  }

  var isEmpty: Bool {
    copyToDevice.isEmpty && copyToFolder.isEmpty
      && updateOnDevice.isEmpty && updateInFolder.isEmpty
      && playlistActions.isEmpty && removeFromDeviceNotInLibrary.isEmpty
      && removeFromDeviceOutsideScope.isEmpty
      && generationStampRevalidations.isEmpty
  }
  var totalSteps: Int {
    copyToDevice.count + copyToFolder.count + updateOnDevice.count + updateInFolder.count
      + playlistActions.count + removeFromDevice.count
  }
}

struct SyncGenerationStampRevalidation: Sendable {
  var local: LibraryTrack
  var entry: SyncLedgerEntry
}

struct SyncDeviceUpdate: Sendable {
  var local: LibraryTrack
  var device: ITDBTrack
  var entry: SyncLedgerEntry
  var delivery: DeviceDelivery = .direct
  var requiresDeviceWrite: Bool = false
}

struct SyncFolderUpdate: Sendable {
  var local: LibraryTrack
  var device: ITDBTrack
  var entry: SyncLedgerEntry
}

struct SyncAdoptedPair: Sendable {
  var local: LibraryTrack
  var device: ITDBTrack
}

struct SyncPlanCache {
  private struct Entry {
    let libraryRevision: UInt64
    let deviceRevision: UInt64
    let playlistsRevision: UInt64
    let transcodeSettings: TranscodeSettings
    let deviceSettings: SyncDeviceSettings
    let scopeFacts: [String: SmartRuleFacts]
    let plan: SyncPlan
  }

  private var entries: [URL: Entry] = [:]
  private(set) var buildCount = 0

  mutating func plan(
    library: [LibraryTrack],
    libraryRevision: UInt64,
    device: IpodDevice
  ) -> SyncPlan {
    plan(
      library: library, libraryRevision: libraryRevision, device: device,
      builder: {
        SyncEngine.makePlan(library: $0, device: $1, deviceFamily: device.family)
      })
  }

  mutating func plan(
    library: [LibraryTrack],
    libraryRevision: UInt64,
    playlistsRevision: UInt64 = 0,
    transcodeSettings: TranscodeSettings = TranscodeSettings(),
    deviceSettings: SyncDeviceSettings = SyncDeviceSettings(),
    scopeFacts: [String: SmartRuleFacts] = [:],
    device: IpodDevice,
    builder: ([LibraryTrack], [ITDBTrack]) -> SyncPlan
  ) -> SyncPlan {
    if let cached = cachedPlan(
      libraryRevision: libraryRevision,
      playlistsRevision: playlistsRevision,
      transcodeSettings: transcodeSettings,
      deviceSettings: deviceSettings,
      scopeFacts: scopeFacts,
      device: device)
    {
      return cached
    }

    let plan = builder(library, device.tracks)
    store(
      plan,
      libraryRevision: libraryRevision,
      playlistsRevision: playlistsRevision,
      transcodeSettings: transcodeSettings,
      deviceSettings: deviceSettings,
      scopeFacts: scopeFacts,
      device: device)
    return plan
  }

  mutating func cachedPlan(
    libraryRevision: UInt64,
    playlistsRevision: UInt64,
    transcodeSettings: TranscodeSettings,
    deviceSettings: SyncDeviceSettings,
    scopeFacts: [String: SmartRuleFacts],
    device: IpodDevice
  ) -> SyncPlan? {
    let deviceID = device.id.standardizedFileURL
    guard let entry = entries[deviceID],
      entry.libraryRevision == libraryRevision,
      entry.deviceRevision == device.derivedDataRevision,
      entry.playlistsRevision == playlistsRevision,
      entry.transcodeSettings == transcodeSettings,
      entry.deviceSettings == deviceSettings,
      entry.scopeFacts == scopeFacts
    else { return nil }
    return entry.plan
  }

  mutating func store(
    _ plan: SyncPlan,
    libraryRevision: UInt64,
    playlistsRevision: UInt64,
    transcodeSettings: TranscodeSettings,
    deviceSettings: SyncDeviceSettings,
    scopeFacts: [String: SmartRuleFacts],
    device: IpodDevice
  ) {
    entries[device.id.standardizedFileURL] = Entry(
      libraryRevision: libraryRevision,
      deviceRevision: device.derivedDataRevision,
      playlistsRevision: playlistsRevision,
      transcodeSettings: transcodeSettings,
      deviceSettings: deviceSettings,
      scopeFacts: scopeFacts,
      plan: plan)
    buildCount += 1
  }
}

struct SyncProgress: Sendable {
  var step: Int
  var totalSteps: Int
  var detail: String

  var fraction: Double { totalSteps == 0 ? 0 : Double(step) / Double(totalSteps) }
}

enum SyncFailureOperation: String, Equatable, Sendable {
  case copyToLibrary
  case reconstructMetadata
  case copyToDevice
  case updateOnDevice
  case updateInFolder
  case removeFromDevice
  case saveLedger
  case savePlaylists
  case mergePlayCounts
  case writeArtwork

  var title: String {
    switch self {
    case .copyToLibrary: String(localized: "Copy to Library")
    case .reconstructMetadata: String(localized: "Reconstruct Metadata")
    case .copyToDevice: String(localized: "Copy to iPod")
    case .updateOnDevice: String(localized: "Update on iPod")
    case .updateInFolder: String(localized: "Update in Library")
    case .removeFromDevice: String(localized: "Remove from iPod")
    case .saveLedger: String(localized: "Save Sync Ledger")
    case .savePlaylists: String(localized: "Save Playlists")
    case .mergePlayCounts: String(localized: "Merge Play Counts")
    case .writeArtwork: String(localized: "Write Album Art")
    }
  }

  var systemImage: String {
    switch self {
    case .copyToLibrary: "arrow.down.doc"
    case .reconstructMetadata: "tag"
    case .copyToDevice: "arrow.up.doc"
    case .updateOnDevice: "arrow.up.doc.on.clipboard"
    case .updateInFolder: "pencil.line"
    case .removeFromDevice: "trash"
    case .saveLedger: "list.bullet.rectangle"
    case .savePlaylists: "music.note.list"
    case .mergePlayCounts: "clock.arrow.circlepath"
    case .writeArtwork: "photo"
    }
  }
}

struct SyncFailure: Equatable, Sendable, CustomStringConvertible {
  let operation: SyncFailureOperation
  let path: String
  let reason: String

  var description: String {
    String(localized: "\(operation.title) — \(path): \(reason)")
  }
}

struct SyncResult: Equatable, Sendable {
  var copiedToDevice = 0
  var copiedToFolder = 0
  var updatedOnDevice = 0
  var updatedInFolder = 0
  var removedFromDevice = 0
  var scopeNotes: [String] = []
  var failures: [SyncFailure] = []

  var playlistsCreatedOnDevice = 0
  var playlistsUpdatedOnDevice = 0
  var playlistsDeletedOnDevice = 0
  var playlistsCreatedInLibrary = 0
  var playlistsUpdatedInLibrary = 0
  var playlistsDeletedInLibrary = 0
  var playlistNotes: [String] = []
  var playlistActionSummaries: [String] = []
  var libraryPlaylistActions: [PlaylistSyncAction] = []
  var playlistLinks: [SyncPlaylistLink] = []
  var pendingPlaylistLinks: [SyncPlaylistLink] = []
  var onTheGoImports: [OnTheGoImport] = []
  var onTheGoFilesToDelete: [URL] = []

  var playbackReport: DevicePlaybackReport? = nil
  var playCountsFilesToDelete: [URL] = []
  var playbackNotes: [String] = []
  var devicePlaysMerged = 0
  var devicePlaybackNote: String? = nil

  var artworkImagesWritten = 0
  var artworkNotes: [String] = []
  var databaseID: UInt64? = nil
  var syncedPlaylists = false

  var totalPlaylistChanges: Int {
    playlistsCreatedOnDevice + playlistsUpdatedOnDevice + playlistsDeletedOnDevice
      + playlistsCreatedInLibrary + playlistsUpdatedInLibrary + playlistsDeletedInLibrary
      + onTheGoImports.count
  }

  mutating func fail(_ operation: SyncFailureOperation, _ path: String, _ reason: String) {
    failures.append(SyncFailure(operation: operation, path: path, reason: reason))
  }
}

struct SyncDetailsModel: Equatable, Sendable {
  let result: SyncResult

  var title: String {
    result.failures.isEmpty
      ? String(localized: "Sync Complete") : String(localized: "Sync Completed with Issues")
  }

  var summary: String {
    var parts: [String] = []
    if result.copiedToDevice > 0 {
      parts.append(
        Self.count(
          result.copiedToDevice,
          singular: String(localized: "\(result.copiedToDevice) track copied to iPod"),
          plural: String(localized: "\(result.copiedToDevice) tracks copied to iPod")))
    }
    if result.copiedToFolder > 0 {
      parts.append(
        Self.count(
          result.copiedToFolder,
          singular: String(localized: "\(result.copiedToFolder) track copied to library"),
          plural: String(localized: "\(result.copiedToFolder) tracks copied to library")))
    }
    if result.updatedOnDevice > 0 {
      parts.append(
        Self.count(
          result.updatedOnDevice,
          singular: String(localized: "\(result.updatedOnDevice) track updated on iPod"),
          plural: String(localized: "\(result.updatedOnDevice) tracks updated on iPod")))
    }
    if result.updatedInFolder > 0 {
      parts.append(
        Self.count(
          result.updatedInFolder,
          singular: String(localized: "\(result.updatedInFolder) track updated in library"),
          plural: String(localized: "\(result.updatedInFolder) tracks updated in library")))
    }
    if result.removedFromDevice > 0 {
      parts.append(
        Self.count(
          result.removedFromDevice,
          singular: String(localized: "\(result.removedFromDevice) track removed from iPod"),
          plural: String(localized: "\(result.removedFromDevice) tracks removed from iPod")))
    }
    if result.totalPlaylistChanges > 0 {
      parts.append(
        Self.count(
          result.totalPlaylistChanges,
          singular: String(localized: "\(result.totalPlaylistChanges) playlist change"),
          plural: String(localized: "\(result.totalPlaylistChanges) playlist changes")))
    }
    if let note = result.devicePlaybackNote {
      parts.append(note)
    } else if result.devicePlaysMerged > 0 {
      parts.append(
        Self.count(
          result.devicePlaysMerged,
          singular: String(localized: "\(result.devicePlaysMerged) play picked up from iPod"),
          plural: String(localized: "\(result.devicePlaysMerged) plays picked up from iPod")))
    }
    if result.artworkImagesWritten > 0 {
      parts.append(
        Self.count(
          result.artworkImagesWritten,
          singular: String(localized: "\(result.artworkImagesWritten) cover written to iPod"),
          plural: String(localized: "\(result.artworkImagesWritten) covers written to iPod")))
    }
    if !result.failures.isEmpty {
      parts.append(
        Self.count(
          result.failures.count,
          singular: String(localized: "\(result.failures.count) failed operation"),
          plural: String(localized: "\(result.failures.count) failed operations")))
    }
    return parts.isEmpty
      ? String(localized: "Everything was already in sync.") : parts.joined(separator: " · ")
  }

  var headUnitSummary: String {
    var parts: [String] = []
    if result.copiedToDevice > 0 {
      parts.append(String(localized: "\(result.copiedToDevice) TO IPOD"))
    }
    if result.copiedToFolder > 0 {
      parts.append(String(localized: "\(result.copiedToFolder) TO LIBRARY"))
    }
    if result.updatedOnDevice > 0 {
      parts.append(String(localized: "\(result.updatedOnDevice) UPDATED ON IPOD"))
    }
    if result.updatedInFolder > 0 {
      parts.append(String(localized: "\(result.updatedInFolder) UPDATED IN LIBRARY"))
    }
    if result.removedFromDevice > 0 {
      parts.append(String(localized: "\(result.removedFromDevice) REMOVED"))
    }
    if result.totalPlaylistChanges > 0 {
      parts.append(String(localized: "\(result.totalPlaylistChanges) PLAYLISTS"))
    }
    if result.devicePlaysMerged > 0 {
      parts.append(String(localized: "\(result.devicePlaysMerged) PLAYS IN"))
    }
    if result.artworkImagesWritten > 0 {
      parts.append(String(localized: "\(result.artworkImagesWritten) COVERS"))
    }
    if !result.failures.isEmpty {
      parts.append(String(localized: "\(result.failures.count) FAILED"))
    }
    return parts.isEmpty ? String(localized: "ALREADY IN SYNC") : parts.joined(separator: " · ")
  }

  private static func count(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? singular : plural
  }
}

enum SyncError: Error, LocalizedError {
  case notEnoughSpace(needed: Int64, available: Int64)
  case deviceCapacityUnavailable(underlying: String)
  case localCopyIdentityUnavailable
  case metadataVerificationFailed

  var errorDescription: String? {
    switch self {
    case .deviceCapacityUnavailable(let underlying):
      return String(
        localized: "Could not read the iPod's free space: \(underlying)")
    case .notEnoughSpace(let needed, let available):
      let f = ByteCountFormatter()
      let neededDescription = f.string(fromByteCount: needed)
      let availableDescription = f.string(fromByteCount: available)
      return String(
        localized:
          "Not enough free space on the iPod: need \(neededDescription), have \(availableDescription).")
    case .localCopyIdentityUnavailable:
      return String(localized: "The copied audio could not be identified before it was published.")
    case .metadataVerificationFailed:
      return String(
        localized: "The intended metadata was not readable from the file after writing.")
    }
  }
}

/// The side-effecting operations a sync performs, injectable so tests can
/// simulate failures at each seam. Defaults perform the real work.
struct OutboundFileDescription: Sendable {
  var track: LibraryTrack
  var artwork: Data?
}

struct SyncEngineEffects: Sendable {
  var tagWriter: @Sendable (URL, ITDBTrack) async throws -> Void = { url, track in
    try await SyncEngine.addTagsIfMissing(to: url, from: track)
  }
  var metadataWriter: @Sendable (TrackMetadata, URL) throws -> Void = {
    try TrackFileMetadataWriter.write($0, artworkChange: .unchanged, to: $1)
  }
  var databaseWriter: @Sendable (IpodFileSystem, ITunesDatabase) throws -> Void = {
    try $0.writeDatabase($1)
  }
  var databaseVerificationReader: @Sendable (IpodFileSystem) throws -> ITunesDatabase = {
    try $0.readDatabase()
  }
  var artworkRecoveryMarkerWriter: ArtworkDBTransaction.RecoveryMarkerWriter = { data, url in
    try ArtworkDBTransaction.writeRecoveryMarker(data, to: url)
  }
  var artworkCommitter: @Sendable (ArtworkDBTransaction) throws -> Void = {
    try $0.commit()
  }
  var destinationAllocator: @Sendable (IpodFileSystem, String, Set<URL>) throws -> URL = {
    fileSystem, fileExtension, reservedDestinations in
    try fileSystem.destinationForNewFile(
      extension: fileExtension, excluding: reservedDestinations)
  }
  var removalStager: @Sendable (IpodFileSystem, UInt64, String) throws -> IpodDeleteTransaction? = {
    fileSystem, dbid, ipodPath in
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    guard try transaction.stageMusicFileIfPresent(dbid: dbid, ipodPath: ipodPath) else {
      return nil
    }
    return transaction
  }
  var outboundFileDescriber: @Sendable (URL, OutboundSourceSnapshot, LoudnessStore) async -> OutboundFileDescription = {
    url, snapshot, loudness in
    var track = await MetadataLoader.load(url: url)
    if track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      track.title = snapshot.originalURL.deletingPathExtension().lastPathComponent
    }
    track.gapless = await GaplessScanner.scan(url: url)
    if track.mediaKind == .song {
      track.gainDB = loudness.gain(
        forCapturedSource: snapshot.originalURL,
        fileGenerationStamp: snapshot.fileGenerationStamp,
        measuring: snapshot.url)
    }
    return OutboundFileDescription(
      track: track, artwork: await MetadataLoader.loadArtwork(url: snapshot.url))
  }
}
