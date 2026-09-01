import Foundation

/// One hit in the Cmd+K quick-search palette. Activating a result starts
/// playback of `start` with `tracks` as the queue, so an artist hit carries
/// the artist's whole run of songs and a song hit carries its album context.
struct QuickSearchResult: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let subtitle: String
  let start: LibraryTrack
  let tracks: [LibraryTrack]
  /// The owning browse collection, so activation can reveal the artist,
  /// album, genre, or audiobook in its browse view. Nil for song hits.
  let collectionID: LibraryCollectionID?
}

/// A non-library action exposed alongside artists, albums, and songs in the
/// Cmd+K palette. Keeping this catalog independent of SwiftUI makes the
/// command names and fuzzy matching straightforward to test.
struct QuickSearchCommand: Identifiable, Hashable {
  enum Kind: Hashable {
    case navigation
    case player
    case tool
  }

  enum Action: Hashable {
    case navigate(SidebarItem)
    case navigatePlaylist(UUID)
    case navigatePodcast(URL)
    case openSettings(SettingsTab)
    case togglePlayPause
    case nextTrack
    case previousTrack
    case toggleShuffle
    case cycleRepeatMode
    case toggleMute
    case findDuplicates
    case cleanUpGenres
    case findMetadataProblems
    case organizeLibrary
    case openAudioFiles
    case chooseLibraryFolder
    case rescanLibrary
    case syncIPod
  }

  let id: String
  let kind: Kind
  let title: String
  let subtitle: String
  let systemImage: String
  let keywords: [String]
  let action: Action
  let shortcut: String?

  func resolvingPlayerState(
    isPlaying: Bool, isShuffleEnabled: Bool, repeatMode: PlaybackRepeatMode, isMuted: Bool
  ) -> QuickSearchCommand {
    switch action {
    case .togglePlayPause:
      return replacing(
        title: isPlaying ? String(localized: "Pause") : String(localized: "Play"),
        subtitle: isPlaying ? String(localized: "Pause the current song") : String(localized: "Resume playback"),
        systemImage: isPlaying ? "pause.fill" : "play.fill")
    case .toggleShuffle:
      return replacing(
        title: isShuffleEnabled
          ? String(localized: "Turn Shuffle Off") : String(localized: "Turn Shuffle On"),
        subtitle: isShuffleEnabled
          ? String(localized: "Keep the current queue order") : String(localized: "Randomize upcoming songs"),
        systemImage: "shuffle")
    case .cycleRepeatMode:
      let nextMode: PlaybackRepeatMode =
        switch repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
      return replacing(
        title: repeatMode.label,
        subtitle: String(localized: "Next: \(nextMode.label)"),
        systemImage: repeatMode.systemImage)
    case .toggleMute:
      return replacing(
        title: isMuted ? String(localized: "Unmute") : String(localized: "Mute"),
        subtitle: isMuted ? String(localized: "Restore audio output") : String(localized: "Silence audio output"),
        systemImage: isMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    default:
      return self
    }
  }

  private func replacing(title: String, subtitle: String, systemImage: String) -> QuickSearchCommand {
    QuickSearchCommand(
      id: id, kind: kind, title: title, subtitle: subtitle, systemImage: systemImage,
      keywords: keywords, action: action, shortcut: shortcut)
  }
}

/// Scores how well a query matches a candidate. Matching is case- and
/// diacritic-insensitive subsequence matching: every query character must
/// appear in order, and word-initial, contiguous, and prefix runs outrank
/// scattered ones, so "mdna" finds "Madonna" but "Madonna" itself wins.
enum QuickSearchMatcher {
  /// A query normalized and split into characters once, so scoring a whole
  /// library against it does not re-fold or re-materialize it per candidate.
  struct PreparedQuery: Sendable {
    let text: String
    let characters: [Character]

    init?(_ query: String) {
      let text = QuickSearchMatcher.normalize(query)
      guard !text.isEmpty else { return nil }
      self.text = text
      characters = Array(text)
    }
  }

  static func normalize(_ value: String) -> String {
    value.lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
  }

  static func score(_ query: String, in candidate: String) -> Double? {
    guard let prepared = PreparedQuery(query) else { return nil }
    return score(prepared, inNormalized: normalize(candidate))
  }

