import Foundation

// MARK: - Smart playlist rules

enum SmartPlaylistPredicate: Codable, Equatable, Sendable {
  case artistContains(String)
  case albumContains(String)
  case genreContains(String)
  case yearBetween(minimum: Int?, maximum: Int?)
  case ratingAtLeast(Int)
  case playCountAtLeast(Int)
  case addedWithinDays(Int)
  case favorite
  case format(LibraryAudioFormat)

  var summary: String {
    switch self {
    case .artistContains(let text): String(localized: "artist contains “\(text)”")
    case .albumContains(let text): String(localized: "album contains “\(text)”")
    case .genreContains(let text): String(localized: "genre contains “\(text)”")
    case .yearBetween(let minimum, let maximum):
      switch (minimum, maximum) {
      case (let low?, let high?): String(localized: "year \(low)–\(high)")
      case (let low?, nil): String(localized: "year ≥ \(low)")
      case (nil, let high?): String(localized: "year ≤ \(high)")
      case (nil, nil): String(localized: "any year")
      }
    case .ratingAtLeast(let stars): String(localized: "rated ≥ \(stars)★")
    case .playCountAtLeast(let plays): String(localized: "played ≥ \(plays)×")
    case .addedWithinDays(let days):
      days == 1
        ? String(localized: "added in the last 1 day")
        : String(localized: "added in the last \(days) days")
    case .favorite: String(localized: "favorite")
    case .format(let format):
      String(localized: "format is \(format.rawValue.uppercased())")
    }
  }
}

struct SmartPlaylistRule: Codable, Equatable, Sendable {
  var predicates: [SmartPlaylistPredicate] = []

  var summary: String {
    predicates.isEmpty
      ? String(localized: "all songs")
      : ListFormatter.localizedString(byJoining: predicates.map(\.summary))
  }
}

struct SmartRuleFacts: Equatable, Sendable {
  var rating = 0
  var playCount = 0
  var isFavorite = false
  var lastPlayedAt: Date? = nil

  init(rating: Int = 0, playCount: Int = 0, isFavorite: Bool = false, lastPlayedAt: Date? = nil) {
    self.rating = rating
    self.playCount = playCount
    self.isFavorite = isFavorite
    self.lastPlayedAt = lastPlayedAt
  }

  init(_ metadata: TrackListeningMetadata) {
    self.init(
      rating: metadata.rating, playCount: metadata.playCount,
      isFavorite: metadata.isFavorite, lastPlayedAt: metadata.lastPlayedAt)
  }
}

enum SmartPlaylistEvaluator {
  static func matches(
    _ rule: SmartPlaylistRule, track: LibraryTrack, facts: SmartRuleFacts,
    dateAdded: @autoclosure () -> Date?, now: Date
  ) -> Bool {
    for predicate in rule.predicates {
      switch predicate {
      case .artistContains(let text):
        guard contains(track.artist, text) else { return false }
      case .albumContains(let text):
        guard contains(track.album, text) else { return false }
      case .genreContains(let text):
        guard track.genres.contains(where: { contains($0, text) }) else { return false }
      case .yearBetween(let minimum, let maximum):
        guard track.year > 0 else { return false }
        if let minimum, track.year < minimum { return false }
        if let maximum, track.year > maximum { return false }
      case .ratingAtLeast(let stars):
        guard facts.rating >= stars else { return false }
      case .playCountAtLeast(let plays):
        guard facts.playCount >= plays else { return false }
      case .addedWithinDays(let days):
        guard let added = dateAdded(),
          added >= now.addingTimeInterval(-Double(days) * 86_400)
        else { return false }
      case .favorite:
        guard facts.isFavorite else { return false }
      case .format(let format):
        guard track.audioFormat == format else { return false }
      }
    }
    return true
  }

