import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct LibraryScanProgressTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  @Test
  func testSuccessfulScanReportsEveryPhaseAndPublishesOnlyTheCompleteCatalog() async throws {
    let folder = scratch.appendingPathComponent("library", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["one.mp3", "two.mp3"] {
      try Data([0]).write(to: folder.appendingPathComponent(name))
    }
    let store = LibraryStore(
      folderURL: folder,
      metadataLoader: { url in
        .fixture(url: url, title: url.deletingPathExtension().lastPathComponent)
      })
    var updates: [LibraryScanProgress] = []
    store.onScanProgress = { updates.append($0) }

    #expect(!store.initialScanCompleted)
    await store.rescan()

    #expect((store.scanState) == (.idle))
    #expect(store.initialScanCompleted)
    #expect(store.isSettled)
    #expect((store.tracks.map(\.title)) == (["one", "two"]))
    #expect(
      (Set(updates.map(\.phase)))
        == (Set([
          .discoveringFiles, .checkingCache, .loadingMetadata, .buildingIndex, .savingIndex,
        ])))
    #expect((updates.last { $0.phase == .checkingCache }?.completed) == (2))
    #expect((updates.last { $0.phase == .loadingMetadata }?.completed) == (2))
    // Catalog + total stats + one browser index per LibraryBrowseKind.
    #expect((updates.last { $0.phase == .buildingIndex }?.completed) == (6))
    #expect((updates.last { $0.phase == .savingIndex }?.completed) == (1))
  }

  @Test
  func testCancelDuringMetadataLoadingDropsTheScanAndKeepsMutationsFailClosed() async throws {
    let folder = scratch.appendingPathComponent("cancelled", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<32 {
      try Data([0]).write(to: folder.appendingPathComponent("track-\(index).mp3"))
    }
    let loadsStarted = Mutex(0)
    let store = LibraryStore(
      folderURL: folder,
      metadataLoader: { url in
        loadsStarted.withLock { $0 += 1 }
        try? await Task.sleep(for: .seconds(30))
        return .fixture(url: url, title: url.lastPathComponent)
      })

    let scan = Task { await store.rescan() }
    let reachedMetadata = await waitUntil {
      loadsStarted.withLock { $0 > 0 }
        && store.scanProgress?.phase == .loadingMetadata
    }
    #expect(reachedMetadata)

    let clock = ContinuousClock()
    let cancellationStarted = clock.now
    store.cancelScan()
    await scan.value

    #expect((cancellationStarted.duration(to: clock.now)) < (.seconds(1)))
    #expect((store.scanState) == (.cancelled))
    #expect(!(store.isScanning))
    #expect(!(store.isSettled))
    #expect((store.rootAvailability) == (.checking))
    #expect(store.tracks.isEmpty)
    #expect((store.derivedDataRevision) == (0))
  }

  @Test
  func testCancelClearsFilesystemChangesPendingBehindTheAbandonedScan() async throws {
    let folder = scratch.appendingPathComponent("pending-rescan", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([0]).write(to: folder.appendingPathComponent("one.mp3"))
    let blockLoads = Mutex(true)
    let loadsStarted = Mutex(0)
    let store = LibraryStore(
      folderURL: folder,
      metadataLoader: { url in
        loadsStarted.withLock { $0 += 1 }
        if blockLoads.withLock({ $0 }) {
          try? await Task.sleep(for: .seconds(30))
        }
        return .fixture(url: url, title: url.deletingPathExtension().lastPathComponent)
      })
    var discoveryStarts = 0
    store.onScanProgress = { progress in
      if progress.phase == .discoveringFiles, progress.completed == 0 {
        discoveryStarts += 1
      }
    }

    let abandonedScan = Task { await store.rescan() }
    let started = await waitUntil { loadsStarted.withLock { $0 > 0 } }
    #expect(started)
    try Data([0]).write(to: folder.appendingPathComponent("two.mp3"))
    // FSEvents delivery can lag while the full in-process suite is busy. Give
    // the watcher time to queue this mutation behind the deliberately blocked scan.
    try await Task.sleep(for: .seconds(5))

    store.cancelScan()
    await abandonedScan.value
    blockLoads.withLock { $0 = false }
    await store.rescan()

    #expect((store.tracks.map(\.title)) == (["one", "two"]))
    #expect((discoveryStarts) == (2), Comment(rawValue: "the fresh scan must not trigger a redundant second scan"))
  }

  @Test
  func testCancellableTrackScanReportsCacheAndMetadataCountsWithoutReturningPartials()
    async throws
  {
    let urls = try (0..<128).map { index -> URL in
      let url = scratch.appendingPathComponent("candidate-\(index).mp3")
      try Data([0]).write(to: url)
      return url
    }
    let updates = Mutex<[LibraryScanProgress]>([])
    let loadsStarted = Mutex(0)
    let task = Task {
      try await LibraryStore.scanTracksReportingProgress(
        at: urls, consulting: [:], maximumConcurrentTasks: 8,
        loader: { url in
          loadsStarted.withLock { $0 += 1 }
          try? await Task.sleep(for: .seconds(30))
          return .fixture(url: url, title: url.lastPathComponent)
        },
        progress: { update in updates.withLock { $0.append(update) } })
    }
    let started = await waitUntil { loadsStarted.withLock { $0 > 0 } }
    #expect(started)

    task.cancel()
    do {
      _ = try await task.value
      Issue.record("a cancelled scan must not return a partial result")
    } catch is CancellationError {
    }

    let captured = updates.withLock { $0 }
    #expect((captured.last { $0.phase == .checkingCache }?.completed) == (urls.count))
    #expect((captured.last { $0.phase == .checkingCache }?.total) == (urls.count))
    #expect((captured.first { $0.phase == .loadingMetadata }?.completed) == (0))
    #expect((captured.first { $0.phase == .loadingMetadata }?.total) == (urls.count))
  }
}
