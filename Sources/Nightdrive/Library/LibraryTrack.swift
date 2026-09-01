import AVFoundation
import Foundation

enum LibraryAudioFormat: String, CaseIterable, Codable, Sendable {
  case mp3
  case m4a
  case m4b
  case aac
  case wav
  case aif
  case aiff
  case flac
  case caf

  init?(url: URL) {
    self.init(rawValue: url.pathExtension.lowercased())
  }

  var playsNativelyOnClassicIpods: Bool {
    switch self {
    case .mp3, .m4a, .m4b, .wav, .aif, .aiff:
      true
    case .aac, .flac, .caf:
      false
    }
  }

  var displayName: String {
    switch self {
    case .mp3: String(localized: "MPEG audio file")
    case .m4a, .aac: String(localized: "AAC audio file")
    case .m4b: String(localized: "Audiobook")
    case .wav: String(localized: "WAV audio file")
    case .aif, .aiff: String(localized: "AIFF audio file")
    case .flac: String(localized: "FLAC audio file")
    case .caf: String(localized: "CAF audio file")
    }
  }

  var supportsMetadataEditing: Bool {
    switch self {
    case .mp3, .m4a, .m4b:
      true
    case .aac, .wav, .aif, .aiff, .flac, .caf:
      false
    }
  }
}

enum IpodDeviceFamily: Equatable, Sendable {
  case firstOrSecondGeneration
  case thirdGenerationOrLater
  case shuffle
  case modernShuffle

  // Order-number/generation reference:
  // https://theapplewiki.com/wiki/Models/iPod#iPod_shuffle
  private static let earlyModelPrefixes = [
    "M8513", "M8541", "M8697", "M8709",  // 1st generation 5/10 GB
    "M8737", "M8740", "M8738", "M8741",  // 2nd generation 10/20 GB
  ]

  private static let legacyShuffleModelPrefixes = [
    "M9724", "M9725", "MA133",  // 1st generation 512 MB / 1 GB
    "MA546", "MA564", "MA947", "MA949", "MA951", "MA953",  // 2nd generation 1 GB
    "MB225", "MB227", "MB228", "MB229", "MB231", "MB233",
    "MB518", "MB520", "MB522", "MB524", "MB526",  // 2nd generation 1/2 GB
    "MB681", "MB683", "MB685", "MB779", "MB811", "MB813", "MB815", "MB817",
    "MC167",
  ]

  private static let thirdGenerationShuffleModelPrefixes = [
    "MB867", "MC164", "MC303", "MC306", "MC307", "MC323",  // 3rd generation
    "MC328", "MC331", "MC381", "MC384", "MC387",
  ]

  private static let fourthGenerationShuffleModelPrefixes = [
    "MC584", "MC585", "MC749", "MC750", "MC751",  // 4th generation, 2010
    "MD773", "MD774", "MD775", "MD776", "MD777", "MD778", "MD779", "MD780",
    "ME949", "MKM72", "MKM92", "MKME2", "MKMG2", "MKMJ2", "MKML2",
  ]

  init(modelNumber: String?) {
    guard let model = modelNumber?.uppercased() else {
      self = .thirdGenerationOrLater
      return
    }
    if Self.thirdGenerationShuffleModelPrefixes.contains(where: { model.hasPrefix($0) })
      || Self.fourthGenerationShuffleModelPrefixes.contains(where: { model.hasPrefix($0) })
    {
      self = .modernShuffle
    } else if Self.legacyShuffleModelPrefixes.contains(where: { model.hasPrefix($0) }) {
      self = .shuffle
    } else if Self.earlyModelPrefixes.contains(where: { model.hasPrefix($0) }) {
      self = .firstOrSecondGeneration
    } else {
      self = .thirdGenerationOrLater
    }
  }

  var playsAAC: Bool {
    switch self {
    case .firstOrSecondGeneration: false
    case .thirdGenerationOrLater, .shuffle, .modernShuffle: true
    }
  }

