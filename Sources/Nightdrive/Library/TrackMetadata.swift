import Foundation

struct TrackMetadata: Equatable, Hashable, Sendable, Codable {
  var title: String
  var artist: String
  var album: String
  var albumArtist: String
  var composer: String
  var genre: String
  var grouping: String
  var year: Int
  var bpm: Int
  var trackNumber: Int
  var trackCount: Int
  var discNumber: Int
  var discCount: Int
  var comment: String
  var lyrics: String
  var compilation: Bool
  /// Full release/publication date when the file carries one (podcast
  /// episodes); `year` alone otherwise.
  var releaseDate: Date?
  var musicBrainzRecordingID: String
  var musicBrainzReleaseID: String
  var musicBrainzArtistID: String

  init(
    title: String,
    artist: String,
    album: String,
    albumArtist: String,
    composer: String,
    genre: String,
    grouping: String,
    year: Int,
    bpm: Int,
    trackNumber: Int,
    trackCount: Int,
    discNumber: Int,
    discCount: Int,
    comment: String,
    lyrics: String,
    compilation: Bool,
    releaseDate: Date? = nil,
    musicBrainzRecordingID: String = "",
    musicBrainzReleaseID: String = "",
    musicBrainzArtistID: String = ""
  ) {
    self.title = title
    self.artist = artist
    self.album = album
    self.albumArtist = albumArtist
    self.composer = composer
    self.genre = genre
    self.grouping = grouping
    self.year = year
    self.bpm = bpm
    self.trackNumber = trackNumber
    self.trackCount = trackCount
    self.discNumber = discNumber
    self.discCount = discCount
    self.comment = comment
    self.lyrics = lyrics
    self.compilation = compilation
    self.releaseDate = releaseDate
    self.musicBrainzRecordingID = musicBrainzRecordingID
    self.musicBrainzReleaseID = musicBrainzReleaseID
    self.musicBrainzArtistID = musicBrainzArtistID
  }

  init(_ track: LibraryTrack) {
    self = track.metadata
    title = track.displayTitle
  }

  init(_ track: ITDBTrack) {
    title = track.title ?? ""
    artist = track.artist ?? ""
    album = track.album ?? ""
    albumArtist = track.albumArtist ?? ""
    composer = track.composer ?? ""
    genre = track.genre ?? ""
    grouping = ""
    year = Int(track.year)
    bpm = 0
    trackNumber = Int(track.trackNumber)
    trackCount = Int(track.trackCount)
    discNumber = Int(track.discNumber)
    discCount = Int(track.discCount)
    comment = track.comment ?? ""
    lyrics = ""
    compilation = track.compilation
    releaseDate = track.timeReleased
    musicBrainzRecordingID = ""
    musicBrainzReleaseID = ""
    musicBrainzArtistID = ""
  }

  init(fileTrack: LibraryTrack, databaseTrack: ITDBTrack) {
    self.init(fileTrack)
    let secondaryGenres = Array(genres.dropFirst())
    let database = TrackMetadata(databaseTrack)
    title = database.title
    artist = database.artist
    album = database.album
    albumArtist = database.albumArtist
    composer = database.composer
    genres = [database.primaryGenre] + secondaryGenres
    year = database.year
    trackNumber = database.trackNumber
    trackCount = database.trackCount
    discNumber = database.discNumber
    discCount = database.discCount
    comment = database.comment
    compilation = database.compilation
    releaseDate = databaseTrack.timeReleased ?? releaseDate
  }

