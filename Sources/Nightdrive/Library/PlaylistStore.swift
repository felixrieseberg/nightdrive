import Foundation
import Observation

struct LocalPlaylist: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  var name: String
  var trackIDs: [TrackID]
  var syncEnabled: Bool
  var smartRule: SmartPlaylistRule?

  init(
    id: UUID = UUID(), name: String, trackIDs: [TrackID] = [], syncEnabled: Bool = true,
    smartRule: SmartPlaylistRule? = nil
  ) {
    self.id = id
    self.name = name
    self.trackIDs = trackIDs
    self.syncEnabled = syncEnabled
    self.smartRule = smartRule
  }
}

enum PlaylistStoreError: LocalizedError, Equatable {
  case emptyName
  case playlistNotFound
  case invalidM3UEncoding
  case noImportableTracks
  case unsupportedM3UEntry(String)

  var errorDescription: String? {
    switch self {
    case .emptyName: String(localized: "A playlist needs a name.")
    case .playlistNotFound: String(localized: "That playlist no longer exists.")
    case .invalidM3UEncoding: String(localized: "The playlist isn’t a valid UTF-8 M3U file.")
    case .noImportableTracks:
      String(localized: "The playlist doesn’t contain any local music files.")
    case .unsupportedM3UEntry(let entry):
      String(localized: "The playlist contains a non-local entry that can’t be imported: \(entry)")
    }
  }
}

@Observable
@MainActor
final class PlaylistStore {
  struct StateSnapshot {
    fileprivate let playlists: [LocalPlaylist]
    fileprivate let revision: UInt64
    fileprivate let engine: DebouncedPersistenceEngine<[LocalPlaylist]>.StateSnapshot
  }

  private(set) var playlists: [LocalPlaylist] = []
  private(set) var revision: UInt64 = 0
  var persistenceError: String? { engine.persistenceError }

  @ObservationIgnored private let engine: DebouncedPersistenceEngine<[LocalPlaylist]>
  @ObservationIgnored private var libraryFolder: URL?

  init(
    persistence: any AppDataPersistence,
    persistenceDebounce: Duration = .milliseconds(150)
  ) {
    engine = DebouncedPersistenceEngine(persistence: persistence, debounce: persistenceDebounce)
    engine.snapshotProvider = { [weak self] in self?.playlists }
    load()
  }

  init(
    libraryFolder: URL?,
    persistenceDebounce: Duration = .milliseconds(150)
  ) {
    let folder = libraryFolder?.standardizedFileURL
    self.libraryFolder = folder
    engine = DebouncedPersistenceEngine(
      persistence: Self.persistence(for: folder), debounce: persistenceDebounce)
    engine.snapshotProvider = { [weak self] in self?.playlists }
    load()
  }

  func useLibraryFolder(_ libraryFolder: URL?, resourceChanged: Bool = false) {
    let folder = libraryFolder?.standardizedFileURL
    guard resourceChanged || folder != self.libraryFolder else { return }
    self.libraryFolder = folder
    engine.usePersistence(Self.persistence(for: folder))
    playlists = []
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
    StateSnapshot(playlists: playlists, revision: revision, engine: engine.stateSnapshot())
  }

  func restoreState(_ snapshot: StateSnapshot) {
    playlists = snapshot.playlists
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

  @discardableResult
  func create(name: String) throws -> UUID {
    try create(name: name, trackIDs: [])
  }

  @discardableResult
  func create(name: String, trackIDs: [TrackID]) throws -> UUID {
    let name = try validatedName(name)
    let playlist = LocalPlaylist(name: name, trackIDs: Self.uniqueIDs(trackIDs))
    try update { $0.append(playlist) }
    return playlist.id
  }

  @discardableResult
  func create(name: String, trackURLs: [URL]) throws -> UUID {
    try create(name: name, trackIDs: trackURLs.map(TrackID.init(url:)))
  }

  @discardableResult
  func importM3U(
    _ data: Data,
    named name: String,
    relativeTo baseDirectory: URL
  ) throws -> UUID {
    guard let contents = String(data: data, encoding: .utf8) else {
      throw PlaylistStoreError.invalidM3UEncoding
    }

    var urls: [URL] = []
    for rawLine in contents.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }

      urls.append(try Self.localURL(forM3UEntry: line, relativeTo: baseDirectory))
    }

