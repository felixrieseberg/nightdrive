import Foundation
import Testing

@testable import Nightdrive

struct ModernShuffleDatabaseTests {
  @Test
  func testRoundTripIncludesFirmwareTrackDataAndPlaylists() throws {
    let database = makeDatabase()

    let data = try ModernShuffleDatabaseFile.write(database)
    #expect((String(data: data.prefix(4), encoding: .ascii)) == ("bdhs"))
    #expect((data.count) == (964))
    #expect((DBBytes.u32(data, at: 32)) == (1))
    let pathField = data.subdata(in: 116..<(116 + 256))
    #expect((String(data: pathField.prefix { $0 != 0 }, encoding: .utf8)) == ("/iPod_Control/Music/F00/ONE.mp3"))

    let snapshot = try ModernShuffleDatabaseFile.read(data)
    #expect((snapshot.tracks.count) == (2))
    #expect((snapshot.tracksWithoutPodcastsOrAudiobooks) == (1))
    #expect(
      (snapshot.tracks.map(\.ipodPath))
        == ([
          ":iPod_Control:Music:F00:ONE.mp3", ":iPod_Control:Music:F01:TWO.m4a",
        ]))
    #expect((snapshot.tracks.map(\.filetype)) == ([1, 2]))
    #expect((snapshot.tracks.map(\.dbid)) == ([0x101, 0x202]))
    #expect((snapshot.tracks[0].volumeAdjustment) == (-15))
    #expect((snapshot.tracks[0].stopMS) == (12_345))
    #expect((snapshot.tracks[0].bookmarkMS) == (321))
    #expect(!(snapshot.tracks[0].playsWhenShuffling))
    #expect(snapshot.tracks[0].remembersPlaybackPosition)
    #expect(snapshot.tracks[0].gaplessAlbum)
    #expect((snapshot.tracks[0].pregap) == (0x123))
    #expect((snapshot.tracks[0].postgap) == (0x456))
    #expect((snapshot.tracks[0].sampleCount) == (789))
    #expect((snapshot.tracks[0].gaplessData) == (0xAABBCCDD))
    #expect((snapshot.tracks[0].trackNumber) == (7))
    #expect((snapshot.tracks[0].discNumber) == (2))
    #expect(
      (snapshot.playlists)
        == ([
          .init(dbid: 0, type: 1, trackIndexes: [0, 1]),
          .init(dbid: 0x303, type: 2, trackIndexes: [1]),
        ]))
    #expect(ModernShuffleDatabaseFile.matches(data, database: database))
  }

  @Test
  func testRejectsCorruptChunksAndMissingTracks() throws {
    #expect(throws: (any Error).self) { try ModernShuffleDatabaseFile.read(Data([1, 2, 3])) }

    let valid = try ModernShuffleDatabaseFile.write(makeDatabase())
    var badTrackOffset = valid
    DBBytes.patchU32(&badTrackOffset, at: 84, 999)
    #expect(throws: (any Error).self) { try ModernShuffleDatabaseFile.read(badTrackOffset) }

    var badPlaylistMember = valid
    let playlistHeaderOffset = Int(DBBytes.u32(valid, at: 40))
    let secondPlaylistOffset = Int(DBBytes.u32(valid, at: playlistHeaderOffset + 24))
    DBBytes.patchU32(&badPlaylistMember, at: secondPlaylistOffset + 44, 99)
    #expect(throws: (any Error).self) { try ModernShuffleDatabaseFile.read(badPlaylistMember) }

    #expect(throws: (any Error).self) { try ModernShuffleDatabaseFile.read(Data(valid.dropLast())) }
  }

  private func makeDatabase() -> ITunesDatabase {
    var first = ITDBTrack()
    first.dbid = 0x101
    first.ipodPath = ":iPod_Control:Music:F00:ONE.mp3"
    first.artist = "Artist One"
    first.album = "Album One"
    first.lengthMS = 12_345
    first.volumeAdjustment = -15
    first.bookmarkMS = 321
    first.skipWhenShuffling = true
    first.rememberPlaybackPosition = true
    first.gaplessAlbumFlag = true
    first.pregap = 0x123
    first.postgap = 0x456
    first.sampleCount = 789
    first.gaplessData = 0xAABBCCDD
    first.trackNumber = 7
    first.discNumber = 2

    var second = ITDBTrack()
    second.dbid = 0x202
    second.ipodPath = ":iPod_Control:Music:F01:TWO.m4a"
    second.artist = "Artist Two"
    second.album = "Album Two"
    second.filetypeMarker = 0x4D34_4120
    second.mediaKind = ITDBMediaKind.audiobook.rawValue

    var database = ITunesDatabase()
    database.tracks = [first, second]
    database.playlists = [
      ITDBPlaylist(
        name: "Second song", isMaster: false, persistentID: 0x303,
        memberDbids: [second.dbid])
    ]
    return database
  }
}