  static func evaluate(
    _ rule: SmartPlaylistRule,
    library: [LibraryTrack],
    facts: [String: SmartRuleFacts],
    now: Date = Date(),
    dateAdded: (URL) -> Date? = SmartPlaylistEvaluator.fileDateAdded
  ) -> [LibraryTrack] {
    let needsDates = rule.predicates.contains {
      if case .addedWithinDays = $0 { return true } else { return false }
    }
    var matched: [(sortKey: SortKey, track: LibraryTrack)] = []
    for track in library {
      let key = track.id.rawValue
      let trackFacts = facts[key] ?? SmartRuleFacts()
      guard
        matches(
          rule, track: track, facts: trackFacts,
          dateAdded: needsDates ? dateAdded(track.url) : nil, now: now)
      else { continue }
      matched.append((SortKey(track: track, urlKey: key), track))
    }
    matched.sort { $0.sortKey < $1.sortKey }
    return matched.map(\.track)
  }

  static func refresh(
    _ playlists: [LocalPlaylist],
    library: [LibraryTrack],
    facts: [String: SmartRuleFacts],
    now: Date = Date()
  ) -> (playlists: [LocalPlaylist], changed: Bool) {
    var playlists = playlists
    var changed = false
    for index in playlists.indices {
      guard let rule = playlists[index].smartRule else { continue }
      let trackIDs = evaluate(rule, library: library, facts: facts, now: now).map(\.id)
      if playlists[index].trackIDs != trackIDs {
        playlists[index].trackIDs = trackIDs
        changed = true
      }
    }
    return (playlists, changed)
  }

  static func fileDateAdded(for url: URL) -> Date? {
    let values = try? url.resourceValues(forKeys: [
      .creationDateKey, .contentModificationDateKey,
    ])
    return values?.creationDate ?? values?.contentModificationDate
  }

  private static func contains(_ haystack: String, _ needle: String) -> Bool {
    let needle = needle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private struct SortKey: Comparable {
    let artist: String
    let album: String
    let disc: Int
    let track: Int
    let title: String
    let urlKey: String

    init(track: LibraryTrack, urlKey: String) {
      artist = track.artist.lowercased()
      album = track.album.lowercased()
      disc = track.discNumber
      self.track = track.trackNumber
      title = track.displayTitle.lowercased()
      self.urlKey = urlKey
    }

    static func < (lhs: SortKey, rhs: SortKey) -> Bool {
      if lhs.artist != rhs.artist { return lhs.artist < rhs.artist }
      if lhs.album != rhs.album { return lhs.album < rhs.album }
      if lhs.disc != rhs.disc { return lhs.disc < rhs.disc }
      if lhs.track != rhs.track { return lhs.track < rhs.track }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.urlKey < rhs.urlKey
    }
  }
}

// MARK: - Per-device sync scope

enum TrackSyncMode: String, Codable, Equatable, Sendable {
  case twoWay
  case libraryToIpod
  case ipodToLibrary

  var summary: String {
    switch self {
    case .twoWay: "Two-way"
    case .libraryToIpod: "One-way (Library to iPod)"
    case .ipodToLibrary: "One-way (iPod to Library)"
    }
  }
}

enum SyncScope: Codable, Equatable, Sendable {
  case everything
  case playlists([UUID])
  case rules(SmartPlaylistRule)

  var summary: String {
    switch self {
    case .everything: String(localized: "Everything")
    case .playlists(let ids):
      ids.count == 1
        ? String(localized: "1 playlist") : String(localized: "\(ids.count) playlists")
    case .rules(let rule): String(localized: "Rules: \(rule.summary)")
    }
  }
}

struct SyncDeviceSettings: Codable, Equatable, Sendable {
  var scope: SyncScope = .everything
  var trackSyncMode: TrackSyncMode = .twoWay
  var removesSongsNotInLibrary: Bool = false
  var removesSongsOutsideSyncScope: Bool = false
  var autoSyncOnConnect: Bool = false
  var ejectAfterSync: Bool = false
  var displayName: String? = nil

}

struct SyncScopeInput: Sendable {
  var scope: SyncScope = .everything
  var trackSyncMode: TrackSyncMode = .twoWay
  var removesSongsNotInLibrary = false
  var removesSongsOutsideSyncScope = false
  var localPlaylists: [LocalPlaylist] = []
  var listeningFacts: [String: SmartRuleFacts] = [:]
  var excludedURLKeys: Set<String> = []
  var confirmedRemovalDbids: Set<UInt64>? = nil
  var referenceDate = Date()
}

enum SyncScopeResolver {
  static func inScopeKeys(_ input: SyncScopeInput, library: [LibraryTrack]) -> Set<String>? {
    switch input.scope {
    case .everything:
      return nil
    case .playlists(let ids):
      let wanted = Set(ids)
      var keys = Set<String>()
      for playlist in input.localPlaylists where wanted.contains(playlist.id) {
        for trackID in playlist.trackIDs { keys.insert(trackID.rawValue) }
      }
      return keys
    case .rules(let rule):
      var keys = Set<String>()
      for track in SmartPlaylistEvaluator.evaluate(
        rule, library: library, facts: input.listeningFacts, now: input.referenceDate)
      {
        keys.insert(track.id.rawValue)
      }
      return keys
    }
  }

