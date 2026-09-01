import Foundation

enum AppSyncCommitError: LocalizedError, Equatable {
  case libraryChanged

  var errorDescription: String? {
    String(
      localized: "The library folder changed during sync. Local changes were left for the next sync.")
  }
}

@MainActor
enum AppSyncLocalEffects {
  static func make(
    library: LibraryStore,
    playlists: PlaylistStore,
    listeningHistory: ListeningHistoryStore,
    expectedLibraryFolder: URL,
    expectedLibraryIdentity: UInt64
  ) -> SyncWorkflow.LocalEffects {
    let expectedFolder = expectedLibraryFolder.standardizedFileURL
    return SyncWorkflow.LocalEffects(
      applyPlaylists: { result, _ in
        let outcome = try await MainActor.run {
          try ensureCurrentLibrary(
            library, expectedFolder: expectedFolder, expectedIdentity: expectedLibraryIdentity)
          let outcome = PlaylistSyncApplier.apply(result: result, to: playlists.playlists)
          if outcome.changedLibrary {
            try playlists.replaceAll(outcome.playlists)
          }
          return outcome
        }
        if outcome.changedLibrary {
          try await playlists.flushPersistence()
        }
        return outcome
      },
      mergePlayback: { report in
        let merged = try await MainActor.run {
          try ensureCurrentLibrary(
            library, expectedFolder: expectedFolder, expectedIdentity: expectedLibraryIdentity)
          return try listeningHistory.merge(report)
        }
        try await listeningHistory.flushPersistence()
        return merged
      })
  }

  private static func ensureCurrentLibrary(
    _ library: LibraryStore, expectedFolder: URL, expectedIdentity: UInt64
  ) throws {
    guard library.folderURL?.standardizedFileURL == expectedFolder else {
      throw AppSyncCommitError.libraryChanged
    }
    do {
      try library.validateCurrentIdentity(expectedIdentity)
    } catch {
      throw AppSyncCommitError.libraryChanged
    }
  }
}