  /// Scores an already-normalized candidate, walking its characters without
  /// materializing an array. `characterCount` lets callers with a prebuilt
  /// index skip recounting the candidate.
  static func score(
    _ query: PreparedQuery, inNormalized candidate: String, characterCount: Int? = nil
  ) -> Double? {
    let queryCharacters = query.characters
    let candidateCount = characterCount ?? candidate.count
    guard queryCharacters.count <= candidateCount else { return nil }

    var score = 0.0
    var queryIndex = 0
    var previousCharacter: Character?
    var previousMatched = false
    for character in candidate {
      guard queryIndex < queryCharacters.count else { break }
      defer { previousCharacter = character }
      guard character == queryCharacters[queryIndex] else {
        previousMatched = false
        continue
      }
      if let previousCharacter, previousCharacter.isLetter || previousCharacter.isNumber {
        score += previousMatched ? Self.contiguousBonus : Self.scatteredBonus
      } else {
        score += Self.wordStartBonus
      }
      previousMatched = true
      queryIndex += 1
    }
    guard queryIndex == queryCharacters.count else { return nil }

    // Word-start bonuses alone would let acronym-style hits ("mad" in
    // "My Adorable Dog") outrank real prefixes, so contiguous substrings
    // get a flat boost on top of the per-character walk.
    if candidate.hasPrefix(query.text) {
      score += Self.substringBonus + Self.prefixBonus
    } else if candidate.contains(query.text) {
      score += Self.substringBonus
    }
    return score - Double(candidateCount) * Self.lengthPenalty
  }

  private static let wordStartBonus = 12.0
  private static let contiguousBonus = 8.0
  private static let scatteredBonus = 1.0
  private static let substringBonus = 15.0
  private static let prefixBonus = 10.0
  private static let lengthPenalty = 0.05
}

enum QuickSearch {
  static let maxResults = 12

