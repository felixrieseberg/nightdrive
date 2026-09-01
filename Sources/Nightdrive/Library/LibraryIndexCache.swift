import CryptoKit
import Foundation

struct LibraryIndexCacheEntry: Codable, Sendable {
  let stamp: FileGenerationStamp
  let track: LibraryTrack
}

private struct LibraryIndexCachePayload: Codable, Sendable {
  let metadataDerivationVersion: Int
  let entries: [String: LibraryIndexCacheEntry]
}

struct LibraryIndexCache: Sendable {
  /// Version 4: full release-date extraction changed track derivation.
  private static let metadataDerivationVersion = 4
  /// Entries spread across a fixed set of shard files by a stable hash of
  /// their path, so incremental deltas rewrite one small shard instead of
  /// re-encoding the whole library index.
  private static let shardCount = 64

  private let persistenceForKey: @Sendable (String) -> any AppDataPersistence

  init(persistenceForKey: @escaping @Sendable (String) -> any AppDataPersistence) {
    self.persistenceForKey = persistenceForKey
  }

  init(directoryURL: URL = NightdriveAppData.defaultDirectoryURL) {
    self.init { key in
      let filename = SHA256.hash(data: Data(key.utf8)).hexString + ".json"
      return FileDataPersistence(
        fileURL:
          Self.cacheDirectory(in: directoryURL)
          .appendingPathComponent(filename))
    }
  }

  private static func cacheDirectory(in directoryURL: URL) -> URL {
    directoryURL.appendingPathComponent("LibraryIndex", isDirectory: true)
  }

  static func persistenceKey(for root: LibraryFolderIdentity) -> String {
    "libraryIndex:v\(metadataDerivationVersion):\(root.url.path):\(root.volumeID):\(root.resourceID)"
  }

  private static func shardKey(for root: LibraryFolderIdentity, shard: Int) -> String {
    "\(persistenceKey(for: root))#shard-\(shard)"
  }

  /// Stable across launches, unlike `Hasher`, so entries stay in the shard
  /// they were written to.
  private static func shardIndex(forPath path: String) -> Int {
    var digestBytes = SHA256.hash(data: Data(path.utf8)).makeIterator()
    return Int(digestBytes.next() ?? 0) % shardCount
  }

  func loadEntries(for root: LibraryFolderIdentity) -> [String: LibraryIndexCacheEntry] {
    if let sharded = loadShardedEntries(for: root) { return sharded }
    return loadLegacyPayload(for: root)?.entries ?? [:]
  }

  func saveEntries(_ entries: [String: LibraryIndexCacheEntry], for root: LibraryFolderIdentity) {
    var shards = [[String: LibraryIndexCacheEntry]](repeating: [:], count: Self.shardCount)
    for (path, entry) in entries {
      shards[Self.shardIndex(forPath: path)][path] = entry
    }
    for (shard, shardEntries) in shards.enumerated() {
      saveShard(shardEntries, shard: shard, for: root)
    }
    clearLegacyPayload(for: root)
  }

  /// Applies a small entry delta, rewriting only the shards it touches.
  /// Removals apply before updates so a replaced path keeps its new entry.
  func applyEntryDelta(
    updating updated: [String: LibraryIndexCacheEntry],
    removingPaths removedPaths: Set<String>,
    for root: LibraryFolderIdentity
  ) {
    guard !updated.isEmpty || !removedPaths.isEmpty else { return }
    if let legacy = loadLegacyPayload(for: root), !legacy.entries.isEmpty {
      // The pre-shard single-file layout cannot take deltas; migrate it once.
      var entries = loadShardedEntries(for: root) ?? legacy.entries
      for path in removedPaths { entries.removeValue(forKey: path) }
      entries.merge(updated) { _, new in new }
      saveEntries(entries, for: root)
      return
    }
    var removalsByShard: [Int: [String]] = [:]
    for path in removedPaths {
      removalsByShard[Self.shardIndex(forPath: path), default: []].append(path)
    }
    var updatesByShard: [Int: [String: LibraryIndexCacheEntry]] = [:]
    for (path, entry) in updated {
      updatesByShard[Self.shardIndex(forPath: path), default: [:]][path] = entry
    }
    let dirtyShards = Set(removalsByShard.keys).union(updatesByShard.keys)
    for shard in dirtyShards.sorted() {
      var entries = loadShard(shard, for: root) ?? [:]
      for path in removalsByShard[shard] ?? [] { entries.removeValue(forKey: path) }
      entries.merge(updatesByShard[shard] ?? [:]) { _, new in new }
      saveShard(entries, shard: shard, for: root)
    }
  }

  /// Merged shard contents, or nil when no shard file exists at the current
  /// derivation version — the signal to fall back to the legacy layout.
  private func loadShardedEntries(
    for root: LibraryFolderIdentity
  ) -> [String: LibraryIndexCacheEntry]? {
    var entries: [String: LibraryIndexCacheEntry] = [:]
    var foundShard = false
    for shard in 0..<Self.shardCount {
      guard let shardEntries = loadShard(shard, for: root) else { continue }
      foundShard = true
      entries.merge(shardEntries) { _, new in new }
    }
    return foundShard ? entries : nil
  }

  private func loadShard(
    _ shard: Int, for root: LibraryFolderIdentity
  ) -> [String: LibraryIndexCacheEntry]? {
    let persistence = persistenceForKey(Self.shardKey(for: root, shard: shard))
    guard let payload = try? persistence.load(LibraryIndexCachePayload.self),
      payload.metadataDerivationVersion == Self.metadataDerivationVersion
    else { return nil }
    return payload.entries
  }

  private func saveShard(
    _ entries: [String: LibraryIndexCacheEntry], shard: Int, for root: LibraryFolderIdentity
  ) {
    let persistence = persistenceForKey(Self.shardKey(for: root, shard: shard))
    do {
      try persistence.save(
        LibraryIndexCachePayload(
          metadataDerivationVersion: Self.metadataDerivationVersion, entries: entries))
    } catch {
      NightdriveLog.library.info(
        "Saving the library index cache failed; the next launch rescans: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func loadLegacyPayload(for root: LibraryFolderIdentity) -> LibraryIndexCachePayload? {
    let persistence = persistenceForKey(Self.persistenceKey(for: root))
    guard let payload = try? persistence.load(LibraryIndexCachePayload.self),
      payload.metadataDerivationVersion == Self.metadataDerivationVersion
    else { return nil }
    return payload
  }

  private func clearLegacyPayload(for root: LibraryFolderIdentity) {
    let persistence = persistenceForKey(Self.persistenceKey(for: root))
    guard (try? persistence.load()) != nil else { return }
    if let removable = persistence as? RemovableAppDataPersistence,
      (try? removable.remove()) != nil
    {
      return
    }
    // A tombstone for persistence backends that cannot remove: an empty
    // legacy payload reads the same as an absent one.
    try? persistence.save(
      LibraryIndexCachePayload(
        metadataDerivationVersion: Self.metadataDerivationVersion, entries: [:]))
  }

  func loadEntries(for folder: URL) -> [String: LibraryIndexCacheEntry] {
    guard let root = try? LibraryFolderIdentity.resolve(folder) else { return [:] }
    return loadEntries(for: root)
  }

  func saveEntries(_ entries: [String: LibraryIndexCacheEntry], for folder: URL) {
    guard let root = try? LibraryFolderIdentity.resolve(folder) else { return }
    saveEntries(entries, for: root)
  }
}
