import Foundation

/// Immutable so SwiftUI's table cells share this metadata payload instead of
/// copying every column value while rows are recycled during scrolling.
final class SongRow<ID: Hashable & Sendable>: Identifiable, Equatable, Sendable {
  let id: ID
  let title: String
  let durationMS: Int
  let artist: String
  let album: String
  let genre: String
  let albumArtist: String
  let composer: String
  let comment: String
  let year: Int
  let trackNumber: Int
  let discNumber: Int
  let bpm: Int
  let rating: Int
  let isFavorite: Bool
  let playCount: Int
  let lastPlayedAt: Date?
  let dateModified: Date?
  let kind: String
  let sizeBytes: Int
  let bitrate: Int
  let samplerate: Int
  let location: String

  init(
    id: ID,
    title: String,
    durationMS: Int,
    artist: String,
    album: String,
    genre: String,
    albumArtist: String = "",
    composer: String = "",
    comment: String = "",
    year: Int = 0,
    trackNumber: Int = 0,
    discNumber: Int = 0,
    bpm: Int = 0,
    rating: Int = 0,
    isFavorite: Bool = false,
    playCount: Int = 0,
    lastPlayedAt: Date? = nil,
    dateModified: Date? = nil,
    kind: String = "",
    sizeBytes: Int = 0,
    bitrate: Int = 0,
    samplerate: Int = 0,
    location: String = ""
  ) {
    self.id = id
    self.title = title
    self.durationMS = durationMS
    self.artist = artist
    self.album = album
    self.genre = genre
    self.albumArtist = albumArtist
    self.composer = composer
    self.comment = comment
    self.year = year
    self.trackNumber = trackNumber
    self.discNumber = discNumber
    self.bpm = bpm
    self.rating = rating
    self.isFavorite = isFavorite
    self.playCount = playCount
    self.lastPlayedAt = lastPlayedAt
    self.dateModified = dateModified
    self.kind = kind
    self.sizeBytes = sizeBytes
    self.bitrate = bitrate
    self.samplerate = samplerate
    self.location = location
  }

  static func == (lhs: SongRow<ID>, rhs: SongRow<ID>) -> Bool {
    lhs === rhs
      || (lhs.id == rhs.id
        && lhs.title == rhs.title
        && lhs.durationMS == rhs.durationMS
        && lhs.artist == rhs.artist
        && lhs.album == rhs.album
        && lhs.genre == rhs.genre
        && lhs.albumArtist == rhs.albumArtist
        && lhs.composer == rhs.composer
        && lhs.comment == rhs.comment
        && lhs.year == rhs.year
        && lhs.trackNumber == rhs.trackNumber
        && lhs.discNumber == rhs.discNumber
        && lhs.bpm == rhs.bpm
        && lhs.rating == rhs.rating
        && lhs.isFavorite == rhs.isFavorite
        && lhs.playCount == rhs.playCount
        && lhs.lastPlayedAt == rhs.lastPlayedAt
        && lhs.dateModified == rhs.dateModified
        && lhs.kind == rhs.kind
        && lhs.sizeBytes == rhs.sizeBytes
        && lhs.bitrate == rhs.bitrate
        && lhs.samplerate == rhs.samplerate
        && lhs.location == rhs.location)
  }

  func matches(_ filter: String) -> Bool {
    filter.isEmpty
      || title.localizedCaseInsensitiveContains(filter)
      || artist.localizedCaseInsensitiveContains(filter)
      || album.localizedCaseInsensitiveContains(filter)
      || genre.localizedCaseInsensitiveContains(filter)
  }
}

// MARK: - Cell text

extension SongRow {
  var timeText: String { LibraryTrack.formatDuration(ms: durationMS) }

  var yearText: String { year > 0 ? String(year) : "" }

  var trackNumberText: String { trackNumber > 0 ? String(trackNumber) : "" }

  var discNumberText: String { discNumber > 0 ? String(discNumber) : "" }

  var bpmText: String { bpm > 0 ? String(bpm) : "" }

  var playCountText: String { playCount > 0 ? String(playCount) : "" }

  var sizeText: String { sizeBytes > 0 ? Int64(sizeBytes).byteText : "" }

  var bitrateText: String { bitrate > 0 ? "\(bitrate) kbps" : "" }