  var normalized: TrackMetadata {
    var copy = self
    for field in MetadataField.stringFields {
      copy[keyPath: field.value] =
        self[keyPath: field.value].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    for field in MetadataField.numberFields {
      copy[keyPath: field.value] = max(self[keyPath: field.value], 0)
    }
    copy.musicBrainzRecordingID = musicBrainzRecordingID.trimmingCharacters(
      in: .whitespacesAndNewlines)
    copy.musicBrainzReleaseID = musicBrainzReleaseID.trimmingCharacters(
      in: .whitespacesAndNewlines)
    copy.musicBrainzArtistID = musicBrainzArtistID.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return copy
  }

  func applying(to track: inout ITDBTrack) {
    let metadata = normalized
    func optional(_ value: String) -> String? {
      value.isEmpty ? nil : value
    }
    track.title = optional(metadata.title)
    track.artist = optional(metadata.artist)
    track.album = optional(metadata.album)
    track.albumArtist = optional(metadata.albumArtist)
    track.composer = optional(metadata.composer)
    // The classic iTunesDB has one genre reference per track. Keep the full
    // ordered list in the library file and send its primary value to devices.
    track.genre = optional(metadata.primaryGenre)
    track.comment = optional(metadata.comment)
    track.year = UInt32(clamping: metadata.year)
    track.trackNumber = UInt32(clamping: metadata.trackNumber)
    track.trackCount = UInt32(clamping: metadata.trackCount)
    track.discNumber = UInt32(clamping: metadata.discNumber)
    track.discCount = UInt32(clamping: metadata.discCount)
    track.compilation = metadata.compilation
    track.timeModified = Date()
  }
}

struct TrackMetadataChanges: Equatable, Sendable {
  var title: String? = nil
  var artist: String? = nil
  var album: String? = nil
  var albumArtist: String? = nil
  var composer: String? = nil
  var genre: String? = nil
  var grouping: String? = nil
  var year: Int? = nil
  var bpm: Int? = nil
  var trackNumber: Int? = nil
  var trackCount: Int? = nil
  var discNumber: Int? = nil
  var discCount: Int? = nil
  var comment: String? = nil
  var lyrics: String? = nil
  var compilation: Bool? = nil
  var genreOperation: GenreMetadataOperation? = nil

  init() {}

  init(differenceFrom baseline: TrackMetadata, to edited: TrackMetadata) {
    self.init()
    let baseline = baseline.normalized
    let edited = edited.normalized

    for field in MetadataField.stringFields
    where baseline[keyPath: field.value] != edited[keyPath: field.value] {
      self[keyPath: field.change] = edited[keyPath: field.value]
    }
    for field in MetadataField.numberFields
    where baseline[keyPath: field.value] != edited[keyPath: field.value] {
      self[keyPath: field.change] = edited[keyPath: field.value]
    }
    for field in MetadataField.boolFields
    where baseline[keyPath: field.value] != edited[keyPath: field.value] {
      self[keyPath: field.change] = edited[keyPath: field.value]
    }
  }

  var isEmpty: Bool {
    MetadataField.stringFields.allSatisfy { self[keyPath: $0.change] == nil }
      && MetadataField.numberFields.allSatisfy { self[keyPath: $0.change] == nil }
      && MetadataField.boolFields.allSatisfy { self[keyPath: $0.change] == nil }
      && genreOperation == nil
  }

  func applying(to metadata: TrackMetadata) -> TrackMetadata {
    var result = metadata
    func apply<Value>(_ fields: [MetadataField.Descriptor<Value>]) {
      for field in fields {
        if let value = self[keyPath: field.change] {
          result[keyPath: field.value] = value
        }
      }
    }
    apply(MetadataField.stringFields)
    apply(MetadataField.numberFields)
    apply(MetadataField.boolFields)
    if let genreOperation {
      result.genres = genreOperation.applying(to: result.genres)
    }
    return result.normalized
  }
}

enum GenreMetadataOperation: Equatable, Sendable {
  case add(String)
  case remove(String)
  case makePrimary(String)

  func applying(to genres: [String]) -> [String] {
    switch self {
    case .add(let genre):
      return GenreMetadata.canonicalValues(genres + [genre])
    case .remove(let genre):
      let key = GenreMetadata.normalizedKey(genre)
      return genres.filter { GenreMetadata.normalizedKey($0) != key }
    case .makePrimary(let genre):
      let key = GenreMetadata.normalizedKey(genre)
      let existing = genres.first { GenreMetadata.normalizedKey($0) == key } ?? genre
      return GenreMetadata.canonicalValues(
        [existing] + genres.filter { GenreMetadata.normalizedKey($0) != key })
    }
  }
}

enum MetadataField: CaseIterable, Hashable, Sendable {
  case title, artist, album, albumArtist, composer, genre, grouping
  case year, bpm, trackNumber, trackCount, discNumber, discCount
  case comment, lyrics, compilation

