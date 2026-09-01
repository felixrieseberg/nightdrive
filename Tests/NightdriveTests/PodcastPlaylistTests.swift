import Foundation
import Testing

@testable import Nightdrive

struct PodcastPlaylistTests {
  private func track(
    title: String, album: String? = nil, artist: String? = nil,
    mediaKind: ITDBMediaKind = .audio, year: UInt32 = 0, path: String
  ) -> ITDBTrack {
    var t = ITDBTrack()
    t.title = title
    t.album = album
    t.artist = artist
    t.mediaKind = mediaKind.rawValue
    t.year = year
    t.ipodPath = path
    t.sizeBytes = 2_000_000
    t.lengthMS = 1_800_000
    t.timeAdded = Date(timeIntervalSince1970: 1_400_000_000)
    if mediaKind == .podcast {
      t.rememberPlaybackPosition = true
      t.skipWhenShuffling = true
      t.timeReleased = SyncEngine.releaseDate(forYear: Int(year))
    }
    return t
  }

  private func podcastDB() -> ITunesDatabase {
    var db = ITunesDatabase()
    db.tracks = [
      track(title: "Regular Song", album: "Album", artist: "Artist", path: ":iPod_Control:Music:F00:SONG.mp3"),
      track(
        title: "Alpha Old", album: "Alpha Show", artist: "Alpha Host",
        mediaKind: .podcast, year: 2020, path: ":iPod_Control:Music:F00:A1.mp3"),
      track(
        title: "Alpha New", album: "Alpha Show", artist: "Alpha Host",
        mediaKind: .podcast, year: 2024, path: ":iPod_Control:Music:F00:A2.mp3"),
      track(
        title: "Beta Only", album: "Beta Show", artist: "Beta Host",
        mediaKind: .podcast, year: 2022, path: ":iPod_Control:Music:F01:B1.mp3"),
      track(
        title: "No Album Episode", album: nil, artist: "Gamma Host",
        mediaKind: .podcast, year: 2021, path: ":iPod_Control:Music:F01:C1.mp3"),
    ]
    return db
  }

  private func synthesizedMhyp(in data: Data) throws -> Int {
    let mhyps = DBBytes.mhypOffsets(in: data, sectionType: 3)
    let podcastFlagged = mhyps.filter { DBBytes.u32(data, at: $0 + 40) >> 16 == 1 }
    return try #require(podcastFlagged.last)
  }

  @Test
  func testWriterEmitsPodcastFlagAndGroupedMembers() throws {
    let data = ITunesDBWriter().write(podcastDB())

    let mhyp = try synthesizedMhyp(in: data)
    // u16 pair at +40: string mhod count (low), podcast flag (high).
    #expect(DBBytes.u32(data, at: mhyp + 40) == 0x0001_0001)
    #expect(DBBytes.u32(data, at: mhyp + 12) == 2, "title + display prefs mhods")
    // 3 group headings (Alpha Show, Beta Show, Gamma Host) + 4 episodes.
    #expect(DBBytes.u32(data, at: mhyp + 16) == 7)

    let mhips = DBBytes.mhipOffsets(in: data, mhyp: mhyp)
    #expect(mhips.count == 7)
    var currentGroupID: UInt32 = 0
    var groupCount = 0
    var episodeCount = 0
    for mhip in mhips {
      let flag = DBBytes.u32(data, at: mhip + 16)
      let entryID = DBBytes.u32(data, at: mhip + 20)
      let trackID = DBBytes.u32(data, at: mhip + 24)
      let groupRef = DBBytes.u32(data, at: mhip + 32)
      #expect(entryID != 0, "every podcast mhip carries its own id")
      if flag != 0 {
        #expect(flag == 256, "group headings use libgpod's podcast group flag")
        #expect(trackID == 0, "a group heading names no track")
        #expect(groupRef == 0)
        currentGroupID = entryID
        groupCount += 1
      } else {
        #expect(trackID != 0)
        #expect(groupRef == currentGroupID, "episodes reference their show's group id")
        episodeCount += 1
      }
    }
    #expect(groupCount == 3)
    #expect(episodeCount == 4)

    // The standard playlist section must not gain a podcast-flagged playlist.
    for mhyp in DBBytes.mhypOffsets(in: data, sectionType: 2) {
      #expect(DBBytes.u32(data, at: mhyp + 40) >> 16 == 0)
    }
  }