    guard !urls.isEmpty else { throw PlaylistStoreError.noImportableTracks }
    return try create(name: name, trackURLs: urls)
  }

  func exportM3U(_ playlistID: UUID) throws -> Data {
    guard let playlist = playlist(withID: playlistID) else {
      throw PlaylistStoreError.playlistNotFound
    }
    let lines = ["#EXTM3U"] + playlist.trackIDs.map(\.rawValue)
    return Data((lines.joined(separator: "\n") + "\n").utf8)
  }

  func rename(_ playlistID: UUID, to name: String) throws {
    let name = try validatedName(name)
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].name = name
    }
  }

  func delete(_ playlistID: UUID) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0.remove(at: index)
    }
  }

  func setSyncEnabled(_ enabled: Bool, for playlistID: UUID) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].syncEnabled = enabled
    }
  }

  func replaceAll(_ playlists: [LocalPlaylist]) throws {
    try update { $0 = playlists }
  }

  /// Retargets track references after files move or duplicates collapse onto
  /// a surviving file. Remapped IDs keep their playlist positions; a mapping
  /// that lands on an ID already present earlier in the same playlist is
  /// dropped instead of duplicated.
  func remapTrackIDs(_ mapping: [TrackID: TrackID]) throws {
    guard !mapping.isEmpty else { return }
    let affected = playlists.contains { playlist in
      playlist.trackIDs.contains { mapping[$0] != nil }
    }
    guard affected else { return }
    try update { playlists in
      for index in playlists.indices {
        var seen: Set<TrackID> = []
        playlists[index].trackIDs = playlists[index].trackIDs.compactMap { id in
          let remapped = mapping[id] ?? id
          return seen.insert(remapped).inserted ? remapped : nil
        }
      }
    }
  }

  func add(_ trackIDs: [TrackID], to playlistID: UUID) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      var existing = Set($0[index].trackIDs)
      for trackID in trackIDs where existing.insert(trackID).inserted {
        $0[index].trackIDs.append(trackID)
      }
    }
  }

  func remove(_ trackID: TrackID, from playlistID: UUID) throws {
    try remove([trackID], from: playlistID)
  }

  func remove(_ trackIDs: [TrackID], from playlistID: UUID) throws {
    let removed = Set(trackIDs)
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].trackIDs.removeAll { removed.contains($0) }
    }
  }

  func remove(at offsets: IndexSet, from playlistID: UUID) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].trackIDs.remove(atOffsets: offsets)
    }
  }

  func move(from offsets: IndexSet, to destination: Int, in playlistID: UUID) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].trackIDs.move(fromOffsets: offsets, toOffset: destination)
    }
  }

  @discardableResult
  func createSmart(
    name: String, rule: SmartPlaylistRule,
    library: [LibraryTrack], facts: [String: SmartRuleFacts]
  ) throws -> UUID {
    let name = try validatedName(name)
    let playlist = LocalPlaylist(
      name: name,
      trackIDs: SmartPlaylistEvaluator.evaluate(rule, library: library, facts: facts).map(\.id),
      smartRule: rule)
    try update { $0.append(playlist) }
    return playlist.id
  }

  func setSmartRule(
    _ rule: SmartPlaylistRule?, for playlistID: UUID,
    library: [LibraryTrack], facts: [String: SmartRuleFacts]
  ) throws {
    try update {
      guard let index = $0.firstIndex(where: { $0.id == playlistID }) else {
        throw PlaylistStoreError.playlistNotFound
      }
      $0[index].smartRule = rule
      if let rule {
        $0[index].trackIDs =
          SmartPlaylistEvaluator.evaluate(rule, library: library, facts: facts).map(\.id)
      }
    }
  }

  func refreshSmartPlaylists(library: [LibraryTrack], facts: [String: SmartRuleFacts]) throws {
    let refreshed = SmartPlaylistEvaluator.refresh(playlists, library: library, facts: facts)
    guard refreshed.changed else { return }
    try update { $0 = refreshed.playlists }
  }

  func playlist(withID id: UUID) -> LocalPlaylist? {
    playlists.first { $0.id == id }
  }

  func contains(_ trackID: TrackID, in playlistID: UUID) -> Bool {
    playlist(withID: playlistID)?.trackIDs.contains(trackID) == true
  }

  func tracks(in playlistID: UUID, from catalog: LibraryCatalog) -> [LibraryTrack] {
    guard let playlist = playlist(withID: playlistID) else { return [] }
    return catalog.tracks(for: playlist.trackIDs)
  }

  private func validatedName(_ value: String) throws -> String {
    let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { throw PlaylistStoreError.emptyName }
    return result
  }

  private static func uniqueIDs(_ trackIDs: [TrackID]) -> [TrackID] {
    var seen: Set<TrackID> = []
    return trackIDs.filter { seen.insert($0).inserted }
  }

  private static func localURL(forM3UEntry entry: String, relativeTo baseDirectory: URL)
    throws -> URL
  {
    let components = URLComponents(string: entry)
    if let scheme = components?.scheme {
      guard scheme.localizedCaseInsensitiveCompare("file") == .orderedSame,
        let components,
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.query == nil,
        components.fragment == nil,
        components.percentEncodedPath.hasPrefix("/"),
        components.host?.isEmpty != false
          || components.host?.localizedCaseInsensitiveCompare("localhost") == .orderedSame,
        let decodedPath = components.percentEncodedPath.removingPercentEncoding
      else {
        throw PlaylistStoreError.unsupportedM3UEntry(entry)
      }
      return URL(fileURLWithPath: decodedPath)
    }

    let path = entry.removingPercentEncoding ?? entry
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    return baseDirectory.appendingPathComponent(path)
  }

  private func update(_ mutation: (inout [LocalPlaylist]) throws -> Void) throws {
    try ensurePersistenceWritable()
    try mutation(&playlists)
    revision &+= 1
    engine.noteMutation()
  }

  func flushPersistence() async throws {
    try await engine.flushPersistence()
  }

  private func load() {
    switch engine.loadOutcome([LocalPlaylist].self) {
    case .missing:
      playlists = []
    case .loaded(let stored):
      playlists = stored
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
      fileURL: LocalPlaylistFile.url(for: folder), createsParentDirectories: false)
  }
}

enum LocalPlaylistFile {
  static let filename = ".nightdrive-playlists.json"

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }

  static func loadOutcome(libraryFolder: URL) -> AppDataLoadOutcome<[LocalPlaylist]> {
    SidecarJSONFile.loadOutcome([LocalPlaylist].self, at: url(for: libraryFolder))
  }

  static func load(libraryFolder: URL) throws -> [LocalPlaylist] {
    try loadOutcome(libraryFolder: libraryFolder)
      .unwrap(url: url(for: libraryFolder), whenMissing: [])
  }

  static func save(_ playlists: [LocalPlaylist], libraryFolder: URL) throws {
    try FileDataPersistence(
      fileURL: url(for: libraryFolder), createsParentDirectories: false
    ).save(playlists)
  }
}