  /// Pairs a field with its value key path and optional change key path.
  /// Unchecked only because `WritableKeyPath` is not `Sendable`; every stored
  /// descriptor is an immutable literal in the tables below.
  struct Descriptor<Value: Equatable & Sendable>: @unchecked Sendable {
    let field: MetadataField
    let value: WritableKeyPath<TrackMetadata, Value>
    let change: WritableKeyPath<TrackMetadataChanges, Value?>
  }

  static let stringFields: [Descriptor<String>] = [
    .init(field: .title, value: \.title, change: \.title),
    .init(field: .artist, value: \.artist, change: \.artist),
    .init(field: .album, value: \.album, change: \.album),
    .init(field: .albumArtist, value: \.albumArtist, change: \.albumArtist),
    .init(field: .composer, value: \.composer, change: \.composer),
    .init(field: .genre, value: \.genre, change: \.genre),
    .init(field: .grouping, value: \.grouping, change: \.grouping),
    .init(field: .comment, value: \.comment, change: \.comment),
    .init(field: .lyrics, value: \.lyrics, change: \.lyrics),
  ]

  static let numberFields: [Descriptor<Int>] = [
    .init(field: .year, value: \.year, change: \.year),
    .init(field: .bpm, value: \.bpm, change: \.bpm),
    .init(field: .trackNumber, value: \.trackNumber, change: \.trackNumber),
    .init(field: .trackCount, value: \.trackCount, change: \.trackCount),
    .init(field: .discNumber, value: \.discNumber, change: \.discNumber),
    .init(field: .discCount, value: \.discCount, change: \.discCount),
  ]

  static let boolFields: [Descriptor<Bool>] = [
    .init(field: .compilation, value: \.compilation, change: \.compilation)
  ]
}

enum ArtworkChange: Sendable {
  case unchanged
  case replace(Data)
  case remove
}

enum TrackFileMetadataWriter {
  static func write(
    _ metadata: TrackMetadata,
    artworkChange: ArtworkChange = .unchanged,
    mediaKindChange: LibraryMediaKind? = nil,
    to url: URL,
    expectedGeneration: FileGenerationStamp? = nil
  ) throws {
    switch LibraryAudioFormat(url: url) {
    case .mp3:
      // MP3 has no dedicated media-kind field; the audiobook mark travels in
      // the genre list, which callers set on `metadata` directly.
      try MP3MetadataWriter.write(
        metadata, artworkChange: artworkChange, to: url,
        expectedGeneration: expectedGeneration)
    case .m4a, .m4b:
      try MP4MetadataWriter.write(
        metadata, artworkChange: artworkChange, mediaKindChange: mediaKindChange, to: url,
        expectedGeneration: expectedGeneration)
    default:
      throw LibraryStoreError.metadataEditingUnsupported(url.pathExtension.uppercased())
    }
  }
}

enum MP3MetadataError: Error, LocalizedError, Equatable {
  case notMP3
  case malformedTag
  case tagTooLarge
  case fileChanged

  var errorDescription: String? {
    switch self {
    case .notMP3:
      return String(localized: "The selected file is not an MP3.")
    case .malformedTag:
      return String(localized: "The MP3 has a malformed ID3 tag and was not changed.")
    case .tagTooLarge:
      return String(
        localized:
          "The artwork or metadata is too large for this MP3's ID3 tag and was not changed.")
    case .fileChanged:
      return String(
        localized: "The MP3 changed on disk while it was being edited and was not changed.")
    }
  }
}

enum MP3MetadataWriter {
  private static let maximumV22FrameSize = 0x00FF_FFFF
  private static let maximumSynchsafeSize = 0x0FFF_FFFF

  struct Frame: Equatable {
    var id: String
    var payload: Data
    var flags: UInt16 = 0
  }

