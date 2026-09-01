import Foundation
import Testing

@testable import Nightdrive

struct DevelopmentToolsTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  @Test
  func testDevelopmentSuffixNeedsANonEmptyMarker() {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      #expect(
        (AppIdentity.developmentTitleSuffix(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": "some-branch"])) == ("some-branch"))
      #expect(AppIdentity.developmentTitleSuffix(infoDictionary: [:]) == nil)
      #expect(AppIdentity.developmentTitleSuffix(infoDictionary: nil) == nil)
      #expect(
        AppIdentity.developmentTitleSuffix(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": "  "]) == nil)
      #expect(
        (AppIdentity.developmentTitleSuffix(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": " trimmed \n"])) == ("trimmed"))
    #else
      #expect(
        AppIdentity.developmentTitleSuffix(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": "some-branch"]) == nil)
      #expect(!(AppIdentity.isDevelopmentBuild))
    #endif
  }

  @Test
  func testAppTitleIncludesDevelopmentSuffix() {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      #expect(
        (AppIdentity.appTitle(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": "some-branch"])) == ("Nightdrive (some-branch)"))
      #expect((AppIdentity.appTitle(infoDictionary: [:])) == ("Nightdrive"))
    #else
      #expect(
        (AppIdentity.appTitle(
          infoDictionary: ["NightdriveDevelopmentTitleSuffix": "some-branch"])) == ("Nightdrive"))
    #endif
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    @Test
    func testOnlyDirectoriesCountAsFakeVolumes() throws {
      let directory = scratch

      #expect(DevelopmentSafety.isFakeVolume(directory))
      #expect(!(DevelopmentSafety.isFakeVolume(URL(fileURLWithPath: "/"))))
      #expect(!(DevelopmentSafety.isFakeVolume(directory.appendingPathComponent("does-not-exist"))))

      // seed-demo targets may not exist yet; only their nearest ancestor decides.
      #expect(DevelopmentSafety.isFakeSeedTarget(directory.appendingPathComponent("does-not-exist")))
      #expect(!(DevelopmentSafety.isFakeSeedTarget(URL(fileURLWithPath: "/"))))
      #expect(!(DevelopmentSafety.isFakeSeedTarget(URL(fileURLWithPath: "/does-not-exist-anywhere"))))
    }

    @Test
    func testSeedTargetsNestedInsideMountedVolumesAreUnsafe() throws {
      let mountedVolume = scratch.appendingPathComponent("External", isDirectory: true)
      let nested = mountedVolume.appendingPathComponent("library", isDirectory: true)
      try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

      let simulatedVolumeStatus: (URL) -> Bool? = {
        $0.standardizedFileURL == mountedVolume.standardizedFileURL
      }
      #expect(
        !DevelopmentSafety.isFakeSeedTarget(nested, volumeStatus: simulatedVolumeStatus))
      #expect(
        !DevelopmentSafety.isFakeSeedTarget(
          nested.appendingPathComponent("not-created"), volumeStatus: simulatedVolumeStatus))
    }

    @Test
    func testSeedDemoRejectsMountedLibraryAndIpodTargets() throws {
      let library = scratch.appendingPathComponent("library", isDirectory: true)
      let ipod = scratch.appendingPathComponent("ipod", isDirectory: true)
      #expect(CLI.unsafeSeedDemoTarget(libraryDir: library, ipodDir: ipod) == nil)
      #expect(
        CLI.unsafeSeedDemoTarget(libraryDir: URL(fileURLWithPath: "/"), ipodDir: ipod)?.path
          == "/")
      #expect(
        CLI.unsafeSeedDemoTarget(libraryDir: library, ipodDir: URL(fileURLWithPath: "/"))?.path
          == "/")
    }

    @Test
    func testSyncLedgerResetTargetMustBeARegisteredFakeDevice() {
      let real = IpodDevice(
        volumeURL: URL(fileURLWithPath: "/Volumes/REAL"), name: "Real iPod",
        modelDescription: "iPod", totalCapacity: 1, availableCapacity: 1)
      let fakeURL = URL(fileURLWithPath: "/tmp/nightdrive-fake-ipod")
      let fake = IpodDevice(
        volumeURL: fakeURL, name: "Fake iPod", modelDescription: "iPod",
        totalCapacity: 1, availableCapacity: 1)

      #expect(
        DevelopmentSafety.fakeTargetDevice(
          selected: real, devices: [real, fake], developmentScanRoots: [fakeURL])?.volumeURL
          == fakeURL)
      #expect(
        DevelopmentSafety.fakeTargetDevice(
          selected: real, devices: [real], developmentScanRoots: [fakeURL]) == nil)
      #expect(
        DevelopmentSafety.fakeTargetDevice(
          selected: fake, devices: [real, fake], developmentScanRoots: [fakeURL])?.volumeURL
          == fakeURL)
    }

    @MainActor
    @Test
    func testSyncLedgerCorruptionIsLimitedToDisposableDevelopmentLibraries() throws {
      let root = scratch
      let developmentLibrary = root.appendingPathComponent(
        "DevelopmentLibrary", isDirectory: true)
      let messyLibrary = root.appendingPathComponent(
        "DevelopmentMessyLibrary", isDirectory: true)
      let personalLibrary = root.appendingPathComponent("Music", isDirectory: true)
      try FileManager.default.createDirectory(
        at: developmentLibrary, withIntermediateDirectories: true)

      #expect(
        DevelopmentSyncTools.isDisposableDevelopmentLibrary(
          developmentLibrary, appDataDirectory: root))
      #expect(
        DevelopmentSyncTools.isDisposableDevelopmentLibrary(
          messyLibrary, appDataDirectory: root))
      #expect(
        !DevelopmentSyncTools.isDisposableDevelopmentLibrary(
          personalLibrary, appDataDirectory: root))

      let ledgerURL = SyncLedgerStore.url(for: developmentLibrary)
      try Data(#"{"devices":{},"playlists":{},"settings":{}}"#.utf8).write(to: ledgerURL)
      try DevelopmentSyncTools.corruptLedgerFile(libraryFolder: developmentLibrary)

      guard case .malformed = SyncLedgerStore.loadOutcome(libraryFolder: developmentLibrary) else {
        Issue.record("the development command did not create a malformed sync ledger")
        return
      }
    }

    @MainActor
    @Test
    func testClearingFakedStateDoesNotDependOnAScanRootRemaining() async throws {
      let volume = scratch.appendingPathComponent("FakePod", isDirectory: true)
      try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
      try DemoSeeder.seedIpod(
        at: volume, model: "M9585", name: "FakePod", songs: [], playlists: false)

      let manager = DeviceManager()
      await manager.addDevelopmentScanRoot(volume)
      await manager.setDevelopmentWriteError("simulated", for: volume)
      #expect(manager.hasDevelopmentState)

      await manager.removeAllDevelopmentScanRoots()
      #expect(!(manager.hasDevelopmentState))

      await manager.addDevelopmentScanRoot(volume)
      #expect(manager.devices.first { $0.volumeURL == volume }?.writeError == nil)
    }

    @MainActor
    @Test
    func testMountingAFakeIpodAndFakingItsState() async throws {
      let volume = scratch.appendingPathComponent("FakePod", isDirectory: true)
      try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
      try DemoSeeder.seedIpod(
        at: volume, model: "M9585", name: "FakePod", songs: DemoSeeder.ipodOnlySongs,
        playlists: true)

      let manager = DeviceManager()
      await manager.addDevelopmentScanRoot(volume)
      let mounted = try #require(manager.devices.first { $0.volumeURL == volume })
      #expect((mounted.tracks.count) == (DemoSeeder.ipodOnlySongs.count))
      #expect(mounted.writeError == nil)

      await manager.setDevelopmentAvailableCapacity(4096, for: volume)
      #expect((manager.devices.first { $0.volumeURL == volume }?.availableCapacity) == (4096))

      await manager.setDevelopmentWriteError("simulated", for: volume)
      #expect((manager.devices.first { $0.volumeURL == volume }?.writeError) == ("simulated"))
      #expect((manager.devices.first { $0.volumeURL == volume }?.availableCapacity) == (4096))

      await manager.setDevelopmentAvailableCapacity(nil, for: volume)
      #expect((manager.devices.first { $0.volumeURL == volume }?.availableCapacity) != (4096))

      await manager.removeAllDevelopmentScanRoots()
      #expect(manager.devices.first { $0.volumeURL == volume } == nil)
    }

    @Test
    func testSyncPacingIsOffUntilAskedFor() async {
      #expect(!(DevelopmentSyncPacing.isSlowed))
      let started = ContinuousClock.now
      await DevelopmentSyncPacing.pauseIfSlowed()
      #expect((ContinuousClock.now - started) < (.milliseconds(100)))
    }

    @Test
    func testDevelopmentRemovalIgnoresOnlyMissingTargets() throws {
      struct InjectedFailure: Error {}

      let directory = scratch
      let target = directory.appendingPathComponent("target")
      try DevelopmentFileRemoval.removeItemIfPresent(at: target)

      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try Data("remove me".utf8).write(to: target)
      try DevelopmentFileRemoval.removeItemIfPresent(at: target)
      #expect(!(FileManager.default.fileExists(atPath: target.path)))

      do {
        let caughtError = #expect(throws: (any Error).self) {
          try DevelopmentFileRemoval.removeItemIfPresent(
            at: target, removeItem: { _ in throw InjectedFailure() })
        }
        if let caughtError {
          #expect(caughtError is InjectedFailure)
        }
      }
    }
  #endif
}

