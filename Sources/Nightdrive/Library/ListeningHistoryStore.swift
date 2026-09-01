import Foundation
import Observation

struct TrackListeningMetadata: Codable, Equatable, Sendable {
  let trackID: TrackID
  var rating: Int
  var isFavorite: Bool
  var playCount: Int
  var lastPlayedAt: Date?
  var skipCount: Int
  var bookmarkMS: Int?
  var lastSkippedAt: Date?

  init(
    trackID: TrackID,
    rating: Int = 0,
    isFavorite: Bool = false,
    playCount: Int = 0,
    lastPlayedAt: Date? = nil,
    skipCount: Int = 0,
    bookmarkMS: Int? = nil,
    lastSkippedAt: Date? = nil
  ) {
    self.trackID = trackID
    self.rating = min(max(rating, 0), 5)
    self.isFavorite = isFavorite
    self.playCount = max(playCount, 0)
    self.lastPlayedAt = lastPlayedAt
    self.skipCount = max(skipCount, 0)
    self.bookmarkMS = bookmarkMS.map { max($0, 0) }
    self.lastSkippedAt = lastSkippedAt
  }
}

extension TrackListeningMetadata {
  private enum CodingKeys: String, CodingKey {
    case trackID
    case rating
    case isFavorite
    case playCount
    case lastPlayedAt
    case skipCount
    case bookmarkMS
    case lastSkippedAt
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      trackID: try values.decode(TrackID.self, forKey: .trackID),
      rating: try values.decode(Int.self, forKey: .rating),
      isFavorite: try values.decode(Bool.self, forKey: .isFavorite),
      playCount: try values.decode(Int.self, forKey: .playCount),
      lastPlayedAt: try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt),
      skipCount: try values.decode(Int.self, forKey: .skipCount),
      bookmarkMS: try values.decodeIfPresent(Int.self, forKey: .bookmarkMS),
      lastSkippedAt: try values.decodeIfPresent(Date.self, forKey: .lastSkippedAt))
  }

}

enum ListeningHistorySource: String, Codable, Equatable, Sendable {
  case local
  case device
}

struct ListeningHistoryEntry: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let trackID: TrackID
  let playedAt: Date
  let source: ListeningHistorySource

  init(
    id: UUID = UUID(), trackID: TrackID, playedAt: Date,
    source: ListeningHistorySource = .local
  ) {
    self.id = id
    self.trackID = trackID
    self.playedAt = playedAt
    self.source = source
  }
}

struct ListeningHistoryPayload: Codable, Sendable {
  var metadataByID: [String: TrackListeningMetadata]
  var history: [ListeningHistoryEntry]
  var appliedDeviceReportIDs: [UUID] = []

}

private struct ListeningHistoryPersistenceSnapshot: Encodable, Sendable {
  let metadataByID: [TrackID: TrackListeningMetadata]
  let history: [ListeningHistoryEntry]
  let appliedDeviceReportIDs: [UUID]

  func encode(to encoder: Encoder) throws {
    let payload = ListeningHistoryPayload(
      metadataByID: Dictionary(
        uniqueKeysWithValues: metadataByID.map { ($0.key.rawValue, $0.value) }),
      history: history,
      appliedDeviceReportIDs: appliedDeviceReportIDs)
    try payload.encode(to: encoder)
  }
}

enum DevicePlaybackMerge {
  static let appliedReportIDLimit = 16

  struct Outcome: Sendable {
    var metadata: [TrackID: TrackListeningMetadata]
    var history: [ListeningHistoryEntry]
    var appliedReportIDs: [UUID]
    var applied: Bool
    var mergedPlays: Int
  }

