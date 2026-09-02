import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct MusicBrainzAutoLookupTests {

  @MainActor
  @Test
  func testEngineNeverFiresWithoutConsentAndToggle() async {
    let combinations: [(OnlineServicesConsent, Bool)] = [
      (.unset, true), (.disabled, true), (.enabled, false), (.unset, false), (.disabled, false),
    ]
    for (consent, autoLookup) in combinations {
      let policy = OnlineServicesPolicy(persistence: MemoryPersistence())
      policy.setConsent(consent)
      policy.setAutoLookup(autoLookup)
      let service = FakeMusicBrainzService()
      let store = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
      let tracks = [makeTrack(name: "a.mp3", title: "Airbag", album: "OK Computer")]
      let engine = MusicBrainzAutoLookupEngine(
        policy: policy, store: store, service: service, tracks: { tracks })

      engine.refresh()
      await engine.waitUntilIdle()

      let searches = await service.releaseSearches.count
      let fetches = await service.releaseFetches.count
      #expect(searches == 0, Comment(rawValue: "No search may run for consent=\(consent) auto=\(autoLookup)"))
      #expect(fetches == 0)
      #expect(store.suggestions.isEmpty)
    }
  }

  @MainActor
  @Test
  func testEngineFillsInboxForAlbumMissingIDs() async throws {
    let (policy, service, store) = makeActiveFixtures()
    let tracks = [
      makeTrack(name: "01.mp3", title: "Wrong Title", album: "OK Computer", track: 1),
      makeTrack(name: "02.mp3", title: "Also Wrong", album: "OK Computer", track: 2),
    ]
    let engine = MusicBrainzAutoLookupEngine(
      policy: policy, store: store, service: service, tracks: { tracks })

    engine.refresh()
    await engine.waitUntilIdle()

    let searches = await service.releaseSearches
    #expect(searches.count == 1)
    #expect(searches.first?.artist == "Radiohead")
    #expect(searches.first?.releaseTitle == "OK Computer")
    let fetches = await service.releaseFetches
    #expect(fetches == ["release-1"])

    #expect(store.suggestions.count == 1)
    let suggestion = try #require(store.suggestions.first)
    #expect(suggestion.releaseID == "release-1")
    #expect(suggestion.releaseTitle == "OK Computer")
    #expect(suggestion.releaseYear == 1997)
    #expect(suggestion.tracks.count == 2)
    #expect(suggestion.tracks[0].proposed.title == "Airbag")
    #expect(suggestion.tracks[0].proposed.musicBrainzReleaseID == "release-1")
    #expect(suggestion.tracks[0].current.title == "Wrong Title")
    #expect(!(engine.isRunning))
    #expect(engine.lastError == nil)
  }

  @MainActor
  @Test
  func testEngineSkipsDismissedTaggedAndAlreadySuggestedAlbums() async {
    let (policy, service, store) = makeActiveFixtures()
    store.dismiss(
      albumID: MusicBrainzSuggestionStore.albumKey(album: "Dismissed LP", artist: "Radiohead"))
    let tracks = [
      makeTrack(name: "d1.mp3", title: "One", album: "Dismissed LP"),
      makeTrack(name: "t1.mp3", title: "Two", album: "Tagged LP", releaseID: "already-tagged"),
      makeTrack(name: "f1.flac", title: "Three", album: "Lossless LP"),
      makeTrack(name: "n1.mp3", title: "Four", album: ""),
      makeTrack(name: "w1.mp3", title: "Wrong Title", album: "OK Computer", track: 1),
    ]
    let engine = MusicBrainzAutoLookupEngine(
      policy: policy, store: store, service: service, tracks: { tracks })

    engine.refresh()
    await engine.waitUntilIdle()

    let searches = await service.releaseSearches
    #expect(searches.map(\.releaseTitle) == ["OK Computer"])
    #expect(store.suggestions.count == 1)

    engine.refresh()
    await engine.waitUntilIdle()
    let searchesAfterSecondPass = await service.releaseSearches
    #expect(searchesAfterSecondPass.count == 1)
  }

  @MainActor
  @Test
  func testEngineIgnoresLowScoreMatches() async {
    let (policy, service, store) = makeActiveFixtures()
    await service.setCandidates([
      MusicBrainzReleaseCandidate(
        id: "release-1", score: 60, title: "OK Computer", artistName: "Radiohead",
        date: "1997-05-21", country: "GB", trackCount: 2)
    ])
    let tracks = [makeTrack(name: "01.mp3", title: "Wrong", album: "OK Computer", track: 1)]
    let engine = MusicBrainzAutoLookupEngine(
      policy: policy, store: store, service: service, tracks: { tracks })

    engine.refresh()
    await engine.waitUntilIdle()

    let fetches = await service.releaseFetches
    #expect(fetches.isEmpty, Comment(rawValue: "A speculative match must not be fetched or suggested"))
    #expect(store.suggestions.isEmpty)
  }

  @MainActor
  @Test
  func testEnginePrefersTrackCountMatchOverScore() async {
    let (policy, service, store) = makeActiveFixtures()
    await service.setCandidates([
      MusicBrainzReleaseCandidate(
        id: "deluxe", score: 100, title: "OK Computer", artistName: "Radiohead",
        date: "2017-06-23", country: "GB", trackCount: 23),
      MusicBrainzReleaseCandidate(
        id: "release-1", score: 95, title: "OK Computer", artistName: "Radiohead",
        date: "1997-05-21", country: "GB", trackCount: 2),
    ])
    let tracks = [
      makeTrack(name: "01.mp3", title: "Wrong", album: "OK Computer", track: 1),
      makeTrack(name: "02.mp3", title: "Wronger", album: "OK Computer", track: 2),
    ]
    let engine = MusicBrainzAutoLookupEngine(
      policy: policy, store: store, service: service, tracks: { tracks })

    engine.refresh()
    await engine.waitUntilIdle()

    let fetches = await service.releaseFetches
    #expect(fetches == ["release-1"])
  }

  @MainActor
  @Test
  func testSuggestionStoreRoundTripsIncludingDismissals() throws {
    let persistence = MemoryPersistence()
    let store = MusicBrainzSuggestionStore(persistence: persistence)
    let suggestion = makeSuggestion(albumTitle: "OK Computer")
    store.add(suggestion)
    store.dismiss(
      albumID: MusicBrainzSuggestionStore.albumKey(album: "Rejected LP", artist: "Someone"))

    let reloaded = MusicBrainzSuggestionStore(persistence: persistence)
    #expect(reloaded.suggestions == [suggestion])
    #expect(
      reloaded.isDismissed(
        albumKey: MusicBrainzSuggestionStore.albumKey(album: "Rejected LP", artist: "Someone")))
    #expect(reloaded.persistenceError == nil)

    reloaded.dismiss(albumID: suggestion.id)
    #expect(reloaded.suggestions.isEmpty)
    let final = MusicBrainzSuggestionStore(persistence: persistence)
    #expect(final.suggestions.isEmpty)
    #expect(final.isDismissed(albumKey: suggestion.id))
    final.add(suggestion)
    #expect(final.suggestions.isEmpty, Comment(rawValue: "A dismissed album must not be re-suggested"))
  }

  @MainActor
  @Test
  func testPruneDropsMissingAndStaleTracks() {
    let store = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
    let fresh = makeSuggestion(albumTitle: "Fresh LP")
    let stale = makeSuggestion(albumTitle: "Stale LP")
    let orphaned = makeSuggestion(albumTitle: "Gone LP")
    store.add(fresh)
    store.add(stale)
    store.add(orphaned)

    var changedMetadata = stale.tracks[0].current
    changedMetadata.genre = "Edited Since"
    store.prune(against: { key in
      if let track = fresh.tracks.first(where: { $0.trackKey == key }) { return track.current }
      if stale.tracks.contains(where: { $0.trackKey == key }) { return changedMetadata }
      return nil
    })

    #expect(store.suggestions == [fresh])
  }

  @MainActor
  @Test
  func testEnginePrunesStaleSuggestionsOnRefresh() async {
    let (policy, service, store) = makeActiveFixtures()
    let tracks = [
      makeTrack(name: "01.mp3", title: "Wrong Title", album: "OK Computer", track: 1)
    ]
    var orphan = makeSuggestion(albumTitle: "OK Computer")
    orphan.id = MusicBrainzSuggestionStore.albumKey(album: "OK Computer", artist: "Radiohead")
    store.add(orphan)

    let engine = MusicBrainzAutoLookupEngine(
      policy: policy, store: store, service: service, tracks: { tracks })
    engine.refresh()
    await engine.waitUntilIdle()

    #expect(store.suggestions.count == 1)
    #expect(store.suggestions.first?.releaseID == "release-1")
    let searches = await service.releaseSearches
    #expect(searches.count == 1)
  }

  @MainActor
  @Test
  func testCandidateAlbumsKeepUntaggedCompilationTogether() {
    let store = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
    let tracks = [
      makeTrack(name: "ost1.mp3", title: "Opening", album: "Best OST", artist: "Artist A", track: 1),
      makeTrack(name: "ost2.mp3", title: "Chase", album: "Best OST", artist: "Artist B", track: 2),
      makeTrack(name: "ost3.mp3", title: "Finale", album: "Best OST", artist: "Artist C", track: 3),
    ]

    let albums = MusicBrainzAutoLookupEngine.candidateAlbums(in: tracks, store: store)

    #expect(albums.count == 1, Comment(rawValue: "A shared folder and album must not fragment by track artist"))
    #expect(albums.first?.title == "Best OST")
    #expect(albums.first?.artist == "Various Artists")
    #expect(albums.first?.tracks.count == 3)
  }

  @MainActor
  @Test
  func testPolicyPersistsAutoLookupIndependently() {
    let persistence = MemoryPersistence()
    let policy = OnlineServicesPolicy(persistence: persistence)
    policy.setConsent(.enabled)
    policy.setAutoLookup(false)

    let reloaded = OnlineServicesPolicy(persistence: persistence)
    #expect(reloaded.consent == .enabled)
    #expect(!(reloaded.autoLookup))
    #expect(!(reloaded.isAutoLookupActive))
  }

  @MainActor
  @Test
  func testPodcastsDefaultOnButMalformedPolicyFailsClosed() {
    let fresh = OnlineServicesPolicy(persistence: MemoryPersistence())
    #expect(fresh.isPodcastsEnabled)
    #expect(fresh.isPodcastAutoRefreshActive)

    let garbage = MemoryPersistence()
    try? garbage.save(Data("not json".utf8))
    let recovered = OnlineServicesPolicy(persistence: garbage)
    #expect(!recovered.isEnabled)
    #expect(!recovered.isAutoLookupActive)
    #expect(
      !recovered.isPodcastsEnabled,
      Comment(rawValue: "unreadable consent must not turn background feed refresh on"))
    #expect(!recovered.isPodcastAutoRefreshActive)
    #expect(recovered.persistenceError == nil)

    recovered.setPodcastsConsent(.enabled)
    #expect(recovered.isPodcastsEnabled)
    #expect(!recovered.isPodcastAutoRefreshActive)
    #expect(OnlineServicesPolicy(persistence: garbage).isPodcastsEnabled)
  }

  @MainActor
  @Test
  func testAutoLookupIsNeverActiveWithoutConsent() {
    let policy = OnlineServicesPolicy(persistence: MemoryPersistence())
    #expect(policy.autoLookup)
    #expect(!(policy.isAutoLookupActive), Comment(rawValue: "Unset consent blocks automatic lookup"))
    policy.setConsent(.disabled)
    #expect(!(policy.isAutoLookupActive))
    policy.setConsent(.enabled)
    #expect(policy.isAutoLookupActive)
  }

  @MainActor
  private func makeActiveFixtures() -> (
    OnlineServicesPolicy, FakeMusicBrainzService, MusicBrainzSuggestionStore
  ) {
    let policy = OnlineServicesPolicy(persistence: MemoryPersistence())
    policy.setConsent(.enabled)
    let service = FakeMusicBrainzService()
    let store = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
    return (policy, service, store)
  }

  private func makeTrack(
    name: String, title: String, album: String,
    artist: String = "Radiohead", track: Int = 0, releaseID: String = ""
  ) -> LibraryTrack {
    var track = LibraryTrack.fixture(
      url: URL(fileURLWithPath: "/library/\(name)"), title: title, artist: artist,
      album: album, trackNumber: track, sizeBytes: 4096, bitrate: 128_000)
    track.musicBrainzReleaseID = releaseID
    return track
  }

  private func makeSuggestion(albumTitle: String) -> MusicBrainzAlbumSuggestion {
    let current = TrackMetadata(
      title: "Old", artist: "Radiohead", album: albumTitle, albumArtist: "", composer: "",
      genre: "", grouping: "", year: 0, bpm: 0, trackNumber: 1, trackCount: 0,
      discNumber: 0, discCount: 0, comment: "", lyrics: "", compilation: false)
    var proposed = current
    proposed.title = "New"
    proposed.musicBrainzReleaseID = "some-release"
    return MusicBrainzAlbumSuggestion(
      id: MusicBrainzSuggestionStore.albumKey(album: albumTitle, artist: "Radiohead"),
      albumTitle: albumTitle,
      artistName: "Radiohead",
      releaseID: "some-release",
      releaseTitle: albumTitle,
      releaseYear: 1997,
      tracks: [
        MusicBrainzTrackSuggestion(
          trackKey: "file:///library/\(albumTitle.replacingOccurrences(of: " ", with: ""))-1.mp3",
          displayTitle: "Old",
          current: current,
          proposed: proposed)
      ])
  }
}

