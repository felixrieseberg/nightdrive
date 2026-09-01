import Foundation

enum DockMenuAction: String, Sendable {
  case togglePlayback
  case previous
  case next
  case showNightdrive
  case showUpNext
}

struct DockPlaybackMenuModel: Equatable, Sendable {
  let nowPlaying: String?
  let isPlaying: Bool
  let capabilities: SystemMediaCapabilities
  let isRouteAvailable: Bool

  init(
    nowPlaying: String?, isPlaying: Bool, capabilities: SystemMediaCapabilities,
    isRouteAvailable: Bool
  ) {
    self.nowPlaying = nowPlaying
    self.isPlaying = isPlaying
    self.capabilities = capabilities
    self.isRouteAvailable = isRouteAvailable
  }

  @MainActor
  init(player: PlayerController) {
    let track = player.currentTrack
    let nowPlaying = track.map {
      $0.artist.isEmpty ? $0.displayTitle : "\($0.displayTitle) — \($0.artist)"
    }
    self.init(
      nowPlaying: nowPlaying, isPlaying: player.isPlaying,
      capabilities: SystemMediaController.capabilities(player: player, feedback: nil),
      isRouteAvailable: player.audioOutput.isRouteAvailable)
  }

  var contextTitle: String {
    nowPlaying.map { String(localized: "Now Playing: \($0)") }
      ?? String(localized: "Nothing Playing")
  }

  func title(for action: DockMenuAction) -> String {
    switch action {
    case .togglePlayback: isPlaying ? String(localized: "Pause") : String(localized: "Play")
    case .previous: String(localized: "Previous")
    case .next: String(localized: "Next")
    case .showNightdrive: String(localized: "Show Nightdrive")
    case .showUpNext: String(localized: "Show Up Next")
    }
  }

  func isEnabled(_ action: DockMenuAction) -> Bool {
    switch action {
    case .togglePlayback:
      return isPlaying ? capabilities.canPause : capabilities.canPlay && isRouteAvailable
    case .previous: return capabilities.canGoPrevious && isRouteAvailable
    case .next: return capabilities.canGoNext && isRouteAvailable
    case .showNightdrive, .showUpNext: return true
    }
  }
}