  static func apply(
    report: DevicePlaybackReport,
    metadata: [TrackID: TrackListeningMetadata],
    history: [ListeningHistoryEntry],
    appliedReportIDs: [UUID],
    historyLimit: Int
  ) -> Outcome {
    guard !appliedReportIDs.contains(report.id) else {
      return Outcome(
        metadata: metadata, history: history, appliedReportIDs: appliedReportIDs,
        applied: false, mergedPlays: 0)
    }
    var metadata = metadata
    var history = history
    var mergedPlays = 0
    for entry in report.entries {
      guard let url = entry.localURL else { continue }
      let trackID = TrackID(url: url)
      var value = metadata[trackID] ?? TrackListeningMetadata(trackID: trackID)
      if entry.playCountDelta > 0 {
        value.playCount += min(entry.playCountDelta, Int.max - value.playCount)
        if let played = entry.lastPlayed, played > (value.lastPlayedAt ?? .distantPast) {
          value.lastPlayedAt = played
        }
        let playedAt = entry.lastPlayed ?? Date()
        for _ in 0..<min(entry.playCountDelta, historyLimit) {
          history.append(
            ListeningHistoryEntry(trackID: trackID, playedAt: playedAt, source: .device))
        }
        mergedPlays += entry.playCountDelta
      }
      if entry.skipCountDelta > 0 {
        value.skipCount += min(entry.skipCountDelta, Int.max - value.skipCount)
      }
      if let bookmarkMS = entry.bookmarkMS {
        value.bookmarkMS = max(bookmarkMS, 0)
      }
      if let skipped = entry.lastSkipped,
        skipped > (value.lastSkippedAt ?? .distantPast)
      {
        value.lastSkippedAt = skipped
      }
      if let stars = entry.deviceRating {
        value.rating = min(max(stars, 0), 5)
      }
      metadata[trackID] = value
    }
    history.sort { $0.playedAt > $1.playedAt }
    if history.count > historyLimit {
      history.removeLast(history.count - historyLimit)
    }
    var ids = appliedReportIDs + [report.id]
    if ids.count > appliedReportIDLimit {
      ids.removeFirst(ids.count - appliedReportIDLimit)
    }
    return Outcome(
      metadata: metadata, history: history, appliedReportIDs: ids,
      applied: true, mergedPlays: mergedPlays)
  }
}

@Observable
@MainActor
final class ListeningHistoryStore {
  struct StateSnapshot {
    fileprivate let metadataByID: [TrackID: TrackListeningMetadata]
    fileprivate let history: [ListeningHistoryEntry]
    fileprivate let appliedDeviceReportIDs: [UUID]
    fileprivate let revision: UInt64
    fileprivate let engine: DebouncedPersistenceEngine<ListeningHistoryPersistenceSnapshot>.StateSnapshot
  }

  private(set) var metadataByID: [TrackID: TrackListeningMetadata] = [:]
  private(set) var history: [ListeningHistoryEntry] = []
  private(set) var revision: UInt64 = 0
  var persistenceError: String? { engine.persistenceError }
  @ObservationIgnored private(set) var appliedDeviceReportIDs: [UUID] = []

  @ObservationIgnored private let engine: DebouncedPersistenceEngine<ListeningHistoryPersistenceSnapshot>
  @ObservationIgnored private var libraryFolder: URL?
  private let historyLimit: Int

  init(
    persistence: any AppDataPersistence,
    historyLimit: Int = 500,
    persistenceDebounce: Duration = .milliseconds(150)
  ) {
    engine = DebouncedPersistenceEngine(persistence: persistence, debounce: persistenceDebounce)
    self.historyLimit = max(historyLimit, 0)
    engine.snapshotProvider = { [weak self] in self?.persistenceSnapshot() }
    load()
  }

  init(
    libraryFolder: URL?, historyLimit: Int = 500,
    persistenceDebounce: Duration = .milliseconds(150)
  ) {
    let folder = libraryFolder?.standardizedFileURL
    self.libraryFolder = folder
    engine = DebouncedPersistenceEngine(
      persistence: Self.persistence(for: folder), debounce: persistenceDebounce)
    self.historyLimit = max(historyLimit, 0)
    engine.snapshotProvider = { [weak self] in self?.persistenceSnapshot() }
    load()
  }

