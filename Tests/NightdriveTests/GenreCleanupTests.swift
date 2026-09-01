import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Nightdrive

struct GenreCleanupTests {
  @Test
  func testGenreValuesSplitSemicolonsAndNullsWithoutSplittingGenrePunctuation() {
    #expect(
      (GenreMetadata.values(from: " Indie Folk ; Rock\0Dream Pop;indie folk; "))
        == (["Indie Folk", "Rock", "Dream Pop"]))
    #expect((GenreMetadata.values(from: "R&B/Soul, Pop-Rock")) == (["R&B/Soul, Pop-Rock"]))
  }

  @Test
  func testCanonicalValuesTrimAndDeduplicateWhilePreservingOrder() {
    #expect((GenreMetadata.joined([" Rock ", "Indie", "röck", "Dream Pop; Indie"])) == ("Rock; Indie; Dream Pop"))
    #expect((GenreMetadata.primary(from: "Rock; Indie")) == ("Rock"))
  }

  @Test
  func testGenreCompletionsPreferPrefixesAndExcludeExistingValues() {
    #expect(
      (GenreMetadata.completions(
        for: "rock",
        from: ["Electronic Rock", "Rock", "Rockabilly", "Indie Rock", "rock"],
        excluding: ["Rockabilly"])) == (["Rock", "Electronic Rock", "Indie Rock"]))
    #expect((GenreMetadata.completions(for: "", from: ["Rock", "Pop", "Jazz"], limit: 2)) == (["Rock", "Pop"]))
  }

  @MainActor
  @Test
  func testNativeGenreDraftProvidesLibraryCompletionsAndConsumesReturn() {
    var draft = "Po"
    var submitted: String?
    let editor = GenreDraftTokenField(
      text: Binding(get: { draft }, set: { draft = $0 }),
      candidates: ["Electronic", "Post-Punk", "Indie Pop"],
      excluding: ["Electronic"],
      isFocused: .constant(true),
      onSubmit: { submitted = draft }
    )
    let coordinator = GenreDraftTokenField.Coordinator(parent: editor)
    let field = NSTokenField()
    let textView = NSTextView()
    field.stringValue = draft
    textView.string = draft
    var selectedIndex = 0

    let completions =
      coordinator.tokenField(
        field, completionsForSubstring: draft, indexOfToken: 0,
        indexOfSelectedItem: &selectedIndex) as? [String]
    #expect((completions) == (["Post-Punk", "Indie Pop"]))
    #expect((selectedIndex) == (-1))

    #expect(
      coordinator.control(
        field, textView: textView,
        doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect((submitted) == ("Po"))
    #expect((draft) == (""))
    #expect((field.stringValue) == (""))
    #expect((textView.string) == (""))
  }

  @Test
  func testGenreDraftIsCanonicalizedOnlyWhenConfirmed() {
    #expect(
      GenreEditor.confirmedGenres(
        draft: "  ", existing: ["Indie Rock"], makePrimary: false) == nil)
    #expect(
      (GenreEditor.confirmedGenres(
        draft: " Dream Pop ", existing: ["Indie Rock"], makePrimary: false)) == (["Indie Rock", "Dream Pop"]))
    #expect(
      (GenreEditor.confirmedGenres(
        draft: " dream pop ", existing: ["Indie Rock", "Dream Pop"], makePrimary: true))
        == (["dream pop", "Indie Rock"]))
  }

  @Test
  func testEmptyGenreDraftBecomesAChipAsSoonAsItIsFocused() {
    #expect(!(GenreEditor.showsDraftChip(draft: "", isFocused: false)))
    #expect(GenreEditor.showsDraftChip(draft: "", isFocused: true))
    #expect(GenreEditor.showsDraftChip(draft: "Rock", isFocused: false))
  }

  @Test
  func testGenreDraftWidthIsStableFromEmptyToFirstCharacter() {
    let font = NSFont.preferredFont(forTextStyle: .callout)
    let emptyWidth = GenreEditor.draftFieldWidth(for: "", font: font)
    let firstCharacterWidth = GenreEditor.draftFieldWidth(for: "E", font: font)

    #expect((emptyWidth) == (28))
    #expect((firstCharacterWidth) == (emptyWidth))
    #expect((GenreEditor.draftFieldWidth(for: "Electronic", font: font)) > (firstCharacterWidth))
    #expect((GenreEditor.draftFieldWidth(for: String(repeating: "W", count: 100), font: font)) == (240))
  }

  @Test
  func testPlannerGroupsRepeatedPatternsAndPrefersRecognizedGenre() {
    let raw =
      "WSUM 91.7 FM Madison;my top songs;rock and roll over;indie folk;Versus Verses"
    let tracks = [
      makeTrack("one.mp3", genre: raw),
      makeTrack("two.mp3", genre: raw),
      makeTrack("three.mp3", genre: "Rock"),
    ]

    let groups = GenreCleanupPlanner.groups(
      in: tracks, recognizedGenreNames: ["indie folk", "rock"])

    #expect((groups.count) == (1))
    #expect((groups[0].songCount) == (2))
    #expect((groups[0].suggestedPrimary) == ("indie folk"))
    #expect((groups[0].recognizedGenres) == (Set(["indie folk"])))
    #expect(groups[0].hasUnrecognizedGenres)
  }

  @Test
  func testPlannerMarksAllTokensUnrecognizedWhenMusicBrainzKnowsNone() throws {
    let group = try #require(
      GenreCleanupPlanner.groups(
        in: [makeTrack("song.mp3", genre: "station; personal")],
        recognizedGenreNames: ["Rock"]
      ).first)

    #expect(group.hasUnrecognizedGenres)
    #expect(!(group.isRecognized("station")))
    #expect((GenreCleanupSelection(group: group).primary) == (""))
  }

  @Test
  func testPlannerCanCreateSingleOrMultipleGenreEditsWithoutChangingOtherMetadata() throws {
    let track = makeTrack("song.mp3", genre: "Personal; Indie Folk; Dream Pop")
    let group = try #require(
      GenreCleanupPlanner.groups(
        in: [track], recognizedGenreNames: ["Indie Folk", "Dream Pop"]
      ).first)
    var selection = GenreCleanupSelection(group: group)
    #expect((selection.genres) == (["Indie Folk", "Dream Pop"]))
    selection.primary = "Dream Pop"
    selection.genres.append("Shoegaze")

    let one = try #require(
      GenreCleanupPlanner.edits(
        for: [group], selections: [group.id: selection], keepMultiple: false
      ).first)
    #expect((one.metadata.genre) == ("Dream Pop"))
    #expect((one.metadata.title) == (track.title))
    #expect((one.metadata.artist) == (track.artist))

    let multiple = try #require(
      GenreCleanupPlanner.edits(
        for: [group], selections: [group.id: selection], keepMultiple: true
      ).first)
    #expect((multiple.metadata.genre) == ("Dream Pop; Indie Folk; Shoegaze"))
  }

  @Test
  func testDeviceMetadataUsesPrimaryGenreOnlyAndReconciliationPreservesSecondaries() {
    let fileTrack = makeTrack("song.mp3", genre: "Indie Folk; Dream Pop")
    var deviceTrack = ITDBTrack()
    TrackMetadata(fileTrack).applying(to: &deviceTrack)
    #expect((deviceTrack.genre) == ("Indie Folk"))

    deviceTrack.genre = "Folk"
    let reconciled = TrackMetadata(fileTrack: fileTrack, databaseTrack: deviceTrack)
    #expect((reconciled.genres) == (["Folk", "Dream Pop"]))
  }

  @Test
  func testBulkGenreOperationsPreservePerSongLists() {
    let metadata = TrackMetadata(makeTrack("song.mp3", genre: "Indie Folk; Dream Pop"))

    var add = TrackMetadataChanges()
    add.genreOperation = .add("Shoegaze")
    #expect((add.applying(to: metadata).genres) == (["Indie Folk", "Dream Pop", "Shoegaze"]))

    var remove = TrackMetadataChanges()
    remove.genreOperation = .remove("dream pop")
    #expect((remove.applying(to: metadata).genres) == (["Indie Folk"]))

    var primary = TrackMetadataChanges()
    primary.genreOperation = .makePrimary("Dream Pop")
    #expect((primary.applying(to: metadata).genres) == (["Dream Pop", "Indie Folk"]))

    primary.genreOperation = .makePrimary("Folk")
    #expect((primary.applying(to: metadata).genres) == (["Folk", "Indie Folk", "Dream Pop"]))
  }

  @Test
  func testOfflineCleanupRequiresExplicitPrimaryChoice() throws {
    let group = try #require(
      GenreCleanupPlanner.groups(
        in: [makeTrack("song.mp3", genre: "station; Indie Folk")]
      ).first)
    let selection = GenreCleanupSelection(group: group)
    #expect((selection.primary) == (""))
    #expect(
      GenreCleanupPlanner.edits(
        for: [group], selections: [group.id: selection], keepMultiple: false
      ).isEmpty)
  }

  @MainActor
  @Test
  func testCleanupEditsRealMP3AndPreservesOtherTags() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveGenreCleanupTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("song.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Song", artist: "Artist", album: "Album",
        genre: "station tag; Indie Folk; favorites", trackNumber: 3, year: 2007),
      seconds: 1
    ).write(to: url)

    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let group = try #require(
      GenreCleanupPlanner.groups(
        in: store.tracks, recognizedGenreNames: ["Indie Folk"]
      ).first)
    let selection = GenreCleanupSelection(group: group)
    let edits = GenreCleanupPlanner.edits(
      for: [group], selections: [group.id: selection], keepMultiple: false)
    try await AppState(library: store).applyGenreCleanup(edits)

    let updated = try #require(store.tracks.first)
    #expect((updated.genre) == ("Indie Folk"))
    #expect((updated.title) == ("Song"))
    #expect((updated.artist) == ("Artist"))
    #expect((updated.album) == ("Album"))
    #expect((updated.trackNumber) == (3))
    #expect((updated.year) == (2007))
  }

  @MainActor
  @Test
  func testCleanupRejectsReplacementAtMetadataWriteBoundary() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveGenreBoundaryReplacementTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("song.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Original", artist: "Artist", album: "Album", genre: "junk; Rock",
        trackNumber: 1, year: 2000),
      seconds: 1
    ).write(to: url)
    let replacement = MP3Builder.build(
      tags: .init(
        title: "Replacement", artist: "Other", album: "Other", genre: "Rock",
        trackNumber: 1, year: 2020),
      seconds: 2)
    let live = LibraryFileMutations.live
    let library = LibraryStore(
      folderURL: folder,
      fileMutations: LibraryFileMutations(
        writeMetadata: { metadata, artworkChange, mediaKindChange, target, expectedGeneration in
          try replacement.write(to: target, options: .atomic)
          try live.writeMetadata(metadata, artworkChange, mediaKindChange, target, expectedGeneration)
        },
        moveToTrash: live.moveToTrash))
    await library.rescan()
    let app = AppState(library: library)
    let original = try #require(library.tracks.first)
    var cleaned = TrackMetadata(original)
    cleaned.genre = "Rock"

    do {
      try await app.applyGenreCleanup(
        [TrackMetadataEdit(track: original, metadata: cleaned)])
      Issue.record("Cleanup should reject a replacement introduced at the write boundary")
    } catch LibraryStoreError.bulkMetadataUpdateFailed {
    }

    let replacementLibrary = LibraryStore(folderURL: folder)
    await replacementLibrary.rescan()
    #expect((replacementLibrary.tracks.first?.title) == ("Replacement"))
    #expect((replacementLibrary.tracks.first?.genre) == ("Rock"))
  }

  private func makeTrack(_ name: String, genre: String) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: "/tmp/genre-cleanup/\(name)"),
      title: name, genre: genre, sizeBytes: 1_024)
  }
}
