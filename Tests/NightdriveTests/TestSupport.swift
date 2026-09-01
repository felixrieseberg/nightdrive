import Dispatch
import Foundation
import Testing

@testable import Nightdrive

/// Polls `condition` until it returns true or `timeout` elapses. Runs on the
/// caller's isolation, so conditions may read main-actor or test-local state.
@discardableResult
func waitUntil(
  timeout: Duration = .seconds(5),
  pollInterval: Duration = .milliseconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async rethrows -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if try await condition() { return true }
    try? await Task.sleep(for: pollInterval)
  }
  return try await condition()
}

/// Verifies `condition` stays true for the whole `window`. Use instead of
/// "sleep, then assert nothing happened": it fails fast on the first
/// violation and checks the condition throughout the grace period.
@discardableResult
func holds(
  for window: Duration = .milliseconds(100),
  pollInterval: Duration = .milliseconds(10),
  isolation: isolated (any Actor)? = #isolation,
  _ condition: () async throws -> Bool
) async rethrows -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: window)
  while clock.now < deadline {
    if try await condition() == false { return false }
    try? await Task.sleep(for: pollInterval)
  }
  return try await condition()
}

func waitForSemaphore(
  _ semaphore: DispatchSemaphore, timeout: DispatchTime
) async -> DispatchTimeoutResult {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: semaphore.wait(timeout: timeout))
    }
  }
}

/// Pins `modificationDate` on the file and returns its generation stamp,
/// re-pinning until the stamp differs from `before`. Each pin advances the
/// file's change time, so same-stat rewrite tests get a distinct stamp
/// deterministically instead of sleeping for the clock to tick.
func pinnedGenerationStamp(
  at url: URL, distinctFrom before: FileGenerationStamp, modificationDate: Date
) throws -> FileGenerationStamp {
  for _ in 0..<100_000 {
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: url.path)
    if let stamp = FileGenerationStamp(url: url), stamp != before { return stamp }
  }
  Issue.record("the change time never advanced past the previous stamp")
  throw CocoaError(.fileWriteUnknown)
}

/// A one-shot async gate: `wait()` suspends until `signal()` opens it.
actor TestGate {
  private(set) var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard !isSignaled else { return }
    await withCheckedContinuation { continuation in
      if isSignaled {
        continuation.resume()
      } else {
        waiters.append(continuation)
      }
    }
  }

  func signal() {
    guard !isSignaled else { return }
    isSignaled = true
    let waiting = waiters
    waiters.removeAll()
    for continuation in waiting { continuation.resume() }
  }
}

/// Creates the bare fake iPod folder layout at `volume` — the
/// iPod_Control/iTunes and iPod_Control/Device folders plus a SysInfo naming
/// `modelNumber` — and returns the volume's file system.
@discardableResult
func makeFakeIpodVolume(at volume: URL, modelNumber: String = "M9282") throws -> IpodFileSystem {
  try FileManager.default.createDirectory(
    at: volume.appendingPathComponent("iPod_Control/iTunes"),
    withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: volume.appendingPathComponent("iPod_Control/Device"),
    withIntermediateDirectories: true)
  try Data("ModelNumStr: x\(modelNumber)\n".utf8).write(
    to: volume.appendingPathComponent("iPod_Control/Device/SysInfo"))
  return IpodFileSystem(volumeURL: volume)
}

/// The built-in artwork specs for a model, failing the test when none exist.
func requireArtworkSpecs(modelNumber: String = "M9585") throws -> [ArtworkImageSpec] {
  try #require(ArtworkFormats.staticSpecs(modelNumber: modelNumber))
}

enum TestScratch {
  static func directory(
    prefix: String = "NightdriveTests",
    temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
  ) -> URL {
    try? FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    return
      temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
  }
}

private final class ScratchCleanup: @unchecked Sendable {
  let url: URL

  init(_ url: URL) { self.url = url }