  /// Commands shown before the user types and searched with the same fuzzy
  /// matcher as music.
  static let commands: [QuickSearchCommand] = [
    command(
      "view:music", .navigation, "Music", "Go to your music library", "music.note",
      ["library", "songs", "navigation"], .navigate(.library),
      shortcut: SidebarItem.library.commandShortcutLabel),
    command(
      "view:artists", .navigation, "Artists", "Browse artists", "music.mic",
      ["navigation", "view"], .navigate(.artists),
      shortcut: SidebarItem.artists.commandShortcutLabel),
    command(
      "view:albums", .navigation, "Albums", "Browse albums", "square.stack",
      ["navigation", "view"], .navigate(.albums),
      shortcut: SidebarItem.albums.commandShortcutLabel),
    command(
      "view:genres", .navigation, "Genres", "Browse genres", "guitars",
      ["navigation", "view"], .navigate(.genres),
      shortcut: SidebarItem.genres.commandShortcutLabel),
    command(
      "view:audiobooks", .navigation, "Audiobooks", "Browse audiobooks", "books.vertical",
      ["books", "navigation", "view"], .navigate(.audiobooks),
      shortcut: SidebarItem.audiobooks.commandShortcutLabel),
    command(
      "view:podcasts", .navigation, "Podcasts", "Search and download podcasts",
      "antenna.radiowaves.left.and.right",
      ["shows", "episodes", "subscriptions", "navigation", "view"], .navigate(.podcasts),
      shortcut: SidebarItem.podcasts.commandShortcutLabel),
    command(
      "view:up-next", .navigation, "Up Next", "Show the playback queue", "text.line.first.and.arrowtriangle.forward",
      ["queue", "navigation", "view"], .navigate(.upNext),
      shortcut: SidebarItem.upNext.commandShortcutLabel),
    command(
      "view:listening", .navigation, "Listening", "Show favorites and listening history", "clock.arrow.circlepath",
      ["history", "favorites", "navigation", "view"], .navigate(.listening),
      shortcut: SidebarItem.listening.commandShortcutLabel),
    command(
      "view:suggestions", .navigation, "Suggestions", "Review metadata suggestions", "sparkles",
      ["musicbrainz", "inbox", "navigation", "view"], .navigate(.suggestions),
      shortcut: SidebarItem.suggestions.commandShortcutLabel),
    command(
      "view:playlists", .navigation, "All Playlists", "Browse playlists", "music.note.list",
      ["navigation", "view"], .navigate(.playlists),
      shortcut: SidebarItem.playlists.commandShortcutLabel),
    command(
      "settings:general", .navigation, "General Settings…", "Open General settings",
      "gearshape.fill", ["preferences", "configuration", "navigation"], .openSettings(.general)),
    command(
      "settings:ipod-sync", .navigation, "iPod Sync Settings…", "Open iPod Sync settings",
      "ipod", ["preferences", "device", "configuration", "navigation"], .openSettings(.ipodSync)),
    command(
      "settings:visualizers", .navigation, "Visualizer Settings…", "Choose and arrange visualizers",
      "waveform", ["preferences", "display", "configuration", "navigation"],
      .openSettings(.visualizers)),
    command(
      "settings:online", .navigation, "Online Settings…", "Configure online metadata services",
      "network", ["preferences", "musicbrainz", "configuration", "navigation"], .openSettings(.online)),
    command(
      "player:play-pause", .player, "Play or Pause", "Toggle playback", "playpause.fill",
      ["resume", "stop", "player", "control"], .togglePlayPause, shortcut: "Space"),
    command(
      "player:next", .player, "Next Track", "Skip to the next song", "forward.end.fill",
      ["skip", "player", "control"], .nextTrack, shortcut: "⌘→"),
    command(
      "player:previous", .player, "Previous Track", "Return to the previous song", "backward.end.fill",
      ["back", "player", "control"], .previousTrack, shortcut: "⌘←"),
    command(
      "player:shuffle", .player, "Toggle Shuffle", "Turn shuffle on or off", "shuffle",
      ["toggle", "random", "player", "control"], .toggleShuffle),
    command(
      "player:repeat", .player, "Cycle Repeat Mode", "Change the repeat mode", "repeat",
      ["cycle", "loop", "player", "control"], .cycleRepeatMode),
    command(
      "player:mute", .player, "Mute or Unmute", "Toggle audio output", "speaker.slash.fill",
      ["volume", "sound", "player", "control"], .toggleMute, shortcut: "⌥⌘M"),
    command(
      "tool:duplicates", .tool, "Find Duplicates…", "Detect duplicate songs in the library",
      "square.on.square", ["duplicate detection", "cleanup", "library", "tool"], .findDuplicates),
    command(
      "tool:genres", .tool, "Clean Up Genres…", "Review and normalize genre tags",
      "tag", ["metadata", "library", "tool"], .cleanUpGenres),
    command(
      "tool:metadata", .tool, "Find Metadata Problems…", "Detect suspicious song information",
      "exclamationmark.magnifyingglass", ["tags", "repair", "library", "tool"],
      .findMetadataProblems),
    command(
      "tool:organize", .tool, "Organize Library Files…", "Move songs into a consistent folder layout",
      "folder.badge.gearshape", ["rename", "folders", "cleanup", "library", "tool"],
      .organizeLibrary),
    command(
      "tool:open-audio", .tool, "Open Audio Files…", "Play files without adding them to the library",
      "waveform.badge.plus", ["file", "song", "browse", "tool"], .openAudioFiles, shortcut: "⌘O"),
    command(
      "tool:choose-library", .tool, "Choose Library Folder…", "Select Nightdrive’s music folder",
      "folder.badge.plus", ["change", "music", "location", "tool"], .chooseLibraryFolder,
      shortcut: "⇧⌘O"),
    command(
      "tool:rescan-library", .tool, "Rescan Library", "Look for added, changed, and removed songs",
      "arrow.clockwise", ["refresh", "reload", "music", "tool"], .rescanLibrary, shortcut: "⌘R"),
    command(
      "tool:sync-ipod", .tool, "Sync iPod", "Sync the selected or first connected iPod",
      "arrow.triangle.2.circlepath", ["device", "copy", "music", "tool"], .syncIPod,
      shortcut: "⌘S"),
  ]

  /// Kind weights break ties so typing an artist's name surfaces the artist
  /// above an identically titled album or song.
  fileprivate static let artistBonus = 4.0
  fileprivate static let genreBonus = 3.0
  fileprivate static let albumBonus = 2.0
  fileprivate static let audiobookBonus = 2.0
  /// A song reachable only through "artist title" is discounted so hits in
  /// the title itself outrank ones that lean on the artist name.
  private static let combinedFieldPenalty = 3.0

  /// Put a useful sample of every command category above the palette's fold.
  /// The remaining views and controls are still one scroll or search away.
  private static let defaultCommandOrder = [
    "view:music", "view:artists", "view:albums", "player:play-pause", "player:next",
    "tool:duplicates", "tool:genres", "view:genres", "view:audiobooks", "view:podcasts",
    "view:up-next", "view:listening",
    "view:suggestions", "view:playlists", "settings:general", "settings:ipod-sync",
    "settings:visualizers", "settings:online", "player:previous", "player:shuffle",
    "player:repeat", "player:mute", "tool:metadata", "tool:organize", "tool:open-audio",
    "tool:choose-library", "tool:rescan-library", "tool:sync-ipod",
  ]

