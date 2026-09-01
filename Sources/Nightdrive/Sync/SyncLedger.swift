import CryptoKit
import Foundation

struct SyncLedgerEntry: Codable, Equatable, Sendable {
  var relativePath: String
  var dbid: UInt64
  var fileSize: Int
  var fileModifiedAt: Double
  var fileGenerationStamp: FileGenerationStamp
  var contentSHA256: String
  var deviceSignature: String
  var needsMetadataReconstruction = false
  var lastSyncedRating: Int? = nil
  var artworkSHA256: String? = nil
  var transcodeProfile: String? = nil

  enum CodingKeys: String, CodingKey {
    case relativePath, dbid, fileSize, fileModifiedAt, fileGenerationStamp
    case contentSHA256, deviceSignature, needsMetadataReconstruction
    case lastSyncedRating, artworkSHA256, transcodeProfile
  }
}

/// Fields added after a release decode with their defaults so ledgers
/// written by older versions keep loading instead of failing integrity
/// checks on upgrade.
extension SyncLedgerEntry {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    relativePath = try container.decode(String.self, forKey: .relativePath)
    dbid = try container.decode(UInt64.self, forKey: .dbid)
    fileSize = try container.decode(Int.self, forKey: .fileSize)
    fileModifiedAt = try container.decode(Double.self, forKey: .fileModifiedAt)
    fileGenerationStamp = try container.decode(
      FileGenerationStamp.self, forKey: .fileGenerationStamp)
    contentSHA256 = try container.decode(String.self, forKey: .contentSHA256)
    deviceSignature = try container.decode(String.self, forKey: .deviceSignature)
    needsMetadataReconstruction =
      try container.decodeIfPresent(Bool.self, forKey: .needsMetadataReconstruction) ?? false
    lastSyncedRating = try container.decodeIfPresent(Int.self, forKey: .lastSyncedRating)
    artworkSHA256 = try container.decodeIfPresent(String.self, forKey: .artworkSHA256)
    transcodeProfile = try container.decodeIfPresent(String.self, forKey: .transcodeProfile)
  }
}

struct SyncPlaylistLink: Codable, Equatable, Sendable {
  var localID: UUID
  var persistentID: UInt64
  var name: String
  var memberDbids: [UInt64]
}

struct SyncLedger: Codable, Equatable, Sendable {
  var devices: [String: [SyncLedgerEntry]] = [:]
  var playlists: [String: [SyncPlaylistLink]] = [:]
  var settings: [String: SyncDeviceSettings] = [:]

  static func deviceKey(_ databaseID: UInt64) -> String {
    String(databaseID, radix: 16)
  }
}

struct SyncLink: Sendable {
  var local: LibraryTrack
  var device: ITDBTrack
  var entry: SyncLedgerEntry
}

