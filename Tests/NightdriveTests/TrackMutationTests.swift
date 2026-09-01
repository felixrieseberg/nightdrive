import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
final class TrackMutationTests {
  private var volume: URL!
  private var fileURL: URL!
  private var track: ITDBTrack!
  private var device: IpodDevice!

  init() throws {
    volume = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveTrackMutationTests-\(UUID().uuidString)", isDirectory: true)
    let fs = IpodFileSystem(volumeURL: volume)
    try FileManager.default.createDirectory(
      at: fs.musicDir.appendingPathComponent("F00"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("ModelNumStr: xM9282\n".utf8).write(to: fs.sysInfoURL)
    fileURL = fs.musicDir.appendingPathComponent("F00/TEST.mp3")
    let tags = MP3Builder.Tags(
      title: "Original", artist: "Artist", album: "Album", genre: "Rock",
      trackNumber: 1, year: 2000)
    try MP3Builder.build(tags: tags, seconds: 1).write(to: fileURL)

    track = ITDBTrack()
    track.title = "Original"
    track.artist = "Artist"
    track.album = "Album"
    track.genre = "Rock"
    track.ipodPath = fs.ipodPath(for: fileURL)
    track.sizeBytes = UInt32(clamping: try Self.fileSize(at: fileURL))
    track.playCount = 42
    track.rating = 80

    var database = ITunesDatabase()
    database.tracks = [track]
    database.playlists = [
      ITDBPlaylist(name: "Favorites", isMaster: false, memberDbids: [track.dbid])
    ]
    try fs.writeDatabase(database)
    device = IpodDevice(
      volumeURL: volume,
      databaseID: database.databaseID,
      name: "Test iPod",
      modelDescription: "iPod",
      totalCapacity: 1_000_000,
      availableCapacity: 500_000,
      tracks: [track])
  }

  deinit {
    try? FileManager.default.removeItem(at: volume)
  }

  @Test
  func testDeviceEditPreservesIdentityStatsPathAndPlaylists() async throws {
    let manager = DeviceManager()
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.title = "Edited"
    metadata.albumArtist = "Various"
    metadata.comment = "New comment"
    metadata.discCount = 2
    metadata.compilation = true

    try await manager.updateMetadata(
      for: track, on: device, from: baseline, to: metadata,
      artworkChange: .unchanged)

    let database = try IpodFileSystem(volumeURL: volume).readDatabase()
    let edited = try #require(database.tracks.first)
    #expect((edited.dbid) == (track.dbid))
    #expect((edited.ipodPath) == (track.ipodPath))
    #expect((edited.playCount) == (42))
    #expect((edited.rating) == (80))
    #expect((edited.title) == ("Edited"))
    #expect((edited.albumArtist) == ("Various"))
    #expect((edited.comment) == ("New comment"))
    #expect((edited.discCount) == (2))
    #expect(edited.compilation)
    #expect((database.playlists.first?.memberDbids) == ([track.dbid]))
    let loadedFile = await MetadataLoader.load(url: fileURL)
    #expect((loadedFile.title) == ("Edited"))
  }

  @Test
  func testEjectPublishesFailureAndClearsItAfterSuccess() async {
    struct InjectedEjectFailure: LocalizedError {
      var errorDescription: String? { "The device is busy." }
    }
    let manager = DeviceManager()

    await manager.eject(device, using: { _ in throw InjectedEjectFailure() })

    #expect((manager.ejectError) == ("Test iPod could not be ejected: The device is busy."))

    await manager.eject(device, using: { _ in })
    #expect(manager.ejectError == nil)
  }

  @Test
  func testOlderEjectFailureCannotOverwriteNewerSuccess() async {
    struct OlderFailure: LocalizedError {
      var errorDescription: String? { "Older failure" }
    }
    let manager = DeviceManager()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let older = Task {
      await manager.eject(device) { _ in
        started.signal()
        release.wait()
        throw OlderFailure()
      }
    }
    let olderStarted = await waitForSignal(started)
    #expect(olderStarted)

    await manager.eject(device, using: { _ in })
    release.signal()
    await older.value

    #expect(manager.ejectError == nil)
  }

  @Test
  func testOlderEjectSuccessCannotClearNewerFailure() async {
    struct NewerFailure: LocalizedError {
      var errorDescription: String? { "Newer failure" }
    }
    let manager = DeviceManager()
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let older = Task {
      await manager.eject(device) { _ in
        started.signal()
        release.wait()
      }
    }
    let olderStarted = await waitForSignal(started)
    #expect(olderStarted)

    await manager.eject(device, using: { _ in throw NewerFailure() })
    release.signal()
    await older.value

    #expect((manager.ejectError) == ("Test iPod could not be ejected: Newer failure"))
  }

  @Test
  func testDifferentDeviceSuccessDoesNotSuppressPendingFailure() async {
    struct FirstDeviceFailure: LocalizedError {
      var errorDescription: String? { "First device failure" }
    }
    let manager = DeviceManager()
    let secondDevice = otherDevice(named: "Second iPod")
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let first = Task {
      await manager.eject(device) { _ in
        started.signal()
        release.wait()
        throw FirstDeviceFailure()
      }
    }
    let firstStarted = await waitForSignal(started)
    #expect(firstStarted)

    await manager.eject(secondDevice, using: { _ in })
    release.signal()
    await first.value

    #expect((manager.ejectError) == ("Test iPod could not be ejected: First device failure"))
  }

  @Test
  func testDifferentDeviceFailuresArePresentedInCompletionOrder() async {
    struct FirstDeviceFailure: LocalizedError {
      var errorDescription: String? { "First device failure" }
    }
    struct SecondDeviceFailure: LocalizedError {
      var errorDescription: String? { "Second device failure" }
    }
    let manager = DeviceManager()
    let secondDevice = otherDevice(named: "Second iPod")
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let first = Task {
      await manager.eject(device) { _ in
        started.signal()
        release.wait()
        throw FirstDeviceFailure()
      }
    }
    let firstStarted = await waitForSignal(started)
    #expect(firstStarted)

    await manager.eject(secondDevice, using: { _ in throw SecondDeviceFailure() })
    release.signal()
    await first.value

    #expect((manager.ejectError) == ("Second iPod could not be ejected: Second device failure"))
    manager.dismissEjectError()
    #expect((manager.ejectError) == ("Test iPod could not be ejected: First device failure"))
    manager.dismissEjectError()
    #expect(manager.ejectError == nil)
  }

  @Test
  func testEjectAlertBindingRequiresOneDismissalPerQueuedFailure() async {
    struct FirstDeviceFailure: LocalizedError {
      var errorDescription: String? { "First device failure" }
    }
    struct SecondDeviceFailure: LocalizedError {
      var errorDescription: String? { "Second device failure" }
    }
    let manager = DeviceManager()
    let secondDevice = otherDevice(named: "Second iPod")
    await manager.eject(device, using: { _ in throw FirstDeviceFailure() })
    await manager.eject(secondDevice, using: { _ in throw SecondDeviceFailure() })
    let isPresented = ejectErrorPresentationBinding(for: manager)

    #expect(isPresented.wrappedValue)
    #expect((manager.ejectError) == ("Test iPod could not be ejected: First device failure"))

    isPresented.wrappedValue = false

    #expect(isPresented.wrappedValue)
    #expect((manager.ejectError) == ("Second iPod could not be ejected: Second device failure"))

    isPresented.wrappedValue = false

    #expect(!(isPresented.wrappedValue))
    #expect(manager.ejectError == nil)
  }

  @Test
  func testSingleDeviceEditPersistsArtworkInFileArtworkDBTilesAndTrackLink() async throws {
    try configureColorDevice()
    let artwork = try pngData(red: 1, green: 0, blue: 0)
    let baseline = TrackMetadata(track)

    try await DeviceManager().updateMetadata(
      for: track,
      on: device,
      from: baseline,
      to: baseline,
      artworkChange: .replace(artwork))

    let artworkFrames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
      .filter { $0.id == "APIC" }
    #expect((artworkFrames.count) == (1))
    #expect(artworkFrames[0].payload.suffix(artwork.count) == artwork)

    let fs = IpodFileSystem(volumeURL: volume)
    let storedTrack = try #require(fs.readDatabase().tracks.first)
    #expect((Int(storedTrack.sizeBytes)) == (try Self.fileSize(at: fileURL)))
    let link = try #require(storedTrack.artwork)
    #expect(link.hasArtwork)
    let images = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    let image = try #require(images.first(where: { $0.trackDbid == self.track.dbid }))
    #expect((image.mhiiID) == (link.mhiiID))
    #expect((image.sourceImageSize) == (UInt32(artwork.count)))
    for spec in try requireArtworkSpecs() {
      #expect((try Data(contentsOf: fs.ithmbURL(for: spec)).count) == (spec.bytesPerTile))
    }
  }

  @Test
  func testAbruptExitAfterPreviousMediaMovedRestoresExactOldGenerationOnRead() async throws {
    try configureColorDevice()
    let fs = IpodFileSystem(volumeURL: volume)
    let specs = try requireArtworkSpecs()
    let baseline = TrackMetadata(track)
    try await DeviceManager().updateMetadata(
      for: track, on: device, from: baseline, to: baseline,
      artworkChange: .replace(try pngData(red: 1, green: 0, blue: 0)))

    let previousDatabase = try Data(contentsOf: fs.databaseURL)
    let previousLinks = ArtworkDatabaseLink.links(in: try fs.readDatabase())
    let previousMedia = try Data(contentsOf: fileURL)
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let previousTiles = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })
    let replacementCover = volume.appendingPathComponent("crash-cover.png")
    let replacementMedia = volume.appendingPathComponent("crash-media.mp3")
    try pngData(red: 0, green: 1, blue: 0).write(to: replacementCover)
    try Data("the staged generation must never survive".utf8).write(to: replacementMedia)

    let productsDirectory = Bundle(for: TrackMutationTests.self).bundleURL
      .deletingLastPathComponent()
    let executable = productsDirectory.appendingPathComponent("Nightdrive")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "__test-crash-artwork-media-install", volume.path,
      replacementCover.path, replacementMedia.path,
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()

    #expect((process.terminationReason) == (.exit))
    #expect((process.terminationStatus) == (86))
    #expect(
      !(FileManager.default.fileExists(atPath: fileURL.path)),
      Comment(rawValue: "the child must exit at media afterPreviousMoved, not a later checkpoint"))

