import Darwin
import Foundation
import Synchronization

/// Opt-in, synthetic large-library benchmark invoked only by
/// `scripts/benchmark-library.sh`. The fixture uses copy-on-write clones of
/// one sparse MP3, so 50,000 four-MiB tracks model a 200-GiB catalog without
/// allocating 200 GiB of audio data.
#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  enum LargeLibraryBenchmark {
    struct Configuration: Sendable {
      let counts: [Int]
      let logicalTrackBytes: Int
      let importCount: Int
      let workDirectory: URL
      let keepFixtures: Bool

      static func parse(_ arguments: ArraySlice<String>) throws -> Configuration {
        var counts = [20_000, 50_000, 100_000]
        var logicalTrackMiB = 4
        var importCount = 1_000
        var workDirectory: URL?
        var keepFixtures = false
        var index = arguments.startIndex
        while index < arguments.endIndex {
          switch arguments[index] {
          case "--counts" where arguments.index(after: index) < arguments.endIndex:
            index = arguments.index(after: index)
            counts = arguments[index].split(separator: ",").compactMap { Int($0) }
          case "--logical-track-mib" where arguments.index(after: index) < arguments.endIndex:
            index = arguments.index(after: index)
            logicalTrackMiB = Int(arguments[index]) ?? 0
          case "--import-count" where arguments.index(after: index) < arguments.endIndex:
            index = arguments.index(after: index)
            importCount = Int(arguments[index]) ?? -1
          case "--work-dir" where arguments.index(after: index) < arguments.endIndex:
            index = arguments.index(after: index)
            workDirectory = URL(fileURLWithPath: arguments[index], isDirectory: true)
          case "--keep-fixtures":
            keepFixtures = true
          default:
            throw BenchmarkError.usage
          }
          index = arguments.index(after: index)
        }
        guard !counts.isEmpty, counts.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
          logicalTrackMiB > 0 && logicalTrackMiB <= 1_024,
          importCount >= 0 && importCount <= 100_000,
          let workDirectory
        else { throw BenchmarkError.usage }
        return Configuration(
          counts: counts, logicalTrackBytes: logicalTrackMiB * 1_048_576,
          importCount: importCount, workDirectory: workDirectory.standardizedFileURL,
          keepFixtures: keepFixtures)
      }
    }

    enum BenchmarkError: Error, CustomStringConvertible {
      case usage
      case unsafeWorkDirectory(String)
      case fixture(String)

      var description: String {
        switch self {
        case .usage:
          "usage: benchmark-library --work-dir <empty-dir> [--counts 20000,50000,100000] [--logical-track-mib 4] [--import-count 1000] [--keep-fixtures]"
        case .unsafeWorkDirectory(let path):
          "benchmark work directory must be empty or absent: \(path)"
        case .fixture(let message):
          "benchmark fixture failed: \(message)"
        }
      }
    }

    private struct PhaseResult: Sendable {
      let name: String
      let milliseconds: Double
      let residentMiB: Double
      let detail: String
    }

    private struct ScenarioResult: Sendable {
      let requestedCount: Int
      let logicalGiB: Double
      let fixtureAllocatedBytes: Int64
      let cacheBytes: Int64
      let peakResidentMiB: Double
      let phases: [PhaseResult]
    }

    private final class LoadCounter: Sendable {
      private let countStorage = Mutex(0)

      func record() {
        countStorage.withLock { $0 += 1 }
      }

      var count: Int { countStorage.withLock { $0 } }
    }

    @MainActor
    static func run(configuration: Configuration) async throws {
      try prepareWorkDirectory(configuration.workDirectory)
      defer {
        if !configuration.keepFixtures {
          try? FileManager.default.removeItem(at: configuration.workDirectory)
        }
      }

      print("Nightdrive synthetic large-library benchmark")
      print(
        "Copy-on-write sparse MP3 fixtures; logical size models library bytes, not disk allocation.")
      print("Times are wall-clock measurements; RSS is sampled at the end of each phase.\n")

      for count in configuration.counts {
        let result = try await runScenario(count: count, configuration: configuration)
        printResult(result)
      }
    }

    @MainActor
    private static func runScenario(
      count: Int, configuration: Configuration
    ) async throws -> ScenarioResult {
      let scenarioRoot = configuration.workDirectory.appendingPathComponent(
        "tracks-\(count)", isDirectory: true)
      let library = scenarioRoot.appendingPathComponent("library", isDirectory: true)
      let appData = scenarioRoot.appendingPathComponent("app-data", isDirectory: true)
      try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: appData, withIntermediateDirectories: true)

      var phases: [PhaseResult] = []
      let fixture = try await measure("fixture_create", into: &phases) {
        try createFixture(count: count, logicalTrackBytes: configuration.logicalTrackBytes, in: library)
      }
      let urls = fixture.urls
      var baselineEntries: [String: LibraryIndexCacheEntry]? = try await measure(
        "synthetic_metadata", into: &phases
      ) {
        try makeEntries(for: urls, logicalTrackBytes: configuration.logicalTrackBytes)
      }
      let root = try LibraryFolderIdentity.resolve(library)
      let cache = LibraryIndexCache(directoryURL: appData)
      await measure("cache_encode_write", into: &phases) {
        cache.saveEntries(baselineEntries ?? [:], for: root)
      }
      baselineEntries = nil
      let cacheBytes = cacheFileBytes(in: appData)
      var decoded: [String: LibraryIndexCacheEntry]? = await measure(
        "cache_decode", into: &phases
      ) {
        cache.loadEntries(for: root)
      }
      let discovered = await measure("file_discovery", into: &phases) {
        LibraryStore.findAudioFiles(in: library)
      }
      guard discovered.count == count, decoded?.count == count else {
        throw BenchmarkError.fixture(
          "expected \(count) files/cache rows, found \(discovered.count)/\(decoded?.count ?? 0)")
      }

      let warmCounter = LoadCounter()
      let warm = await measure("warm_stamp_check", into: &phases) {
        let scan = await LibraryStore.scanTracks(at: discovered, consulting: decoded ?? [:]) { url in
          warmCounter.record()
          return syntheticTrack(
            at: url, ordinal: ordinal(in: url), logicalTrackBytes: configuration.logicalTrackBytes)
        }
        return (trackCount: scan.tracks.count, entries: scan.entries)
      }
      decoded = nil
      phases[phases.count - 1] = PhaseResult(
        name: phases.last!.name, milliseconds: phases.last!.milliseconds,
        residentMiB: phases.last!.residentMiB,
        detail: "tracks=\(warm.trackCount) metadata_loads=\(warmCounter.count)")

      var eventStore: LibraryStore? = LibraryStore(folderURL: library, indexCache: cache)
      let reconciliation = await measure("full_warm_reconciliation", into: &phases) {
        let store = eventStore!
        await store.rescan()
        let collectionCount = LibraryBrowseKind.allCases.reduce(0) {
          $0 + store.collections(for: $1).count
        }
        return (trackCount: store.totalStats.count, collectionCount: collectionCount)
      }
      phases[phases.count - 1] = PhaseResult(
        name: phases.last!.name, milliseconds: phases.last!.milliseconds,
        residentMiB: phases.last!.residentMiB,
        detail:
          "tracks=\(reconciliation.trackCount) browser_collections=\(reconciliation.collectionCount)")

      // The actual folder-event pipeline: replace one file on disk and wait
      // for the watcher-driven reconciliation to install the change and
      // persist its cache delta. Wall time includes ~0.5 s of FSEvents and
      // debounce latency.
      let eventURL = discovered[count / 3]
      let revisionBefore = eventStore!.derivedDataRevision
      try replaceCloneWithSparseFile(
        at: eventURL, logicalTrackBytes: configuration.logicalTrackBytes)
      let eventStamp = FileGenerationStamp(url: eventURL)
      let eventObserved = await measure("folder_event_single_change", into: &phases) {
        await waitUntil(timeoutSeconds: 300, pollMilliseconds: 10) {
          eventStore!.derivedDataRevision != revisionBefore
            && eventStore!.track(at: eventURL)?.fileGenerationStamp == eventStamp
        }
      }
      guard eventObserved else {
        throw BenchmarkError.fixture("folder-event reconciliation never installed the change")
      }
      phases[phases.count - 1] = PhaseResult(
        name: phases.last!.name, milliseconds: phases.last!.milliseconds,
        residentMiB: phases.last!.residentMiB,
        detail: "tracks=\(eventStore!.totalStats.count) includes watcher+debounce latency")

      let eventPath = eventURL.standardizedFileURL.path
      let cacheDeltaObserved = await measure("folder_event_cache_delta", into: &phases) {
        await waitUntil(timeoutSeconds: 300) {
          cache.loadEntries(for: root)[eventPath]?.stamp == eventStamp
        }
      }
      guard cacheDeltaObserved else {
        throw BenchmarkError.fixture("folder-event cache delta was never persisted")
      }
      phases[phases.count - 1] = PhaseResult(
        name: phases.last!.name, milliseconds: phases.last!.milliseconds,
        residentMiB: phases.last!.residentMiB,
        detail: "poll granularity 250 ms; includes one full cache decode per poll")
      eventStore = nil

      // The scan below consults the persisted cache, which already reflects
      // the folder-event change, so only the newly replaced file reloads.
      let consultedEntries = cache.loadEntries(for: root)
      let changedURL = discovered[count / 2]
      try replaceCloneWithSparseFile(
        at: changedURL, logicalTrackBytes: configuration.logicalTrackBytes)
      let changedCounter = LoadCounter()
      let changed = await measure("single_file_change", into: &phases) {
        let scan = await LibraryStore.scanTracks(at: discovered, consulting: consultedEntries) { url in
          changedCounter.record()
          return syntheticTrack(
            at: url, ordinal: ordinal(in: url), logicalTrackBytes: configuration.logicalTrackBytes)
        }
        return (trackCount: scan.tracks.count, entries: scan.entries)
      }
      phases[phases.count - 1] = PhaseResult(
        name: phases.last!.name, milliseconds: phases.last!.milliseconds,
        residentMiB: phases.last!.residentMiB,
        detail: "tracks=\(changed.trackCount) metadata_loads=\(changedCounter.count)")

      if configuration.importCount > 0 {
        let imported = try createImportedFixture(
          count: configuration.importCount, startingAt: count,
          logicalTrackBytes: configuration.logicalTrackBytes, in: library)
        let afterImport = (discovered + imported).sorted { $0.path < $1.path }
        let importCounter = LoadCounter()
        let importedTrackCount = await measure("thousand_file_import", into: &phases) {
          let scan = await LibraryStore.scanTracks(at: afterImport, consulting: changed.entries) {
            url in
            importCounter.record()
            return syntheticTrack(
              at: url, ordinal: ordinal(in: url),
              logicalTrackBytes: configuration.logicalTrackBytes)
          }
          return scan.tracks.count
        }
        phases[phases.count - 1] = PhaseResult(
          name: phases.last!.name, milliseconds: phases.last!.milliseconds,
          residentMiB: phases.last!.residentMiB,
          detail:
            "tracks=\(importedTrackCount) metadata_loads=\(importCounter.count)")
      }

      let logicalGiB = Double(count) * Double(configuration.logicalTrackBytes) / 1_073_741_824
      return ScenarioResult(
        requestedCount: count, logicalGiB: logicalGiB,
        fixtureAllocatedBytes: fixture.allocatedBytes, cacheBytes: cacheBytes,
        peakResidentMiB: peakResidentBytes() / 1_048_576, phases: phases)
    }

    private static func prepareWorkDirectory(_ directory: URL) throws {
      let manager = FileManager.default
      if manager.fileExists(atPath: directory.path) {
        let contents = try manager.contentsOfDirectory(atPath: directory.path)
        guard contents.isEmpty else {
          throw BenchmarkError.unsafeWorkDirectory(directory.path)
        }
      } else {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      }
    }

    private static func createFixture(
      count: Int, logicalTrackBytes: Int, in library: URL
    ) throws -> (urls: [URL], allocatedBytes: Int64) {
      let source = library.appendingPathComponent(".benchmark-source.mp3")
      try writeSparseMP3(to: source, logicalTrackBytes: logicalTrackBytes)
      let urls = try createClones(
        count: count, startingAt: 0, source: source,
        under: library.appendingPathComponent("Tracks", isDirectory: true))
      return (urls, allocatedBytes(at: source))
    }

    private static func createImportedFixture(
      count: Int, startingAt: Int, logicalTrackBytes: Int, in library: URL
    ) throws -> [URL] {
      let source = library.appendingPathComponent(".benchmark-import-source.mp3")
      try writeSparseMP3(to: source, logicalTrackBytes: logicalTrackBytes)
      return try createClones(
        count: count, startingAt: startingAt, source: source,
        under: library.appendingPathComponent("Imported", isDirectory: true))
    }

    private static func createClones(
      count: Int, startingAt: Int, source: URL, under root: URL
    ) throws -> [URL] {
      let manager = FileManager.default
      var urls: [URL] = []
      urls.reserveCapacity(count)
      var currentBucket = -1
      var bucketURL = root
      for offset in 0..<count {
        let ordinal = startingAt + offset
        let bucket = ordinal / 1_000
        if bucket != currentBucket {
          currentBucket = bucket
          bucketURL = root.appendingPathComponent(String(format: "%04d", bucket), isDirectory: true)
          try manager.createDirectory(at: bucketURL, withIntermediateDirectories: true)
        }
        let url = bucketURL.appendingPathComponent(
          String(format: "track-%07d.mp3", ordinal))
        guard clonefile(source.path, url.path, 0) == 0 else {
          throw BenchmarkError.fixture(
            "copy-on-write clone failed for \(url.path): \(String(cString: strerror(errno)))")
        }
        urls.append(url)
      }
      return urls
    }

    private static func writeSparseMP3(to url: URL, logicalTrackBytes: Int) throws {
      let tags = MP3Builder.Tags(
        title: "Benchmark Source", artist: "Nightdrive", album: "Synthetic Library",
        genre: "Benchmark", trackNumber: 1, year: 2026)
      try MP3Builder.build(tags: tags, seconds: 1).write(to: url)
      let descriptor = Darwin.open(url.path, O_WRONLY)
      guard descriptor >= 0 else {
        throw BenchmarkError.fixture("open failed for \(url.path): \(String(cString: strerror(errno)))")
      }
      defer { Darwin.close(descriptor) }
      guard ftruncate(descriptor, off_t(logicalTrackBytes)) == 0 else {
        throw BenchmarkError.fixture(
          "ftruncate failed for \(url.path): \(String(cString: strerror(errno)))")
      }
    }

    private static func replaceCloneWithSparseFile(
      at url: URL, logicalTrackBytes: Int
    ) throws {
      try FileManager.default.removeItem(at: url)
      try writeSparseMP3(to: url, logicalTrackBytes: logicalTrackBytes)
    }

    private static func makeEntries(
      for urls: [URL], logicalTrackBytes: Int
    ) throws -> [String: LibraryIndexCacheEntry] {
      var entries: [String: LibraryIndexCacheEntry] = [:]
      entries.reserveCapacity(urls.count)
      for (index, url) in urls.enumerated() {
        guard let stamp = FileGenerationStamp(url: url) else {
          throw BenchmarkError.fixture("could not stat \(url.path)")
        }
        var track = syntheticTrack(at: url, ordinal: index, logicalTrackBytes: logicalTrackBytes)
        track.fileGenerationStamp = stamp
        track.modificationDate = stamp.modificationDate
        track.sizeBytes = stamp.sizeBytes
        entries[url.standardizedFileURL.path] = LibraryIndexCacheEntry(stamp: stamp, track: track)
      }
      return entries
    }

    private static func syntheticTrack(
      at url: URL, ordinal: Int, logicalTrackBytes: Int
    ) -> LibraryTrack {
      let albumOrdinal = ordinal / 10
      let artist = "Artist \(albumOrdinal % 5_000)"
      return LibraryTrack(
        url: url, title: "Track \(ordinal)", artist: artist,
        album: "Album \(albumOrdinal % 10_000)",
        albumArtist: artist, genre: "Genre \(ordinal % 24)",
        composer: "Composer \(ordinal % 500)", trackNumber: ordinal % 10 + 1,
        trackCount: 10, discNumber: ordinal % 200 == 0 ? 2 : 1, discCount: 2,
        year: 1960 + ordinal % 67, durationMS: 180_000 + ordinal % 180_000,
        sizeBytes: logicalTrackBytes, bitrate: 192, samplerate: 44_100)
    }

    private static func ordinal(in url: URL) -> Int {
      Int(url.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "0") ?? 0
    }

    private static func cacheFileBytes(in appData: URL) -> Int64 {
      let directory = appData.appendingPathComponent("LibraryIndex", isDirectory: true)
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
      return files.reduce(0) {
        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    }

    private static func allocatedBytes(at url: URL) -> Int64 {
      var status = stat()
      guard url.path.withCString({ lstat($0, &status) }) == 0 else { return 0 }
      return Int64(status.st_blocks) * 512
    }

    private static func currentResidentBytes() -> Double {
      var info = proc_taskinfo()
      let size = Int32(MemoryLayout<proc_taskinfo>.size)
      guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
      return Double(info.pti_resident_size)
    }

    private static func peakResidentBytes() -> Double {
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
      return Double(usage.ru_maxrss)
    }

    @MainActor
    private static func waitUntil(
      timeoutSeconds: Double, pollMilliseconds: Int = 250,
      _ condition: @MainActor () -> Bool
    ) async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
      while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(pollMilliseconds))
      }
      return condition()
    }

    @MainActor
    private static func measure<T>(
      _ name: String, into phases: inout [PhaseResult], operation: () async throws -> T
    ) async rethrows -> T {
      let clock = ContinuousClock()
      let start = clock.now
      let result = try await operation()
      let duration = start.duration(to: clock.now)
      let milliseconds =
        Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
      phases.append(
        PhaseResult(
          name: name, milliseconds: milliseconds,
          residentMiB: currentResidentBytes() / 1_048_576, detail: ""))
      return result
    }

    private static func printResult(_ result: ScenarioResult) {
      print(
        "== \(result.requestedCount) tracks / \(String(format: "%.1f", result.logicalGiB)) GiB logical ==")
      for phase in result.phases {
        let detail = phase.detail.isEmpty ? "" : "  \(phase.detail)"
        print(
          String(
            format: "%-26@ %10.1f ms  %8.1f MiB RSS%@", phase.name as NSString,
            phase.milliseconds, phase.residentMiB, detail as NSString))
      }
      print(
        "fixture audio allocated: \(formatBytes(result.fixtureAllocatedBytes)); cache: \(formatBytes(result.cacheBytes)); process peak RSS: \(String(format: "%.1f", result.peakResidentMiB)) MiB\n"
      )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
      if bytes >= 1_048_576 {
        return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
      }
      if bytes >= 1_024 {
        return String(format: "%.1f KiB", Double(bytes) / 1_024)
      }
      return "\(bytes) bytes"
    }
  }
#endif
