import AppIntents
import CoreSpotlight
import Foundation

enum NightdriveCollectionKind: String, Codable, Sendable {
  case playlist
  case artist
  case album

  var label: String {
    switch self {
    case .playlist: String(localized: "Playlist")
    case .artist: String(localized: "Artist")
    case .album: String(localized: "Album")
    }
  }

  var symbol: String {
    switch self {
    case .playlist: "music.note.list"
    case .artist: "music.microphone"
    case .album: "square.stack"
    }
  }
}

struct NightdriveCollectionEntity: AppEntity, IndexedEntity, Codable, Equatable, Sendable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Music Collection")
  static let defaultQuery = NightdriveCollectionQuery()

  let id: String
  let kind: NightdriveCollectionKind
  let title: String
  let subtitle: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(title)", subtitle: "\(subtitle)",
      image: .init(systemName: kind.symbol))
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let attributes = defaultAttributeSet
    attributes.title = title
    attributes.displayName = title
    attributes.contentDescription = subtitle
    attributes.keywords = [kind.label, title, subtitle]
    attributes.contentURL = NightdriveDeepLink.url(forCollectionID: id)
    attributes.domainIdentifier = NightdriveSpotlightSynchronizer.domainIdentifier
    attributes.userOwned = true
    return attributes
  }

  static func libraryCollection(_ collection: LibraryCollection) -> Self? {
    let kind: NightdriveCollectionKind
    switch collection.id.kind {
    case .artist: kind = .artist
    case .album: kind = .album
    case .genre, .audiobook: return nil
    }
    return Self(
      id: stableID(kind: kind, parts: [collection.id.primary, collection.id.secondary]),
      kind: kind, title: collection.title, subtitle: collection.subtitle)
  }

  static func playlist(_ playlist: LocalPlaylist, availableTrackCount: Int) -> Self {
    Self(
      id: "playlist:\(playlist.id.uuidString.lowercased())", kind: .playlist,
      title: playlist.name,
      subtitle: availableTrackCount == 1
        ? String(localized: "1 song") : String(localized: "\(availableTrackCount) songs"))
  }

  private static func stableID(kind: NightdriveCollectionKind, parts: [String]) -> String {
    ([kind.rawValue]
      + parts.map {
        Data($0.utf8).base64EncodedString()
          .replacingOccurrences(of: "+", with: "-")
          .replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: "=", with: "")
      }).joined(separator: ":")
  }
}

struct NightdriveCollectionQuery: EntityQuery {
  func entities(for identifiers: [String]) async throws -> [NightdriveCollectionEntity] {
    try await NightdriveIntentBridge.shared.entities(identifiedBy: identifiers)
  }

  func suggestedEntities() async throws -> [NightdriveCollectionEntity] {
    try await NightdriveIntentBridge.shared.entities()
  }
}

enum NightdriveDeepLink {
  static let scheme = "nightdrive"

  static func url(forCollectionID id: String) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = "open"
    components.queryItems = [URLQueryItem(name: "collection", value: id)]
    return components.url!
  }

  static func collectionID(from url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.caseInsensitiveCompare(scheme) == .orderedSame,
      components.host?.caseInsensitiveCompare("open") == .orderedSame,
      components.user == nil, components.password == nil, components.port == nil,
      components.path.isEmpty, components.fragment == nil,
      let query = components.queryItems, query.count == 1, query[0].name == "collection",
      let id = query[0].value, !id.isEmpty, id.utf8.count <= 4096
    else { return nil }
    return id
  }
}

enum NightdriveIntentError: LocalizedError {
  case unavailable
  case libraryUnavailable
  case collectionUnavailable

  var errorDescription: String? {
    switch self {
    case .unavailable: String(localized: "Nightdrive is not ready yet. Try again in a moment.")
    case .libraryUnavailable:
      String(localized: "Nightdrive’s music library is unavailable.")
    case .collectionUnavailable:
      String(localized: "That music collection is empty or no longer exists.")
    }
  }
}

