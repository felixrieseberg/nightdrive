import Foundation
import Testing

@testable import Nightdrive

struct ITunesDBTests {
  private func sampleTrack(
    title: String, artist: String, album: String, path: String
  ) -> ITDBTrack {
    var t = ITDBTrack()
    t.title = title
    t.artist = artist
    t.album = album
    t.genre = "Electronic"
    t.ipodPath = path
    t.sizeBytes = 4_567_890
    t.lengthMS = 214_000
    t.trackNumber = 3
    t.trackCount = 11
    t.year = 2004
    t.bitrate = 192
    t.samplerate = 44100
    t.rating = 80
    t.playCount = 7
    t.timeAdded = Date(timeIntervalSince1970: 1_100_000_000)
    return t
  }

  @Test
  func testRoundTrip() throws {
    var db = ITunesDatabase()
    db.masterPlaylistName = "Nightdrive Test"
    db.tracks = [
      sampleTrack(
        title: "Such Great Heights", artist: "The Postal Service",
        album: "Give Up", path: ":iPod_Control:Music:F00:ABCD.mp3"),
      sampleTrack(
        title: "Änglamark — übergroß", artist: "Ünïcode Ärtist",
        album: "日本語アルバム", path: ":iPod_Control:Music:F01:WXYZ.mp3"),
    ]
    var playlist = ITDBPlaylist(name: "Road Trip", isMaster: false)
    playlist.memberDbids = [db.tracks[1].dbid, db.tracks[0].dbid]
    db.playlists = [playlist]

    let data = ITunesDBWriter().write(db)
    let parsed = try ITunesDBReader().read(data)

    #expect(parsed.tracks.count == 2)
    #expect(parsed.masterPlaylistName == "Nightdrive Test")
    #expect(parsed.databaseID == db.databaseID)
    #expect(parsed.libraryPersistentID == db.libraryPersistentID)

    let first = parsed.tracks[0]
    #expect(first.title == "Such Great Heights")
    #expect(first.artist == "The Postal Service")
    #expect(first.album == "Give Up")
    #expect(first.genre == "Electronic")
    #expect(first.ipodPath == ":iPod_Control:Music:F00:ABCD.mp3")
    #expect(first.sizeBytes == 4_567_890)
    #expect(first.lengthMS == 214_000)
    #expect(first.trackNumber == 3)
    #expect(first.trackCount == 11)
    #expect(first.year == 2004)
    #expect(first.bitrate == 192)
    #expect(first.samplerate == 44100)
    #expect(first.rating == 80)
    #expect(first.playCount == 7)
    #expect(first.dbid == db.tracks[0].dbid)
    #expect(abs((first.timeAdded!.timeIntervalSince1970) - (db.tracks[0].timeAdded!.timeIntervalSince1970)) <= 1)

    let second = parsed.tracks[1]
    #expect(second.title == "Änglamark — übergroß")
    #expect(second.album == "日本語アルバム")

    #expect(parsed.playlists.count == 1)
    #expect(parsed.playlists[0].name == "Road Trip")
    #expect(parsed.playlists[0].memberDbids == playlist.memberDbids)
  }

  @Test
  func testClassicPlaybackStateRoundTripsInMhit() throws {
    let skipped = Date(timeIntervalSince1970: 1_300_000_000)
    var track = sampleTrack(
      title: "Playback", artist: "Artist", album: "Album",
      path: ":iPod_Control:Music:F00:PLAY.mp3")
    track.bookmarkMS = 98_765
    track.skipCount = 42
    track.lastSkipped = skipped
    var db = ITunesDatabase()
    db.timezoneShift = 19_800
    db.tracks = [track]

    let data = ITunesDBWriter().write(db)
    let mhit = try #require(DBBytes.mhitOffsets(in: data).first)
    #expect(DBBytes.u32(data, at: mhit + 0x6C) == 98_765)
    #expect(DBBytes.u32(data, at: mhit + 0x9C) == 42)
    #expect(
      DBBytes.u32(data, at: mhit + 0xA0)
        == UInt32(1_300_000_000 + Int(ITunesDBWriter.macEpochOffset) + db.timezoneShift))