  var isShuffle: Bool {
    self == .shuffle || self == .modernShuffle
  }

  var supportsDevicePlaylists: Bool {
    self != .shuffle
  }

  static func shuffleGeneration(modelNumber: String?) -> Int? {
    guard let model = modelNumber?.uppercased() else { return nil }
    if thirdGenerationShuffleModelPrefixes.contains(where: { model.hasPrefix($0) }) { return 3 }
    if fourthGenerationShuffleModelPrefixes.contains(where: { model.hasPrefix($0) }) { return 4 }
    if ["M9724", "M9725", "MA133"].contains(where: { model.hasPrefix($0) }) { return 1 }
    if legacyShuffleModelPrefixes.contains(where: { model.hasPrefix($0) }) { return 2 }
    return nil
  }
}

enum DeviceDelivery: Equatable, Sendable {
  case direct
  case transcode(to: TranscodeProfile)
  case unsupported(reason: String)
}

enum LibraryMediaValidation: Hashable, Codable, Sendable {
  case valid
  case invalid(reason: String)
}

enum LibraryMediaKind: String, Hashable, Sendable, Codable {
  case song
  case audiobook
  case podcast
}

@dynamicMemberLookup
struct LibraryTrack: Identifiable, Sendable, Hashable, Codable {
  let id: TrackID
  let url: URL
  var metadata: TrackMetadata
  var durationMS: Int
  var sizeBytes: Int
  var bitrate: Int
  var samplerate: Int
  var modificationDate: Date?
  var fileGenerationStamp: FileGenerationStamp?
  var mediaValidation: LibraryMediaValidation
  var sortTitle: String = ""
  var sortAlbum: String = ""
  var sortArtist: String = ""
  var sortAlbumArtist: String = ""
  var sortComposer: String = ""
  var mediaKind: LibraryMediaKind = .song
  var gapless: GaplessInfo?
  var gainDB: Double?

  subscript<Value>(
    dynamicMember keyPath: WritableKeyPath<TrackMetadata, Value>
  ) -> Value {
    get { metadata[keyPath: keyPath] }
    set { metadata[keyPath: keyPath] = newValue }
  }

  /// Identity and the physical facts of the file are required; everything else
  /// is an optional tag that a real MP3 is free to omit.
  init(
    url: URL,
    title: String,
    artist: String = "",
    album: String = "",
    albumArtist: String = "",
    genre: String = "",
    composer: String = "",
    grouping: String = "",
    comment: String = "",
    lyrics: String = "",
    bpm: Int = 0,
    trackNumber: Int = 0,
    trackCount: Int = 0,
    discNumber: Int = 0,
    discCount: Int = 0,
    year: Int = 0,
    compilation: Bool = false,
    durationMS: Int,
    sizeBytes: Int,
    bitrate: Int,
    samplerate: Int,
    modificationDate: Date? = nil,
    fileGenerationStamp: FileGenerationStamp? = nil,
    mediaValidation: LibraryMediaValidation = .valid
  ) {
    self.id = TrackID(url: url)
    self.url = url
    self.metadata = TrackMetadata(
      title: title, artist: artist, album: album, albumArtist: albumArtist,
      composer: composer, genre: genre, grouping: grouping, year: year,
      bpm: bpm, trackNumber: trackNumber, trackCount: trackCount,
      discNumber: discNumber, discCount: discCount, comment: comment,
      lyrics: lyrics, compilation: compilation)
    self.durationMS = durationMS
    self.sizeBytes = sizeBytes
    self.bitrate = bitrate
    self.samplerate = samplerate
    self.modificationDate = modificationDate
    self.fileGenerationStamp = fileGenerationStamp
    self.mediaValidation = mediaValidation
  }

  var displayTitle: String {
    let trimmed = metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
  }

