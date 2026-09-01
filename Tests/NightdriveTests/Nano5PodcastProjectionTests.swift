import Foundation
import Testing

@testable import Nightdrive

/// Verifies that podcast tracks and the synthesized podcast playlist are
/// projected into the nano 5G SQLite databases consistently with the CDB.
struct Nano5PodcastProjectionTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private func podcastTrack(
    title: String, album: String?, year: UInt32, released: Date?, path: String
  ) -> ITDBTrack {
    var t = ITDBTrack()
    t.title = title
    t.album = album
    t.artist = "Host"
    t.mediaKind = ITDBMediaKind.podcast.rawValue
    t.year = year
    t.rememberPlaybackPosition = true
    t.skipWhenShuffling = true
    t.timeReleased = released
    t.ipodPath = path
    t.filetypeMarker = SyncEngine.filetypeMarker(for: "mp3")
    t.sizeBytes = 2_000_000
    t.lengthMS = 1_800_000
    return t
  }

  private func songTrack(title: String, path: String) -> ITDBTrack {
    var t = ITDBTrack()
    t.title = title
    t.album = "Album"
    t.artist = "Artist"
    t.ipodPath = path
    t.filetypeMarker = SyncEngine.filetypeMarker(for: "mp3")
    return t
  }

  @Test
  func testWriteProjectsPodcastsIntoSQLiteAndStaysIdempotent() throws {
    let root = scratch
    let fs = try makeNano5FileSystem(at: root).fs

    var database = ITunesDatabase()
    let newest = Date(timeIntervalSince1970: 1_717_200_000)
    let oldest = Date(timeIntervalSince1970: 1_704_067_200)
    let song = songTrack(title: "Song", path: ":iPod_Control:Music:F00:SONG.mp3")
    let early = podcastTrack(
      title: "Early", album: "Show", year: 2024, released: oldest,
      path: ":iPod_Control:Music:F00:E1.mp3")
    let late = podcastTrack(
      title: "Late", album: "Show", year: 2024, released: newest,
      path: ":iPod_Control:Music:F00:E2.mp3")
    database.tracks = [song, early, late]
    try fs.writeDatabase(database)

    let libraryURL = fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb")
    let dynamicURL = fs.sqliteLibraryDirectory.appendingPathComponent("Dynamic.itdb")
    let podcastPID = Int64(
      bitPattern: ITunesDBWriter.synthesizedPodcastPlaylistID(for: database))
    let earlyID = Int64(bitPattern: early.dbid)
    let lateID = Int64(bitPattern: late.dbid)
    let songID = Int64(bitPattern: song.dbid)

    func checkProjection() throws {
      #expect(try sqliteInt(at: libraryURL, query: "SELECT COUNT(*) FROM podcast_info") == 2)
      for id in [earlyID, lateID] {
        #expect(
          try sqliteInt(
            at: libraryURL,
            query: "SELECT COUNT(*) FROM podcast_info WHERE item_pid = \(id)") == 1)
        #expect(
          try sqliteInt(
            at: libraryURL, query: "SELECT media_kind FROM item WHERE pid = \(id)") == 4)
      }
      #expect(
        try sqliteInt(
          at: libraryURL,
          query: "SELECT COUNT(*) FROM podcast_info WHERE item_pid = \(songID)") == 0)
      #expect(
        try sqliteInt(
          at: libraryURL, query: "SELECT media_kind FROM item WHERE pid = \(songID)") == 1)
      #expect(
        try sqliteInt(
          at: libraryURL, query: "SELECT date_released FROM item WHERE pid = \(lateID)")
          == Nano5DatabaseWriter.sqlTime(newest, timezone: database.timezoneShift))
      #expect(
        try sqliteInt(
          at: libraryURL, query: "SELECT date_released FROM item WHERE pid = \(songID)") == 0)
      #expect(
        try sqliteInt(
          at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(podcastPID)")
          == 1)
      #expect(
        try sqliteInt(
          at: libraryURL, query: "SELECT media_kinds FROM container WHERE pid = \(podcastPID)")
          == 4)
      #expect(
        try sqliteInt(
          at: libraryURL,
          query:
            "SELECT COUNT(*) FROM item_to_container WHERE container_pid = \(podcastPID)") == 2)
      // Episodes are grouped newest-first inside the synthesized playlist.
      #expect(
        try sqliteInt(
          at: libraryURL,
          query: """
            SELECT item_pid FROM item_to_container WHERE container_pid = \(podcastPID)
            ORDER BY physical_order LIMIT 1
            """) == lateID)
      #expect(
        try sqliteInt(
          at: libraryURL,
          query: """
            SELECT item_pid FROM item_to_container WHERE container_pid = \(podcastPID)
            ORDER BY physical_order LIMIT 1 OFFSET 1
            """) == earlyID)
      #expect(
        try sqliteInt(
          at: dynamicURL,
          query: "SELECT COUNT(*) FROM container_ui WHERE container_pid = \(podcastPID)") == 1)
    }
    try checkProjection()

    // A read-back reconcile write must reproduce the same projection.
    let reread = try fs.readDatabase()
    #expect(reread.podcastPlaylists.contains { $0.isPodcast })
    try fs.writeDatabase(reread)
    try checkProjection()
  }

  @Test
  func testRemovingPodcastsCleansUpSQLiteRows() throws {
    let root = scratch
    let fs = try makeNano5FileSystem(at: root).fs

    var database = ITunesDatabase()
    let episode = podcastTrack(
      title: "Episode", album: "Show", year: 2024,
      released: Date(timeIntervalSince1970: 1_717_200_000),
      path: ":iPod_Control:Music:F00:E1.mp3")
    let song = songTrack(title: "Song", path: ":iPod_Control:Music:F00:SONG.mp3")
    database.tracks = [song, episode]
    try fs.writeDatabase(database)

    let libraryURL = fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb")
    let dynamicURL = fs.sqliteLibraryDirectory.appendingPathComponent("Dynamic.itdb")
    let podcastPID = Int64(
      bitPattern: ITunesDBWriter.synthesizedPodcastPlaylistID(for: database))
    #expect(try sqliteInt(at: libraryURL, query: "SELECT COUNT(*) FROM podcast_info") == 1)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(podcastPID)") == 1)

    // Dropping the last podcast track removes the synthesized playlist's
    // container rows and the track's podcast rows during reconcile.
    var mutated = try fs.readDatabase()
    mutated.tracks.removeAll { $0.mediaKind == ITDBMediaKind.podcast.rawValue }
    try fs.writeDatabase(mutated)
    #expect(try sqliteInt(at: libraryURL, query: "SELECT COUNT(*) FROM podcast_info") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(podcastPID)") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM item_to_container WHERE container_pid = \(podcastPID)")
        == 0)
    #expect(
      try sqliteInt(
        at: dynamicURL,
        query: "SELECT COUNT(*) FROM container_ui WHERE container_pid = \(podcastPID)") == 0)
  }

  @Test
  func testTrackFlippedToSongLosesItsPodcastInfoRow() throws {
    let root = scratch
    let fs = try makeNano5FileSystem(at: root).fs

    var database = ITunesDatabase()
    let episode = podcastTrack(
      title: "Episode", album: "Show", year: 2024,
      released: Date(timeIntervalSince1970: 1_717_200_000),
      path: ":iPod_Control:Music:F00:E1.mp3")
    database.tracks = [episode]
    try fs.writeDatabase(database)

    let libraryURL = fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb")
    let episodeID = Int64(bitPattern: episode.dbid)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM podcast_info WHERE item_pid = \(episodeID)") == 1)

    var mutated = try fs.readDatabase()
    mutated.tracks[0].mediaKind = ITDBMediaKind.audio.rawValue
    mutated.tracks[0].timeReleased = nil
    try fs.writeDatabase(mutated)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM podcast_info WHERE item_pid = \(episodeID)") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT media_kind FROM item WHERE pid = \(episodeID)") == 1)
  }
}