  static func commands(
    matching query: String, baseCommands: [QuickSearchCommand]? = nil,
    additionalCommands: [QuickSearchCommand] = []
  ) -> [QuickSearchCommand] {
    let baseCommands = baseCommands ?? commands
    let allCommands = baseCommands + additionalCommands
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      let commandsByID = Dictionary(uniqueKeysWithValues: baseCommands.map { ($0.id, $0) })
      return defaultCommandOrder.compactMap { commandsByID[$0] } + additionalCommands
    }

    return
      allCommands
      .enumerated()
      .compactMap { index, command -> (Double, Int, QuickSearchCommand)? in
        let searchableValues = [command.title, command.subtitle] + command.keywords
        guard let score = searchableValues.compactMap({ QuickSearchMatcher.score(trimmed, in: $0) }).max()
        else { return nil }
        return (score, index, command)
      }
      .sorted { lhs, rhs in
        lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
      }
      .map(\.2)
  }

  static func results(
    matching query: String,
    artists: [LibraryCollection],
    albums: [LibraryCollection],
    genres: [LibraryCollection] = [],
    audiobooks: [LibraryCollection] = [],
    tracks: [LibraryTrack]
  ) -> [QuickSearchResult] {
    let index = QuickSearchIndex(
      artists: artists, albums: albums, genres: genres, audiobooks: audiobooks, tracks: tracks)
    return (try? results(matching: query, in: index)) ?? []
  }

  /// Scores every candidate in a prebuilt index and keeps only the top
  /// `maxResults`, so a 100k-track library never sorts (or even materializes)
  /// the full match list. Throws `CancellationError` when the surrounding
  /// task is cancelled by a newer keystroke.
  static func results(
    matching query: String, in index: QuickSearchIndex
  ) throws -> [QuickSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let prepared = QuickSearchMatcher.PreparedQuery(trimmed) else { return [] }

    var top = TopResults(limit: Self.maxResults)

    for (offset, entry) in index.collections.enumerated() {
      if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
      let collection = entry.collection
      guard let first = collection.tracks.first,
        let score = QuickSearchMatcher.score(
          prepared, inNormalized: entry.normalizedTitle, characterCount: entry.normalizedTitleCount)
      else { continue }
      top.insert(score: score + entry.bonus, title: collection.title) {
        QuickSearchResult(
          id: "\(collection.id.kind.rawValue):\(collection.id.primary)|\(collection.id.secondary)",
          title: collection.title, subtitle: collection.subtitle,
          start: first, tracks: collection.tracks, collectionID: collection.id)
      }
    }

    for (offset, entry) in index.tracks.enumerated() {
      if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
      var best = QuickSearchMatcher.score(
        prepared, inNormalized: entry.normalizedTitle, characterCount: entry.normalizedTitleCount)
      if let combined = entry.normalizedArtistAndTitle,
        let combinedScore = QuickSearchMatcher.score(
          prepared, inNormalized: combined, characterCount: entry.normalizedArtistAndTitleCount)
      {
        best = max(best ?? -.infinity, combinedScore - Self.combinedFieldPenalty)
      }
      guard let score = best else { continue }
      let track = entry.track
      top.insert(score: score, title: entry.title) {
        QuickSearchResult(
          id: "song:\(track.id.rawValue)",
          title: entry.title, subtitle: songSubtitle(for: track),
          start: track, tracks: index.albumTracks(for: track), collectionID: nil)
      }
    }

    return top.results
  }

  /// A bounded, ordered set of the best-scoring results. Candidates that
  /// cannot beat the current worst entry are rejected before their result
  /// payload is ever built.
  private struct TopResults {
    let limit: Int
    private var entries: [(score: Double, result: QuickSearchResult)] = []

    init(limit: Int) {
      self.limit = limit
      entries.reserveCapacity(limit + 1)
    }

    var results: [QuickSearchResult] { entries.map(\.result) }

