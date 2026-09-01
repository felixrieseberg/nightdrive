import Foundation
import Observation

/// Shared debounced-persistence machinery for sidecar-backed stores. The
/// engine owns the write debounce, pending-write retirement, session and
/// generation guards, and load-failure bookkeeping; the owning store keeps
/// only its payload and provides snapshots of it on demand.
@Observable
@MainActor
final class DebouncedPersistenceEngine<Snapshot: Encodable & Sendable> {
  struct StateSnapshot {
    fileprivate let persistenceError: String?
    fileprivate let persistenceBlock: AppDataMutationBlockedError?
    fileprivate let mutationGeneration: UInt64
    fileprivate let persistedGeneration: UInt64
  }

  private(set) var persistenceError: String?

  @ObservationIgnored private var persistence: any AppDataPersistence
  @ObservationIgnored private var snapshotWriter: AppDataSnapshotWriter<Snapshot>
  @ObservationIgnored private var persistenceBlock: AppDataMutationBlockedError?
  @ObservationIgnored private var mutationValidator: (() throws -> Void)?
  @ObservationIgnored private var persistenceTask: Task<Void, Never>?
  @ObservationIgnored private var retiredWriteTasks: [Task<String?, Never>] = []
  @ObservationIgnored private var persistenceSession: UInt64 = 0
  @ObservationIgnored private var mutationGeneration: UInt64 = 0
  @ObservationIgnored private var persistedGeneration: UInt64 = 0
  @ObservationIgnored private let debounce: Duration
  /// Reads the owning store's current payload; `nil` once the store is gone.
  @ObservationIgnored var snapshotProvider: () -> Snapshot? = { nil }

  init(persistence: any AppDataPersistence, debounce: Duration) {
    self.persistence = persistence
    self.snapshotWriter = AppDataSnapshotWriter(persistence: persistence)
    self.debounce = debounce
  }

  /// Swaps the backing persistence, retiring any pending write against the
  /// previous location first, and resets all bookkeeping for the new one.
  func usePersistence(_ persistence: any AppDataPersistence) {
    retirePendingWrite()
    self.persistence = persistence
    snapshotWriter = AppDataSnapshotWriter(persistence: persistence)
    persistenceSession &+= 1
    mutationGeneration = 0
    persistedGeneration = 0
    persistenceError = nil
    persistenceBlock = nil
  }

  /// Re-reads the persisted payload via `reload`. A scan can finish while a
  /// debounced write is pending. In-memory state is authoritative until that
  /// snapshot is durable; do not replace it with an older file image unless
  /// recovery explicitly discards the pending edits.
  func reloadFromPersistence(discardingPendingChanges: Bool, reload: () -> Void) throws {
    guard discardingPendingChanges || mutationGeneration == persistedGeneration else { return }
    persistenceTask?.cancel()
    persistenceTask = nil
    persistenceSession &+= 1
    reload()
    snapshotWriter = AppDataSnapshotWriter(persistence: persistence)
    if let persistenceBlock { throw persistenceBlock }
    mutationGeneration = 0
    persistedGeneration = 0
  }

  /// Loads the persisted payload and records failure bookkeeping: a missing
  /// or loaded file clears any block, while a malformed or unreadable one
  /// blocks mutations and surfaces the failure.
  func loadOutcome<Value: Decodable>(_ type: Value.Type) -> AppDataLoadOutcome<Value> {
    let outcome = persistence.loadOutcome(type)
    switch outcome {
    case .missing, .loaded:
      persistenceBlock = nil
      persistenceError = nil
    case .malformed(let failure):
      let blocked = AppDataMutationBlockedError(reason: failure.reason)
      persistenceBlock = blocked
      persistenceError = blocked.localizedDescription
    case .unreadable(let failure):
      let blocked = AppDataMutationBlockedError(reason: failure.reason, kind: .unreadable)
      persistenceBlock = blocked
      persistenceError = blocked.localizedDescription
    }
    return outcome
  }

