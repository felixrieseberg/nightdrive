import Foundation

/// Debounced, cancellable search resolution shared by the Cmd+K palette and
/// the library filter: a search index built off the main actor once per
/// library revision (and cached across queries and views), plus per-query
/// matching on a detached task. Callers drive `resolve` from a SwiftUI
/// `.task(id:)`, so a newer keystroke or library revision cancels the
/// in-flight call while the index build carries on for reuse.
@MainActor
@Observable
final class DebouncedSearchModel<Index: Sendable, Value: Sendable> {
  struct Resolved {
    let query: String
    let revision: UInt64
    let value: Value
  }

  private(set) var resolved: Resolved?
  @ObservationIgnored private var indexRevision: UInt64?
  @ObservationIgnored private var indexTask: Task<Index, Never>?

  static var debounce: Duration { .milliseconds(100) }

  /// Resolves one query against the index for `revision`. An empty query
  /// clears the last result but still warms the index so the first real
  /// keystroke doesn't pay for the build.
  func resolve(
    query: String, revision: UInt64,
    buildIndex: @escaping @Sendable () -> Index,
    match: @escaping @Sendable (Index) throws -> Value
  ) async {
    let indexTask = preparedIndexTask(revision: revision, buildIndex: buildIndex)
    guard !query.isEmpty else {
      resolved = nil
      return
    }
    guard resolved?.query != query || resolved?.revision != revision else { return }
    guard (try? await Task.sleep(for: Self.debounce)) != nil else { return }
    let index = await indexTask.value
    guard !Task.isCancelled else { return }
    let worker = Task.detached(priority: .userInitiated) { try match(index) }
    let value = await withTaskCancellationHandler {
      try? await worker.value
    } onCancel: {
      worker.cancel()
    }
    guard let value, !Task.isCancelled else { return }
    resolved = Resolved(query: query, revision: revision, value: value)
  }

  private func preparedIndexTask(
    revision: UInt64, buildIndex: @escaping @Sendable () -> Index
  ) -> Task<Index, Never> {
    if indexRevision == revision, let indexTask { return indexTask }
    // Detached so a cancelled keystroke never tears down the shared build.
    let task = Task.detached(priority: .userInitiated) { buildIndex() }
    indexRevision = revision
    indexTask = task
    return task
  }
}