  func useLibraryFolder(_ libraryFolder: URL?, resourceChanged: Bool = false) {
    let folder = libraryFolder?.standardizedFileURL
    guard resourceChanged || folder != self.libraryFolder else { return }
    self.libraryFolder = folder
    engine.usePersistence(Self.persistence(for: folder))
    metadataByID = [:]
    history = []
    appliedDeviceReportIDs = []
    load()
    revision &+= 1
  }

  func reloadFromPersistence(discardingPendingChanges: Bool = false) throws {
    try engine.reloadFromPersistence(discardingPendingChanges: discardingPendingChanges) {
      load()
      revision &+= 1
    }
  }

  func stateSnapshot() -> StateSnapshot {
    StateSnapshot(
      metadataByID: metadataByID, history: history,
      appliedDeviceReportIDs: appliedDeviceReportIDs,
      revision: revision,
      engine: engine.stateSnapshot())
  }

  func restoreState(_ snapshot: StateSnapshot) {
    metadataByID = snapshot.metadataByID
    history = snapshot.history
    appliedDeviceReportIDs = snapshot.appliedDeviceReportIDs
    revision = snapshot.revision
    engine.restoreState(snapshot.engine)
  }

  func setMutationValidator(_ validator: @escaping () throws -> Void) {
    engine.setMutationValidator(validator)
  }

  func dismissPersistenceError() {
    engine.dismissPersistenceError()
  }

  var canReloadDiscardingPendingChanges: Bool {
    engine.canReloadDiscardingPendingChanges
  }

  func metadata(for trackID: TrackID) -> TrackListeningMetadata {
    metadataByID[trackID] ?? TrackListeningMetadata(trackID: trackID)
  }

  func rating(for trackID: TrackID) -> Int {
    metadataByID[trackID]?.rating ?? 0
  }

  func isFavorite(_ trackID: TrackID) -> Bool {
    metadataByID[trackID]?.isFavorite ?? false
  }

  func playCount(for trackID: TrackID) -> Int {
    metadataByID[trackID]?.playCount ?? 0
  }

  func lastPlayedAt(for trackID: TrackID) -> Date? {
    metadataByID[trackID]?.lastPlayedAt
  }

  func bookmarkMS(for trackID: TrackID) -> Int? {
    metadataByID[trackID]?.bookmarkMS
  }

  func setBookmarkMS(_ bookmarkMS: Int?, for trackID: TrackID) throws {
    let bookmarkMS = bookmarkMS.map { max($0, 0) }
    guard metadataByID[trackID]?.bookmarkMS != bookmarkMS else { return }
    // Avoid creating an otherwise-empty metadata row just because playback
    // briefly selected a bookmarkable track at its beginning.
    guard bookmarkMS.map({ $0 > 0 }) == true || metadataByID[trackID] != nil else { return }
    try update { metadata, _ in
      var value = metadata[trackID] ?? TrackListeningMetadata(trackID: trackID)
      value.bookmarkMS = bookmarkMS
      metadata[trackID] = value
    }
  }

  func setRating(_ rating: Int, for trackID: TrackID) throws {
    try setRating(rating, for: [trackID])
  }

  func setRating(_ rating: Int, for trackIDs: [TrackID]) throws {
    try update { metadata, _ in
      for trackID in Self.uniqueIDs(trackIDs) {
        var value = metadata[trackID] ?? TrackListeningMetadata(trackID: trackID)
        value.rating = min(max(rating, 0), 5)
        metadata[trackID] = value
      }
    }
  }

  func setFavorite(_ isFavorite: Bool, for trackIDs: [TrackID]) throws {
    try update { metadata, _ in
      for trackID in Self.uniqueIDs(trackIDs) {
        var value = metadata[trackID] ?? TrackListeningMetadata(trackID: trackID)
        value.isFavorite = isFavorite
        metadata[trackID] = value
      }
    }
  }

  @discardableResult
  func toggleFavorite(_ trackID: TrackID) throws -> Bool {
    let result = !isFavorite(trackID)
    try setFavorite(result, for: [trackID])
    return result
  }