@MainActor
struct NightdriveIntentOperations {
  var togglePlayback: () async throws -> Void
  var next: () async throws -> Void
  var previous: () async throws -> Void
  var entities: () async throws -> [NightdriveCollectionEntity]
  var playCollection: (String) async throws -> Void
  var openCollection: (String) async throws -> Void
  var openUpNext: () throws -> Void
}

@MainActor
final class NightdriveIntentBridge {
  static let shared = NightdriveIntentBridge()

  private var operations: NightdriveIntentOperations?

  init(operations: NightdriveIntentOperations? = nil) {
    self.operations = operations
  }

  func install(app: AppState) {
    operations = .live(app: app)
  }

  func togglePlayback() async throws { try await required.togglePlayback() }
  func next() async throws { try await required.next() }
  func previous() async throws { try await required.previous() }
  func playCollection(_ id: String) async throws { try await required.playCollection(id) }
  func openCollection(_ id: String) async throws { try await required.openCollection(id) }
  func openUpNext() throws { try required.openUpNext() }

  func entities() async throws -> [NightdriveCollectionEntity] {
    try await required.entities()
  }

  func entities(identifiedBy ids: [String]) async throws -> [NightdriveCollectionEntity] {
    let byID = Dictionary(
      try await entities().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ids.compactMap { byID[$0] }
  }

  private var required: NightdriveIntentOperations {
    get throws {
      guard let operations else { throw NightdriveIntentError.unavailable }
      return operations
    }
  }
}

extension NightdriveIntentOperations {
  static func live(app: AppState) -> Self {
    Self(
      togglePlayback: { [weak app] in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.intentTogglePlayback()
      },
      next: { [weak app] in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.preparePlaybackForIntent()
        app.player.next()
      },
      previous: { [weak app] in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.preparePlaybackForIntent()
        app.player.previous()
      },
      entities: { [weak app] in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.prepareLibraryForIntent()
        return app.searchCollectionEntities()
      },
      playCollection: { [weak app] id in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.playSearchCollection(id)
      },
      openCollection: { [weak app] id in
        guard let app else { throw NightdriveIntentError.unavailable }
        try await app.openSearchCollection(id)
      },
      openUpNext: { [weak app] in
        guard let app else { throw NightdriveIntentError.unavailable }
        app.openSidebarItem(.upNext)
      })
  }
}

extension AppState {
  fileprivate func prepareLibraryForIntent() async throws {
    if library.folderURL != nil, !library.initialScanCompleted {
      await library.rescan()
    }
    guard library.isSettled else { throw NightdriveIntentError.libraryUnavailable }
  }

  fileprivate func preparePlaybackForIntent() async throws {
    if player.currentTrack == nil {
      try await prepareLibraryForIntent()
      restorePlaybackIfNeeded()
    }
    guard player.currentTrack != nil || !player.playbackQueue.isEmpty else {
      throw NightdriveIntentError.collectionUnavailable
    }
    startPlaybackIntegrations()
  }

  fileprivate func intentTogglePlayback() async throws {
    if !player.isPlaying { try await preparePlaybackForIntent() }
    player.togglePlayPause()
  }

  func searchCollectionEntities() -> [NightdriveCollectionEntity] {
    let catalog = library.catalog
    let collections = [LibraryBrowseKind.artist, .album].flatMap(library.collections)
      .compactMap(NightdriveCollectionEntity.libraryCollection)
    let playlistEntities = playlists.playlists.compactMap { playlist in
      let count = playlists.tracks(in: playlist.id, from: catalog).count
      return count == 0
        ? nil
        : NightdriveCollectionEntity.playlist(
          playlist, availableTrackCount: count)
    }
    return collections + playlistEntities
  }

  fileprivate func playSearchCollection(_ id: String) async throws {
    try await prepareLibraryForIntent()
    let tracks = try resolvedSearchCollection(id).tracks
    guard let first = tracks.first else { throw NightdriveIntentError.collectionUnavailable }
    startPlaybackIntegrations()
    player.play(first, in: tracks)
  }

