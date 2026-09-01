import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct ITunesDBEdgeCaseTests {
  private func sampleTrack(title: String, path: String) -> ITDBTrack {
    var t = ITDBTrack()
    t.title = title
    t.artist = "Edge Artist"
    t.album = "Edge Album"
    t.ipodPath = path
    t.sizeBytes = 1_234_567
    t.lengthMS = 180_000
    t.timeAdded = Date(timeIntervalSince1970: 1_100_000_000)
    return t
  }

  private func twoTrackDB(withUserPlaylist: Bool = false) -> ITunesDatabase {
    var db = ITunesDatabase()
    db.tracks = [
      sampleTrack(title: "First", path: ":iPod_Control:Music:F00:AAAA.mp3"),
      sampleTrack(title: "Second", path: ":iPod_Control:Music:F01:BBBB.mp3"),
    ]
    if withUserPlaylist {
      var pl = ITDBPlaylist(name: "Mix", isMaster: false)
      pl.memberDbids = [db.tracks[0].dbid, db.tracks[1].dbid]
      db.playlists = [pl]
    }
    return db
  }

  @Test
  func testDuplicateTrackDbidsAreRejectedAsCorrupt() throws {
    var data = ITunesDBWriter().write(twoTrackDB())

    let mhits = DBBytes.mhitOffsets(in: data)
    #expect(mhits.count == 2)
    DBBytes.patchU32(&data, at: mhits[1] + 112, DBBytes.u32(data, at: mhits[0] + 112))
    DBBytes.patchU32(&data, at: mhits[1] + 116, DBBytes.u32(data, at: mhits[0] + 116))

    do {
      let caughtError = #expect(throws: (any Error).self) { try ITunesDBReader().read(data) }
      if let caughtError {
        #expect(
          caughtError.localizedDescription.contains("dbid"), Comment(rawValue: "unexpected caughtError \(caughtError)"))
      }
    }
  }

  @Test
  func testSamplerateRoundTripsThroughThePacked16BitField() throws {
    var db = ITunesDatabase()
    var t = sampleTrack(title: "Hz", path: ":iPod_Control:Music:F00:DDDD.mp3")
    t.samplerate = 48_000
    t.samplerateLow = 0x1234
    db.tracks = [t]

    let data = ITunesDBWriter().write(db)
    let mhit = try #require(DBBytes.mhitOffsets(in: data).first)
    #expect(DBBytes.u32(data, at: mhit + 60) == 48_000 << 16 | 0x1234)
    let parsed = try #require(ITunesDBReader().read(data).tracks.first)
    #expect(parsed.samplerate == 48_000)
    #expect(parsed.samplerateLow == 0x1234)
  }

  @Test
  func testZeroLengthSiblingMhodThrowsInsteadOfHanging() async throws {
    var data = ITunesDBWriter().write(twoTrackDB())

    let mhyp = try #require(DBBytes.mhypOffsets(in: data, sectionType: 2).first)
    let mhip = try #require(DBBytes.mhipOffsets(in: data, mhyp: mhyp).first)
    #expect(DBBytes.u32(data, at: mhip + 8) == 120)
    DBBytes.patchU32(&data, at: mhip + 8, 76)
    #expect(DBBytes.tag(data, at: mhip + 76) == "mhod")
    DBBytes.patchU32(&data, at: mhip + 76 + 8, 0)

    let parseResult = Mutex<Result<Void, any Error>?>(nil)
    let parseData = data
    Task.detached {
      let result = Result<Void, any Error> {
        _ = try ITunesDBReader().read(parseData)
      }
      parseResult.withLock { $0 = result }
    }
    #expect(await waitUntil { parseResult.withLock { $0 != nil } })
    let completedResult = parseResult.withLock { $0 }
    switch try #require(completedResult) {
    case .success:
      Issue.record("the malformed playlist hierarchy should be rejected")
    case .failure(let error):
      #expect(error is ITunesDBError, Comment(rawValue: "unexpected error \(error)"))
    }
  }

  @Test
  func testDuplicateTrackIDsDoNotCrash() throws {
    let db = twoTrackDB(withUserPlaylist: true)
    var data = ITunesDBWriter().write(db)

    let mhits = DBBytes.mhitOffsets(in: data)
    #expect(mhits.count == 2)
    let firstID = DBBytes.u32(data, at: mhits[0] + 16)
    DBBytes.patchU32(&data, at: mhits[1] + 16, firstID)

    let parsed = try ITunesDBReader().read(data)
    #expect(parsed.tracks.count == 2)
    #expect(parsed.playlists.count == 1)
    #expect(parsed.playlists[0].memberDbids == [db.tracks[0].dbid])
  }

  @Test
  func testMhsdSectionOrderIndependence() throws {
    let db = twoTrackDB(withUserPlaylist: true)
    let data = ITunesDBWriter().write(db)

    let sections = DBBytes.mhsdSections(in: data)
    #expect(sections.map(\.type) == [1, 3, 2, 4, 8, 6, 10, 5])
    let reordered = sections.sorted { a, b in
      func rank(_ t: UInt32) -> Int { t == 2 || t == 3 ? 0 : 1 }
      return rank(a.type) < rank(b.type)
    }
    var rebuilt = data.prefix(244)
    for section in reordered { rebuilt += data[section.range] }
    #expect(rebuilt.count == data.count)

    let parsed = try ITunesDBReader().read(rebuilt)
    #expect(parsed.tracks.map(\.title) == ["First", "Second"])
    #expect(parsed.playlists.count == 1)
    #expect(parsed.playlists[0].memberDbids == db.playlists[0].memberDbids)
  }

  @Test
  func testTimezoneShiftPreservedOnRoundTrip() throws {
    var db = twoTrackDB()
    db.timezoneShift = -18_000
    let added = Date(timeIntervalSince1970: 1_200_000_000)
    db.tracks[0].timeAdded = added

    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    #expect(parsed.timezoneShift == -18_000)
    #expect(abs((parsed.tracks[0].timeAdded!.timeIntervalSince1970) - (added.timeIntervalSince1970)) <= 1)
  }

  @Test
  func testBinaryAndNanoTimestampConventionsUseOppositeTimezoneDirections() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let timezone = 19_800
    var database = ITunesDatabase()
    database.timezoneShift = timezone
    let writer = ITunesDBWriter()
    _ = writer.write(database)

    #expect(writer.macTime(date) == UInt32(1_700_000_000 + Int(ITunesDBWriter.macEpochOffset) + timezone))
    #expect(Nano5DatabaseWriter.sqlTime(date, timezone: timezone) == 1_700_000_000 - 978_307_200 - Int64(timezone))
  }

  @Test
  func testCodecAndPlaybackFieldsPreservedOnRoundTrip() throws {
    var db = ITunesDatabase()
    var t = sampleTrack(title: "AAC-ish", path: ":iPod_Control:Music:F00:CCCC.m4a")
    t.type2 = 0
    t.samplerateLow = 12_345
    t.rating = 60
    t.playCount = 42
    t.compilation = true
    t.vbr = true
    db.tracks = [t]

    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    let track = try #require(parsed.tracks.first)
    #expect(track.type2 == 0)
    #expect(track.samplerateLow == 12_345)
    #expect(track.rating == 60)
    #expect(track.playCount == 42)
    #expect(track.compilation)
    #expect(track.vbr)
  }

  @Test
  func testUndersizedMhipThrows() throws {
    var data = ITunesDBWriter().write(twoTrackDB())
    let mhyp = try #require(DBBytes.mhypOffsets(in: data, sectionType: 2).first)
    let mhip = try #require(DBBytes.mhipOffsets(in: data, mhyp: mhyp).first)
    DBBytes.patchU32(&data, at: mhip + 8, 27)
    do {
      let caughtError = #expect(throws: (any Error).self) { try ITunesDBReader().read(data) }
      if let caughtError {
        #expect(caughtError is ITunesDBError, Comment(rawValue: "unexpected caughtError \(caughtError)"))
      }
    }
  }

  @Test
  func testMasterPlaylistIDAndLibraryIDAreIndependent() throws {
    var db = twoTrackDB()
    db.masterPlaylistID = 0x1111_2222_3333_4444
    db.libraryPersistentID = 0x5555_6666_7777_8888

    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    #expect(parsed.masterPlaylistID == 0x1111_2222_3333_4444)
    #expect(parsed.libraryPersistentID == 0x5555_6666_7777_8888)
  }

  @Test
  func testRejectsHeaderOnlyMissingSectionsAndDeclaredCountMismatches() throws {
    let original = ITunesDBWriter().write(twoTrackDB(withUserPlaylist: true))

    var headerOnly = Data(original.prefix(244))
    DBBytes.patchU32(&headerOnly, at: 8, UInt32(headerOnly.count))
    DBBytes.patchU32(&headerOnly, at: 20, 0)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(headerOnly) }

    let sections = DBBytes.mhsdSections(in: original)
    let playlist = try #require(sections.first(where: { $0.type == 2 }))
    var missingPlaylist = original
    missingPlaylist.removeSubrange(playlist.range)
    DBBytes.patchU32(&missingPlaylist, at: 8, UInt32(missingPlaylist.count))
    DBBytes.patchU32(&missingPlaylist, at: 20, 7)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(missingPlaylist) }

    var badSectionCount = original
    DBBytes.patchU32(&badSectionCount, at: 20, 7)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(badSectionCount) }

    var badTrackCount = original
    let trackSection = try #require(sections.first(where: { $0.type == 1 }))
    let mhlt = trackSection.range.lowerBound + Int(DBBytes.u32(original, at: trackSection.range.lowerBound + 4))
    DBBytes.patchU32(&badTrackCount, at: mhlt + 8, 3)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(badTrackCount) }

    var badMhodCount = original
    let mhit = try #require(DBBytes.mhitOffsets(in: original).first)
    DBBytes.patchU32(&badMhodCount, at: mhit + 12, DBBytes.u32(original, at: mhit + 12) + 1)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(badMhodCount) }

    var badPlaylistCount = original
    let playlistSection = try #require(sections.first(where: { $0.type == 2 }))
    let mhlp =
      playlistSection.range.lowerBound
      + Int(DBBytes.u32(original, at: playlistSection.range.lowerBound + 4))
    DBBytes.patchU32(&badPlaylistCount, at: mhlp + 8, 3)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(badPlaylistCount) }

    var badMhipChildCount = original
    let mhyp = try #require(DBBytes.mhypOffsets(in: original, sectionType: 2).first)
    let mhip = try #require(DBBytes.mhipOffsets(in: original, mhyp: mhyp).first)
    DBBytes.patchU32(&badMhipChildCount, at: mhip + 12, 2)
    #expect(throws: (any Error).self) { try ITunesDBReader().read(badMhipChildCount) }
  }

  @Test
  func testRejectsTrackCountThatCannotFitBeforeReservingStorage() throws {
    var data = ITunesDBWriter().write(twoTrackDB())
    let trackSection = try #require(DBBytes.mhsdSections(in: data).first(where: { $0.type == 1 }))
    let mhlt =
      trackSection.range.lowerBound
      + Int(DBBytes.u32(data, at: trackSection.range.lowerBound + 4))
    DBBytes.patchU32(&data, at: mhlt + 8, 1_000_000)

    do {
      let caughtError = #expect(throws: (any Error).self) { try ITunesDBReader().read(data) }
      if let caughtError {
        #expect(
          caughtError.localizedDescription.contains("exceeds mhlt bounds"),
          Comment(rawValue: "unexpected caughtError \(caughtError)"))
      }
    }
  }

  @Test
  func testForeignTrackAndPlaylistMetadataSurvivesMutation() throws {
    var bytes = ITunesDBWriter().write(twoTrackDB(withUserPlaylist: true))
    let firstTrack = try #require(DBBytes.mhitOffsets(in: bytes).first)
    DBBytes.patchU32(&bytes, at: firstTrack + 100, 0xCAFE_BABE)
    DBBytes.patchU32(&bytes, at: firstTrack + 108, 91_234)
    DBBytes.patchU32(&bytes, at: firstTrack + 128, 456_789)
    DBBytes.patchU32(&bytes, at: firstTrack + 208, 4)
    DBBytes.patchU32(&bytes, at: firstTrack + 248, 0x1122_3344)
    bytes[firstTrack + 164] = 1
    bytes[firstTrack + 166] = 1
    bytes[firstTrack + 177] = 1

    let master = try #require(DBBytes.mhypOffsets(in: bytes, sectionType: 2).first)
    bytes[master + 52] = 0xA7

    var parsed = try ITunesDBReader().read(bytes)
    parsed.tracks[0].title = "Edited"
    let imported = parsed.tracks[0]
    _ = parsed.tracks.removeLast()
    var added = sampleTrack(title: "Added", path: ":iPod_Control:Music:F02:NEW.mp3")
    added.artist = "New Artist"
    added.album = "New Album"
    parsed.tracks = [added, imported]
    parsed.playlists[0].memberDbids = [added.dbid, imported.dbid]
    parsed.masterPlaylistName = "Renamed"
    let rewritten = ITunesDBWriter().write(parsed)
    let rewrittenTracks = DBBytes.mhitOffsets(in: rewritten)
    #expect(rewrittenTracks.count == 2)
    let rewrittenTrack = rewrittenTracks[1]
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 100) == 0xCAFE_BABE)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 108) == 91_234)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 128) == 456_789)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 208) == 4)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 248) == 0x1122_3344)
    #expect(rewritten[rewrittenTrack + 164] == 1)
    #expect(rewritten[rewrittenTrack + 166] == 1)
    #expect(rewritten[rewrittenTrack + 177] == 1)
    #expect(rewritten[try #require(DBBytes.mhypOffsets(in: rewritten, sectionType: 2).first) + 52] == 0xA7)
    let reparsed = try ITunesDBReader().read(rewritten)
    #expect(reparsed.tracks.map(\.title) == ["Added", "Edited"])
    #expect(reparsed.playlists[0].memberDbids == [added.dbid, imported.dbid])

    let userPlaylist = try #require(DBBytes.mhypOffsets(in: rewritten, sectionType: 2).last)
    let members = DBBytes.mhipOffsets(in: rewritten, mhyp: userPlaylist)
    #expect(members.count == 2)
    #expect(DBBytes.u32(rewritten, at: members[0] + 100) == 0)
    #expect(DBBytes.u32(rewritten, at: members[1] + 100) == 1)
    #expect(DBBytes.u32(rewritten, at: members[0] + 108) == 0)
    #expect(DBBytes.u32(rewritten, at: members[1] + 108) == 0)

    let albumSection = try #require(DBBytes.mhsdSections(in: rewritten).first(where: { $0.type == 4 }))
    let albumList =
      albumSection.range.lowerBound
      + Int(DBBytes.u32(rewritten, at: albumSection.range.lowerBound + 4))
    #expect(DBBytes.u32(rewritten, at: albumList + 8) == 2)
    #expect(DBBytes.u32(rewritten, at: rewrittenTracks[0] + 288) == 2)
  }

  @Test
  func testShortForeignMhitOnlyPatchesPlaybackFieldsItsHeaderCarries() throws {
    var bytes = ITunesDBWriter().write(twoTrackDB())
    let trackSection = try #require(DBBytes.mhsdSections(in: bytes).first(where: { $0.type == 1 }))
    let firstTrack = try #require(DBBytes.mhitOffsets(in: bytes).first)
    let oldHeaderLength = Int(DBBytes.u32(bytes, at: firstTrack + 4))
    let newHeaderLength = 0xA0
    let removed = oldHeaderLength - newHeaderLength
    DBBytes.patchU32(&bytes, at: firstTrack + 0x6C, 123)
    DBBytes.patchU32(&bytes, at: firstTrack + 0x9C, 7)
    bytes.removeSubrange(
      (firstTrack + newHeaderLength)..<(firstTrack + oldHeaderLength))
    DBBytes.patchU32(&bytes, at: firstTrack + 4, UInt32(newHeaderLength))
    DBBytes.patchU32(
      &bytes, at: firstTrack + 8,
      DBBytes.u32(bytes, at: firstTrack + 8) - UInt32(removed))
    DBBytes.patchU32(
      &bytes, at: trackSection.range.lowerBound + 8,
      DBBytes.u32(bytes, at: trackSection.range.lowerBound + 8) - UInt32(removed))
    DBBytes.patchU32(&bytes, at: 8, UInt32(bytes.count))

    var parsed = try ITunesDBReader().read(bytes)
    #expect(parsed.tracks[0].bookmarkMS == 123)
    #expect(parsed.tracks[0].skipCount == 7)
    #expect(parsed.tracks[0].lastSkipped == nil)
    parsed.tracks[0].bookmarkMS = 456
    parsed.tracks[0].skipCount = 9
    parsed.tracks[0].lastSkipped = Date(timeIntervalSince1970: 1_300_000_000)

    let rewritten = ITunesDBWriter().write(parsed)
    let rewrittenTrack = try #require(DBBytes.mhitOffsets(in: rewritten).first)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 4) == UInt32(newHeaderLength))
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 0x6C) == 456)
    #expect(DBBytes.u32(rewritten, at: rewrittenTrack + 0x9C) == 9)
    #expect(try ITunesDBReader().read(rewritten).tracks[0].lastSkipped == nil)
  }

  @Test
  func testImportedTrackMetadataEditsRefreshAlbumAndArtistIndexIDs() throws {
    let writer = ITunesDBWriter()
    let original = writer.write(twoTrackDB())
    let originalTrack = try #require(DBBytes.mhitOffsets(in: original).first)
    let originalAlbumID = DBBytes.u32(original, at: originalTrack + 288)
    let originalArtistID = DBBytes.u32(original, at: originalTrack + 480)

    let unchanged = writer.write(try ITunesDBReader().read(original))
    let unchangedTrack = try #require(DBBytes.mhitOffsets(in: unchanged).first)
    #expect(DBBytes.u32(unchanged, at: unchangedTrack + 288) == originalAlbumID)
    #expect(DBBytes.u32(unchanged, at: unchangedTrack + 480) == originalArtistID)

    var edited = try ITunesDBReader().read(original)
    edited.tracks[0].album = "Edited Album"
    edited.tracks[0].artist = "Edited Artist"
    let rewritten = writer.write(edited)
    let rewrittenTrack = try #require(DBBytes.mhitOffsets(in: rewritten).first)
    let rewrittenAlbumID = DBBytes.u32(rewritten, at: rewrittenTrack + 288)
    let rewrittenArtistID = DBBytes.u32(rewritten, at: rewrittenTrack + 480)
    #expect(rewrittenAlbumID != originalAlbumID)
    #expect(rewrittenArtistID != originalArtistID)

    let albumSection = try #require(DBBytes.mhsdSections(in: rewritten).first(where: { $0.type == 4 }))
    let artistSection = try #require(DBBytes.mhsdSections(in: rewritten).first(where: { $0.type == 8 }))
    let albumList =
      albumSection.range.lowerBound
      + Int(DBBytes.u32(rewritten, at: albumSection.range.lowerBound + 4))
    let artistList =
      artistSection.range.lowerBound
      + Int(DBBytes.u32(rewritten, at: artistSection.range.lowerBound + 4))
    #expect(DBBytes.u32(rewritten, at: albumList + 8) == 2)
    #expect(DBBytes.u32(rewritten, at: artistList + 8) == 2)

    let reparsed = try ITunesDBReader().read(rewritten)
    #expect(reparsed.tracks[0].album == "Edited Album")
    #expect(reparsed.tracks[0].artist == "Edited Artist")
  }

  @Test
  func testMalformedPreservedIndexCountDoesNotDriveAllocation() throws {
    let writer = ITunesDBWriter()
    var parsed = try ITunesDBReader().read(writer.write(twoTrackDB()))
    let sectionIndex = try #require(parsed.preservedSections.firstIndex { $0.type == 4 })
    var section = parsed.preservedSections[sectionIndex].data
    let list = Int(DBBytes.u32(section, at: 4))
    DBBytes.patchU32(&section, at: list + 8, UInt32.max)
    parsed.preservedSections[sectionIndex].data = section
    parsed.tracks[0].album = "Edited Album"

    #expect(throws: Never.self) { _ = writer.write(parsed) }
  }

  @Test
  func testPodcastPlaylistDropsDeletedTrackWithoutLosingRemainingRecords() throws {
    var parsed = try ITunesDBReader().read(
      ITunesDBWriter().write(twoTrackDB(withUserPlaylist: true)))
    #expect(!(parsed.podcastPlaylists.isEmpty))
    let deleted = parsed.tracks.removeFirst().dbid
    let rewritten = try ITunesDBReader().read(ITunesDBWriter().write(parsed))
    #expect(!(rewritten.podcastPlaylists.isEmpty))
    #expect(!(rewritten.podcastPlaylists.flatMap(\.memberDbids).contains(deleted)))
    #expect(Set(rewritten.podcastPlaylists.flatMap(\.memberDbids)) == Set(rewritten.tracks.map(\.dbid)))
  }

  @Test
  func testType3PlaylistMirrorReconcilesStandardPlaylistChanges() throws {
    let writer = ITunesDBWriter()
    var parsed = try ITunesDBReader().read(writer.write(twoTrackDB(withUserPlaylist: true)))
    let originalID = try #require(parsed.playlists.first?.persistentID)
    parsed.playlists[0].name = "Renamed Mix"
    parsed.playlists[0].memberDbids.reverse()
    var created = ITDBPlaylist(name: "Created Locally", isMaster: false)
    created.memberDbids = [parsed.tracks[1].dbid]
    parsed.playlists.append(created)

    var rewritten = try ITunesDBReader().read(writer.write(parsed))
    let mirroredUsers = rewritten.podcastPlaylists.filter { !$0.isMaster }
    #expect(mirroredUsers.map(\.persistentID) == rewritten.playlists.map(\.persistentID))
    #expect(mirroredUsers.map(\.name) == ["Renamed Mix", "Created Locally"])
    #expect(mirroredUsers.map(\.memberDbids) == rewritten.playlists.map(\.memberDbids))

    rewritten.playlists.removeAll { $0.persistentID == originalID }
    let afterDeletion = try ITunesDBReader().read(writer.write(rewritten))
    #expect(!(afterDeletion.playlists.contains { $0.persistentID == originalID }))
    #expect(!(afterDeletion.podcastPlaylists.contains { $0.persistentID == originalID }))
  }

  @Test
  func testOldStyleSiblingPlaylistPositionsAreRepairedAfterReorder() throws {
    let database = twoTrackDB(withUserPlaylist: true)
    var bytes = ITunesDBWriter().write(database)
    let userPlaylist = try #require(DBBytes.mhypOffsets(in: bytes, sectionType: 2).last)
    let originalMembers = DBBytes.mhipOffsets(in: bytes, mhyp: userPlaylist)
    #expect(originalMembers.count == 2)

    for member in originalMembers {
      #expect(DBBytes.u32(bytes, at: member + 8) == 120)
      DBBytes.patchU32(&bytes, at: member + 8, 76)
      DBBytes.patchU32(&bytes, at: member + 12, 0)
    }

    var parsed = try ITunesDBReader().read(bytes)
    parsed.playlists[0].memberDbids.reverse()
    let rewritten = ITunesDBWriter().write(parsed)
    let reparsed = try ITunesDBReader().read(rewritten)
    #expect(reparsed.playlists[0].memberDbids == Array(database.playlists[0].memberDbids.reversed()))

    let rewrittenPlaylist = try #require(DBBytes.mhypOffsets(in: rewritten, sectionType: 2).last)
    let headerLen = Int(DBBytes.u32(rewritten, at: rewrittenPlaylist + 4))
    let mhodCount = Int(DBBytes.u32(rewritten, at: rewrittenPlaylist + 12))
    let memberCount = Int(DBBytes.u32(rewritten, at: rewrittenPlaylist + 16))
    var position = rewrittenPlaylist + headerLen
    for _ in 0..<mhodCount {
      position += Int(DBBytes.u32(rewritten, at: position + 8))
    }
    var siblingPositions: [UInt32] = []
    for _ in 0..<memberCount {
      #expect(DBBytes.tag(rewritten, at: position) == "mhip")
      position += Int(DBBytes.u32(rewritten, at: position + 8))
      #expect(DBBytes.tag(rewritten, at: position) == "mhod")
      #expect(DBBytes.u32(rewritten, at: position + 12) == 100)
      siblingPositions.append(DBBytes.u32(rewritten, at: position + 24))
      #expect(DBBytes.u32(rewritten, at: position + 32) == 0)
      position += Int(DBBytes.u32(rewritten, at: position + 8))
    }
    #expect(siblingPositions == [0, 1])
  }

  @Test
  func testTrackIDAssignmentPreservesFirstImportedOccurrenceAndReservesLaterIDs() {
    var newTrack = ITDBTrack()
    newTrack.id = 52

    var imported = ITDBTrack()
    imported.id = 52
    imported.preservedMhitHeader = Data()

    let importedDuplicate = imported
    var importedWithoutID = imported
    importedWithoutID.id = 0

    var laterImported = imported
    laterImported.id = 60

    var tracks = [newTrack, imported, importedDuplicate, importedWithoutID, laterImported]
    ITunesDBWriter.assignTrackIDs(&tracks)

    #expect(tracks.map(\.id) == [61, 52, 62, 63, 60])
  }

  @Test
  func testPreservedMemberLookupKeepsPerTrackAndOpaqueRecordOrder() {
    let first: UInt64 = 11
    let second: UInt64 = 22
    var lookup = ITunesDBWriter.PreservedMemberLookup([
      ITDBPlaylistMember(dbid: first, data: Data([0xA1])),
      ITDBPlaylistMember(dbid: nil, data: Data([0xF1])),
      ITDBPlaylistMember(dbid: second, data: Data([0xB1])),
      ITDBPlaylistMember(dbid: first, data: Data([0xA2])),
      ITDBPlaylistMember(dbid: nil, data: Data([0xF2])),
    ])

    #expect(lookup.takeRecord(for: first) == Data([0xA1]))
    #expect(lookup.takeRecord(for: second) == Data([0xB1]))
    #expect(lookup.takeRecord(for: first) == Data([0xA2]))
    #expect(lookup.takeRecord(for: first) == nil)
    #expect(lookup.opaqueRecords == [Data([0xF1]), Data([0xF2])])
  }

  @Test
  func testWriterPreparationScalesToLargeImportedLibrariesAndPlaylists() {
    let count = 20_000

    var imported = ITDBTrack()
    imported.preservedMhitHeader = Data()
    var tracks: [ITDBTrack] = []
    tracks.reserveCapacity(count)
    for offset in 0..<count {
      var track = imported
      track.id = UInt32(offset + 1)
      tracks.append(track)
    }
    ITunesDBWriter.assignTrackIDs(&tracks)
    #expect(tracks.first?.id == 1)
    #expect(tracks.last?.id == UInt32(count))
    #expect(Set(tracks.map(\.id)).count == count)

    let dbid: UInt64 = 42
    let members = (0..<count).map {
      ITDBPlaylistMember(dbid: dbid, data: Data([UInt8(truncatingIfNeeded: $0)]))
    }
    var lookup = ITunesDBWriter.PreservedMemberLookup(members)
    for offset in 0..<count {
      #expect(lookup.takeRecord(for: dbid) == Data([UInt8(truncatingIfNeeded: offset)]))
    }
    #expect(lookup.takeRecord(for: dbid) == nil)
  }
}
