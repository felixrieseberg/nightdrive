import AppKit
import Dispatch
import MediaPlayer

struct SystemMediaFeedbackState: Equatable, Sendable {
  var isFavorite: Bool
  var rating: Int
}

struct SystemMediaCapabilities: Equatable, Sendable {
  var canPlay: Bool
  var canPause: Bool
  var canStop: Bool
  var canGoNext: Bool
  var canGoPrevious: Bool
  var canSeek: Bool
  var canSkip: Bool
  var canChangeRate: Bool
  var canChangeShuffle: Bool
  var canChangeRepeat: Bool
  var canGiveFeedback: Bool
}

private struct SystemMediaCommandTarget: @unchecked Sendable {
  let command: MPRemoteCommand
  let token: Any
}

@MainActor
final class SystemMediaController {
  typealias FeedbackProvider = @MainActor (LibraryTrack) -> SystemMediaFeedbackState?
  typealias FavoriteHandler = @MainActor (LibraryTrack, Bool) throws -> Void
  typealias RatingHandler = @MainActor (LibraryTrack, Int) throws -> Void

  private weak var player: PlayerController?
  private let feedbackProvider: FeedbackProvider
  private let setFavorite: FavoriteHandler
  private let setRating: RatingHandler
  private var commandTargets: [SystemMediaCommandTarget] = []

  init(
    player: PlayerController,
    feedbackProvider: @escaping FeedbackProvider = { _ in nil },
    setFavorite: @escaping FavoriteHandler = { _, _ in },
    setRating: @escaping RatingHandler = { _, _ in }
  ) {
    self.player = player
    self.feedbackProvider = feedbackProvider
    self.setFavorite = setFavorite
    self.setRating = setRating
    registerRemoteCommands()
    synchronizeRemoteCommands()
  }

  deinit {
    for target in commandTargets {
      target.command.removeTarget(target.token)
    }
  }