  private static let replacedFrameIDs: Set<String> = [
    "TIT2", "TPE1", "TALB", "TPE2", "TCOM", "TCON", "TDRC", "TYER", "TRCK", "TPOS",
    "TIT1", "TBPM", "TCMP", "TDAT", "TIME", "TDRL",
  ]
  private static let replacedV22FrameIDs: Set<String> = [
    "TT2", "TP1", "TAL", "TP2", "TCM", "TCO", "TYE", "TRK", "TPA", "TT1", "TBP",
    "TCP", "TDA", "TIM",
  ]

  static func write(
    _ metadata: TrackMetadata,
    artworkChange: ArtworkChange = .unchanged,
    to url: URL,
    expectedGeneration: FileGenerationStamp? = nil
  ) throws {
    guard url.pathExtension.lowercased() == "mp3" else { throw MP3MetadataError.notMP3 }
    let original = try Data(contentsOf: url, options: .mappedIfSafe)
    let parsed = try parseTag(in: original)
    let version = parsed.version
    let replacedIDs = version == 2 ? replacedV22FrameIDs : replacedFrameIDs
    var frames = parsed.frames.filter {
      !replacedIDs.contains($0.id) && !isCanonicalLanguageTextFrame($0, version: version)
        && !MusicBrainzID3.isManagedFrame($0)
    }
    switch artworkChange {
    case .unchanged:
      break
    case .replace, .remove:
      frames.removeAll { $0.id == (version == 2 ? "PIC" : "APIC") }
    }
    frames.append(contentsOf: metadataFrames(metadata.normalized, version: version))
    if case .replace(let data) = artworkChange {
      try validateArtworkSize(data, version: version)
      frames.append(artworkFrame(data, version: version))
    }
    let replacement = try serialize(frames: frames, version: version)

    try replaceTag(
      contentsOf: url,
      with: replacement,
      audioOffset: parsed.audioOffset,
      originalSize: original.count,
      expectedAudioPrefix: original.subdata(
        in: parsed.audioOffset..<min(parsed.audioOffset + 16, original.count)),
      expectedGeneration: expectedGeneration)
  }

  static func replaceTag(
    contentsOf url: URL,
    with replacement: Data,
    audioOffset: Int,
    originalSize: Int,
    expectedAudioPrefix: Data,
    expectedGeneration: FileGenerationStamp? = nil
  ) throws {
    try AtomicFileRewriter.rewrite(
      contentsOf: url, expectedGeneration: expectedGeneration,
      fileChangedError: MP3MetadataError.fileChanged
    ) { input, output in
      let currentSize = try input.seekToEnd()
      guard currentSize == UInt64(originalSize) else { throw MP3MetadataError.fileChanged }
      try input.seek(toOffset: UInt64(audioOffset))
      let prefixOnDisk = try input.read(upToCount: expectedAudioPrefix.count) ?? Data()
      guard prefixOnDisk == expectedAudioPrefix else { throw MP3MetadataError.fileChanged }
      try input.seek(toOffset: UInt64(audioOffset))
      try output.write(contentsOf: replacement)
      try AtomicFileRewriter.copyRemaining(from: input, to: output)
    }
  }

  static func frames(in data: Data) throws -> [Frame] {
    try parseTag(in: data).frames
  }

