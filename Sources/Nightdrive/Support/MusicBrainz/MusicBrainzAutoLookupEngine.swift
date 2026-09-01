import Foundation
import Observation

@Observable
@MainActor
final class MusicBrainzAutoLookupEngine {
  static let minimumSearchScore = 85

  private(set) var isRunning = false
  private(set) var lastError: String?

  @ObservationIgnored private let policy: OnlineServicesPolicy
  @ObservationIgnored private let store: MusicBrainzSuggestionStore
  @ObservationIgnored private let service: any MusicBrainzService
  @ObservationIgnored private let tracksProvider: @MainActor () -> [LibraryTrack]
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt64 = 0

  init(
    policy: OnlineServicesPolicy,
    store: MusicBrainzSuggestionStore,
    service: any MusicBrainzService,
    tracks: @escaping @MainActor () -> [LibraryTrack]
  ) {
    self.policy = policy
    self.store = store
    self.service = service
    self.tracksProvider = tracks
    observePolicy()
  }

  func refresh() {
    generation &+= 1
    let runGeneration = generation
    task?.cancel()
    guard policy.isAutoLookupActive else {
      isRunning = false
      return
    }
    let previous = task
    task = Task { [weak self] in
      await previous?.value
      await self?.run(generation: runGeneration)
    }
  }

  func stop() {
    generation &+= 1
    task?.cancel()
    isRunning = false
    lastError = nil
  }

  func waitUntilIdle() async {
    await task?.value
  }

  private func run(generation runGeneration: UInt64) async {
    guard isCurrent(runGeneration) else { return }
    isRunning = true
    lastError = nil
    defer {
      if generation == runGeneration { isRunning = false }
    }

    let tracks = tracksProvider()
    guard isCurrent(runGeneration) else { return }
    let index = Dictionary(
      tracks.map { ($0.id.rawValue, TrackMetadata($0)) },
      uniquingKeysWith: { first, _ in first })
    store.prune(against: { index[$0] })

    for album in Self.candidateAlbums(in: tracks, store: store) {
      guard isCurrent(runGeneration) else { return }
      do {
        if let suggestion = try await lookUp(album, generation: runGeneration) {
          guard isCurrent(runGeneration) else { return }
          store.add(suggestion)
        }
      } catch is CancellationError {
        return
      } catch {
        guard isCurrent(runGeneration) else { return }
        lastError = error.localizedDescription
        return
      }
    }
  }

  private func lookUp(
    _ album: CandidateAlbum, generation runGeneration: UInt64
  ) async throws -> MusicBrainzAlbumSuggestion? {
    let candidates = try await service.searchReleases(
      artist: album.artist, releaseTitle: album.title)
    guard isCurrent(runGeneration) else { throw CancellationError() }
    let best = candidates.sortedForLocalTrackCount(album.tracks.count).first
    guard let best, best.score >= Self.minimumSearchScore else { return nil }

    let release = try await service.release(withID: best.id)
    guard isCurrent(runGeneration) else { throw CancellationError() }

    let proposals = MusicBrainzReleaseMatcher.proposals(for: album.tracks, release: release)
      .filter(\.hasChanges)
    guard !proposals.isEmpty else { return nil }
    return MusicBrainzAlbumSuggestion(
      id: album.key,
      albumTitle: album.title,
      artistName: album.artist,
      releaseID: release.id,
      releaseTitle: release.title,
      releaseYear: release.year,
      tracks: proposals.map {
        MusicBrainzTrackSuggestion(
          trackKey: $0.track.id.rawValue,
          displayTitle: $0.track.displayTitle,
          current: $0.current,
          proposed: $0.proposed)
      })
  }

  private func isCurrent(_ runGeneration: UInt64) -> Bool {
    generation == runGeneration && policy.isAutoLookupActive && !Task.isCancelled
  }

  struct CandidateAlbum: Equatable {
    var key: String
    var title: String
    var artist: String
    var tracks: [LibraryTrack]
  }

  static func candidateAlbums(
    in tracks: [LibraryTrack], store: MusicBrainzSuggestionStore
  ) -> [CandidateAlbum] {
    let eligible = tracks.filter {
      $0.audioFormat == .mp3
        && !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return LibraryStore.resolveAlbums(in: eligible).compactMap { album in
      guard !album.title.isEmpty, !album.albumArtist.isEmpty else { return nil }
      let key = MusicBrainzSuggestionStore.albumKey(album: album.title, artist: album.albumArtist)
      guard !store.isDismissed(albumKey: key),
        !store.hasSuggestion(forAlbumKey: key),
        album.tracks.contains(where: { $0.musicBrainzReleaseID.isEmpty })
      else { return nil }
      return CandidateAlbum(
        key: key, title: album.title, artist: album.albumArtist, tracks: album.tracks)
    }
  }

  private func observePolicy() {
    withObservationTracking {
      _ = policy.consent
      _ = policy.autoLookup
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self else { return }
        if self.policy.isAutoLookupActive {
          self.refresh()
        } else {
          self.stop()
        }
        self.observePolicy()
      }
    }
  }
}
