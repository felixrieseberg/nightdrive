import MediaPlayer
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct SystemMediaControllerTests {
  @Test
  func nowPlayingInfoIncludesQueueContentAndListeningMetadata() {
    let track = podcast("Episode")
    let info = SystemMediaController.nowPlayingInfo(
      track: track,
      isPlaying: false,
      elapsed: 90,
      duration: 60,
      playbackRate: 1.5,
      queueIndex: 1,
      queueCount: 3,
      feedback: SystemMediaFeedbackState(isFavorite: true, rating: 4))

    #expect(info[MPMediaItemPropertyTitle] as? String == "Episode")
    #expect(info[MPMediaItemPropertyArtist] as? String == "Host")
    #expect(info[MPMediaItemPropertyAlbumTitle] as? String == "Night Radio")
    #expect(info[MPMediaItemPropertyAlbumArtist] as? String == "Station")
    #expect(info[MPMediaItemPropertyPodcastTitle] as? String == "Night Radio")
    #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 60)
    #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    #expect(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double == 1.5)
    #expect(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int == 1)
    #expect(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int == 3)
    #expect(info[MPMediaItemPropertyRating] as? Int == 4)
    #expect(info[MPMediaItemPropertyMediaType] as? UInt == MPMediaType.podcast.rawValue)
  }

  @Test
  func capabilitiesReflectTheCurrentItemAndQueue() {
    let first = podcast("First")
    let second = podcast("Second")
    let player = PlayerController()
    player.restore(
      queue: [first, second], currentID: first.id, position: 0, volume: 1,
      shuffle: false, repeatMode: .off)

    var capabilities = SystemMediaController.capabilities(
      player: player, feedback: SystemMediaFeedbackState(isFavorite: false, rating: 0))
    #expect(capabilities.canPlay)
    #expect(!capabilities.canPause)
    #expect(capabilities.canStop)
    #expect(capabilities.canGoNext)
    #expect(!capabilities.canGoPrevious)
    #expect(!capabilities.canSeek)
    #expect(!capabilities.canSkip)
    #expect(capabilities.canChangeRate)
    #expect(capabilities.canChangeShuffle)
    #expect(capabilities.canChangeRepeat)
    #expect(capabilities.canGiveFeedback)

    player.setRepeatMode(.all)
    capabilities = SystemMediaController.capabilities(player: player, feedback: nil)
    #expect(capabilities.canGoPrevious)
    #expect(!capabilities.canGiveFeedback)

    player.restore(
      queue: [first], currentID: first.id, position: 0, volume: 1,
      shuffle: true, repeatMode: .off)
    capabilities = SystemMediaController.capabilities(player: player, feedback: nil)
    #expect(capabilities.canChangeShuffle)
    player.stop()
  }

  @Test
  func playbackRateAndSkipTargetsRejectUnsupportedValuesAndClampToTheItem() {
    let player = PlayerController()
    #expect(player.setPlaybackRate(1.5))
    #expect(player.playbackRate == 1.5)
    #expect(!player.setPlaybackRate(1.1))
    #expect(player.playbackRate == 1.5)

    #expect(PlayerController.skipTarget(elapsed: 20, duration: 60, interval: 30) == 50)
    #expect(PlayerController.skipTarget(elapsed: 5, duration: 60, interval: -15) == 0)
    #expect(PlayerController.skipTarget(elapsed: 50, duration: 60, interval: 30) == 60)
    #expect(PlayerController.skipTarget(elapsed: 1, duration: 0, interval: 15) == nil)
    #expect(!player.skip(by: 15))
  }

  @Test
  func favoriteAndRatingCommandsPersistThroughAppStateWiring() async throws {
    let root = TestScratch.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeTestSong(
      title: "Favorite", to: root.appendingPathComponent("favorite.mp3"), genre: "Podcast")
    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let track = try #require(library.tracks.first)
    let history = ListeningHistoryStore(libraryFolder: root)
    let app = AppState(
      library: library,
      listeningHistory: history,
      playbackPersistence: PlaybackPersistenceStore(
        fileURL: root.appendingPathComponent("playback.json")))
    app.player.restore(
      queue: [track], currentID: track.id, position: 0, volume: 1,
      shuffle: false, repeatMode: .off)
    let didPrepare = await waitUntil {
      SystemMediaController.capabilities(player: app.player, feedback: nil).canSeek
    }
    #expect(didPrepare)
    #expect(SystemMediaController.capabilities(player: app.player, feedback: nil).canSkip)

    #expect(app.mediaController.handleFavorite(true) == .success)
    #expect(app.mediaController.handleRating(4) == .success)
    #expect(app.mediaController.handleRating(6) == .commandFailed)
    try await history.flushPersistence()

    let restored = ListeningHistoryStore(libraryFolder: root)
    #expect(restored.isFavorite(track.id))
    #expect(restored.rating(for: track.id) == 4)
    app.player.stop()
    app.mediaController.clearNowPlaying()
  }

  private func podcast(_ title: String) -> LibraryTrack {
    var track = LibraryTrack(
      url: URL(fileURLWithPath: "/tmp/\(title).mp3"), title: title,
      artist: "Host", album: "Night Radio", albumArtist: "Station",
      genre: "Podcast", composer: "Producer", trackNumber: 2, trackCount: 10,
      discNumber: 1, discCount: 1, durationMS: 60_000, sizeBytes: 1,
      bitrate: 128, samplerate: 44_100)
    track.mediaKind = .podcast
    return track
  }
}