  deinit { try? FileManager.default.removeItem(at: url) }
}

struct ScratchFixture: Sendable {
  let scratch: URL
  private let cleanup: ScratchCleanup

  init() throws {
    scratch = TestScratch.directory()
    cleanup = ScratchCleanup(scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }
}

protocol ScratchFixtureProviding {
  var scratchFixture: ScratchFixture { get }
}

extension ScratchFixtureProviding {
  var scratch: URL { scratchFixture.scratch }
}

/// A test case with a throwaway visualizer plugin folder and approval suite.
private final class PluginFixtureCleanup: @unchecked Sendable {
  let folder: URL
  let approvalSuite: String

  init(folder: URL, approvalSuite: String) {
    self.folder = folder
    self.approvalSuite = approvalSuite
  }

  deinit {
    UserDefaults().removePersistentDomain(forName: approvalSuite)
    try? FileManager.default.removeItem(at: folder)
  }
}

struct PluginFolderFixture: Sendable {
  let folder: URL
  let approvalSuite: String
  private let cleanup: PluginFixtureCleanup

  init() {
    folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nightdrive-plugins-\(UUID().uuidString)", isDirectory: true)
    approvalSuite = "nightdrive-plugin-approvals-\(UUID().uuidString)"
    cleanup = PluginFixtureCleanup(folder: folder, approvalSuite: approvalSuite)
  }
}

protocol PluginFolderFixtureProviding {
  var pluginFixture: PluginFolderFixture { get }
}

extension PluginFolderFixtureProviding {
  var folder: URL { pluginFixture.folder }
  var approvalSuite: String { pluginFixture.approvalSuite }

  func write(_ name: String, _ source: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try source.write(
      to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  var unseeded: VisualizerPluginFolder {
    VisualizerPluginFolder(url: folder, requiresApproval: false, examples: [])
  }

  @MainActor
  func loadedRegistry(folder: VisualizerPluginFolder? = nil) async -> VisualizerRegistry {
    let registry = VisualizerRegistry(folder: folder ?? unseeded)
    await registry.waitUntilReady()
    return registry
  }
}

fileprivate final class FakeIpodStorage: @unchecked Sendable {
  let cleanup: ScratchCleanup
  var localPlaylists: [LocalPlaylist] = []

  init(scratch: URL) { cleanup = ScratchCleanup(scratch) }
}

struct FakeIpodFixture: Sendable {
  let scratch: URL
  let libraryDir: URL
  let ipodDir: URL
  let modelNumber: String
  fileprivate let storage: FakeIpodStorage

  init(folderName: String = "FAKEPOD", modelNumber: String = "M9282") throws {
    scratch = TestScratch.directory()
    libraryDir = scratch.appendingPathComponent("library", isDirectory: true)
    ipodDir = scratch.appendingPathComponent(folderName, isDirectory: true)
    self.modelNumber = modelNumber
    storage = FakeIpodStorage(scratch: scratch)
    try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
    try makeFakeIpodVolume(at: ipodDir, modelNumber: modelNumber)
  }
}

extension Tag {
  @Tag static var fakeIpod: Self
}

protocol FakeIpodFixtureProviding {
  var fakeIpodFixture: FakeIpodFixture { get }
}

extension FakeIpodFixtureProviding {
  var scratch: URL { fakeIpodFixture.scratch }
  var libraryDir: URL { fakeIpodFixture.libraryDir }
  var ipodDir: URL { fakeIpodFixture.ipodDir }
  var modelNumber: String { fakeIpodFixture.modelNumber }
  var localPlaylists: [LocalPlaylist] {
    get { fakeIpodFixture.storage.localPlaylists }
    nonmutating set { fakeIpodFixture.storage.localPlaylists = newValue }
  }

  var fs: IpodFileSystem { IpodFileSystem(volumeURL: ipodDir) }

  func setModelNumber(_ model: String) throws {
    try Data("ModelNumStr: x\(model)\n".utf8).write(
      to: ipodDir.appendingPathComponent("iPod_Control/Device/SysInfo"))
  }

  func scanLibrary() async -> [LibraryTrack] {
    var tracks: [LibraryTrack] = []
    for url in LibraryStore.findAudioFiles(in: libraryDir) {
      tracks.append(await MetadataLoader.load(url: url))
    }
    return tracks
  }

  func makePlan(
    scope: SyncScopeInput = SyncScopeInput(),
    deviceFamily: IpodDeviceFamily = .thirdGenerationOrLater,
    localPlaylists: [LocalPlaylist] = []
  ) async throws -> SyncPlan {
    let db = try fs.readDatabase()
    let library = await scanLibrary()
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir),
      library: library, device: db.tracks, libraryFolder: libraryDir)
    var plan = SyncEngine.makePlan(
      library: library, device: db.tracks, links: links,
      deviceFamily: deviceFamily, scope: scope)
    plan.localPlaylists = localPlaylists
    return plan
  }

