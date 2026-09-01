import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct SyncPlaylistTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  @discardableResult
  private func sync() async throws -> SyncResult {
    let result = try await runSync(try await makePlan(localPlaylists: localPlaylists))
    try await applyLocalPlaylistSyncEffects(result)
    return result
  }

  private func dbid(for url: URL) throws -> UInt64 {
    let db = try fs.readDatabase()
    let entries = SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
    let entry = try #require(
      entries.first {
        libraryDir.appendingPathComponent($0.relativePath).standardizedFileURL
          == url.standardizedFileURL
      }, Comment(rawValue: "no ledger entry for \(url.lastPathComponent)"))
    return entry.dbid
  }

  private func playlistLinks() throws -> [SyncPlaylistLink] {
    let db = try fs.readDatabase()
    return SyncLedgerStore.playlistLinks(for: db.databaseID, libraryFolder: libraryDir)
  }

  @Test
  func testCreateLocalPlaylistAppearsOnDeviceInOrder() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    let b = try writeLibraryMP3(filename: "b.mp3", title: "Song B")
    localPlaylists = [LocalPlaylist(name: "Road Trip", trackIDs: [b, a].map(TrackID.init(url:)))]

    let result = try await sync()
    #expect((result.playlistsCreatedOnDevice) == (1))
    #expect((result.failures) == ([]))

    let db = try fs.readDatabase()
    #expect((db.playlists.count) == (1))
    #expect((db.playlists[0].name) == ("Road Trip"))
    #expect((db.playlists[0].memberDbids) == ([try dbid(for: b), try dbid(for: a)]))
    let mirrored = try #require(db.podcastPlaylists.first { $0.name == "Road Trip" })
    #expect((mirrored.persistentID) == (db.playlists[0].persistentID))
    #expect((mirrored.memberDbids) == (db.playlists[0].memberDbids))

    let links = try playlistLinks()
    #expect((links.count) == (1))
    #expect((links[0].localID) == (localPlaylists[0].id))
    #expect((links[0].persistentID) == (db.playlists[0].persistentID))
    #expect((links[0].memberDbids) == (db.playlists[0].memberDbids))
  }

  @Test
  func testReorderLocallyUpdatesDeviceOrderWithStablePersistentID() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    let b = try writeLibraryMP3(filename: "b.mp3", title: "Song B")
    localPlaylists = [LocalPlaylist(name: "Mix", trackIDs: [a, b].map(TrackID.init(url:)))]
    try await sync()
    let persistentID = try fs.readDatabase().playlists[0].persistentID

    localPlaylists[0].trackIDs = [b, a].map(TrackID.init(url:))
    let result = try await sync()
    #expect((result.playlistsUpdatedOnDevice) == (1))
    #expect((result.playlistsCreatedOnDevice) == (0))

    let db = try fs.readDatabase()
    #expect((db.playlists.count) == (1))
    #expect((db.playlists[0].persistentID) == (persistentID), Comment(rawValue: "identity must survive a reorder"))
    #expect((db.playlists[0].memberDbids) == ([try dbid(for: b), try dbid(for: a)]))
  }

  @Test
  func testRenameOnDeviceRenamesLocalPlaylist() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    localPlaylists = [LocalPlaylist(name: "Old Name", trackIDs: [TrackID(url: a)])]
    try await sync()

    var db = try fs.readDatabase()
    db.playlists[0].name = "New Name"
    try fs.writeDatabase(db)

    let result = try await sync()
    #expect((result.playlistsUpdatedInLibrary) == (1))
    #expect((localPlaylists.count) == (1))
    #expect((localPlaylists[0].name) == ("New Name"))
    #expect((try playlistLinks().first?.name) == ("New Name"))
  }

  @Test
  func testDeleteLocallyRemovesFromDevice() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    localPlaylists = [LocalPlaylist(name: "Doomed", trackIDs: [TrackID(url: a)])]
    try await sync()
    #expect((try fs.readDatabase().playlists.count) == (1))

    localPlaylists = []
    let result = try await sync()
    #expect((result.playlistsDeletedOnDevice) == (1))
    #expect(try fs.readDatabase().playlists.isEmpty)
    #expect(try playlistLinks().isEmpty)
  }

  @Test
  func testDeleteOnDeviceRemovesLocally() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    localPlaylists = [LocalPlaylist(name: "Doomed", trackIDs: [TrackID(url: a)])]
    try await sync()

    var db = try fs.readDatabase()
    db.playlists = []
    try fs.writeDatabase(db)

    let result = try await sync()
    #expect((result.playlistsDeletedInLibrary) == (1))
    #expect(localPlaylists.isEmpty)
    #expect(try playlistLinks().isEmpty)
  }

  @Test
  func testBothEditedLocalOrderWinsDeviceAdditionsAppended() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    let b = try writeLibraryMP3(filename: "b.mp3", title: "Song B")
    let c = try writeLibraryMP3(filename: "c.mp3", title: "Song C")
    let d = try writeLibraryMP3(filename: "d.mp3", title: "Song D")
    localPlaylists = [LocalPlaylist(name: "Contested", trackIDs: [a, b].map(TrackID.init(url:)))]
    try await sync()

    var db = try fs.readDatabase()
    db.playlists[0].memberDbids.append(try dbid(for: d))
    try fs.writeDatabase(db)
    localPlaylists[0].trackIDs = [b, a, c].map(TrackID.init(url:))

    let result = try await sync()
    #expect(
      result.playlistActionSummaries.contains { $0.contains("Merged playlist \"Contested\"") },
      Comment(rawValue: "conflict resolution must be reported, got \(result.playlistActionSummaries)"))

    let expected = [try dbid(for: b), try dbid(for: a), try dbid(for: c), try dbid(for: d)]
    #expect((try fs.readDatabase().playlists[0].memberDbids) == (expected))
    #expect((localPlaylists[0].trackIDs) == ([b, a, c, d].map(TrackID.init(url:))))
  }

  @Test
  func testPlaylistTrackMissingFromDeviceIsSkippedWithNote() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    let ghost = libraryDir.appendingPathComponent("missing.mp3")
    localPlaylists = [LocalPlaylist(name: "Partial", trackIDs: [a, ghost].map(TrackID.init(url:)))]

    let result = try await sync()
    #expect((result.playlistsCreatedOnDevice) == (1))
    #expect(
      result.playlistNotes.contains { $0.contains("Partial") && $0.contains("skipped") },
      Comment(rawValue: "skipped member must be noted, got \(result.playlistNotes)"))

    let db = try fs.readDatabase()
    #expect((db.playlists[0].memberDbids) == ([try dbid(for: a)]))
    #expect((localPlaylists[0].trackIDs.count) == (2))
  }

  @Test
  func testSecondSyncIsTrueNoOp() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    let b = try writeLibraryMP3(filename: "b.mp3", title: "Song B")
    localPlaylists = [LocalPlaylist(name: "Steady", trackIDs: [a, b].map(TrackID.init(url:)))]
    try await sync()

    let dbMtime = try modificationDate(of: fs.databaseURL)
    let ledgerMtime = try modificationDate(of: SyncLedgerStore.url(for: libraryDir))
    let playlistsBefore = localPlaylists

    let result = try await sync()
    #expect((result.copiedToDevice + result.copiedToFolder) == (0))
    #expect((result.totalPlaylistChanges) == (0))
    #expect((localPlaylists) == (playlistsBefore))
    #expect(
      (try modificationDate(of: fs.databaseURL)) == (dbMtime),
      Comment(rawValue: "an idempotent sync must not rewrite the device database"))
    #expect(
      (try modificationDate(of: SyncLedgerStore.url(for: libraryDir))) == (ledgerMtime),
      Comment(rawValue: "an idempotent sync must not rewrite the ledger"))
  }

  @Test
  func testSyncDisabledPlaylistIsLeftAloneOnBothSides() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let a = try writeLibraryMP3(filename: "a.mp3", title: "Song A")
    localPlaylists = [LocalPlaylist(name: "Private", trackIDs: [TrackID(url: a)], syncEnabled: false)]

    let result = try await sync()
    #expect((result.totalPlaylistChanges) == (0))
    #expect(try fs.readDatabase().playlists.isEmpty)
  }

  @Test
  func testDeviceOnlyPlaylistIsImportedToLibrary() async throws {
    var db = ITunesDatabase()
    let dest = try fs.destinationForNewFile(extension: "mp3")
    let data = MP3Builder.build(
      tags: .init(
        title: "Device Song", artist: "Ipod Artist", album: "Device Album",
        genre: "Pop", trackNumber: 1, year: 2003),
      seconds: 2)
    try data.write(to: dest)
    var track = ITDBTrack()
    track.title = "Device Song"
    track.artist = "Ipod Artist"
    track.ipodPath = fs.ipodPath(for: dest)
    track.sizeBytes = UInt32(data.count)
    track.lengthMS = 2000
    db.tracks = [track]
    var playlist = ITDBPlaylist(name: "Device Mix", isMaster: false)
    playlist.memberDbids = [track.dbid]
    db.playlists = [playlist]
    try fs.writeDatabase(db)

    let result = try await sync()
    #expect((result.copiedToFolder) == (1))
    #expect((result.playlistsCreatedInLibrary) == (1))
    #expect((localPlaylists.count) == (1))
    #expect((localPlaylists[0].name) == ("Device Mix"))
    #expect((localPlaylists[0].trackIDs.count) == (1))

    let links = try playlistLinks()
    #expect((links.count) == (1))
    #expect((links[0].localID) == (localPlaylists[0].id))
    let second = try await sync()
    #expect((second.totalPlaylistChanges) == (0))
  }

  @Test
  func testMergeKeepsLinkWhenNothingChanged() {
    let local = LocalPlaylist(name: "P", trackIDs: [TrackID(url: URL(fileURLWithPath: "/lib/a.mp3"))])
    var device = ITDBPlaylist(name: "P", isMaster: false)
    device.memberDbids = [1]
    let link = SyncPlaylistLink(
      localID: local.id, persistentID: device.persistentID, name: "P", memberDbids: [1])
    var trackLinks = PlaylistTrackLinks()
    trackLinks.dbidForTrackID = [TrackID(url: URL(fileURLWithPath: "/lib/a.mp3")): 1]
    trackLinks.trackIDForDbid = [1: TrackID(url: URL(fileURLWithPath: "/lib/a.mp3"))]
    trackLinks.urlForDbid = [1: URL(fileURLWithPath: "/lib/a.mp3")]

    let plan = SyncEngine.makePlaylistPlan(
      local: [local], device: [device], links: [link], trackLinks: trackLinks)
    #expect(plan.isEmpty)
    #expect((plan.links) == ([link]))
    #expect(plan.notes.isEmpty)
  }

  @Test
  func testMergeAdoptsUnlinkedPairByExactName() {
    let a = URL(fileURLWithPath: "/lib/a.mp3")
    let local = LocalPlaylist(name: "Shared", trackIDs: [TrackID(url: a)])
    var device = ITDBPlaylist(name: "Shared", isMaster: false)
    device.memberDbids = [1]
    var trackLinks = PlaylistTrackLinks()
    trackLinks.dbidForTrackID = [TrackID(url: a): 1]
    trackLinks.trackIDForDbid = [1: TrackID(url: a)]
    trackLinks.urlForDbid = [1: a]

    let plan = SyncEngine.makePlaylistPlan(
      local: [local], device: [device], links: [], trackLinks: trackLinks)
    #expect(plan.deviceActions.isEmpty)
    #expect(plan.libraryActions.isEmpty)
    #expect((plan.links.count) == (1))
    #expect((plan.links.first?.localID) == (local.id))
    #expect((plan.links.first?.persistentID) == (device.persistentID))
  }

  @Test
  func testMergeDeletedOneSideChangedOtherKeepsSurvivor() {
    let a = URL(fileURLWithPath: "/lib/a.mp3")
    var device = ITDBPlaylist(name: "Renamed", isMaster: false)
    device.memberDbids = [1]
    let link = SyncPlaylistLink(
      localID: UUID(), persistentID: device.persistentID, name: "Original", memberDbids: [1])
    var trackLinks = PlaylistTrackLinks()
    trackLinks.dbidForTrackID = [TrackID(url: a): 1]
    trackLinks.trackIDForDbid = [1: TrackID(url: a)]
    trackLinks.urlForDbid = [1: a]

    let plan = SyncEngine.makePlaylistPlan(
      local: [], device: [device], links: [link], trackLinks: trackLinks)
    #expect(plan.deviceActions.isEmpty, Comment(rawValue: "the surviving side must not be deleted"))
    #expect(
      plan.libraryActions.contains {
        if case .createInLibrary(let name, _, _) = $0 { return name == "Renamed" }
        return false
      })
    #expect(
      plan.libraryActions.contains {
        if case .conflictResolved = $0 { return true }
        return false
      })
  }

  @Test
  func testMergeBothRenamedLocalNameWinsWithNote() {
    let a = URL(fileURLWithPath: "/lib/a.mp3")
    let localID = UUID()
    let local = LocalPlaylist(id: localID, name: "Local Name", trackIDs: [TrackID(url: a)])
    var device = ITDBPlaylist(name: "Device Name", isMaster: false)
    device.memberDbids = [1]
    let link = SyncPlaylistLink(
      localID: localID, persistentID: device.persistentID, name: "Original", memberDbids: [1])
    var trackLinks = PlaylistTrackLinks()
    trackLinks.dbidForTrackID = [TrackID(url: a): 1]
    trackLinks.trackIDForDbid = [1: TrackID(url: a)]
    trackLinks.urlForDbid = [1: a]

    let plan = SyncEngine.makePlaylistPlan(
      local: [local], device: [device], links: [link], trackLinks: trackLinks)
    #expect(
      plan.deviceActions.contains {
        if case .updateOnDevice(_, _, let name, _) = $0 { return name == "Local Name" }
        return false
      })
    #expect(
      plan.libraryActions.contains {
        if case .conflictResolved = $0 { return true }
        return false
      })
    #expect((plan.links.first?.name) == ("Local Name"))
  }

  @Test
  func testReplacePlaylistLinksSkipsWriteWhenUnchanged() throws {
    let link = SyncPlaylistLink(localID: UUID(), persistentID: 9, name: "P", memberDbids: [7])
    try SyncLedgerStore.replacePlaylistLinks([link], for: 1, libraryFolder: libraryDir)
    let url = SyncLedgerStore.url(for: libraryDir)
    let mtime = try modificationDate(of: url)
    let bytes = try Data(contentsOf: url)
    try SyncLedgerStore.replacePlaylistLinks([link], for: 1, libraryFolder: libraryDir)
    #expect((try modificationDate(of: url)) == (mtime))
    #expect((try Data(contentsOf: url)) == (bytes))
  }

}
