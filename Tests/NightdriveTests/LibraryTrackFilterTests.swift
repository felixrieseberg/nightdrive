import Foundation
import Testing

@testable import Nightdrive

struct LibraryTrackFilterTests {
  @Test
  func testMatchingIDsMirrorSongRowFieldMatching() throws {
    let vogue = LibraryTrack.fixture(
      url: URL(fileURLWithPath: "/tmp/nightdrive-filter-vogue.mp3"),
      title: "Vogue", artist: "Madonna", album: "Celebration", genre: "Pop")
    let toxic = LibraryTrack.fixture(
      url: URL(fileURLWithPath: "/tmp/nightdrive-filter-toxic.mp3"),
      title: "Toxic", artist: "Britney Spears", album: "In the Zone", genre: "Dance")
    let index = LibraryTrackSearchIndex(tracks: [vogue, toxic])

    #expect(try index.matchingIDs(for: "vogue") == [vogue.id])
    #expect(try index.matchingIDs(for: "MADONNA") == [vogue.id])
    #expect(try index.matchingIDs(for: "the zone") == [toxic.id])
    #expect(try index.matchingIDs(for: "dance") == [toxic.id])
    #expect(try index.matchingIDs(for: "o") == [vogue.id, toxic.id])
    #expect(try index.matchingIDs(for: "no such song").isEmpty)
  }

  @Test
  func testMatchingAgreesWithSongRowMatches() throws {
    let tracks = [
      LibraryTrack.fixture(
        url: URL(fileURLWithPath: "/tmp/nightdrive-filter-parity-1.mp3"),
        title: "Ray of Light", artist: "Madonna", album: "Ray of Light", genre: "Electronica"),
      LibraryTrack.fixture(
        url: URL(fileURLWithPath: "/tmp/nightdrive-filter-parity-2.mp3"),
        title: "Frozen", artist: "MADONNA", album: "", genre: ""),
    ]
    let index = LibraryTrackSearchIndex(tracks: tracks)

    for query in ["ray", "madonna", "FROZEN", "electronica", "light", "zzz"] {
      let expected = Set(
        tracks.filter { SongRow(track: $0, listening: nil).matches(query) }.map(\.id))
      #expect(try index.matchingIDs(for: query) == expected, "query: \(query)")
    }
  }
}