  static func playlistsForReconciliation(
    _ playlists: [LocalPlaylist], scope: SyncScope
  ) -> [LocalPlaylist] {
    guard case .playlists(let ids) = scope else { return playlists }
    let wanted = Set(ids)
    return playlists.map { playlist in
      var playlist = playlist
      if !wanted.contains(playlist.id) { playlist.syncEnabled = false }
      return playlist
    }
  }
}

// MARK: - Capacity preflight

enum SyncCapacity {
  static let reserveBytes: Int64 = 50_000_000
  static let artworkBytesPerTrack: Int64 = 65_536

  static func estimatedBytes(
    for track: LibraryTrack, family: IpodDeviceFamily, settings: TranscodeSettings
  ) -> Int64 {
    switch track.deviceDelivery(for: family, transcode: settings) {
    case .transcode(let profile):
      return Int64(profile.bitrateKbps) * Int64(track.durationMS) / 8
    case .direct, .unsupported:
      return Int64(track.sizeBytes)
    }
  }

  static func plannedOutboundBytes(
    _ plan: SyncPlan, family: IpodDeviceFamily, settings: TranscodeSettings
  ) -> Int64 {
    let copies = plan.copyToDevice.reduce(Int64(0)) {
      $0 + estimatedBytes(for: $1, family: family, settings: settings)
    }
    let updates = plan.updateOnDevice.reduce(Int64(0)) {
      $0 + estimatedBytes(for: $1.local, family: family, settings: settings)
    }
    return copies + updates + artworkBytesPerTrack * Int64(plan.copyToDevice.count)
  }

  static func shortfall(
    plan: SyncPlan, availableCapacity: Int64,
    family: IpodDeviceFamily, settings: TranscodeSettings
  ) -> Int64? {
    let needed = plannedOutboundBytes(plan, family: family, settings: settings)
    guard needed > 0 else { return nil }
    let over = needed - (availableCapacity - reserveBytes)
    return over > 0 ? over : nil
  }

  static func suggestedTrim(
    plan: SyncPlan, shortfall: Int64,
    family: IpodDeviceFamily, settings: TranscodeSettings
  ) -> [LibraryTrack] {
    guard shortfall > 0 else { return [] }
    let facts = plan.scopeInput.listeningFacts
    let ordered = plan.copyToDevice.sorted { lhs, rhs in
      let lhsKey = lhs.id.rawValue
      let rhsKey = rhs.id.rawValue
      let lhsFacts = facts[lhsKey] ?? SmartRuleFacts()
      let rhsFacts = facts[rhsKey] ?? SmartRuleFacts()
      if lhsFacts.rating != rhsFacts.rating { return lhsFacts.rating < rhsFacts.rating }
      let lhsPlayed = lhsFacts.lastPlayedAt ?? .distantPast
      let rhsPlayed = rhsFacts.lastPlayedAt ?? .distantPast
      if lhsPlayed != rhsPlayed { return lhsPlayed < rhsPlayed }
      return lhsKey < rhsKey
    }
    var trimmed: [LibraryTrack] = []
    var recovered: Int64 = 0
    for track in ordered {
      guard recovered < shortfall else { break }
      recovered +=
        estimatedBytes(for: track, family: family, settings: settings) + artworkBytesPerTrack
      trimmed.append(track)
    }
    return trimmed
  }
}
