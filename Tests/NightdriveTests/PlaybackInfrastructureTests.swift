import AppKit
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.serialized)
struct PlaybackInfrastructureTests {
  private final class MemoryStorage: RemovableAppDataPersistence, Sendable {
    private struct State {
      var data: Data?
      var writeCount = 0
    }

    private let state = Mutex(State())

    var data: Data? {
      get { state.withLock { $0.data } }
      set { state.withLock { $0.data = newValue } }
    }

    var writes: Int {
      state.withLock { $0.writeCount }
    }

    func resetWrites() {
      state.withLock { $0.writeCount = 0 }
    }

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
      state.withLock { state in
        state.data = data
        state.writeCount += 1
      }
    }

    func remove() throws {
      state.withLock { state in
        state.data = nil
        state.writeCount += 1
      }
    }
  }

  private actor MetadataLoadProbe {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var completionOrder: [URL] = []

    func load(_ url: URL) async -> LibraryTrack {
      active += 1
      peak = max(peak, active)
      let delay: Duration
      switch url.lastPathComponent {
      case let name where name.hasPrefix("slow"): delay = .milliseconds(60)
      case let name where name.hasPrefix("medium"): delay = .milliseconds(20)
      default: delay = .milliseconds(5)
      }
      try? await Task.sleep(for: delay)
      completionOrder.append(url)
      active -= 1
      return LibraryTrack(
        url: url, title: url.deletingPathExtension().lastPathComponent, artist: "Artist", album: "Album",
        genre: "Genre", durationMS: 1_000, sizeBytes: 1_000, bitrate: 128, samplerate: 44_100)
    }
  }

  @Test
  func testSnapshotDefaultsSuiteIsIsolatedFromStandardPreferences() throws {
    let suite = "dev.nightdrive.tests.snapshot-defaults.\(UUID().uuidString)"
    let key = "snapshot-isolation-\(UUID().uuidString)"
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let isolated = NightdriveDefaults.resolve(environment: [
      NightdriveDefaults.suiteEnvironmentKey: suite
    ])
    isolated.set("tour", forKey: key)

    #expect(isolated.string(forKey: key) == "tour")
    #expect(UserDefaults.standard.string(forKey: key) == nil)
  }

  @Test
  func testAudioDiscoveryIncludesLocallyPlayableFormatsAndSkipsOtherFiles() throws {
    let root = TestScratch.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    for name in ["one.mp3", "two.M4A", "three.flac", "four.caf", "notes.txt", ".hidden.wav"] {
      try Data().write(to: root.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("not-a-song.mp3", isDirectory: true),
      withIntermediateDirectories: false)
    let outside = root.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString).mp3")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data().write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escaped.mp3"), withDestinationURL: outside)

    #expect(
      LibraryStore.findAudioFiles(in: root).map(\.lastPathComponent) == [
        "four.caf", "one.mp3", "three.flac", "two.M4A",
      ])
  }

  @Test
  func testMetadataLoadingIsBoundedConcurrentAndPreservesDiscoveryOrder() async {
    let urls = [
      "slow-0.mp3", "fast-1.m4a", "medium-2.wav", "fast-3.aif",
      "slow-4.flac", "fast-5.caf", "medium-6.aac", "fast-7.m4b",
    ].map { URL(fileURLWithPath: "/Music/\($0)") }
    let probe = MetadataLoadProbe()

    let tracks = await LibraryStore.loadTracks(
      at: urls, maximumConcurrentTasks: 3,
      loader: { await probe.load($0) })
    let peak = await probe.peak
    let completionOrder = await probe.completionOrder

    #expect(tracks.map(\.url) == urls)
    #expect(peak == 3)
    #expect(completionOrder != urls)
  }

  @Test
  func testDeviceCompatibilityIsSeparateFromLocalFormatSupport() {
    let compatible = makeTrack(extension: "m4a")
    let audiobook = makeTrack(extension: "m4b")
    let rawAAC = makeTrack(extension: "aac")
    let localOnly = makeTrack(extension: "flac")

    #expect(compatible.audioFormat == .m4a)
    #expect(compatible.deviceDelivery(for: .thirdGenerationOrLater) == .direct)
    #expect(audiobook.deviceDelivery(for: .thirdGenerationOrLater) == .direct)
    #expect(localOnly.audioFormat == .flac)
    let settings = TranscodeSettings()
    #expect(rawAAC.deviceDelivery(for: .thirdGenerationOrLater) == .transcode(to: settings.aacProfile))
    #expect(localOnly.deviceDelivery(for: .thirdGenerationOrLater) == .transcode(to: settings.aacProfile))
    guard case .unsupported(let reason) = localOnly.deviceDelivery(for: .firstOrSecondGeneration)
    else {
      Issue.record("Expected a clear incompatibility reason")
      return
    }
    #expect(reason.contains("MP3"))
  }

  @Test
  func testPlaybackStateRoundTripsThroughInjectedStorage() throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let first = URL(fileURLWithPath: "/Music/First Song.mp3")
    let state = PlaybackPersistenceState(
      queueURLs: [first, URL(fileURLWithPath: "/Music/Second.m4a")],
      currentURL: first,
      position: 42.5,
      volume: 0.65,
      shuffleEnabled: true,
      repeatMode: .all,
      isMuted: true,
      equalizerPreset: .bassBoost,
      podcastBookmarkRecovery: PodcastBookmarkRecoveryState(
        libraryIdentity: LibraryResourceIdentity(volumeID: 7, resourceID: 11),
        bookmarks: [TrackID(url: first).rawValue: 12_500]))

    try store.save(state)

    #expect(try store.load() == state)
    try store.clear()
    #expect(try store.load() == nil)
  }

  @Test
  func testPlaybackStateWithoutPodcastRecoveryBookmarksStillDecodes() throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let state = PlaybackPersistenceState(
      queueURLs: [], currentURL: nil, position: 0, volume: 1,
      shuffleEnabled: false, repeatMode: .off)
    try store.save(state)
    let encoded = try #require(storage.data)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "podcastBookmarkRecovery")
    storage.data = try JSONSerialization.data(withJSONObject: object)

    let loaded = try store.load()
    let restored = try #require(loaded)

    #expect(restored.podcastBookmarkRecovery == nil)
  }

  @Test
  func testPlaybackCoordinatorSkipsNoOpState() async throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let state = PlaybackPersistenceState(
      queueURLs: [], currentURL: nil, position: 0, volume: 0.75,
      shuffleEnabled: false, repeatMode: .off)
    try store.save(state)
    storage.resetWrites()

    let coordinator = PlaybackPersistenceCoordinator(
      store: store, initialState: state, delay: .seconds(60))
    await coordinator.schedule(state, revision: 1)
    await coordinator.flush(state, revision: 2)

    #expect(storage.writes == 0)
  }

  @Test
  func testPlaybackCoordinatorCoalescesWrites() async throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let first = PlaybackPersistenceState(
      queueURLs: [], currentURL: nil, position: 1, volume: 1,
      shuffleEnabled: false, repeatMode: .off)
    var latest = first
    latest.position = 9
    latest.isMuted = true
    let coordinator = PlaybackPersistenceCoordinator(
      store: store, initialState: nil, delay: .seconds(1))

    await coordinator.schedule(first, revision: 1)
    await coordinator.schedule(latest, revision: 2)
    await coordinator.waitForScheduledSave()

    #expect(storage.writes == 1)
    #expect(try store.load() == latest)
  }

  @MainActor
  @Test
  func testPlaybackCoordinatorExplicitFlushWorksBeforeIntegrationsStart() async throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let state = PlaybackPersistenceState(
      queueURLs: [], currentURL: nil, position: 7, volume: 0.5,
      shuffleEnabled: false, repeatMode: .off)
    let coordinator = PlaybackPersistenceCoordinator(
      store: store, initialState: nil, delay: .seconds(60))

    // No startIntegrations call: the state provider is not installed yet.
    await coordinator.flush(state)

    #expect(storage.writes == 1)
    #expect(try store.load() == state)
  }

  @Test
  func testPlaybackCoordinatorLifecycleFlushRejectsStaleSubmissions() async throws {
    let storage = MemoryStorage()
    let store = PlaybackPersistenceStore(persistence: storage)
    let stale = PlaybackPersistenceState(
      queueURLs: [], currentURL: nil, position: 1, volume: 1,
      shuffleEnabled: false, repeatMode: .off)
    var latest = stale
    latest.position = 9
    let coordinator = PlaybackPersistenceCoordinator(
      store: store, initialState: nil, delay: .seconds(60))

    await coordinator.schedule(stale, revision: 1)
    await coordinator.flush(latest, revision: 2)
    await coordinator.schedule(stale, revision: 1)

    #expect(storage.writes == 1)
    #expect(try store.load() == latest)
  }

  @MainActor
  @Test
  func testApplicationTerminationWaitsForPlaybackFlushBeforeReplying() async throws {
    var didFlush = false
    var replies: [Bool] = []
    let delegate = NightdriveApplicationDelegate { _, shouldTerminate in
      replies.append(shouldTerminate)
    }
    let allowFlush = TestGate()
    delegate.flushPlaybackState = {
      await allowFlush.wait()
      didFlush = true
    }

    let response = delegate.applicationShouldTerminate(NSApplication.shared)

    #expect(response == .terminateLater)
    #expect(!(didFlush))
    #expect(replies.isEmpty)
    await allowFlush.signal()
    await waitUntil(timeout: .seconds(1)) { !replies.isEmpty }
    #expect(didFlush)
    #expect(replies == [true])
  }

  @MainActor
  @Test
  func testApplicationDelegateBuffersOpenRequestsUntilTheAppIsReady() {
    let delegate = NightdriveApplicationDelegate { _, _ in }
    let first = URL(fileURLWithPath: "/Music/First.mp3")
    let second = URL(fileURLWithPath: "/Music/Second.m4a")
    var delivered: [[URL]] = []

    delegate.application(NSApplication.shared, open: [first, second])
    #expect(delivered.isEmpty)

    delegate.openAudioFiles = { delivered.append($0) }
    #expect(delivered == [[first, second]])

    delegate.application(NSApplication.shared, open: [second])
    #expect(delivered == [[first, second], [second]])
  }

  @MainActor
  @Test
  func testDefaultAudioAppOfferIsOnceOnly() {
    let suite = "DefaultAudioAppOffer-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let appURL = URL(fileURLWithPath: "/Applications/Nightdrive.app")
    let controller = DefaultAudioAppController(
      operations: DefaultAudioAppOperations(
        applicationURL: appURL,
        defaultApplicationURL: { _ in URL(fileURLWithPath: "/Applications/Music.app") },
        setDefaultApplication: { _, _ in }),
      defaults: defaults)

    controller.offerAtLaunchIfNeeded()
    #expect(controller.isPromptPresented)
    #expect(!(defaults.bool(forKey: "offeredDefaultAudioApp")))
    controller.declinePrompt()
    #expect(defaults.bool(forKey: "offeredDefaultAudioApp"))
    controller.offerAtLaunchIfNeeded()
    #expect(!(controller.isPromptPresented))
  }

  @MainActor
  @Test
  func testDefaultAudioAppOfferSkipsAnExistingDefault() {
    let suite = "DefaultAudioAppExisting-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let appURL = URL(fileURLWithPath: "/Applications/Nightdrive.app")
    let controller = DefaultAudioAppController(
      operations: DefaultAudioAppOperations(
        applicationURL: appURL,
        defaultApplicationURL: { _ in URL(fileURLWithPath: "/applications/nightdrive.app") },
        setDefaultApplication: { _, _ in }),
      defaults: defaults)

    controller.offerAtLaunchIfNeeded()

    #expect(!(controller.isPromptPresented))
    #expect(defaults.bool(forKey: "offeredDefaultAudioApp"))
  }

  @MainActor
  @Test
  func testDefaultAudioAppClaimsMissingTypesAndReportsPartialFailure() async {
    let suite = "DefaultAudioAppClaim-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let appURL = URL(fileURLWithPath: "/Applications/Nightdrive.app")
    let existingType = AudioFileOpening.contentTypes[0]
    var defaultsByType = [existingType.identifier: appURL]
    var attempted: [String] = []
    let controller = DefaultAudioAppController(
      operations: DefaultAudioAppOperations(
        applicationURL: appURL,
        defaultApplicationURL: { defaultsByType[$0.identifier] },
        setDefaultApplication: { _, type in
          attempted.append(type.identifier)
          if attempted.count == 2 {
            throw NSError(
              domain: "DefaultAudioAppTests", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "The default app change was declined."])
          }
          defaultsByType[type.identifier] = appURL
        }),
      defaults: defaults)

    #expect(controller.status == .some)
    let failure = await controller.makeDefault()

    #expect(!(attempted.contains(existingType.identifier)))
    #expect(attempted.count == AudioFileOpening.contentTypes.count - 1)
    #expect(controller.status == .some)
    #expect(failure?.changedCount == AudioFileOpening.contentTypes.count - 2)
    #expect(failure?.failedCount == 1)
    #expect(failure?.underlyingDescription == "The default app change was declined.")
  }

  @MainActor
  @Test
  func testAudioFileOpeningUsesCatalogTracksAndLoadsExternalFilesInOrder() async throws {
    let root = TestScratch.directory()
    let externalRoot = TestScratch.directory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalRoot)
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    let libraryURL = root.appendingPathComponent("Library Song.mp3")
    let externalURL = externalRoot.appendingPathComponent("External Song.mp3")
    try writeTestSong(title: "Catalog Title", to: libraryURL)
    try writeTestSong(title: "External Title", to: externalURL)

    let library = LibraryStore(folderURL: root)
    await library.rescan()
    let tracks = await AudioFileOpening.resolveTracks(
      [externalURL, libraryURL, externalURL, externalRoot.appendingPathComponent("Notes.txt")],
      library: library)

    #expect(tracks.map(\.title) == ["External Title", "Catalog Title"])
    #expect(tracks[0].url == externalURL)
    #expect(tracks[1] == library.track(at: libraryURL))
  }

  @Test
  func testDroppedFoldersExpandInOrderDeduplicateAndRejectNestedSymlinks() throws {
    let root = TestScratch.directory()
    let externalRoot = TestScratch.directory()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: externalRoot)
    }
    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    let a = root.appendingPathComponent("a.mp3")
    let b = nested.appendingPathComponent("b.wav")
    let first = externalRoot.appendingPathComponent("first.flac")
    for url in [a, b, first] { try Data().write(to: url) }
    try Data().write(to: root.appendingPathComponent("notes.txt"))
    try Data().write(to: root.appendingPathComponent(".hidden.m4a"))
    try FileManager.default.createSymbolicLink(
      at: nested.appendingPathComponent("escaped.mp3"), withDestinationURL: first)
    let rootLink = externalRoot.appendingPathComponent("root-link")
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: root)

    let expanded = AudioFileOpening.eligibleDropURLs([
      first, rootLink, a, URL(string: "https://example.com/not-local.mp3")!,
    ])

    #expect(expanded == [first, a, b].map { $0.resolvingSymlinksInPath().standardizedFileURL })
  }

  @Test
  func testDropAcceptanceRejectsUnsupportedAndMissingItemsButAcceptsFolders() throws {
    let root = TestScratch.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let notes = root.appendingPathComponent("notes.txt")
    let audio = root.appendingPathComponent("song.mp3")
    try Data().write(to: notes)
    try Data().write(to: audio)

    #expect(!AudioFileOpening.canAcceptDrop([notes]))
    #expect(!AudioFileOpening.canAcceptDrop([root.appendingPathComponent("missing.mp3")]))
    #expect(!AudioFileOpening.canAcceptDrop([URL(string: "https://example.com/song.mp3")!]))
    #expect(AudioFileOpening.canAcceptDrop([audio]))
    #expect(AudioFileOpening.canAcceptDrop([root]))
  }

  @MainActor
  @Test
  func testDroppedFolderCanBeEnqueuedWithoutStartingPlayback() async throws {
    let libraryRoot = TestScratch.directory()
    let droppedRoot = TestScratch.directory()
    defer {
      try? FileManager.default.removeItem(at: libraryRoot)
      try? FileManager.default.removeItem(at: droppedRoot)
    }
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: droppedRoot, withIntermediateDirectories: true)
    try writeTestSong(title: "Second", to: droppedRoot.appendingPathComponent("02.mp3"))
    try writeTestSong(title: "First", to: droppedRoot.appendingPathComponent("01.mp3"))
    let app = AppState(library: LibraryStore(folderURL: libraryRoot))

    await app.enqueueDroppedAudioFiles([droppedRoot])

    #expect(app.player.currentTrack == nil)
    #expect(app.player.upNextTracks.map(\.title) == ["First", "Second"])
  }

  @MainActor
  @Test
  func testPersistedPlaybackPositionIsClampedBeforeIntegerConversion() {
    #expect(PlayerController.restoredFrame(position: 1e300, sampleRate: 44_100, length: 88_200) == 88_199)
    #expect(PlayerController.restoredFrame(position: -12, sampleRate: 44_100, length: 88_200) == 0)
    #expect(PlayerController.restoredFrame(position: .infinity, sampleRate: 44_100, length: 88_200) == 0)
    #expect(PlayerController.restoredFrame(position: 0.5, sampleRate: 44_100, length: 88_200) == 22_050)
  }

  private func makeTrack(extension ext: String) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: "/Music/Track.\(ext)"), title: "Track",
      artist: "", album: "", sizeBytes: 1, bitrate: 0)
  }
}