  private static func parseTag(in data: Data) throws -> (
    version: Int, frames: [Frame], audioOffset: Int
  ) {
    guard data.count >= 10, String(data: data[0..<3], encoding: .ascii) == "ID3" else {
      return (3, [], 0)
    }
    let version = Int(data[3])
    guard (2...4).contains(version) else { throw MP3MetadataError.malformedTag }
    let tagSize = try synchsafe(data, at: 6)
    let end = 10 + tagSize
    let footerSize = version == 4 && data[5] & 0x10 != 0 ? 10 : 0
    guard end + footerSize <= data.count else { throw MP3MetadataError.malformedTag }

    var body = Data(data[10..<end])
    let flags = data[5]
    let tagUnsynchronized = flags & 0x80 != 0
    if version < 4, tagUnsynchronized { body = removeUnsynchronization(body) }

    var offset = 0
    if version == 2, flags & 0x40 != 0 {
      throw MP3MetadataError.malformedTag
    }
    if version >= 3, flags & 0x40 != 0 {
      guard body.count >= 4 else { throw MP3MetadataError.malformedTag }
      let size = version == 4 ? try synchsafe(body, at: 0) : int32(body, at: 0)
      let total = version == 4 ? size : size + 4
      guard total >= 4, total <= body.count else { throw MP3MetadataError.malformedTag }
      offset = total
    }

    var frames: [Frame] = []
    while offset < body.count {
      if body[offset] == 0 { break }
      if version == 2 {
        guard offset + 6 <= body.count else { throw MP3MetadataError.malformedTag }
        let id = String(data: body[offset..<(offset + 3)], encoding: .ascii) ?? ""
        guard validFrameID(id, length: 3) else { throw MP3MetadataError.malformedTag }
        let size =
          Int(body[offset + 3]) << 16 | Int(body[offset + 4]) << 8 | Int(body[offset + 5])
        let payloadStart = offset + 6
        guard size >= 0, payloadStart + size <= body.count else {
          throw MP3MetadataError.malformedTag
        }
        frames.append(
          Frame(id: id, payload: Data(body[payloadStart..<(payloadStart + size)])))
        offset = payloadStart + size
      } else {
        guard offset + 10 <= body.count else { throw MP3MetadataError.malformedTag }
        let id = String(data: body[offset..<(offset + 4)], encoding: .ascii) ?? ""
        guard validFrameID(id, length: 4) else { throw MP3MetadataError.malformedTag }
        let size = version == 4 ? try synchsafe(body, at: offset + 4) : int32(body, at: offset + 4)
        let payloadStart = offset + 10
        guard size >= 0, payloadStart + size <= body.count else {
          throw MP3MetadataError.malformedTag
        }
        var frameFlags = UInt16(body[offset + 8]) << 8 | UInt16(body[offset + 9])
        var payload = Data(body[payloadStart..<(payloadStart + size)])
        if version == 4, tagUnsynchronized || frameFlags & 0x2 != 0 {
          if frameFlags & 0xD != 0 {
            frameFlags |= 0x2
          } else {
            payload = removeUnsynchronization(payload)
            frameFlags &= ~UInt16(0x2)
          }
        }
        frames.append(Frame(id: id, payload: payload, flags: frameFlags))
        offset = payloadStart + size
      }
    }
    return (version, frames, end + footerSize)
  }

  private static func metadataFrames(_ metadata: TrackMetadata, version: Int) -> [Frame] {
    var frames: [Frame] = []
    func text(_ id: String, v22ID: String, _ value: String) {
      guard !value.isEmpty else { return }
      frames.append(Frame(id: version == 2 ? v22ID : id, payload: encodedText(value)))
    }
    text("TIT2", v22ID: "TT2", metadata.title)
    text("TPE1", v22ID: "TP1", metadata.artist)
    text("TALB", v22ID: "TAL", metadata.album)
    text("TPE2", v22ID: "TP2", metadata.albumArtist)
    text("TCOM", v22ID: "TCM", metadata.composer)
    text("TCON", v22ID: "TCO", metadata.genre)
    text("TIT1", v22ID: "TT1", metadata.grouping)
    if metadata.bpm > 0 {
      text("TBPM", v22ID: "TBP", String(metadata.bpm))
    }
    if metadata.year > 0 {
      text(version == 4 ? "TDRC" : "TYER", v22ID: "TYE", String(metadata.year))
    }
    if let releaseDate = metadata.releaseDate {
      if version == 4 {
        text("TDRL", v22ID: "TDA", ID3ReleaseDate.timestampString(releaseDate))
      } else {
        text("TDAT", v22ID: "TDA", ID3ReleaseDate.dayMonthString(releaseDate))
        text("TIME", v22ID: "TIM", ID3ReleaseDate.hourMinuteString(releaseDate))
      }
    }
    if metadata.trackNumber > 0 || metadata.trackCount > 0 {
      text("TRCK", v22ID: "TRK", pair(metadata.trackNumber, metadata.trackCount))
    }
    if metadata.discNumber > 0 || metadata.discCount > 0 {
      text("TPOS", v22ID: "TPA", pair(metadata.discNumber, metadata.discCount))
    }
    if !metadata.comment.isEmpty {
      let payload = encodedLanguageText(metadata.comment)
      frames.append(Frame(id: version == 2 ? "COM" : "COMM", payload: payload))
    }
    if !metadata.lyrics.isEmpty {
      let payload = encodedLanguageText(metadata.lyrics)
      frames.append(Frame(id: version == 2 ? "ULT" : "USLT", payload: payload))
    }
    if metadata.compilation { text("TCMP", v22ID: "TCP", "1") }
    frames.append(contentsOf: MusicBrainzID3.frames(for: metadata, version: version))
    return frames
  }

