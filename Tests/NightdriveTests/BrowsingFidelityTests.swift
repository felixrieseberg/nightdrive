import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct BrowsingFidelityTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private func makeLibraryTrack(
    title: String = "Song", artist: String = "", album: String = "",
    composer: String = "", albumArtist: String = ""
  ) -> LibraryTrack {
    var track = LibraryTrack(
      url: URL(fileURLWithPath: "/tmp/song.mp3"), title: title, artist: artist, album: album, composer: composer,
      trackNumber: 1, year: 2000, durationMS: 1000, sizeBytes: 1000, bitrate: 128, samplerate: 44100)
    track.albumArtist = albumArtist
    return track
  }

  @Test
  func testArticleStripping() {
    #expect(SortNames.strippingLeadingArticle("The Beatles") == "Beatles")
    #expect(SortNames.strippingLeadingArticle("A Perfect Circle") == "Perfect Circle")
    #expect(SortNames.strippingLeadingArticle("An Awesome Wave") == "Awesome Wave")
    #expect(SortNames.strippingLeadingArticle("THE WHO") == "WHO")
    #expect(SortNames.strippingLeadingArticle("Theodore") == "Theodore")
    #expect(SortNames.strippingLeadingArticle("Radiohead") == "Radiohead")
    #expect(SortNames.strippingLeadingArticle("The") == "The")
  }

  @Test
  func testSortValueDerivation() {
    #expect(SortNames.sortValue(display: "The Beatles", explicit: nil) == "Beatles")
    #expect(SortNames.sortValue(display: "Radiohead", explicit: nil) == nil)
    #expect(SortNames.sortValue(display: "The Beatles", explicit: "Fab Four") == "Fab Four")
    #expect(SortNames.sortValue(display: "Radiohead", explicit: "Radiohead") == nil)
    #expect(SortNames.sortValue(display: nil, explicit: nil) == nil)
  }

  @Test
  func testMakeDBTrackDerivesSortFields() {
    var track = makeLibraryTrack(
      title: "The Look of Love", artist: "The Beatles", album: "A Hard Day's Night",
      composer: "Composer", albumArtist: "The Beatles")
    track.sortComposer = "Explicit, Composer"
    let db = SyncEngine.makeDBTrack(from: track, ipodPath: ":iPod_Control:Music:F00:A.mp3")
    #expect(db.sortTitle == "Look of Love")
    #expect(db.sortArtist == "Beatles")
    #expect(db.sortAlbum == "Hard Day's Night")
    #expect(db.sortAlbumArtist == "Beatles")
    #expect(db.sortComposer == "Explicit, Composer")

    let plain = makeLibraryTrack(title: "Karma Police", artist: "Radiohead")
    let plainDB = SyncEngine.makeDBTrack(from: plain, ipodPath: ":A.mp3")
    #expect(plainDB.sortTitle == nil)
    #expect(plainDB.sortArtist == nil)
  }

  @Test
  func testMetadataLoaderReadsSortTags() async throws {
    let dir = scratch
    var tags = MP3Builder.Tags(
      title: "The Song", artist: "The Beatles", album: "The Album",
      genre: "Rock", trackNumber: 1, year: 2001)
    tags.sortTitle = "Song, The"
    tags.sortArtist = "Beatles, The"
    tags.sortAlbum = "Album, The"
    let url = dir.appendingPathComponent("sorted.mp3")
    try MP3Builder.build(tags: tags, seconds: 1).write(to: url)

    let track = await MetadataLoader.load(url: url)
    #expect(track.sortTitle == "Song, The")
    #expect(track.sortArtist == "Beatles, The")
    #expect(track.sortAlbum == "Album, The")
  }

  @Test
  func testMakeDBTrackMapsMediaKinds() {
    var song = makeLibraryTrack()
    song.mediaKind = .song
    let songDB = SyncEngine.makeDBTrack(from: song, ipodPath: ":A.mp3")
    #expect(songDB.mediaKind == 1)
    #expect(!(songDB.rememberPlaybackPosition))
    #expect(!(songDB.skipWhenShuffling))

    var book = makeLibraryTrack()
    book.mediaKind = .audiobook
    let bookDB = SyncEngine.makeDBTrack(from: book, ipodPath: ":A.m4b")
    #expect(bookDB.mediaKind == 8)
    #expect(bookDB.rememberPlaybackPosition)
    #expect(bookDB.skipWhenShuffling)

    var cast = makeLibraryTrack()
    cast.mediaKind = .podcast
    let castDB = SyncEngine.makeDBTrack(from: cast, ipodPath: ":A.mp3")
    #expect(castDB.mediaKind == 4)
    #expect(castDB.rememberPlaybackPosition)
    #expect(castDB.skipWhenShuffling)
  }

  @Test
  func testMetadataLoaderDetectsMediaKind() async throws {
    let dir = scratch
    let podcastTags = MP3Builder.Tags(
      title: "Episode 1", artist: "Host", album: "Show",
      genre: "Podcast", trackNumber: 1, year: 2020)
    let podcastURL = dir.appendingPathComponent("episode.mp3")
    try MP3Builder.build(tags: podcastTags, seconds: 1).write(to: podcastURL)
    let podcast = await MetadataLoader.load(url: podcastURL)
    #expect(podcast.mediaKind == .podcast)

    let bookURL = dir.appendingPathComponent("book.m4b")
    try Data([0x00]).write(to: bookURL)
    let book = await MetadataLoader.load(url: bookURL)
    #expect(book.mediaKind == .audiobook)

    let songTags = MP3Builder.Tags(
      title: "Song", artist: "Artist", album: "Album",
      genre: "Rock", trackNumber: 1, year: 2020)
    let songURL = dir.appendingPathComponent("song.mp3")
    try MP3Builder.build(tags: songTags, seconds: 1).write(to: songURL)
    let song = await MetadataLoader.load(url: songURL)
    #expect(song.mediaKind == .song)
  }

  @Test
  func testMetadataLoaderClassifiesAudiobookGenreAsAudiobook() async throws {
    let dir = scratch
    for (index, genre) in ["Audiobook", "audiobooks", "Fantasy; Audiobook"].enumerated() {
      let tags = MP3Builder.Tags(
        title: "Chapter \(index)", artist: "Narrator", album: "The Book",
        genre: genre, trackNumber: 1, year: 2020)
      let url = dir.appendingPathComponent("chapter-\(index).mp3")
      try MP3Builder.build(tags: tags, seconds: 1).write(to: url)
      let book = await MetadataLoader.load(url: url)
      #expect(book.mediaKind == .audiobook, Comment(rawValue: "genre \(genre)"))
    }
  }

  @Test
  func testScanMP3ReadsLAMEGaplessFields() {
    let tags = MP3Builder.Tags(
      title: "Gapless", artist: "Artist", album: "Album",
      genre: "Rock", trackNumber: 1, year: 2020)
    let musicFrames = 40
    let seconds = (Double(musicFrames) + 0.5) * 1152.0 / 44100.0
    let data = MP3Builder.build(
      tags: tags, seconds: seconds,
      gapless: MP3Builder.Gapless(encoderDelay: 576, encoderPadding: 1728))

    let info = try! #require(GaplessScanner.scanMP3(data))
    #expect(info.pregap == 576)
    #expect(info.postgap == 1728)
    #expect(info.sampleCount == 44928)
    #expect(info.gaplessData == UInt32(417 * (41 - 8)))
  }

  @Test
  func testScanMP3WithoutLAMETagYieldsNothing() {
    let tags = MP3Builder.Tags(
      title: "Plain", artist: "Artist", album: "Album",
      genre: "Rock", trackNumber: 1, year: 2020)
    let data = MP3Builder.build(tags: tags, seconds: 1)
    #expect(GaplessScanner.scanMP3(data) == nil)
    #expect(GaplessScanner.scanMP3(Data()) == nil)
    #expect(GaplessScanner.scanMP3(Data(repeating: 0xFF, count: 128)) == nil)
  }

  @Test
  func testParseITunSMPB() {
    let value =
      " 00000000 00000840 000001C4 0000000000B18E00 00000000 00000000"
      + " 00000000 00000000 00000000 00000000 00000000 00000000"
    let info = try! #require(GaplessScanner.parseITunSMPB(value))
    #expect(info.pregap == 0x840)
    #expect(info.postgap == 0x1C4)
    #expect(info.sampleCount == 0xB1_8E00)
    #expect(info.gaplessData == 0)

    #expect(GaplessScanner.parseITunSMPB("") == nil)
    #expect(GaplessScanner.parseITunSMPB("garbage") == nil)
    #expect(GaplessScanner.parseITunSMPB("00000000 XYZ 000001C4 00B18E00") == nil)
    #expect(GaplessScanner.parseITunSMPB("00000000 00000000 000001C4 00B18E00") == nil)
    #expect(GaplessScanner.parseITunSMPB("00000000 00000840 000001C4 0000000000000000") == nil)
  }

  @Test
  func testMakeMP3InfoRejectsOutOfRangeValues() {
    #expect(
      GaplessScanner.makeMP3Info(delay: 576, padding: 1728, sampleCount: 44928, gaplessData: 13761)
        == GaplessInfo(pregap: 576, postgap: 1728, sampleCount: 44928, gaplessData: 13761))
    #expect(
      GaplessScanner.makeMP3Info(
        delay: 576, padding: 1728, sampleCount: 44928,
        gaplessData: Int64(UInt32.max) + 1) == nil)
    #expect(
      GaplessScanner.makeMP3Info(
        delay: 576, padding: 1728, sampleCount: 44928,
        gaplessData: Int64(UInt32.max)) != nil)
    #expect(GaplessScanner.makeMP3Info(delay: 0, padding: 1728, sampleCount: 44928, gaplessData: 1) == nil)
    #expect(GaplessScanner.makeMP3Info(delay: 576, padding: 0, sampleCount: 44928, gaplessData: 1) == nil)
    #expect(GaplessScanner.makeMP3Info(delay: 576, padding: 1728, sampleCount: -1, gaplessData: 1) == nil)
    #expect(GaplessScanner.makeMP3Info(delay: 576, padding: 1728, sampleCount: 44928, gaplessData: 0) == nil)
  }

  @Test
  func testMakeDBTrackMapsGapless() {
    var track = makeLibraryTrack()
    track.gapless = GaplessInfo(
      pregap: 576, postgap: 1728, sampleCount: 44928, gaplessData: 13761)
    let db = SyncEngine.makeDBTrack(from: track, ipodPath: ":A.mp3")
    #expect(db.pregap == 576)
    #expect(db.postgap == 1728)
    #expect(db.sampleCount == 44928)
    #expect(db.gaplessData == 13761)
    #expect(db.gaplessTrackFlag)

    let plain = SyncEngine.makeDBTrack(from: makeLibraryTrack(), ipodPath: ":A.mp3")
    #expect(plain.pregap == 0)
    #expect(!(plain.gaplessTrackFlag))
  }

  @Test
  func testSoundcheckFormula() {
    #expect(LoudnessAnalyzer.soundcheckValue(gainDB: 0) == 1000)
    #expect(LoudnessAnalyzer.soundcheckValue(gainDB: -10) == 10000)
    #expect(LoudnessAnalyzer.soundcheckValue(gainDB: 10) == 100)
    #expect(LoudnessAnalyzer.soundcheckValue(gainDB: 5) == 316)
    #expect(LoudnessAnalyzer.soundcheckValue(gainDB: 60) > 0)
    #expect(
      LoudnessAnalyzer.soundcheckValue(gainDB: -60)
        == LoudnessAnalyzer.soundcheckValue(gainDB: -LoudnessAnalyzer.maxGainDB))
  }

  private func writeSineFile(
    to url: URL, amplitude: Float, seconds: Double = 2.0, frequency: Double = 997
  ) throws {
    let sampleRate = 44_100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let file = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
      ])
    let frames = AVAudioFrameCount(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for i in 0..<Int(frames) {
      let sample = amplitude * Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
      buffer.floatChannelData![0][i] = sample
      buffer.floatChannelData![1][i] = 0
    }
    try file.write(from: buffer)
  }

  @Test
  func testLoudnessMeasurement() throws {
    let dir = scratch
    let loud = dir.appendingPathComponent("loud.caf")
    let quiet = dir.appendingPathComponent("quiet.caf")
    try writeSineFile(to: loud, amplitude: 1.0)
    try writeSineFile(to: quiet, amplitude: 0.1)

    let loudLUFS = try #require(LoudnessAnalyzer.measureLoudness(url: loud))
    #expect(abs((loudLUFS) - (-3.0)) <= 1.5)

    let quietLUFS = try #require(LoudnessAnalyzer.measureLoudness(url: quiet))
    #expect(abs((loudLUFS - quietLUFS) - (20.0)) <= 0.2)

    let gain = try #require(LoudnessAnalyzer.measureGain(url: loud))
    #expect(abs((gain) - (LoudnessAnalyzer.referenceLUFS - loudLUFS)) <= 0.001)
    #expect(abs(gain) <= LoudnessAnalyzer.maxGainDB)

    let silent = dir.appendingPathComponent("silent.mp3")
    let tags = MP3Builder.Tags(
      title: "S", artist: "A", album: "L", genre: "G", trackNumber: 1, year: 2020)
    try MP3Builder.build(tags: tags, seconds: 1).write(to: silent)
    #expect(LoudnessAnalyzer.measureLoudness(url: silent) == nil)
  }

  @Test
  func testLoudnessStoreCachesAndInvalidates() throws {
    let dir = scratch
    let store = LoudnessStore(directory: dir.appendingPathComponent("cache"))
    let source = dir.appendingPathComponent("tone.caf")
    try writeSineFile(to: source, amplitude: 0.5, seconds: 0.5)

    #expect(store.cachedGain(forSource: source) == nil)
    let measured = try #require(store.gain(forSource: source))
    #expect(store.cachedGain(forSource: source) == measured)
    #expect(store.gain(forSource: source) == measured)

    try writeSineFile(to: source, amplitude: 0.5, seconds: 0.6)
    #expect(store.cachedGain(forSource: source) == nil)
  }

  @Test
  func testLoudnessStoreInvalidatesSameSizeRewriteWithinOneSecond() throws {
    let dir = scratch
    let store = LoudnessStore(directory: dir.appendingPathComponent("cache"))
    let source = dir.appendingPathComponent("source.bin")
    let firstBytes = Data("first".utf8)
    let secondBytes = Data("other".utf8)
    let firstDate = Date(timeIntervalSince1970: 1_700_000_000.125)
    let secondDate = Date(timeIntervalSince1970: 1_700_000_000.875)

    try firstBytes.write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: firstDate], ofItemAtPath: source.path)
    let firstAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let firstModified = try #require(firstAttributes[.modificationDate] as? Date)
    store.store(gain: 4.25, forSource: source)
    #expect(store.cachedGain(forSource: source) == 4.25)

    try secondBytes.write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: secondDate], ofItemAtPath: source.path)
    let secondAttributes = try FileManager.default.attributesOfItem(atPath: source.path)
    let secondModified = try #require(secondAttributes[.modificationDate] as? Date)

    #expect(firstAttributes[.size] as? Int == secondAttributes[.size] as? Int)
    #expect(Int(firstModified.timeIntervalSince1970) == Int(secondModified.timeIntervalSince1970))
    #expect(firstModified.timeIntervalSince1970.bitPattern != secondModified.timeIntervalSince1970.bitPattern)
    #expect(
      store.cachedGain(forSource: source) == nil,
      Comment(rawValue: "a same-size rewrite within one second must not reuse the previous file's gain"))
  }

  @Test
  func testLoudnessStoreRemeasuresInPlaceRewriteWithExactSameStat() throws {
    let dir = scratch
    let cache = dir.appendingPathComponent("cache")
    let source = dir.appendingPathComponent("source.bin")
    let original = Data("first".utf8)
    let replacement = Data("other".utf8)
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try original.write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: source.path)
    let originalStamp = try #require(FileGenerationStamp(url: source))

    let observations = Mutex<[Data]>([])
    let store = LoudnessStore(
      directory: cache,
      measureGain: { analyzedURL in
        guard let bytes = try? Data(contentsOf: analyzedURL) else { return nil }
        observations.withLock { $0.append(bytes) }
        return bytes == original ? -4.0 : 2.0
      })
    #expect(store.gain(forSource: source) == -4.0)

    try replacement.write(to: source)
    let replacementStamp = try pinnedGenerationStamp(
      at: source, distinctFrom: originalStamp, modificationDate: pinnedDate)
    #expect(replacementStamp.inode == originalStamp.inode)
    #expect(replacementStamp.sizeBytes == originalStamp.sizeBytes)
    #expect(replacementStamp.modificationSeconds == originalStamp.modificationSeconds)
    #expect(replacementStamp.modificationNanoseconds == originalStamp.modificationNanoseconds)
    #expect(replacementStamp != originalStamp)

    #expect(store.cachedGain(forSource: source) == nil)
    #expect(store.gain(forSource: source) == 2.0)
    #expect(observations.withLock { $0 } == [original, replacement])
  }

  @Test
  func testLoudnessStoreDoesNotCacheOldMeasurementForReplacementFile() throws {
    let dir = scratch
    let cache = dir.appendingPathComponent("cache")
    let source = dir.appendingPathComponent("source.bin")
    let original = Data("first".utf8)
    let replacement = Data("other".utf8)
    let originalDate = Date(timeIntervalSince1970: 1_700_000_000.125)
    let replacementDate = Date(timeIntervalSince1970: 1_700_000_001.125)
    try original.write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: source.path)

    let observations = Mutex<[Data]>([])
    let store = LoudnessStore(
      directory: cache,
      measureGain: { analyzedURL in
        guard let bytes = try? Data(contentsOf: analyzedURL) else { return nil }
        observations.withLock { $0.append(bytes) }
        if bytes == original {
          try! replacement.write(to: analyzedURL)
          try! FileManager.default.setAttributes(
            [.modificationDate: replacementDate], ofItemAtPath: analyzedURL.path)
          return -7.0
        }
        return bytes == replacement ? 3.5 : nil
      })

    #expect(store.gain(forSource: source) == 3.5)
    #expect(observations.withLock { $0 } == [original, replacement])
    #expect(store.cachedGain(forSource: source) == 3.5)

    try original.write(to: source)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate], ofItemAtPath: source.path)
    #expect(store.cachedGain(forSource: source) == nil)
  }

  @Test
  func testCapturedSourceGainReusesOriginalCacheAcrossSnapshotPaths() async throws {
    let dir = scratch
    let cache = dir.appendingPathComponent("cache")
    let store = LoudnessStore(directory: cache)
    let source = dir.appendingPathComponent("tone.caf")
    try writeSineFile(to: source, amplitude: 0.5, seconds: 0.5)

    let firstArea = try OutboundSnapshotArea.create(libraryFolder: dir)
    let firstSnapshot = try OutboundSourceSnapshot.create(
      from: source, in: dir, area: firstArea)
    let first = try #require(
      store.gain(
        forCapturedSource: source,
        fileGenerationStamp: firstSnapshot.fileGenerationStamp,
        measuring: firstSnapshot.url))
    #expect(store.cachedGain(forSource: source) == first)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1)
    firstSnapshot.remove()
    firstArea.remove()

    let secondArea = try OutboundSnapshotArea.create(libraryFolder: dir)
    let secondSnapshot = try OutboundSourceSnapshot.create(
      from: source, in: dir, area: secondArea)
    #expect(
      store.gain(
        forCapturedSource: source,
        fileGenerationStamp: secondSnapshot.fileGenerationStamp,
        measuring: secondSnapshot.url) == first)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: cache.path).count == 1,
      Comment(rawValue: "UUID snapshot paths must not create persistent loudness-cache keys"))
    secondSnapshot.remove()
    secondArea.remove()
  }

  @Test
  func testMakeDBTrackMapsSoundcheck() {
    var track = makeLibraryTrack()
    track.gainDB = -3.0
    let db = SyncEngine.makeDBTrack(from: track, ipodPath: ":A.mp3")
    #expect(db.soundcheck == UInt32((1000.0 * pow(10.0, 0.3)).rounded()))
    let plain = SyncEngine.makeDBTrack(from: makeLibraryTrack(), ipodPath: ":A.mp3")
    #expect(plain.soundcheck == 0)
  }

  private func fidelityTrack() -> ITDBTrack {
    var t = ITDBTrack()
    t.title = "The Song"
    t.artist = "The Beatles"
    t.album = "Album"
    t.composer = "Composer"
    t.ipodPath = ":iPod_Control:Music:F00:AAAA.mp3"
    t.sortTitle = "Song, The"
    t.sortArtist = "Beatles"
    t.sortAlbumArtist = "Beatles"
    t.mediaKind = ITDBMediaKind.audiobook.rawValue
    t.rememberPlaybackPosition = true
    t.skipWhenShuffling = true
    t.pregap = 576
    t.postgap = 1728
    t.sampleCount = 44928
    t.gaplessData = 13761
    t.gaplessTrackFlag = true
    t.soundcheck = 1259
    return t
  }

  private func assertFidelityFields(_ track: ITDBTrack) {
    #expect(track.sortTitle == "Song, The")
    #expect(track.sortArtist == "Beatles")
    #expect(track.sortAlbumArtist == "Beatles")
    #expect(track.sortAlbum == nil)
    #expect(track.sortComposer == nil)
    #expect(track.mediaKind == 8)
    #expect(track.rememberPlaybackPosition)
    #expect(track.skipWhenShuffling)
    #expect(track.pregap == 576)
    #expect(track.postgap == 1728)
    #expect(track.sampleCount == 44928)
    #expect(track.gaplessData == 13761)
    #expect(track.gaplessTrackFlag)
    #expect(!(track.gaplessAlbumFlag))
    #expect(track.soundcheck == 1259)
  }

  @Test
  func testFidelityFieldsRoundTrip() throws {
    var db = ITunesDatabase()
    db.tracks = [fidelityTrack()]
    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    #expect(parsed.tracks.count == 1)
    assertFidelityFields(parsed.tracks[0])
    #expect(parsed.tracks[0].preservedMhods.isEmpty)
  }

  private func mhodTypes(in data: Data, mhit: Int) -> [UInt32] {
    let headerLen = Int(DBBytes.u32(data, at: mhit + 4))
    let count = Int(DBBytes.u32(data, at: mhit + 12))
    var pos = mhit + headerLen
    var types: [UInt32] = []
    for _ in 0..<count {
      types.append(DBBytes.u32(data, at: pos + 12))
      pos += Int(DBBytes.u32(data, at: pos + 8))
    }
    return types
  }

  @Test
  func testPreservedRewriteReplacesSortMhodsWithoutDuplication() throws {
    var db = ITunesDatabase()
    db.tracks = [fidelityTrack()]
    let firstWrite = ITunesDBWriter().write(db)

    var imported = try ITunesDBReader().read(firstWrite)
    #expect(imported.tracks[0].preservedMhitHeader != nil)
    imported.tracks[0].sortTitle = "Retitled"
    let secondWrite = ITunesDBWriter().write(imported)
    let reparsed = try ITunesDBReader().read(secondWrite)
    let thirdWrite = ITunesDBWriter().write(reparsed)

    #expect(reparsed.tracks[0].sortTitle == "Retitled")
    #expect(reparsed.tracks[0].sortArtist == "Beatles")
    #expect(reparsed.tracks[0].mediaKind == 8)
    #expect(reparsed.tracks[0].pregap == 576)
    #expect(reparsed.tracks[0].soundcheck == 1259)
    #expect(reparsed.tracks[0].gaplessTrackFlag)

    for bytes in [secondWrite, thirdWrite] {
      let mhits = DBBytes.mhitOffsets(in: bytes)
      #expect(mhits.count == 1)
      let types = mhodTypes(in: bytes, mhit: mhits[0])
      for sortType: UInt32 in [23, 27, 28, 29, 30] {
        #expect(
          types.filter { $0 == sortType }.count <= 1,
          Comment(rawValue: "sort mhod type \(sortType) duplicated: \(types)"))
      }
      #expect(types.filter { $0 == 27 }.count == 1)
      #expect(types.filter { $0 == 23 }.count == 1)
    }
  }

  @Test
  func testForeignSortMhodsSurviveWhenUnmodeled() throws {
    var db = ITunesDatabase()
    var track = fidelityTrack()
    track.sortComposer = "Composer, Sorted"
    db.tracks = [track]
    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    let rewritten = try ITunesDBReader().read(ITunesDBWriter().write(parsed))
    #expect(rewritten.tracks[0].sortComposer == "Composer, Sorted")
  }
}
