import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct AppStateOperationOwnershipTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  @MainActor
  @Test
  func testSettingsFailureCannotReleaseSyncOwnerOrAdmitSecondSync() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())
    let second = try makeSecondDevice()
    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = makeApp(library: library) { _, _, _ in
      throw CocoaError(.fileWriteNoPermission)
    }
    let first = makeDevice(volume: ipodDir, databaseID: try fs.readDatabase().databaseID)
    let replacementLibrary = scratch.appendingPathComponent("replacement-library", isDirectory: true)
    try FileManager.default.createDirectory(
      at: replacementLibrary, withIntermediateDirectories: true)

    let deviceLock = try await ScopedAdvisoryLock.acquire(for: ipodDir, namespace: .device)
    defer { deviceLock.unlock() }
    app.sync(first)
    #expect(app.isDeviceOperationActive)

    app.setDisplayName("Primary iPod", for: first)
    await app.flushSyncSettingsWrites()

    #expect(app.syncSettingsError != nil)
    #expect(app.isDeviceOperationActive)
    guard case .syncing = app.syncState else {
      Issue.record("a settings error replaced the active sync presentation")
      return
    }
    #expect(!(app.setLibraryFolder(replacementLibrary)))
    #expect((app.library.folderURL) == (libraryDir.standardizedFileURL))

    app.sync(second.device)
    #expect(app.isDeviceOperationActive)
    deviceLock.unlock()
    try await waitUntilOperationEnds(app)

    #expect((try fs.readDatabase().tracks.count) == (1))
    #expect((try second.fileSystem.readDatabase().tracks.count) == (0))
    #expect(app.syncSettingsError != nil)
    guard case .finished = app.syncState else {
      Issue.record("the owned sync did not publish its terminal result")
      return
    }
  }

  @MainActor
  @Test
  func testMalformedLedgerOffersAbortOrQuarantinedEmptyResetWithoutAutoRetry() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())
    let corrupt = Data("not json".utf8)
    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    try corrupt.write(to: ledgerURL)
    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = makeApp(library: library)
    let device = makeDevice(volume: ipodDir, databaseID: try fs.readDatabase().databaseID)

    app.sync(device)
    try await waitUntilOperationEnds(app)

    #expect(app.syncLedgerRecoveryPrompt != nil)
    #expect(app.isSyncLedgerRecoveryPromptPresented)
    #expect((try Data(contentsOf: ledgerURL)) == (corrupt))
    #expect((try fs.readDatabase().tracks.count) == (0))

    app.dismissSyncLedgerRecoveryPromptPresentation()
    #expect(!(app.isSyncLedgerRecoveryPromptPresented))
    #expect(app.canShowSyncErrorDetails)
    app.showSyncErrorDetails()
    #expect(app.isSyncLedgerRecoveryPromptPresented)

    app.abortSyncLedgerRecovery()
    #expect(app.syncLedgerRecoveryPrompt == nil)
    #expect(!(app.isSyncLedgerRecoveryPromptPresented))
    #expect(!(app.canShowSyncErrorDetails))
    #expect((try Data(contentsOf: ledgerURL)) == (corrupt))
    guard case .idle = app.syncState else {
      Issue.record("aborting recovery did not clear the head-unit error")
      return
    }

    app.sync(device)
    try await waitUntilOperationEnds(app)
    let quarantinePath = try #require(app.syncLedgerRecoveryPrompt?.quarantinePath)
    app.assumeEmptySyncLedger()
    try await waitUntilOperationEnds(app)

    #expect(app.syncLedgerRecoveryPrompt == nil)
    #expect(!(app.canShowSyncErrorDetails))
    #expect(!(FileManager.default.fileExists(atPath: ledgerURL.path)))
    #expect((try Data(contentsOf: URL(fileURLWithPath: quarantinePath))) == (corrupt))
    #expect((try fs.readDatabase().tracks.count) == (0))
    guard case .failed(let message) = app.syncState else {
      Issue.record("reset should stop and ask for a fresh sync review")
      return
    }
    #expect(message.contains("Review the refreshed sync settings"))
  }

  @MainActor
  @Test
  func testAbortingMalformedLedgerRecoveryDropsQueuedAutoSyncs() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())
    let second = try makeSecondDevice()
    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = makeApp(library: library)
    let first = makeDevice(volume: ipodDir, databaseID: try fs.readDatabase().databaseID)

    app.updateSyncSettings(for: first) { $0.autoSyncOnConnect = true }
    app.updateSyncSettings(for: second.device) { $0.autoSyncOnConnect = true }
    await app.flushSyncSettingsWrites()
    try Data("not json".utf8).write(to: SyncLedgerStore.url(for: libraryDir))

    app.autoSyncIfRequested([first, second.device])
    try await waitUntilOperationEnds(app)
    #expect(app.syncLedgerRecoveryPrompt != nil)
    #expect((try second.fileSystem.readDatabase().tracks.count) == (0))

    app.abortSyncLedgerRecovery()
    #expect(!(app.isDeviceOperationActive))
    #expect((try second.fileSystem.readDatabase().tracks.count) == (0))
  }

  @MainActor
  @Test
  func testEmptyLedgerResetDrainsAndExcludesQueuedSettingsWrites() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let corrupt = Data("not json".utf8)
    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    try corrupt.write(to: ledgerURL)
    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let writerStarted = TestGate()
    let releaseWriter = TestGate()
    let app = makeApp(library: library) { settings, databaseID, folder in
      await writerStarted.signal()
      await releaseWriter.wait()
      try await SyncEngine.writeDeviceSettings(
        settings, databaseID: databaseID, libraryFolder: folder)
    }
    let device = makeDevice(volume: ipodDir, databaseID: try fs.readDatabase().databaseID)

    app.updateSyncSettings(for: device) { $0.autoSyncOnConnect = true }
    await writerStarted.wait()
    app.sync(device)
    try await waitUntilOperationEnds(app)
    let quarantinePath = try #require(app.syncLedgerRecoveryPrompt?.quarantinePath)

    app.assumeEmptySyncLedger()
    app.updateSyncSettings(for: device) { $0.ejectAfterSync = true }
    #expect(app.isDeviceOperationActive)
    #expect((try Data(contentsOf: ledgerURL)) == (corrupt))

    await releaseWriter.signal()
    try await waitUntilOperationEnds(app)
    #expect(!(FileManager.default.fileExists(atPath: ledgerURL.path)))
    #expect((try Data(contentsOf: URL(fileURLWithPath: quarantinePath))) == (corrupt))
    #expect((try SyncLedgerStore.load(libraryFolder: libraryDir)) == (SyncLedger()))
  }

  @MainActor
  @Test
  func testRepairExcludesSyncAndRepairThenReleasesOwnerAfterTerminalCleanup() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())
    let second = try makeSecondDevice()
    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = makeApp(library: library)
    let first = makeDevice(volume: ipodDir, databaseID: try fs.readDatabase().databaseID)

    let deviceLock = try await ScopedAdvisoryLock.acquire(for: ipodDir, namespace: .device)
    defer { deviceLock.unlock() }
    let repair = Task { try await app.repairDatabase(first) }
    try await waitUntilOperationStarts(app)

    app.sync(second.device)
    do {
      _ = try await app.repairDatabase(second.device)
      Issue.record("a second repair must not be admitted")
    } catch {
      #expect(error.localizedDescription.contains("already running"))
    }
    #expect(app.isDeviceOperationActive)
    #expect((try second.fileSystem.readDatabase().tracks.count) == (0))

    deviceLock.unlock()
    _ = try await repair.value
    #expect(!(app.isDeviceOperationActive))
    guard case .idle = app.syncState else {
      Issue.record("repair completion did not publish its terminal state")
      return
    }

    app.sync(second.device)
    try await waitUntilOperationEnds(app)
    #expect((try second.fileSystem.readDatabase().tracks.count) == (1))
  }

  @MainActor
  private func makeApp(
    library: LibraryStore,
    syncSettingsWriter: @escaping AppSyncSettingsWriter = { settings, databaseID, folder in
      try await SyncEngine.writeDeviceSettings(
        settings, databaseID: databaseID, libraryFolder: folder)
    }
  ) -> AppState {
    AppState(
      library: library,
      listeningHistory: ListeningHistoryStore(persistence: OperationMemoryPersistence()),
      syncSettingsWriter: syncSettingsWriter)
  }

  private func makeDevice(volume: URL, databaseID: UInt64) -> IpodDevice {
    IpodDevice(
      volumeURL: volume, databaseID: databaseID,
      name: volume.lastPathComponent, modelDescription: "iPod",
      totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
  }

  private func makeSecondDevice() throws -> (device: IpodDevice, fileSystem: IpodFileSystem) {
    let volume = scratch.appendingPathComponent("SECOND-POD", isDirectory: true)
    let fileSystem = try makeFakeIpodVolume(at: volume)
    try fileSystem.writeDatabase(ITunesDatabase())
    return (
      makeDevice(volume: volume, databaseID: try fileSystem.readDatabase().databaseID),
      fileSystem
    )
  }

  @MainActor
  private func waitUntilOperationStarts(_ app: AppState) async throws {
    let started = await waitUntil { app.isDeviceOperationActive }
    #expect(started, Comment(rawValue: "the operation never acquired AppState ownership"))
  }

  @MainActor
  private func waitUntilOperationEnds(_ app: AppState) async throws {
    let ended = await waitUntil(timeout: .seconds(30)) { !app.isDeviceOperationActive }
    #expect(ended, Comment(rawValue: "the operation owner was not released"))
  }
}

private final class OperationMemoryPersistence: AppDataPersistence, Sendable {
  private let stored = Mutex<Data?>(nil)
  var data: Data? {
    get { stored.withLock { $0 } }
    set { stored.withLock { $0 = newValue } }
  }

  func load() throws -> Data? { data }
  func save(_ data: Data) throws { self.data = data }
}
