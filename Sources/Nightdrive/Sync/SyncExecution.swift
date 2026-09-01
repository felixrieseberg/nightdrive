import Foundation

struct SyncExecutionRequest: Sendable {
  var librarySnapshot: [LibraryTrack]
  var localPlaylists: [LocalPlaylist]
  var localRatings: [String: Int]
  var scopeInput: SyncScopeInput

  init(
    librarySnapshot: [LibraryTrack],
    localPlaylists: [LocalPlaylist] = [],
    localRatings: [String: Int] = [:],
    scopeInput: SyncScopeInput = SyncScopeInput()
  ) {
    self.librarySnapshot = librarySnapshot
    self.localPlaylists = localPlaylists
    self.localRatings = localRatings
    self.scopeInput = scopeInput
  }

  init(_ preview: SyncPlan) {
    self.init(
      librarySnapshot: preview.librarySnapshot,
      localPlaylists: preview.localPlaylists,
      localRatings: preview.localRatings,
      scopeInput: preview.scopeInput)
  }
}