  private static func isCanonicalLanguageTextFrame(_ frame: Frame, version: Int) -> Bool {
    let hasExpectedID =
      version == 2
      ? frame.id == "COM" || frame.id == "ULT"
      : frame.id == "COMM" || frame.id == "USLT"
    guard hasExpectedID, !hasNonPlainPayload(frame, version: version) else {
      return false
    }

    let payload = frame.payload
    guard payload.count >= 5,
      payload[1] == UInt8(ascii: "e"),
      payload[2] == UInt8(ascii: "n"),
      payload[3] == UInt8(ascii: "g")
    else { return false }

    switch payload[0] {
    case 0:  // ISO-8859-1
      return payload[4] == 0
    case 1:  // UTF-16 with a byte-order mark
      guard payload.count >= 8 else { return false }
      let hasByteOrderMark =
        (payload[4] == 0xFF && payload[5] == 0xFE)
        || (payload[4] == 0xFE && payload[5] == 0xFF)
      return hasByteOrderMark && payload[6] == 0 && payload[7] == 0
    case 2 where version == 4:  // UTF-16BE without a byte-order mark
      return payload.count >= 6 && payload[4] == 0 && payload[5] == 0
    case 3 where version == 4:  // UTF-8
      return payload[4] == 0
    default:
      return false
    }
  }

  private static func hasNonPlainPayload(_ frame: Frame, version: Int) -> Bool {
    switch version {
    case 3:
      return frame.flags & 0x1FFF != 0
    case 4:
      return frame.flags & 0x8FFF != 0
    default:
      return false
    }
  }

  private static func serialize(frames: [Frame], version: Int) throws -> Data {
    let idLength = version == 2 ? 3 : 4
    let serializableFrames = frames.filter { validFrameID($0.id, length: idLength) }
    let frameHeaderSize = version == 2 ? 6 : 10
    let maximumFrameSize =
      version == 2
      ? maximumV22FrameSize
      : (version == 4 ? maximumSynchsafeSize : Int(UInt32.max))
    var bodySize = 0
    for frame in serializableFrames {
      guard frame.payload.count <= maximumFrameSize else {
        throw MP3MetadataError.tagTooLarge
      }
      let (framedSize, frameOverflow) = frameHeaderSize.addingReportingOverflow(
        frame.payload.count)
      let (nextBodySize, bodyOverflow) = bodySize.addingReportingOverflow(framedSize)
      guard !frameOverflow, !bodyOverflow, nextBodySize <= maximumSynchsafeSize else {
        throw MP3MetadataError.tagTooLarge
      }
      bodySize = nextBodySize
    }

    var body = Data()
    body.reserveCapacity(bodySize)
    for frame in serializableFrames {
      body.append(Data(frame.id.utf8))
      if version == 2 {
        body.append(contentsOf: [
          UInt8((frame.payload.count >> 16) & 0xFF),
          UInt8((frame.payload.count >> 8) & 0xFF),
          UInt8(frame.payload.count & 0xFF),
        ])
      } else if version == 4 {
        body.append(contentsOf: synchsafeBytes(frame.payload.count))
      } else {
        var size = UInt32(frame.payload.count).bigEndian
        withUnsafeBytes(of: &size) { body.append(contentsOf: $0) }
      }
      if version != 2 {
        var flags = frame.flags.bigEndian
        withUnsafeBytes(of: &flags) { body.append(contentsOf: $0) }
      }
      body.append(frame.payload)
    }
    var tag = Data("ID3".utf8)
    tag.append(UInt8(version))
    tag.append(contentsOf: [0x00, 0x00])
    tag.append(contentsOf: synchsafeBytes(body.count))
    tag.append(body)
    return tag
  }