  func recordPlay(of trackID: TrackID, at date: Date = Date()) throws {
    try update { metadata, history in
      var value = metadata[trackID] ?? TrackListeningMetadata(trackID: trackID)
      if value.playCount < Int.max {
        value.playCount += 1
      }
      value.lastPlayedAt = date
      metadata[trackID] = value
      history.insert(ListeningHistoryEntry(trackID: trackID, playedAt: date), at: 0)
      if history.count > historyLimit {
        history.removeLast(history.count - historyLimit)
      }
    }
  }

  func clearHistory() throws {
    try update { _, history in history.removeAll() }
  }

  @discardableResult
  func merge(_ report: DevicePlaybackReport) throws -> Int {
    try ensurePersistenceWritable()
    let outcome = DevicePlaybackMerge.apply(
      report: report, metadata: metadataByID, history: history,
      appliedReportIDs: appliedDeviceReportIDs, historyLimit: historyLimit)
    guard outcome.applied else { return 0 }
    metadataByID = outcome.metadata
    history = outcome.history
    appliedDeviceReportIDs = outcome.appliedReportIDs
    revision &+= 1
    engine.noteMutation()
    return outcome.mergedPlays
  }

  func resetStatistics(for trackID: TrackID) throws {
    try update { metadata, history in
      guard var value = metadata[trackID] else { return }
      value.playCount = 0
      value.lastPlayedAt = nil
      value.skipCount = 0
      value.bookmarkMS = nil
      value.lastSkippedAt = nil
      metadata[trackID] = value
      history.removeAll { $0.trackID == trackID }
    }
  }

  /// Retargets listening data after files move or duplicates collapse onto a
  /// surviving file. When source and destination both carry metadata, the
  /// values combine: play and skip counts add up, ratings and favorites keep
  /// their strongest value, and timestamps keep the most recent.
  func remapTrackIDs(_ mapping: [TrackID: TrackID]) throws {
    guard !mapping.isEmpty else { return }
    let affectedMetadata = metadataByID.keys.contains { mapping[$0] != nil }
    let affectedHistory = history.contains { mapping[$0.trackID] != nil }
    guard affectedMetadata || affectedHistory else { return }
    try update { metadata, history in
      for (source, destination) in mapping where source != destination {
        guard let value = metadata.removeValue(forKey: source) else { continue }
        let existing = metadata[destination] ?? TrackListeningMetadata(trackID: destination)
        metadata[destination] = Self.combined(existing, value, id: destination)
      }
      history = history.map { entry in
        guard let destination = mapping[entry.trackID], destination != entry.trackID else {
          return entry
        }
        return ListeningHistoryEntry(
          id: entry.id, trackID: destination, playedAt: entry.playedAt, source: entry.source)
      }
    }
  }

  nonisolated private static func combined(
    _ a: TrackListeningMetadata, _ b: TrackListeningMetadata, id: TrackID
  ) -> TrackListeningMetadata {
    let lastPlayed = [a.lastPlayedAt, b.lastPlayedAt].compactMap { $0 }.max()
    let lastSkipped = [a.lastSkippedAt, b.lastSkippedAt].compactMap { $0 }.max()
    return TrackListeningMetadata(
      trackID: id,
      rating: max(a.rating, b.rating),
      isFavorite: a.isFavorite || b.isFavorite,
      playCount: a.playCount + min(b.playCount, Int.max - a.playCount),
      lastPlayedAt: lastPlayed,
      skipCount: a.skipCount + min(b.skipCount, Int.max - a.skipCount),
      bookmarkMS: a.bookmarkMS ?? b.bookmarkMS,
      lastSkippedAt: lastSkipped)
  }

  func favoriteTracks(from library: [LibraryTrack]) -> [LibraryTrack] {
    library.filter { isFavorite($0.id) }
  }

  func recentTracks(from catalog: LibraryCatalog, limit: Int? = nil) -> [LibraryTrack] {
    let entries = limit.map { Array(history.prefix(max($0, 0))) } ?? history
    return entries.compactMap { catalog[$0.trackID] }
  }