  var samplerateText: String {
    guard samplerate > 0 else { return "" }
    let kHz = Double(samplerate) / 1000
    let rounded = kHz.rounded()
    let text =
      abs(kHz - rounded) < 0.05
      ? String(format: "%.0f", rounded)
      : String(format: "%.1f", kHz)
    return "\(text) kHz"
  }

  var lastPlayedText: String { Self.dateText(lastPlayedAt) }

  var dateModifiedText: String { Self.dateText(dateModified) }

  var lastPlayedSortKey: Date { lastPlayedAt ?? .distantPast }

  var dateModifiedSortKey: Date { dateModified ?? .distantPast }

  var ratingText: String { String(repeating: "★", count: min(max(rating, 0), 5)) }

  private static func dateText(_ date: Date?) -> String {
    guard let date else { return "" }
    return date.formatted(date: .numeric, time: .shortened)
  }
}

// MARK: - Sources

extension SongRow where ID == TrackID {
  convenience init(track: LibraryTrack, listening: TrackListeningMetadata?) {
    self.init(
      id: track.id,
      title: track.displayTitle,
      durationMS: track.durationMS,
      artist: track.artist,
      album: track.album,
      genre: track.genre,
      albumArtist: track.albumArtist,
      composer: track.composer,
      comment: track.comment,
      year: track.year,
      trackNumber: track.trackNumber,
      discNumber: track.discNumber,
      bpm: track.bpm,
      rating: listening?.rating ?? 0,
      isFavorite: listening?.isFavorite ?? false,
      playCount: listening?.playCount ?? 0,
      lastPlayedAt: listening?.lastPlayedAt,
      dateModified: track.modificationDate,
      kind: track.audioFormat?.displayName ?? "",
      sizeBytes: track.sizeBytes,
      bitrate: track.bitrate,
      samplerate: track.samplerate,
      location: track.url.path(percentEncoded: false))
  }
}

extension SongRow where ID == UInt64 {
  convenience init(deviceTrack track: ITDBTrack) {
    let filename = (track.relativeFilePath as NSString?)?.lastPathComponent
    self.init(
      id: track.dbid,
      title: track.title ?? (filename ?? String(localized: "Unknown")),
      durationMS: Int(track.lengthMS),
      artist: track.artist ?? "",
      album: track.album ?? "",
      genre: track.genre ?? "",
      albumArtist: track.albumArtist ?? "",
      composer: track.composer ?? "",
      comment: track.comment ?? "",
      year: Int(track.year),
      trackNumber: Int(track.trackNumber),
      discNumber: Int(track.discNumber),
      bpm: 0,
      rating: Int(track.rating) / 20,
      isFavorite: false,
      playCount: Int(track.playCount),
      lastPlayedAt: track.timePlayed,
      dateModified: track.timeModified,
      kind: track.filetypeDescription ?? "",
      sizeBytes: Int(track.sizeBytes),
      bitrate: Int(track.bitrate),
      samplerate: Int(track.samplerate),
      location: track.relativeFilePath ?? "")
  }
}

// MARK: - Columns

enum SongTableColumn: String, CaseIterable, Sendable {
  case time
  case artist
  case album
  case genre
  case albumArtist
  case composer
  case year
  case trackNumber
  case discNumber
  case rating
  case playCount
  case lastPlayed
  case dateModified
  case kind
  case size
  case bitrate
  case samplerate
  case bpm
  case comment
  case location

  var customizationID: String { "song.\(rawValue)" }

  var title: String {
    switch self {
    case .time: String(localized: "Time")
    case .artist: String(localized: "Artist")
    case .album: String(localized: "Album")
    case .genre: String(localized: "Genre")
    case .albumArtist: String(localized: "Album Artist")
    case .composer: String(localized: "Composer")
    case .year: String(localized: "Year")
    case .trackNumber: String(localized: "Track")
    case .discNumber: String(localized: "Disc")
    case .rating: String(localized: "Rating")
    case .playCount: String(localized: "Plays")
    case .lastPlayed: String(localized: "Last Played")
    case .dateModified: String(localized: "Date Modified")
    case .kind: String(localized: "Kind")
    case .size: String(localized: "Size")
    case .bitrate: String(localized: "Bit Rate")
    case .samplerate: String(localized: "Sample Rate")
    case .bpm: String(localized: "BPM")
    case .comment: String(localized: "Comment")
    case .location: String(localized: "Location")
    }
  }

  var isVisibleByDefault: Bool {
    switch self {
    case .time, .artist, .album, .genre: true
    default: false
    }
  }
}