  var audioFormat: LibraryAudioFormat? {
    LibraryAudioFormat(url: url)
  }

  func deviceDelivery(
    for family: IpodDeviceFamily,
    transcode settings: TranscodeSettings = TranscodeSettings()
  ) -> DeviceDelivery {
    if case .invalid(let reason) = mediaValidation {
      return .unsupported(reason: reason)
    }
    guard let audioFormat else {
      return .unsupported(reason: String(localized: "The audio format is not recognized."))
    }
    if family.isShuffle {
      switch audioFormat {
      case .mp3, .m4a, .m4b, .wav:
        return .direct
      case .aac, .aif, .aiff, .flac, .caf:
        return .transcode(to: settings.aacProfile)
      }
    }
    if audioFormat.playsNativelyOnClassicIpods {
      return .direct
    }
    if family.playsAAC {
      return .transcode(to: settings.aacProfile)
    }
    return .unsupported(
      reason: String(
        localized:
          "\(audioFormat.rawValue.uppercased()) cannot be converted for this iPod: 1st- and 2nd-generation models play only MP3, which Nightdrive cannot encode."
      )
    )
  }

  var supportsMetadataEditing: Bool {
    audioFormat?.supportsMetadataEditing ?? false
  }

  static func formatDuration(ms: Int) -> String {
    let seconds = ms / 1000
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

enum TrackMatcher {
  struct Key: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int
  }

  static func normalize(_ s: String?) -> String {
    (s ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func key(
    title: String?, artist: String?, album: String?, discNumber: Int,
    trackNumber: Int, fallbackStem: String
  ) -> Key {
    var t = normalize(title)
    if t.isEmpty { t = normalize(fallbackStem) }
    return Key(
      title: t,
      artist: normalize(artist),
      album: normalize(album),
      discNumber: discNumber,
      trackNumber: trackNumber)
  }

  static func key(for track: LibraryTrack) -> Key {
    key(
      title: track.title, artist: track.artist, album: track.album,
      discNumber: track.discNumber, trackNumber: track.trackNumber,
      fallbackStem: track.url.deletingPathExtension().lastPathComponent)
  }

  static func key(for track: ITDBTrack) -> Key {
    let filename =
      track.ipodPath?.split(separator: ":", omittingEmptySubsequences: true).last
      .map(String.init) ?? ""
    return key(
      title: track.title, artist: track.artist, album: track.album,
      discNumber: Int(track.discNumber), trackNumber: Int(track.trackNumber),
      fallbackStem: (filename as NSString).deletingPathExtension)
  }
}

enum MetadataLoader {
  static func load(url: URL) async -> LibraryTrack {
    let generationStamp = FileGenerationStamp(url: url)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let size = generationStamp?.sizeBytes ?? (attrs?[.size] as? Int) ?? 0
    let modified = generationStamp?.modificationDate ?? attrs?[.modificationDate] as? Date

    var track = LibraryTrack(
      url: url, title: "", artist: "", album: "", genre: "", composer: "",
      trackNumber: 0, trackCount: 0, discNumber: 0, year: 0,
      durationMS: 0, sizeBytes: size, bitrate: 0, samplerate: 44100,
      modificationDate: modified, fileGenerationStamp: generationStamp)

    let asset = AVURLAsset(url: url)
    var assetDurationSeconds: Double?
    if let duration = try? await asset.load(.duration), duration.isNumeric {
      assetDurationSeconds = duration.seconds
      if track.audioFormat != .mp3 {
        track.durationMS = MP3DurationValidator.checkedMilliseconds(seconds: duration.seconds) ?? 0
      }
    }
    if let metadata = try? await asset.load(.metadata) {
      let commonTags: [AVMetadataKey: WritableKeyPath<LibraryTrack, String>] = [
        .commonKeyTitle: \.title, .commonKeyArtist: \.artist,
        .commonKeyAlbumName: \.album, .commonKeyType: \.genre,
        .commonKeyCreator: \.composer,
      ]
      for item in metadata {
        guard let common = item.commonKey, let keyPath = commonTags[common],
          let value = await item.loadedStringValue
        else { continue }
        track[keyPath: keyPath] = value
      }
      // ID3v2.3 / ID3v2.2 / MP4 spellings of the plain string tags.
      let stringTags: [([String], WritableKeyPath<LibraryTrack, String>)] = [
        (["TCON", "TCO", "\u{00A9}gen"], \.genre),
        (["TCOM", "\u{00A9}wrt"], \.composer),
        (["TIT1", "TT1", "GRP1", "\u{00A9}grp"], \.grouping),
        (["TPE2", "TP2", "aART"], \.albumArtist),
        (["COMM", "COM", "\u{00A9}cmt"], \.comment),
        (["USLT", "ULT", "\u{00A9}lyr"], \.lyrics),
        (["TSOT", "TST", "sonm"], \.sortTitle),
        (["TSOA", "TSA", "soal"], \.sortAlbum),
        (["TSOP", "TSP", "soar"], \.sortArtist),
        (["TSO2", "TS2", "soaa"], \.sortAlbumArtist),
        (["TSOC", "TSC", "soco"], \.sortComposer),
      ]
      var podcastMarker = false
      for item in metadata {
        guard let key = tagKey(for: item) else { continue }
        switch key {
        case "TRCK", "TRK":
          if let pair = await slashPair(item) {
            track.trackNumber = pair.index
            if let total = pair.total { track.trackCount = total }
          }
        case "TPOS", "TPA":
          if let pair = await slashPair(item) {
            track.discNumber = pair.index
            if let total = pair.total { track.discCount = total }
          }
        case "trkn":
          if let pair = await mp4NumberPair(item) {
            (track.trackNumber, track.trackCount) = pair
          }
        case "disk":
          if let pair = await mp4NumberPair(item) {
            (track.discNumber, track.discCount) = pair
          }
        case "TYER", "TDRC", "TYE", "\u{00A9}day":
          if let v = await item.loadedStringValue {
            track.year = Int(v.prefix(4)) ?? 0
            if let date = ID3ReleaseDate.parseTimestamp(v) { track.releaseDate = date }
          }
        case "TBPM", "TBP":
          if let v = await item.loadedStringValue { track.bpm = Int(v) ?? 0 }
        case "tmpo":
          if let n = await item.loadedNumberValue { track.bpm = n.intValue }
        case "TCMP", "TCP", "cpil":
          if let v = await item.loadedStringValue {
            track.compilation = v == "1" || v.localizedCaseInsensitiveCompare("true") == .orderedSame
          } else if let n = await item.loadedNumberValue {
            track.compilation = n.intValue != 0
          }
        case "stik":
          if let n = await item.loadedNumberValue, n.intValue == 2 {
            track.mediaKind = .audiobook
          }
        case "pcst", "PCST":
          // A missing/unloadable value on a pcst atom still marks a podcast.
          if (await item.loadedNumberValue)?.intValue != 0 { podcastMarker = true }
        default:
          if let keyPath = stringTags.first(where: { $0.0.contains(key) })?.1,
            let v = await item.loadedStringValue
          {
            track[keyPath: keyPath] = v
          }
        }
      }
      if track.mediaKind == .song, podcastMarker {
        track.mediaKind = .podcast
      }
    }
    if url.pathExtension.lowercased() == "m4b" {
      track.mediaKind = .audiobook
    }
    // MPEG-4 files carry an authoritative media kind in the stik atom, so the
    // genre convention only classifies formats without a dedicated marker.
    if track.mediaKind == .song, track.audioFormat != .m4a,
      track.metadata.hasAudiobookGenre
    {
      track.mediaKind = .audiobook
    }
    if track.mediaKind == .song,
      track.genre.caseInsensitiveCompare("Podcast") == .orderedSame
    {
      track.mediaKind = .podcast
    }
    if track.audioFormat == .mp3 {
      let ids = MusicBrainzID3.read(fromMP3At: url)
      track.musicBrainzRecordingID = ids.recordingID
      track.musicBrainzReleaseID = ids.releaseID
      track.musicBrainzArtistID = ids.artistID
      // AVFoundation does not surface TDAT/TIME/TDRL, so read the release
      // date through the repository's own ID3 parsing.
      if let date = ID3ReleaseDate.read(fromMP3At: url) { track.releaseDate = date }
    }
    var decoderDurationSeconds: Double?
    do {
      let audioFile = try AVAudioFile(forReading: url)
      let sampleRate = audioFile.fileFormat.sampleRate
      guard audioFile.length > 0, sampleRate.isFinite, sampleRate > 0,
        sampleRate < Double(Int.max)
      else {
        track.mediaValidation = .invalid(
          reason: String(localized: "The file does not contain playable audio."))
        return track
      }
      track.samplerate = Int(sampleRate)
      decoderDurationSeconds = Double(audioFile.length) / sampleRate
      if track.audioFormat != .mp3, track.durationMS == 0,
        let decoderDurationSeconds
      {
        track.durationMS =
          MP3DurationValidator.checkedMilliseconds(seconds: decoderDurationSeconds) ?? 0
      }
    } catch {
      track.mediaValidation = .invalid(
        reason: String(localized: "The audio file could not be decoded."))
      return track
    }
    if track.audioFormat == .mp3 {
      let facts = MP3DurationValidator.inspect(
        url: url, assetSeconds: assetDurationSeconds,
        decoderSeconds: decoderDurationSeconds,
        isCancelled: { Task.isCancelled })
      guard
        let seconds = MP3DurationValidator.resolveDurationSeconds(
          assetSeconds: assetDurationSeconds,
          decoderSeconds: decoderDurationSeconds,
          fileSizeBytes: size,
          facts: facts),
        let durationMS = MP3DurationValidator.checkedMilliseconds(seconds: seconds)
      else {
        track.mediaValidation = .invalid(
          reason: String(localized: "The audio file does not contain a trustworthy duration."))
        return track
      }
      track.durationMS = durationMS
    }
    if track.durationMS > 0 {
      track.bitrate =
        MP3DurationValidator.checkedBitrateKbps(
          sizeBytes: size, durationMS: track.durationMS) ?? 0
    }
    return track
  }

  private static func tagKey(for item: AVMetadataItem) -> String? {
    if let key = item.key as? String { return key }
    guard let identifier = item.identifier?.rawValue,
      let raw = identifier.split(separator: "/").last.map(String.init)
    else { return nil }
    return raw.replacingOccurrences(of: "%A9", with: "\u{00A9}")
  }

  /// Parse an ID3 "index/total" string tag like "5/12" or a bare "5".
  private static func slashPair(_ item: AVMetadataItem) async -> (
    index: Int, total: Int?
  )? {
    guard let v = await item.loadedStringValue else { return nil }
    let parts = v.split(separator: "/")
    return (Int(parts.first ?? "") ?? 0, parts.count > 1 ? (Int(parts[1]) ?? 0) : nil)
  }

  private static func mp4NumberPair(_ item: AVMetadataItem) async -> (
    index: Int, total: Int
  )? {
    guard let data = await item.loadedDataValue, data.count >= 6 else { return nil }
    let bytes = [UInt8](data)
    let index = Int(bytes[2]) << 8 | Int(bytes[3])
    let total = Int(bytes[4]) << 8 | Int(bytes[5])
    return (index, total)
  }

  static func loadArtwork(url: URL) async -> Data? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.metadata) else { return nil }
    for item in metadata where item.commonKey == .commonKeyArtwork {
      if let data = await item.loadedDataValue { return data }
    }
    return nil
  }
}