  /// Executes a sync against the fake iPod and library folders with a no-op
  /// progress handler, the shape of nearly every engine invocation in tests.
  @discardableResult
  func runSync(
    _ plan: SyncPlan,
    expectedDatabaseID: UInt64? = nil,
    transcoding: TranscodeContext = TranscodeContext(),
    loudness: LoudnessStore = LoudnessStore()
  ) async throws -> SyncResult {
    try await runSync(
      request: SyncExecutionRequest(plan), expectedDatabaseID: expectedDatabaseID,
      transcoding: transcoding, loudness: loudness)
  }

  @discardableResult
  func runSync(
    request: SyncExecutionRequest,
    expectedDatabaseID: UInt64? = nil,
    effects: SyncEngineEffects = SyncEngineEffects(),
    transcoding: TranscodeContext = TranscodeContext(),
    loudness: LoudnessStore = LoudnessStore()
  ) async throws -> SyncResult {
    try await SyncEngine.execute(
      request: request, deviceVolume: ipodDir, libraryFolder: libraryDir,
      expectedDatabaseID: expectedDatabaseID, effects: effects,
      transcoding: transcoding, loudness: loudness
    ) { _ in }
  }

  @discardableResult
  func writeLibraryMP3(
    filename: String, title: String, artist: String = "Artist", album: String = "Album",
    genre: String = "Rock", trackNumber: Int = 1, year: Int = 2004, seconds: Double = 2
  ) throws -> URL {
    let data = MP3Builder.build(
      tags: .init(
        title: title, artist: artist, album: album,
        genre: genre, trackNumber: trackNumber, year: year),
      seconds: seconds)
    let url = libraryDir.appendingPathComponent(filename)
    try data.write(to: url)
    return url
  }