enum SyncLedgerStore {
  static let filename = ".nightdrive-sync.json"

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }

  static func loadOutcome(libraryFolder: URL) -> AppDataLoadOutcome<SyncLedger> {
    SidecarJSONFile.loadOutcome(SyncLedger.self, at: url(for: libraryFolder))
  }

  /// Loads the ledger for read-only callers that must not fail, treating an
  /// unreadable or malformed ledger as empty. The failure is still recorded:
  /// an empty ledger can duplicate copies on the next sync.
  private static func loadTreatingFailureAsEmpty(libraryFolder: URL) -> SyncLedger {
    do {
      return try load(libraryFolder: libraryFolder)
    } catch {
      NightdriveLog.sync.error(
        "Sync ledger is unreadable; treating it as empty: \(error.localizedDescription, privacy: .public)"
      )
      return SyncLedger()
    }
  }

  static func load(libraryFolder: URL) throws -> SyncLedger {
    try loadOutcome(libraryFolder: libraryFolder).unwrap(
      url: url(for: libraryFolder), whenMissing: SyncLedger(),
      malformedRecoveryInstruction: String(
        localized:
          "Repair it, or explicitly start with an empty sync ledger. Starting empty can duplicate copies and change which songs are eligible for removal."
      ))
  }

  static func entries(for databaseID: UInt64, libraryFolder: URL) -> [SyncLedgerEntry] {
    let ledger = loadTreatingFailureAsEmpty(libraryFolder: libraryFolder)
    return ledger.devices[SyncLedger.deviceKey(databaseID)] ?? []
  }

  static func checkedEntries(
    for databaseID: UInt64, libraryFolder: URL
  ) throws -> [SyncLedgerEntry] {
    try load(libraryFolder: libraryFolder).devices[SyncLedger.deviceKey(databaseID)] ?? []
  }

  static func playlistLinks(for databaseID: UInt64, libraryFolder: URL) -> [SyncPlaylistLink] {
    let ledger = loadTreatingFailureAsEmpty(libraryFolder: libraryFolder)
    return ledger.playlists[SyncLedger.deviceKey(databaseID)] ?? []
  }

  static func checkedPlaylistLinks(
    for databaseID: UInt64, libraryFolder: URL
  ) throws -> [SyncPlaylistLink] {
    try load(libraryFolder: libraryFolder).playlists[SyncLedger.deviceKey(databaseID)] ?? []
  }

  static func replaceEntries(
    _ entries: [SyncLedgerEntry], for databaseID: UInt64, libraryFolder: URL
  ) throws {
    var ledger = try load(libraryFolder: libraryFolder)
    let key = SyncLedger.deviceKey(databaseID)
    if ledger.devices[key] == entries { return }
    if entries.isEmpty {
      ledger.devices.removeValue(forKey: key)
    } else {
      ledger.devices[key] = entries
    }
    try write(ledger, libraryFolder: libraryFolder)
  }

  static func replacePlaylistLinks(
    _ links: [SyncPlaylistLink], for databaseID: UInt64, libraryFolder: URL
  ) throws {
    var ledger = try load(libraryFolder: libraryFolder)
    let key = SyncLedger.deviceKey(databaseID)
    let sorted = links.sorted { $0.persistentID < $1.persistentID }
    if (ledger.playlists[key] ?? []) == sorted { return }
    if sorted.isEmpty {
      ledger.playlists.removeValue(forKey: key)
    } else {
      ledger.playlists[key] = sorted
    }
    try write(ledger, libraryFolder: libraryFolder)
  }

  static func deviceSettings(for databaseID: UInt64, libraryFolder: URL) -> SyncDeviceSettings {
    let ledger = loadTreatingFailureAsEmpty(libraryFolder: libraryFolder)
    return ledger.settings[SyncLedger.deviceKey(databaseID)] ?? SyncDeviceSettings()
  }

  static func checkedDeviceSettings(
    for databaseID: UInt64, libraryFolder: URL
  ) throws -> SyncDeviceSettings {
    try load(libraryFolder: libraryFolder).settings[SyncLedger.deviceKey(databaseID)]
      ?? SyncDeviceSettings()
  }

  static func replaceDeviceSettings(
    _ settings: SyncDeviceSettings, for databaseID: UInt64, libraryFolder: URL
  ) throws {
    var ledger = try load(libraryFolder: libraryFolder)
    let key = SyncLedger.deviceKey(databaseID)
    if (ledger.settings[key] ?? SyncDeviceSettings()) == settings { return }
    if settings == SyncDeviceSettings() {
      ledger.settings.removeValue(forKey: key)
    } else {
      ledger.settings[key] = settings
    }
    try write(ledger, libraryFolder: libraryFolder)
  }

  private static func write(_ ledger: SyncLedger, libraryFolder: URL) throws {
    let fileURL = url(for: libraryFolder)
    try SidecarJSONFile.save(ledger, to: fileURL)
  }

  /// Preserves a ledger rejected by `load` and leaves the store genuinely
  /// missing so a user-confirmed retry can start without remembered links.
  static func assumeEmptyAfterIntegrityWarning(libraryFolder: URL) throws -> URL? {
    let fileURL = url(for: libraryFolder)
    switch loadOutcome(libraryFolder: libraryFolder) {
    case .missing:
      return nil
    case .loaded:
      throw SidecarRecovery.Refusal.intact(path: fileURL.path)
    case .malformed, .unreadable:
      let quarantine = SidecarRecovery.quarantineURL(for: fileURL)
      try FileManager.default.moveItem(at: fileURL, to: quarantine)
      return quarantine
    }
  }

  static func resolveLinks(
    entries: [SyncLedgerEntry],
    library: [LibraryTrack],
    device: [ITDBTrack],
    libraryFolder: URL
  ) -> [SyncLink] {
    guard !entries.isEmpty else { return [] }
    let root = libraryFolder.standardizedFileURL
    var localByPath: [String: LibraryTrack] = [:]
    for track in library {
      localByPath[track.url.standardizedFileURL.path] = track
    }
    var localByResolvedPath: [String: LibraryTrack]?
    func resolvedLookupTable() -> [String: LibraryTrack] {
      if let localByResolvedPath { return localByResolvedPath }
      var resolved: [String: LibraryTrack] = [:]
      for track in library {
        resolved[track.url.resolvingSymlinksInPath().standardizedFileURL.path] = track
      }
      localByResolvedPath = resolved
      return resolved
    }
    func localTrack(for candidate: URL) -> LibraryTrack? {
      if let track = localByPath[candidate.path] { return track }
      return resolvedLookupTable()[candidate.resolvingSymlinksInPath().standardizedFileURL.path]
    }
    var deviceByDbid: [UInt64: ITDBTrack] = [:]
    for track in device where deviceByDbid[track.dbid] == nil {
      deviceByDbid[track.dbid] = track
    }
    var links: [SyncLink] = []
    var usedURLs: Set<URL> = []
    var usedDbids: Set<UInt64> = []
    for entry in entries {
      guard !entry.relativePath.isEmpty, !entry.relativePath.hasPrefix("/") else { continue }
      let candidate = root.appendingPathComponent(entry.relativePath).standardizedFileURL
      guard PathContainment.path(candidate.path, isInside: root.path, allowRoot: false)
      else { continue }
      guard let local = localTrack(for: candidate), let device = deviceByDbid[entry.dbid],
        !usedURLs.contains(local.url), !usedDbids.contains(entry.dbid)
      else { continue }
      usedURLs.insert(local.url)
      usedDbids.insert(entry.dbid)
      links.append(SyncLink(local: local, device: device, entry: entry))
    }
    return links
  }

  static func relativePath(for fileURL: URL, in libraryFolder: URL) -> String? {
    PathContainment.relativePath(
      of: fileURL.canonicalFileURL.path, inside: libraryFolder.canonicalFileURL.path)
  }

  /// Rewrites ledger entries after library files move inside the root, so an
  /// organize pass followed by a sync stays a no-op. The generation stamp is
  /// recaptured from the destination because a rename changes the file's
  /// ctime while its content, size, and mtime stay identical.
  static func remapMovedFiles(
    _ movesByRelativePath: [String: String], libraryFolder: URL
  ) throws {
    guard !movesByRelativePath.isEmpty else { return }
    var ledger = try load(libraryFolder: libraryFolder)
    var changed = false
    var stamps: [String: FileGenerationStamp?] = [:]
    func stamp(for relativePath: String) -> FileGenerationStamp? {
      if let cached = stamps[relativePath] { return cached }
      let stamp = FileGenerationStamp(
        url: libraryFolder.appendingPathComponent(relativePath))
      stamps[relativePath] = stamp
      return stamp
    }
    for (device, entries) in ledger.devices {
      var updated = entries
      for index in updated.indices {
        guard let destination = movesByRelativePath[updated[index].relativePath] else {
          continue
        }
        updated[index].relativePath = destination
        if let stamp = stamp(for: destination) {
          updated[index].fileGenerationStamp = stamp
          updated[index].fileSize = stamp.sizeBytes
          updated[index].fileModifiedAt = stamp.modificationDate.timeIntervalSince1970
        }
        changed = true
      }
      ledger.devices[device] = updated
    }
    guard changed else { return }
    try write(ledger, libraryFolder: libraryFolder)
  }

}

