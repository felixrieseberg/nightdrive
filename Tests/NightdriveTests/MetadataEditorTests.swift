import Foundation
import Testing

@testable import Nightdrive

final class MetadataEditorTests {
  private var directory: URL!

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMetadataEditorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  @Test
  func testMetadataFieldSchemaCoversEveryFieldExactlyOnce() {
    let described =
      MetadataField.stringFields.map(\.field)
      + MetadataField.numberFields.map(\.field)
      + MetadataField.boolFields.map(\.field)
    #expect((described.count) == (MetadataField.allCases.count))
    #expect((Set(described)) == (Set(MetadataField.allCases)))
  }

  @Test
  func testWritesEveryEditableFieldAndUnicode() async throws {
    let url = try makeMP3()
    let metadata = TrackMetadata(
      title: "星の歌",
      artist: "Björk",
      album: "Album",
      albumArtist: "Various Artists",
      composer: "Composer",
      genre: "Electronic",
      grouping: "Movement I",
      year: 2026,
      bpm: 128,
      trackNumber: 3,
      trackCount: 12,
      discNumber: 2,
      discCount: 3,
      comment: "A useful note",
      lyrics: "Some lyrics",
      compilation: true)

    try MP3MetadataWriter.write(metadata, to: url)
    let loaded = await MetadataLoader.load(url: url)

    #expect((loaded.title) == (metadata.title))
    #expect((loaded.artist) == (metadata.artist))
    #expect((loaded.album) == (metadata.album))
    #expect((loaded.albumArtist) == (metadata.albumArtist))
    #expect((loaded.composer) == (metadata.composer))
    #expect((loaded.genre) == (metadata.genre))
    #expect((loaded.grouping) == (metadata.grouping))
    #expect((loaded.year) == (metadata.year))
    #expect((loaded.bpm) == (metadata.bpm))
    #expect((loaded.trackNumber) == (metadata.trackNumber))
    #expect((loaded.trackCount) == (metadata.trackCount))
    #expect((loaded.discNumber) == (metadata.discNumber))
    #expect((loaded.discCount) == (metadata.discCount))
    #expect((loaded.comment) == (metadata.comment))
    #expect((loaded.lyrics) == (metadata.lyrics))
    #expect(loaded.compilation)
  }

  @MainActor
  @Test
  func testBulkGenreEditPreservesEveryOtherProperty() async throws {
    let firstURL = directory.appendingPathComponent("first.mp3")
    let secondURL = directory.appendingPathComponent("second.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "First", artist: "Artist One", album: "Album One",
        genre: "Rock", trackNumber: 3, year: 2001),
      seconds: 1
    ).write(to: firstURL)
    try MP3Builder.build(
      tags: .init(
        title: "Second", artist: "Artist Two", album: "Album Two",
        genre: "Pop", trackNumber: 7, year: 2007),
      seconds: 1
    ).write(to: secondURL)

    let store = LibraryStore(folderURL: directory)
    await store.rescan()
    let before = Dictionary(
      uniqueKeysWithValues: store.tracks.map { ($0.id, TrackMetadata($0)) })
    var changes = TrackMetadataChanges()
    changes.genre = "Electronic"

    try await store.updateMetadata(for: store.tracks, applying: changes)