  @Test
  func testRoundTripPreservesGroupsAndEpisodeOrder() throws {
    let db = podcastDB()
    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))

    let playlist = try #require(parsed.podcastPlaylists.first { $0.isPodcast })
    #expect(playlist.name == "Podcasts")
    #expect(playlist.podcastGroups.map(\.title) == ["Alpha Show", "Beta Show", "Gamma Host"])

    let titleByDbid = Dictionary(
      parsed.tracks.map { ($0.dbid, $0.title ?? "") }, uniquingKeysWith: { first, _ in first })
    let episodeTitles = playlist.podcastGroups.map { $0.episodeDbids.map { titleByDbid[$0] } }
    #expect(episodeTitles[0] == ["Alpha New", "Alpha Old"], "episodes sort newest-first")
    #expect(episodeTitles[1] == ["Beta Only"])
    #expect(episodeTitles[2] == ["No Album Episode"])
    #expect(playlist.memberDbids == playlist.podcastGroups.flatMap(\.episodeDbids))

    // A second round trip must reproduce the same structure.
    let again = try ITunesDBReader().read(ITunesDBWriter().write(parsed))
    let stable = try #require(again.podcastPlaylists.first { $0.isPodcast })
    #expect(stable.persistentID == playlist.persistentID)
    #expect(stable.podcastGroups == playlist.podcastGroups)
    #expect(again.podcastPlaylists.count == parsed.podcastPlaylists.count)
  }

  @Test
  func testRewriteIsByteIdenticalForPodcastDatabases() throws {
    let first = ITunesDBWriter().write(podcastDB())
    let second = ITunesDBWriter().write(try ITunesDBReader().read(first))
    let third = ITunesDBWriter().write(try ITunesDBReader().read(second))
    #expect(second == third, "a no-change rewrite must be byte-identical")
  }

  @Test
  func testDatabaseWithoutPodcastTracksGetsNoPodcastPlaylist() throws {
    var db = ITunesDatabase()
    db.tracks = [
      track(title: "Song A", album: "Album", artist: "Artist", path: ":iPod_Control:Music:F00:A.mp3"),
      track(title: "Song B", album: "Album", artist: "Artist", path: ":iPod_Control:Music:F00:B.mp3"),
    ]
    var pl = ITDBPlaylist(name: "Mix", isMaster: false)
    pl.memberDbids = [db.tracks[0].dbid, db.tracks[1].dbid]
    db.playlists = [pl]

    let data = ITunesDBWriter().write(db)
    // The type-3 section stays a pure mirror: master + the user playlist.
    #expect(DBBytes.mhypOffsets(in: data, sectionType: 3).count == 2)
    for mhyp in DBBytes.mhypOffsets(in: data, sectionType: 3) {
      #expect(DBBytes.u32(data, at: mhyp + 40) >> 16 == 0)
    }
    let parsed = try ITunesDBReader().read(data)
    #expect(parsed.podcastPlaylists.allSatisfy { !$0.isPodcast })
    #expect(!parsed.podcastPlaylists.contains { $0.name == "Podcasts" })
  }

  @Test
  func testRemovingAllPodcastTracksDropsTheSynthesizedPlaylist() throws {
    var parsed = try ITunesDBReader().read(ITunesDBWriter().write(podcastDB()))
    #expect(parsed.podcastPlaylists.contains { $0.isPodcast })

    parsed.tracks.removeAll { $0.mediaKind == ITDBMediaKind.podcast.rawValue }
    let rewritten = try ITunesDBReader().read(ITunesDBWriter().write(parsed))
    #expect(!rewritten.podcastPlaylists.contains { $0.isPodcast })
    #expect(!rewritten.podcastPlaylists.contains { $0.name == "Podcasts" })
  }

  @Test
  func testForeignPodcastPlaylistIsPreservedNextToSynthesizedOne() throws {
    var parsed = try ITunesDBReader().read(ITunesDBWriter().write(podcastDB()))
    // Re-badge the parsed playlist as a foreign one (different persistent ID),
    // as if another application had written its own podcast playlist.
    var foreign = try #require(parsed.podcastPlaylists.first { $0.isPodcast })
    foreign.persistentID = 0xF00D_F00D_F00D_F00D
    foreign.name = "Foreign Casts"
    parsed.podcastPlaylists.append(foreign)

    let rewritten = try ITunesDBReader().read(ITunesDBWriter().write(parsed))
    let preserved = try #require(
      rewritten.podcastPlaylists.first { $0.persistentID == 0xF00D_F00D_F00D_F00D })
    #expect(preserved.name == "Foreign Casts")
    #expect(preserved.isPodcast)
    #expect(preserved.memberDbids == foreign.memberDbids)
    #expect(preserved.podcastGroups == foreign.podcastGroups, "group order survives preservation")
    #expect(
      rewritten.podcastPlaylists.contains {
        $0.isPodcast && $0.persistentID != 0xF00D_F00D_F00D_F00D
      }, "the synthesized playlist is still rebuilt")
  }

  @Test
  func testTimeReleasedRoundTripsThroughTheMhit() throws {
    var db = ITunesDatabase()
    var t = track(
      title: "Dated Episode", album: "Show", mediaKind: .podcast, year: 2023,
      path: ":iPod_Control:Music:F00:D.mp3")
    let released = Date(timeIntervalSince1970: 1_695_000_000)
    t.timeReleased = released
    db.tracks = [t]

    let data = ITunesDBWriter().write(db)
    let mhit = try #require(DBBytes.mhitOffsets(in: data).first)
    #expect(
      DBBytes.u32(data, at: mhit + 0x8C)
        == ITunesDBWriter.macTime(released, timezoneShift: db.timezoneShift))
    let parsed = try #require(ITunesDBReader().read(data).tracks.first)
    #expect(parsed.timeReleased == released)

    // The preserved-header rewrite path must keep the value too.
    let rewritten = ITunesDBWriter().write(try ITunesDBReader().read(data))
    let reparsed = try #require(ITunesDBReader().read(rewritten).tracks.first)
    #expect(reparsed.timeReleased == released)
  }

  @Test
  func testMakeDBTrackSetsReleaseDateForPodcastsOnly() {
    var cast = LibraryTrack(
      url: URL(fileURLWithPath: "/library/episode.mp3"), title: "Episode", artist: "Host",
      album: "Show", trackNumber: 1, year: 2021, durationMS: 1000, sizeBytes: 1000,
      bitrate: 128, samplerate: 44100)
    cast.mediaKind = .podcast
    let castDB = SyncEngine.makeDBTrack(from: cast, ipodPath: ":A.mp3")
    #expect(castDB.timeReleased == SyncEngine.releaseDate(forYear: 2021))
    #expect(SyncEngine.releaseDate(forYear: 0) == nil)

    var song = cast
    song.mediaKind = .song
    #expect(SyncEngine.makeDBTrack(from: song, ipodPath: ":A.mp3").timeReleased == nil)
  }

  @Test
  func testMakeDBTrackPrefersFullPublicationDateOverYear() throws {
    var cast = LibraryTrack(
      url: URL(fileURLWithPath: "/library/episode.mp3"), title: "Episode", artist: "Host",
      album: "Show", trackNumber: 1, year: 2023, durationMS: 1000, sizeBytes: 1000,
      bitrate: 128, samplerate: 44100)
    cast.mediaKind = .podcast
    let published = Date(timeIntervalSince1970: 1_695_212_340)
    cast.releaseDate = published

    let episode = SyncEngine.makeDBTrack(from: cast, ipodPath: ":A.mp3")
    #expect(episode.timeReleased == published)

    // The exact date survives into the mhit and back.
    var db = ITunesDatabase()
    var track = episode
    track.ipodPath = ":iPod_Control:Music:F00:E.mp3"
    db.tracks = [track]
    let parsed = try #require(ITunesDBReader().read(ITunesDBWriter().write(db)).tracks.first)
    #expect(parsed.timeReleased == published)
  }

  @Test
  func testSameYearEpisodesOrderByPublicationDate() throws {
    var db = ITunesDatabase()
    var early = track(
      title: "Early", album: "Show", artist: "Host", mediaKind: .podcast, year: 2024,
      path: ":iPod_Control:Music:F00:E1.mp3")
    early.timeReleased = Date(timeIntervalSince1970: 1_704_067_200)
    var late = track(
      title: "Late", album: "Show", artist: "Host", mediaKind: .podcast, year: 2024,
      path: ":iPod_Control:Music:F00:E2.mp3")
    late.timeReleased = Date(timeIntervalSince1970: 1_717_200_000)
    db.tracks = [early, late]

    let playlist = try #require(ITunesDBWriter.synthesizedPodcastPlaylist(for: db))
    #expect(playlist.memberDbids == [late.dbid, early.dbid], "newer publication date sorts first")

    // The order survives a write/read round trip.
    let parsed = try ITunesDBReader().read(ITunesDBWriter().write(db))
    let roundTripped = try #require(parsed.podcastPlaylists.first { $0.isPodcast })
    #expect(roundTripped.memberDbids == [late.dbid, early.dbid])
  }

  @Test
  func testTaggerWritesFullPublicationDateAndLoaderReadsItBack() async throws {
    let dir = TestScratch.directory()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("episode.mp3")
    try MP3Builder.build(
      tags: MP3Builder.Tags(
        title: "Raw", artist: "", album: "", genre: "", trackNumber: 0, year: 0),
      seconds: 2
    ).write(to: url)

    // ID3v2.3 TIME carries hours and minutes, so use a minute-aligned date.
    let published = Date(timeIntervalSince1970: 1_695_212_340)
    let episode = PodcastEpisode(
      id: "e1", title: "Episode", showTitle: "Show",
      enclosureURL: URL(fileURLWithPath: "/feed/e1.mp3"), publishedAt: published,
      durationSeconds: nil, episodeDescription: "About the episode", episodeNumber: 3,
      sizeBytes: nil)
    try PodcastEpisodeTagger.tag(fileURL: url, episode: episode, feedAuthor: "Host")

    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
    #expect(frames.contains { $0.id == "TYER" })
    #expect(frames.contains { $0.id == "TDAT" })
    #expect(frames.contains { $0.id == "TIME" })
    #expect(ID3ReleaseDate.read(fromMP3At: url) == published)

    let loaded = await MetadataLoader.load(url: url)
    #expect(loaded.releaseDate == published)
    #expect(loaded.year == 2023)
    #expect(loaded.mediaKind == .podcast)

    // Re-tagging must replace the date frames, not stack duplicates.
    try PodcastEpisodeTagger.tag(fileURL: url, episode: episode, feedAuthor: "Host")
    let again = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
    #expect(again.filter { $0.id == "TDAT" }.count == 1)
    #expect(again.filter { $0.id == "TIME" }.count == 1)
    #expect(ID3ReleaseDate.read(fromMP3At: url) == published)
  }

  @Test
  func testReleaseTimestampParsesISO8601OffsetsAndFractions() throws {
    let expected = try #require(ID3ReleaseDate.parseTimestamp("2024-01-02T01:04:05Z"))
    #expect(ID3ReleaseDate.parseTimestamp("2024-01-02T03:04:05+02:00") == expected)
    #expect(ID3ReleaseDate.parseTimestamp("2024-01-02 01:04:05") == expected)
    #expect(
      ID3ReleaseDate.parseTimestamp("2024-01-02T01:04:05.750Z")
        == expected.addingTimeInterval(0.75))
    #expect(ID3ReleaseDate.parseTimestamp("2024-01") != nil)
    #expect(ID3ReleaseDate.parseTimestamp("2024") == nil)
  }

  @Test
  func testModernShuffleTreatsSynthesizedPlaylistConsistently() throws {
    let db = podcastDB()
    let shuffleData = try ModernShuffleDatabaseFile.write(db)
    let snapshot = try ModernShuffleDatabaseFile.read(shuffleData)
    #expect(snapshot.tracksWithoutPodcastsOrAudiobooks == 1)

    let podcastLists = snapshot.playlists.filter { $0.type == 3 }
    #expect(podcastLists.count == 1)
    #expect(podcastLists[0].trackIndexes.count == 4)

    // The shuffle database built before the iTunesDB write must match the
    // one that a re-read database would produce, or every sync would rewrite it.
    let reread = try ITunesDBReader().read(ITunesDBWriter().write(db))
    #expect(ModernShuffleDatabaseFile.matches(shuffleData, database: reread))
  }
}
