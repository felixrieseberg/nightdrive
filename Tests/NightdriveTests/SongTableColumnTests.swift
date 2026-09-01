import Foundation
import Testing

@testable import Nightdrive

struct SongTableColumnTests {
  private func makeLibraryTrack(
    url: URL = URL(fileURLWithPath: "/Music/Radiohead/Kid A/Idioteque.mp3")
  ) -> LibraryTrack {
    var track = LibraryTrack(
      url: url, title: "Idioteque", artist: "Radiohead", album: "Kid A",
      albumArtist: "Radiohead", genre: "Electronic", composer: "Thom Yorke",
      comment: "ripped 2004", bpm: 122,
      trackNumber: 8, trackCount: 10, discNumber: 1, year: 2000,
      durationMS: 249_000, sizeBytes: 5_982_720, bitrate: 192, samplerate: 44100,
      modificationDate: Date(timeIntervalSince1970: 1_000_000))
    track.metadata.comment = "ripped 2004"
    return track
  }

  @Test
  func testLibraryRowCarriesEveryColumnValue() {
    let track = makeLibraryTrack()
    let listening = TrackListeningMetadata(
      trackID: track.id, rating: 4, isFavorite: true, playCount: 12,
      lastPlayedAt: Date(timeIntervalSince1970: 2_000_000))

    let row = SongRow(track: track, listening: listening)

    #expect(row.id == track.id)
    #expect(row.title == "Idioteque")
    #expect(row.albumArtist == "Radiohead")
    #expect(row.composer == "Thom Yorke")
    #expect(row.comment == "ripped 2004")
    #expect(row.year == 2000)
    #expect(row.trackNumber == 8)
    #expect(row.discNumber == 1)
    #expect(row.bpm == 122)
    #expect(row.rating == 4)
    #expect(row.isFavorite)
    #expect(row.playCount == 12)
    #expect(row.lastPlayedAt == Date(timeIntervalSince1970: 2_000_000))
    #expect(row.dateModified == Date(timeIntervalSince1970: 1_000_000))
    #expect(row.kind == "MPEG audio file")
    #expect(row.sizeBytes == 5_982_720)
    #expect(row.bitrate == 192)
    #expect(row.samplerate == 44100)
    #expect(row.location == "/Music/Radiohead/Kid A/Idioteque.mp3")
  }

  @Test
  func testLibraryRowWithoutListeningHistoryIsUnrated() {
    let row = SongRow(track: makeLibraryTrack(), listening: nil)

    #expect(row.rating == 0)
    #expect(!(row.isFavorite))
    #expect(row.playCount == 0)
    #expect(row.lastPlayedAt == nil)
    #expect(row.ratingText == "")
    #expect(row.playCountText == "")
    #expect(row.lastPlayedText == "")
  }

  @Test
  func testLibraryRowLocationSurvivesSpacesAndAccents() {
    let track = makeLibraryTrack(
      url: URL(fileURLWithPath: "/Music/Sigur Rós/Ágætis byrjun/Svefn-g-englar.mp3"))

    #expect(SongRow(track: track, listening: nil).location == "/Music/Sigur Rós/Ágætis byrjun/Svefn-g-englar.mp3")
  }

  @Test
  func testDeviceRowCarriesEveryColumnValue() {
    var track = ITDBTrack()
    track.dbid = 42
    track.title = "Idioteque"
    track.artist = "Radiohead"
    track.album = "Kid A"
    track.albumArtist = "Radiohead"
    track.genre = "Electronic"
    track.composer = "Thom Yorke"
    track.comment = "ripped 2004"
    track.year = 2000
    track.trackNumber = 8
    track.discNumber = 1
    track.lengthMS = 249_000
    track.sizeBytes = 5_982_720
    track.bitrate = 192
    track.samplerate = 44100
    track.playCount = 12
    track.rating = 80
    track.timePlayed = Date(timeIntervalSince1970: 2_000_000)
    track.timeModified = Date(timeIntervalSince1970: 1_000_000)
    track.filetypeDescription = "MPEG audio file"
    track.ipodPath = ":iPod_Control:Music:F03:XQRZ.mp3"

    let row = SongRow(deviceTrack: track)

    #expect(row.id == 42)
    #expect(row.durationMS == 249_000)
    #expect(row.albumArtist == "Radiohead")
    #expect(row.composer == "Thom Yorke")
    #expect(row.comment == "ripped 2004")
    #expect(row.year == 2000)
    #expect(row.trackNumber == 8)
    #expect(row.discNumber == 1)
    #expect(row.rating == 4)
    #expect(row.playCount == 12)
    #expect(row.lastPlayedAt == Date(timeIntervalSince1970: 2_000_000))
    #expect(row.dateModified == Date(timeIntervalSince1970: 1_000_000))
    #expect(row.kind == "MPEG audio file")
    #expect(row.sizeBytes == 5_982_720)
    #expect(row.bitrate == 192)
    #expect(row.samplerate == 44100)
    #expect(row.location == "/iPod_Control/Music/F03/XQRZ.mp3")
    #expect(!(row.isFavorite))
  }

