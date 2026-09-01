import Foundation
import Observation

/// Memoizes the sync-ledger data that playlist rows display so SwiftUI body
/// evaluation never performs synchronous ledger disk IO. Snapshots are keyed
/// by library folder and device database ID; AppState invalidates the cache
/// on the events that can change the ledger — sync completion, sync-ledger
/// recovery, library relocation remaps, sidecar reinstalls, and library
/// folder changes. Reads observe `revision` so invalidation refreshes any
/// row that displayed a cached snapshot.
@Observable
@MainActor
final class PlaylistSyncLedgerCache {
  struct Snapshot {
    var playlistLinks: [SyncPlaylistLink] = []
    var trackLinks = PlaylistTrackLinks()
  }

  private(set) var revision: UInt64 = 0
  @ObservationIgnored private var cache: [String: Snapshot] = [:]
  @ObservationIgnored private let loadLedger: (URL) -> SyncLedger

  init(
    loadLedger: @escaping (URL) -> SyncLedger = { folder in
      (try? SyncLedgerStore.load(libraryFolder: folder)) ?? SyncLedger()
    }
  ) {
    self.loadLedger = loadLedger
  }

  func snapshot(for databaseID: UInt64, libraryFolder: URL) -> Snapshot {
    _ = revision
    let key = libraryFolder.standardizedFileURL.path + "|" + String(databaseID)
    if let cached = cache[key] { return cached }
    let ledger = loadLedger(libraryFolder)
    let deviceKey = SyncLedger.deviceKey(databaseID)
    let snapshot = Snapshot(
      playlistLinks: ledger.playlists[deviceKey] ?? [],
      trackLinks: PlaylistTrackLinks(
        entries: ledger.devices[deviceKey] ?? [], libraryFolder: libraryFolder))
    cache[key] = snapshot
    return snapshot
  }

  func invalidate() {
    cache.removeAll()
    revision &+= 1
  }
}