    let recoveredDatabase = try fs.readDatabase()
    #expect((ArtworkDatabaseLink.links(in: recoveredDatabase)) == (previousLinks))
    #expect((try Data(contentsOf: fs.databaseURL)) == (previousDatabase))
    #expect((try Data(contentsOf: fileURL)) == (previousMedia))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (previousArtworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (previousTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    #expect((try artworkTransactionDirectories(fileSystem: fs)) == ([]))
  }

  @Test
  func testEditingOneTrackRejectsUntouchedEmbeddedCoverThatDiffersFromStoredPixels()
    async throws
  {
    try configureColorDevice()
    let fs = IpodFileSystem(volumeURL: volume)
    let specs = try requireArtworkSpecs()
    let secondFile = fs.musicDir.appendingPathComponent("F00/SECOND.mp3")
    let secondTags = MP3Builder.Tags(
      title: "Second", artist: "Artist", album: "Album", genre: "Rock",
      trackNumber: 2, year: 2000)
    try MP3Builder.build(tags: secondTags, seconds: 1).write(to: secondFile)
    var database = try fs.readDatabase()
    var secondTrack = ITDBTrack()
    secondTrack.dbid = track.dbid &+ 1
    if secondTrack.dbid == track.dbid { secondTrack.dbid &+= 1 }
    secondTrack.title = "Second"
    secondTrack.artist = "Artist"
    secondTrack.album = "Album"
    secondTrack.genre = "Rock"
    secondTrack.ipodPath = fs.ipodPath(for: secondFile)
    secondTrack.sizeBytes = UInt32(clamping: try Self.fileSize(at: secondFile))
    database.tracks.append(secondTrack)
    try fs.writeDatabase(database)
    let currentDevice = IpodDevice(
      volumeURL: volume, databaseID: database.databaseID,
      name: "Test iPod", modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000,
      tracks: database.tracks)
    let coverA = try pngData(red: 1, green: 0, blue: 0)
    let manager = DeviceManager()
    for dbid in [track.dbid, secondTrack.dbid] {
      let liveTrack = try #require(fs.readDatabase().tracks.first { $0.dbid == dbid })
      let liveMetadata = TrackMetadata(liveTrack)
      try await manager.updateMetadata(
        for: liveTrack, on: currentDevice, from: liveMetadata, to: liveMetadata,
        artworkChange: .replace(coverA))
    }

    let secondStoredTrack = try #require(fs.readDatabase().tracks.first { $0.dbid == secondTrack.dbid })
    let secondLiveMetadata = TrackMetadata(
      fileTrack: await MetadataLoader.load(url: secondFile), databaseTrack: secondStoredTrack)
    try TrackFileMetadataWriter.write(
      secondLiveMetadata,
      artworkChange: .replace(try pngData(red: 0, green: 0, blue: 1)),
      to: secondFile)

    let beforeDatabase = try Data(contentsOf: fs.databaseURL)
    let beforeFirstMedia = try Data(contentsOf: fileURL)
    let beforeSecondMedia = try Data(contentsOf: secondFile)
    let beforeArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let beforeTiles = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })
    let firstStoredTrack = try #require(fs.readDatabase().tracks.first { $0.dbid == track.dbid })
    let firstMetadata = TrackMetadata(
      fileTrack: await MetadataLoader.load(url: fileURL), databaseTrack: firstStoredTrack)

    do {
      try await manager.updateMetadata(
        for: firstStoredTrack, on: currentDevice,
        from: firstMetadata, to: firstMetadata,
        artworkChange: .replace(try pngData(red: 0, green: 1, blue: 0)))
      Issue.record("the untouched store/embedded mismatch must fail closed")
    } catch DeviceArtworkMutationError.untouchedArtworkMismatch {
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (beforeDatabase))
    #expect((try Data(contentsOf: fileURL)) == (beforeFirstMedia))
    #expect((try Data(contentsOf: secondFile)) == (beforeSecondMedia))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (beforeArtworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (beforeTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    #expect((try artworkTransactionDirectories(fileSystem: fs)) == ([]))
  }

  @Test
  func testSingleDeviceEditRemovesArtworkFromFileStoreTilesAndTrackLink() async throws {
    try configureColorDevice()
    let manager = DeviceManager()
    try await manager.updateMetadata(
      for: track, on: device, from: TrackMetadata(track), to: TrackMetadata(track),
      artworkChange: .replace(try pngData(red: 1, green: 0, blue: 0)))

    let installed = try IpodFileSystem(volumeURL: volume).readDatabase()
    let installedTrack = try #require(installed.tracks.first)
    try await manager.updateMetadata(
      for: installedTrack, on: device, from: TrackMetadata(installedTrack),
      to: TrackMetadata(installedTrack),
      artworkChange: .remove)

    let artworkFrames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
      .filter { $0.id == "APIC" }
    #expect(artworkFrames.isEmpty)
    let fs = IpodFileSystem(volumeURL: volume)
    let removedTrack = try #require(fs.readDatabase().tracks.first)
    #expect(removedTrack.artwork == nil)
    #expect((Int(removedTrack.sizeBytes)) == (try Self.fileSize(at: fileURL)))
    #expect(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).isEmpty)
    for spec in try requireArtworkSpecs() {
      #expect(try Data(contentsOf: fs.ithmbURL(for: spec)).isEmpty)
    }
  }

  @Test
  func testArtworkReplaceRollsBackEveryGenerationWhenDatabaseDoesNotCommit() async throws {
    try configureColorDevice()
    let fs = IpodFileSystem(volumeURL: volume)
    let specs = try requireArtworkSpecs()
    let installedArtwork = try pngData(red: 1, green: 0, blue: 0)
    try await DeviceManager().updateMetadata(
      for: track, on: device, from: TrackMetadata(track), to: TrackMetadata(track),
      artworkChange: .replace(installedArtwork))
    let installedTrack = try #require(fs.readDatabase().tracks.first)
    let previousFile = try Data(contentsOf: fileURL)
    let previousDatabase = try Data(contentsOf: fs.databaseURL)
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let previousTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })

    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in throw UncommittedFailure() }
    do {
      try await manager.updateMetadata(
        for: installedTrack, on: device, from: TrackMetadata(installedTrack),
        to: TrackMetadata(installedTrack),
        artworkChange: .replace(try pngData(red: 0, green: 0, blue: 1)))
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try Data(contentsOf: fileURL)) == (previousFile))
    #expect((try Data(contentsOf: fs.databaseURL)) == (previousDatabase))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (previousArtworkDatabase))
    for spec in specs {
      #expect((try Data(contentsOf: fs.ithmbURL(for: spec))) == (previousTiles[spec.ithmbName]))
    }
    #expect((try artworkTransactionDirectories(fileSystem: fs)) == ([]))
  }

  @Test
  func testArtworkRemoveKeepsCompleteNewGenerationWhenDatabaseCommittedBeforeThrow() async throws {
    try configureColorDevice()
    let fs = IpodFileSystem(volumeURL: volume)
    let specs = try requireArtworkSpecs()
    try await DeviceManager().updateMetadata(
      for: track, on: device, from: TrackMetadata(track), to: TrackMetadata(track),
      artworkChange: .replace(try pngData(red: 1, green: 0, blue: 0)))
    let installedTrack = try #require(fs.readDatabase().tracks.first)

    struct CommittedButReportedFailure: Error {}
    let manager = DeviceManager { fileSystem, database in
      try fileSystem.writeDatabase(database)
      throw CommittedButReportedFailure()
    }
    do {
      try await manager.updateMetadata(
        for: installedTrack, on: device, from: TrackMetadata(installedTrack),
        to: TrackMetadata(installedTrack),
        artworkChange: .remove)
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    #expect(
      try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
        .filter { $0.id == "APIC" }.isEmpty)
    let committedTrack = try #require(fs.readDatabase().tracks.first)
    #expect(committedTrack.artwork == nil)
    #expect((Int(committedTrack.sizeBytes)) == (try Self.fileSize(at: fileURL)))
    #expect(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).isEmpty)
    for spec in specs {
      #expect(try Data(contentsOf: fs.ithmbURL(for: spec)).isEmpty)
    }
    #expect((try artworkTransactionDirectories(fileSystem: fs)) == ([]))
  }

  @Test
  func testArtworkReplaceDefersUnknownDatabaseOutcomeAndRecoversCommittedGeneration() async throws {
    try configureColorDevice()
    let fs = IpodFileSystem(volumeURL: volume)
    try await DeviceManager().updateMetadata(
      for: track, on: device, from: TrackMetadata(track), to: TrackMetadata(track),
      artworkChange: .replace(try pngData(red: 1, green: 0, blue: 0)))
    let installedTrack = try #require(fs.readDatabase().tracks.first)
    let intendedArtwork = try pngData(red: 0, green: 1, blue: 0)

    struct CommittedButReportedFailure: Error {}
    struct VerificationReadFailure: Error {}
    let manager = DeviceManager(
      metadataDatabaseWriter: { fileSystem, database in
        try fileSystem.writeDatabase(database)
        throw CommittedButReportedFailure()
      },
      metadataDatabaseVerificationReader: { _ in throw VerificationReadFailure() })
    do {
      try await manager.updateMetadata(
        for: installedTrack, on: device, from: TrackMetadata(installedTrack),
        to: TrackMetadata(installedTrack),
        artworkChange: .replace(intendedArtwork))
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    #expect((try artworkTransactionDirectories(fileSystem: fs).count) == (1))
    let recovered = try fs.readDatabase()
    let recoveredTrack = try #require(recovered.tracks.first)
    #expect((Int(recoveredTrack.sizeBytes)) == (try Self.fileSize(at: fileURL)))
    let recoveredLink = try #require(recoveredTrack.artwork)
    let recoveredImage = try #require(ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).first)
    #expect((recoveredImage.trackDbid) == (recoveredTrack.dbid))
    #expect((recoveredImage.mhiiID) == (recoveredLink.mhiiID))
    #expect((recoveredImage.sourceImageSize) == (UInt32(intendedArtwork.count)))
    #expect(
      try #require(
        MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
          .first(where: { $0.id == "APIC" })
      )
      .payload.suffix(intendedArtwork.count) == intendedArtwork)
    #expect((try artworkTransactionDirectories(fileSystem: fs)) == ([]))
  }

  @Test
  func testArtworkOnlySingleEditPreservesConcurrentLiveMetadata() async throws {
    try configureColorDevice()
    let baselineFile = await MetadataLoader.load(url: fileURL)
    let baseline = TrackMetadata(fileTrack: baselineFile, databaseTrack: track)
    try await installConcurrentLiveMetadata()
    let artwork = try pngData(red: 1, green: 0, blue: 0)

    try await DeviceManager().updateMetadata(
      for: track,
      on: device,
      from: baseline,
      to: baseline,
      artworkChange: .replace(artwork))

    try assertConcurrentDatabaseMetadata(title: "Concurrent Title")
    let loadedFile = await MetadataLoader.load(url: fileURL)
    assertConcurrentFileMetadata(loadedFile, title: "Concurrent Title")
    let artworkFrames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
      .filter { $0.id == "APIC" }
    #expect((artworkFrames.count) == (1))
    #expect(artworkFrames[0].payload.suffix(artwork.count) == artwork)
  }

  @Test
  func testSingleFieldEditWinsConflictAndPreservesOtherConcurrentMetadata() async throws {
    let baselineFile = await MetadataLoader.load(url: fileURL)
    let baseline = TrackMetadata(fileTrack: baselineFile, databaseTrack: track)
    var edited = baseline
    edited.title = "User Title"
    try await installConcurrentLiveMetadata()

    try await DeviceManager().updateMetadata(
      for: track,
      on: device,
      from: baseline,
      to: edited,
      artworkChange: .unchanged)

    try assertConcurrentDatabaseMetadata(title: "User Title")
    let loadedFile = await MetadataLoader.load(url: fileURL)
    assertConcurrentFileMetadata(loadedFile, title: "User Title")
  }

  @Test
  func testMP3MetadataGrowthAndShrinkReconcileDatabaseAndReloadedDeviceSize() async throws {
    let manager = DeviceManager()
    let mounted = try #require(device)
    let originalSize = try Self.fileSize(at: fileURL)
    let mountedTrack = try #require(mounted.tracks.first)
    let originalFileTrack = await MetadataLoader.load(url: fileURL)
    let originalMetadata = TrackMetadata(
      fileTrack: originalFileTrack, databaseTrack: mountedTrack)
    var grownMetadata = originalMetadata
    grownMetadata.title = String(repeating: "A much longer MP3 title ", count: 32)
    grownMetadata.grouping = String(repeating: "Large grouping ", count: 64)
    grownMetadata.lyrics = String(repeating: "Metadata growth must be counted.\n", count: 512)

    try await manager.updateMetadata(
      for: mountedTrack, on: mounted, from: originalMetadata, to: grownMetadata,
      artworkChange: .replace(artworkData(size: 16_384)))

    let grownSize = try Self.fileSize(at: fileURL)
    #expect((grownSize) > (originalSize))
    try assertReloadedSizeCoherence(fileURL: fileURL, dbid: mountedTrack.dbid)

    let grownTrack = try #require(
      IpodFileSystem(volumeURL: volume).readDatabase().tracks.first {
        $0.dbid == mountedTrack.dbid
      })
    let grownFileTrack = await MetadataLoader.load(url: fileURL)
    let grownBaseline = TrackMetadata(fileTrack: grownFileTrack, databaseTrack: grownTrack)
    try await manager.updateMetadata(
      for: grownTrack, on: mounted, from: grownBaseline,
      to: minimalMetadata(title: "Small MP3"),
      artworkChange: .remove)

    let shrunkSize = try Self.fileSize(at: fileURL)
    #expect((shrunkSize) < (grownSize))
    try assertReloadedSizeCoherence(fileURL: fileURL, dbid: mountedTrack.dbid)
  }

  @Test
  func testM4AMetadataGrowthAndShrinkReconcileDatabaseAndReloadedDeviceSize() async throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let m4aURL = fs.musicDir.appendingPathComponent("F00/TEST.m4a")
    try writeAudioFixture(to: m4aURL, formatID: kAudioFormatMPEG4AAC, amplitude: 0)
    var m4aTrack = ITDBTrack()
    m4aTrack.dbid = 0x4D_34_41
    m4aTrack.title = "Original M4A"
    m4aTrack.ipodPath = fs.ipodPath(for: m4aURL)
    m4aTrack.sizeBytes = UInt32(clamping: try Self.fileSize(at: m4aURL))
    var database = try fs.readDatabase()
    database.tracks = [m4aTrack]
    try fs.writeDatabase(database)

    let manager = DeviceManager()
    let mounted = IpodDevice(
      volumeURL: volume, databaseID: database.databaseID, name: "Test iPod",
      modelDescription: "iPod", totalCapacity: 1_000_000, availableCapacity: 500_000,
      tracks: [m4aTrack])
    let mountedTrack = m4aTrack
    let originalSize = try Self.fileSize(at: m4aURL)
    let originalFileTrack = await MetadataLoader.load(url: m4aURL)
    let originalMetadata = TrackMetadata(
      fileTrack: originalFileTrack, databaseTrack: mountedTrack)
    var grownMetadata = originalMetadata
    grownMetadata.title = String(repeating: "A much longer M4A title ", count: 32)
    grownMetadata.grouping = String(repeating: "Large grouping ", count: 64)
    grownMetadata.comment = String(repeating: "Large comment ", count: 64)
    grownMetadata.lyrics = String(repeating: "The moov atom growth must be counted.\n", count: 512)

    try await manager.updateMetadata(
      for: mountedTrack, on: mounted, from: originalMetadata, to: grownMetadata,
      artworkChange: .replace(artworkData(size: 16_384)))

    let grownSize = try Self.fileSize(at: m4aURL)
    #expect((grownSize) > (originalSize))
    try assertReloadedSizeCoherence(fileURL: m4aURL, dbid: mountedTrack.dbid)

    let grownTrack = try #require(fs.readDatabase().tracks.first { $0.dbid == mountedTrack.dbid })
    let grownFileTrack = await MetadataLoader.load(url: m4aURL)
    let grownBaseline = TrackMetadata(fileTrack: grownFileTrack, databaseTrack: grownTrack)
    try await manager.updateMetadata(
      for: grownTrack, on: mounted, from: grownBaseline,
      to: minimalMetadata(title: "Small M4A"),
      artworkChange: .remove)

    let shrunkSize = try Self.fileSize(at: m4aURL)
    #expect((shrunkSize) < (grownSize))
    try assertReloadedSizeCoherence(fileURL: m4aURL, dbid: mountedTrack.dbid)
  }

  @Test
  func testArtworkSizeChangeRollsFileBackWhenDatabaseSizeDoesNotCommit() async throws {
    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in
      throw UncommittedFailure()
    }
    let mounted = try #require(device)
    let mountedTrack = try #require(track)
    let original = try Data(contentsOf: fileURL)

    do {
      let baseline = TrackMetadata(mountedTrack)
      try await manager.updateMetadata(
        for: mountedTrack, on: mounted, from: baseline, to: baseline,
        artworkChange: .replace(artworkData(size: 16_384)))
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try Data(contentsOf: fileURL)) == (original))
    try assertReloadedSizeCoherence(fileURL: fileURL, dbid: mountedTrack.dbid)
  }

  @Test
  func testDeviceDeleteRemovesFileDatabaseTrackAndPlaylistReference() async throws {
    let manager = DeviceManager()
    try await manager.delete(track, from: device)

    #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
    let database = try IpodFileSystem(volumeURL: volume).readDatabase()
    #expect(database.tracks.isEmpty)
    #expect(database.playlists.first?.memberDbids.isEmpty == true)
  }

  @Test
  func testInterruptedDeleteRestoresFileWhenDatabaseStillReferencesTrack() throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let transaction = try IpodDeleteTransaction(fileSystem: fs)
    try transaction.stage(
      source: fileURL, dbid: track.dbid, ipodPath: try #require(track.ipodPath))
    #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))

    try fs.recoverInterruptedDeletions(database: fs.readDatabase())

    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testInterruptedDeleteDiscardsFileAfterDatabaseCommit() throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let transaction = try IpodDeleteTransaction(fileSystem: fs)
    try transaction.stage(
      source: fileURL, dbid: track.dbid, ipodPath: try #require(track.ipodPath))
    var committedDatabase = try fs.readDatabase()
    committedDatabase.tracks.removeAll { $0.dbid == track.dbid }
    try fs.writeDatabase(committedDatabase)

    try fs.recoverInterruptedDeletions(database: fs.readDatabase())

    #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testDeviceBulkGenreEditPreservesOtherMetadata() async throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let secondURL = fs.musicDir.appendingPathComponent("F00/SECOND.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Second", artist: "Other Artist", album: "Other Album",
        genre: "Jazz", trackNumber: 8, year: 2008),
      seconds: 1
    ).write(to: secondURL)
    var second = ITDBTrack()
    second.title = "Second"
    second.artist = "Other Artist"
    second.album = "Other Album"
    second.genre = "Jazz"
    second.trackNumber = 8
    second.year = 2008
    second.ipodPath = fs.ipodPath(for: secondURL)

    var database = try fs.readDatabase()
    database.tracks.append(second)
    try fs.writeDatabase(database)
    let firstFileMetadata = await MetadataLoader.load(url: fileURL)
    let secondFileMetadata = await MetadataLoader.load(url: secondURL)
    let edits = [
      DeviceTrackMetadataEdit(
        dbid: track.dbid,
        metadata: TrackMetadata(fileTrack: firstFileMetadata, databaseTrack: track)),
      DeviceTrackMetadataEdit(
        dbid: second.dbid,
        metadata: TrackMetadata(fileTrack: secondFileMetadata, databaseTrack: second)),
    ]
    var lateFileMetadata = TrackMetadata(firstFileMetadata)
    lateFileMetadata.grouping = "Current grouping"
    lateFileMetadata.bpm = 137
    lateFileMetadata.lyrics = "Current lyrics"
    try MP3MetadataWriter.write(lateFileMetadata, to: fileURL)
    var changes = TrackMetadataChanges()
    changes.genre = "Electronic"

    try await DeviceManager().updateMetadata(for: edits, on: device, applying: changes)

    let updated = try fs.readDatabase().tracks.sorted { $0.title ?? "" < $1.title ?? "" }
    #expect((updated.map(\.genre)) == (["Electronic", "Electronic"]))
    #expect((updated.map(\.title)) == (["Original", "Second"]))
    #expect((updated.map(\.artist)) == (["Artist", "Other Artist"]))
    #expect((updated.map(\.album)) == (["Album", "Other Album"]))
    let firstFile = await MetadataLoader.load(url: fileURL)
    let secondFile = await MetadataLoader.load(url: secondURL)
    #expect((firstFile.genre) == ("Electronic"))
    #expect((firstFile.title) == ("Original"))
    #expect((firstFile.grouping) == ("Current grouping"))
    #expect((firstFile.bpm) == (137))
    #expect((firstFile.lyrics) == ("Current lyrics"))
    #expect((secondFile.genre) == ("Electronic"))
    #expect((secondFile.title) == ("Second"))
    #expect((secondFile.trackNumber) == (8))
    #expect((secondFile.year) == (2008))
  }

  @Test
  func testDeviceBulkEditRecoversAbandonedSyncCopyBeforeMutation() async throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let orphan = fs.musicDir.appendingPathComponent("F00/ORPH.mp3")
    let transaction = try IpodCopyTransaction(fileSystem: fs)
    let staged = try transaction.stage(source: fileURL, destination: orphan)
    try transaction.publishJournal()
    try FileManager.default.moveItem(at: staged, to: orphan)

    var changes = TrackMetadataChanges()
    changes.genre = "Recovered"
    let edit = DeviceTrackMetadataEdit(dbid: track.dbid, metadata: TrackMetadata(track))
    try await DeviceManager().updateMetadata(
      for: [edit], on: device, applying: changes)

    #expect(!(FileManager.default.fileExists(atPath: orphan.path)))
    #expect((try fs.readDatabase().tracks.first?.genre) == ("Recovered"))
  }

  @Test
  func testSingleDeviceEditKeepsNewFileWhenDatabaseCommittedBeforeThrow() async throws {
    struct CommittedButReportedFailure: Error {}
    let manager = DeviceManager { fileSystem, database in
      try fileSystem.writeDatabase(database)
      throw CommittedButReportedFailure()
    }
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.title = "Committed title"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.title) == ("Committed title"))
    let committedFile = await MetadataLoader.load(url: fileURL)
    #expect((committedFile.title) == ("Committed title"))
  }

  @Test
  func testSingleDeviceEditRestoresOldFileWhenDatabaseDidNotCommit() async throws {
    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in throw UncommittedFailure() }
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.title = "Must roll back"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.title) == ("Original"))
    let restoredFile = await MetadataLoader.load(url: fileURL)
    #expect((restoredFile.title) == ("Original"))
  }

  @Test
  func testPreDatabaseMetadataFailureReportsFailedAudioRollback() async throws {
    struct InjectedRollbackFailure: Error {}
    let manager = DeviceManager(
      metadataModificationDate: { Date() },
      metadataDatabaseWriter: { try $0.writeDatabase($1) },
      metadataDatabaseVerificationReader: { try $0.readDatabase() },
      metadataRollbackWriter: { _, _ in throw InjectedRollbackFailure() })
    var changes = TrackMetadataChanges()
    changes.genre = "Must remain uncommitted"
    let missingDbid = track.dbid == UInt64.max ? track.dbid - 1 : track.dbid + 1
    let edits = [
      DeviceTrackMetadataEdit(dbid: track.dbid, metadata: TrackMetadata(track)),
      DeviceTrackMetadataEdit(dbid: missingDbid, metadata: TrackMetadata(track)),
    ]

    do {
      try await manager.updateMetadata(for: edits, on: device, applying: changes)
      Issue.record("the missing track and failed rollback must escape")
    } catch let error as DeviceMetadataMutationError {
      guard case .rollbackFailed(let operation, let failures) = error else {
        Issue.record("unexpected metadata error \(error)")
        return
      }
      #expect(operation is ITunesDBError, Comment(rawValue: "\(operation)"))
      #expect((failures.count) == (1))
      #expect((failures.first?.url) == (fileURL))
      #expect(failures.first?.error is InjectedRollbackFailure)
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.genre) == ("Rock"))
    let changedFile = await MetadataLoader.load(url: fileURL)
    #expect((changedFile.genre) == ("Must remain uncommitted"))
  }

  @Test
  func testDatabaseMetadataFailureReportsFailedReconciliationRollback() async throws {
    struct UncommittedFailure: Error {}
    struct InjectedRollbackFailure: Error {}
    let manager = DeviceManager(
      metadataModificationDate: { Date() },
      metadataDatabaseWriter: { _, _ in throw UncommittedFailure() },
      metadataDatabaseVerificationReader: { try $0.readDatabase() },
      metadataRollbackWriter: { _, _ in throw InjectedRollbackFailure() })
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.title = "Must remain uncommitted"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the database and failed rollback errors must escape")
    } catch let error as DeviceMetadataMutationError {
      guard case .rollbackFailed(let operation, let failures) = error else {
        Issue.record("unexpected metadata error \(error)")
        return
      }
      #expect(operation is UncommittedFailure, Comment(rawValue: "\(operation)"))
      #expect((failures.count) == (1))
      #expect((failures.first?.url) == (fileURL))
      #expect(failures.first?.error is InjectedRollbackFailure)
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.title) == ("Original"))
    let changedFile = await MetadataLoader.load(url: fileURL)
    #expect((changedFile.title) == ("Must remain uncommitted"))
  }

  @Test
  func testMetadataRollbackContinuesAfterEarlierRestorationFailure() async throws {
    struct UncommittedFailure: Error {}
    struct FirstRollbackFailure: Error {}
    let fs = IpodFileSystem(volumeURL: volume)
    let firstURL = try #require(fileURL)
    let secondURL = fs.musicDir.appendingPathComponent("F00/SECOND.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Second", artist: "Other Artist", album: "Other Album",
        genre: "Jazz", trackNumber: 2, year: 2001),
      seconds: 1
    ).write(to: secondURL)
    var second = ITDBTrack()
    second.title = "Second"
    second.artist = "Other Artist"
    second.album = "Other Album"
    second.genre = "Jazz"
    second.ipodPath = fs.ipodPath(for: secondURL)
    second.sizeBytes = UInt32(clamping: try Self.fileSize(at: secondURL))
    var database = try fs.readDatabase()
    database.tracks.append(second)
    try fs.writeDatabase(database)
    let firstOriginal = try Data(contentsOf: firstURL)
    let secondOriginal = try Data(contentsOf: secondURL)
    let rollbackAttempts = Mutex<[URL]>([])
    let manager = DeviceManager(
      metadataModificationDate: { Date() },
      metadataDatabaseWriter: { _, _ in throw UncommittedFailure() },
      metadataDatabaseVerificationReader: { try $0.readDatabase() },
      metadataRollbackWriter: { data, url in
        rollbackAttempts.withLock { $0.append(url) }
        if url == firstURL { throw FirstRollbackFailure() }
        try data.write(to: url, options: .atomic)
      })
    var changes = TrackMetadataChanges()
    changes.genre = "Must remain uncommitted"
    let edits = [
      DeviceTrackMetadataEdit(dbid: track.dbid, metadata: TrackMetadata(track)),
      DeviceTrackMetadataEdit(dbid: second.dbid, metadata: TrackMetadata(second)),
    ]

    do {
      try await manager.updateMetadata(for: edits, on: device, applying: changes)
      Issue.record("the database and first rollback errors must escape")
    } catch let error as DeviceMetadataMutationError {
      guard case .rollbackFailed(let operation, let failures) = error else {
        Issue.record("unexpected metadata error \(error)")
        return
      }
      #expect(operation is UncommittedFailure, Comment(rawValue: "\(operation)"))
      #expect((failures.count) == (1))
      #expect((failures.first?.url) == (firstURL))
      #expect(failures.first?.error is FirstRollbackFailure)
    }

    #expect((rollbackAttempts.withLock { $0 }) == ([firstURL, secondURL]))
    #expect((try Data(contentsOf: firstURL)) != (firstOriginal))
    #expect((try Data(contentsOf: secondURL)) == (secondOriginal))
    #expect((try fs.readDatabase().tracks.map(\.genre)) == (["Rock", "Jazz"]))
  }

  @Test
  func testSuccessfulMetadataRollbackPreservesOperationError() async throws {
    struct UncommittedFailure: Error {}
    let originalFile = try Data(contentsOf: fileURL)
    let rollbackCount = Mutex(0)
    let manager = DeviceManager(
      metadataModificationDate: { Date() },
      metadataDatabaseWriter: { _, _ in throw UncommittedFailure() },
      metadataDatabaseVerificationReader: { try $0.readDatabase() },
      metadataRollbackWriter: { data, url in
        rollbackCount.withLock { $0 += 1 }
        try data.write(to: url, options: .atomic)
      })
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.title = "Must roll back"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the database error must escape")
    } catch is UncommittedFailure {
    }

    #expect((rollbackCount.withLock { $0 }) == (1))
    #expect((try Data(contentsOf: fileURL)) == (originalFile))
  }

  @Test
  func testBulkDeviceEditKeepsNewFileWhenDatabaseCommittedBeforeThrow() async throws {
    struct CommittedButReportedFailure: Error {}
    let manager = DeviceManager { fileSystem, database in
      try fileSystem.writeDatabase(database)
      throw CommittedButReportedFailure()
    }
    var changes = TrackMetadataChanges()
    changes.genre = "Committed genre"
    let edits = [DeviceTrackMetadataEdit(dbid: track.dbid, metadata: TrackMetadata(track))]

    do {
      try await manager.updateMetadata(for: edits, on: device, applying: changes)
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.genre) == ("Committed genre"))
    let committedFile = await MetadataLoader.load(url: fileURL)
    #expect((committedFile.genre) == ("Committed genre"))
  }

  @Test
  func testBulkDeviceEditRestoresOldFileWhenDatabaseDidNotCommit() async throws {
    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in throw UncommittedFailure() }
    var changes = TrackMetadataChanges()
    changes.genre = "Must roll back"
    let edits = [DeviceTrackMetadataEdit(dbid: track.dbid, metadata: TrackMetadata(track))]

    do {
      try await manager.updateMetadata(for: edits, on: device, applying: changes)
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try IpodFileSystem(volumeURL: volume).readDatabase().tracks.first?.genre) == ("Rock"))
    let restoredFile = await MetadataLoader.load(url: fileURL)
    #expect((restoredFile.genre) == ("Rock"))
  }

  @Test
  func testFileOnlyDeviceEditRestoresExactBytesWhenDatabaseDidNotCommit() async throws {
    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in throw UncommittedFailure() }
    let originalFile = try Data(contentsOf: fileURL)
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.grouping = "Must roll back"
    metadata.bpm = 173
    metadata.lyrics = "These lyrics must roll back too"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try Data(contentsOf: fileURL)) == (originalFile))
    let databaseTrack = try #require(IpodFileSystem(volumeURL: volume).readDatabase().tracks.first)
    #expect(databaseTrack.timeModified == nil)
  }

  @Test
  func testArtworkDeviceEditRestoresExactBytesWhenDatabaseDidNotCommit() async throws {
    struct UncommittedFailure: Error {}
    let manager = DeviceManager { _, _ in throw UncommittedFailure() }
    let originalFile = try Data(contentsOf: fileURL)
    let artwork = Data([0x89, 0x50, 0x4E, 0x47, 40, 50, 60])
    let baseline = TrackMetadata(track)

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: baseline,
        artworkChange: .replace(artwork))
      Issue.record("the injected database error should be rethrown")
    } catch is UncommittedFailure {
    }

    #expect((try Data(contentsOf: fileURL)) == (originalFile))
    let databaseTrack = try #require(IpodFileSystem(volumeURL: volume).readDatabase().tracks.first)
    #expect(databaseTrack.timeModified == nil)
  }

  @Test
  func testFileOnlyDeviceEditKeepsFileWhenDatabaseCommittedBeforeThrow() async throws {
    struct CommittedButReportedFailure: Error {}
    let manager = DeviceManager { fileSystem, database in
      try fileSystem.writeDatabase(database)
      throw CommittedButReportedFailure()
    }
    let originalFile = try Data(contentsOf: fileURL)
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.grouping = "Committed grouping"
    metadata.bpm = 151
    metadata.lyrics = "Committed lyrics"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    #expect((try Data(contentsOf: fileURL)) != (originalFile))
    let committedFile = await MetadataLoader.load(url: fileURL)
    #expect((committedFile.grouping) == ("Committed grouping"))
    #expect((committedFile.bpm) == (151))
    #expect((committedFile.lyrics) == ("Committed lyrics"))
    let databaseTrack = try #require(IpodFileSystem(volumeURL: volume).readDatabase().tracks.first)
    #expect(databaseTrack.timeModified != nil)
  }

  @Test
  func testArtworkDeviceEditKeepsFileWhenDatabaseCommittedBeforeThrow() async throws {
    struct CommittedButReportedFailure: Error {}
    let manager = DeviceManager { fileSystem, database in
      try fileSystem.writeDatabase(database)
      throw CommittedButReportedFailure()
    }
    let originalFile = try Data(contentsOf: fileURL)
    let artwork = Data([0x89, 0x50, 0x4E, 0x47, 70, 80, 90])
    let baseline = TrackMetadata(track)

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: baseline,
        artworkChange: .replace(artwork))
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    let committedFile = try Data(contentsOf: fileURL)
    #expect((committedFile) != (originalFile))
    let artworkFrames = try MP3MetadataWriter.frames(in: committedFile)
      .filter { $0.id == "APIC" }
    #expect((artworkFrames.count) == (1))
    #expect(artworkFrames[0].payload.suffix(artwork.count) == artwork)
    let databaseTrack = try #require(IpodFileSystem(volumeURL: volume).readDatabase().tracks.first)
    #expect(databaseTrack.timeModified != nil)
  }

  @Test
  func testRapidFileOnlyEditAdvancesCommitMarkerWhenDatabaseCommittedBeforeThrow() async throws {
    struct CommittedButReportedFailure: Error {}
    let previousMarker: UInt32 = 4_000_000_000
    let previousDate = try installModificationMarker(previousMarker)
    let intendedState = Mutex<(file: Data?, marker: UInt32?)>((nil, nil))
    let targetURL = try #require(fileURL)
    let manager = DeviceManager(
      metadataModificationDate: { previousDate },
      metadataDatabaseWriter: { fileSystem, database in
        let intendedFile = try Data(contentsOf: targetURL)
        let intendedMarker = ITunesDBWriter.macTime(
          database.tracks.first?.timeModified, timezoneShift: database.timezoneShift)
        intendedState.withLock { $0 = (intendedFile, intendedMarker) }
        try fileSystem.writeDatabase(database)
        throw CommittedButReportedFailure()
      })
    let originalFile = try Data(contentsOf: targetURL)
    let baseline = TrackMetadata(track)
    var metadata = baseline
    metadata.grouping = "Committed rapid edit"

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: metadata,
        artworkChange: .unchanged)
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    let intended = intendedState.withLock { $0 }
    let committedFile = try Data(contentsOf: targetURL)
    #expect((committedFile) != (originalFile))
    #expect((committedFile) == (try #require(intended.file)))
    let committedDatabase = try IpodFileSystem(volumeURL: volume).readDatabase()
    let rereadMarker = ITunesDBWriter.macTime(
      committedDatabase.tracks.first?.timeModified,
      timezoneShift: committedDatabase.timezoneShift)
    #expect((try #require(intended.marker)) == (previousMarker + 1))
    #expect((rereadMarker) == (intended.marker))
  }

  @Test
  func testMaximumCommitMarkerWrapPreservesCommittedArtworkFile() async throws {
    try configureColorDevice()
    struct CommittedButReportedFailure: Error {}
    let previousDate = try installModificationMarker(UInt32.max)
    let intendedState = Mutex<(file: Data?, marker: UInt32?)>((nil, nil))
    let targetURL = try #require(fileURL)
    let manager = DeviceManager(
      metadataModificationDate: { previousDate },
      metadataDatabaseWriter: { fileSystem, database in
        let intendedFile = try Data(contentsOf: targetURL)
        let intendedMarker = ITunesDBWriter.macTime(
          database.tracks.first?.timeModified, timezoneShift: database.timezoneShift)
        intendedState.withLock { $0 = (intendedFile, intendedMarker) }
        try fileSystem.writeDatabase(database)
        throw CommittedButReportedFailure()
      })
    let originalFile = try Data(contentsOf: targetURL)
    let artwork = try pngData(red: 0, green: 0, blue: 1)
    let baseline = TrackMetadata(track)

    do {
      try await manager.updateMetadata(
        for: track, on: device, from: baseline, to: baseline,
        artworkChange: .replace(artwork))
      Issue.record("the injected late database error should be rethrown")
    } catch is CommittedButReportedFailure {
    }

    let intended = intendedState.withLock { $0 }
    let committedFile = try Data(contentsOf: targetURL)
    #expect((committedFile) != (originalFile))
    #expect((committedFile) == (try #require(intended.file)))
    let artworkFrames = try MP3MetadataWriter.frames(in: committedFile)
      .filter { $0.id == "APIC" }
    #expect((artworkFrames.count) == (1))
    #expect(artworkFrames[0].payload.suffix(artwork.count) == artwork)
    let committedDatabase = try IpodFileSystem(volumeURL: volume).readDatabase()
    let rereadMarker = ITunesDBWriter.macTime(
      committedDatabase.tracks.first?.timeModified,
      timezoneShift: committedDatabase.timezoneShift)
    #expect((intended.marker) == (1))
    #expect((rereadMarker) == (intended.marker))
  }

  @Test
  func testConcurrentDeletesSerializeWholeDatabaseMutation() async throws {
    let fs = IpodFileSystem(volumeURL: volume)
    let secondFile = fs.musicDir.appendingPathComponent("F00/NEXT.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Second", artist: "Artist", album: "Album", genre: "Rock",
        trackNumber: 2, year: 2000),
      seconds: 1
    ).write(to: secondFile)
    var secondTrack = ITDBTrack()
    secondTrack.title = "Second"
    secondTrack.artist = "Artist"
    secondTrack.ipodPath = fs.ipodPath(for: secondFile)

    var database = try fs.readDatabase()
    database.tracks.append(secondTrack)
    database.playlists[0].memberDbids.append(secondTrack.dbid)
    try fs.writeDatabase(database)
    let currentDevice = IpodDevice(
      volumeURL: volume, databaseID: database.databaseID, name: "Test iPod",
      modelDescription: "iPod",
      totalCapacity: 1_000_000, availableCapacity: 500_000,
      tracks: [track, secondTrack])
    let manager = DeviceManager()
    let firstTrackToDelete = try #require(track)
    let secondTrackToDelete = secondTrack

    async let firstDelete: Void = manager.delete(firstTrackToDelete, from: currentDevice)
    async let secondDelete: Void = manager.delete(secondTrackToDelete, from: currentDevice)
    try await firstDelete
    try await secondDelete

    let finalDatabase = try fs.readDatabase()
    #expect(finalDatabase.tracks.isEmpty)
    #expect(finalDatabase.playlists[0].memberDbids.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: fileURL.path)))
    #expect(!(FileManager.default.fileExists(atPath: secondFile.path)))
  }

  @Test
  func testValidatedTrackPathRejectsSymlinkEscape() throws {
    let outside = volume.deletingLastPathComponent().appendingPathComponent(
      "outside-\(UUID().uuidString).mp3")
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data([1, 2, 3]).write(to: outside)
    let link = IpodFileSystem(volumeURL: volume).musicDir.appendingPathComponent("F00/EVIL.mp3")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    #expect(throws: (any Error).self) {
      try IpodFileSystem(volumeURL: volume)
        .validatedMusicFileURL(forIpodPath: ":iPod_Control:Music:F00:EVIL.mp3")
    }
  }

  private func assertReloadedSizeCoherence(fileURL: URL, dbid: UInt64) throws {
    let diskSize = try Self.fileSize(at: fileURL)
    let database = try IpodFileSystem(volumeURL: volume).readDatabase()
    let storedTrack = try #require(database.tracks.first { $0.dbid == dbid })
    #expect((Int(storedTrack.sizeBytes)) == (diskSize))

    let reloadedDevice = DeviceManager.loadDevice(at: volume)
    let reloadedTrack = try #require(reloadedDevice.tracks.first { $0.dbid == dbid })
    #expect((Int(reloadedTrack.sizeBytes)) == (diskSize))
    #expect((reloadedDevice.usedByAudioBytes) == (database.tracks.reduce(Int64(0)) { $0 + Int64($1.sizeBytes) }))
    #expect((reloadedDevice.usedByAudioBytes) == (Int64(diskSize)))
  }

  private func installConcurrentLiveMetadata() async throws {
    let fs = IpodFileSystem(volumeURL: volume)
    var database = try fs.readDatabase()
    let index = try #require(database.tracks.firstIndex { $0.dbid == track.dbid })
    database.tracks[index].title = "Concurrent Title"
    database.tracks[index].artist = "Live Artist"
    database.tracks[index].album = "Live Album"
    database.tracks[index].genre = "Live Genre"
    database.tracks[index].comment = "Live Comment"
    try fs.writeDatabase(database)

    let loadedFile = await MetadataLoader.load(url: fileURL)
    var metadata = TrackMetadata(loadedFile)
    metadata.title = "Concurrent Title"
    metadata.artist = "Live Artist"
    metadata.album = "Live Album"
    metadata.genre = "Live Genre"
    metadata.comment = "Live Comment"
    metadata.grouping = "Live Grouping"
    metadata.bpm = 155
    metadata.lyrics = "Live Lyrics"
    try MP3MetadataWriter.write(metadata, to: fileURL)
  }

  private func assertConcurrentDatabaseMetadata(title: String) throws {
    let stored = try #require(IpodFileSystem(volumeURL: volume).readDatabase().tracks.first)
    #expect((stored.title) == (title))
    #expect((stored.artist) == ("Live Artist"))
    #expect((stored.album) == ("Live Album"))
    #expect((stored.genre) == ("Live Genre"))
    #expect((stored.comment) == ("Live Comment"))
  }

  private func assertConcurrentFileMetadata(_ loaded: LibraryTrack, title: String) {
    #expect((loaded.title) == (title))
    #expect((loaded.artist) == ("Live Artist"))
    #expect((loaded.album) == ("Live Album"))
    #expect((loaded.genre) == ("Live Genre"))
    #expect((loaded.comment) == ("Live Comment"))
    #expect((loaded.grouping) == ("Live Grouping"))
    #expect((loaded.bpm) == (155))
    #expect((loaded.lyrics) == ("Live Lyrics"))
  }

  nonisolated private static func fileSize(at url: URL) throws -> Int {
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      throw CocoaError(.fileReadUnknown)
    }
    return size
  }

  private func artworkData(size: Int) -> Data {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data.append(Data(repeating: 0x5A, count: size))
    return data
  }

  private func minimalMetadata(title: String) -> TrackMetadata {
    TrackMetadata(
      title: title, artist: "", album: "", albumArtist: "", composer: "", genre: "",
      grouping: "", year: 0, bpm: 0, trackNumber: 0, trackCount: 0, discNumber: 0,
      discCount: 0, comment: "", lyrics: "", compilation: false)
  }

  private func installModificationMarker(_ marker: UInt32) throws -> Date {
    let fs = IpodFileSystem(volumeURL: volume)
    var database = try fs.readDatabase()
    let unixTime =
      Int64(marker) - Int64(ITunesDBWriter.macEpochOffset) - Int64(database.timezoneShift)
    database.tracks[0].timeModified = Date(timeIntervalSince1970: TimeInterval(unixTime))
    try fs.writeDatabase(database)

    let reread = try fs.readDatabase()
    let rereadTrack = try #require(reread.tracks.first)
    #expect(
      (ITunesDBWriter.macTime(
        rereadTrack.timeModified, timezoneShift: reread.timezoneShift)) == (marker))
    return try #require(rereadTrack.timeModified)
  }

  private func configureColorDevice() throws {
    let fs = IpodFileSystem(volumeURL: volume)
    try Data("ModelNumStr: xM9585\n".utf8).write(to: fs.sysInfoURL)
  }

  private func otherDevice(named name: String) -> IpodDevice {
    IpodDevice(
      volumeURL: volume.deletingLastPathComponent().appendingPathComponent(
        "\(name)-\(UUID().uuidString)", isDirectory: true),
      name: name,
      modelDescription: "iPod",
      totalCapacity: 1_000_000,
      availableCapacity: 500_000)
  }

  private func waitForSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await waitUntil { isSignaled(semaphore) }
  }

  private nonisolated func isSignaled(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now()) == .success
  }

  private func artworkTransactionDirectories(fileSystem fs: IpodFileSystem) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
  }
}