  @Test
  func testDeviceRowFallsBackToFilenameWhenUntitled() {
    var track = ITDBTrack()
    track.ipodPath = ":iPod_Control:Music:F03:XQRZ.mp3"

    #expect(SongRow(deviceTrack: track).title == "XQRZ.mp3")
  }

  @Test
  func testDeviceRowRatingRoundsDownToWholeStars() {
    var track = ITDBTrack()
    track.rating = 50
    #expect(SongRow(deviceTrack: track).rating == 2)
    track.rating = 100
    #expect(SongRow(deviceTrack: track).rating == 5)
    track.rating = 0
    #expect(SongRow(deviceTrack: track).rating == 0)
  }

  @Test
  func testMissingValuesRenderAsEmptyCellsRatherThanZeros() {
    let row = SongRow<UInt64>(
      id: 1, title: "Untagged", durationMS: 0, artist: "", album: "", genre: "")

    #expect(row.yearText == "")
    #expect(row.trackNumberText == "")
    #expect(row.discNumberText == "")
    #expect(row.bpmText == "")
    #expect(row.sizeText == "")
    #expect(row.bitrateText == "")
    #expect(row.samplerateText == "")
    #expect(row.dateModifiedText == "")
  }

  @Test
  func testDerivedValuesCarryTheirUnits() {
    let row = SongRow<UInt64>(
      id: 1, title: "Song", durationMS: 249_000, artist: "", album: "", genre: "",
      year: 2000, rating: 3, bitrate: 192, samplerate: 44100)

    #expect(row.timeText == "4:09")
    #expect(row.yearText == "2000")
    #expect(row.bitrateText == "192 kbps")
    #expect(row.ratingText == "★★★")
    #expect(row.samplerateText == "44.1 kHz")
    #expect(
      SongRow<UInt64>(
        id: 2, title: "Song", durationMS: 0, artist: "", album: "", genre: "",
        samplerate: 48000
      ).samplerateText == "48 kHz")
    #expect(
      SongRow<UInt64>(
        id: 3, title: "Song", durationMS: 0, artist: "", album: "", genre: "",
        samplerate: 8000
      ).samplerateText == "8 kHz")
  }

  @Test
  func testRatingTextNeverExceedsFiveStars() {
    #expect(
      SongRow<UInt64>(
        id: 1, title: "Song", durationMS: 0, artist: "", album: "", genre: "", rating: 9
      ).ratingText == "★★★★★")
    #expect(
      SongRow<UInt64>(
        id: 2, title: "Song", durationMS: 0, artist: "", album: "", genre: "", rating: -1
      ).ratingText == "")
  }

  @Test
  func testUndatedRowsSortToOneEndRatherThanAmongTheDated() {
    let played = SongRow<UInt64>(
      id: 1, title: "Played", durationMS: 0, artist: "", album: "", genre: "",
      lastPlayedAt: Date(timeIntervalSince1970: 1_000_000),
      dateModified: Date(timeIntervalSince1970: 1_000_000))
    let never = SongRow<UInt64>(
      id: 2, title: "Never", durationMS: 0, artist: "", album: "", genre: "")

    #expect(never.lastPlayedSortKey == .distantPast)
    #expect(never.dateModifiedSortKey == .distantPast)
    #expect(never.lastPlayedSortKey < played.lastPlayedSortKey)
    #expect(never.dateModifiedSortKey < played.dateModifiedSortKey)
  }

  @Test
  func testTableRowCopiesShareTheirImmutableMetadataPayload() {
    let row = SongRow<UInt64>(
      id: 1, title: "Song", durationMS: 1, artist: "Artist", album: "Album", genre: "Rock")
    let rows = [row]
    let copy = rows

    #expect(rows[0] === copy[0])
  }

  @Test
  func testDistinctRowsStillCompareEveryMetadataValue() {
    let original = SongRow<UInt64>(
      id: 1, title: "Song", durationMS: 1, artist: "Artist", album: "Album", genre: "Rock",
      rating: 3)
    let equalCopy = SongRow<UInt64>(
      id: 1, title: "Song", durationMS: 1, artist: "Artist", album: "Album", genre: "Rock",
      rating: 3)
    let changed = SongRow<UInt64>(
      id: 1, title: "Song", durationMS: 1, artist: "Artist", album: "Album", genre: "Rock",
      rating: 4)

    #expect(original == equalCopy)
    #expect(original != changed)
  }

  @Test
  func testEveryColumnHasADistinctNamespacedIDAndTitle() {
    let ids = SongTableColumn.allCases.map(\.customizationID)
    let titles = SongTableColumn.allCases.map(\.title)

    #expect(Set(ids).count == ids.count)
    #expect(Set(titles).count == titles.count)
    #expect(ids.allSatisfy { $0.hasPrefix("song.") })
    #expect(titles.allSatisfy { !$0.isEmpty })
    #expect(!(ids.contains("song.title")))
  }

  @Test
  func testTheDefaultLayoutIsTheOneTheTableAlwaysHad() {
    let visible = SongTableColumn.allCases.filter(\.isVisibleByDefault)

    #expect(visible == [.time, .artist, .album, .genre])
  }
}
