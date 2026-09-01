import Foundation

enum MP4MetadataError: Error, LocalizedError, Equatable {
  case notMP4
  case malformedContainer
  case tagTooLarge
  case fileChanged

  var errorDescription: String? {
    switch self {
    case .notMP4:
      return String(localized: "The selected file is not an MPEG-4 audio file.")
    case .malformedContainer:
      return String(localized: "The MPEG-4 container is malformed and was not changed.")
    case .tagTooLarge:
      return String(
        localized: "The artwork or metadata is too large for this file and it was not changed.")
    case .fileChanged:
      return String(
        localized: "The MPEG-4 file changed on disk while it was being edited and was not changed.")
    }
  }
}

enum MP4MetadataWriter {

  struct Entry: Equatable {
    let type: String
    let bytes: Data
  }

  private static let replacedTypes: Set<String> = [
    "\u{00A9}nam", "\u{00A9}ART", "\u{00A9}alb", "aART", "\u{00A9}wrt",
    "\u{00A9}gen", "gnre", "\u{00A9}grp", "\u{00A9}day", "tmpo", "trkn",
    "disk", "\u{00A9}cmt", "\u{00A9}lyr", "cpil",
  ]
  private static let coverType = "covr"
  private static let mediaKindType = "stik"

  /// iTunes-style media kind values for the `stik` atom.
  private static func stikValue(for kind: LibraryMediaKind) -> UInt8 {
    switch kind {
    case .song: 1
    case .audiobook: 2
    case .podcast: 10
    }
  }

  static func write(
    _ metadata: TrackMetadata,
    artworkChange: ArtworkChange = .unchanged,
    mediaKindChange: LibraryMediaKind? = nil,
    to url: URL,
    expectedGeneration: FileGenerationStamp? = nil
  ) throws {
    guard let format = LibraryAudioFormat(url: url), format == .m4a || format == .m4b
    else { throw MP4MetadataError.notMP4 }
    let original = try Data(contentsOf: url, options: .mappedIfSafe)

    let topLevel = try boxes(in: original, range: 0..<original.count)
    let moovBoxes = topLevel.filter { $0.type == "moov" }
    guard moovBoxes.count == 1, let moov = moovBoxes.first,
      topLevel.contains(where: { $0.type == "ftyp" })
    else { throw MP4MetadataError.malformedContainer }

    var newMoov = try rebuiltMoov(
      original, moov: moov, metadata: metadata.normalized, artworkChange: artworkChange,
      mediaKindChange: mediaKindChange)
    let delta = newMoov.count - moov.range.count
    if delta != 0 {
      try shiftChunkOffsets(
        in: &newMoov, by: delta, forOffsetsAtOrPast: moov.range.upperBound)
    }

    try replace(
      contentsOf: url, byteRange: moov.range, with: newMoov,
      originalSize: original.count,
      expectedRangePrefix: original.subdata(
        in: moov.range.lowerBound..<min(moov.range.lowerBound + 16, moov.range.upperBound)),
      expectedGeneration: expectedGeneration)
  }

  static func ilstEntries(in fileData: Data) throws -> [Entry] {
    let topLevel = try boxes(in: fileData, range: 0..<fileData.count)
    guard let moov = topLevel.first(where: { $0.type == "moov" }) else { return [] }
    let moovChildren = try boxes(in: fileData, range: moov.payload)
    guard let meta = try preferredMetadata(in: fileData, moovChildren: moovChildren)?.meta
    else { return [] }
    return try ilstEntries(in: fileData, meta: meta)
  }

  private static func ilstEntries(in fileData: Data, meta: RawBox) throws -> [Entry] {
    guard meta.payload.count >= 4 else { return [] }
    let children = try boxes(
      in: fileData, range: (meta.payload.lowerBound + 4)..<meta.payload.upperBound)
    guard let ilst = children.first(where: { $0.type == "ilst" }) else { return [] }
    return try boxes(in: fileData, range: ilst.payload).map {
      Entry(type: $0.type, bytes: Data(fileData[$0.range]))
    }
  }

  // MARK: - Box parsing

  private struct RawBox {
    let type: String
    let range: Range<Int>
    let payload: Range<Int>
  }

