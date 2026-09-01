import AVFoundation
import Foundation
import Observation

/// A logical mutex for the full download-and-tag lifecycle. Main-actor
/// methods are reentrant at awaits, so actor isolation alone does not prevent
/// two enclosures from spending the same disk-capacity budget concurrently.
private actor PodcastDownloadGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isHeld {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

/// Podcast directory search, subscriptions, and episode downloads.
///
/// All network-touching methods (`search`, `loadPopular`, `loadFeed`,
/// `subscribe`, `refreshAll`, `download`) must only be invoked after the
/// caller has confirmed the user's online-services consent (see
/// `OnlineServicesPolicy`); this store deliberately does not gate requests
/// itself and never performs network work from `init`.
@MainActor
@Observable
final class PodcastStore {
  nonisolated static let defaultsKey = "podcastSubscriptions"

  private(set) var subscriptions: [PodcastSubscription] = []
  private(set) var feeds: [URL: PodcastFeed] = [:]
  private(set) var episodeStates: [String: PodcastEpisodeState] = [:]
  private(set) var popular: [PodcastDirectoryResult] = []
  private(set) var lastError: String?

  /// Set by the app to the current library folder. Downloads fail
  /// gracefully with `lastError` while it is nil or returns nil.
  var libraryFolderProvider: (@MainActor () -> URL?)?

  /// Set by the app to answer whether the audio file at a URL has been
  /// listened to (locally or on a synced iPod). Drives automatic removal
  /// and keeps auto-download from re-fetching finished episodes.
  var episodePlayedProvider: (@MainActor (URL) -> Bool)?

  @ObservationIgnored private let persistence: any AppDataPersistence
  @ObservationIgnored private let urlSession: URLSession
  @ObservationIgnored private let resourceLimits: PodcastResourceLimits
  @ObservationIgnored private let downloadGate = PodcastDownloadGate()
  @ObservationIgnored private let feedLoader: FeedLoader
  @ObservationIgnored private var isPreloadingEpisodes = false
  @ObservationIgnored private var isPerformingMaintenance = false
  @ObservationIgnored private var maintenanceNeedsAnotherPass = false
  /// Library-relative file paths of completed downloads keyed by episode id.
  /// Persisted so downloads survive publisher renames of show or episode
  /// titles (which change the computed path) and a library folder move.
  @ObservationIgnored private var downloadsCache: [String: String]?
  @ObservationIgnored private var downloadsCacheKey: String?
  @ObservationIgnored private var downloadsUnavailableReason: String?
  /// Feed ownership for each recorded episode id. Kept separately from the
  /// stable path sidecar so old libraries remain readable; a missing owner
  /// only disables pruning after an episode disappears from its feed.
  @ObservationIgnored private var downloadOwnersCache: [String: String]?
  @ObservationIgnored private var downloadOwnersCacheKey: String?
  @ObservationIgnored private var downloadOwnersUnavailableReason: String?

  nonisolated private static let progressUpdateByteStride: Int64 = 256 * 1024

  nonisolated private static let userAgent: String = {
    let info = Bundle.main.infoDictionary
    let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0"
    return "Nightdrive/\(version) (\(AppLinks.repository.absoluteString))"
  }()

  init(
    persistence: any AppDataPersistence = UserDefaultsDataPersistence(
      key: PodcastStore.defaultsKey),
    urlSession: URLSession = .shared,
    resourceLimits: PodcastResourceLimits = .standard
  ) {
    self.persistence = persistence
    self.urlSession = urlSession
    self.resourceLimits = resourceLimits
    self.feedLoader = FeedLoader(
      maximumConcurrentLoads: resourceLimits.maximumConcurrentFeedLoads)
    loadState()
  }

  // MARK: - Directory search

  func search(term: String) async -> [PodcastDirectoryResult] {
    guard let url = PodcastDirectory.searchURL(term: term) else { return [] }
    do {
      let data = try await Self.fetch(
        url, session: urlSession,
        maximumBytes: resourceLimits.maximumDirectoryResponseBytes)
      let results = try PodcastDirectory.results(from: data)
      lastError = nil
      return results
    } catch {
      recordError(error)
      return []
    }
  }

  // MARK: - Feeds

  /// Loads the current top-podcasts chart once per app run: chart IDs from
  /// Apple's marketing feed, then one batched lookup for the feed URLs.
  func loadPopular(while shouldContinue: @MainActor () -> Bool = { true }) async {
    guard popular.isEmpty else { return }
    guard shouldContinue(), !Task.isCancelled else { return }
    guard let chartURL = PodcastDirectory.topChartURL() else { return }
    do {
      let ids = try PodcastDirectory.chartIDs(
        from: try await Self.fetch(
          chartURL, session: urlSession,
          maximumBytes: resourceLimits.maximumDirectoryResponseBytes))
      guard shouldContinue(), !Task.isCancelled else { return }
      guard let lookupURL = PodcastDirectory.lookupURL(ids: ids) else { return }
      let results = try PodcastDirectory.results(
        from: try await Self.fetch(
          lookupURL, session: urlSession,
          maximumBytes: resourceLimits.maximumDirectoryResponseBytes))
      guard shouldContinue(), !Task.isCancelled else { return }
      popular = PodcastDirectory.ordered(results, byChartIDs: ids)
      lastError = nil
    } catch {
      recordError(error)
    }
  }

  @discardableResult
  func loadFeed(url: URL) async -> PodcastFeed? {
    install(
      await feedLoader.load(
        at: url, using: urlSession, maximumBytes: resourceLimits.maximumFeedBytes))
  }

  func refreshAll() async {
    for subscription in subscriptions {
      await loadFeed(url: subscription.feedURL)
    }
  }

  /// Warms subscribed episode lists and the Popular directory shortly after
  /// launch. Popular publishers are contacted only when the user opens a
  /// show; eagerly retaining every chart feed wastes memory and makes the
  /// directory list contact publishers unnecessarily.
  func preloadEpisodes(
    while podcastsAreEnabled: @MainActor () -> Bool,
    refreshSubscriptionsWhile shouldRefreshSubscriptions: @MainActor () -> Bool
  ) async {
    guard !isPreloadingEpisodes else { return }
    guard podcastsAreEnabled(), !Task.isCancelled else { return }
    let subscriptionURLs =
      shouldRefreshSubscriptions() ? subscriptions.map(\.feedURL) : []
    let subscriptionsAreWarm = subscriptionURLs.allSatisfy { feeds[$0] != nil }
    let popularDirectoryIsWarm = !popular.isEmpty
    guard !subscriptionsAreWarm || !popularDirectoryIsWarm else { return }

    isPreloadingEpisodes = true
    defer { isPreloadingEpisodes = false }

    async let popularLoad: Void = loadPopular(while: podcastsAreEnabled)
    await preloadFeeds(at: subscriptionURLs) {
      podcastsAreEnabled() && shouldRefreshSubscriptions()
    }
    await popularLoad

    if podcastsAreEnabled(), shouldRefreshSubscriptions(), !Task.isCancelled {
      await performMaintenance()
    }
  }

  private enum FeedPreloadOutcome: Sendable {
    case loaded(URL, PodcastFeed)
    case failed(String)
    case cancelled
  }

  /// Coalesces background and interactive loads of the same publisher feed.
  /// Each caller has its own continuation: cancelling one waiter returns it
  /// promptly without cancelling a request another caller still needs, while
  /// the underlying request is cancelled as soon as no waiters remain.
  private actor FeedLoader {
    private struct Entry {
      var task: Task<Void, Never>?
      var taskID: UUID?
      var waiters: [UUID: CheckedContinuation<FeedPreloadOutcome, Never>]
      let session: URLSession
      let maximumBytes: Int64
    }

    private let maximumConcurrentLoads: Int
    private var entries: [URL: Entry] = [:]
    private var pendingURLs: [URL] = []
    private var activeTaskIDs: Set<UUID> = []

    init(maximumConcurrentLoads: Int) {
      precondition(maximumConcurrentLoads > 0)
      self.maximumConcurrentLoads = maximumConcurrentLoads
    }

    func load(
      at url: URL, using session: URLSession, maximumBytes: Int64
    ) async -> FeedPreloadOutcome {
      let waiterID = UUID()
      return await withTaskCancellationHandler {
        let outcome = await wait(
          at: url, using: session, maximumBytes: maximumBytes, waiterID: waiterID)
        return Task.isCancelled ? .cancelled : outcome
      } onCancel: {
        Task { await self.cancel(waiterID: waiterID, at: url) }
      }
    }

    private func wait(
      at url: URL, using session: URLSession, maximumBytes: Int64, waiterID: UUID
    ) async -> FeedPreloadOutcome {
      guard !Task.isCancelled else { return .cancelled }
      return await withCheckedContinuation { continuation in
        if var entry = entries[url] {
          entry.waiters[waiterID] = continuation
          entries[url] = entry
          return
        }

        entries[url] = Entry(
          task: nil, taskID: nil, waiters: [waiterID: continuation],
          session: session, maximumBytes: maximumBytes)
        pendingURLs.append(url)
        startPendingLoads()
      }
    }

    private func cancel(waiterID: UUID, at url: URL) {
      guard var entry = entries[url], let waiter = entry.waiters.removeValue(forKey: waiterID)
      else { return }
      waiter.resume(returning: .cancelled)
      if entry.waiters.isEmpty {
        entry.task?.cancel()
        entries[url] = nil
        pendingURLs.removeAll { $0 == url }
        startPendingLoads()
      } else {
        entries[url] = entry
      }
    }

    private func startPendingLoads() {
      while activeTaskIDs.count < maximumConcurrentLoads, !pendingURLs.isEmpty {
        let url = pendingURLs.removeFirst()
        guard var entry = entries[url], entry.task == nil, !entry.waiters.isEmpty else {
          continue
        }
        let taskID = UUID()
        let session = entry.session
        let maximumBytes = entry.maximumBytes
        activeTaskIDs.insert(taskID)
        entry.taskID = taskID
        entry.task = Task { [weak self] in
          let outcome = await PodcastStore.preloadFeed(
            at: url, using: session, maximumBytes: maximumBytes)
          await self?.finish(outcome, at: url, taskID: taskID)
        }
        entries[url] = entry
      }
    }

    private func finish(_ outcome: FeedPreloadOutcome, at url: URL, taskID: UUID) {
      activeTaskIDs.remove(taskID)
      if let entry = entries[url], entry.taskID == taskID {
        entries[url] = nil
        for waiter in entry.waiters.values {
          waiter.resume(returning: outcome)
        }
      }
      startPendingLoads()
    }
  }

  private func preloadFeeds<S: Sequence>(
    at urls: S, while shouldContinue: @MainActor () -> Bool
  ) async where S.Element == URL {
    var seen: Set<URL> = []
    let remaining = urls.filter { feeds[$0] == nil && seen.insert($0).inserted }
    var iterator = remaining.makeIterator()
    let session = urlSession
    let loader = feedLoader
    let maximumBytes = resourceLimits.maximumFeedBytes

    await withTaskGroup(of: FeedPreloadOutcome.self) { group in
      for _ in 0..<resourceLimits.maximumConcurrentFeedLoads {
        guard shouldContinue(), !Task.isCancelled, let url = iterator.next() else { break }
        group.addTask {
          await loader.load(at: url, using: session, maximumBytes: maximumBytes)
        }
      }

      while let outcome = await group.next() {
        _ = install(outcome)

        guard shouldContinue(), !Task.isCancelled else {
          group.cancelAll()
          continue
        }
        if let url = iterator.next() {
          group.addTask {
            await loader.load(at: url, using: session, maximumBytes: maximumBytes)
          }
        }
      }
    }
  }

  @discardableResult
  private func install(_ outcome: FeedPreloadOutcome) -> PodcastFeed? {
    switch outcome {
    case .loaded(let url, let feed):
      feeds[url] = feed
      reconcileEpisodeStates(for: feed, feedURL: url)
      lastError = nil
      return feed
    case .failed(let message):
      lastError = message
      return nil
    case .cancelled:
      return nil
    }
  }

  nonisolated private static func preloadFeed(
    at url: URL, using session: URLSession, maximumBytes: Int64
  ) async -> FeedPreloadOutcome {
    do {
      let data = try await fetch(url, session: session, maximumBytes: maximumBytes)
      return .loaded(url, try await parseFeed(data: data, feedURL: url))
    } catch {
      return isCancellation(error) ? .cancelled : .failed(error.localizedDescription)
    }
  }

  // MARK: - Subscriptions

  func subscribe(_ result: PodcastDirectoryResult) async {
    if !isSubscribed(feedURL: result.feedURL) {
      addSubscription(
        PodcastSubscription(
          feedURL: result.feedURL,
          title: result.title,
          author: result.author.isEmpty ? nil : result.author,
          artworkURL: result.artworkURL,
          addedAt: Date()))
    }
    // A feed the user was just browsing is already loaded; don't reload it
    // out from under the visible episode list.
    if feeds[result.feedURL] == nil {
      await loadFeed(url: result.feedURL)
    }
  }

  func subscribe(feedURL: URL) async {
    var feed = feeds[feedURL]
    if feed == nil {
      feed = await loadFeed(url: feedURL)
    }
    guard let feed else { return }
    guard !isSubscribed(feedURL: feedURL) else { return }
    addSubscription(
      PodcastSubscription(
        feedURL: feedURL,
        title: feed.title.isEmpty ? feedURL.absoluteString : feed.title,
        author: feed.author,
        artworkURL: feed.artworkURL,
        addedAt: Date()))
  }

  func unsubscribe(_ subscription: PodcastSubscription) {
    subscriptions.removeAll { $0.feedURL == subscription.feedURL }
    // The loaded feed and its episode states stay: the show remains
    // browsable exactly like any other unsubscribed show, and downloaded
    // files remain in the library either way.
    saveState()
  }

  private func isSubscribed(feedURL: URL) -> Bool {
    subscriptions.contains { $0.feedURL == feedURL }
  }

  func setAutoDownloadCount(_ count: Int, for subscription: PodcastSubscription) {
    updateSubscription(subscription.feedURL) { $0.autoDownloadCount = max(0, count) }
  }

  func setAutoDeleteKeepCount(_ count: Int, for subscription: PodcastSubscription) {
    updateSubscription(subscription.feedURL) { $0.autoDeleteKeepCount = max(0, count) }
  }

  func setRemovePlayedEpisodes(_ enabled: Bool, for subscription: PodcastSubscription) {
    updateSubscription(subscription.feedURL) { $0.removePlayedEpisodes = enabled }
  }

  private func updateSubscription(_ feedURL: URL, _ change: (inout PodcastSubscription) -> Void) {
    guard let index = subscriptions.firstIndex(where: { $0.feedURL == feedURL }) else { return }
    change(&subscriptions[index])
    saveState()
  }

  // MARK: - Automatic maintenance

  /// Applies each subscription's automation: removes downloaded episodes
  /// outside its newest-episode retention limit or already listened to,
  /// then downloads the configured newest episodes, skipping ones already
  /// played. Callers gate this behind podcast consent; it fetches feeds that
  /// are not loaded yet.
  ///
  /// Settings changed while a pass runs are honored: the pass re-resolves
  /// each subscription's current settings after every await, and a call
  /// arriving during an active run queues one more full pass so its
  /// (possibly corrective) intent is never dropped.
  func performMaintenance() async {
    guard !isPerformingMaintenance else {
      maintenanceNeedsAnotherPass = true
      return
    }
    isPerformingMaintenance = true
    defer { isPerformingMaintenance = false }
    repeat {
      maintenanceNeedsAnotherPass = false
      await performMaintenancePass()
    } while maintenanceNeedsAnotherPass
  }

  private func performMaintenancePass() async {
    var firstDeletionError: String?
    for subscription in subscriptions {
      guard
        subscription.autoDownloadCount > 0 || subscription.autoDeleteKeepCount > 0
          || subscription.removePlayedEpisodes
      else {
        continue
      }
      let feedURL = subscription.feedURL
      var loadedFeed = feeds[feedURL]
      if loadedFeed == nil {
        loadedFeed = await loadFeed(url: feedURL)
      }
      guard let feed = loadedFeed else { continue }

      // The user may have changed this subscription's automation (or
      // unsubscribed) while the feed was loading; act on current settings,
      // not the snapshot this pass started from.
      guard let afterLoad = currentSubscription(feedURL) else { continue }
      let candidates = feed.episodes.filter {
        PodcastFileNaming.downloadExtension(
          forEnclosure: $0.enclosureURL, mimeType: $0.enclosureType) != nil
      }
      if afterLoad.autoDeleteKeepCount > 0 {
        if let error = deleteDownloadsOutsideRetention(
          keeping: afterLoad.autoDeleteKeepCount, feedURL: feedURL, feed: feed,
          candidates: candidates), firstDeletionError == nil
        {
          firstDeletionError = error
        }
      }
      if afterLoad.removePlayedEpisodes {
        for episode in feed.episodes {
          if case .downloaded(let fileURL) = episodeStates[episode.id], isPlayed(fileURL) {
            if !deleteDownload(episode), firstDeletionError == nil {
              firstDeletionError = lastError
            }
          }
        }
      }

      for (index, episode) in candidates.enumerated() {
        // Re-check before every download: either limit may have changed while
        // the previous episode was fetching. Retention caps downloading so a
        // "download 5, delete all but 3" setup never fetches and immediately
        // removes episodes four and five on every pass.
        guard let current = currentSubscription(feedURL) else { break }
        let downloadCount =
          current.autoDeleteKeepCount > 0
          ? min(current.autoDownloadCount, current.autoDeleteKeepCount)
          : current.autoDownloadCount
        guard index < downloadCount else { break }
        guard case .notDownloaded = episodeStates[episode.id] ?? .notDownloaded else { continue }
        // A finished episode stays played in listening history even after
        // its file is removed, so automation never re-downloads it.
        if let expected = expectedFileURL(for: episode), isPlayed(expected) { continue }
        await download(episode)
      }
    }
    // Successful downloads clear the store's transient error banner. A
    // deletion that failed earlier in this same pass must remain visible.
    if let firstDeletionError { lastError = firstDeletionError }
  }

  private func currentSubscription(_ feedURL: URL) -> PodcastSubscription? {
    subscriptions.first { $0.feedURL == feedURL }
  }

  private func isPlayed(_ fileURL: URL) -> Bool {
    episodePlayedProvider?(fileURL) ?? false
  }

  /// Retention mirrors auto-download's newest-first, downloadable-only
  /// ordering. It also removes recorded downloads that have disappeared
  /// from a publisher's rolling feed; otherwise a one-item feed would retain
  /// every episode it ever published despite a keep-one policy.
  private func deleteDownloadsOutsideRetention(
    keeping count: Int, feedURL: URL, feed: PodcastFeed, candidates: [PodcastEpisode]
  ) -> String? {
    var firstError: String?
    let retainedIDs = Set(candidates.prefix(count).map(\.id))
    for episode in candidates.dropFirst(count) {
      if case .downloaded = episodeStates[episode.id] {
        if !deleteDownload(episode), firstError == nil { firstError = lastError }
      }
    }

    guard let (libraryFolder, libraryKey) = currentLibrary else { return firstError }
    if let reason = downloadsRecordUnavailableReason(in: libraryFolder, key: libraryKey) {
      lastError = reason
      return firstError ?? reason
    }
    guard let owners = downloadOwners(in: libraryFolder, key: libraryKey) else {
      return firstError
    }
    let currentFeedIDs = Set(feed.episodes.map(\.id))
    let disappearedDownloads = downloads(in: libraryFolder, key: libraryKey).filter {
      owners[$0.key] == feedURL.absoluteString && !currentFeedIDs.contains($0.key)
        && !retainedIDs.contains($0.key)
    }
    for (episodeID, relativePath) in disappearedDownloads {
      guard
        let fileURL = Self.downloadURL(
          forEpisode: episodeID, relativePath: relativePath, in: libraryFolder)
      else { continue }
      if !deleteDownload(
        episodeID: episodeID, fileURL: fileURL, in: libraryFolder, key: libraryKey),
        firstError == nil
      {
        firstError = lastError
      }
    }
    return firstError
  }

  /// The active library folder together with the cache key its download
  /// mapping is held under in memory. The mapping itself lives in a sidecar
  /// inside the library folder, so identity comes from the folder's own
  /// contents — the key only prevents redundant sidecar reads.
  private var currentLibrary: (folder: URL, key: String)? {
    guard let folder = libraryFolderProvider?() else { return nil }
    return (folder, folder.canonicalFileURL.path)
  }

  /// This library's episode-id → library-relative-path download record,
  /// loaded from its sidecar. Like the playlists and listening-history
  /// sidecars, the record travels with the folder through moves and renames
  /// and is never shared between different libraries at the same path.
  /// A malformed or unreadable sidecar is NOT an empty one: reads fall back
  /// to title-derived paths, but writes refuse so a rewrite can never
  /// destroy the existing record.
  private func downloads(in folder: URL, key: String) -> [String: String] {
    loadDownloadsIfNeeded(in: folder, key: key)
    return downloadsCache ?? [:]
  }

  private func loadDownloadsIfNeeded(in folder: URL, key: String) {
    guard downloadsCacheKey != key else { return }
    let url = PodcastDownloadsFile.url(for: folder)
    do {
      let mapping = try SidecarJSONFile.loadOutcome([String: String].self, at: url)
        .unwrap(url: url, whenMissing: [:])
      if mapping.contains(where: {
        Self.downloadURL(forEpisode: $0.key, relativePath: $0.value, in: folder) == nil
      }) {
        downloadsCache = nil
        downloadsUnavailableReason = String(
          localized:
            "The podcast download record at \(url.path) contains an unsafe file path. Restore or remove that file before changing podcast downloads."
        )
      } else {
        downloadsCache = mapping
        downloadsUnavailableReason = nil
      }
    } catch {
      downloadsCache = nil
      downloadsUnavailableReason = error.localizedDescription
    }
    downloadsCacheKey = key
  }

  /// Records (path non-nil) or forgets (nil) an episode's download in the
  /// library's sidecar. Returns false — with `lastError` set — when the
  /// record could not be persisted; the in-memory cache only takes the new
  /// value after the write succeeds.
  @discardableResult
  private func setDownloadPath(
    _ path: String?, forEpisode episodeID: String, in folder: URL, key: String
  ) -> Bool {
    loadDownloadsIfNeeded(in: folder, key: key)
    if let reason = downloadsUnavailableReason {
      lastError = reason
      return false
    }
    var mapping = downloadsCache ?? [:]
    if let path {
      mapping[episodeID] = path
    } else if mapping.removeValue(forKey: episodeID) == nil {
      return true
    }
    do {
      try Self.saveDownloads(mapping, in: folder)
    } catch {
      lastError = error.localizedDescription
      return false
    }
    downloadsCache = mapping
    return true
  }

  /// Non-nil while the current library's download sidecar exists but cannot
  /// be trusted (malformed or unreadable). Recording downloads is blocked
  /// until it is repaired so the existing record is never overwritten.
  private func downloadsRecordUnavailableReason(in folder: URL, key: String) -> String? {
    loadDownloadsIfNeeded(in: folder, key: key)
    return downloadsUnavailableReason
  }

  /// Exact feed ownership for download ids. Legacy libraries have no owner
  /// sidecar and safely return an empty mapping; a malformed sidecar returns
  /// nil so it is never used to authorize destructive orphan pruning.
  private func downloadOwners(in folder: URL, key: String) -> [String: String]? {
    loadDownloadOwnersIfNeeded(in: folder, key: key)
    guard downloadOwnersUnavailableReason == nil else { return nil }
    return downloadOwnersCache ?? [:]
  }

  private func loadDownloadOwnersIfNeeded(in folder: URL, key: String) {
    guard downloadOwnersCacheKey != key else { return }
    let url = PodcastDownloadOwnersFile.url(for: folder)
    do {
      downloadOwnersCache = try SidecarJSONFile.loadOutcome([String: String].self, at: url)
        .unwrap(url: url, whenMissing: [:])
      downloadOwnersUnavailableReason = nil
    } catch {
      downloadOwnersCache = nil
      downloadOwnersUnavailableReason = error.localizedDescription
    }
    downloadOwnersCacheKey = key
  }

  /// Records exact ownership when known, or removes it alongside a deleted
  /// download. Failure is non-destructive: the path record remains usable,
  /// but missing ownership prevents pruning after the item leaves its feed.
  @discardableResult
  private func setDownloadOwner(
    _ feedURL: URL?, forEpisode episodeID: String, in folder: URL, key: String
  ) -> Bool {
    loadDownloadOwnersIfNeeded(in: folder, key: key)
    guard downloadOwnersUnavailableReason == nil else { return false }
    var owners = downloadOwnersCache ?? [:]
    if let feedURL {
      let owner = feedURL.absoluteString
      if owners[episodeID] == owner { return true }
      owners[episodeID] = owner
    } else if owners.removeValue(forKey: episodeID) == nil {
      return true
    }
    do {
      try Self.saveDownloadOwners(owners, in: folder)
    } catch {
      downloadOwnersUnavailableReason = error.localizedDescription
      return false
    }
    downloadOwnersCache = owners
    return true
  }

  /// The library-relative path computed from the episode's current feed
  /// titles; nil for unsupported enclosure formats.
  private static func titledRelativePath(for episode: PodcastEpisode) -> String? {
    guard
      let fileExtension = PodcastFileNaming.downloadExtension(
        forEnclosure: episode.enclosureURL, mimeType: episode.enclosureType)
    else { return nil }
    return PodcastFileNaming.episodeRelativePath(
      showTitle: episode.showTitle, episodeTitle: episode.title,
      episodeID: episode.id, fileExtension: fileExtension)
  }

  /// Where the episode's download lives (or would live) in the current
  /// library: that library's persisted mapping first — it survives title
  /// renames — then the path computed from the current feed titles.
  private func expectedFileURL(for episode: PodcastEpisode) -> URL? {
    guard let (folder, key) = currentLibrary else { return nil }
    let relativePath =
      downloads(in: folder, key: key)[episode.id]
      ?? Self.titledRelativePath(for: episode)
    return relativePath.flatMap {
      Self.downloadURL(forEpisode: episode.id, relativePath: $0, in: folder)
    }
  }

  /// Verifies that the current library's podcast record can be trusted
  /// before filesystem maintenance starts moving files.
  func ensureDownloadsPersistenceWritable() throws {
    guard let (folder, key) = currentLibrary else { throw AppDataLibraryNotSelectedError() }
    if let reason = downloadsRecordUnavailableReason(in: folder, key: key) {
      throw PodcastFeedError(reason: reason)
    }
  }

  /// Retargets completed downloads after trusted moves inside the active
  /// library. Podcast filenames retain their ownership fingerprint through
  /// organizer renames, so a later reload can still reject corrupt paths.
  func remapMovedFiles(_ movesByRelativePath: [String: String]) throws {
    guard !movesByRelativePath.isEmpty else { return }
    guard let (folder, key) = currentLibrary else { throw AppDataLibraryNotSelectedError() }
    try ensureDownloadsPersistenceWritable()
    var mapping = downloads(in: folder, key: key)
    var changed = false
    for (episodeID, source) in mapping {
      guard let destination = movesByRelativePath[source] else { continue }
      guard Self.downloadURL(forEpisode: episodeID, relativePath: destination, in: folder) != nil
      else {
        throw PodcastFeedError(
          reason: String(
            localized: "An organized podcast filename lost its download identifier."))
      }
      mapping[episodeID] = destination
      changed = true
    }
    guard changed else { return }
    try Self.saveDownloads(mapping, in: folder)
    downloadsCache = mapping
    for (feedURL, feed) in feeds { reconcileEpisodeStates(for: feed, feedURL: feedURL) }
  }

  /// Called when the active library folder changes: episode states from the
  /// previous library no longer apply, and loaded feeds re-reconcile
  /// against the new library's own download sidecar.
  func libraryFolderDidChange() {
    downloadsCache = nil
    downloadsCacheKey = nil
    downloadsUnavailableReason = nil
    downloadOwnersCache = nil
    downloadOwnersCacheKey = nil
    downloadOwnersUnavailableReason = nil
    for (id, state) in episodeStates {
      // In-flight downloads re-verify the folder before publishing.
      if case .downloading = state { continue }
      episodeStates[id] = .notDownloaded
    }
    for (feedURL, feed) in feeds {
      reconcileEpisodeStates(for: feed, feedURL: feedURL)
    }
  }

  private func addSubscription(_ subscription: PodcastSubscription) {
    subscriptions.append(subscription)
    subscriptions.sort {
      $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
    }
    saveState()
  }

  // MARK: - Downloads

  func download(_ episode: PodcastEpisode) async {
    if case .downloading = episodeStates[episode.id] { return }
    guard let (libraryFolder, libraryKey) = currentLibrary else {
      let message = String(
        localized: "Choose a library folder before downloading podcast episodes.")
      lastError = message
      episodeStates[episode.id] = .failed(message: message)
      return
    }
    guard let relativePath = Self.titledRelativePath(for: episode) else {
      let format =
        episode.enclosureURL.pathExtension.isEmpty
        ? (episode.enclosureType ?? String(localized: "unknown"))
        : episode.enclosureURL.pathExtension.uppercased()
      let message = String(
        localized:
          "This episode is a \(format) file. Nightdrive downloads MP3 and M4A episodes only."
      )
      episodeStates[episode.id] = .failed(message: message)
      return
    }
    // A damaged download record blocks new downloads outright: completing
    // one would have to rewrite the sidecar and could orphan every
    // previously recorded file.
    if let reason = downloadsRecordUnavailableReason(in: libraryFolder, key: libraryKey) {
      lastError = reason
      episodeStates[episode.id] = .failed(message: reason)
      return
    }

    guard
      let destination = Self.downloadURL(
        forEpisode: episode.id, relativePath: relativePath, in: libraryFolder)
    else {
      let message = String(localized: "The podcast download path is unsafe.")
      lastError = message
      episodeStates[episode.id] = .failed(message: message)
      return
    }
    let fileExtension = destination.pathExtension
    let temporary = destination.deletingLastPathComponent()
      .appendingPathComponent(
        ".\(destination.deletingPathExtension().lastPathComponent).partial-\(UUID().uuidString).\(fileExtension)",
        isDirectory: false)

    episodeStates[episode.id] = .downloading(progress: 0)
    await downloadGate.acquire()
    if Task.isCancelled {
      episodeStates[episode.id] = .notDownloaded
      await downloadGate.release()
      return
    }
    guard case .downloading = episodeStates[episode.id] else {
      await downloadGate.release()
      return
    }
    await performDownload(
      episode, libraryFolder: libraryFolder, libraryKey: libraryKey,
      relativePath: relativePath, destination: destination, temporary: temporary)
    await downloadGate.release()
  }

  /// Called with `downloadGate` held. Keeping fetch, validation, publication,
  /// and the full-file metadata rewrite in one critical section prevents
  /// overlapping downloads from spending the same free-space snapshot.
  private func performDownload(
    _ episode: PodcastEpisode, libraryFolder: URL, libraryKey: String,
    relativePath: String, destination: URL, temporary: URL
  ) async {
    let episodeID = episode.id
    let session = urlSession
    let expectedBytes = episode.sizeBytes
    do {
      try await Self.fetchEnclosure(
        from: episode.enclosureURL, to: temporary, session: session,
        expectedBytes: expectedBytes, storageURL: libraryFolder,
        limits: resourceLimits
      ) { [weak self] progress in
        Task { @MainActor [weak self] in
          guard let self, case .downloading = self.episodeStates[episodeID] else { return }
          self.episodeStates[episodeID] = .downloading(progress: progress)
        }
      }
      try await Task.detached(priority: .utility) {
        try Self.validateDownloadedAudio(at: temporary)
      }.value
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: temporary, to: destination)
      // Tagging rewrites the whole audio file; keep it off the main actor
      // like LibraryStore does for the same writer.
      let author = feedAuthor(for: episode)
      try await Task.detached(priority: .utility) {
        do {
          try PodcastEpisodeTagger.tag(fileURL: destination, episode: episode, feedAuthor: author)
        } catch {
          try? FileManager.default.removeItem(at: destination)
          throw error
        }
      }.value
      // The library folder may have switched while the fetch and tagging
      // were in flight; never publish a file into the old library or
      // record it as downloaded.
      guard let (currentFolder, currentKey) = currentLibrary,
        Self.sameFolder(currentFolder, libraryFolder), currentKey == libraryKey
      else {
        try? FileManager.default.removeItem(at: temporary)
        try? FileManager.default.removeItem(at: destination)
        episodeStates[episode.id] = .notDownloaded
        return
      }
      downloadsCacheKey = nil  // re-read the sidecars in case another writer touched them
      downloadOwnersCacheKey = nil
      let recorded = setDownloadPath(
        relativePath, forEpisode: episode.id, in: libraryFolder, key: libraryKey)
      guard recorded else {
        try? FileManager.default.removeItem(at: destination)
        episodeStates[episode.id] = .failed(
          message: lastError ?? String(localized: "The podcast download could not be recorded."))
        return
      }
      if let feedURL = feedURL(for: episode) {
        setDownloadOwner(feedURL, forEpisode: episode.id, in: libraryFolder, key: libraryKey)
      }
      episodeStates[episode.id] = .downloaded(fileURL: destination)
      lastError = nil
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      if Self.isCancellation(error) {
        // A cancelled fetch (view dismissal, app teardown) is not a
        // failure: the episode simply remains not downloaded.
        episodeStates[episode.id] = .notDownloaded
        return
      }
      episodeStates[episode.id] = .failed(message: error.localizedDescription)
      lastError = error.localizedDescription
    }
  }

  @discardableResult
  func deleteDownload(_ episode: PodcastEpisode) -> Bool {
    // Only ever remove files — and mapping entries — belonging to the
    // current library folder: a stale .downloaded state may still point
    // into a previously active library.
    guard let (libraryFolder, libraryKey) = currentLibrary else {
      episodeStates[episode.id] = .notDownloaded
      return true
    }
    if let reason = downloadsRecordUnavailableReason(in: libraryFolder, key: libraryKey) {
      lastError = reason
      return false
    }
    let recordedFileURL = downloads(in: libraryFolder, key: libraryKey)[episode.id].flatMap {
      Self.downloadURL(forEpisode: episode.id, relativePath: $0, in: libraryFolder)
    }
    let stateFileURL: URL? = {
      guard case .downloaded(let fileURL) = episodeStates[episode.id],
        Self.isDownloadURL(fileURL, forEpisode: episode.id, under: libraryFolder)
      else { return nil }
      return fileURL
    }()
    return deleteDownload(
      episodeID: episode.id, fileURL: recordedFileURL ?? stateFileURL,
      in: libraryFolder, key: libraryKey)
  }

  /// Removes a verified current-library download without forgetting its
  /// record when the filesystem refuses the deletion.
  @discardableResult
  private func deleteDownload(
    episodeID: String, fileURL: URL?, in libraryFolder: URL, key libraryKey: String
  ) -> Bool {
    if let fileURL {
      do {
        try FileManager.default.removeItem(at: fileURL)
      } catch CocoaError.fileNoSuchFile {
        // A missing file is already deleted; finish removing its stale record.
      } catch {
        lastError = error.localizedDescription
        return false
      }
    }
    let forgotPath = setDownloadPath(
      nil, forEpisode: episodeID, in: libraryFolder, key: libraryKey)
    episodeStates[episodeID] = .notDownloaded
    if forgotPath {
      setDownloadOwner(nil, forEpisode: episodeID, in: libraryFolder, key: libraryKey)
    }
    return forgotPath
  }

  func localFileURL(for episode: PodcastEpisode) -> URL? {
    guard case .downloaded(let fileURL) = episodeStates[episode.id],
      let libraryFolder = libraryFolderProvider?(),
      Self.isDownloadURL(fileURL, forEpisode: episode.id, under: libraryFolder)
    else { return nil }
    return fileURL
  }

  // MARK: - Reconciliation

  private func reconcileEpisodeStates(for feed: PodcastFeed, feedURL: URL) {
    guard let (libraryFolder, libraryKey) = currentLibrary else { return }
    for episode in feed.episodes {
      if case .downloading = episodeStates[episode.id] { continue }
      guard let titledPath = Self.titledRelativePath(for: episode) else { continue }
      // The library's own download record wins so a publisher retitling the
      // show or an episode does not orphan the file that was downloaded
      // under the old titles.
      if let relativePath = downloads(in: libraryFolder, key: libraryKey)[episode.id] {
        if let mapped = Self.downloadURL(
          forEpisode: episode.id, relativePath: relativePath, in: libraryFolder),
          FileManager.default.fileExists(atPath: mapped.path)
        {
          episodeStates[episode.id] = .downloaded(fileURL: mapped)
          setDownloadOwner(
            feedURL, forEpisode: episode.id, in: libraryFolder, key: libraryKey)
          continue
        }
      }
      guard
        let expected = Self.downloadURL(
          forEpisode: episode.id, relativePath: titledPath, in: libraryFolder)
      else { continue }
      if FileManager.default.fileExists(atPath: expected.path) {
        episodeStates[episode.id] = .downloaded(fileURL: expected)
        // Repair the record opportunistically, but never write over a
        // damaged sidecar.
        if downloadsRecordUnavailableReason(in: libraryFolder, key: libraryKey) == nil,
          downloads(in: libraryFolder, key: libraryKey)[episode.id] != titledPath
        {
          if setDownloadPath(
            titledPath, forEpisode: episode.id, in: libraryFolder, key: libraryKey)
          {
            setDownloadOwner(
              feedURL, forEpisode: episode.id, in: libraryFolder, key: libraryKey)
          }
        }
      } else if case .downloaded = episodeStates[episode.id] {
        // Covers a deleted file and a stale state still pointing into a
        // previously active library folder.
        episodeStates[episode.id] = .notDownloaded
      }
    }
  }

  private func feedAuthor(for episode: PodcastEpisode) -> String? {
    for (feedURL, feed) in feeds
    where feed.episodes.contains(where: { $0.id == episode.id }) {
      return feed.author ?? subscriptions.first { $0.feedURL == feedURL }?.author
    }
    return nil
  }

  private func feedURL(for episode: PodcastEpisode) -> URL? {
    feeds.first { $0.value.episodes.contains(where: { $0.id == episode.id }) }?.key
  }

  // MARK: - Errors

  /// Cancellation (a dismissed view's `.task`, app teardown) is the caller
  /// changing its mind, not a failure worth surfacing to the user.
  private func recordError(_ error: Error) {
    guard !Self.isCancellation(error) else { return }
    lastError = error.localizedDescription
  }

  nonisolated private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  // MARK: - Networking

  /// Accumulates a small response with both an up-front Content-Length
  /// check and an independent streaming ceiling. The latter still applies
  /// to chunked, compressed, missing, or dishonest length declarations.
  nonisolated private static func fetch(
    _ url: URL, session: URLSession, maximumBytes: Int64
  ) async throws -> Data {
    let request = request(for: url, timeout: 30)
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    try validateHTTPStatus(response)
    let contentLength = try validatedContentLength(
      in: response, maximumBytes: maximumBytes)

    var data = Data()
    if let contentLength, contentLength > 0, contentLength <= Int64(Int.max) {
      data.reserveCapacity(Int(contentLength))
    }
    var buffer = [UInt8]()
    buffer.reserveCapacity(64 * 1_024)
    var received: Int64 = 0
    for try await byte in bytes {
      guard received < maximumBytes else {
        throw responseTooLarge(maximumBytes: maximumBytes)
      }
      buffer.append(byte)
      received += 1
      if buffer.count == buffer.capacity {
        data.append(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
      }
    }
    data.append(contentsOf: buffer)
    return data
  }

  /// XMLParser and all show-note normalization run outside the main actor.
  nonisolated private static func parseFeed(data: Data, feedURL: URL) async throws
    -> PodcastFeed
  {
    try await Task.detached(priority: .utility) {
      try PodcastFeedParser.parse(data: data, feedURL: feedURL)
    }.value
  }

  /// Streams an enclosure to a temporary file, reporting progress roughly
  /// every 256 KB. Runs off the main actor so byte iteration never blocks UI.
  nonisolated private static func fetchEnclosure(
    from url: URL, to temporaryURL: URL, session: URLSession,
    expectedBytes: Int64?, storageURL: URL, limits: PodcastResourceLimits,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    if let expectedBytes, expectedBytes > limits.maximumEnclosureBytes {
      throw responseTooLarge(maximumBytes: limits.maximumEnclosureBytes)
    }
    let request = request(for: url, timeout: 60)
    let (bytes, response) = try await session.bytes(for: request)
    defer { bytes.task.cancel() }
    try validateHTTPStatus(response)
    if let mimeType = response.mimeType?.lowercased(), mimeType.hasPrefix("text/") {
      throw PodcastFeedError(
        reason: String(localized: "The server returned \(mimeType) instead of an audio file."))
    }
    let contentLength = try validatedContentLength(
      in: response, maximumBytes: limits.maximumEnclosureBytes)
    let totalBytes: Int64? = {
      if let contentLength, contentLength > 0 { return contentLength }
      if let expectedBytes, expectedBytes > 0 { return expectedBytes }
      return nil
    }()
    let diskBudget = try writableByteBudget(
      at: storageURL, preserving: limits.minimumFreeDiskBytes)
    // Tagging atomically rewrites the entire downloaded file. Budget for
    // both copies at once so the configured headroom remains intact during
    // that rewrite, not merely after it completes.
    let enclosureDiskBudget = diskBudget / 2
    if let totalBytes, totalBytes > enclosureDiskBudget {
      throw insufficientDiskSpace(reserveBytes: limits.minimumFreeDiskBytes)
    }
    let transferBudget = min(limits.maximumEnclosureBytes, enclosureDiskBudget)

    try FileManager.default.createDirectory(
      at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: temporaryURL)
    do {
      var buffer = [UInt8]()
      buffer.reserveCapacity(Int(progressUpdateByteStride))
      var written: Int64 = 0
      var nextProgressUpdate = progressUpdateByteStride
      for try await byte in bytes {
        guard written + Int64(buffer.count) < limits.maximumEnclosureBytes else {
          throw responseTooLarge(maximumBytes: limits.maximumEnclosureBytes)
        }
        guard written + Int64(buffer.count) < transferBudget else {
          throw insufficientDiskSpace(reserveBytes: limits.minimumFreeDiskBytes)
        }
        buffer.append(byte)
        if buffer.count >= Int(progressUpdateByteStride) {
          try handle.write(contentsOf: buffer)
          written += Int64(buffer.count)
          buffer.removeAll(keepingCapacity: true)
          if written >= nextProgressUpdate {
            nextProgressUpdate = written + progressUpdateByteStride
            if let totalBytes {
              progress(min(1, Double(written) / Double(totalBytes)))
            } else {
              progress(0)
            }
          }
        }
      }
      if !buffer.isEmpty {
        try handle.write(contentsOf: buffer)
      }
      try handle.close()
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  nonisolated private static func request(for url: URL, timeout: TimeInterval) -> URLRequest {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    return request
  }

  nonisolated private static func validateHTTPStatus(_ response: URLResponse) throws {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw PodcastFeedError(
        reason: String(localized: "The server answered with HTTP \(http.statusCode)."))
    }
  }

  /// Returns a trustworthy non-negative response length when one is
  /// declared. A malformed HTTP header is rejected; a missing header is
  /// allowed because the streaming byte ceiling remains authoritative.
  nonisolated static func validatedContentLength(
    in response: URLResponse, maximumBytes: Int64
  ) throws -> Int64? {
    var declaredLength: Int64?
    if let http = response as? HTTPURLResponse,
      let rawValue = http.value(forHTTPHeaderField: "Content-Length")
    {
      let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let parsed = Int64(value)
      else {
        throw PodcastFeedError(
          reason: String(localized: "The server returned an invalid Content-Length."))
      }
      declaredLength = parsed
    }

    let expectedLength = response.expectedContentLength
    if expectedLength >= 0 {
      if expectedLength > maximumBytes {
        throw responseTooLarge(maximumBytes: maximumBytes)
      }
      declaredLength = declaredLength ?? expectedLength
    }
    if let declaredLength, declaredLength > maximumBytes {
      throw responseTooLarge(maximumBytes: maximumBytes)
    }
    return declaredLength
  }

  nonisolated private static func writableByteBudget(
    at storageURL: URL, preserving reserveBytes: Int64
  ) throws -> Int64 {
    let available: Int64
    do {
      guard
        let capacity = try storageURL.resourceValues(
          forKeys: [.volumeAvailableCapacityKey]
        ).volumeAvailableCapacity
      else {
        throw PodcastFeedError(
          reason: String(localized: "The library volume did not report its available space."))
      }
      available = Int64(capacity)
    } catch let error as PodcastFeedError {
      throw error
    } catch {
      throw PodcastFeedError(
        reason: String(
          localized: "The library volume's available space could not be checked."))
    }
    guard available > reserveBytes else {
      throw insufficientDiskSpace(reserveBytes: reserveBytes)
    }
    return available - reserveBytes
  }

  nonisolated private static func responseTooLarge(maximumBytes: Int64) -> PodcastFeedError {
    PodcastFeedError(
      reason: String(
        localized:
          "The podcast response exceeds Nightdrive's \(formattedByteCount(maximumBytes)) limit."))
  }

  nonisolated private static func insufficientDiskSpace(reserveBytes: Int64) -> PodcastFeedError {
    PodcastFeedError(
      reason: String(
        localized:
          "There is not enough free space to download this episode while preserving \(formattedByteCount(reserveBytes)) of disk headroom."
      ))
  }

  nonisolated private static func formattedByteCount(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  nonisolated private static func validateDownloadedAudio(at url: URL) throws {
    if url.pathExtension.lowercased() == "mp3" {
      guard
        MP3DurationValidator.inspect(
          url: url, assetSeconds: nil, decoderSeconds: nil) != nil
      else {
        throw PodcastFeedError(
          reason: String(localized: "The downloaded file could not be decoded as audio."))
      }
      return
    }
    do {
      let audio = try AVAudioFile(forReading: url)
      let sampleRate = audio.fileFormat.sampleRate
      guard audio.length > 0, sampleRate.isFinite, sampleRate > 0 else {
        throw PodcastFeedError(
          reason: String(localized: "The downloaded file does not contain playable audio."))
      }
    } catch let error as PodcastFeedError {
      throw error
    } catch {
      throw PodcastFeedError(
        reason: String(localized: "The downloaded file could not be decoded as audio."))
    }
  }

  // MARK: - Library scoping

  nonisolated private static func sameFolder(_ first: URL, _ second: URL) -> Bool {
    first.standardizedFileURL.path == second.standardizedFileURL.path
  }

  nonisolated private static func isFileURL(_ fileURL: URL, under folder: URL) -> Bool {
    PathContainment.path(
      fileURL.canonicalFileURL.path, isInside: folder.canonicalFileURL.path, allowRoot: false)
  }

  nonisolated private static func isDownloadURL(
    _ fileURL: URL, forEpisode episodeID: String, under folder: URL
  ) -> Bool {
    isFileURL(fileURL, under: folder)
      && fileURL.deletingPathExtension().lastPathComponent.contains(
        "[\(PodcastFileNaming.fingerprint(episodeID))]")
  }

  nonisolated private static func downloadURL(
    forEpisode episodeID: String, relativePath: String, in folder: URL
  ) -> URL? {
    guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
    let url = folder.appendingPathComponent(relativePath, isDirectory: false)
    return isDownloadURL(url, forEpisode: episodeID, under: folder) ? url : nil
  }

  nonisolated private static func saveDownloads(
    _ mapping: [String: String], in folder: URL
  ) throws {
    try FileDataPersistence(
      fileURL: PodcastDownloadsFile.url(for: folder), createsParentDirectories: false
    ).save(mapping)
  }

  nonisolated private static func saveDownloadOwners(
    _ owners: [String: String], in folder: URL
  ) throws {
    try FileDataPersistence(
      fileURL: PodcastDownloadOwnersFile.url(for: folder), createsParentDirectories: false
    ).save(owners)
  }

  // MARK: - Persistence

  /// App-level persisted state: the subscription list. Download records are
  /// per-library and live in each library's sidecar (`PodcastDownloadsFile`).
  private struct PersistedState: Codable {
    var subscriptions: [PodcastSubscription] = []
  }

  private func loadState() {
    do {
      guard let stored = try persistence.load(PersistedState.self) else { return }
      subscriptions = stored.subscriptions.sorted {
        $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
      }
    } catch {
      // App-level state that fails to decode starts fresh: surfacing a
      // banner for it would only alarm the user about data the app itself
      // wrote in an older shape.
      NightdriveLog.app.error(
        "Saved podcast subscriptions could not be decoded; starting fresh: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func saveState() {
    do {
      try persistence.save(PersistedState(subscriptions: subscriptions))
    } catch {
      lastError = error.localizedDescription
    }
  }
}

/// The episode-id → library-relative-path record of a library's podcast
/// downloads, stored inside the library folder like the playlists and
/// listening-history sidecars.
enum PodcastDownloadsFile {
  static let filename = ".nightdrive-podcast-downloads.json"

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }
}

/// Exact episode-id → feed-URL ownership for safe pruning when a rolling
/// feed no longer contains an older downloaded episode.
enum PodcastDownloadOwnersFile {
  static let filename = ".nightdrive-podcast-download-owners.json"

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }
}