  fileprivate func openSearchCollection(_ id: String) async throws {
    try await prepareLibraryForIntent()
    let target = try resolvedSearchCollection(id)
    switch target.destination {
    case .collection(let collectionID): revealCollection(collectionID)
    case .playlist(let playlistID):
      selectedPlaylistID = playlistID
      openSidebarItem(.playlists)
    }
  }

  private func resolvedSearchCollection(_ id: String) throws -> (
    tracks: [LibraryTrack], destination: NightdriveSearchDestination
  ) {
    for kind in [LibraryBrowseKind.artist, .album] {
      for collection in library.collections(for: kind)
      where NightdriveCollectionEntity.libraryCollection(collection)?.id == id {
        return (collection.tracks, .collection(collection.id))
      }
    }
    if id.hasPrefix("playlist:"),
      let playlistID = UUID(uuidString: String(id.dropFirst("playlist:".count))),
      playlists.playlist(withID: playlistID) != nil
    {
      return (
        playlists.tracks(in: playlistID, from: library.catalog), .playlist(playlistID)
      )
    }
    throw NightdriveIntentError.collectionUnavailable
  }
}

private enum NightdriveSearchDestination {
  case collection(LibraryCollectionID)
  case playlist(UUID)
}

struct ToggleNightdrivePlaybackIntent: AppIntent {
  static let title: LocalizedStringResource = "Play or Pause Nightdrive"
  static let description = IntentDescription("Toggle music playback in Nightdrive.")

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.togglePlayback()
    return .result()
  }
}

struct NextNightdriveTrackIntent: AppIntent {
  static let title: LocalizedStringResource = "Next Nightdrive Track"

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.next()
    return .result()
  }
}

struct PreviousNightdriveTrackIntent: AppIntent {
  static let title: LocalizedStringResource = "Previous Nightdrive Track"

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.previous()
    return .result()
  }
}

struct PlayNightdriveCollectionIntent: AppIntent {
  static let title: LocalizedStringResource = "Play Music in Nightdrive"

  @Parameter(title: "Music") var collection: NightdriveCollectionEntity

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.playCollection(collection.id)
    return .result()
  }
}

struct OpenNightdriveCollectionIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Music in Nightdrive"
  static let openAppWhenRun = true

  @Parameter(title: "Music") var collection: NightdriveCollectionEntity

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.openCollection(collection.id)
    return .result()
  }
}

struct OpenNightdriveUpNextIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Up Next in Nightdrive"
  static let openAppWhenRun = true

  func perform() async throws -> some IntentResult {
    try await NightdriveIntentBridge.shared.openUpNext()
    return .result()
  }
}

struct NightdriveShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ToggleNightdrivePlaybackIntent(),
      phrases: ["Play or pause \(.applicationName)"],
      shortTitle: "Play or Pause", systemImageName: "playpause")
    AppShortcut(
      intent: NextNightdriveTrackIntent(),
      phrases: ["Next song in \(.applicationName)"],
      shortTitle: "Next Track", systemImageName: "forward.end")
    AppShortcut(
      intent: PreviousNightdriveTrackIntent(),
      phrases: ["Previous song in \(.applicationName)"],
      shortTitle: "Previous Track", systemImageName: "backward.end")
    AppShortcut(
      intent: PlayNightdriveCollectionIntent(),
      phrases: ["Play \(\.$collection) in \(.applicationName)"],
      shortTitle: "Play Music", systemImageName: "music.note")
    AppShortcut(
      intent: OpenNightdriveUpNextIntent(),
      phrases: ["Show Up Next in \(.applicationName)"],
      shortTitle: "Open Up Next", systemImageName: "text.line.first.and.arrowtriangle.forward")
  }

  static var shortcutTileColor: ShortcutTileColor { .navy }
}
