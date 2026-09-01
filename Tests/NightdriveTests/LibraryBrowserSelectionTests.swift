import Foundation
import Testing

@testable import Nightdrive

struct LibraryBrowserSelectionTests {
  private let albumAID = LibraryCollectionID(kind: .album, primary: "a", secondary: "")
  private let albumBID = LibraryCollectionID(kind: .album, primary: "b", secondary: "")

  @Test
  func testSelectingTrackKeepsMultiCollectionScope() {
    let fixture = makeFixture()
    let transition = LibraryBrowserSelection.transition(
      for: .tracks(Set([fixture.trackAID])),
      currentCollectionIDs: Set([albumAID, albumBID]),
      selectedTrackIDs: Set([fixture.trackAID, fixture.trackBID]),
      collections: fixture.collections)

    #expect(transition.collectionIDs == Set([albumAID, albumBID]))
    #expect(transition.trackIDs == Set([fixture.trackAID]))
  }

  @Test
  func testExpandingCollectionScopeDoesNotDropNewCollection() {
    let fixture = makeFixture()
    let transition = LibraryBrowserSelection.transition(
      for: .collections(Set([albumAID, albumBID])),
      currentCollectionIDs: Set([albumAID]),
      selectedTrackIDs: Set([fixture.trackAID]),
      collections: fixture.collections)

    #expect(transition.collectionIDs == Set([albumAID, albumBID]))
    #expect(transition.trackIDs == Set([fixture.trackAID]))
  }

  @Test
  func testDestinationProjectsSharedTracksButCollectionRefreshPreservesScope() {
    let fixture = makeFixture()
    let destination = LibraryBrowserSelection.transition(
      for: .destination,
      currentCollectionIDs: [],
      selectedTrackIDs: Set([fixture.trackBID]),
      collections: fixture.collections)
    #expect(destination.collectionIDs == Set([albumBID]))

    let refresh = LibraryBrowserSelection.transition(
      for: .collectionData,
      currentCollectionIDs: Set([albumAID, albumBID]),
      selectedTrackIDs: Set([fixture.trackAID]),
      collections: fixture.collections)
    #expect(refresh.collectionIDs == Set([albumAID, albumBID]))
  }

  @Test
  func testDestinationUsesPreparedProjectionAndValidityIndexes() {
    let fixture = makeFixture()
    let transition = LibraryBrowserSelection.transition(
      for: .destination,
      currentCollectionIDs: Set([albumAID]),
      selectedTrackIDs: Set([fixture.trackAID]),
      collections: fixture.collections,
      projectedCollectionIDs: Set([albumBID]),
      isValidCollectionID: { $0 == self.albumBID })

    #expect(transition.collectionIDs == Set([albumBID]))
    #expect(transition.trackIDs == Set([fixture.trackAID]))
  }

  @Test
  func testEmptySpaceContextClickDoesNotActOnSelection() {
    let fixture = makeFixture()
    #expect(
      LibraryBrowserSelection.contextCollectionIDs(
        for: [],
        selectedCollectionIDs: Set([albumAID, albumBID]),
        collections: fixture.collections
      ).isEmpty)

    #expect(
      LibraryBrowserSelection.contextCollectionIDs(
        for: Set([albumAID]),
        selectedCollectionIDs: Set([albumAID, albumBID]),
        collections: fixture.collections) == Set([albumAID, albumBID]))
  }

  private func makeFixture() -> (
    collections: [LibraryCollection], trackAID: TrackID, trackBID: TrackID
  ) {
    let trackA = makeTrack("a")
    let trackB = makeTrack("b")
    return (
      collections: [
        LibraryCollection(id: albumAID, title: "A", subtitle: "Artist · 1 song", tracks: [trackA]),
        LibraryCollection(id: albumBID, title: "B", subtitle: "Artist · 1 song", tracks: [trackB]),
      ],
      trackAID: trackA.id,
      trackBID: trackB.id
    )
  }

  private func makeTrack(_ name: String) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: "/tmp/nightdrive-selection-\(name).mp3"),
      title: name.uppercased(), album: name.uppercased(), genre: "Genre",
      trackNumber: 1, trackCount: 1, discNumber: 1, year: 2026, sizeBytes: 1, bitrate: 320)
  }
}