  private static func uniqueIDs(_ trackIDs: [TrackID]) -> [TrackID] {
    var seen: Set<TrackID> = []
    return trackIDs.filter { seen.insert($0).inserted }
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    func removeAllForDevelopment() throws {
      metadataByID = [:]
      history = []
      appliedDeviceReportIDs = []
      revision &+= 1
      engine.clearLoadFailureForDevelopment()
      engine.noteMutation()
    }
  #endif

  private func update(
    _ mutation: (
      inout [TrackID: TrackListeningMetadata],
      inout [ListeningHistoryEntry]
    ) -> Void
  ) throws {
    try ensurePersistenceWritable()
    mutation(&metadataByID, &history)
    revision &+= 1
    engine.noteMutation()
  }

  func flushPersistence() async throws {
    try await engine.flushPersistence()
  }

  private func persistenceSnapshot() -> ListeningHistoryPersistenceSnapshot {
    ListeningHistoryPersistenceSnapshot(
      metadataByID: metadataByID, history: history,
      appliedDeviceReportIDs: appliedDeviceReportIDs)
  }

  private func load() {
    switch engine.loadOutcome(ListeningHistoryPayload.self) {
    case .missing:
      metadataByID = [:]
      history = []
      appliedDeviceReportIDs = []
    case .loaded(let stored):
      metadataByID = stored.metadataByID.values.reduce(into: [:]) {
        $0[$1.trackID] = $1
      }
      history = Array(stored.history.prefix(historyLimit))
      appliedDeviceReportIDs = stored.appliedDeviceReportIDs
    case .malformed, .unreadable:
      break
    }
  }

  func ensurePersistenceWritable() throws {
    try engine.ensurePersistenceWritable()
  }

  nonisolated private static func persistence(for folder: URL?) -> any AppDataPersistence {
    guard let folder else { return EmptyDataPersistence() }
    return FileDataPersistence(
      fileURL: ListeningHistoryFile.url(for: folder), createsParentDirectories: false)
  }
}

enum ListeningHistoryFile {
  static let filename = ".nightdrive-history.json"
  private static let historyLimit = 500

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }

  static func loadOutcome(libraryFolder: URL) -> AppDataLoadOutcome<ListeningHistoryPayload> {
    SidecarJSONFile.loadOutcome(ListeningHistoryPayload.self, at: url(for: libraryFolder))
  }

  static func loadPayload(libraryFolder: URL) throws -> ListeningHistoryPayload {
    try loadOutcome(libraryFolder: libraryFolder).unwrap(
      url: url(for: libraryFolder),
      whenMissing: ListeningHistoryPayload(metadataByID: [:], history: []))
  }

  static func loadRatings(libraryFolder: URL) throws -> [String: Int] {
    try loadPayload(libraryFolder: libraryFolder).metadataByID.values
      .reduce(into: [:]) { result, value in
        if value.rating > 0 { result[value.trackID.rawValue] = value.rating }
      }
  }

  @discardableResult
  static func merge(_ report: DevicePlaybackReport, libraryFolder: URL) throws -> Int {
    let payload = try loadPayload(libraryFolder: libraryFolder)
    let metadataByID = payload.metadataByID.values.reduce(
      into: [TrackID: TrackListeningMetadata]()
    ) { $0[$1.trackID] = $1 }
    let outcome = DevicePlaybackMerge.apply(
      report: report, metadata: metadataByID, history: payload.history,
      appliedReportIDs: payload.appliedDeviceReportIDs, historyLimit: historyLimit)
    guard outcome.applied else { return 0 }
    let updated = ListeningHistoryPayload(
      metadataByID: Dictionary(
        uniqueKeysWithValues: outcome.metadata.map { ($0.key.rawValue, $0.value) }),
      history: outcome.history,
      appliedDeviceReportIDs: outcome.appliedReportIDs)
    try FileDataPersistence(
      fileURL: url(for: libraryFolder), createsParentDirectories: false
    ).save(updated)
    return outcome.mergedPlays
  }
}