  private static func validateArtworkSize(_ data: Data, version: Int) throws {
    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    let overhead = version == 2 ? 6 : (isPNG ? 13 : 14)
    let limit =
      version == 2
      ? maximumV22FrameSize
      : (version == 4 ? maximumSynchsafeSize : Int(UInt32.max))
    guard data.count <= limit - overhead else { throw MP3MetadataError.tagTooLarge }
  }

  private static func encodedText(_ value: String) -> Data {
    var data = Data([0x01, 0xFF, 0xFE])
    data.append(utf16LE(value))
    return data
  }

  private static func encodedLanguageText(_ value: String) -> Data {
    var payload = Data([0x01])
    payload.append(Data("eng".utf8))
    payload.append(contentsOf: [0xFF, 0xFE, 0x00, 0x00])
    payload.append(utf16LE(value))
    return payload
  }

  private static func artworkFrame(_ data: Data, version: Int) -> Frame {
    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    var payload = Data([0])
    if version == 2 {
      payload.append(Data(isPNG ? "PNG".utf8 : "JPG".utf8))
    } else {
      payload.append(Data(isPNG ? "image/png".utf8 : "image/jpeg".utf8))
      payload.append(0)
    }
    payload.append(3)
    payload.append(0)
    payload.append(data)
    return Frame(id: version == 2 ? "PIC" : "APIC", payload: payload)
  }

  private static func utf16LE(_ value: String) -> Data {
    var data = Data()
    for unit in value.utf16 {
      data.append(UInt8(unit & 0xFF))
      data.append(UInt8(unit >> 8))
    }
    return data
  }

  private static func pair(_ number: Int, _ total: Int) -> String {
    total > 0 ? "\(number)/\(total)" : String(number)
  }

  private static func validFrameID(_ id: String, length: Int) -> Bool {
    guard id.utf8.count == length else { return false }
    return id.utf8.allSatisfy {
      ($0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z"))
        || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
    }
  }

  private static func int32(_ data: Data, at offset: Int) -> Int {
    guard offset + 4 <= data.count else { return -1 }
    return Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
      | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
  }

  private static func synchsafe(_ data: Data, at offset: Int) throws -> Int {
    guard offset + 4 <= data.count else { throw MP3MetadataError.malformedTag }
    let bytes = data[offset..<(offset + 4)]
    guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { throw MP3MetadataError.malformedTag }
    return bytes.reduce(0) { ($0 << 7) | Int($1) }
  }

  private static func synchsafeBytes(_ value: Int) -> [UInt8] {
    [
      UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
      UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
    ]
  }

  private static func removeUnsynchronization(_ data: Data) -> Data {
    var output = Data()
    var offset = 0
    while offset < data.count {
      output.append(data[offset])
      if data[offset] == 0xFF, offset + 1 < data.count, data[offset + 1] == 0x00 {
        offset += 1
      }
      offset += 1
    }
    return output
  }

}

/// Formats and parses the tag fields that carry a full release
/// (publication) date: a TDRL timestamp in ID3v2.4 tags, TYER + TDAT +
/// TIME in ID3v2.3/v2.2 tags, and an ISO-8601 `©day` string in MP4 files.
/// ID3v2.3 stores the time of day only to the minute, so dates round-trip
/// at minute granularity there.
enum ID3ReleaseDate {
  private static var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
    return calendar
  }

  static func timestampString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  /// The ID3v2.3 TDAT payload: "DDMM".
  static func dayMonthString(_ date: Date) -> String {
    let c = utcCalendar.dateComponents([.day, .month], from: date)
    return String(format: "%02d%02d", c.day ?? 0, c.month ?? 0)
  }