private actor FakeMusicBrainzService: MusicBrainzService {
  private(set) var releaseSearches: [(artist: String, releaseTitle: String)] = []
  private(set) var releaseFetches: [String] = []
  private var candidates: [MusicBrainzReleaseCandidate] = [
    MusicBrainzReleaseCandidate(
      id: "release-1", score: 100, title: "OK Computer", artistName: "Radiohead",
      date: "1997-05-21", country: "GB", trackCount: 2)
  ]
  private var releasesByID: [String: MusicBrainzRelease] = [
    "release-1": MusicBrainzRelease(
      id: "release-1",
      title: "OK Computer",
      artistName: "Radiohead",
      artistID: "artist-1",
      date: "1997-05-21",
      discCount: 1,
      tracks: [
        MusicBrainzReleaseTrack(
          recordingID: "rec-1", title: "Airbag", artistName: "Radiohead",
          artistID: "artist-1", discNumber: 1, trackNumber: 1, trackCount: 2),
        MusicBrainzReleaseTrack(
          recordingID: "rec-2", title: "Paranoid Android", artistName: "Radiohead",
          artistID: "artist-1", discNumber: 1, trackNumber: 2, trackCount: 2),
      ])
  ]

  func setCandidates(_ candidates: [MusicBrainzReleaseCandidate]) {
    self.candidates = candidates
  }

  func searchRecordings(
    title: String, artist: String, album: String
  ) async throws -> [MusicBrainzRecordingCandidate] {
    Issue.record("The auto-lookup engine must use release searches, not recording searches")
    return []
  }

  func searchReleases(
    artist: String, releaseTitle: String
  ) async throws -> [MusicBrainzReleaseCandidate] {
    releaseSearches.append((artist, releaseTitle))
    return candidates
  }

  func release(withID id: String) async throws -> MusicBrainzRelease {
    releaseFetches.append(id)
    guard let release = releasesByID[id] else {
      throw MusicBrainzError.malformedResponse("No canned release for \(id)")
    }
    return release
  }

  func genreNames() async throws -> Set<String> { [] }
}

private final class MemoryPersistence: AppDataPersistence {
  private struct State {
    var data: Data?
    var error: Error?
  }

  private let state = Mutex(State())

  func load() throws -> Data? {
    try state.withLock { state in
      if let error = state.error { throw error }
      return state.data
    }
  }

  func save(_ data: Data) throws {
    try state.withLock { state in
      if let error = state.error { throw error }
      state.data = data
    }
  }
}
