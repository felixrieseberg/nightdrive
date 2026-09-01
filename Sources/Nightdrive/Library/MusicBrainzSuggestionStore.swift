import Foundation
import Observation

struct MusicBrainzTrackSuggestion: Codable, Equatable, Identifiable, Sendable {
  var trackKey: String
  var displayTitle: String
  var current: TrackMetadata
  var proposed: TrackMetadata

  var id: String { trackKey }
}

struct MusicBrainzAlbumSuggestion: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var albumTitle: String
  var artistName: String
  var releaseID: String
  var releaseTitle: String
  var releaseYear: Int
  var tracks: [MusicBrainzTrackSuggestion]
}

@Observable
@MainActor
final class MusicBrainzSuggestionStore {
  private(set) var suggestions: [MusicBrainzAlbumSuggestion] = []
  private(set) var dismissedAlbumKeys: Set<String> = []
  private(set) var persistenceError: String?

  @ObservationIgnored private let persistence: any AppDataPersistence
  nonisolated static let defaultsKey = "musicBrainzSuggestions"

  private struct PersistedState: Codable {
    var suggestions: [MusicBrainzAlbumSuggestion]
    var dismissedAlbumKeys: Set<String>
  }

  init(
    persistence: any AppDataPersistence = UserDefaultsDataPersistence(
      key: MusicBrainzSuggestionStore.defaultsKey)
  ) {
    self.persistence = persistence
    load()
  }

  nonisolated static func albumKey(album: String, artist: String) -> String {
    let fold = { (value: String) in
      value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    return "\(fold(artist))\n\(fold(album))"
  }

  func suggestion(withID id: String) -> MusicBrainzAlbumSuggestion? {
    suggestions.first { $0.id == id }
  }

  func hasSuggestion(forAlbumKey key: String) -> Bool {
    suggestions.contains { $0.id == key }
  }

  func isDismissed(albumKey key: String) -> Bool {
    dismissedAlbumKeys.contains(key)
  }

  func add(_ suggestion: MusicBrainzAlbumSuggestion) {
    guard !suggestion.tracks.isEmpty, !isDismissed(albumKey: suggestion.id) else { return }
    if let index = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
      suggestions[index] = suggestion
    } else {
      suggestions.append(suggestion)
    }
    save()
  }

  func remove(albumID: String) {
    guard suggestions.contains(where: { $0.id == albumID }) else { return }
    suggestions.removeAll { $0.id == albumID }
    save()
  }

  func dismiss(albumID: String) {
    guard !dismissedAlbumKeys.contains(albumID) || suggestions.contains(where: { $0.id == albumID })
    else { return }
    dismissedAlbumKeys.insert(albumID)
    suggestions.removeAll { $0.id == albumID }
    save()
  }

  func prune(against currentMetadata: (String) -> TrackMetadata?) {
    let kept = suggestions.filter { suggestion in
      suggestion.tracks.allSatisfy { track in
        currentMetadata(track.trackKey) == track.current
      }
    }
    guard kept.count != suggestions.count else { return }
    suggestions = kept
    save()
  }

  private func load() {
    do {
      guard let data = try persistence.load() else { return }
      let state = try JSONDecoder().decode(PersistedState.self, from: data)
      suggestions = state.suggestions
      dismissedAlbumKeys = state.dismissedAlbumKeys
    } catch {
      persistenceError = error.localizedDescription
    }
  }

  private func save() {
    do {
      try persistence.save(
        PersistedState(suggestions: suggestions, dismissedAlbumKeys: dismissedAlbumKeys))
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
    }
  }
}
