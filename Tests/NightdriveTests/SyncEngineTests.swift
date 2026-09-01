import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct SyncEngineTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  private actor OutboundPreparationProbe {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var describedPaths: [String] = []

    func begin(path: String) {
      active += 1
      maximumActive = max(maximumActive, active)
      describedPaths.append(path)
    }

    func end() { active -= 1 }
  }

  @Test
  func testTwoWaySync() async throws {

    var deviceOnly = try putTrackOnIpod(title: "Device Song", artist: "Ipod Artist")
    deviceOnly.trackNumber = 1
    var initialDB = ITunesDatabase()
    initialDB.tracks = [deviceOnly]
    try fs.writeDatabase(initialDB)

    let libA = try makeLibraryMP3(title: "Alpha", artist: "Band A", album: "First")
    let libB = try makeLibraryMP3(title: "Beta", artist: "Band B", album: "Second")
    let shared = try makeLibraryMP3(
      title: "Device Song", artist: "Ipod Artist", album: "Device Album")

    let device = try fs.readDatabase()
    let plan = SyncEngine.makePlan(library: [libA, libB, shared], device: device.tracks)
    #expect((Set(plan.copyToDevice.map(\.title))) == (["Alpha", "Beta"]))
    #expect(plan.copyToFolder.isEmpty)

    let result = try await runSync(plan)
    #expect((result.copiedToDevice) == (2))
    #expect((result.failures) == ([]))

    let after = try fs.readDatabase()
    #expect((after.tracks.count) == (3))
    for track in after.tracks {
      let ipodPath = try #require(track.ipodPath)
      let url = try #require(fs.fileURL(forIpodPath: ipodPath))
      #expect(FileManager.default.fileExists(atPath: url.path), Comment(rawValue: "missing \(track.ipodPath ?? "?")"))
    }
    #expect(FileManager.default.fileExists(atPath: fs.databaseBackupURL.path))

    let emptyLibraryDir = scratch.appendingPathComponent("library2", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyLibraryDir, withIntermediateDirectories: true)
    let reversePlan = SyncEngine.makePlan(library: [], device: after.tracks)
    #expect((reversePlan.copyToFolder.count) == (3))
    let reverseResult = try await SyncEngine.execute(
      plan: reversePlan, deviceVolume: ipodDir, libraryFolder: emptyLibraryDir
    ) { _ in }
    #expect((reverseResult.copiedToFolder) == (3))
    let pulled = try FileManager.default.contentsOfDirectory(atPath: emptyLibraryDir.path)
      .filter { $0.hasSuffix(".mp3") }.sorted()
    #expect((pulled.count) == (3))
    #expect(pulled.contains("Ipod Artist - Device Song.mp3"), Comment(rawValue: "\(pulled)"))
  }

  @Test
  func testOutboundPreparationIsParallelAndStaysOffDevice() async throws {
    let titles = (1...6).map { "Parallel \($0)" }
    var library: [LibraryTrack] = []
    for title in titles {
      library.append(try makeLibraryMP3(title: title, artist: "Pipeline", album: "Test"))
    }
    let probe = OutboundPreparationProbe()
    let devicePath = ipodDir.standardizedFileURL.path + "/"

    let result = try await runSync(
      request: SyncExecutionRequest(SyncEngine.makePlan(library: library, device: [])),
      effects: SyncEngineEffects(
        tagWriter: { _, _ in },
        outboundFileDescriber: { url, _, _ in
          await probe.begin(path: url.standardizedFileURL.path)
          try? await Task.sleep(for: .milliseconds(150))
          let track = await MetadataLoader.load(url: url)
          await probe.end()
          return OutboundFileDescription(track: track, artwork: nil)
        }))

    #expect((result.copiedToDevice) == (titles.count))
    #expect((result.failures) == ([]))
    let maximumActive = await probe.maximumActive
    #expect((maximumActive) > (1), Comment(rawValue: "preparation should overlap work"))
    #expect((maximumActive) <= (4), Comment(rawValue: "preparation should stay within its bound"))
    let describedPaths = await probe.describedPaths
    #expect((describedPaths.count) == (titles.count))
    #expect(
      describedPaths.allSatisfy { !$0.hasPrefix(devicePath) },
      Comment(rawValue: "metadata and gapless analysis must read local prepared files, not the iPod"))
    #expect((try fs.readDatabase().tracks.map(\.title)) == (titles))
  }

  @Test
  func testUntaggedFileSyncIsIdempotent() async throws {
    try fs.writeDatabase(ITunesDatabase())

    let frame = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 413)
    let url = libraryDir.appendingPathComponent("untagged mystery track.mp3")
    try Data(repeating: 0, count: 0).write(to: url)
    try (0..<80).reduce(into: Data()) { data, _ in data.append(frame) }.write(to: url)
    let track = await MetadataLoader.load(url: url)
    #expect((track.title) == (""))
    #expect((track.mediaValidation) == (.valid))

    let plan1 = SyncEngine.makePlan(library: [track], device: [])
    #expect((plan1.copyToDevice.count) == (1))
    _ = try await runSync(plan1)

    let after = try fs.readDatabase()
    #expect((after.tracks.first?.title) == ("untagged mystery track"))
    let plan2 = SyncEngine.makePlan(library: [track], device: after.tracks)
    #expect(plan2.isEmpty, Comment(rawValue: "untagged track must not re-sync: \(plan2)"))
  }

  @Test
  func testMetadataLoaderReadsGeneratedMP3() async throws {
    let track = try makeLibraryMP3(title: "Meta Song", artist: "Meta Artist", album: "Meta LP")
    let loaded = await MetadataLoader.load(url: track.url)
    #expect((loaded.title) == ("Meta Song"))
    #expect((loaded.artist) == ("Meta Artist"))
    #expect((loaded.album) == ("Meta LP"))
    #expect((loaded.samplerate) == (44100))
    #expect((loaded.durationMS) > (1500))
    #expect((loaded.durationMS) < (2500))
    #expect((loaded.mediaValidation) == (.valid))
  }

  @Test
  func testMetadataLoaderRejectsCorruptMP3BeforeSync() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let url = libraryDir.appendingPathComponent("looks-like-a-song.mp3")
    try Data("not audio data".utf8).write(to: url)

    let track = await MetadataLoader.load(url: url)

    #expect((track.mediaValidation) == (.invalid(reason: "The audio file could not be decoded.")))
    #expect(
      (track.deviceDelivery(for: .thirdGenerationOrLater))
        == (.unsupported(reason: "The audio file could not be decoded.")))

    let plan = SyncEngine.makePlan(library: [track], device: [])
    #expect(plan.copyToDevice.isEmpty)
    #expect((plan.unsupportedForDevice.map(\.url)) == ([url]))

    let result = try await runSync(plan)
    #expect((result.copiedToDevice) == (0))
    #expect((try fs.readDatabase().tracks.count) == (0))
  }

  @Test
  func testSanitizeBlocksTraversal() {
    #expect(!(SyncEngine.sanitize("../../etc/passwd").contains("/")))
    #expect(!(SyncEngine.sanitize(".hidden").hasPrefix(".")))
    #expect((SyncEngine.sanitize("AC/DC: Live")) == ("AC-DC- Live"))

    var track = ITDBTrack()
    track.title = "../../../evil"
    track.artist = "x"
    let dest = SyncEngine.folderDestination(
      for: track, source: URL(fileURLWithPath: "/tmp/a.mp3"),
      in: URL(fileURLWithPath: "/lib"))
    #expect(dest.standardizedFileURL.path.hasPrefix("/lib/"))
  }

  @Test
  func testIpodPathResolutionRefusesEscape() {
    let fs = IpodFileSystem(volumeURL: URL(fileURLWithPath: "/Volumes/IPOD"))
    #expect(fs.fileURL(forIpodPath: ":..:..:etc:passwd") == nil)
    #expect(fs.fileURL(forIpodPath: ":iPod_Control:Music:F00:ABCD.mp3") != nil)
  }

  @Test
  func testFiletypeMarker() {
    #expect((SyncEngine.filetypeMarker(for: "mp3")) == (0x4D50_3320))
  }

  @Test
  func testSyncPlanCacheBuildsOncePerLibraryAndDeviceRevision() throws {
    let local = try makeLibraryMP3(title: "Local", artist: "Artist", album: "Album")
    var device = IpodDevice(
      volumeURL: ipodDir, name: "Fake iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000)
    device.assignDerivedDataRevision(1)
    var cache = SyncPlanCache()
    var builderCalls = 0
    let builder: ([LibraryTrack], [ITDBTrack]) -> SyncPlan = { library, device in
      builderCalls += 1
      return SyncEngine.makePlan(library: library, device: device)
    }

    let first = cache.plan(
      library: [local], libraryRevision: 10, device: device, builder: builder)
    let repeated = cache.plan(
      library: [local], libraryRevision: 10, device: device, builder: builder)

    #expect((first.copyToDevice.map(\.title)) == (["Local"]))
    #expect((repeated.copyToDevice.map(\.title)) == (["Local"]))
    #expect((builderCalls) == (1))
    #expect((cache.buildCount) == (1))

    _ = cache.plan(
      library: [local], libraryRevision: 11, device: device, builder: builder)
    #expect((builderCalls) == (2), Comment(rawValue: "a new library snapshot must invalidate the plan"))

    var remote = ITDBTrack()
    remote.title = "Remote"
    remote.artist = "iPod"
    device.installTracks([remote])
    device.assignDerivedDataRevision(2)
    let refreshed = cache.plan(
      library: [local], libraryRevision: 11, device: device, builder: builder)

    #expect((refreshed.copyToFolder.map(\.title)) == (["Remote"]))
    #expect((builderCalls) == (3), Comment(rawValue: "a new device snapshot must invalidate the plan"))
    #expect((cache.buildCount) == (3))
  }

  @Test
  func testDeviceTrackAggregatesAreInstalledWithTheSnapshot() {
    var first = ITDBTrack()
    first.lengthMS = 1_500
    first.sizeBytes = 2_000
    var second = ITDBTrack()
    second.lengthMS = 2_500
    second.sizeBytes = 3_000
    var device = IpodDevice(
      volumeURL: ipodDir, name: "Fake iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000,
      tracks: [first, second])

    #expect((device.trackDurationMS) == (4_000))
    #expect((device.usedByAudioBytes) == (5_000))

    device.installTracks([second])
    #expect((device.trackDurationMS) == (2_500))
    #expect((device.usedByAudioBytes) == (3_000))
  }
}
