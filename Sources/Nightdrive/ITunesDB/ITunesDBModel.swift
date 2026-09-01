import Foundation

enum ITDBAudioCodec: Equatable, Sendable {
  case mp3
  case aac
  case pcm
  case unknown

  init(filetypeMarker: UInt32) {
    switch filetypeMarker {
    case Self.marker("MP3 "):
      self = .mp3
    case Self.marker("M4A "), Self.marker("M4B "), Self.marker("M4R "), Self.marker("MP4 "):
      self = .aac
    case Self.marker("WAV "), Self.marker("AIF "), Self.marker("AIFF"):
      self = .pcm
    default:
      self = .unknown
    }
  }

  init(fileExtension: String) {
    self.init(filetypeMarker: Self.marker(fileExtension.uppercased()))
  }

  var binaryType2: UInt8? {
    switch self {
    case .mp3: 1
    case .aac: 0
    case .pcm, .unknown: nil
    }
  }

  var nanoAudioFormat: Int64 {
    switch self {
    case .mp3: 301
    case .aac: 502
    case .pcm, .unknown: 0
    }
  }

  var filetypeDescription: String {
    switch self {
    case .mp3: "MPEG audio file"
    case .aac: "AAC audio file"
    case .pcm: "PCM audio file"
    case .unknown: "Audio file"
    }
  }

  private static func marker(_ value: String) -> UInt32 {
    var result: UInt32 = 0
    let bytes = Array(value.utf8.prefix(4))
    for index in 0..<4 {
      result <<= 8
      result |= UInt32(index < bytes.count ? bytes[index] : UInt8(ascii: " "))
    }
    return result
  }
}

struct ITDBTrackArtwork: Equatable, Sendable {
  var mhiiID: UInt32
  var sizeBytes: UInt32
  var count: UInt16 = 1

  static let cleared = ITDBTrackArtwork(mhiiID: 0, sizeBytes: 0, count: 0)
  var hasArtwork: Bool { mhiiID != 0 }
}

struct ITDBTrack: Identifiable, Sendable {
  var id: UInt32 = 0
  var dbid: UInt64 = ITDBTrack.randomDbid()

  var title: String?
  var artist: String?
  var album: String?
  var albumArtist: String?
  var genre: String?
  var composer: String?
  var comment: String?
  var sortTitle: String?
  var sortAlbum: String?
  var sortArtist: String?
  var sortAlbumArtist: String?
  var sortComposer: String?
  var filetypeDescription: String? = "MPEG audio file"
  var ipodPath: String?

  var sizeBytes: UInt32 = 0
  var lengthMS: UInt32 = 0
  var trackNumber: UInt32 = 0
  var trackCount: UInt32 = 0
  var discNumber: UInt32 = 0
  var discCount: UInt32 = 0
  var year: UInt32 = 0
  var bitrate: UInt32 = 0
  var samplerate: UInt16 = 44100
  var samplerateLow: UInt16 = 0
  var volumeAdjustment: Int32 = 0
  var soundcheck: UInt32 = 0

  var mediaKind: UInt32 = ITDBMediaKind.audio.rawValue
  var rememberPlaybackPosition: Bool = false
  var skipWhenShuffling: Bool = false

  var pregap: UInt32 = 0
  var postgap: UInt32 = 0
  var sampleCount: UInt64 = 0
  var gaplessData: UInt32 = 0
  var gaplessTrackFlag: Bool = false
  var gaplessAlbumFlag: Bool = false

  var playCount: UInt32 = 0
  var playCount2: UInt32 = 0
  var bookmarkMS: UInt32 = 0
  var skipCount: UInt32 = 0
  var rating: UInt8 = 0
  var vbr: Bool = false
  var artwork: ITDBTrackArtwork?
  var type2: UInt8 = 1
  var compilation: Bool = false

  var timeAdded: Date?
  var timeModified: Date?
  var timePlayed: Date?
  var lastSkipped: Date?
  var timeReleased: Date?

  var filetypeMarker: UInt32 = 0x4D50_3320

  var preservedMhitHeader: Data?
  var preservedMhods: [Data] = []

  static func randomDbid() -> UInt64 {
    var v: UInt64 = 0
    while v == 0 { v = UInt64.random(in: UInt64.min...UInt64.max) }
    return v
  }

  var relativeFilePath: String? {
    guard let p = ipodPath else { return nil }
    return IpodPath.slashSeparated(p)
  }

  var audioCodec: ITDBAudioCodec {
    let markerCodec = ITDBAudioCodec(filetypeMarker: filetypeMarker)
    if markerCodec != .unknown { return markerCodec }
    if let path = ipodPath {
      let pathCodec = ITDBAudioCodec(
        fileExtension: URL(fileURLWithPath: IpodPath.slashSeparated(path))
          .pathExtension)
      if pathCodec != .unknown { return pathCodec }
    }
    switch type2 {
    case 1: return .mp3
    case 0: return .aac
    default: return .unknown
    }
  }
}

enum ITDBMediaKind: UInt32, Sendable {
  case audio = 1
  case podcast = 4
  case audiobook = 8
}

struct ITDBPlaylist: Sendable {
  var name: String
  var isMaster: Bool
  var persistentID: UInt64 = ITDBTrack.randomDbid()
  var timestamp: Date?
  var sortOrder: UInt32 = 1
  var memberDbids: [UInt64] = []
  var isPodcast: Bool = false
  var podcastGroups: [ITDBPodcastGroup] = []
  var preservedMhypHeader: Data?
  var preservedMhods: [Data] = []
  var preservedMembers: [ITDBPlaylistMember] = []
}

/// One show heading inside a podcast playlist: a group mhip carrying the
/// show title followed by that show's episode mhips.
struct ITDBPodcastGroup: Equatable, Sendable {
  var title: String
  var episodeDbids: [UInt64] = []
}

struct ITDBPlaylistMember: Sendable {
  var dbid: UInt64?
  var data: Data
}

struct ITunesDatabase: Sendable {
  var tracks: [ITDBTrack] = []
  var playlists: [ITDBPlaylist] = []

  var databaseID: UInt64 = ITDBTrack.randomDbid()
  var libraryPersistentID: UInt64 = ITDBTrack.randomDbid()
  var masterPlaylistID: UInt64 = ITDBTrack.randomDbid()
  var id0x24: UInt64 = 0
  var platform: UInt16 = 1  // 1 = macOS
  var language: UInt16 = 0
  var timezoneShift: Int = TimeZone.current.secondsFromGMT()

  var masterPlaylistName: String = "Nightdrive"
  var masterPlaylistTemplate: ITDBPlaylist?
  var podcastPlaylists: [ITDBPlaylist] = []

  var preservedMhbdHeader: Data?
  var preservedSections: [ITDBPreservedSection] = []

  var sourceTrackDbids: Set<UInt64>?
  var sourcePlaylistIDs: Set<UInt64>?
}

struct ITDBPreservedSection: Sendable {
  var type: UInt32
  var data: Data
}
