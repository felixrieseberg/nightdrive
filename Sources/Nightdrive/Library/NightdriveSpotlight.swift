import AppIntents
import CoreSpotlight
import Foundation

@MainActor
protocol NightdriveSpotlightWriting: AnyObject {
  func index(_ entities: [NightdriveCollectionEntity]) async throws
  func delete(identifiers: [String]) async throws
  func deleteAll() async throws
}

@MainActor
protocol NightdriveSpotlightSnapshotStoring: AnyObject {
  func load() -> [String: NightdriveCollectionEntity]?
  func save(_ entities: [String: NightdriveCollectionEntity]) throws
}

@MainActor
final class NightdriveSpotlightDefaultsSnapshotStore: NightdriveSpotlightSnapshotStoring {
  private let defaults: UserDefaults
  private let key = "spotlight.collections.v1"

  init(defaults: UserDefaults = NightdriveDefaults.current) {
    self.defaults = defaults
  }

  func load() -> [String: NightdriveCollectionEntity]? {
    defaults.data(forKey: key).flatMap {
      try? JSONDecoder().decode([String: NightdriveCollectionEntity].self, from: $0)
    }
  }

  func save(_ entities: [String: NightdriveCollectionEntity]) throws {
    defaults.set(try JSONEncoder().encode(entities), forKey: key)
  }
}

@MainActor
final class CoreSpotlightWriter: NightdriveSpotlightWriting {
  func index(_ entities: [NightdriveCollectionEntity]) async throws {
    guard !entities.isEmpty else { return }
    try await CSSearchableIndex.default().indexAppEntities(entities)
  }

  func delete(identifiers: [String]) async throws {
    guard !identifiers.isEmpty else { return }
    try await CSSearchableIndex.default().deleteAppEntities(
      identifiedBy: identifiers, ofType: NightdriveCollectionEntity.self)
  }

  func deleteAll() async throws {
    try await CSSearchableIndex.default().deleteAppEntities(
      ofType: NightdriveCollectionEntity.self)
  }
}

@MainActor
final class NightdriveSpotlightSynchronizer {
  nonisolated static let domainIdentifier = "dev.nightdrive.library"

  private let writer: any NightdriveSpotlightWriting
  private let snapshotStore: any NightdriveSpotlightSnapshotStoring
  private var indexed: [String: NightdriveCollectionEntity]?
  private var debounceTask: Task<Void, Never>?
  private var synchronizationTail: Task<Void, Never>?

  init(
    writer: any NightdriveSpotlightWriting = CoreSpotlightWriter(),
    snapshotStore: any NightdriveSpotlightSnapshotStoring = NightdriveSpotlightDefaultsSnapshotStore()
  ) {
    self.writer = writer
    self.snapshotStore = snapshotStore
    self.indexed = snapshotStore.load()
  }

  func schedule(_ entities: [NightdriveCollectionEntity]) {
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      await self?.synchronize(entities)
    }
  }

  func synchronize(_ entities: [NightdriveCollectionEntity]) async {
    let precedingTask = synchronizationTail
    let task = Task { @MainActor [weak self] in
      await precedingTask?.value
      await self?.performSynchronization(entities)
    }
    synchronizationTail = task
    await task.value
  }

  private func performSynchronization(_ entities: [NightdriveCollectionEntity]) async {
    let next = Dictionary(
      entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let entities = next.values.sorted { $0.id < $1.id }
    do {
      guard let indexed else {
        try await writer.deleteAll()
        if !entities.isEmpty { try await writer.index(entities) }
        try snapshotStore.save(next)
        self.indexed = next
        return
      }
      guard next != indexed else { return }
      let removed = indexed.keys.filter { next[$0] == nil }.sorted()
      let changed = entities.filter { indexed[$0.id] != $0 }
      if !removed.isEmpty { try await writer.delete(identifiers: removed) }
      if !changed.isEmpty { try await writer.index(changed) }
      try snapshotStore.save(next)
      self.indexed = next
    } catch {
      NightdriveLog.app.error(
        "Updating Spotlight failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  func flush() async {
    await debounceTask?.value
    await synchronizationTail?.value
  }
}