    mutating func insert(score: Double, title: String, make: () -> QuickSearchResult) {
      if entries.count == limit, !outranksLast(score: score, title: title) { return }
      let entry = (score: score, result: make())
      let position = entries.firstIndex { candidate in
        if candidate.score != entry.score { return candidate.score < entry.score }
        return title.localizedCaseInsensitiveCompare(candidate.result.title) == .orderedAscending
      }
      entries.insert(entry, at: position ?? entries.count)
      if entries.count > limit { entries.removeLast() }
    }

    private func outranksLast(score: Double, title: String) -> Bool {
      guard let last = entries.last else { return true }
      if score != last.score { return score > last.score }
      return title.localizedCaseInsensitiveCompare(last.result.title) == .orderedAscending
    }
  }

  private static func songSubtitle(for track: LibraryTrack) -> String {
    let parts = [track.artist, track.album]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? String(localized: "Song") : parts.joined(separator: " · ")
  }

  private static func command(
    _ id: String, _ kind: QuickSearchCommand.Kind, _ title: LocalizedStringResource,
    _ subtitle: LocalizedStringResource,
    _ systemImage: String, _ keywords: [String], _ action: QuickSearchCommand.Action,
    shortcut: String? = nil
  ) -> QuickSearchCommand {
    QuickSearchCommand(
      id: id, kind: kind, title: String(localized: title), subtitle: String(localized: subtitle),
      systemImage: systemImage, keywords: keywords, action: action, shortcut: shortcut)
  }
}

/// Pre-normalized quick-search candidates. Building the index folds every
/// collection and track name exactly once, so it runs off the main actor when
/// the library changes and each keystroke afterwards only walks folded
/// strings.
struct QuickSearchIndex: Sendable {
  struct CollectionEntry: Sendable {
    let collection: LibraryCollection
    let bonus: Double
    let normalizedTitle: String
    let normalizedTitleCount: Int

    init(collection: LibraryCollection, bonus: Double) {
      self.collection = collection
      self.bonus = bonus
      normalizedTitle = QuickSearchMatcher.normalize(collection.title)
      normalizedTitleCount = normalizedTitle.count
    }
  }

  struct TrackEntry: Sendable {
    let track: LibraryTrack
    let title: String
    let normalizedTitle: String
    let normalizedTitleCount: Int
    let normalizedArtistAndTitle: String?
    let normalizedArtistAndTitleCount: Int

    init(track: LibraryTrack) {
      self.track = track
      title = track.displayTitle
      normalizedTitle = QuickSearchMatcher.normalize(title)
      normalizedTitleCount = normalizedTitle.count
      if track.artist.isEmpty {
        normalizedArtistAndTitle = nil
        normalizedArtistAndTitleCount = 0
      } else {
        let combined = QuickSearchMatcher.normalize("\(track.artist) \(title)")
        normalizedArtistAndTitle = combined
        normalizedArtistAndTitleCount = combined.count
      }
    }
  }

  let collections: [CollectionEntry]
  let tracks: [TrackEntry]
  private let albumByTrackID: [TrackID: LibraryCollection]

  init(
    artists: [LibraryCollection],
    albums: [LibraryCollection],
    genres: [LibraryCollection],
    audiobooks: [LibraryCollection],
    tracks: [LibraryTrack]
  ) {
    var collections: [CollectionEntry] = []
    collections.reserveCapacity(artists.count + genres.count + audiobooks.count + albums.count)
    // Kind order matches the kind bonuses: exact ties keep artists first.
    collections.append(
      contentsOf: artists.map { CollectionEntry(collection: $0, bonus: QuickSearch.artistBonus) })
    collections.append(
      contentsOf: genres.map { CollectionEntry(collection: $0, bonus: QuickSearch.genreBonus) })
    collections.append(
      contentsOf: audiobooks.map {
        CollectionEntry(collection: $0, bonus: QuickSearch.audiobookBonus)
      })
    collections.append(
      contentsOf: albums.map { CollectionEntry(collection: $0, bonus: QuickSearch.albumBonus) })
    self.collections = collections

    var albumByTrackID: [TrackID: LibraryCollection] = [:]
    for collection in albums {
      for track in collection.tracks where albumByTrackID[track.id] == nil {
        albumByTrackID[track.id] = collection
      }
    }
    self.albumByTrackID = albumByTrackID
    self.tracks = tracks.map(TrackEntry.init)
  }

  /// The album context a song result plays in: its album's full track run,
  /// or just the song when no album claims it.
  func albumTracks(for track: LibraryTrack) -> [LibraryTrack] {
    albumByTrackID[track.id]?.tracks ?? [track]
  }
}
