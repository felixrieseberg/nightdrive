import Foundation

struct PodcastBookmarkRecoveryState: Codable, Equatable, Sendable {
  let libraryIdentity: LibraryResourceIdentity
  var bookmarks: [String: Int]
}

struct PlaybackPersistenceState: Codable, Equatable, Sendable {
  var queueURLs: [URL]
  var currentURL: URL?
  var position: TimeInterval
  var volume: Float
  var shuffleEnabled: Bool
  var repeatMode: PlaybackRepeatMode
  var isMuted: Bool
  var equalizerPreset: EqualizerPreset
  var podcastBookmarkRecovery: PodcastBookmarkRecoveryState?

  init(
    queueURLs: [URL],
    currentURL: URL?,
    position: TimeInterval,
    volume: Float,
    shuffleEnabled: Bool,
    repeatMode: PlaybackRepeatMode,
    isMuted: Bool = false,
    equalizerPreset: EqualizerPreset = .flat,
    podcastBookmarkRecovery: PodcastBookmarkRecoveryState? = nil
  ) {
    self.queueURLs = queueURLs
    self.currentURL = currentURL
    self.position = position
    self.volume = volume
    self.shuffleEnabled = shuffleEnabled
    self.repeatMode = repeatMode
    self.isMuted = isMuted
    self.equalizerPreset = equalizerPreset
    self.podcastBookmarkRecovery = podcastBookmarkRecovery
  }

  private enum CodingKeys: String, CodingKey {
    case queueURLs
    case currentURL
    case position
    case volume
    case shuffleEnabled
    case repeatMode
    case isMuted
    case equalizerPreset
    case podcastBookmarkRecovery
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    queueURLs = try container.decode([URL].self, forKey: .queueURLs)
    currentURL = try container.decodeIfPresent(URL.self, forKey: .currentURL)
    position = try container.decode(TimeInterval.self, forKey: .position)
    volume = try container.decode(Float.self, forKey: .volume)
    shuffleEnabled = try container.decode(Bool.self, forKey: .shuffleEnabled)
    repeatMode = try container.decode(PlaybackRepeatMode.self, forKey: .repeatMode)
    isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
    equalizerPreset =
      try container.decodeIfPresent(EqualizerPreset.self, forKey: .equalizerPreset) ?? .flat
    podcastBookmarkRecovery = try container.decodeIfPresent(
      PodcastBookmarkRecoveryState.self, forKey: .podcastBookmarkRecovery)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(queueURLs, forKey: .queueURLs)
    try container.encodeIfPresent(currentURL, forKey: .currentURL)
    try container.encode(position, forKey: .position)
    try container.encode(volume, forKey: .volume)
    try container.encode(shuffleEnabled, forKey: .shuffleEnabled)
    try container.encode(repeatMode, forKey: .repeatMode)
    try container.encode(isMuted, forKey: .isMuted)
    try container.encode(equalizerPreset, forKey: .equalizerPreset)
    try container.encodeIfPresent(podcastBookmarkRecovery, forKey: .podcastBookmarkRecovery)
  }
}

struct PlaybackPersistenceStore: Sendable {
  static let pathEnvironmentKey = "NIGHTDRIVE_PLAYBACK_STATE_PATH"

  private let persistence: any RemovableAppDataPersistence

  init(fileURL: URL = Self.defaultURL()) {
    self.persistence = FileDataPersistence(fileURL: fileURL)
  }

  init(persistence: any RemovableAppDataPersistence) {
    self.persistence = persistence
  }

  static func defaultURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    if let override = environment[pathEnvironmentKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return URL(fileURLWithPath: override)
    }
    return
      NightdriveAppData.directoryURL(environment: environment, fileManager: fileManager)
      .appendingPathComponent("playback-state.json", isDirectory: false)
  }

  func load() throws -> PlaybackPersistenceState? {
    try persistence.load(PlaybackPersistenceState.self)
  }

  func save(_ state: PlaybackPersistenceState) throws {
    try persistence.save(state)
  }

  func clear() throws {
    try persistence.remove()
  }
}

