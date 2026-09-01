import AVFoundation
import Foundation
import Testing

@testable import Nightdrive

struct MP4MetadataWriterTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  private func writeBareM4A(to url: URL, seconds: Double = 1.0) throws {
    try writeAudioFixture(to: url, formatID: kAudioFormatMPEG4AAC, seconds: seconds)
  }

  private func writeTaggedM4A(to url: URL, metadata: TrackMetadata) async throws {
    let source = scratch.appendingPathComponent("tagged-source.m4a")
    try writeBareM4A(to: source)
    try await AVFoundationAACEncoder().encode(
      source: source, destination: url,
      profile: TranscodeProfile(bitrateKbps: 128),
      metadata: metadata, artwork: pngArtwork())
  }

  private func sampleMetadata() -> TrackMetadata {
    TrackMetadata(
      title: "Atom Heart", artist: "The Writers", album: "Boxed",
      albumArtist: "Various Writers", composer: "C. Omposer", genre: "Electronic",
      grouping: "Sessions", year: 2014, bpm: 121, trackNumber: 3, trackCount: 12,
      discNumber: 1, discCount: 2, comment: "Bit-exact, please",
      lyrics: "moov la la", compilation: true)
  }

  private func atom(_ type: String, payload: Data) throws -> Data {
    let typeBytes = try #require(type.data(using: .isoLatin1))
    #expect((typeBytes.count) == (4))
    var data = Data()
    var size = UInt32(payload.count + 8).bigEndian
    withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
    data.append(typeBytes)
    data.append(payload)
    return data
  }

  private func metadataEntry(_ type: String, value: String) throws -> Data {
    var dataPayload = Data(repeating: 0, count: 8)
    dataPayload[3] = 1
    dataPayload.append(Data(value.utf8))
    return try atom(type, payload: atom("data", payload: dataPayload))
  }

  private func metadataHandler(_ type: String) throws -> Data {
    var payload = Data(repeating: 0, count: 8)
    payload.append(Data(type.utf8))
    payload.append(Data(repeating: 0, count: 12))
    return try atom("hdlr", payload: payload)
  }

  private func iTunesMeta(title: String, foreignValue: String) throws -> Data {
    var ilst = try metadataEntry("\u{00A9}nam", value: title)
    ilst.append(try metadataEntry("\u{00A9}too", value: foreignValue))
    var payload = Data(repeating: 0, count: 4)
    payload.append(try metadataHandler("mdir"))
    payload.append(try atom("ilst", payload: ilst))
    return try atom("meta", payload: payload)
  }

  private func keyedMeta() throws -> Data {
    var key = Data()
    var keySize = UInt32(8 + "com.example.title".utf8.count).bigEndian
    withUnsafeBytes(of: &keySize) { key.append(contentsOf: $0) }
    key.append(Data("mdta".utf8))
    key.append(Data("com.example.title".utf8))
    var keys = Data(repeating: 0, count: 4)
    keys.append(contentsOf: [0, 0, 0, 1])
    keys.append(key)

    var payload = Data(repeating: 0, count: 4)
    payload.append(try metadataHandler("mdta"))
    payload.append(try atom("keys", payload: keys))
    payload.append(
      try atom("ilst", payload: metadataEntry("\0\0\0\u{01}", value: "Keyed Title")))
    return try atom("meta", payload: payload)
  }

  private func foreignMeta() throws -> Data {
    var payload = Data(repeating: 0, count: 4)
    payload.append(try metadataHandler("ID32"))
    payload.append(try atom("ID32", payload: Data([0x41, 0x42, 0x43])))
    return try atom("meta", payload: payload)
  }

  private func directMetaFixture() throws -> Data {
    let moov = try atom(
      "moov", payload: iTunesMeta(title: "Old Title", foreignValue: "Foreign Tool"))
    let ftyp = try atom("ftyp", payload: Data("M4A \0\0\0\0M4A ".utf8))
    return ftyp + moov
  }

  private func mixedMetaFixture() throws -> (file: Data, keyedMeta: Data) {
    let keyedMeta = try keyedMeta()
    let userData = try atom(
      "udta", payload: iTunesMeta(title: "Old iTunes Title", foreignValue: "iTunes Tool"))
    let moov = try atom("moov", payload: keyedMeta + userData)
    let ftyp = try atom("ftyp", payload: Data("M4A \0\0\0\0M4A ".utf8))
    return (ftyp + moov, keyedMeta)
  }

  private func keyedUserDataFixture(includeITunesMeta: Bool) throws -> (
    file: Data, keyedMeta: Data
  ) {
    let keyedMeta = try keyedMeta()
    var userDataPayload = keyedMeta
    if includeITunesMeta {
      userDataPayload.append(
        try iTunesMeta(title: "Old iTunes Title", foreignValue: "Nested iTunes Tool"))
    }
    let moov = try atom("moov", payload: atom("udta", payload: userDataPayload))
    let ftyp = try atom("ftyp", payload: Data("M4A \0\0\0\0M4A ".utf8))
    return (ftyp + moov, keyedMeta)
  }

  private func foreignUserDataFixture() throws -> (file: Data, foreignMeta: Data) {
    let foreignMeta = try foreignMeta()
    let moov = try atom("moov", payload: atom("udta", payload: foreignMeta))
    let ftyp = try atom("ftyp", payload: Data("M4A \0\0\0\0M4A ".utf8))
    return (ftyp + moov, foreignMeta)
  }

  private func topLevelBoxes(in data: Data) throws -> [(type: String, range: Range<Int>)] {
    var boxes: [(String, Range<Int>)] = []
    var cursor = 0
    while cursor + 8 <= data.count {
      var size = Int(
        UInt32(data[cursor]) << 24 | UInt32(data[cursor + 1]) << 16
          | UInt32(data[cursor + 2]) << 8 | UInt32(data[cursor + 3]))
      let type =
        String(
          bytes: data[(cursor + 4)..<(cursor + 8)], encoding: .isoLatin1) ?? "????"
      if size == 0 {
        size = data.count - cursor
      } else if size == 1 {
        guard cursor + 16 <= data.count else { throw MP4MetadataError.malformedContainer }
        size = data[(cursor + 8)..<(cursor + 16)].reduce(0) { $0 << 8 | Int($1) }
      }
      guard size >= 8, cursor + size <= data.count else {
        throw MP4MetadataError.malformedContainer
      }
      boxes.append((type, cursor..<(cursor + size)))
      cursor += size
    }
    return boxes
  }

  private func assertAudioBytesUnchanged(original: Data, edited: Data) throws {
    let before = try topLevelBoxes(in: original).filter { $0.type != "moov" }
    let after = try topLevelBoxes(in: edited).filter { $0.type != "moov" }
    #expect((before.map(\.type)) == (after.map(\.type)), Comment(rawValue: "non-moov box layout must not change"))
    for (lhs, rhs) in zip(before, after) {
      #expect(
        (original[lhs.range]) == (edited[rhs.range]), Comment(rawValue: "\(lhs.type) box bytes must be bit-identical"))
    }
  }

  private func decodedSamples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let frames = AVAudioFrameCount(file.length)
    guard
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
    else {
      throw TranscodeError.encodingFailed("Could not allocate the decode buffer.")
    }
    try file.read(into: buffer)
    guard let channel = buffer.floatChannelData?[0] else { return [] }
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
  }

  @Test
  func testWritesEveryFieldIntoAFileWithNoExistingTags() async throws {
    let url = scratch.appendingPathComponent("bare.m4a")
    try writeBareM4A(to: url)
    let original = try Data(contentsOf: url)
    let metadata = sampleMetadata()

    try MP4MetadataWriter.write(metadata, to: url)

    let track = await MetadataLoader.load(url: url)
    #expect((track.title) == (metadata.title))
    #expect((track.artist) == (metadata.artist))
    #expect((track.album) == (metadata.album))
    #expect((track.albumArtist) == (metadata.albumArtist))
    #expect((track.composer) == (metadata.composer))
    #expect((track.genre) == (metadata.genre))
    #expect((track.grouping) == (metadata.grouping))
    #expect((track.year) == (metadata.year))
    #expect((track.bpm) == (metadata.bpm))
    #expect((track.trackNumber) == (metadata.trackNumber))
    #expect((track.trackCount) == (metadata.trackCount))
    #expect((track.discNumber) == (metadata.discNumber))
    #expect((track.discCount) == (metadata.discCount))
    #expect((track.comment) == (metadata.comment))
    #expect((track.lyrics) == (metadata.lyrics))
    #expect(track.compilation)

    let edited = try Data(contentsOf: url)
    try assertAudioBytesUnchanged(original: original, edited: edited)
  }

  @Test
  func testWritesAndClearsTheMediaKindStikAtom() async throws {
    let url = scratch.appendingPathComponent("book.m4a")
    try writeBareM4A(to: url)
    let original = try Data(contentsOf: url)

    try MP4MetadataWriter.write(sampleMetadata(), mediaKindChange: .audiobook, to: url)
    var track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .audiobook)

    // An unrelated edit must preserve the stik atom.
    var retitled = sampleMetadata()
    retitled.title = "Still an Audiobook"
    try MP4MetadataWriter.write(retitled, to: url)
    track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .audiobook)
    #expect((track.title) == ("Still an Audiobook"))

    try MP4MetadataWriter.write(sampleMetadata(), mediaKindChange: .song, to: url)
    track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .song)

    let edited = try Data(contentsOf: url)
    try assertAudioBytesUnchanged(original: original, edited: edited)
  }

  @Test
  func testAudiobookGenreDoesNotOverrideAnM4AWithoutAnAudiobookStik() async throws {
    let url = scratch.appendingPathComponent("genre-only.m4a")
    try writeBareM4A(to: url)
    var metadata = sampleMetadata()
    metadata.genre = "Audiobook"

    // The stik atom is authoritative for MPEG-4: an Audiobook genre alone
    // (absent or explicit song stik) must not reclassify the file.
    try MP4MetadataWriter.write(metadata, to: url)
    var track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .song)

    try MP4MetadataWriter.write(metadata, mediaKindChange: .song, to: url)
    track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .song)

    try MP4MetadataWriter.write(metadata, mediaKindChange: .audiobook, to: url)
    track = await MetadataLoader.load(url: url)
    #expect(track.mediaKind == .audiobook)
  }

  @Test
  func testRewritingTagsKeepsAudioDecodableAndBitIdentical() async throws {
    let url = scratch.appendingPathComponent("tagged.m4a")
    try await writeTaggedM4A(to: url, metadata: sampleMetadata())
    let original = try Data(contentsOf: url)
    let samplesBefore = try decodedSamples(of: url)
    #expect(!(samplesBefore.isEmpty))

    var metadata = sampleMetadata()
    metadata.title = "Rewritten Title With Considerably More Characters"
    metadata.lyrics = Array(
      repeating: "moov grows and offsets shift", count: 64
    ).joined(separator: "\n")
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    try assertAudioBytesUnchanged(original: original, edited: edited)
    #expect(
      (try decodedSamples(of: url)) == (samplesBefore),
      Comment(rawValue: "chunk offsets must survive a moov size change"))

    let track = await MetadataLoader.load(url: url)
    #expect((track.title) == (metadata.title))
    #expect((track.lyrics) == (metadata.lyrics))
  }

  @Test
  func testForeignIlstAtomsSurviveAnEdit() async throws {
    let url = scratch.appendingPathComponent("foreign.m4a")
    try await writeTaggedM4A(to: url, metadata: sampleMetadata())

    let owned: Set<String> = [
      "\u{00A9}nam", "\u{00A9}ART", "\u{00A9}alb", "aART", "\u{00A9}wrt",
      "\u{00A9}gen", "gnre", "\u{00A9}grp", "\u{00A9}day", "tmpo", "trkn",
      "disk", "\u{00A9}cmt", "\u{00A9}lyr", "cpil", "covr",
    ]
    let foreignBefore = try MP4MetadataWriter.ilstEntries(in: Data(contentsOf: url))
      .filter { !owned.contains($0.type) }
    #expect(
      !(foreignBefore.isEmpty),
      Comment(rawValue: "fixture must carry at least one atom Nightdrive does not edit (e.g. ©too)"))

    var metadata = sampleMetadata()
    metadata.title = "Changed"
    try MP4MetadataWriter.write(metadata, to: url)

    let entriesAfter = try MP4MetadataWriter.ilstEntries(in: Data(contentsOf: url))
    for entry in foreignBefore {
      #expect(entriesAfter.contains(entry), Comment(rawValue: "\(entry.type) must be preserved verbatim"))
    }
  }

  @Test
  func testReusesDirectMoovMetaLayoutWithoutAddingUdtaMetadata() throws {
    let url = scratch.appendingPathComponent("direct-meta.m4a")
    try directMetaFixture().write(to: url)

    var metadata = sampleMetadata()
    metadata.title = "Direct Metadata"
    try MP4MetadataWriter.write(metadata, to: url)
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    let moov = try #require(topLevelBoxes(in: edited).first { $0.type == "moov" })
    let moovChildren = try topLevelBoxes(
      in: Data(edited[(moov.range.lowerBound + 8)..<moov.range.upperBound]))
    #expect((moovChildren.filter { $0.type == "meta" }.count) == (1))
    #expect(!(moovChildren.contains { $0.type == "udta" }))

    let entries = try MP4MetadataWriter.ilstEntries(in: edited)
    #expect((entries.filter { $0.type == "\u{00A9}nam" }.count) == (1))
    #expect((entries.filter { $0.type == "\u{00A9}too" }.count) == (1))
  }

  @Test
  func testPrefersITunesUserDataOverDirectKeyedMetadata() throws {
    let url = scratch.appendingPathComponent("mixed-meta.m4a")
    let fixture = try mixedMetaFixture()
    try fixture.file.write(to: url)

    var metadata = sampleMetadata()
    metadata.title = "Updated iTunes Title"
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    #expect(edited.range(of: fixture.keyedMeta) != nil)
    let entries = try MP4MetadataWriter.ilstEntries(in: edited)
    #expect((entries.filter { $0.type == "\u{00A9}nam" }.count) == (1))
    #expect((entries.filter { $0.type == "\u{00A9}too" }.count) == (1))
    #expect(entries.contains { $0.bytes.range(of: Data(metadata.title.utf8)) != nil })
    #expect(entries.contains { $0.bytes.range(of: Data("iTunes Tool".utf8)) != nil })
  }

  @Test
  func testAddsSeparateITunesMetadataBesideKeyedUserData() throws {
    let url = scratch.appendingPathComponent("keyed-user-data.m4a")
    let fixture = try keyedUserDataFixture(includeITunesMeta: false)
    try fixture.file.write(to: url)

    var metadata = sampleMetadata()
    metadata.title = "Separate iTunes Title"
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    #expect(edited.range(of: fixture.keyedMeta) != nil)
    let entries = try MP4MetadataWriter.ilstEntries(in: edited)
    #expect((entries.filter { $0.type == "\u{00A9}nam" }.count) == (1))
    #expect(entries.contains { $0.bytes.range(of: Data(metadata.title.utf8)) != nil })
  }

  @Test
  func testUpdatesSelectedITunesMetaWhenItFollowsKeyedMetaInUserData() throws {
    let url = scratch.appendingPathComponent("ordered-user-data.m4a")
    let fixture = try keyedUserDataFixture(includeITunesMeta: true)
    try fixture.file.write(to: url)

    var metadata = sampleMetadata()
    metadata.title = "Updated Nested Title"
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    #expect(edited.range(of: fixture.keyedMeta) != nil)
    let entries = try MP4MetadataWriter.ilstEntries(in: edited)
    #expect((entries.filter { $0.type == "\u{00A9}nam" }.count) == (1))
    #expect(entries.contains { $0.bytes.range(of: Data(metadata.title.utf8)) != nil })
    #expect(entries.contains { $0.bytes.range(of: Data("Nested iTunes Tool".utf8)) != nil })
  }

  @Test
  func testAddsSeparateITunesMetadataBesideForeignUserData() throws {
    let url = scratch.appendingPathComponent("foreign-user-data.m4a")
    let fixture = try foreignUserDataFixture()
    try fixture.file.write(to: url)

    var metadata = sampleMetadata()
    metadata.title = "Separate From Foreign Metadata"
    try MP4MetadataWriter.write(metadata, to: url)

    let edited = try Data(contentsOf: url)
    #expect(edited.range(of: fixture.foreignMeta) != nil)
    let entries = try MP4MetadataWriter.ilstEntries(in: edited)
    #expect((entries.filter { $0.type == "\u{00A9}nam" }.count) == (1))
    #expect(entries.contains { $0.bytes.range(of: Data(metadata.title.utf8)) != nil })
  }

  @Test
  func testAtomicSameStatM4AReplacementInvalidatesLibraryIndex() async throws {
    let url = scratch.appendingPathComponent("same-stat.m4a")
    try writeBareM4A(to: url)
    var metadata = sampleMetadata()
    metadata.title = "Before"
    try MP4MetadataWriter.write(metadata, to: url)
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: url.path)

    let cold = await LibraryStore.scanTracks(at: [url], consulting: [:])
    #expect((cold.tracks.first?.title) == ("Before"))
    let before = try #require(FileGenerationStamp(url: url))

    metadata.title = "After!"
    try MP4MetadataWriter.write(metadata, to: url)
    let after = try pinnedGenerationStamp(
      at: url, distinctFrom: before, modificationDate: pinnedDate)

    #expect((after.inode) != (before.inode), Comment(rawValue: "the MP4 writer must atomically replace the file"))
    #expect((after.sizeBytes) == (before.sizeBytes))
    #expect((after.modificationSeconds) == (before.modificationSeconds))
    #expect((after.modificationNanoseconds) == (before.modificationNanoseconds))
    #expect((after) != (before))

    let warm = await LibraryStore.scanTracks(at: [url], consulting: cold.entries)
    #expect((warm.tracks.first?.title) == ("After!"))
    #expect((warm.tracks.first?.mediaValidation) == (.valid))
  }

  @Test
  func testArtworkReplaceAndRemove() async throws {
    let url = scratch.appendingPathComponent("artwork.m4a")
    try writeBareM4A(to: url)
    let original = try Data(contentsOf: url)
    let png = pngArtwork(size: 16)

    try MP4MetadataWriter.write(sampleMetadata(), artworkChange: .replace(png), to: url)
    let written = await MetadataLoader.loadArtwork(url: url)
    #expect((written) == (png))

    var metadata = sampleMetadata()
    metadata.comment = "still covered"
    try MP4MetadataWriter.write(metadata, to: url)
    let kept = await MetadataLoader.loadArtwork(url: url)
    #expect((kept) == (png))

    try MP4MetadataWriter.write(sampleMetadata(), artworkChange: .remove, to: url)
    let removed = await MetadataLoader.loadArtwork(url: url)
    #expect(removed == nil)

    try assertAudioBytesUnchanged(original: original, edited: Data(contentsOf: url))
  }

  @Test
  func testRejectsNonMP4FilesUnchanged() throws {
    let mp3URL = scratch.appendingPathComponent("song.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Nope", artist: "A", album: "B", genre: "Rock",
        trackNumber: 1, year: 2000),
      seconds: 1
    ).write(to: mp3URL)
    let mp3Bytes = try Data(contentsOf: mp3URL)
    do {
      let caughtError = #expect(throws: (any Error).self) { try MP4MetadataWriter.write(sampleMetadata(), to: mp3URL) }
      if let caughtError {
        #expect((caughtError as? MP4MetadataError) == (.notMP4))
      }
    }
    #expect((try Data(contentsOf: mp3URL)) == (mp3Bytes))

    let corrupt = scratch.appendingPathComponent("corrupt.m4a")
    try Data("this is not an mpeg-4 container at all".utf8).write(to: corrupt)
    let corruptBytes = try Data(contentsOf: corrupt)
    #expect(throws: (any Error).self) { try MP4MetadataWriter.write(sampleMetadata(), to: corrupt) }
    #expect((try Data(contentsOf: corrupt)) == (corruptBytes))
  }

  @Test
  func testRejectsOverflowingLargeBoxSizeWithoutCrashing() throws {
    let url = scratch.appendingPathComponent("overflow.m4a")
    var data = Data()
    data.append(contentsOf: [0, 0, 0, 16])
    data.append(Data("ftypM4A ".utf8))
    data.append(contentsOf: [0, 0, 0, 0])
    // A 64-bit box size that passes the Int.max guard on its own but
    // overflows once added to the box's offset.
    data.append(contentsOf: [0, 0, 0, 1])
    data.append(Data("moov".utf8))
    withUnsafeBytes(of: UInt64(Int.max).bigEndian) { data.append(contentsOf: $0) }
    try data.write(to: url)

    let caughtError = #expect(throws: (any Error).self) {
      try MP4MetadataWriter.write(sampleMetadata(), to: url)
    }
    if let caughtError {
      #expect((caughtError as? MP4MetadataError) == (.malformedContainer))
    }
    #expect((try Data(contentsOf: url)) == (data))
  }

  @Test
  func testRefusesToSpliceWhenTheFileChangedAfterParsing() throws {
    let url = scratch.appendingPathComponent("raced.m4a")
    try writeBareM4A(to: url)

    let snapshot = try Data(contentsOf: url)
    let moovRange = try #require(topLevelBoxes(in: snapshot).first { $0.type == "moov" }?.range)
    let stalePrefix = snapshot.subdata(
      in: moovRange.lowerBound..<min(moovRange.lowerBound + 16, moovRange.upperBound))
    let replacement = snapshot.subdata(in: moovRange)

    var grown = snapshot
    grown.append(Data(repeating: 0xAB, count: 64))
    try grown.write(to: url)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try MP4MetadataWriter.replace(
          contentsOf: url, byteRange: moovRange, with: replacement,
          originalSize: snapshot.count, expectedRangePrefix: stalePrefix)
      }
      if let caughtError {
        #expect((caughtError as? MP4MetadataError) == (.malformedContainer))
      }
    }
    #expect((try Data(contentsOf: url)) == (grown), Comment(rawValue: "a refused write must not touch the file"))

    var shuffled = snapshot
    shuffled.replaceSubrange(
      moovRange.lowerBound..<(moovRange.lowerBound + 8),
      with: Data(repeating: 0xCD, count: 8))
    try shuffled.write(to: url)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try MP4MetadataWriter.replace(
          contentsOf: url, byteRange: moovRange, with: replacement,
          originalSize: snapshot.count, expectedRangePrefix: stalePrefix)
      }
      if let caughtError {
        #expect((caughtError as? MP4MetadataError) == (.malformedContainer))
      }
    }
    #expect((try Data(contentsOf: url)) == (shuffled))

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
      .filter { $0.contains(".nightdrive-") }
    #expect((leftovers) == ([]))

    try snapshot.write(to: url)
    try MP4MetadataWriter.replace(
      contentsOf: url, byteRange: moovRange, with: replacement,
      originalSize: snapshot.count, expectedRangePrefix: stalePrefix)
    #expect((try Data(contentsOf: url)) == (snapshot))
  }

  @Test
  func testFormatGatingCoversMP4Audio() throws {
    #expect(LibraryAudioFormat.mp3.supportsMetadataEditing)
    #expect(LibraryAudioFormat.m4a.supportsMetadataEditing)
    #expect(LibraryAudioFormat.m4b.supportsMetadataEditing)
    #expect(!(LibraryAudioFormat.flac.supportsMetadataEditing))
    #expect(!(LibraryAudioFormat.wav.supportsMetadataEditing))
    #expect(!(LibraryAudioFormat.aiff.supportsMetadataEditing))
  }

  @MainActor
  @Test
  func testLibraryStoreEditsM4ATracksEndToEnd() async throws {
    let url = scratch.appendingPathComponent("editable.m4a")
    try writeBareM4A(to: url)
    let store = LibraryStore(folderURL: scratch)
    await store.rescan()
    let track = try #require(store.tracks.first { $0.url == url.canonicalFileURL })
    #expect(track.supportsMetadataEditing)

    var metadata = TrackMetadata(track)
    metadata.title = "Edited In Place"
    metadata.artist = "New Artist"
    try await store.updateMetadata(for: track, to: metadata, artworkChange: .unchanged)

    let refreshed = try #require(store.tracks.first { $0.url == url.canonicalFileURL })
    #expect((refreshed.title) == ("Edited In Place"))
    #expect((refreshed.artist) == ("New Artist"))
  }
}