  func stateSnapshot() -> StateSnapshot {
    StateSnapshot(
      persistenceError: persistenceError, persistenceBlock: persistenceBlock,
      mutationGeneration: mutationGeneration, persistedGeneration: persistedGeneration)
  }

  func restoreState(_ snapshot: StateSnapshot) {
    persistenceError = snapshot.persistenceError
    persistenceBlock = snapshot.persistenceBlock
    mutationGeneration = snapshot.mutationGeneration
    persistedGeneration = snapshot.persistedGeneration
    persistenceSession &+= 1
  }

  func setMutationValidator(_ validator: @escaping () throws -> Void) {
    mutationValidator = validator
  }

  func dismissPersistenceError() {
    persistenceError = nil
  }

  var canReloadDiscardingPendingChanges: Bool {
    persistenceError != nil && mutationGeneration != persistedGeneration
  }

  /// Records a completed in-memory mutation and schedules a coalesced write.
  func noteMutation() {
    mutationGeneration &+= 1
    scheduleWrite()
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    func clearLoadFailureForDevelopment() {
      persistenceBlock = nil
      persistenceError = nil
    }
  #endif

  /// Makes the latest in-memory snapshot durable. Sync and shutdown await
  /// this explicitly; ordinary edits use the coalesced background path.
  func flushPersistence() async throws {
    persistenceTask?.cancel()
    persistenceTask = nil

    var firstFailure: AppDataRetiredWriteError?
    let retired = retiredWriteTasks
    retiredWriteTasks.removeAll()
    for task in retired {
      if let reason = await task.value, firstFailure == nil {
        firstFailure = AppDataRetiredWriteError(reason: reason)
      }
    }
    if let firstFailure { throw firstFailure }

    try ensurePersistenceWritable()

    let generation = mutationGeneration
    if generation > persistedGeneration {
      let session = persistenceSession
      let writer = snapshotWriter
      guard let snapshot = snapshotProvider() else { return }
      do {
        try await writer.save(snapshot, generation: generation)
        guard session == persistenceSession else {
          return
        }
        persistedGeneration = max(persistedGeneration, generation)
        if generation == mutationGeneration { persistenceError = nil }
      } catch {
        if session == persistenceSession {
          persistenceError = error.localizedDescription
        }
        throw error
      }
    }
  }

  private func scheduleWrite() {
    persistenceTask?.cancel()
    let session = persistenceSession
    let generation = mutationGeneration
    let writer = snapshotWriter
    let delay = debounce
    persistenceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self, session == self.persistenceSession,
        generation == self.mutationGeneration,
        let snapshot = self.snapshotProvider()
      else { return }
      do {
        try await writer.save(snapshot, generation: generation)
        guard session == self.persistenceSession else { return }
        self.persistedGeneration = max(self.persistedGeneration, generation)
        if generation == self.mutationGeneration { self.persistenceError = nil }
      } catch {
        guard session == self.persistenceSession,
          generation == self.mutationGeneration
        else { return }
        self.persistenceError = error.localizedDescription
      }
    }
  }

  private func retirePendingWrite() {
    persistenceTask?.cancel()
    persistenceTask = nil
    guard mutationGeneration > persistedGeneration, let snapshot = snapshotProvider() else {
      return
    }
    let writer = snapshotWriter
    let generation = mutationGeneration
    retiredWriteTasks.append(
      Task {
        do {
          try await writer.save(snapshot, generation: generation)
          return nil
        } catch {
          return error.localizedDescription
        }
      })
  }

  /// Verifies the store can accept a mutation right now. Callers about to
  /// perform destructive filesystem work preflight with this so a blocked
  /// sidecar aborts before any file moves.
  func ensurePersistenceWritable() throws {
    try mutationValidator?()
    if let persistenceBlock { throw persistenceBlock }
    if persistence is EmptyDataPersistence {
      throw AppDataLibraryNotSelectedError()
    }
  }
}