/// Debounces playback-state writes so scrubbing and ticking don't hammer
/// the disk, keyed by caller-assigned revisions so stale submissions lose.
private actor PlaybackPersistenceDebouncer {
  private let store: PlaybackPersistenceStore
  private let delay: Duration
  private var latestRevision = 0
  private var lastPersistedState: PlaybackPersistenceState?
  private var pendingState: PlaybackPersistenceState?
  private var delayedSave: Task<Void, Never>?

  init(
    store: PlaybackPersistenceStore,
    initialState: PlaybackPersistenceState?,
    delay: Duration = .seconds(5)
  ) {
    self.store = store
    self.delay = delay
    self.lastPersistedState = initialState
  }

  func schedule(_ state: PlaybackPersistenceState, revision: Int) {
    guard revision > latestRevision else { return }
    latestRevision = revision
    if state == lastPersistedState {
      pendingState = nil
      delayedSave?.cancel()
      delayedSave = nil
      return
    }
    pendingState = state
    guard delayedSave == nil else { return }
    let delay = self.delay
    delayedSave = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.persistPendingState()
    }
  }

  func flush(_ state: PlaybackPersistenceState, revision: Int) {
    guard revision >= latestRevision else { return }
    latestRevision = revision
    pendingState = state == lastPersistedState ? nil : state
    delayedSave?.cancel()
    delayedSave = nil
    persistPendingState()
  }

  func waitForScheduledSave() async {
    let save = delayedSave
    await save?.value
  }

  private func persistPendingState() {
    delayedSave = nil
    guard let state = pendingState else { return }
    do {
      try store.save(state)
      lastPersistedState = state
      pendingState = nil
    } catch {
      // Keep pendingState so the next flush retries, but record the failure:
      // playback position and queue restore silently break if this persists.
      NightdriveLog.app.error(
        "Saving playback state failed; will retry on the next flush: \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

/// Owns the playback-persistence pipeline: the periodic integration timer,
/// change detection against the last submitted state, revision stamping, and
/// the debounced writer behind them.
@MainActor
final class PlaybackPersistenceCoordinator {
  private let debouncer: PlaybackPersistenceDebouncer
  private var integrationTimer: Timer?
  private var persistenceTick = 0
  private var persistenceRevision = 0
  private var lastSubmittedState: PlaybackPersistenceState?
  private var currentState: (@MainActor () -> PlaybackPersistenceState?)?

  nonisolated init(
    store: PlaybackPersistenceStore,
    initialState: PlaybackPersistenceState?,
    delay: Duration = .seconds(5)
  ) {
    self.debouncer = PlaybackPersistenceDebouncer(
      store: store, initialState: initialState, delay: delay)
  }

  func schedule(_ state: PlaybackPersistenceState, revision: Int) async {
    await debouncer.schedule(state, revision: revision)
  }

  func flush(_ state: PlaybackPersistenceState, revision: Int) async {
    await debouncer.flush(state, revision: revision)
  }

  func waitForScheduledSave() async {
    await debouncer.waitForScheduledSave()
  }

  /// Starts the half-second integration timer. `onTick` runs every tick;
  /// the current playback state is persisted every fourth tick.
  func startIntegrations(
    currentState: @escaping @MainActor () -> PlaybackPersistenceState?,
    onTick: @escaping @MainActor () -> Void
  ) {
    self.currentState = currentState
    guard integrationTimer == nil else { return }
    integrationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
      [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        onTick()
        self.persistenceTick += 1
        if self.persistenceTick.isMultiple(of: 4) {
          self.save()
        }
      }
    }
  }

  func save() {
    save(currentState?())
  }

  /// Explicit saves pass the state directly so they work before
  /// `startIntegrations` installs the state provider.
  func save(_ state: PlaybackPersistenceState?) {
    guard let submission = submission(for: state) else { return }
    let debouncer = self.debouncer
    Task {
      await debouncer.schedule(submission.state, revision: submission.revision)
    }
  }

  func flush(_ state: PlaybackPersistenceState?) async {
    guard let submission = submission(for: state, force: true) else { return }
    await debouncer.flush(submission.state, revision: submission.revision)
  }

  private func submission(
    for state: PlaybackPersistenceState?, force: Bool = false
  ) -> (
    state: PlaybackPersistenceState, revision: Int
  )? {
    guard let state else { return nil }
    guard force || state != lastSubmittedState else { return nil }
    lastSubmittedState = state
    persistenceRevision += 1
    return (state, persistenceRevision)
  }
}
