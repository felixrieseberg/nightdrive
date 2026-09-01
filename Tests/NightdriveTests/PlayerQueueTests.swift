import AVFoundation
import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct PlayerQueueTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  private struct ExpectedEngineStartFailure: LocalizedError {
    var errorDescription: String? { "No test audio output is available." }
  }

  @Test
  func testRepeatModeCyclesThroughAllStates() {
    var mode = PlaybackRepeatMode.off
    mode.cycle()
    #expect((mode) == (.all))
    mode.cycle()
    #expect((mode) == (.one))
    mode.cycle()
    #expect((mode) == (.off))
  }

  @Test
  func testUpNextCanBeInsertedMovedRemovedAndCleared() {
    let player = PlayerController()
    let one = track("One")
    let two = track("Two")
    let three = track("Three")

    player.addToUpNext(one)
    player.addToUpNext(three)
    player.playNext(two)
    #expect((player.upNextTracks.map(\.title)) == (["Two", "One", "Three"]))

    player.moveUpNext(from: IndexSet(integer: 2), to: 0)
    #expect((player.upNextTracks.map(\.title)) == (["Three", "Two", "One"]))

    player.removeUpNext(at: IndexSet(integer: 1))
    #expect((player.upNextTracks.map(\.title)) == (["Three", "One"]))

    player.clearUpNext()
    #expect(player.upNextTracks.isEmpty)
  }

  @Test
  func testPlayWithNothingSelectedStartsARandomLibraryTrack() async throws {
    let urls = try makeAudioFiles(named: ["One", "Two", "Three", "Four"])
    let tracks = zip(["One", "Two", "Three", "Four"], urls).map { track($0, url: $1) }
    let player = PlayerController { _ in throw ExpectedEngineStartFailure() }
    player.randomPlaybackSource = { tracks }

    player.togglePlayPause()
    await player.waitForPendingPreparation()

    let started = try #require(player.currentTrack)
    #expect(tracks.contains { $0.url == started.url })
    #expect((Set(player.playbackQueue.map(\.url))) == (Set(tracks.map(\.url))))
    player.stop()
  }

  @Test
  func testPlayWithNothingSelectedAndAnEmptyLibraryDoesNothing() {
    let player = PlayerController { _ in throw ExpectedEngineStartFailure() }
    player.randomPlaybackSource = { [] }

    player.togglePlayPause()

    #expect(player.currentTrack == nil)
    #expect(player.playbackQueue.isEmpty)
    #expect(!(player.isPlaying))
  }

  @Test
  func testSlowInitialOpenDoesNotBlockControlsOrInstallAnObsoleteFile() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [track("First", url: urls[0]), track("Second", url: urls[1])]
    let loader = ControlledAudioFileLoader()
    let player = PlayerController(
      audioFileLoader: { url in try await loader.open(url) },
      engineStarter: { _ in throw ExpectedEngineStartFailure() })

    player.play(tracks[0], in: tracks)
    await waitUntil { await loader.hasStarted(urls[0]) }

    #expect(player.isPlaying)
    player.pause()
    #expect(!player.isPlaying)
    player.resume()
    #expect(player.isPlaying)
    player.toggleMute()
    #expect(player.isMuted)
    #expect(player.currentTrack?.url == urls[0])

    player.play(tracks[1], in: tracks)
    await waitUntil { await loader.hasStarted(urls[1]) }
    await loader.release(urls[1])
    await player.waitForPendingPreparation()
    #expect(player.currentTrack?.url == urls[1])

    await loader.release(urls[0])
    let stayedOnLatestTrack = await holds { player.currentTrack?.url == urls[1] }
    #expect(stayedOnLatestTrack)
    player.stop()
  }

  @Test
  func testSlowGaplessOpenDoesNotBlockPreparedTrackControls() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [track("First", url: urls[0]), track("Second", url: urls[1])]
    let loader = ControlledAudioFileLoader()
    await loader.release(urls[0])
    let player = PlayerController(audioFileLoader: { url in try await loader.open(url) })

    player.restore(
      queue: tracks, currentID: tracks[0].id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await waitUntil { await loader.hasStarted(urls[1]) }

    player.toggleMute()
    #expect(player.isMuted)
    #expect(player.currentTrack?.url == urls[0])
    #expect(player.gaplessSuccessorURL == nil)

    await loader.release(urls[1])
    await player.waitForPendingPreparation()
    #expect(player.gaplessSuccessorURL == urls[1])
    player.stop()
  }

  @Test
  func testRemappingTrackDuringSlowOpenRestartsPreparationAtNewURL() async throws {
    let urls = try makeAudioFiles(named: ["Original", "Moved"])
    let original = track("Original", url: urls[0])
    let moved = track("Moved", url: urls[1])
    let loader = ControlledAudioFileLoader()
    let player = PlayerController(
      audioFileLoader: { url in try await loader.open(url) },
      engineStarter: { _ in throw ExpectedEngineStartFailure() })

    player.play(original, in: [original])
    await waitUntil { await loader.hasStarted(urls[0]) }
    player.remapTracks([original.id: moved.id], catalog: LibraryCatalog([moved]))
    await waitUntil { await loader.hasStarted(urls[1]) }

    await loader.release(urls[1])
    await player.waitForPendingPreparation()
    #expect(player.currentTrack?.url == urls[1])
    #expect(player.playbackIssue?.trackTitle == nil)

    await loader.release(urls[0])
    player.stop()
  }

  @Test
  func testReconcileDuringSlowGaplessOpenPreparesRefreshedSuccessor() async throws {
    let urls = try makeAudioFiles(named: ["First", "Removed", "Replacement"])
    let tracks = [
      track("First", url: urls[0]),
      track("Removed", url: urls[1]),
      track("Replacement", url: urls[2]),
    ]
    let loader = ControlledAudioFileLoader()
    await loader.release(urls[0])
    let player = PlayerController(audioFileLoader: { url in try await loader.open(url) })

    player.restore(
      queue: tracks, currentID: tracks[0].id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await waitUntil { await loader.hasStarted(urls[1]) }

    player.reconcile(with: LibraryCatalog([tracks[0], tracks[2]]))
    await waitUntil { await loader.hasStarted(urls[2]) }
    await loader.release(urls[2])
    await player.waitForPendingPreparation()
    #expect(player.gaplessSuccessorURL == urls[2])

    await loader.release(urls[1])
    player.stop()
  }

  @Test
  func testStalledOpenDoesNotRetainPlayerController() async throws {
    let url = try makeAudioFiles(named: ["Stalled"])[0]
    let stalled = track("Stalled", url: url)
    let loader = ControlledAudioFileLoader()
    var player: PlayerController? = PlayerController(
      audioFileLoader: { url in try await loader.open(url) })
    weak let weakPlayer = player

    player?.play(stalled, in: [stalled])
    await waitUntil { await loader.hasStarted(url) }
    player = nil

    #expect(weakPlayer == nil)
    await loader.release(url)
  }

  @Test
  func testTurningOnShufflePreservesQueuedTrackMembership() {
    let player = PlayerController()
    let tracks = ["One", "Two", "Three", "Four"].map(track)
    tracks.forEach(player.addToUpNext)

    player.toggleShuffle()

    #expect(player.isShuffleEnabled)
    #expect((Set(player.upNextTracks.map(\.url))) == (Set(tracks.map(\.url))))
  }

  @Test
  func testRestorePreparesSavedTrackPausedAtPosition() async throws {
    let fileURL = scratch.appendingPathComponent(
      "NightdrivePlayerQueueTests-\(UUID().uuidString).mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Restored",
        artist: "Artist",
        album: "Album",
        genre: "Genre",
        trackNumber: 1,
        year: 2026),
      seconds: 3
    ).write(to: fileURL)
    var restored = track("Restored")
    restored = LibraryTrack(
      url: fileURL,
      title: restored.title,
      artist: restored.artist,
      album: restored.album,
      genre: restored.genre,
      composer: restored.composer,
      trackNumber: restored.trackNumber,
      trackCount: restored.trackCount,
      discNumber: restored.discNumber,
      year: restored.year,
      durationMS: 3_000,
      sizeBytes: 1,
      bitrate: 128,
      samplerate: 44_100)
    let player = PlayerController()

    player.restore(
      queue: [restored],
      currentID: TrackID(url: fileURL),
      position: 1.25,
      volume: 0.4,
      shuffle: true,
      repeatMode: .one)
    #expect(abs(player.elapsed - 1.25) <= 0.01)
    #expect(player.duration >= 1.25)
    await player.waitForPendingPreparation()

    #expect((player.currentTrack?.url) == (fileURL))
    #expect((player.currentQueueIndex) == (0))
    #expect(!(player.isPlaying))
    #expect(abs((player.elapsed) - (1.25)) <= 0.01)
    #expect(abs((player.volume) - (0.4)) <= 0.001)
    #expect(player.isShuffleEnabled)
    #expect((player.repeatMode) == (.one))
    #expect(!(player.isTickerRunning))
    player.stop()
  }

  @Test
  func testTickerStopsAfterPausedAnalysisDecayAndRestartsWithPlayback() async throws {
    let url = try makeAudioFiles(named: ["Ticker"])[0]
    let player = PlayerController()

    player.play(track("Ticker", url: url), in: [])
    await player.waitForPendingPreparation()
    #expect(player.isTickerRunning)

    player.pause()
    #expect(!(player.isPlaying))
    await waitUntil { !player.isTickerRunning }
    #expect(!(player.isTickerRunning))

    player.resume()
    #expect(player.isPlaying)
    #expect(player.isTickerRunning)
    player.stop()
  }

  @Test
  func testCompatibleSuccessorIsScheduledBeforePlaybackStarts() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [
      track("First", url: urls[0]),
      track("Second", url: urls[1]),
    ]
    let player = PlayerController()

    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()

    #expect((player.gaplessSuccessorURL) == (urls[1]))
    #expect((player.currentTrack?.url) == (urls[0]))
    #expect(!(player.isPlaying))
    player.stop()
  }

  @Test
  func testUnreadableTrackIsReportedAndAutomaticallySkipped() async throws {
    let playableURL = try makeAudioFiles(named: ["Playable"])[0]
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMissing-\(UUID().uuidString).mp3")
    let tracks = [
      track("Missing", url: missingURL),
      track("Playable", url: playableURL),
    ]
    let player = PlayerController()

    player.restore(
      queue: tracks, currentID: TrackID(url: missingURL), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()

    #expect((player.currentTrack?.url) == (playableURL))
    #expect((player.currentQueueIndex) == (1))
    #expect(!(player.isPlaying))
    #expect((player.playbackIssue?.url) == (missingURL))
    #expect(player.playbackIssue?.message.contains("Missing") == true)
    player.stop()
  }

  @Test
  func testSlowRecoveryTrackDoesNotInheritFailedRestorePosition() async throws {
    let playableURL = try makeAudioFiles(named: ["Playable"])[0]
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMissing-\(UUID().uuidString).mp3")
    let tracks = [
      track("Missing", url: missingURL),
      track("Playable", url: playableURL),
    ]
    let loader = ControlledAudioFileLoader()
    await loader.release(missingURL)
    let player = PlayerController(audioFileLoader: { url in try await loader.open(url) })

    player.restore(
      queue: tracks, currentID: tracks[0].id, position: 1.25, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await waitUntil { await loader.hasStarted(playableURL) }

    #expect(player.currentTrack?.url == playableURL)
    #expect(player.elapsed == 0)
    #expect(player.duration == 1)

    await loader.release(playableURL)
    await player.waitForPendingPreparation()
    player.stop()
  }

  @Test
  func testEngineStartFailurePreservesPreparedQueueWithoutBlamingTrack() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [
      track("First", url: urls[0]),
      track("Second", url: urls[1]),
    ]
    var startAttempts = 0
    var qualifiedTracks: [URL] = []
    let player = PlayerController { _ in
      startAttempts += 1
      throw ExpectedEngineStartFailure()
    }
    player.onTrackQualifiedAsPlayed = { qualifiedTracks.append($0.url) }

    player.play(tracks[0], in: tracks)
    await player.waitForPendingPreparation()

    #expect((startAttempts) == (1))
    #expect((player.playbackQueue.map(\.url)) == (urls))
    #expect((player.currentTrack?.url) == (urls[0]))
    #expect((player.currentQueueIndex) == (0))
    #expect((player.gaplessSuccessorURL) == (urls[1]))
    #expect(!(player.isPlaying))
    #expect(player.playbackHistory.isEmpty)
    #expect(player.playbackIssue?.trackTitle == nil)
    #expect(player.playbackIssue?.url == nil)
    #expect((player.playbackIssue?.title) == ("Playback Couldn’t Start"))
    #expect(qualifiedTracks.isEmpty)
    #expect(player.playbackIssue?.message.localizedCaseInsensitiveContains("audio output") == true)

    player.togglePlayPause()
    #expect((startAttempts) == (2))
    #expect((player.playbackQueue.map(\.url)) == (urls))
    #expect((player.currentTrack?.url) == (urls[0]))
    player.stop()
  }

  @Test
  func testEngineConfigurationChangeRebuildsScheduleWithoutLosingState() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [track("First", url: urls[0]), track("Second", url: urls[1])]
    let player = PlayerController { _ in throw ExpectedEngineStartFailure() }

    player.play(tracks[0], in: tracks)
    await player.waitForPendingPreparation()
    #expect(!(player.isPlaying))
    #expect((player.gaplessSuccessorURL) == (urls[1]))

    player.handleEngineConfigurationChange()
    await player.waitForPendingPreparation()

    #expect((player.currentTrack?.url) == (urls[0]))
    #expect((player.currentQueueIndex) == (0))
    #expect((player.playbackQueue.map(\.url)) == (urls))
    #expect(!(player.isPlaying))
    #expect((player.gaplessSuccessorURL) == (urls[1]))
    #expect(abs((player.elapsed) - (0)) <= 0.01)
    player.stop()
  }

  @Test
  func test48KilohertzPlaybackKeepsEqualizerInputAndOutputFormatsMatched() async throws {
    let fileURL = scratch.appendingPathComponent(
      "NightdrivePlayerQueueTests-48k-\(UUID().uuidString).mp3")
    try MP3Builder.build(
      tags: .init(
        title: "48 kHz",
        artist: "Artist",
        album: "Album",
        genre: "Genre",
        trackNumber: 1,
        year: 2026),
      seconds: 2,
      sampleRate: 48_000
    ).write(to: fileURL)
    let player = PlayerController()

    player.play(track("48 kHz", url: fileURL), in: [])
    await player.waitForPendingPreparation()

    #expect(player.isPlaying)
    #expect(player.playbackIssue == nil)
    #expect((player.equalizerInputSampleRate) == (48_000))
    #expect((player.equalizerOutputSampleRate) == (48_000))
    player.stop()
  }

  @Test
  func testGaplessPreparationSkipsUnreadableUpcomingTrack() async throws {
    let urls = try makeAudioFiles(named: ["First", "Third"])
    let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMissing-\(UUID().uuidString).mp3")
    let tracks = [
      track("First", url: urls[0]),
      track("Missing", url: missingURL),
      track("Third", url: urls[1]),
    ]
    let player = PlayerController()

    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()

    #expect((player.gaplessSuccessorURL) == (urls[1]))
    #expect((player.playbackIssue?.url) == (missingURL))
    player.stop()
  }

  @Test
  func testMuteAndEqualizerChangeTheAudioGraph() {
    let player = PlayerController()
    player.volume = 0.6
    #expect(abs((player.effectiveOutputVolume) - (0.6)) <= 0.001)

    player.toggleMute()
    #expect(abs((player.effectiveOutputVolume) - (0)) <= 0.001)
    #expect(abs((player.volume) - (0.6)) <= 0.001)

    player.equalizerPreset = .bassBoost
    #expect((player.equalizerBandGains) == ([6, -1, 0]))
    player.cycleEqualizerPreset()
    #expect((player.equalizerPreset) == (.vocal))
    #expect((player.equalizerBandGains) == ([-2, 4, -1]))
  }

  @Test
  func testForwardAndPreviousUseActualPlaybackHistory() throws {
    let urls = try makeAudioFiles(named: ["First", "Second", "Third"])
    let tracks = zip(["First", "Second", "Third"], urls).map {
      track($0.0, url: $0.1)
    }
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)

    player.next()
    #expect((player.currentTrack?.title) == ("Second"))
    #expect((player.playbackHistory.map(\.title)) == (["First"]))
    player.next()
    #expect((player.currentTrack?.title) == ("Third"))
    #expect((player.playbackHistory.map(\.title)) == (["First", "Second"]))

    player.previous()
    #expect((player.currentTrack?.title) == ("Second"))
    #expect((player.playbackHistory.map(\.title)) == (["First"]))
    player.previous()
    #expect((player.currentTrack?.title) == ("First"))
    #expect(player.playbackHistory.isEmpty)
    player.stop()
  }

  @Test
  func testPlayNowPreservesSkippedUpcomingOrder() throws {
    let names = ["First", "Second", "Third", "Fourth"]
    let urls = try makeAudioFiles(named: names)
    let tracks = zip(names, urls).map { track($0.0, url: $0.1) }
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)

    player.playNow(tracks[2])

    #expect((player.currentTrack?.title) == ("Third"))
    #expect((player.playbackQueue.map(\.title)) == (["First", "Third", "Second", "Fourth"]))
    #expect((player.upNextTracks.map(\.title)) == (["Second", "Fourth"]))
    #expect((player.playbackHistory.map(\.title)) == (["First"]))

    player.previous()
    #expect((player.currentTrack?.title) == ("First"))
    #expect((player.upNextTracks.map(\.title)) == (["Third", "Second", "Fourth"]))
    #expect(player.playbackHistory.isEmpty)
    player.stop()
  }

  @Test
  func testPlayNowStartsSelectedTrackFromColdQueueAndPreservesOrder() throws {
    let names = ["First", "Second", "Third"]
    let urls = try makeAudioFiles(named: names)
    let tracks = zip(names, urls).map { track($0.0, url: $0.1) }
    let player = PlayerController()
    tracks.forEach(player.addToUpNext)
    #expect(player.currentQueueIndex == nil)

    player.playNow(tracks[1])

    #expect((player.playbackQueue.map(\.title)) == (["Second", "First", "Third"]))
    #expect((player.currentTrack?.title) == ("Second"))
    #expect((player.currentQueueIndex) == (0))
    #expect((player.upNextTracks.map(\.title)) == (["First", "Third"]))
    #expect(player.playbackHistory.isEmpty)
    player.stop()
  }

  @Test
  func testPlayUpNextTargetsCorrectInstanceWhenQueueHasDuplicates() throws {
    let names = ["First", "Second", "Third"]
    let urls = try makeAudioFiles(named: names)
    let tracks = zip(names, urls).map { track($0.0, url: $0.1) }
    let player = PlayerController()
    player.restore(
      queue: tracks + [tracks[1]], currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)

    #expect((player.upNextTracks.map(\.title)) == (["Second", "Third", "Second"]))

    player.playUpNext(at: 2)

    #expect((player.currentTrack?.title) == ("Second"))
    #expect((player.playbackQueue.map(\.title)) == (["First", "Second", "Second", "Third"]))
    #expect((player.upNextTracks.map(\.title)) == (["Second", "Third"]))
    #expect((player.playbackHistory.map(\.title)) == (["First"]))
    player.stop()
  }

  @Test
  func testPlaybackHistoryIsCappedButPreviousStillWorks() throws {
    let urls = try makeAudioFiles(named: ["A", "B"], seconds: 0.5)

    let tracks = (0..<260).map { i in
      track("T\(i)", url: urls[i % 2])
    }
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)

    #expect((player.currentTrack?.title) == ("T0"))

    for _ in 0..<259 {
      player.playUpNext(at: 0)
    }

    #expect((player.playbackHistory.count) == (200))
    #expect((player.playbackHistory.first?.title) == ("T59"))
    #expect((player.playbackHistory.last?.title) == ("T258"))

    player.previous()
    #expect((player.currentTrack?.title) == ("T258"))
    player.stop()
  }

  @Test
  func testRestoringNewSessionClearsPlaybackHistory() throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [
      track("First", url: urls[0]),
      track("Second", url: urls[1]),
    ]
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    player.next()
    #expect(!(player.playbackHistory.isEmpty))

    player.restore(
      queue: tracks, currentID: TrackID(url: urls[1]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)

    #expect(player.playbackHistory.isEmpty)
    player.stop()
  }

  @Test
  func testLibraryReconciliationRefreshesQueueCurrentAndHistoryMetadata() throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    let tracks = [track("First", url: urls[0]), track("Second", url: urls[1])]
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    player.next()

    let refreshed = [track("First (Edited)", url: urls[0]), track("Second (Edited)", url: urls[1])]
    player.reconcile(with: LibraryCatalog(refreshed))

    #expect((player.playbackQueue.map(\.title)) == (["First (Edited)", "Second (Edited)"]))
    #expect((player.currentTrack?.title) == ("Second (Edited)"))
    #expect((player.currentQueueIndex) == (1))
    #expect((player.playbackHistory.map(\.title)) == (["First (Edited)"]))
    player.stop()
  }

  @Test
  func testLibraryReconciliationRemovesQueuedTrackAndRefreshesSuccessor() async throws {
    let urls = try makeAudioFiles(named: ["First", "Removed", "Third"])
    let tracks = zip(["First", "Removed", "Third"], urls).map {
      track($0.0, url: $0.1)
    }
    let player = PlayerController()
    player.restore(
      queue: tracks, currentID: TrackID(url: urls[0]), position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()
    #expect((player.gaplessSuccessorURL) == (urls[1]))

    player.reconcile(with: LibraryCatalog([tracks[0], tracks[2]]))
    await player.waitForPendingPreparation()

    #expect((player.playbackQueue.map(\.url)) == ([urls[0], urls[2]]))
    #expect((player.currentQueueIndex) == (0))
    #expect((player.gaplessSuccessorURL) == (urls[2]))
    player.stop()
  }

  @Test
  func testLibraryReconciliationAdvancesPastRemovedCurrentTrack() async throws {
    let urls = try makeAudioFiles(named: ["First", "Removed", "Third"])
    let tracks = zip(["First", "Removed", "Third"], urls).map {
      track($0.0, url: $0.1)
    }
    let player = PlayerController()
    player.play(tracks[1], in: tracks)
    await player.waitForPendingPreparation()
    #expect(player.isPlaying)

    player.reconcile(with: LibraryCatalog([tracks[0], tracks[2]]))
    await player.waitForPendingPreparation()

    #expect((player.playbackQueue.map(\.url)) == ([urls[0], urls[2]]))
    #expect((player.currentTrack?.url) == (urls[2]))
    #expect((player.currentQueueIndex) == (1))
    #expect(player.isPlaying)
    player.stop()
  }

  @Test
  func testLibraryReconciliationReschedulesCallbacksWhenEarlierTrackIsRemoved() async throws {
    let urls = try makeAudioFiles(named: ["Earlier", "Playing", "Next"], seconds: 0.6)
    let tracks = zip(["Earlier", "Playing", "Next"], urls).map {
      track($0.0, url: $0.1)
    }
    let player = PlayerController()
    player.play(tracks[1], in: tracks)
    await player.waitForPendingPreparation()
    #expect((player.currentQueueIndex) == (1))
    #expect((player.gaplessSuccessorURL) == (urls[2]))

    player.reconcile(with: LibraryCatalog([tracks[1], tracks[2]]))
    await player.waitForPendingPreparation()

    #expect((player.currentQueueIndex) == (0))
    #expect((player.gaplessSuccessorURL) == (urls[2]))
    await waitUntil(timeout: .seconds(3), pollInterval: .milliseconds(20)) {
      player.currentTrack?.url == urls[2]
    }
    #expect((player.currentTrack?.url) == (urls[2]))
    #expect((player.currentQueueIndex) == (1))
    #expect(player.isPlaying)
    player.stop()
  }

  @Test
  func testThreeTrackGaplessTransitionHasOrderedCallbacksHistoryAndTimeline() async throws {
    let names = ["First", "Second", "Third"]
    let urls = try makeAudioFiles(named: names, seconds: 0.6)
    let tracks = zip(names, urls).map { track($0.0, url: $0.1) }
    let player = PlayerController()
    var callbacks: [String] = []
    var qualified: [String] = []
    player.onTrackStarted = { callbacks.append($0.title) }
    player.onTrackQualifiedAsPlayed = { qualified.append($0.title) }

    player.play(tracks[0], in: tracks)
    #expect((player.playbackTimelineStartSample) == (0))
    var secondTimelineStart: AVAudioFramePosition?
    await waitUntil(timeout: .seconds(3), pollInterval: .milliseconds(20)) {
      if player.currentTrack?.url == urls[1] {
        secondTimelineStart = player.playbackTimelineStartSample
      }
      return player.currentTrack?.url == urls[2]
    }

    #expect((player.currentTrack?.title) == ("Third"))
    #expect((callbacks) == (names))
    #expect((Array(qualified.prefix(2))) == (["First", "Second"]))
    #expect((player.playbackHistory.map(\.title)) == (["First", "Second"]))
    let secondStart = try #require(secondTimelineStart)
    #expect((secondStart) > (0))
    #expect((player.playbackTimelineStartSample) > (secondStart))
    #expect((player.elapsed) >= (0))
    #expect((player.elapsed) < (player.duration))
    #expect(player.isPlaying)
    player.stop()
  }

  @Test
  func testQualificationDoesNotCountASkipBeforeThreshold() {
    var qualification = PlaybackQualification()
    qualification.start(duration: 100, at: 0)

    #expect(!{ qualification.observe(renderedPosition: 12) }())

    qualification.start(duration: 100, at: 0)
    #expect(!(qualification.isQualified))
    #expect((qualification.renderedDuration) == (0))
  }

  @Test
  func testQualificationFiresOnlyOnceAfterRenderedThreshold() {
    var qualification = PlaybackQualification()
    qualification.start(duration: 100, at: 0)

    #expect(!{ qualification.observe(renderedPosition: 29.9) }())
    #expect({ qualification.observe(renderedPosition: 30) }())
    #expect(!{ qualification.observe(renderedPosition: 60) }())
    #expect(qualification.isQualified)
  }

  @Test
  func testQualificationRestartsForReplayAndRepeat() {
    var qualification = PlaybackQualification()
    for _ in 0..<3 {
      qualification.start(duration: 20, at: 0)
      #expect({ qualification.observe(renderedPosition: 10) }())
      #expect(!{ qualification.observe(renderedPosition: 20) }())
    }
  }

  @Test
  func testPlayerDoesNotQualifyAnImmediateSkip() async throws {
    let urls = try makeAudioFiles(named: ["Skipped", "Next"], seconds: 2)
    let tracks = [
      track("Skipped", url: urls[0]),
      track("Next", url: urls[1]),
    ]
    let player = PlayerController()
    var qualified: [String] = []
    player.onTrackQualifiedAsPlayed = { qualified.append($0.title) }

    player.play(tracks[0], in: tracks)
    player.next()
    let neverQualified = await holds { qualified.isEmpty }

    #expect(neverQualified, Comment(rawValue: "an immediate skip must not qualify: \(qualified)"))
    player.stop()
  }

  @Test
  func testPlayerQualifiesACompletedShortTrackExactlyOnce() async throws {
    let url = try makeAudioFiles(named: ["Short"], seconds: 0.4)[0]
    let short = track("Short", url: url)
    let player = PlayerController()
    var qualified: [String] = []
    player.onTrackQualifiedAsPlayed = { qualified.append($0.title) }

    player.play(short, in: [short])
    await waitUntil(timeout: .seconds(2), pollInterval: .milliseconds(20)) {
      !qualified.isEmpty
    }
    let qualifiedExactlyOnce = await holds { qualified == ["Short"] }

    #expect(qualifiedExactlyOnce, Comment(rawValue: "expected one qualification, got \(qualified)"))
    player.stop()
  }

  @Test
  func testRepeatOneQualifiesEveryCompletedPlayback() async throws {
    let url = try makeAudioFiles(named: ["Loop"], seconds: 0.4)[0]
    let loop = track("Loop", url: url)
    let player = PlayerController()
    player.repeatMode = .one
    var qualified: [String] = []
    player.onTrackQualifiedAsPlayed = { qualified.append($0.title) }

    player.play(loop, in: [loop])
    await waitUntil(timeout: .seconds(3), pollInterval: .milliseconds(20)) {
      qualified.count >= 2
    }

    #expect((qualified.count) >= (2))
    #expect((Array(qualified.prefix(2))) == (["Loop", "Loop"]))
    player.stop()
  }

  @Test
  func testQualificationCountsRenderedTimeButNotSeekDistance() {
    var qualification = PlaybackQualification()
    qualification.start(duration: 100, at: 0)

    #expect(!{ qualification.observe(renderedPosition: 10) }())
    qualification.rebase(at: 80)
    #expect(!{ qualification.observe(renderedPosition: 85) }())
    qualification.rebase(at: 5)
    #expect({ qualification.observe(renderedPosition: 20) }())
    #expect((qualification.renderedDuration) == (30))

    var restored = PlaybackQualification()
    restored.start(duration: 100, at: 80)
    #expect(!{ restored.observe(renderedPosition: 85) }())
    #expect((restored.renderedDuration) == (5))
  }

  @Test
  func testQualificationUsesHalfDurationForShortTracksAndThirtySecondsWhenUnknown() {
    #expect((PlaybackQualification.threshold(for: 4)) == (2))
    #expect((PlaybackQualification.threshold(for: 300)) == (30))
    #expect((PlaybackQualification.threshold(for: 0)) == (30))
    #expect((PlaybackQualification.threshold(for: .nan)) == (30))

    var short = PlaybackQualification()
    short.start(duration: 0.4, at: 0)
    #expect(!{ short.observe(renderedPosition: 0.19) }())
    #expect({ short.observe(renderedPosition: 0.2) }())
  }

  private func makeAudioFiles(named names: [String], seconds: Double = 2) throws -> [URL] {
    try names.map { name in
      let url = scratch.appendingPathComponent(
        "NightdrivePlayerQueueTests-\(name)-\(UUID().uuidString).mp3")
      try MP3Builder.build(
        tags: .init(
          title: name, artist: "Artist", album: "Album", genre: "Genre",
          trackNumber: 1, year: 2026),
        seconds: seconds
      ).write(to: url)
      return url
    }
  }

  private func track(_ title: String) -> LibraryTrack {
    track(title, url: URL(fileURLWithPath: "/tmp/\(title).mp3"))
  }

  private func track(_ title: String, url: URL) -> LibraryTrack {
    LibraryTrack(
      url: url, title: title, artist: "Artist", album: "Album", genre: "Genre", durationMS: 1_000, sizeBytes: 1,
      bitrate: 128, samplerate: 44_100)
  }
}

private actor ControlledAudioFileLoader {
  private var started = Set<URL>()
  private var released = Set<URL>()
  private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

  func open(_ url: URL) async throws -> AVAudioFile {
    started.insert(url)
    if !released.contains(url) {
      await withCheckedContinuation { continuation in
        waiters[url, default: []].append(continuation)
      }
    }
    return try AVAudioFile(forReading: url)
  }

  func hasStarted(_ url: URL) -> Bool {
    started.contains(url)
  }

  func release(_ url: URL) {
    released.insert(url)
    let pending = waiters.removeValue(forKey: url) ?? []
    for continuation in pending { continuation.resume() }
  }
}