@Suite(.tags(.fakeIpod))
struct ModernShuffleSyncTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture(
      folderName: "FAKEMODERNSHUFFLE", modelNumber: "MC584")
  }

  @Test
  func testRecognizesAllModernShuffleGenerationsAndCapabilities() throws {
    for model in ["MB867", "MC164LL/A", "MC381", "MC584", "MD780", "MKMJ2LL/A"] {
      #expect((IpodDeviceFamily(modelNumber: model)) == (.modernShuffle), Comment(rawValue: model))
    }
    for model in ["M9725", "MA949", "MB681", "MC167"] {
      #expect((IpodDeviceFamily(modelNumber: model)) == (.shuffle), Comment(rawValue: model))
    }
    #expect(IpodDeviceFamily.modernShuffle.isShuffle)
    #expect(IpodDeviceFamily.modernShuffle.playsAAC)
    #expect(IpodDeviceFamily.modernShuffle.supportsDevicePlaylists)
    #expect(!(IpodDeviceFamily.shuffle.supportsDevicePlaylists))
    #expect((fs.deviceFamily()) == (.modernShuffle))
    #expect((fs.modelDescription()) == ("iPod shuffle (4th generation)"))

    try setModelNumber("UNKNOWN")
    try ModernShuffleDatabaseFile.write(ITunesDatabase()).write(to: fs.shuffleDatabaseURL)
    #expect((fs.deviceFamily()) == (.modernShuffle), Comment(rawValue: "iTunesSD should provide a safe fallback"))
  }

  @Test
  func testSyncWritesModernPlayOrderAndPlaylistIdempotently() async throws {
    let first = try writeLibraryMP3(filename: "one.mp3", title: "One")
    let second = try writeLibraryMP3(filename: "two.mp3", title: "Two")
    let playlists = [
      LocalPlaylist(name: "Reverse", trackIDs: [second, first].map(TrackID.init(url:)))
    ]

    let result = try await runSync(try await makePlan(deviceFamily: .modernShuffle, localPlaylists: playlists))
    #expect((result.copiedToDevice) == (2))
    #expect((result.failures) == ([]))
    #expect(result.syncedPlaylists)
    #expect((result.playlistsCreatedOnDevice) == (1))
    #expect((result.artworkImagesWritten) == (0))
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDBURL.path)))

    let database = try fs.readDatabase()
    let devicePlaylist = try #require(database.playlists.first { $0.name == "Reverse" })
    #expect((devicePlaylist.memberDbids) == (result.playlistLinks.first?.memberDbids))

    let shuffleData = try Data(contentsOf: fs.shuffleDatabaseURL)
    let snapshot = try ModernShuffleDatabaseFile.read(shuffleData)
    #expect((snapshot.tracks.count) == (2))
    #expect((snapshot.playlists.count) == (2))
    #expect((snapshot.playlists[0].type) == (1))
    let indexesByDbid = Dictionary(
      uniqueKeysWithValues: snapshot.tracks.enumerated().map { ($0.element.dbid, UInt32($0.offset)) })
    #expect((snapshot.playlists[1].trackIndexes) == (devicePlaylist.memberDbids.compactMap { indexesByDbid[$0] }))
    #expect((snapshot) == (try ModernShuffleDatabaseFile.read(ModernShuffleDatabaseFile.write(database))))
    #expect(fs.shuffleDatabaseMatches(database))

    if let databaseID = result.databaseID {
      let outcome = PlaylistSyncApplier.apply(result: result, to: playlists)
      try await SyncEngine.writePlaylistLinks(
        outcome.links, databaseID: databaseID, libraryFolder: libraryDir)
    }
    let secondPlan = try await makePlan(
      deviceFamily: .modernShuffle, localPlaylists: playlists)
    #expect(secondPlan.isEmpty, Comment(rawValue: "second plan must be empty: \(secondPlan)"))
    let secondResult = try await runSync(secondPlan)
    #expect((secondResult.failures) == ([]))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (shuffleData))
  }
}