  func updateNowPlaying(
    track: LibraryTrack,
    isPlaying: Bool,
    elapsed: TimeInterval,
    duration: TimeInterval,
    artwork: NSImage?
  ) {
    guard let player else { return }
    let feedback = feedbackProvider(track)
    var info = Self.nowPlayingInfo(
      track: track,
      isPlaying: isPlaying,
      elapsed: elapsed,
      duration: duration,
      playbackRate: player.playbackRate,
      queueIndex: player.currentQueueIndex,
      queueCount: player.playbackQueue.count,
      feedback: feedback)
    if let artwork {
      info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) {
        @Sendable _ in artwork
      }
    }

    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = isPlaying ? .playing : .paused
    synchronizeRemoteCommands(feedback: feedback)
  }

  func clearNowPlaying() {
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    synchronizeRemoteCommands()
  }

  static func nowPlayingInfo(
    track: LibraryTrack,
    isPlaying: Bool,
    elapsed: TimeInterval,
    duration: TimeInterval,
    playbackRate: Float,
    queueIndex: Int?,
    queueCount: Int,
    feedback: SystemMediaFeedbackState?
  ) -> [String: Any] {
    let elapsed = elapsed.isFinite ? max(0, elapsed) : 0
    let duration = duration.isFinite ? max(0, duration) : 0
    let playbackRate = Double(playbackRate)
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: track.displayTitle,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: min(elapsed, duration),
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackRate : 0.0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: playbackRate,
      MPNowPlayingInfoPropertyAssetURL: track.url,
      MPNowPlayingInfoPropertyExternalContentIdentifier: track.id.rawValue,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
      MPNowPlayingInfoPropertyIsLiveStream: false,
      MPMediaItemPropertyMediaType: mediaType(for: track.mediaKind).rawValue,
    ]
    add(track.artist, as: MPMediaItemPropertyArtist, to: &info)
    add(track.album, as: MPMediaItemPropertyAlbumTitle, to: &info)
    add(track.albumArtist, as: MPMediaItemPropertyAlbumArtist, to: &info)
    add(track.genre, as: MPMediaItemPropertyGenre, to: &info)
    add(track.composer, as: MPMediaItemPropertyComposer, to: &info)
    if track.mediaKind == .podcast {
      add(track.album, as: MPMediaItemPropertyPodcastTitle, to: &info)
    }
    addPositive(track.trackNumber, as: MPMediaItemPropertyAlbumTrackNumber, to: &info)
    addPositive(track.trackCount, as: MPMediaItemPropertyAlbumTrackCount, to: &info)
    addPositive(track.discNumber, as: MPMediaItemPropertyDiscNumber, to: &info)
    addPositive(track.discCount, as: MPMediaItemPropertyDiscCount, to: &info)
    if let queueIndex, queueCount > 0, (0..<queueCount).contains(queueIndex) {
      info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
      info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueCount
    }
    if let feedback {
      info[MPMediaItemPropertyRating] = min(max(feedback.rating, 0), 5)
    }
    return info
  }

  static func capabilities(
    player: PlayerController,
    feedback: SystemMediaFeedbackState?
  ) -> SystemMediaCapabilities {
    let hasItem = player.currentTrack != nil
    let index = player.currentQueueIndex
    let queueCount = player.playbackQueue.count
    let wraps = player.repeatMode == .all && queueCount > 0
    let isLongForm =
      player.currentTrack.map {
        $0.mediaKind == .podcast || $0.mediaKind == .audiobook
      } ?? false
    return SystemMediaCapabilities(
      canPlay: hasItem && !player.isPlaying,
      canPause: hasItem && player.isPlaying,
      canStop: hasItem,
      canGoNext: index.map { $0 + 1 < queueCount || wraps } ?? false,
      canGoPrevious: hasItem
        && (player.elapsed > 3 || !player.playbackHistory.isEmpty
          || index.map { $0 > 0 || wraps } == true),
      canSeek: player.canSeek,
      canSkip: isLongForm && player.canSeek,
      canChangeRate: hasItem,
      canChangeShuffle: hasItem,
      canChangeRepeat: hasItem,
      canGiveFeedback: feedback != nil)
  }

  private func registerRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    register(center.playCommand) { controller, _ in controller.perform { $0.resume() } }
    register(center.pauseCommand) { controller, _ in controller.perform { $0.pause() } }
    register(center.stopCommand) { controller, _ in controller.perform { $0.stop() } }
    register(center.togglePlayPauseCommand) { controller, _ in
      controller.perform { $0.togglePlayPause() }
    }
    register(center.nextTrackCommand) { controller, _ in controller.perform { $0.next() } }
    register(center.previousTrackCommand) { controller, _ in
      controller.perform { $0.previous() }
    }
    register(center.changePlaybackPositionCommand) { controller, event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      guard event.positionTime.isFinite else { return .commandFailed }
      return controller.performIfPossible { $0.seek(toTime: event.positionTime) }
    }

    center.skipForwardCommand.preferredIntervals = [30]
    register(center.skipForwardCommand) { controller, event in
      controller.performSkip(event, direction: 1)
    }
    center.skipBackwardCommand.preferredIntervals = [15]
    register(center.skipBackwardCommand) { controller, event in
      controller.performSkip(event, direction: -1)
    }

    center.changePlaybackRateCommand.supportedPlaybackRates =
      PlayerController.supportedPlaybackRates.map(NSNumber.init(value:))
    register(center.changePlaybackRateCommand) { controller, event in
      guard let event = event as? MPChangePlaybackRateCommandEvent else {
        return .commandFailed
      }
      return controller.performIfPossible { $0.setPlaybackRate(event.playbackRate) }
    }
    register(center.changeShuffleModeCommand) { controller, event in
      guard let event = event as? MPChangeShuffleModeCommandEvent else {
        return .commandFailed
      }
      switch event.shuffleType {
      case .off: return controller.perform { $0.setShuffleEnabled(false) }
      case .items: return controller.perform { $0.setShuffleEnabled(true) }
      default: return .commandFailed
      }
    }
    register(center.changeRepeatModeCommand) { controller, event in
      guard let event = event as? MPChangeRepeatModeCommandEvent,
        let mode = PlaybackRepeatMode(event.repeatType)
      else { return .commandFailed }
      return controller.perform { $0.setRepeatMode(mode) }
    }

    center.likeCommand.localizedTitle = String(localized: "Favorite")
    center.likeCommand.localizedShortTitle = String(localized: "Favorite")
    register(center.likeCommand) { controller, event in
      guard let event = event as? MPFeedbackCommandEvent else { return .commandFailed }
      return controller.handleFavorite(!event.isNegative)
    }
    center.ratingCommand.minimumRating = 0
    center.ratingCommand.maximumRating = 5
    register(center.ratingCommand) { controller, event in
      guard let event = event as? MPRatingCommandEvent else { return .commandFailed }
      return controller.handleRating(Int(event.rating.rounded()))
    }
  }

  func handleFavorite(_ isFavorite: Bool) -> MPRemoteCommandHandlerStatus {
    performFeedback { try setFavorite($0, isFavorite) }
  }

  func handleRating(_ rating: Int) -> MPRemoteCommandHandlerStatus {
    guard (0...5).contains(rating) else { return .commandFailed }
    return performFeedback { try setRating($0, rating) }
  }

  private func register(
    _ command: MPRemoteCommand,
    handler:
      @escaping @MainActor (SystemMediaController, MPRemoteCommandEvent)
      -> MPRemoteCommandHandlerStatus
  ) {
    let token = command.addTarget { [weak self] event in
      if Thread.isMainThread {
        return MainActor.assumeIsolated {
          guard let self else { return .noActionableNowPlayingItem }
          return handler(self, event)
        }
      }
      return DispatchQueue.main.sync {
        guard let self else { return .noActionableNowPlayingItem }
        return handler(self, event)
      }
    }
    commandTargets.append(SystemMediaCommandTarget(command: command, token: token))
  }

  private func perform(
    _ action: (PlayerController) -> Void
  ) -> MPRemoteCommandHandlerStatus {
    guard let player, player.currentTrack != nil else { return .noActionableNowPlayingItem }
    action(player)
    publishPlayerState()
    return .success
  }

  private func performIfPossible(
    _ action: (PlayerController) -> Bool
  ) -> MPRemoteCommandHandlerStatus {
    guard let player, player.currentTrack != nil else { return .noActionableNowPlayingItem }
    guard action(player) else { return .commandFailed }
    publishPlayerState()
    return .success
  }

  private func performSkip(
    _ event: MPRemoteCommandEvent, direction: Double
  ) -> MPRemoteCommandHandlerStatus {
    guard let event = event as? MPSkipIntervalCommandEvent,
      event.interval.isFinite, event.interval > 0
    else { return .commandFailed }
    guard let track = player?.currentTrack,
      track.mediaKind == .podcast || track.mediaKind == .audiobook
    else { return .noActionableNowPlayingItem }
    return performIfPossible { $0.skip(by: event.interval * direction) }
  }

  private func performFeedback(
    _ action: (LibraryTrack) throws -> Void
  ) -> MPRemoteCommandHandlerStatus {
    guard let track = player?.currentTrack, feedbackProvider(track) != nil else {
      return .noActionableNowPlayingItem
    }
    do {
      try action(track)
      publishPlayerState()
      return .success
    } catch {
      NightdriveLog.app.error(
        "Updating Now Playing feedback failed: \(error.localizedDescription, privacy: .public)")
      return .commandFailed
    }
  }

  private func publishPlayerState() {
    guard let player, let track = player.currentTrack else {
      clearNowPlaying()
      return
    }
    updateNowPlaying(
      track: track, isPlaying: player.isPlaying, elapsed: player.elapsed,
      duration: player.duration, artwork: player.artwork)
  }

  private func synchronizeRemoteCommands(feedback: SystemMediaFeedbackState? = nil) {
    guard let player else { return }
    let feedback = feedback ?? player.currentTrack.flatMap(feedbackProvider)
    let state = Self.capabilities(player: player, feedback: feedback)
    let center = MPRemoteCommandCenter.shared()
    center.playCommand.isEnabled = state.canPlay
    center.pauseCommand.isEnabled = state.canPause
    center.stopCommand.isEnabled = state.canStop
    center.togglePlayPauseCommand.isEnabled = state.canPlay || state.canPause
    center.nextTrackCommand.isEnabled = state.canGoNext
    center.previousTrackCommand.isEnabled = state.canGoPrevious
    center.changePlaybackPositionCommand.isEnabled = state.canSeek
    center.skipForwardCommand.isEnabled = state.canSkip
    center.skipBackwardCommand.isEnabled = state.canSkip
    center.changePlaybackRateCommand.isEnabled = state.canChangeRate
    center.changeShuffleModeCommand.isEnabled = state.canChangeShuffle
    center.changeShuffleModeCommand.currentShuffleType =
      player.isShuffleEnabled ? .items : .off
    center.changeRepeatModeCommand.isEnabled = state.canChangeRepeat
    center.changeRepeatModeCommand.currentRepeatType = player.repeatMode.mediaPlayerValue
    center.likeCommand.isEnabled = state.canGiveFeedback
    center.likeCommand.isActive = feedback?.isFavorite == true
    center.ratingCommand.isEnabled = state.canGiveFeedback
  }

  private static func add(_ value: String, as key: String, to info: inout [String: Any]) {
    if !value.isEmpty { info[key] = value }
  }

  private static func addPositive(_ value: Int, as key: String, to info: inout [String: Any]) {
    if value > 0 { info[key] = value }
  }

  private static func mediaType(for kind: LibraryMediaKind) -> MPMediaType {
    switch kind {
    case .song: .music
    case .audiobook: .audioBook
    case .podcast: .podcast
    }
  }
}

extension PlaybackRepeatMode {
  fileprivate init?(_ value: MPRepeatType) {
    switch value {
    case .off: self = .off
    case .one: self = .one
    case .all: self = .all
    default: return nil
    }
  }

  fileprivate var mediaPlayerValue: MPRepeatType {
    switch self {
    case .off: .off
    case .one: .one
    case .all: .all
    }
  }
}