struct DemoSeederShapeTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  @Test
  func testSeededIpodCarriesSongsAndAnOnTheGoPlaylist() throws {
    let ipod = scratch.appendingPathComponent("photo", isDirectory: true)
    try DemoSeeder.seedIpod(
      at: ipod, model: "M9585", name: "FakePhoto", songs: DemoSeeder.ipodOnlySongs,
      playlists: true)

    #expect(IpodFileSystem.isIpodVolume(ipod))
    let fs = IpodFileSystem(volumeURL: ipod)
    #expect((fs.deviceFamily()) == (.thirdGenerationOrLater))
    let db = try fs.readDatabase()
    #expect((db.tracks.count) == (DemoSeeder.ipodOnlySongs.count))
    #expect((db.playlists.count) == (1))
    #expect((db.playlists.first?.memberDbids.count) == (db.tracks.count))
  }

  @Test
  func testShuffleSeedCarriesNoPlaylists() throws {
    let ipod = scratch.appendingPathComponent("shuffle", isDirectory: true)
    try DemoSeeder.seedIpod(
      at: ipod, model: "MA564", name: "FakeShuffle", songs: DemoSeeder.ipodOnlySongs,
      playlists: false)

    let fs = IpodFileSystem(volumeURL: ipod)
    #expect((fs.deviceFamily()) == (.shuffle))
    #expect(try fs.readDatabase().playlists.isEmpty)
  }

  @Test
  func testEmptySeedIsAReadableIpodWithNoTracks() throws {
    let ipod = scratch.appendingPathComponent("empty", isDirectory: true)
    try DemoSeeder.seedIpod(
      at: ipod, model: "M9585", name: "FakeEmpty", songs: [], playlists: true)

    #expect(IpodFileSystem.isIpodVolume(ipod))
    let db = try IpodFileSystem(volumeURL: ipod).readDatabase()
    #expect(db.tracks.isEmpty)
    #expect(db.playlists.isEmpty)
  }

  @Test
  func testCombinedSeedStillProducesLibraryAndDevice() throws {
    let library = scratch.appendingPathComponent("library", isDirectory: true)
    let ipod = scratch.appendingPathComponent("pod", isDirectory: true)
    try DemoSeeder.seed(libraryDir: library, ipodDir: ipod)

    let audio = LibraryStore.findAudioFiles(in: library)
    #expect((audio.count) == (DemoSeeder.librarySongs.count))
    #expect((IpodFileSystem(volumeURL: ipod).modelNumber()) == ("M9585"))
    #expect((try IpodFileSystem(volumeURL: ipod).readDatabase().tracks.count) == (3))
  }
}