  /// The ID3v2.3 TIME payload: "HHMM".
  static func hourMinuteString(_ date: Date) -> String {
    let c = utcCalendar.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d%02d", c.hour ?? 0, c.minute ?? 0)
  }

  /// Parses ISO-8601 timestamps plus the partial yyyy-MM and yyyy-MM-dd
  /// forms used by ID3 and MP4 tags. A bare year keeps flowing through the
  /// `year` field instead.
  static func parseTimestamp(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("T") || trimmed.contains(" ") {
      var timestamp = trimmed.replacingOccurrences(of: " ", with: "T")
      let time = timestamp.split(separator: "T", maxSplits: 1).last ?? ""
      if time.last != "Z", !time.dropFirst().contains("+"), !time.dropFirst().contains("-") {
        timestamp += "Z"
      }
      let formatter = ISO8601DateFormatter()
      for options: ISO8601DateFormatter.Options in [
        [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
      ] {
        formatter.formatOptions = options
        if let date = formatter.date(from: timestamp) { return date }
      }
      return nil
    }
    let fields = trimmed.split(separator: "-", omittingEmptySubsequences: false)
    guard (2...3).contains(fields.count), let year = Int(fields[0]), year > 0,
      let month = Int(fields[1]), (1...12).contains(month),
      fields.count == 2 || Int(fields[2]) != nil
    else { return nil }
    var components = DateComponents(year: year, month: month, day: 1)
    if fields.count == 3 { components.day = Int(fields[2]) }
    return utcCalendar.date(from: components)
  }

  static func read(fromMP3At url: URL) -> Date? {
    guard url.pathExtension.lowercased() == "mp3",
      let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    else { return nil }
    return read(fromTagIn: data)
  }

  static func read(fromTagIn data: Data) -> Date? {
    guard let frames = try? MP3MetadataWriter.frames(in: data) else { return nil }
    var year: Int?
    var dayMonth: (day: Int, month: Int)?
    var hourMinute: (hour: Int, minute: Int)?
    var releaseTimestamp: Date?
    var recordingTimestamp: Date?
    for frame in frames {
      guard let text = decodedText(frame.payload) else { continue }
      switch frame.id {
      case "TDRL":
        releaseTimestamp = releaseTimestamp ?? parseTimestamp(text)
      case "TDRC":
        recordingTimestamp = recordingTimestamp ?? parseTimestamp(text)
      case "TYER", "TYE":
        year = year ?? Int(text.prefix(4))
      case "TDAT", "TDA":
        dayMonth = dayMonth ?? digitPair(text).map { (day: $0.0, month: $0.1) }
      case "TIME", "TIM":
        hourMinute = hourMinute ?? digitPair(text).map { (hour: $0.0, minute: $0.1) }
      default:
        break
      }
    }
    if let releaseTimestamp { return releaseTimestamp }
    if let year, year > 0, let dayMonth,
      (1...12).contains(dayMonth.month), (1...31).contains(dayMonth.day)
    {
      var components = DateComponents()
      components.year = year
      components.month = dayMonth.month
      components.day = dayMonth.day
      components.hour = hourMinute?.hour ?? 0
      components.minute = hourMinute?.minute ?? 0
      if let date = utcCalendar.date(from: components) { return date }
    }
    return recordingTimestamp
  }

  /// Splits a four-digit payload like TDAT's "DDMM" or TIME's "HHMM".
  private static func digitPair(_ text: String) -> (Int, Int)? {
    let digits = text.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }
    guard digits.count == 4,
      let first = Int(String(String.UnicodeScalarView(digits.prefix(2)))),
      let second = Int(String(String.UnicodeScalarView(digits.suffix(2))))
    else { return nil }
    return (first, second)
  }

  private static func decodedText(_ payload: Data) -> String? {
    guard let encoding = payload.first else { return nil }
    let body = Data(payload.dropFirst())
    let text: String?
    switch encoding {
    case 0: text = String(data: body, encoding: .isoLatin1)
    case 1: text = String(data: body, encoding: .utf16)
    case 2: text = String(data: body, encoding: .utf16BigEndian)
    case 3: text = String(data: body, encoding: .utf8)
    default: text = nil
    }
    return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
  }
}