    let parsed = try #require(ITunesDBReader().read(data).tracks.first)
    #expect(parsed.bookmarkMS == 98_765)
    #expect(parsed.skipCount == 42)
    #expect(parsed.lastSkipped == skipped)
  }

  @Test
  func testStructuralInvariants() throws {
    var db = ITunesDatabase()
    db.tracks = [
      sampleTrack(
        title: "A", artist: "B", album: "C", path: ":iPod_Control:Music:F00:AAAA.mp3")
    ]
    let data = ITunesDBWriter().write(db)
    let r = ByteReader(data)

    #expect(try r.tag(0) == "mhbd")
    #expect(try r.u32(4) == 244)
    #expect(Int(try r.u32(8)) == data.count)
    #expect(try r.u32(16) == 0x30)
    #expect(try r.u32(20) == 8)

    var pos = 244
    var types: [UInt32] = []
    while pos < data.count {
      #expect(try r.tag(pos) == "mhsd")
      types.append(try r.u32(pos + 12))
      pos += Int(try r.u32(pos + 8))
    }
    #expect(pos == data.count)
    #expect(types == [1, 3, 2, 4, 8, 6, 10, 5])
  }

  @Test
  func testByteReaderReadsDataSliceWithoutRebasingIndexes() throws {
    let bytes = Data([0xFF, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x41, 0x42, 0x43, 0x44])
    let data = bytes[1...]
    #expect(data.startIndex != 0)

    let reader = ByteReader(data)
    #expect(try reader.u8(0) == 0x34)
    #expect(try reader.u16(0) == 0x1234)
    #expect(try reader.u32(2) == 0x1234_5678)
    #expect(try reader.tag(6) == "ABCD")
    #expect(try reader.slice(2, 4) == Data([0x78, 0x56, 0x34, 0x12]))
  }

  @Test
  func testByteReaderRejectsOverflowingOffsets() {
    let reader = ByteReader(Data([0, 1, 2, 3]))
    #expect(throws: (any Error).self) { try reader.u32(Int.max) }
    #expect(throws: (any Error).self) { try reader.slice(Int.max, 1) }
  }

  @Test
  func testEmptyDatabaseRoundTrip() throws {
    let data = ITunesDBWriter().write(ITunesDatabase())
    let parsed = try ITunesDBReader().read(data)
    #expect(parsed.tracks.count == 0)
    #expect(parsed.playlists.count == 0)
  }

  @Test
  func testRejectsCorruptData() {
    #expect(throws: (any Error).self) { try ITunesDBReader().read(Data("not a database".utf8)) }
    #expect(throws: (any Error).self) { try ITunesDBReader().read(Data()) }

    var db = ITunesDatabase()
    db.tracks = [
      sampleTrack(
        title: "A", artist: "B", album: "C", path: ":iPod_Control:Music:F00:AAAA.mp3")
    ]
    var data = ITunesDBWriter().write(db)
    data = data.prefix(300)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(data) }
  }

  @Test
  func testRereadingOwnOutputIsStable() throws {
    var db = ITunesDatabase()
    db.tracks = [
      sampleTrack(
        title: "One", artist: "Artist", album: "Album",
        path: ":iPod_Control:Music:F00:AAAA.mp3"),
      sampleTrack(
        title: "Two", artist: "Artist", album: "Album",
        path: ":iPod_Control:Music:F01:BBBB.mp3"),
    ]
    let once = ITunesDBWriter().write(db)
    let parsed = try ITunesDBReader().read(once)
    let twice = ITunesDBWriter().write(parsed)
    #expect(once.count == twice.count)
    let reparsed = try ITunesDBReader().read(twice)
    #expect(reparsed.tracks.map(\.dbid) == parsed.tracks.map(\.dbid))
    #expect(reparsed.tracks.map(\.title) == parsed.tracks.map(\.title))
  }
}