  private struct MetadataLocation {
    let meta: RawBox
    let udta: RawBox?
  }

  private enum MetadataKind {
    case iTunes
    case keyed
    case foreign
    case unknown
  }

  private static func boxes(in data: Data, range: Range<Int>) throws -> [RawBox] {
    var result: [RawBox] = []
    var offset = range.lowerBound
    while offset < range.upperBound {
      guard offset + 8 <= range.upperBound else { throw MP4MetadataError.malformedContainer }
      let size32 = Int(u32(data, at: offset))
      guard let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .isoLatin1)
      else { throw MP4MetadataError.malformedContainer }
      var headerSize = 8
      var size = size32
      if size32 == 1 {
        guard offset + 16 <= range.upperBound else { throw MP4MetadataError.malformedContainer }
        let large = u64(data, at: offset + 8)
        guard large <= UInt64(Int.max) else { throw MP4MetadataError.malformedContainer }
        size = Int(large)
        headerSize = 16
      } else if size32 == 0 {
        size = range.upperBound - offset
      }
      guard size >= headerSize, size <= range.upperBound - offset else {
        throw MP4MetadataError.malformedContainer
      }
      result.append(
        RawBox(
          type: type,
          range: offset..<(offset + size),
          payload: (offset + headerSize)..<(offset + size)))
      offset += size
    }
    return result
  }

  private static func preferredMetadata(
    in data: Data, moovChildren: [RawBox]
  ) throws -> MetadataLocation? {
    let direct = moovChildren.filter { $0.type == "meta" }
    var userData: [MetadataLocation] = []
    for udta in moovChildren where udta.type == "udta" {
      for meta in try boxes(in: data, range: udta.payload) where meta.type == "meta" {
        userData.append(MetadataLocation(meta: meta, udta: udta))
      }
    }
    if let location = try userData.first(where: {
      try metadataKind($0.meta, in: data) == .iTunes
    }) {
      return location
    }
    if let meta = try direct.first(where: { try metadataKind($0, in: data) == .iTunes }) {
      return MetadataLocation(meta: meta, udta: nil)
    }
    return try userData.first(where: { try metadataKind($0.meta, in: data) == .unknown })
  }

  private static func metadataKind(_ meta: RawBox, in data: Data) throws -> MetadataKind {
    guard meta.payload.count >= 4 else { throw MP4MetadataError.malformedContainer }
    let children = try boxes(
      in: data, range: (meta.payload.lowerBound + 4)..<meta.payload.upperBound)
    if let handler = children.first(where: { $0.type == "hdlr" }) {
      guard handler.payload.count >= 12 else { throw MP4MetadataError.malformedContainer }
      let typeStart = handler.payload.lowerBound + 8
      let handlerType = String(
        bytes: data[typeStart..<(typeStart + 4)], encoding: .isoLatin1)
      if handlerType == "mdir" { return .iTunes }
      if handlerType == "mdta" { return .keyed }
      return .foreign
    }
    guard let ilst = children.first(where: { $0.type == "ilst" }) else { return .unknown }
    let hasITunesEntry = try boxes(in: data, range: ilst.payload).contains {
      replacedTypes.contains($0.type) || $0.type == coverType
        || $0.type.unicodeScalars.first?.value == 0xA9
    }
    return hasITunesEntry ? .iTunes : .unknown
  }

  // MARK: - moov reconstruction

  private static func rebuiltMoov(
    _ data: Data, moov: RawBox, metadata: TrackMetadata, artworkChange: ArtworkChange,
    mediaKindChange: LibraryMediaKind?
  ) throws -> Data {
    let children = try boxes(in: data, range: moov.payload)
    let location = try preferredMetadata(in: data, moovChildren: children)
    let targetMetaStart = location?.udta == nil ? location?.meta.range.lowerBound : nil
    let targetUdtaStart =
      location?.udta?.range.lowerBound
      ?? (location == nil ? children.first(where: { $0.type == "udta" })?.range.lowerBound : nil)
    var payload = Data()
    var rebuiltMetadata = false
    for child in children {
      if child.range.lowerBound == targetMetaStart {
        payload.append(
          try rebuiltMeta(
            data, meta: child, metadata: metadata, artworkChange: artworkChange,
            mediaKindChange: mediaKindChange))
        rebuiltMetadata = true
      } else if child.range.lowerBound == targetUdtaStart {
        payload.append(
          try rebuiltUdta(
            data, udta: child, targetMetaStart: location?.meta.range.lowerBound,
            metadata: metadata, artworkChange: artworkChange,
            mediaKindChange: mediaKindChange))
        rebuiltMetadata = true
      } else {
        payload.append(data[child.range])
      }
    }
    if !rebuiltMetadata {
      let meta = try builtMeta(
        existingPayloadPrefix: nil, preservedChildren: Data(),
        ilst: try ilstPayload(
          existingEntries: [], metadata: metadata, artworkChange: artworkChange,
          mediaKindChange: mediaKindChange))
      payload.append(try box("udta", payload: meta))
    }
    return try box("moov", payload: payload)
  }

  private static func rebuiltUdta(
    _ data: Data, udta: RawBox, targetMetaStart: Int?, metadata: TrackMetadata,
    artworkChange: ArtworkChange, mediaKindChange: LibraryMediaKind?
  ) throws -> Data {
    var payload = Data()
    var replacedMeta = false
    for child in try boxes(in: data, range: udta.payload) {
      if child.range.lowerBound == targetMetaStart {
        payload.append(
          try rebuiltMeta(
            data, meta: child, metadata: metadata, artworkChange: artworkChange,
            mediaKindChange: mediaKindChange))
        replacedMeta = true
      } else {
        payload.append(data[child.range])
      }
    }
    if !replacedMeta {
      payload.append(
        try builtMeta(
          existingPayloadPrefix: nil, preservedChildren: Data(),
          ilst: try ilstPayload(
            existingEntries: [], metadata: metadata, artworkChange: artworkChange,
            mediaKindChange: mediaKindChange)))
    }
    return try box("udta", payload: payload)
  }

  private static func rebuiltMeta(
    _ data: Data, meta: RawBox, metadata: TrackMetadata, artworkChange: ArtworkChange,
    mediaKindChange: LibraryMediaKind?
  ) throws -> Data {
    guard meta.payload.count >= 4 else { throw MP4MetadataError.malformedContainer }
    let versionAndFlags = Data(
      data[meta.payload.lowerBound..<(meta.payload.lowerBound + 4)])
    let children = try boxes(
      in: data, range: (meta.payload.lowerBound + 4)..<meta.payload.upperBound)
    var preserved = Data()
    var existingEntries: [RawBox] = []
    var sawIlst = false
    for child in children {
      if child.type == "ilst" && !sawIlst {
        existingEntries = try boxes(in: data, range: child.payload)
        sawIlst = true
      } else {
        preserved.append(data[child.range])
      }
    }
    let ilst = try ilstPayload(
      existingEntries: existingEntries.map { (type: $0.type, bytes: Data(data[$0.range])) },
      metadata: metadata, artworkChange: artworkChange, mediaKindChange: mediaKindChange)
    return try builtMeta(
      existingPayloadPrefix: versionAndFlags, preservedChildren: preserved, ilst: ilst)
  }

  private static func builtMeta(
    existingPayloadPrefix: Data?, preservedChildren: Data, ilst: Data
  ) throws -> Data {
    var payload = existingPayloadPrefix ?? Data([0, 0, 0, 0])
    if existingPayloadPrefix == nil {
      var handler = Data()
      handler.append(contentsOf: [0, 0, 0, 0])  // version and flags
      handler.append(contentsOf: [0, 0, 0, 0])  // predefined
      handler.append(Data("mdir".utf8))
      handler.append(Data("appl".utf8))
      handler.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0])
      payload.append(try box("hdlr", payload: handler))
    }
    payload.append(preservedChildren)
    payload.append(try box("ilst", payload: ilst))
    return try box("meta", payload: payload)
  }

  // MARK: - ilst construction

  private static func ilstPayload(
    existingEntries: [(type: String, bytes: Data)],
    metadata: TrackMetadata,
    artworkChange: ArtworkChange,
    mediaKindChange: LibraryMediaKind?
  ) throws -> Data {
    var payload = Data()
    for entry in existingEntries {
      if replacedTypes.contains(entry.type) { continue }
      if entry.type == mediaKindType, mediaKindChange != nil { continue }
      if entry.type == coverType {
        switch artworkChange {
        case .unchanged: break
        case .replace, .remove: continue
        }
      }
      payload.append(entry.bytes)
    }

    func text(_ type: String, _ value: String) throws {
      guard !value.isEmpty else { return }
      payload.append(try entry(type, dataIndicator: 1, dataPayload: Data(value.utf8)))
    }
    try text("\u{00A9}nam", metadata.title)
    try text("\u{00A9}ART", metadata.artist)
    try text("\u{00A9}alb", metadata.album)
    try text("aART", metadata.albumArtist)
    try text("\u{00A9}wrt", metadata.composer)
    try text("\u{00A9}gen", metadata.genre)
    try text("\u{00A9}grp", metadata.grouping)
    try text("\u{00A9}cmt", metadata.comment)
    try text("\u{00A9}lyr", metadata.lyrics)
    if let releaseDate = metadata.releaseDate {
      try text("\u{00A9}day", ID3ReleaseDate.timestampString(releaseDate))
    } else if metadata.year > 0 {
      try text("\u{00A9}day", String(metadata.year))
    }
    if metadata.bpm > 0 {
      let bpm = UInt16(clamping: metadata.bpm)
      payload.append(
        try entry(
          "tmpo", dataIndicator: 21,
          dataPayload: Data([UInt8(bpm >> 8), UInt8(bpm & 0xFF)])))
    }
    if metadata.trackNumber > 0 || metadata.trackCount > 0 {
      payload.append(
        try entry(
          "trkn", dataIndicator: 0,
          dataPayload: numberPair(metadata.trackNumber, metadata.trackCount) + Data([0, 0])))
    }
    if metadata.discNumber > 0 || metadata.discCount > 0 {
      payload.append(
        try entry(
          "disk", dataIndicator: 0,
          dataPayload: numberPair(metadata.discNumber, metadata.discCount)))
    }
    if metadata.compilation {
      payload.append(try entry("cpil", dataIndicator: 21, dataPayload: Data([1])))
    }
    if let mediaKindChange {
      payload.append(
        try entry(
          mediaKindType, dataIndicator: 21,
          dataPayload: Data([stikValue(for: mediaKindChange)])))
    }
    if case .replace(let artwork) = artworkChange {
      let isPNG = artwork.starts(with: [0x89, 0x50, 0x4E, 0x47])
      payload.append(
        try entry(coverType, dataIndicator: isPNG ? 14 : 13, dataPayload: artwork))
    }
    return payload
  }

  private static func entry(
    _ type: String, dataIndicator: UInt32, dataPayload: Data
  ) throws -> Data {
    var dataAtom = Data()
    dataAtom.append(u32Bytes(dataIndicator))
    dataAtom.append(u32Bytes(0))
    dataAtom.append(dataPayload)
    return try box(type, payload: try box("data", payload: dataAtom))
  }

  private static func numberPair(_ index: Int, _ total: Int) -> Data {
    let index = UInt16(clamping: index)
    let total = UInt16(clamping: total)
    return Data([
      0, 0,
      UInt8(index >> 8), UInt8(index & 0xFF),
      UInt8(total >> 8), UInt8(total & 0xFF),
    ])
  }

  private static func box(_ type: String, payload: Data) throws -> Data {
    guard let typeBytes = type.data(using: .isoLatin1), typeBytes.count == 4 else {
      throw MP4MetadataError.malformedContainer
    }
    let size = payload.count + 8
    guard size <= Int(UInt32.max) else { throw MP4MetadataError.tagTooLarge }
    var out = Data()
    out.append(u32Bytes(UInt32(size)))
    out.append(typeBytes)
    out.append(payload)
    return out
  }

  // MARK: - Chunk-offset patching

  private static let sampleTablePath: Set<String> = ["trak", "mdia", "minf", "stbl"]

  private static func shiftChunkOffsets(
    in moov: inout Data, by delta: Int, forOffsetsAtOrPast threshold: Int
  ) throws {
    guard moov.count >= 8 else { throw MP4MetadataError.malformedContainer }
    try shiftChunkOffsets(
      in: &moov, range: 8..<moov.count, by: delta, threshold: threshold)
  }

  private static func shiftChunkOffsets(
    in moov: inout Data, range: Range<Int>, by delta: Int, threshold: Int
  ) throws {
    for child in try boxes(in: moov, range: range) {
      if sampleTablePath.contains(child.type) {
        try shiftChunkOffsets(in: &moov, range: child.payload, by: delta, threshold: threshold)
      } else if child.type == "stco" || child.type == "co64" {
        guard child.payload.count >= 8 else { throw MP4MetadataError.malformedContainer }
        let count = Int(u32(moov, at: child.payload.lowerBound + 4))
        let entrySize = child.type == "stco" ? 4 : 8
        let entriesStart = child.payload.lowerBound + 8
        guard entriesStart + count * entrySize <= child.payload.upperBound else {
          throw MP4MetadataError.malformedContainer
        }
        for index in 0..<count {
          let position = entriesStart + index * entrySize
          if child.type == "stco" {
            let offset = Int(u32(moov, at: position))
            guard offset >= threshold else { continue }
            let shifted = offset + delta
            guard shifted >= 0, shifted <= Int(UInt32.max) else {
              throw MP4MetadataError.tagTooLarge
            }
            replaceU32(&moov, at: position, with: UInt32(shifted))
          } else {
            let offset = u64(moov, at: position)
            guard offset >= UInt64(threshold) else { continue }
            let shifted = Int64(bitPattern: offset) + Int64(delta)
            guard shifted >= 0 else { throw MP4MetadataError.malformedContainer }
            replaceU64(&moov, at: position, with: UInt64(shifted))
          }
        }
      }
    }
  }

  // MARK: - File replacement

  static func replace(
    contentsOf url: URL, byteRange: Range<Int>, with replacement: Data,
    originalSize: Int, expectedRangePrefix: Data,
    expectedGeneration: FileGenerationStamp? = nil
  ) throws {
    try AtomicFileRewriter.rewrite(
      contentsOf: url, expectedGeneration: expectedGeneration,
      fileChangedError: MP4MetadataError.fileChanged
    ) { input, output in
      let currentSize = try input.seekToEnd()
      guard currentSize == UInt64(originalSize) else {
        throw MP4MetadataError.malformedContainer
      }
      try input.seek(toOffset: UInt64(byteRange.lowerBound))
      let prefixOnDisk = try input.read(upToCount: expectedRangePrefix.count) ?? Data()
      guard prefixOnDisk == expectedRangePrefix else {
        throw MP4MetadataError.malformedContainer
      }
      try input.seek(toOffset: 0)
      try AtomicFileRewriter.copy(
        byteCount: byteRange.lowerBound, from: input, to: output,
        unexpectedEndOfFileError: MP4MetadataError.malformedContainer)
      try output.write(contentsOf: replacement)
      try input.seek(toOffset: UInt64(byteRange.upperBound))
      try AtomicFileRewriter.copyRemaining(from: input, to: output)
    }
  }

  // MARK: - Byte helpers

  private static func u32(_ data: Data, at offset: Int) -> UInt32 {
    let base = data.startIndex + offset
    return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
      | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
  }

  private static func u64(_ data: Data, at offset: Int) -> UInt64 {
    UInt64(u32(data, at: offset)) << 32 | UInt64(u32(data, at: offset + 4))
  }

  private static func u32Bytes(_ value: UInt32) -> Data {
    Data([
      UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ])
  }

  private static func replaceU32(_ data: inout Data, at offset: Int, with value: UInt32) {
    let base = data.startIndex + offset
    data.replaceSubrange(base..<(base + 4), with: u32Bytes(value))
  }

  private static func replaceU64(_ data: inout Data, at offset: Int, with value: UInt64) {
    let base = data.startIndex + offset
    var out = u32Bytes(UInt32((value >> 32) & 0xFFFF_FFFF))
    out.append(u32Bytes(UInt32(value & 0xFFFF_FFFF)))
    data.replaceSubrange(base..<(base + 8), with: out)
  }
}