enum SyncSignature {
  static func fileSHA256(url: URL) throws -> String {
    try fileSHA256(url: url, isCancelled: { false })
  }

  static func fileSHA256(
    url: URL, isCancelled: () -> Bool
  ) throws -> String {
    guard !isCancelled() else { throw CancellationError() }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while !isCancelled(),
      let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty
    {
      hasher.update(data: chunk)
    }
    guard !isCancelled() else { throw CancellationError() }
    return hasher.finalize().hexString
  }

  static func deviceSignature(for track: ITDBTrack) -> String {
    let metadata = TrackMetadata(track).normalized
    let fields: [String] = [
      metadata.title, metadata.artist, metadata.album, metadata.albumArtist,
      metadata.composer, metadata.genre, metadata.comment,
      String(metadata.year), String(metadata.trackNumber), String(metadata.trackCount),
      String(metadata.discNumber), String(metadata.discCount),
      metadata.compilation ? "1" : "0",
      String(track.sizeBytes),
    ]
    let canonical = fields.joined(separator: "\u{1F}")
    return SHA256.hash(data: Data(canonical.utf8)).hexString
  }

  static func starRating(for track: ITDBTrack) -> Int {
    min(5, Int(track.rating) / 20)
  }

  static func localLooksChanged(_ track: LibraryTrack, entry: SyncLedgerEntry) -> Bool {
    guard let current = track.fileGenerationStamp else { return true }
    let reconciled = entry.fileGenerationStamp
    if current != reconciled, current.matchesStableIdentity(reconciled) {
      return false
    }
    return current != reconciled
  }

  static func needsHashReverification(_ track: LibraryTrack, entry: SyncLedgerEntry) -> Bool {
    guard let current = track.fileGenerationStamp else { return false }
    let reconciled = entry.fileGenerationStamp
    return current != reconciled && current.matchesStableIdentity(reconciled)
  }
}
