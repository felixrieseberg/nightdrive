import Foundation
import Testing

@testable import Nightdrive

struct MediaKindMarkingTests {
  private func makeTrack(
    path: String, genre: String = "Rock", mediaKind: LibraryMediaKind = .song
  ) -> LibraryTrack {
    var track = LibraryTrack(
      url: URL(fileURLWithPath: path), title: "Track", genre: genre,
      trackNumber: 1, durationMS: 1000, sizeBytes: 1000, bitrate: 128, samplerate: 44100)
    track.mediaKind = mediaKind
    return track
  }

  @Test
  func testMarkingAnMP3AsAudiobookMakesAudiobookThePrimaryGenre() throws {
    let track = makeTrack(path: "/Music/book.mp3", genre: "Fantasy")
    let edit = try #require(AppState.mediaKindEdit(for: track, to: .audiobook))
    #expect(edit.metadata.genres == ["Audiobook", "Fantasy"])
    #expect(edit.mediaKindChange == nil)
  }

  @Test
  func testUnmarkingAnMP3RemovesEveryAudiobookGenreSpelling() throws {
    let track = makeTrack(
      path: "/Music/book.mp3", genre: "Audiobook; audiobooks; Fantasy", mediaKind: .audiobook)
    let edit = try #require(AppState.mediaKindEdit(for: track, to: .song))
    #expect(edit.metadata.genres == ["Fantasy"])
    #expect(edit.mediaKindChange == nil)
  }

  @Test
  func testMarkingAnM4AWritesTheMediaKindAtomAndKeepsTheGenre() throws {
    let track = makeTrack(path: "/Music/book.m4a", genre: "Fantasy")
    let edit = try #require(AppState.mediaKindEdit(for: track, to: .audiobook))
    #expect(edit.mediaKindChange == .audiobook)
    #expect(edit.metadata.genres == ["Fantasy"])
  }

  @Test
  func testUnmarkingAnM4AClearsTheAtomAndTheGenreMark() throws {
    let track = makeTrack(path: "/Music/book.m4a", genre: "Audiobook", mediaKind: .audiobook)
    let edit = try #require(AppState.mediaKindEdit(for: track, to: .song))
    #expect(edit.mediaKindChange == .song)
    #expect(edit.metadata.genres.isEmpty)
  }

  @Test
  func testMarkingAnUntitledTrackDoesNotPersistTheFilenameAsATitle() throws {
    var track = LibraryTrack(
      url: URL(fileURLWithPath: "/Music/untitled-book.mp3"), title: "",
      genre: "Fantasy", trackNumber: 1, durationMS: 1000, sizeBytes: 1000,
      bitrate: 128, samplerate: 44100)
    track.mediaKind = .song
    let edit = try #require(AppState.mediaKindEdit(for: track, to: .audiobook))
    #expect(edit.metadata.title.isEmpty)
  }

  @Test
  func testImpossibleMediaKindChangesProduceNoEdit() {
    // The extension fixes an .m4b as an audiobook.
    let m4b = makeTrack(path: "/Music/book.m4b", mediaKind: .audiobook)
    #expect(AppState.mediaKindEdit(for: m4b, to: .song) == nil)
    #expect(AppState.mediaKindEdit(for: m4b, to: .audiobook) == nil)

    // Formats without editable metadata cannot carry the mark.
    let wav = makeTrack(path: "/Music/book.wav")
    #expect(AppState.mediaKindEdit(for: wav, to: .audiobook) == nil)

    // Already the requested kind.
    let song = makeTrack(path: "/Music/song.mp3")
    #expect(AppState.mediaKindEdit(for: song, to: .song) == nil)

    // A podcast never becomes a target kind through this path.
    let mp3 = makeTrack(path: "/Music/episode.mp3")
    #expect(AppState.mediaKindEdit(for: mp3, to: .podcast) == nil)
  }

  @Test
  func testCanSetMediaKindMirrorsEditAvailability() {
    let mp3 = makeTrack(path: "/Music/song.mp3")
    #expect(AppState.canSetMediaKind(.audiobook, for: mp3))
    #expect(!AppState.canSetMediaKind(.song, for: mp3))

    let m4b = makeTrack(path: "/Music/book.m4b", mediaKind: .audiobook)
    #expect(!AppState.canSetMediaKind(.song, for: m4b))
  }
}