    #expect((store.tracks.count) == (2))
    for track in store.tracks {
      let original = try #require(before[track.id])
      let updated = TrackMetadata(track)
      #expect((updated.genre) == ("Electronic"))
      #expect((updated.title) == (original.title))
      #expect((updated.artist) == (original.artist))
      #expect((updated.album) == (original.album))
      #expect((updated.albumArtist) == (original.albumArtist))
      #expect((updated.composer) == (original.composer))
      #expect((updated.grouping) == (original.grouping))
      #expect((updated.year) == (original.year))
      #expect((updated.bpm) == (original.bpm))
      #expect((updated.trackNumber) == (original.trackNumber))
      #expect((updated.trackCount) == (original.trackCount))
      #expect((updated.discNumber) == (original.discNumber))
      #expect((updated.discCount) == (original.discCount))
      #expect((updated.comment) == (original.comment))
      #expect((updated.lyrics) == (original.lyrics))
      #expect((updated.compilation) == (original.compilation))
    }
  }

  @MainActor
  @Test
  func testCancellingBatchEditStopsBetweenFilesAndStillRescans() async throws {
    let count = 6
    for index in 0..<count {
      let url = directory.appendingPathComponent(String(format: "track-%02d.mp3", index))
      try MP3Builder.build(
        tags: .init(
          title: "Old \(index)", artist: "Artist", album: "Album",
          genre: "Rock", trackNumber: index + 1, year: 2000),
        seconds: 1
      ).write(to: url)
    }

    let store = LibraryStore(folderURL: directory)
    await store.rescan()
    #expect((store.tracks.count) == (count))

    let edits = store.tracks.map { track -> TrackMetadataEdit in
      var metadata = TrackMetadata(track)
      metadata.title = "New \(track.trackNumber)"
      return TrackMetadataEdit(track: track, metadata: metadata)
    }
    let firstURL = edits[0].track.url
    let lastURL = edits[count - 1].track.url
    let originalFirst = try Data(contentsOf: firstURL)
    let originalLast = try Data(contentsOf: lastURL)

    let task = Task { try await store.updateMetadata(applying: edits) }
    let deadline = Date().addingTimeInterval(30)
    while try Data(contentsOf: firstURL) == originalFirst {
      guard Date() < deadline else {
        task.cancel()
        Issue.record("First write never landed")
        return
      }
      await Task.yield()
    }
    task.cancel()
    do {
      try await task.value
      Issue.record("Expected CancellationError")
    } catch is CancellationError {
    }

    #expect(
      (try Data(contentsOf: lastURL)) == (originalLast),
      Comment(rawValue: "A cancelled batch must not keep rewriting files"))
    #expect((store.tracks.first?.title) == ("New 1"))
  }

  @Test
  func testPreservesArtworkUnknownFramesAndAudioBytes() throws {
    let url = try makeMP3()
    let original = try Data(contentsOf: url)
    let audio = audioBytes(in: original)
    let privatePayload = Data("owner\u{0}private value".utf8)
    let artworkPayload = Data([0, 0x69, 0x6D, 0x61, 0x67, 0x65, 0, 3, 0, 1, 2, 3])
    let augmented = addingFrames(
      [
        .init(id: "PRIV", payload: privatePayload),
        .init(id: "APIC", payload: artworkPayload),
      ],
      to: original)
    try augmented.write(to: url)

    var metadata = baselineMetadata
    metadata.title = "Changed"
    try MP3MetadataWriter.write(metadata, to: url)

    let updated = try Data(contentsOf: url)
    let frames = try MP3MetadataWriter.frames(in: updated)
    #expect(frames.contains(.init(id: "PRIV", payload: privatePayload)))
    #expect(frames.contains(.init(id: "APIC", payload: artworkPayload)))
    #expect((audioBytes(in: updated)) == (audio))
  }

  @Test
  func testClearingOptionalFieldsRemovesTheirFrames() throws {
    let url = try makeMP3()
    try MP3MetadataWriter.write(baselineMetadata, to: url)
    var cleared = baselineMetadata
    cleared.album = ""
    cleared.albumArtist = ""
    cleared.comment = ""
    cleared.trackNumber = 0
    cleared.trackCount = 0
    cleared.compilation = false

    try MP3MetadataWriter.write(cleared, to: url)
    let ids = Set(try MP3MetadataWriter.frames(in: Data(contentsOf: url)).map(\.id))
    #expect(!(ids.contains("TALB")))
    #expect(!(ids.contains("TPE2")))
    #expect(!(ids.contains("COMM")))
    #expect(!(ids.contains("TRCK")))
    #expect(!(ids.contains("TCMP")))
  }

  @Test
  func testMalformedTagDoesNotChangeFile() throws {
    let url = directory.appendingPathComponent("malformed.mp3")
    let malformed = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 1, 0])
    try malformed.write(to: url)

    #expect(throws: (any Error).self) { try MP3MetadataWriter.write(baselineMetadata, to: url) }
    #expect((try Data(contentsOf: url)) == (malformed))
  }

  @Test
  func testReplacesAndRemovesArtwork() throws {
    let url = try makeMP3()
    let oldArtwork = Data([0, 0x69, 0x6D, 0x61, 0x67, 0, 3, 0, 1, 2, 3])
    try addingFrames(
      [.init(id: "APIC", payload: oldArtwork)],
      to: Data(contentsOf: url)
    ).write(to: url)
    let png = Data([0x89, 0x50, 0x4E, 0x47, 10, 20, 30])

    try MP3MetadataWriter.write(
      baselineMetadata, artworkChange: .replace(png), to: url)
    var artworkFrames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
      .filter { $0.id == "APIC" }
    #expect((artworkFrames.count) == (1))
    #expect(artworkFrames[0].payload.suffix(png.count) == png)

    try MP3MetadataWriter.write(
      baselineMetadata, artworkChange: .remove, to: url)
    artworkFrames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
      .filter { $0.id == "APIC" }
    #expect(artworkFrames.isEmpty)
  }

  @Test
  func testPreservesVersion22FramesAndAudio() throws {
    let url = directory.appendingPathComponent("v22.mp3")
    let artwork = Data([0, 0x4A, 0x50, 0x47, 3, 0, 1, 2, 3])
    let privatePayload = Data("kept".utf8)
    let audio = Data([0xFF, 0xFB, 0x90, 0]) + Data(count: 32)
    let original = taggedMP3(
      version: 2,
      frames: [
        .init(id: "TT2", payload: Data([0]) + Data("Old".utf8)),
        .init(id: "PIC", payload: artwork),
        .init(id: "XYZ", payload: privatePayload),
      ],
      audio: audio)
    try original.write(to: url)

    try MP3MetadataWriter.write(baselineMetadata, to: url)

    let updated = try Data(contentsOf: url)
    let frames = try MP3MetadataWriter.frames(in: updated)
    #expect(frames.contains(.init(id: "PIC", payload: artwork)))
    #expect(frames.contains(.init(id: "XYZ", payload: privatePayload)))
    #expect(frames.contains { $0.id == "TT2" })
    #expect((audioBytes(in: updated)) == (audio))
  }

  @Test
  func testVersion22RejectsOversizedArtworkWithoutChangingTheFile() throws {
    let url = directory.appendingPathComponent("v22-oversized-art.mp3")
    let original = taggedMP3(
      version: 2,
      frames: [.init(id: "TT2", payload: Data([0]) + Data("Original".utf8))],
      audio: Data([0xFF, 0xFB, 0x90, 0]) + Data(count: 32))
    try original.write(to: url)

    let oversizedArtwork = Data(count: 0x0100_0000)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try MP3MetadataWriter.write(
          baselineMetadata, artworkChange: .replace(oversizedArtwork), to: url)
      }
      if let caughtError {
        #expect((caughtError as? MP3MetadataError) == (.tagTooLarge))
      }
    }
    #expect((try Data(contentsOf: url)) == (original))
  }

  @Test
  func testPreservesVersion24FramesAndAudio() throws {
    let url = directory.appendingPathComponent("v24.mp3")
    let privatePayload = Data("owner\u{0}kept".utf8)
    let audio = Data([0xFF, 0xFB, 0x90, 0]) + Data(count: 32)
    let original = taggedMP3(
      version: 4,
      frames: [
        .init(id: "TIT2", payload: Data([3]) + Data("Old".utf8)),
        .init(id: "PRIV", payload: privatePayload),
      ],
      audio: audio)
    try original.write(to: url)

    try MP3MetadataWriter.write(baselineMetadata, to: url)

    let updated = try Data(contentsOf: url)
    let frames = try MP3MetadataWriter.frames(in: updated)
    #expect(frames.contains(.init(id: "PRIV", payload: privatePayload)))
    #expect((audioBytes(in: updated)) == (audio))
  }

  @Test
  func testCommentAndLyricsEditsPreserveNoncanonicalSiblingFrames() throws {
    for version in 2...4 {
      let url = directory.appendingPathComponent("language-text-v2\(version).mp3")
      let commentID = version == 2 ? "COM" : "COMM"
      let lyricsID = version == 2 ? "ULT" : "USLT"
      let audio = Data([0xFF, 0xFB, 0x90, UInt8(version)]) + Data(count: 32)

      let alternateComment = MP3MetadataWriter.Frame(
        id: commentID,
        payload: languageTextPayload(
          encoding: version == 4 ? 2 : 0,
          language: "spa",
          description: "",
          text: "Comentario"))
      let describedLyrics = MP3MetadataWriter.Frame(
        id: lyricsID,
        payload: languageTextPayload(
          encoding: version == 4 ? 3 : 1,
          language: "eng",
          description: "karaoke",
          text: "Alternate lyrics",
          utf16BigEndian: version == 3))
      let describedComment = MP3MetadataWriter.Frame(
        id: commentID,
        payload: languageTextPayload(
          encoding: version == 4 ? 3 : 0,
          language: "eng",
          description: "iTunNORM",
          text: "0000 0000"))
      let alternateLyrics = MP3MetadataWriter.Frame(
        id: lyricsID,
        payload: languageTextPayload(
          encoding: version == 4 ? 2 : 1,
          language: "deu",
          description: "",
          text: "Anderer Text",
          utf16BigEndian: version == 3))
      let malformedComment = MP3MetadataWriter.Frame(
        id: commentID,
        payload: malformedLanguageTextPayload(version: version))
      let transformedLyrics = MP3MetadataWriter.Frame(
        id: lyricsID,
        payload: languageTextPayload(
          encoding: 0, language: "eng", description: "", text: "Opaque"),
        flags: version == 3 ? 0x0020 : (version == 4 ? 0x0040 : 0))
      let preserved =
        [
          alternateComment, describedLyrics, malformedComment, describedComment, alternateLyrics,
        ] + (version == 2 ? [] : [transformedLyrics])

      let originalComment = MP3MetadataWriter.Frame(
        id: commentID,
        payload: languageTextPayload(
          encoding: version == 4 ? 2 : 1,
          language: "eng",
          description: "",
          text: "Old canonical comment",
          utf16BigEndian: version == 3))
      let originalLyrics = MP3MetadataWriter.Frame(
        id: lyricsID,
        payload: languageTextPayload(
          encoding: version == 4 ? 3 : 0,
          language: "eng",
          description: "",
          text: "Old canonical lyrics"))
      let original = taggedMP3(
        version: version,
        frames: [
          .init(
            id: version == 2 ? "TT2" : "TIT2",
            payload: Data([0]) + Data("Old title".utf8)),
          alternateComment,
          describedLyrics,
          originalComment,
          malformedComment,
          originalLyrics,
          describedComment,
          alternateLyrics,
        ] + (version == 2 ? [] : [transformedLyrics]),
        audio: audio)
      try original.write(to: url)

      var updatedMetadata = baselineMetadata
      updatedMetadata.comment = "New canonical comment"
      updatedMetadata.lyrics = "New canonical lyrics"
      try MP3MetadataWriter.write(updatedMetadata, to: url)

      var frames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
      #expect((frames.filter { preserved.contains($0) }) == (preserved), Comment(rawValue: "ID3v2.\(version)"))
      #expect(!(frames.contains(originalComment)), Comment(rawValue: "ID3v2.\(version)"))
      #expect(!(frames.contains(originalLyrics)), Comment(rawValue: "ID3v2.\(version)"))
      #expect(
        frames.contains(
          .init(
            id: commentID,
            payload: languageTextPayload(
              encoding: 1,
              language: "eng",
              description: "",
              text: updatedMetadata.comment))), Comment(rawValue: "ID3v2.\(version)"))
      #expect(
        frames.contains(
          .init(
            id: lyricsID,
            payload: languageTextPayload(
              encoding: 1,
              language: "eng",
              description: "",
              text: updatedMetadata.lyrics))), Comment(rawValue: "ID3v2.\(version)"))
      #expect(
        (frames.filter { $0.id == commentID || $0.id == lyricsID }.count) == (preserved.count + 2),
        Comment(rawValue: "ID3v2.\(version)"))
      #expect((audioBytes(in: try Data(contentsOf: url))) == (audio), Comment(rawValue: "ID3v2.\(version)"))

      var clearedMetadata = updatedMetadata
      clearedMetadata.comment = ""
      clearedMetadata.lyrics = ""
      try MP3MetadataWriter.write(clearedMetadata, to: url)

      frames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
      #expect((frames.filter { preserved.contains($0) }) == (preserved), Comment(rawValue: "ID3v2.\(version)"))
      #expect(
        (frames.filter { $0.id == commentID || $0.id == lyricsID }.count) == (preserved.count),
        Comment(rawValue: "ID3v2.\(version)"))
      #expect((audioBytes(in: try Data(contentsOf: url))) == (audio), Comment(rawValue: "ID3v2.\(version)"))
    }
  }

  @Test
  func testRewritePreservesLargeAudioTailExactly() throws {
    let url = directory.appendingPathComponent("large-tail.mp3")
    let audio = Data(repeating: 0xA5, count: 5 * 1_024 * 1_024 + 17)
    let original = taggedMP3(
      version: 3,
      frames: [.init(id: "TIT2", payload: Data([3]) + Data("Old".utf8))],
      audio: audio)
    try original.write(to: url)

    try MP3MetadataWriter.write(baselineMetadata, to: url)

    #expect((audioBytes(in: try Data(contentsOf: url))) == (audio))
  }

  @Test
  func testParsesVersion24TagLevelUnsynchronization() throws {
    let url = directory.appendingPathComponent("v24-tag-unsync.mp3")
    let storedBinary = Data([0x41, 0xFF, 0x00, 0xFB, 0x42])
    let decodedBinary = Data([0x41, 0xFF, 0xFB, 0x42])
    let storedCompressed = Data([0xFF, 0x00, 0xE0, 0x07])
    let audio = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(repeating: 0x22, count: 32)
    let original = taggedMP3(
      version: 4,
      tagFlags: 0x80,
      frames: [
        .init(id: "XXXX", payload: storedBinary),
        .init(id: "YYYY", payload: storedCompressed, flags: 0x000A),
        .init(id: "TIT2", payload: Data([0]) + Data("Kept".utf8)),
      ],
      audio: audio)
    try original.write(to: url)

    let frames = try MP3MetadataWriter.frames(in: original)
    let binary = try #require(frames.first { $0.id == "XXXX" })
    #expect((binary.payload) == (decodedBinary))
    #expect((binary.flags & 0x2) == (0))
    let compressed = try #require(frames.first { $0.id == "YYYY" })
    #expect((compressed.payload) == (storedCompressed))
    #expect((compressed.flags & 0x2) == (0x2))
    let title = try #require(frames.first { $0.id == "TIT2" })
    #expect((title.payload) == (Data([0]) + Data("Kept".utf8)))

    try MP3MetadataWriter.write(baselineMetadata, to: url)

    let rewritten = try Data(contentsOf: url)
    let preserved = try MP3MetadataWriter.frames(in: rewritten)
    #expect((preserved.first { $0.id == "XXXX" }?.payload) == (decodedBinary))
    #expect((preserved.first { $0.id == "YYYY" }?.payload) == (storedCompressed))
    #expect((audioBytes(in: rewritten)) == (audio))
  }

  @Test
  func testDecodesVersion24PerFrameUnsynchronization() throws {
    let stored = Data([0x00, 0xFF, 0x00, 0xFB])
    let original = taggedMP3(
      version: 4,
      frames: [.init(id: "XXXX", payload: stored, flags: 0x0002)],
      audio: Data([0xFF, 0xFB, 0x90, 0x00]))

    let frames = try MP3MetadataWriter.frames(in: original)

    let frame = try #require(frames.first { $0.id == "XXXX" })
    #expect((frame.payload) == (Data([0x00, 0xFF, 0xFB])))
    #expect((frame.flags & 0x2) == (0))
  }

  @Test
  func testVersion23TagLevelUnsynchronizationDecodesWholeTag() throws {
    var body = Data("XXXX".utf8)
    body.append(contentsOf: [0, 0, 0, 3])
    body.append(contentsOf: [0, 0])
    body.append(contentsOf: [0x41, 0xFF, 0xFB])
    var escaped = Data()
    for byte in body {
      escaped.append(byte)
      if byte == 0xFF { escaped.append(0x00) }
    }
    var tag = Data("ID3".utf8)
    tag.append(contentsOf: [3, 0, 0x80])
    tag.append(contentsOf: synchsafeBytes(escaped.count))
    tag.append(escaped)

    let frames = try MP3MetadataWriter.frames(in: tag)

    #expect((frames.count) == (1))
    #expect((frames.first?.id) == ("XXXX"))
    #expect((frames.first?.payload) == (Data([0x41, 0xFF, 0xFB])))
  }

  @Test
  func testRefusesToSpliceWhenTheFileChangedAfterParsing() throws {
    let url = directory.appendingPathComponent("stale.mp3")
    let audio = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(repeating: 0x11, count: 64)
    let snapshot = taggedMP3(
      version: 3,
      frames: [.init(id: "TIT2", payload: Data([0]) + Data("Kept".utf8))],
      audio: audio)
    let audioOffset = snapshot.count - audio.count
    let expectedPrefix = snapshot.subdata(
      in: audioOffset..<min(audioOffset + 16, snapshot.count))
    let replacement = snapshot.subdata(in: 0..<audioOffset)

    try (snapshot + Data(repeating: 0xAB, count: 64)).write(to: url)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try MP3MetadataWriter.replaceTag(
          contentsOf: url, with: replacement, audioOffset: audioOffset,
          originalSize: snapshot.count, expectedAudioPrefix: expectedPrefix)
      }
      if let caughtError {
        #expect((caughtError as? MP3MetadataError) == (.fileChanged))
      }
    }
    #expect((try Data(contentsOf: url)) == (snapshot + Data(repeating: 0xAB, count: 64)))

    var swapped = snapshot
    swapped.replaceSubrange(
      audioOffset..<snapshot.count,
      with: Data(repeating: 0xCD, count: audio.count))
    try swapped.write(to: url)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try MP3MetadataWriter.replaceTag(
          contentsOf: url, with: replacement, audioOffset: audioOffset,
          originalSize: snapshot.count, expectedAudioPrefix: expectedPrefix)
      }
      if let caughtError {
        #expect((caughtError as? MP3MetadataError) == (.fileChanged))
      }
    }
    #expect((try Data(contentsOf: url)) == (swapped))

    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.contains(".nightdrive-") }
    #expect((leftovers) == ([]))

    try snapshot.write(to: url)
    try MP3MetadataWriter.replaceTag(
      contentsOf: url, with: replacement, audioOffset: audioOffset,
      originalSize: snapshot.count, expectedAudioPrefix: expectedPrefix)
    #expect((try Data(contentsOf: url)) == (snapshot))
  }

  private var baselineMetadata: TrackMetadata {
    TrackMetadata(
      title: "Title",
      artist: "Artist",
      album: "Album",
      albumArtist: "Album Artist",
      composer: "Composer",
      genre: "Rock",
      grouping: "Suite",
      year: 2001,
      bpm: 120,
      trackNumber: 1,
      trackCount: 9,
      discNumber: 1,
      discCount: 2,
      comment: "Comment",
      lyrics: "Lyrics",
      compilation: true)
  }

  private func makeMP3() throws -> URL {
    try makeTaggedMP3(in: directory)
  }

  private func taggedMP3(
    version: Int, tagFlags: UInt8 = 0, frames: [MP3MetadataWriter.Frame], audio: Data
  ) -> Data {
    var body = Data()
    for frame in frames {
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
    var output = Data("ID3".utf8)
    output.append(contentsOf: [UInt8(version), 0, tagFlags])
    output.append(contentsOf: synchsafeBytes(body.count))
    output.append(body)
    output.append(audio)
    return output
  }

  private func audioBytes(in mp3: Data) -> Data {
    guard mp3.count >= 10, String(data: mp3[0..<3], encoding: .ascii) == "ID3" else {
      return mp3
    }
    let size = synchsafeSize(mp3[6..<10])
    return Data(mp3[(10 + size)...])
  }

  private func languageTextPayload(
    encoding: UInt8,
    language: String,
    description: String,
    text: String,
    utf16BigEndian: Bool = false
  ) -> Data {
    var payload = Data([encoding])
    payload.append(Data(language.utf8))
    switch encoding {
    case 0:
      payload.append(description.data(using: .isoLatin1)!)
      payload.append(0)
      payload.append(text.data(using: .isoLatin1)!)
    case 1:
      payload.append(contentsOf: utf16BigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE])
      payload.append(utf16(description, bigEndian: utf16BigEndian))
      payload.append(contentsOf: [0, 0])
      payload.append(utf16(text, bigEndian: utf16BigEndian))
    case 2:
      payload.append(utf16(description, bigEndian: true))
      payload.append(contentsOf: [0, 0])
      payload.append(utf16(text, bigEndian: true))
    default:
      payload.append(Data(description.utf8))
      payload.append(0)
      payload.append(Data(text.utf8))
    }
    return payload
  }

  private func malformedLanguageTextPayload(version: Int) -> Data {
    if version == 4 {
      return Data([1]) + Data("eng".utf8) + Data([0xFF])
    }
    return Data([version == 2 ? 3 : 2]) + Data("eng".utf8) + Data([0])
  }

  private func utf16(_ value: String, bigEndian: Bool) -> Data {
    var data = Data()
    for unit in value.utf16 {
      data.append(UInt8(bigEndian ? unit >> 8 : unit & 0xFF))
      data.append(UInt8(bigEndian ? unit & 0xFF : unit >> 8))
    }
    return data
  }
}
