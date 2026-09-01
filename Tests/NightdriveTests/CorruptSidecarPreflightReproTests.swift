import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct CorruptSidecarPreflightReproTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture(modelNumber: "M9585")
  }

  private func deviceFiles() throws -> [String: Data] {
    let root = ipodDir.standardizedFileURL
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
    var files: [String: Data] = [:]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
      files[relative] = try Data(contentsOf: url)
    }
    return files
  }

  private func leavePublishedCopyTransaction() throws -> (directory: URL, destination: URL) {
    try fs.writeDatabase(ITunesDatabase())
    let source = libraryDir.appendingPathComponent("source.mp3")
    try Data("uncommitted audio".utf8).write(to: source)
    let destination = try fs.destinationForNewFile(extension: "mp3")
    let transaction = try IpodCopyTransaction(fileSystem: fs)
    let staged = try transaction.stage(source: source, destination: destination)
    try transaction.publishJournal()
    try FileManager.default.moveItem(at: staged, to: destination)
    return (transaction.directory, destination)
  }

  @Test
  func testMalformedPendingPreflightsBeforeRecoveringDeviceCopyJournal() async throws {
    let journal = try leavePublishedCopyTransaction()

    let pendingURL = PendingPlaybackReportStore.url(for: libraryDir)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: pendingURL)
    let before = try deviceFiles()
    #expect(FileManager.default.fileExists(atPath: journal.directory.path))
    #expect(FileManager.default.fileExists(atPath: journal.destination.path))

    do {
      _ = try await runSync(SyncEngine.makePlan(library: [], device: []))
      Issue.record("Malformed pending state must abort before device recovery")
    } catch {
      #expect(error is SidecarIntegrityError, Comment(rawValue: "\(error)"))
    }

    #expect((try deviceFiles()) == (before))
    #expect(FileManager.default.fileExists(atPath: journal.directory.path))
    #expect(FileManager.default.fileExists(atPath: journal.destination.path))
    #expect((try Data(contentsOf: pendingURL)) == (corrupt))
  }

  @Test
  func testMalformedPendingOnShufflePreflightsBeforeRecoveringDeviceCopyJournal() async throws {
    try setModelNumber("MA564")
    let journal = try leavePublishedCopyTransaction()

    let pendingURL = PendingPlaybackReportStore.url(for: libraryDir)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: pendingURL)
    let before = try deviceFiles()
    #expect(FileManager.default.fileExists(atPath: journal.directory.path))
    #expect(FileManager.default.fileExists(atPath: journal.destination.path))

    do {
      _ = try await runSync(
        SyncEngine.makePlan(
          library: [], device: [], deviceFamily: .shuffle))
      Issue.record("Malformed pending state must abort shuffle sync before device recovery")
    } catch {
      #expect(error is SidecarIntegrityError, Comment(rawValue: "\(error)"))
    }

    #expect((try deviceFiles()) == (before))
    #expect(FileManager.default.fileExists(atPath: journal.directory.path))
    #expect(FileManager.default.fileExists(atPath: journal.destination.path))
    #expect((try Data(contentsOf: pendingURL)) == (corrupt))
  }

  @Test
  func testMalformedSyncLedgerPreflightsBeforeRecoveringDeviceCopyJournal() async throws {
    let journal = try leavePublishedCopyTransaction()

    let ledgerURL = SyncLedgerStore.url(for: libraryDir)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: ledgerURL)
    let before = try deviceFiles()

    do {
      _ = try await runSync(SyncEngine.makePlan(library: [], device: []))
      Issue.record("Malformed sync ledger must abort before device recovery")
    } catch {
      #expect(error is SidecarIntegrityError, Comment(rawValue: "\(error)"))
    }

    #expect((try deviceFiles()) == (before))
    #expect(FileManager.default.fileExists(atPath: journal.directory.path))
    #expect(FileManager.default.fileExists(atPath: journal.destination.path))
    #expect((try Data(contentsOf: ledgerURL)) == (corrupt))
  }

  @Test
  func testMalformedPlaylistPreflightsBeforeCLIReadRecoversArtworkJournal() async throws {
    let recoveryDirectory = try leaveDeferredArtworkTransaction().recoveryDirectory
    let libraryFolder = libraryDir
    let deviceVolume = ipodDir
    let playlistURL = LocalPlaylistFile.url(for: libraryFolder)
    let corrupt = Data("not json".utf8)
    try corrupt.write(to: playlistURL)
    let before = try deviceFiles()
    #expect(FileManager.default.fileExists(atPath: recoveryDirectory.path))

    do {
      _ = try await SyncWorkflow.execute(
        deviceVolume: ipodDir, libraryFolder: libraryFolder, deviceName: "Test iPod",
        prepare: {
          let sidecars = try CLI.loadSyncSidecars(libraryFolder: libraryFolder)
          let database = try IpodFileSystem(volumeURL: deviceVolume).readDatabase()
          return SyncWorkflow.PreparedExecution(
            request: SyncExecutionRequest(
              librarySnapshot: [], localPlaylists: sidecars.playlists),
            expectedDatabaseID: database.databaseID)
        },
        localEffects: SyncWorkflow.LocalEffects(
          applyPlaylists: { result, playlists in
            PlaylistSyncApplier.apply(result: result, to: playlists)
          },
          mergePlayback: { _ in 0 }),
        engine: { _, _, _, _ in
          Issue.record("Engine must not run after malformed CLI preparation")
          return SyncResult()
        },
        progress: { _ in })
      Issue.record("Malformed playlists must abort before device recovery")
    } catch {
      #expect(error is SidecarIntegrityError, Comment(rawValue: "\(error)"))
    }

    #expect((try deviceFiles()) == (before))
    #expect(FileManager.default.fileExists(atPath: recoveryDirectory.path))
    #expect((try Data(contentsOf: playlistURL)) == (corrupt))
  }
}
