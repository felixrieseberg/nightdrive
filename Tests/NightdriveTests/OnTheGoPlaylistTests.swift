import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct OnTheGoPlaylistTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  @Test
  func testParsesValidFile() throws {
    #expect((try OnTheGoPlaylist.parseIndices(otgData(indices: [2, 0, 1]))) == ([2, 0, 1]))
  }

  @Test
  func testParsesEmptyFile() throws {
    #expect((try OnTheGoPlaylist.parseIndices(otgData(indices: []))) == ([]))
  }

  @Test
  func testRejectsTruncatedHeader() {
    do {
      let caughtError = #expect(throws: (any Error).self) { try OnTheGoPlaylist.parseIndices(Data("mhpo".utf8)) }
      if let caughtError {
        #expect((caughtError as? OnTheGoPlaylist.ParseError) == (.truncated))
      }
    }
  }

  @Test
  func testRejectsTruncatedEntries() {
    let data = otgData(indices: [5], entryCount: 3)
    do {
      let caughtError = #expect(throws: (any Error).self) { try OnTheGoPlaylist.parseIndices(data) }
      if let caughtError {
        #expect((caughtError as? OnTheGoPlaylist.ParseError) == (.truncated))
      }
    }
  }

  @Test
  func testRejectsBadMagic() {
    var data = otgData(indices: [1])
    data.replaceSubrange(0..<4, with: Data("mhbd".utf8))
    do {
      let caughtError = #expect(throws: (any Error).self) { try OnTheGoPlaylist.parseIndices(data) }
      if let caughtError {
        #expect((caughtError as? OnTheGoPlaylist.ParseError) == (.badMagic))
      }
    }
  }

  @Test
  func testOutOfRangeIndicesAreDroppedIndividually() {
    var tracks: [ITDBTrack] = []
    for title in ["A", "B"] {
      var track = ITDBTrack()
      track.title = title
      tracks.append(track)
    }
    let resolved = OnTheGoPlaylist.resolve(indices: [1, 7, 0], tracks: tracks)
    #expect((resolved.dbids) == ([tracks[1].dbid, tracks[0].dbid]))
    #expect((resolved.droppedIndexCount) == (1))
  }

  @Test
  func testFileNameRecognitionAndOrdering() {
    #expect(OnTheGoPlaylist.isPlaylistFileName("OTGPlaylistInfo"))
    #expect(OnTheGoPlaylist.isPlaylistFileName("OTGPlaylistInfo_1"))
    #expect(OnTheGoPlaylist.isPlaylistFileName("OTGPlaylistInfo_12"))
    #expect(!(OnTheGoPlaylist.isPlaylistFileName("OTGPlaylistInfo_")))
    #expect(!(OnTheGoPlaylist.isPlaylistFileName("OTGPlaylistInfo_x")))
    #expect(!(OnTheGoPlaylist.isPlaylistFileName("iTunesDB")))
  }

  private func seedDeviceTracks(_ count: Int) throws -> ITunesDatabase {
    var db = ITunesDatabase()
    for index in 0..<count {
      let dest = try fs.destinationForNewFile(extension: "mp3")
      let data = MP3Builder.build(
        tags: .init(
          title: "Device Song \(index)", artist: "Ipod Artist", album: "Device Album",
          genre: "Pop", trackNumber: index + 1, year: 2003),
        seconds: 2)
      try data.write(to: dest)
      var track = ITDBTrack()
      track.title = "Device Song \(index)"
      track.artist = "Ipod Artist"
      track.trackNumber = UInt32(index + 1)
      track.ipodPath = fs.ipodPath(for: dest)
      track.sizeBytes = UInt32(data.count)
      track.lengthMS = 2000
      db.tracks.append(track)
    }
    try fs.writeDatabase(db)
    return db
  }

  @discardableResult
  private func sync() async throws -> SyncResult {
    let result = try await runSync(try await makePlan(localPlaylists: localPlaylists))
    try await applyLocalPlaylistSyncEffects(result)
    return result
  }

  @Test
  func testOnTheGoFileIsImportedThenDeleted() async throws {
    let db = try seedDeviceTracks(3)
    let otgURL = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try otgData(indices: [2, 0]).write(to: otgURL)

    let result = try await sync()
    #expect((result.copiedToFolder) == (3))
    #expect((result.onTheGoImports.count) == (1))
    #expect((result.onTheGoImports[0].name) == ("On-The-Go 1"))

    let imported = try #require(localPlaylists.first { $0.name == "On-The-Go 1" })
    #expect((imported.trackIDs.count) == (2))
    let entries = SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
    let urlByDbid = Dictionary(
      entries.map { ($0.dbid, libraryDir.appendingPathComponent($0.relativePath)) },
      uniquingKeysWith: { first, _ in first })
    #expect(
      (imported.trackIDs)
        == ([db.tracks[2].dbid, db.tracks[0].dbid].compactMap { urlByDbid[$0] }
          .map(TrackID.init(url:))))
    #expect(
      !(FileManager.default.fileExists(atPath: otgURL.path)),
      Comment(rawValue: "the consumed On-The-Go file must be deleted after the import is persisted"))
  }

  @Test
  func testMalformedOnTheGoFileIsIgnoredWithNoteAndKept() async throws {
    _ = try seedDeviceTracks(1)
    let otgURL = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try Data("garbage".utf8).write(to: otgURL)

    let result = try await sync()
    #expect((result.failures) == ([]), Comment(rawValue: "a malformed OTG file must never fail the sync"))
    #expect(result.onTheGoImports.isEmpty)
    #expect(
      result.playlistNotes.contains { $0.contains("malformed") }, Comment(rawValue: "got \(result.playlistNotes)"))
    #expect(FileManager.default.fileExists(atPath: otgURL.path))
  }

  @Test
  func testOutOfRangeOnTheGoIndicesAreDroppedWithNote() async throws {
    _ = try seedDeviceTracks(2)
    let otgURL = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try otgData(indices: [0, 9]).write(to: otgURL)

    let result = try await sync()
    #expect((result.onTheGoImports.count) == (1))
    #expect((result.onTheGoImports[0].trackIDs.count) == (1))
    #expect(
      result.playlistNotes.contains { $0.contains("no longer exist") }, Comment(rawValue: "got \(result.playlistNotes)")
    )
  }

  @Test
  func testDuplicateOnTheGoImportIsSuppressed() async throws {
    _ = try seedDeviceTracks(2)
    try otgData(indices: [0, 1]).write(
      to: fs.itunesDir.appendingPathComponent("OTGPlaylistInfo"))
    try await sync()
    #expect((localPlaylists.filter { $0.name.hasPrefix("On-The-Go") }.count) == (1))

    let again = fs.itunesDir.appendingPathComponent("OTGPlaylistInfo")
    try otgData(indices: [0, 1]).write(to: again)
    let result = try await sync()
    #expect(result.onTheGoImports.isEmpty)
    #expect((localPlaylists.filter { $0.name.hasPrefix("On-The-Go") }.count) == (1))
    #expect(!(FileManager.default.fileExists(atPath: again.path)))
  }

  @Test
  func testMultipleOnTheGoFilesGetSequentialNames() async throws {
    _ = try seedDeviceTracks(3)
    try otgData(indices: [0]).write(to: fs.itunesDir.appendingPathComponent("OTGPlaylistInfo"))
    try otgData(indices: [1, 2]).write(
      to: fs.itunesDir.appendingPathComponent("OTGPlaylistInfo_1"))

    let result = try await sync()
    #expect((result.onTheGoImports.map(\.name)) == (["On-The-Go 1", "On-The-Go 2"]))
  }
}
