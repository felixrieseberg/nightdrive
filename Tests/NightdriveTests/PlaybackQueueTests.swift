import Foundation
import Testing

@testable import Nightdrive

struct PlaybackQueueTests {
  @Test
  func testActivateBuildsQueueAroundChosenTrackAndClearsHistory() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three"].map(track)
    queue.load(tracks, currentID: tracks[0].id)
    queue.record(tracks[0])
    #expect(queue.history.count == 1)

    queue.activate(tracks[1], in: tracks)

    #expect(queue.tracks.map(\.title) == ["One", "Two", "Three"])
    #expect(queue.currentIndex == 1)
    #expect(queue.history.isEmpty)
  }

  @Test
  func testActivateWithShufflePutsChosenTrackFirstAndKeepsMembership() {
    var queue = PlaybackQueue()
    queue.isShuffleEnabled = true
    let tracks = ["One", "Two", "Three", "Four"].map(track)

    queue.activate(tracks[2], in: tracks)

    #expect(queue.tracks.first?.title == "Three")
    #expect(queue.currentIndex == 0)
    #expect(Set(queue.tracks.map(\.url)) == Set(tracks.map(\.url)))
  }

  @Test
  func testActivateWithTrackOutsideSourcePrependsIt() {
    var queue = PlaybackQueue()
    let source = ["One", "Two"].map(track)
    let outsider = track("Outsider")

    queue.activate(outsider, in: source)

    #expect(queue.tracks.map(\.title) == ["Outsider", "One", "Two"])
    #expect(queue.currentIndex == 0)
  }

  @Test
  func testHistoryEntriesPairTrackWithQueueIndexAndAreCapped() {
    var queue = PlaybackQueue()
    let tracks = (0..<3).map { track("T\($0)") }
    queue.load(tracks, currentID: tracks[1].id)

    for round in 0..<(PlaybackQueue.maxHistory + 25) {
      queue.record(tracks[round % tracks.count])
    }

    #expect(queue.history.count == PlaybackQueue.maxHistory)
    #expect(queue.history.allSatisfy { $0.queueIndex == 1 })
    #expect(queue.history.first?.track.title == "T\(25 % tracks.count)")
  }

  @Test
  func testAdvanceIndexStopsAtEndWithRepeatOff() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two"].map(track)
    queue.load(tracks, currentID: tracks[1].id)

    #expect(queue.advanceIndex(by: 1, automatic: true) == nil)
  }

  @Test
  func testAdvanceIndexWrapsWithRepeatAll() {
    var queue = PlaybackQueue()
    queue.repeatMode = .all
    let tracks = ["One", "Two"].map(track)
    queue.load(tracks, currentID: tracks[1].id)

    #expect(queue.advanceIndex(by: 1, automatic: true) == 0)
    queue.currentIndex = 0
    #expect(queue.advanceIndex(by: -1, automatic: false) == 1)
  }

  @Test
  func testAutomaticAdvanceRepeatsCurrentWithRepeatOne() {
    var queue = PlaybackQueue()
    queue.repeatMode = .one
    let tracks = ["One", "Two"].map(track)
    queue.load(tracks, currentID: tracks[0].id)

    #expect(queue.advanceIndex(by: 1, automatic: true) == 0)
    #expect(queue.advanceIndex(by: 1, automatic: false) == 1)
  }

  @Test
  func testShuffledRepeatAllWrapReshufflesWithoutImmediateRepeat() {
    var queue = PlaybackQueue()
    queue.repeatMode = .all
    queue.isShuffleEnabled = true
    let tracks = (0..<8).map { track("T\($0)") }
    let lastID = tracks.last!.id
    for _ in 0..<20 {
      queue.load(tracks, currentID: lastID)
      let target = queue.advanceIndex(by: 1, automatic: true)
      #expect(target == 0)
      #expect(queue.tracks.first?.id != lastID)
      #expect(Set(queue.tracks.map(\.url)) == Set(tracks.map(\.url)))
    }
  }

  @Test
  func testPromoteMovesUpcomingTrackAfterCurrentAndRecordsHistory() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three", "Four"].map(track)
    queue.load(tracks, currentID: tracks[0].id)

    let selected = queue.promote(at: 3, recording: tracks[0])

    #expect(selected?.title == "Four")
    #expect(queue.tracks.map(\.title) == ["One", "Four", "Two", "Three"])
    #expect(queue.currentIndex == 1)
    #expect(queue.history.map(\.track.title) == ["One"])
    #expect(queue.history.map(\.queueIndex) == [0])
  }

  @Test
  func testPromoteWithNothingCurrentMovesSelectionToFront() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three"].map(track)
    queue.load(tracks, currentID: nil)
    queue.record(tracks[0])

    let selected = queue.promote(at: 2, recording: nil)

    #expect(selected?.title == "Three")
    #expect(queue.tracks.map(\.title) == ["Three", "One", "Two"])
    #expect(queue.currentIndex == 0)
    #expect(queue.history.isEmpty)
  }

  @Test
  func testUpNextEditsKeepCurrentPrefixIntact() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three", "Four"].map(track)
    queue.load(tracks, currentID: tracks[1].id)

    queue.insertNext(track("Inserted"))
    #expect(queue.upNext.map(\.title) == ["Inserted", "Three", "Four"])

    queue.moveUpNext(from: IndexSet(integer: 2), to: 0)
    #expect(queue.upNext.map(\.title) == ["Four", "Inserted", "Three"])

    queue.removeUpNext(at: IndexSet(integer: 1))
    #expect(queue.upNext.map(\.title) == ["Four", "Three"])

    queue.replaceUpNext(with: [])
    #expect(queue.upNext.isEmpty)
    #expect(queue.tracks.map(\.title) == ["One", "Two"])
    #expect(queue.currentIndex == 1)
  }

  @Test
  func testRemoveTrackDropsDuplicatesAndKeepsCurrentPointedAtSameItem() {
    var queue = PlaybackQueue()
    let dupe = track("Dupe")
    let current = track("Current")
    queue.load([dupe, dupe, current, dupe], currentID: current.id)

    queue.removeTrack(id: dupe.id)

    #expect(queue.tracks.map(\.title) == ["Current"])
    #expect(queue.currentIndex == 0)
  }

  @Test
  func testReconciledRemapsQueueHistoryAndCurrentIndex() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three"].map(track)
    queue.load(tracks, currentID: tracks[0].id)
    queue.record(tracks[0])
    queue.currentIndex = 1
    queue.record(tracks[1])
    queue.currentIndex = 2

    var refreshedTwo = tracks[1]
    refreshedTwo.title = "Two (Edited)"
    let (reconciled, map) = queue.reconciled(with: LibraryCatalog([refreshedTwo, tracks[2]]))

    #expect(reconciled.tracks.map(\.title) == ["Two (Edited)", "Three"])
    #expect(reconciled.currentIndex == 1)
    #expect(map == [1: 0, 2: 1])
    #expect(reconciled.history.map(\.track.title) == ["Two (Edited)"])
    #expect(reconciled.history.map(\.queueIndex) == [0])
  }

  @Test
  func testReconciledClearsCurrentIndexWhenCurrentEntryDisappears() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two"].map(track)
    queue.load(tracks, currentID: tracks[0].id)

    let (reconciled, _) = queue.reconciled(with: LibraryCatalog([tracks[1]]))

    #expect(reconciled.tracks.map(\.title) == ["Two"])
    #expect(reconciled.currentIndex == nil)
  }

  @Test
  func testIndexOfTrackPrefersStoredIndexThenNearestEarlierOccurrence() {
    var queue = PlaybackQueue()
    let dupe = track("Dupe")
    let other = track("Other")
    queue.load([dupe, other, dupe, other, dupe], currentID: nil)
    queue.currentIndex = 3

    #expect(queue.index(of: dupe, preferring: 2) == 2)
    #expect(queue.index(of: dupe, preferring: 1) == 2)
    #expect(queue.index(of: dupe, preferring: nil) == 2)
    #expect(queue.index(of: track("Missing"), preferring: nil) == nil)
  }

  @Test
  func testSuccessorIndicesHonorRepeatModes() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three"].map(track)
    queue.load(tracks, currentID: tracks[1].id)

    #expect(queue.successorIndices(after: 1) == [2])

    queue.repeatMode = .one
    #expect(queue.successorIndices(after: 1) == [1])

    queue.repeatMode = .all
    #expect(queue.successorIndices(after: 2) == [0, 1, 2])
    queue.isShuffleEnabled = true
    #expect(queue.successorIndices(after: 2) == [])
  }

  @Test
  func testRecoveryIndexSkipsAttemptedAndWrapsOnlyWithRepeatAll() {
    var queue = PlaybackQueue()
    let tracks = ["One", "Two", "Three"].map(track)
    queue.load(tracks, currentID: tracks[0].id)

    #expect(queue.recoveryIndex(after: 0, excluding: [1]) == 2)
    #expect(queue.recoveryIndex(after: 2, excluding: []) == nil)

    queue.repeatMode = .all
    #expect(queue.recoveryIndex(after: 2, excluding: [0]) == 1)
  }

  private func track(_ title: String) -> LibraryTrack {
    LibraryTrack(
      url: URL(fileURLWithPath: "/tmp/\(title).mp3"), title: title, artist: "Artist", album: "Album", genre: "Genre",
      durationMS: 1_000, sizeBytes: 1, bitrate: 128, samplerate: 44_100)
  }
}