  func makeLibraryMP3(title: String, artist: String, album: String) throws -> LibraryTrack {
    let data = MP3Builder.build(
      tags: .init(
        title: title, artist: artist, album: album,
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2)
    let url = libraryDir.appendingPathComponent("\(artist) - \(title).mp3")
    try data.write(to: url)
    return LibraryTrack(
      url: url, title: title, artist: artist, album: album, genre: "Rock", trackNumber: 1, year: 2004, durationMS: 2000,
      sizeBytes: data.count, bitrate: 128, samplerate: 44100, modificationDate: Date())
  }

  /// Applies the local-library side effects of a playlist-bearing sync
  /// result: adopts the merged playlists, persists the playlist links, and
  /// deletes consumed On-The-Go files.
  func applyLocalPlaylistSyncEffects(_ result: SyncResult) async throws {
    guard result.syncedPlaylists else { return }
    let outcome = PlaylistSyncApplier.apply(result: result, to: localPlaylists)
    localPlaylists = outcome.playlists
    if let databaseID = result.databaseID {
      try await SyncEngine.writePlaylistLinks(
        outcome.links, databaseID: databaseID, libraryFolder: libraryDir)
    }
    await SyncEngine.removeOnTheGoFiles(result.onTheGoFilesToDelete, deviceVolume: ipodDir)
  }

  func putTrackOnIpod(title: String, artist: String, trackNumber: UInt32 = 0) throws -> ITDBTrack {
    let fs = self.fs
    let dest = try fs.destinationForNewFile(extension: "mp3")
    let data = MP3Builder.build(
      tags: .init(
        title: title, artist: artist, album: "Device Album",
        genre: "Pop", trackNumber: 2, year: 2003),
      seconds: 2)
    try data.write(to: dest)
    var t = ITDBTrack()
    t.title = title
    t.artist = artist
    t.album = "Device Album"
    t.trackNumber = trackNumber
    t.ipodPath = fs.ipodPath(for: dest)
    t.sizeBytes = UInt32(data.count)
    t.lengthMS = 2000
    return t
  }
}

func writeTestSong(
  title: String, to url: URL, artist: String = "Artist", album: String = "Album",
  genre: String = "Rock", trackNumber: Int = 1, year: Int = 2026, seconds: Double = 1
) throws {
  try MP3Builder.build(
    tags: .init(
      title: title, artist: artist, album: album, genre: genre,
      trackNumber: trackNumber, year: year),
    seconds: seconds
  ).write(to: url)
}

enum DBBytes {
  static func u32(_ data: Data, at offset: Int) -> UInt32 {
    let i = data.startIndex + offset
    return UInt32(data[i]) | UInt32(data[i + 1]) << 8
      | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
  }

  static func patchU32(_ data: inout Data, at offset: Int, _ value: UInt32) {
    let i = data.startIndex + offset
    data.replaceSubrange(
      i..<i + 4,
      with: [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
      ])
  }

  static func tag(_ data: Data, at offset: Int) -> String {
    let i = data.startIndex + offset
    return String(bytes: data[i..<i + 4], encoding: .ascii) ?? ""
  }

  static func mhsdSections(in data: Data) -> [(type: UInt32, range: Range<Int>)] {
    var sections: [(UInt32, Range<Int>)] = []
    var pos = 244
    while pos + 16 <= data.count, tag(data, at: pos) == "mhsd" {
      let total = Int(u32(data, at: pos + 8))
      sections.append((u32(data, at: pos + 12), pos..<pos + total))
      pos += total
    }
    return sections
  }

  static func mhitOffsets(in data: Data) -> [Int] {
    // Track and playlist sections share the same list-header walk.
    mhypOffsets(in: data, sectionType: 1)
  }

  static func mhypOffsets(in data: Data, sectionType: UInt32 = 2) -> [Int] {
    guard let section = mhsdSections(in: data).first(where: { $0.type == sectionType })
    else { return [] }
    let mhlp = section.range.lowerBound + Int(u32(data, at: section.range.lowerBound + 4))
    let count = Int(u32(data, at: mhlp + 8))
    var pos = mhlp + Int(u32(data, at: mhlp + 4))
    var offsets: [Int] = []
    for _ in 0..<count {
      offsets.append(pos)
      pos += Int(u32(data, at: pos + 8))
    }
    return offsets
  }

  static func mhipOffsets(in data: Data, mhyp: Int) -> [Int] {
    let headerLen = Int(u32(data, at: mhyp + 4))
    let mhodCount = Int(u32(data, at: mhyp + 12))
    let mhipCount = Int(u32(data, at: mhyp + 16))
    var pos = mhyp + headerLen
    for _ in 0..<mhodCount {
      pos += Int(u32(data, at: pos + 8))
    }
    var offsets: [Int] = []
    for _ in 0..<mhipCount {
      offsets.append(pos)
      pos += Int(u32(data, at: pos + 8))
    }
    return offsets
  }
}
