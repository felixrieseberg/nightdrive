import CoreGraphics
import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct ArtworkDBTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture(modelNumber: "M9585")
  }

  private func makeLibraryMP3(
    title: String, artist: String, album: String, artwork: Data?
  ) async throws -> LibraryTrack {
    let data = MP3Builder.build(
      tags: .init(
        title: title, artist: artist, album: album,
        genre: "Rock", trackNumber: 1, year: 2004, artwork: artwork),
      seconds: 2)
    let url = libraryDir.appendingPathComponent("\(artist) - \(title).mp3")
    try data.write(to: url)
    return await MetadataLoader.load(url: url)
  }

  private func seedITunesManagedArtwork(
    title: String = "Managed Song", artist: String = "Managed Artist", count: UInt16 = 1
  ) throws -> (track: ITDBTrack, specs: [ArtworkImageSpec], tileData: [String: Data]) {
    var track = try putTrackOnIpod(title: title, artist: artist, trackNumber: 1)
    let specs = try requireArtworkSpecs(modelNumber: modelNumber)
    let assignments = try ArtworkDBWriter.write(
      images: [
        ArtworkImage(dbid: track.dbid, data: pngData(red: 0, green: 0, blue: 1))
      ],
      specs: specs, fileSystem: fs)
    let assignment = try #require(assignments[track.dbid])
    track.artwork = ITDBTrackArtwork(
      mhiiID: assignment.mhiiID, sizeBytes: assignment.sourceImageSize, count: count)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let tileData = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })
    return (track, specs, tileData)
  }

  @Test
  func testRGB565PacksKnownColors() {
    #expect((ArtworkPixels.rgb565(r: 255, g: 0, b: 0)) == (0xF800))
    #expect((ArtworkPixels.rgb565(r: 0, g: 255, b: 0)) == (0x07E0))
    #expect((ArtworkPixels.rgb565(r: 0, g: 0, b: 255)) == (0x001F))
    #expect((ArtworkPixels.rgb565(r: 255, g: 255, b: 255)) == (0xFFFF))
    #expect((ArtworkPixels.rgb565(r: 0, g: 0, b: 0)) == (0x0000))
  }

  @Test
  func testAspectFitRectLetterboxesWithoutDistortion() {
    let wide = ArtworkPixels.aspectFitRect(
      imageSize: CGSize(width: 200, height: 100), in: CGSize(width: 56, height: 56))
    #expect(abs((wide.width) - (56)) <= 0.001)
    #expect(abs((wide.height) - (28)) <= 0.001)
    #expect(abs((wide.minX) - (0)) <= 0.001)
    #expect(abs((wide.midY) - (28)) <= 0.001)
    let tall = ArtworkPixels.aspectFitRect(
      imageSize: CGSize(width: 100, height: 400), in: CGSize(width: 56, height: 56))
    #expect(abs((tall.height) - (56)) <= 0.001)
    #expect(abs((tall.width) - (14)) <= 0.001)
    #expect(abs((tall.midX) - (28)) <= 0.001)
    #expect(abs((wide.width / wide.height) - (2)) <= 0.001)
    #expect(abs((tall.height / tall.width) - (4)) <= 0.001)
  }

  @Test
  func testTileDataUsesSpecEndianness() throws {
    let image = try #require(solidImage(red: 1, green: 0, blue: 0, width: 8, height: 8))
    let little = ArtworkPixels.tileData(
      image: image,
      spec: ArtworkImageSpec(formatID: 1017, width: 4, height: 4, bigEndian: false))
    #expect((little.count) == (4 * 4 * 2))
    #expect((Array(little.prefix(2))) == ([0x00, 0xF8]))
    let big = ArtworkPixels.tileData(
      image: image,
      spec: ArtworkImageSpec(formatID: 1061, width: 4, height: 4, bigEndian: true))
    #expect((Array(big.prefix(2))) == ([0xF8, 0x00]))
  }

  @Test
  func testStaticTableCoversFakeDeviceAndRejectsUnknownModels() {
    let photo = ArtworkFormats.staticSpecs(modelNumber: "M9585")
    #expect((photo?.map(\.formatID).sorted()) == ([1016, 1017]))
    #expect((ArtworkFormats.staticSpecs(modelNumber: "M9282")) == ([]))
    #expect(ArtworkFormats.staticSpecs(modelNumber: "Z9999") == nil)
  }

  @Test
  func testSysInfoExtendedSpecsAreAuthoritative() throws {
    let plist: [String: Any] = [
      "AlbumArt": [
        [
          "FormatId": 1060, "RenderWidth": 320, "RenderHeight": 320,
          "PixelFormat": "42353635",
        ],
        [
          "FormatId": 1055, "RenderWidth": 128, "RenderHeight": 128,
          "PixelFormat": "4C353635",
        ],
        [
          "FormatId": 1064, "RenderWidth": 320, "RenderHeight": 240,
          "PixelFormat": "55595659",
        ],
      ]
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    let specs = try #require(ArtworkFormats.specsFromSysInfoExtended(data))
    #expect((specs.count) == (2))
    #expect((specs[0].formatID) == (1060))
    #expect(specs[0].bigEndian)
    #expect((specs[1].formatID) == (1055))
    #expect(!(specs[1].bigEndian))
    try data.write(to: fs.sysInfoExtendedURL)
    guard case .specs(let resolved) = ArtworkFormats.resolve(fileSystem: fs) else {
      Issue.record("expected specs")
      return
    }
    #expect((resolved.map(\.formatID)) == ([1060, 1055]))
  }

  @Test
  func testArtworkDBRoundTripsImageList() throws {
    let specs = try requireArtworkSpecs()
    let coverA = try pngData(red: 1, green: 0, blue: 0)
    let coverB = try pngData(red: 0, green: 0, blue: 1)
    let images = [
      ArtworkImage(dbid: 0x1111, data: coverA),
      ArtworkImage(dbid: 0x2222, data: coverA),
      ArtworkImage(dbid: 0x3333, data: coverB),
    ]
    let assignments = try ArtworkDBWriter.write(images: images, specs: specs, fileSystem: fs)
    #expect((assignments.count) == (3))

    let parsed = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((parsed.count) == (3))
    #expect((Set(parsed.map(\.trackDbid))) == ([0x1111, 0x2222, 0x3333]))
    for image in parsed {
      let assignment = try #require(assignments[image.trackDbid])
      #expect((image.mhiiID) == (assignment.mhiiID))
      #expect((image.sourceImageSize) == (assignment.sourceImageSize))
      #expect((image.thumbnails.count) == (specs.count))
      for (thumbnail, spec) in zip(image.thumbnails, specs) {
        #expect((thumbnail.formatID) == (spec.formatID))
        #expect((thumbnail.width) == (spec.width))
        #expect((thumbnail.height) == (spec.height))
        #expect((thumbnail.imageSize) == (UInt32(spec.bytesPerTile)))
        #expect((thumbnail.fileName) == (":" + spec.ithmbName))
        #expect((Int(thumbnail.ithmbOffset) % spec.bytesPerTile) == (0))
      }
    }
    let offsets = { (dbid: UInt64) -> UInt32 in
      parsed.first { $0.trackDbid == dbid }!.thumbnails[0].ithmbOffset
    }
    #expect((offsets(0x1111)) == (offsets(0x2222)))
    #expect((offsets(0x1111)) != (offsets(0x3333)))
    for spec in specs {
      let size =
        try FileManager.default.attributesOfItem(
          atPath: fs.ithmbURL(for: spec).path)[.size] as? Int
      #expect((size) == (2 * spec.bytesPerTile), Comment(rawValue: "\(spec.ithmbName)"))
    }
  }

  @Test
  func testArtworkDBRejectsImageCountThatCannotFitBeforeReservingStorage() throws {
    let specs = try requireArtworkSpecs()
    _ = try ArtworkDBWriter.write(images: [], specs: specs, fileSystem: fs)
    var data = try Data(contentsOf: fs.artworkDBURL)
    let mhliTag = Data("mhli".utf8)
    let mhli = try #require(data.range(of: mhliTag)?.lowerBound)
    DBBytes.patchU32(&data, at: mhli + 8, 1_000_000)

    do {
      let caughtError = #expect(throws: (any Error).self) { try ArtworkDBReader.read(data) }
      if let caughtError {
        #expect(
          caughtError.localizedDescription.contains("exceeds mhli bounds"),
          Comment(rawValue: "unexpected caughtError \(caughtError)"))
      }
    }
  }

  @Test
  func testArtworkDBCapacityEstimateFallsBackToZeroOnOverflow() {
    #expect((ArtworkDBWriter.estimatedCapacity(recordCount: 2, specCount: 3)) == (1_024 + 2 * (256 + 3 * 192)))
    #expect((ArtworkDBWriter.estimatedCapacity(recordCount: Int.max, specCount: 1)) == (0))
    #expect((ArtworkDBWriter.estimatedCapacity(recordCount: 1, specCount: Int.max)) == (0))
  }

  @Test
  func testArtworkDBWriteKeepsBackupOfPreviousDatabase() throws {
    let specs = try requireArtworkSpecs()
    let coverA = try pngData(red: 1, green: 0, blue: 0)
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: coverA)], specs: specs, fileSystem: fs)
    let first = try Data(contentsOf: fs.artworkDBURL)
    let coverB = try pngData(red: 0, green: 1, blue: 0)
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: coverB)], specs: specs, fileSystem: fs)
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (first))
    #expect((try Data(contentsOf: fs.artworkDBURL)) != (first))
  }

  @Test
  func testArtworkDBCommitRetainsTransactionWhenBackupReadFails() throws {
    let specs = try requireArtworkSpecs()
    try FileManager.default.createDirectory(
      at: fs.artworkDir, withIntermediateDirectories: true)
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 1, green: 0, blue: 0))],
      specs: specs, fileSystem: fs)
    let previousDatabase = try Data(contentsOf: fs.artworkDBURL)
    let write = try ArtworkDBWriter.beginWrite(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 0, green: 1, blue: 0))],
      specs: specs, fileSystem: fs)

    struct InjectedBackupReadFailure: Error {}
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try write.transaction.commit(backupReader: { _ in throw InjectedBackupReadFailure() })
      }
      if let caughtError {
        #expect(caughtError is InjectedBackupReadFailure, Comment(rawValue: "\(caughtError)"))
      }
    }
    #expect(FileManager.default.fileExists(atPath: write.transaction.recoveryDirectory.path))
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDBBackupURL.path)))

    try write.transaction.commit()
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousDatabase))
    #expect(!(FileManager.default.fileExists(atPath: write.transaction.recoveryDirectory.path)))
  }

  @Test
  func testArtworkDBCommitRetainsTransactionWhenBackupWriteFails() throws {
    let specs = try requireArtworkSpecs()
    try FileManager.default.createDirectory(
      at: fs.artworkDir, withIntermediateDirectories: true)
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 1, green: 0, blue: 0))],
      specs: specs, fileSystem: fs)
    let previousDatabase = try Data(contentsOf: fs.artworkDBURL)
    let existingBackup = Data("older artwork backup".utf8)
    try existingBackup.write(to: fs.artworkDBBackupURL)
    let write = try ArtworkDBWriter.beginWrite(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 0, green: 1, blue: 0))],
      specs: specs, fileSystem: fs)

    struct InjectedBackupWriteFailure: Error {}
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try write.transaction.commit(
          backupWriter: { _, _ in throw InjectedBackupWriteFailure() })
      }
      if let caughtError {
        #expect(caughtError is InjectedBackupWriteFailure, Comment(rawValue: "\(caughtError)"))
      }
    }
    #expect(FileManager.default.fileExists(atPath: write.transaction.recoveryDirectory.path))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (existingBackup))

    try write.transaction.commit()
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousDatabase))
    #expect(!(FileManager.default.fileExists(atPath: write.transaction.recoveryDirectory.path)))
  }

  @Test
  func testPartialArtworkInstallationRestoresCompletePreviousGeneration() throws {
    let specs = try requireArtworkSpecs()
    let originalCover = try pngData(red: 1, green: 0, blue: 0)
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: originalCover)], specs: specs, fileSystem: fs)

    let originalDatabase = try Data(contentsOf: fs.artworkDBURL)
    let originalTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })
    let existingBackup = Data("older artwork backup".utf8)
    try existingBackup.write(to: fs.artworkDBBackupURL)

    struct InjectedInstallFailure: Error {}
    var checkpointCount = 0
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ArtworkDBWriter.beginWrite(
          images: [
            ArtworkImage(dbid: 1, data: pngData(red: 0, green: 1, blue: 0))
          ], specs: specs, fileSystem: fs,
          installationCheckpoint: { _ in
            checkpointCount += 1
            if checkpointCount == 2 { throw InjectedInstallFailure() }
          })
      }
      if let caughtError {
        #expect(caughtError is InjectedInstallFailure, Comment(rawValue: "\(caughtError)"))
      }
    }

    #expect((checkpointCount) == (2), Comment(rawValue: "one tile must install before the injected failure"))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (originalDatabase))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (existingBackup))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (originalTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
    #expect((leftovers) == ([]))
  }

  @Test
  func testFailureBetweenPreviousAndLiveMovesRestoresPreviousGeneration() throws {
    let specs = try requireArtworkSpecs()
    _ = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 1, green: 0, blue: 0))],
      specs: specs, fileSystem: fs)
    let originalDatabase = try Data(contentsOf: fs.artworkDBURL)
    let originalTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })

    struct InjectedMoveGapFailure: Error {}
    var injected = false
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ArtworkDBWriter.beginWrite(
          images: [ArtworkImage(dbid: 1, data: pngData(red: 0, green: 1, blue: 0))],
          specs: specs, fileSystem: fs,
          afterPreviousMoved: { _ in
            guard !injected else { return }
            injected = true
            throw InjectedMoveGapFailure()
          })
      }
      if let caughtError {
        #expect(caughtError is InjectedMoveGapFailure, Comment(rawValue: "\(caughtError)"))
      }
    }

    #expect(injected)
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (originalDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (originalTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testArtworkWriteRejectsEscapingArtworkDirectorySymlink() throws {
    let outside = libraryDir.appendingPathComponent("outside-artwork", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let sentinel = outside.appendingPathComponent("sentinel")
    try Data("preserve me".utf8).write(to: sentinel)
    try FileManager.default.createSymbolicLink(at: fs.artworkDir, withDestinationURL: outside)

    #expect(throws: (any Error).self) {
      try ArtworkDBWriter.write(
        images: [ArtworkImage(dbid: 1, data: pngData(red: 1, green: 0, blue: 0))],
        specs: requireArtworkSpecs(),
        fileSystem: fs)
    }
    #expect((try Data(contentsOf: sentinel)) == (Data("preserve me".utf8)))
    #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)) == (["sentinel"]))
  }

  @Test
  func testMhitArtworkFieldsRoundTrip() throws {
    var db = ITunesDatabase()
    var withArt = ITDBTrack()
    withArt.title = "Covered"
    withArt.ipodPath = ":iPod_Control:Music:F00:covered.mp3"
    withArt.artwork = ITDBTrackArtwork(mhiiID: 0x40, sizeBytes: 1234)
    var withoutArt = ITDBTrack()
    withoutArt.title = "Bare"
    withoutArt.ipodPath = ":iPod_Control:Music:F00:bare.mp3"
    db.tracks = [withArt, withoutArt]
    try fs.writeDatabase(db)

    let read = try fs.readDatabase()
    let covered = try #require(read.tracks.first { $0.title == "Covered" })
    #expect((covered.artwork) == (ITDBTrackArtwork(mhiiID: 0x40, sizeBytes: 1234)))
    let bare = try #require(read.tracks.first { $0.title == "Bare" })
    #expect(bare.artwork == nil)

    var preserved = read
    #expect(preserved.tracks.first?.preservedMhitHeader != nil)
    for index in preserved.tracks.indices { preserved.tracks[index].artwork = nil }
    try fs.writeDatabase(preserved)
    let untouched = try fs.readDatabase()
    #expect(
      (untouched.tracks.first { $0.title == "Covered" }?.artwork) == (ITDBTrackArtwork(mhiiID: 0x40, sizeBytes: 1234)))

    var cleared = untouched
    for index in cleared.tracks.indices { cleared.tracks[index].artwork = .cleared }
    try fs.writeDatabase(cleared)
    let afterClear = try fs.readDatabase()
    for track in afterClear.tracks {
      #expect(track.artwork == nil, Comment(rawValue: "\(track.title ?? "?") should have no artwork"))
    }
  }

  @Test
  func testForeignMultiCoverCountSurvivesPreservedRewrites() throws {
    var db = ITunesDatabase()
    var foreign = ITDBTrack()
    foreign.title = "Foreign"
    foreign.ipodPath = ":iPod_Control:Music:F00:foreign.mp3"
    foreign.artwork = ITDBTrackArtwork(mhiiID: 0x77, sizeBytes: 4321, count: 3)
    db.tracks = [foreign]
    try fs.writeDatabase(db)

    let read = try fs.readDatabase()
    #expect((read.tracks.first?.artwork) == (ITDBTrackArtwork(mhiiID: 0x77, sizeBytes: 4321, count: 3)))

    var preserved = read
    #expect(preserved.tracks.first?.preservedMhitHeader != nil)
    preserved.tracks[0].artwork = nil
    try fs.writeDatabase(preserved)
    #expect(
      (try fs.readDatabase().tracks.first?.artwork) == (ITDBTrackArtwork(mhiiID: 0x77, sizeBytes: 4321, count: 3)))

    var relinked = try fs.readDatabase()
    let parsedArtwork = try #require(relinked.tracks[0].artwork)
    relinked.tracks[0].artwork = parsedArtwork
    try fs.writeDatabase(relinked)
    #expect(
      (try fs.readDatabase().tracks.first?.artwork) == (ITDBTrackArtwork(mhiiID: 0x77, sizeBytes: 4321, count: 3)))
  }

  @Test
  func testFirstInboundSyncPreservesExactForeignLinkWhenDbidHasMultipleImages()
    async throws
  {
    var track = try putTrackOnIpod(
      title: "Managed Song", artist: "Managed Artist", trackNumber: 1)
    let specs = try requireArtworkSpecs(modelNumber: modelNumber)
    let linkedCover = try pngData(red: 0, green: 0, blue: 1)
    let alternateCover = try pngData(red: 0, green: 1, blue: 0, width: 80)
    _ = try ArtworkDBWriter.write(
      images: [
        ArtworkImage(dbid: track.dbid, data: linkedCover),
        ArtworkImage(dbid: track.dbid, data: alternateCover),
      ],
      specs: specs, fileSystem: fs)
    let parsedBefore = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((parsedBefore.map(\.trackDbid)) == ([track.dbid, track.dbid]))
    let linkedImage = try #require(parsedBefore.first)
    let alternateImage = try #require(parsedBefore.last)
    #expect((linkedImage.mhiiID) != (alternateImage.mhiiID))

    track.artwork = ITDBTrackArtwork(
      mhiiID: linkedImage.mhiiID, sizeBytes: linkedImage.sourceImageSize, count: 3)
    var database = ITunesDatabase()
    database.tracks = [track]
    try fs.writeDatabase(database)
    let expectedLink = try #require(fs.readDatabase().tracks.first?.artwork)
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let tiles = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })

    let before = try fs.readDatabase()
    let result = try await runSync(SyncEngine.makePlan(library: [], device: before.tracks))
    #expect((result.failures) == ([]))
    #expect((result.copiedToFolder) == (1))
    #expect((result.artworkImagesWritten) == (0))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (expectedLink))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (tiles[spec.ithmbName]), Comment(rawValue: spec.ithmbName))
    }

    let localURL = try #require(LibraryStore.findAudioFiles(in: libraryDir).first)
    try writeLibraryMP3(
      filename: localURL.lastPathComponent, title: "Managed Song", artist: "Managed Artist",
      album: "Device Album", genre: "Pop", trackNumber: 1, seconds: 4)
    let replacementPlan = try await makePlan()
    #expect((replacementPlan.updateOnDevice.count) == (1))
    let replacement = try await runSync(replacementPlan)
    #expect((replacement.failures) == ([]))
    #expect((replacement.updatedOnDevice) == (1))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (expectedLink))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
  }

  @Test
  func testUndecodableKnownReplacementRollsBackBeforeDatabaseAssignment() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let redCover = try pngData(red: 1, green: 0, blue: 0)
    _ = try await makeLibraryMP3(
      title: "Known", artist: "Local Artist", album: "Local Album", artwork: redCover)
    _ = try await runSync(try await makePlan())

    let before = try fs.readDatabase()
    let expectedArtwork = try #require(before.tracks.first?.artwork)
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let specs = try requireArtworkSpecs(modelNumber: modelNumber)
    let tiles = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })
    let originalEntry = try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first)

    let invalidPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
    let replacement = try await makeLibraryMP3(
      title: "Known", artist: "Local Artist", album: "Local Album", artwork: invalidPNG)
    let extractedArtwork = await MetadataLoader.loadArtwork(url: replacement.url)
    #expect((extractedArtwork) == (invalidPNG))
    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))

    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.updatedOnDevice) == (1))
    #expect((result.artworkImagesWritten) == (0))
    #expect((result.artworkNotes.count) == (1))
    #expect(result.artworkNotes[0].contains("deferred"))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (expectedArtwork))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (tiles[spec.ithmbName]), Comment(rawValue: spec.ithmbName))
    }
    let pendingEntry = try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first)
    #expect((pendingEntry.artworkSHA256) == (originalEntry.artworkSHA256))
    #expect((pendingEntry.contentSHA256) == (originalEntry.contentSHA256))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testFirstInboundSyncPreservesITunesManagedArtworkMissingFromAudio() async throws {
    let seeded = try seedITunesManagedArtwork(count: 3)
    let deviceFile = try fs.validatedMusicFileURL(
      forIpodPath: try #require(seeded.track.ipodPath))
    let deviceArtwork = await MetadataLoader.loadArtwork(url: deviceFile)
    #expect(deviceArtwork == nil)
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)

    let before = try fs.readDatabase()
    let result = try await runSync(SyncEngine.makePlan(library: [], device: before.tracks))
    #expect((result.failures) == ([]))
    #expect((result.copiedToFolder) == (1))
    #expect((result.artworkImagesWritten) == (0))

    let local = try #require(LibraryStore.findAudioFiles(in: libraryDir).first)
    let localArtwork = await MetadataLoader.loadArtwork(url: local)
    #expect(localArtwork == nil)
    let after = try fs.readDatabase()
    #expect((after.tracks.first?.artwork) == (seeded.track.artwork))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in seeded.specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (seeded.tileData[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    let entry = try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first)
    #expect(entry.artworkSHA256 == nil)

    let secondResult = try await runSync(SyncEngine.makePlan(library: await scanLibrary(), device: after.tracks))
    #expect((secondResult.failures) == ([]))
    #expect((secondResult.artworkImagesWritten) == (0))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (seeded.track.artwork))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    #expect(
      try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first).artworkSHA256
        == nil)

    try writeLibraryMP3(
      filename: local.lastPathComponent, title: "Managed Song", artist: "Managed Artist",
      album: "Device Album", genre: "Pop", trackNumber: 1, seconds: 4)
    let thirdResult = try await runSync(
      SyncEngine.makePlan(
        library: await scanLibrary(), device: try fs.readDatabase().tracks))
    #expect((thirdResult.failures) == ([]))
    #expect((thirdResult.updatedOnDevice) == (1))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (seeded.track.artwork))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    #expect(
      try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first).artworkSHA256
        == nil)
  }

  @Test
  func testFirstAdoptedPairPreservesITunesManagedArtworkMissingFromLocalAudio()
    async throws
  {
    let seeded = try seedITunesManagedArtwork()
    try writeLibraryMP3(
      filename: "managed.mp3", title: "Managed Song", artist: "Managed Artist",
      album: "Device Album", genre: "Pop", trackNumber: 1)
    let before = try fs.readDatabase()
    let plan = SyncEngine.makePlan(library: await scanLibrary(), device: before.tracks)
    #expect((plan.adoptedPairs.count) == (1))
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)

    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.artworkImagesWritten) == (0))
    #expect((try fs.readDatabase().tracks.first?.artwork) == (seeded.track.artwork))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in seeded.specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (seeded.tileData[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    let entry = try #require(SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir).first)
    #expect(entry.artworkSHA256 == nil)
  }

  @Test
  func testArtworkRebuildDefersWhileITunesManagedCoverCannotBeReconstructed()
    async throws
  {
    let seeded = try seedITunesManagedArtwork()
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    _ = try await makeLibraryMP3(
      title: "New Cover", artist: "Local Artist", album: "Local Album",
      artwork: pngData(red: 0, green: 1, blue: 0))
    let before = try fs.readDatabase()

    let result = try await runSync(SyncEngine.makePlan(library: await scanLibrary(), device: before.tracks))
    #expect((result.failures) == ([]))
    #expect((result.copiedToFolder) == (1))
    #expect((result.copiedToDevice) == (1))
    #expect((result.artworkImagesWritten) == (0))
    #expect((result.artworkNotes.count) == (1))
    #expect(result.artworkNotes[0].contains("deferred"), Comment(rawValue: "\(result.artworkNotes)"))

    let after = try fs.readDatabase()
    #expect((after.tracks.first { $0.dbid == seeded.track.dbid }?.artwork) == (seeded.track.artwork))
    #expect(after.tracks.first { $0.title == "New Cover" }?.artwork == nil)
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in seeded.specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (seeded.tileData[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    let entries = SyncLedgerStore.entries(
      for: before.databaseID, libraryFolder: libraryDir)
    #expect(entries.allSatisfy { $0.artworkSHA256 == nil })
    #expect(
      (Set(ArtworkDatabaseLink.links(in: after).map(\.dbid)))
        == (Set(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).map(\.trackDbid))))

    let secondResult = try await runSync(SyncEngine.makePlan(library: await scanLibrary(), device: after.tracks))
    #expect((secondResult.failures) == ([]))
    #expect((secondResult.artworkImagesWritten) == (0))
    #expect((secondResult.artworkNotes.count) == (1))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testDeferredKnownCoverChangeRemainsPendingBesideITunesManagedCover()
    async throws
  {
    try fs.writeDatabase(ITunesDatabase())
    let redCover = try pngData(red: 1, green: 0, blue: 0)
    _ = try await makeLibraryMP3(
      title: "Known", artist: "Local Artist", album: "Local Album", artwork: redCover)
    _ = try await runSync(try await makePlan())

    var database = try fs.readDatabase()
    let knownDbid = try #require(database.tracks.first?.dbid)
    let originalEntry = try #require(SyncLedgerStore.entries(for: database.databaseID, libraryFolder: libraryDir).first)
    #expect((originalEntry.artworkSHA256) == (ArtworkPixels.sha256Hex(redCover)))

    var foreign = try putTrackOnIpod(title: "Foreign", artist: "Managed Artist")
    let specs = try requireArtworkSpecs(modelNumber: modelNumber)
    let assignments = try ArtworkDBWriter.write(
      images: [
        ArtworkImage(dbid: knownDbid, data: redCover),
        ArtworkImage(dbid: foreign.dbid, data: pngData(red: 0, green: 0, blue: 1)),
      ], specs: specs, fileSystem: fs)
    let knownAssignment = try #require(assignments[knownDbid])
    database.tracks[0].artwork = ITDBTrackArtwork(
      mhiiID: knownAssignment.mhiiID, sizeBytes: knownAssignment.sourceImageSize)
    let foreignAssignment = try #require(assignments[foreign.dbid])
    foreign.artwork = ITDBTrackArtwork(
      mhiiID: foreignAssignment.mhiiID, sizeBytes: foreignAssignment.sourceImageSize)
    database.tracks.append(foreign)
    try fs.writeDatabase(database)
    let artworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let tileData = try Dictionary(
      uniqueKeysWithValues: specs.map {
        ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0)))
      })

    _ = try await makeLibraryMP3(
      title: "Known", artist: "Local Artist", album: "Local Album",
      artwork: pngData(red: 0, green: 1, blue: 0, width: 80))
    let firstPlan = try await makePlan()
    #expect((firstPlan.updateOnDevice.count) == (1))
    #expect((firstPlan.copyToFolder.count) == (1))
    let firstResult = try await runSync(firstPlan)
    #expect((firstResult.failures) == ([]))
    #expect((firstResult.updatedOnDevice) == (1))
    #expect((firstResult.copiedToFolder) == (1))
    #expect((firstResult.artworkImagesWritten) == (0))
    #expect((firstResult.artworkNotes.count) == (1))
    #expect(firstResult.artworkNotes[0].contains("deferred"))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (tileData[spec.ithmbName]), Comment(rawValue: spec.ithmbName))
    }

    let afterFirst = try fs.readDatabase()
    #expect(
      (Set(ArtworkDatabaseLink.links(in: afterFirst).map(\.dbid)))
        == (Set(try ArtworkDBReader.read(artworkDatabase).map(\.trackDbid))))
    let pendingEntry = try #require(
      SyncLedgerStore.entries(for: afterFirst.databaseID, libraryFolder: libraryDir)
        .first { $0.dbid == knownDbid })
    #expect((pendingEntry.artworkSHA256) == (originalEntry.artworkSHA256))
    #expect((pendingEntry.contentSHA256) == (originalEntry.contentSHA256))

    let retryPlan = try await makePlan()
    #expect((retryPlan.updateOnDevice.count) == (1))
    let retryResult = try await runSync(retryPlan)
    #expect((retryResult.failures) == ([]))
    #expect((retryResult.updatedOnDevice) == (1))
    #expect((retryResult.artworkNotes.count) == (1))
    #expect(retryResult.artworkNotes[0].contains("deferred"))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (artworkDatabase))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testSyncWritesArtworkOnceAndSkipsRebuildWhenUnchanged() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let sharedCover = try pngData(red: 1, green: 0, blue: 0)
    let library = try await [
      makeLibraryMP3(title: "Alpha", artist: "Band", album: "One", artwork: sharedCover),
      makeLibraryMP3(title: "Beta", artist: "Band", album: "One", artwork: sharedCover),
      makeLibraryMP3(
        title: "Gamma", artist: "Band", album: "Two",
        artwork: pngData(red: 0, green: 0, blue: 1)),
      makeLibraryMP3(title: "Plain", artist: "Band", album: "Three", artwork: nil),
    ]

    let plan = SyncEngine.makePlan(library: library, device: [])
    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.artworkImagesWritten) == (3))
    #expect((result.artworkNotes) == ([]))

    let after = try fs.readDatabase()
    let parsed = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((parsed.count) == (3))
    for title in ["Alpha", "Beta", "Gamma"] {
      let track = try #require(after.tracks.first { $0.title == title })
      let artwork = try #require(track.artwork, Comment(rawValue: title))
      #expect((parsed.first { $0.trackDbid == track.dbid }?.mhiiID) == (artwork.mhiiID), Comment(rawValue: title))
    }
    #expect(after.tracks.first { $0.title == "Plain" }?.artwork == nil)

    let specs = try requireArtworkSpecs()
    for spec in specs {
      let size =
        try FileManager.default.attributesOfItem(
          atPath: fs.ithmbURL(for: spec).path)[.size] as? Int
      #expect((size) == (2 * spec.bytesPerTile))
    }

    let artworkDBDate = try modificationDate(of: fs.artworkDBURL)
    let ithmbDate = try modificationDate(of: fs.ithmbURL(for: specs[0]))
    let databaseDate = try modificationDate(of: fs.databaseURL)

    let plan2 = SyncEngine.makePlan(library: library, device: after.tracks)
    let result2 = try await runSync(plan2)
    #expect((result2.failures) == ([]))
    #expect((result2.artworkImagesWritten) == (0))
    #expect((try modificationDate(of: fs.artworkDBURL)) == (artworkDBDate))
    #expect((try modificationDate(of: fs.ithmbURL(for: specs[0]))) == (ithmbDate))
    #expect((try modificationDate(of: fs.databaseURL)) == (databaseDate))
  }

  @Test
  func testChangedCoverTriggersRebuild() async throws {
    try fs.writeDatabase(ITunesDatabase())
    var track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    let plan = SyncEngine.makePlan(library: [track], device: [])
    _ = try await runSync(plan)
    let firstTiles = try Data(
      contentsOf: fs.ithmbURL(
        for: requireArtworkSpecs().first!))

    track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 0, green: 1, blue: 0))
    let device = try fs.readDatabase()
    let plan2 = SyncEngine.makePlan(library: [track], device: device.tracks)
    let result2 = try await runSync(plan2)
    #expect((result2.failures) == ([]))
    #expect((result2.artworkImagesWritten) == (1))
    let secondTiles = try Data(
      contentsOf: fs.ithmbURL(
        for: requireArtworkSpecs().first!))
    #expect((firstTiles) != (secondTiles))
  }

  @Test
  func testSameStatCoverReplacementUpdatesDeviceArtwork() async throws {
    try fs.writeDatabase(ITunesDatabase())
    var redCover = try pngData(red: 1, green: 0, blue: 0)
    var greenCover = try pngData(red: 0, green: 1, blue: 0)
    if redCover.count < greenCover.count {
      redCover.append(Data(count: greenCover.count - redCover.count))
    } else if greenCover.count < redCover.count {
      greenCover.append(Data(count: redCover.count - greenCover.count))
    }
    #expect((greenCover.count) == (redCover.count), Comment(rawValue: "fixture covers must preserve MP3 size"))

    var track = try await makeLibraryMP3(
      title: "Artwork", artist: "Band", album: "Album", artwork: redCover)
    let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: pinnedDate], ofItemAtPath: track.url.path)
    track = await MetadataLoader.load(url: track.url)
    _ = try await runSync(SyncEngine.makePlan(library: [track], device: []))

    let beforeStamp = try #require(FileGenerationStamp(url: track.url))
    let replacement = try await makeLibraryMP3(
      title: "Artwork", artist: "Band", album: "Album", artwork: greenCover)
    let afterStamp = try pinnedGenerationStamp(
      at: replacement.url, distinctFrom: beforeStamp, modificationDate: pinnedDate)
    #expect((afterStamp.inode) == (beforeStamp.inode))
    #expect((afterStamp.sizeBytes) == (beforeStamp.sizeBytes))
    #expect((afterStamp.modificationSeconds) == (beforeStamp.modificationSeconds))
    #expect((afterStamp.modificationNanoseconds) == (beforeStamp.modificationNanoseconds))
    #expect((afterStamp) != (beforeStamp))

    let plan = try await makePlan()
    #expect((plan.updateOnDevice.count) == (1))
    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.updatedOnDevice) == (1))
    #expect((result.artworkImagesWritten) == (1))

    let database = try fs.readDatabase()
    let entry = try #require(SyncLedgerStore.entries(for: database.databaseID, libraryFolder: libraryDir).first)
    #expect((entry.artworkSHA256) == (ArtworkPixels.sha256Hex(greenCover)))
    #expect((entry.fileGenerationStamp) == (afterStamp))
    let followUp = try await makePlan()
    #expect(followUp.isEmpty)
  }

  @Test
  func testDatabaseWriteFailureRollsBackInstalledArtworkGeneration() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [track], device: []))

    let specs = try requireArtworkSpecs()
    let originalDatabase = try Data(contentsOf: fs.databaseURL)
    let originalArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let originalTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })

    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 1, blue: 0))
    let device = try fs.readDatabase()
    let library = [track, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: device.databaseID, libraryFolder: libraryDir),
      library: library, device: device.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: device.tracks, links: links)
    #expect((plan.copyToDevice.count) == (1))

    struct InjectedDatabaseFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { _, _ in throw InjectedDatabaseFailure() }))
      Issue.record("the injected database failure must escape")
    } catch {
      #expect(error is InjectedDatabaseFailure, Comment(rawValue: "\(error)"))
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (originalDatabase))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (originalArtworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (originalTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
    #expect((leftovers) == ([]))
  }

  @Test
  func testLateDatabaseErrorKeepsArtworkWhenSemanticLinksCommitted() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)

    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 0, blue: 1))
    let before = try fs.readDatabase()
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir),
      library: library, device: before.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: before.tracks, links: links)
    #expect((plan.copyToDevice.count) == (1))

    struct InjectedLateDatabaseError: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { fileSystem, database in
            try fileSystem.writeDatabase(database)
            throw InjectedLateDatabaseError()
          }))
      Issue.record("the injected late database error must escape")
    } catch {
      #expect(error is InjectedLateDatabaseError, Comment(rawValue: "\(error)"))
    }

    let committed = try fs.readDatabase()
    #expect((Set(committed.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    let parsed = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((Set(parsed.map(\.trackDbid))) == (Set(committed.tracks.map(\.dbid))))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousArtworkDatabase))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
    #expect((leftovers) == ([]))
  }

  @Test
  func testBackupWriteFailureAfterDatabaseCommitRecoversBackupAndReceiptOnRead() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))
    let before = try fs.readDatabase()
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDBBackupURL.path)))

    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 0, blue: 1))
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir),
      library: library, device: before.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: before.tracks, links: links)
    #expect((plan.copyToDevice.count) == (1))

    final class InjectedBackupWriteFailure: Error, Sendable {}
    let injectedFailure = InjectedBackupWriteFailure()
    var receiptDirectory: URL?
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { fileSystem, database in
            #expect((Set(database.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
            try fileSystem.writeDatabase(database)
          },
          databaseVerificationReader: { fileSystem in
            try ITunesDBReader().read(Data(contentsOf: fileSystem.databaseURL))
          },
          artworkCommitter: { transaction in
            try transaction.commit(
              backupWriter: { _, _ in throw injectedFailure })
          }))
      Issue.record("the injected artwork commit failure must escape")
    } catch ArtworkDBTransactionError.resolutionFailed(
      let operation, let resolution, let directory)
    {
      #expect(operation as AnyObject === injectedFailure)
      #expect(resolution as AnyObject === injectedFailure)
      receiptDirectory = directory
    } catch {
      Issue.record("unexpected error: \(error)")
    }

    let receipt = try #require(receiptDirectory)
    let committed = try ITunesDBReader().read(Data(contentsOf: fs.databaseURL))
    #expect((Set(committed.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    #expect(
      (Set(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).map(\.trackDbid)))
        == (Set(committed.tracks.map(\.dbid))),
      Comment(rawValue: "commit failure must not roll artwork back under the committed iTunesDB"))
    #expect(FileManager.default.fileExists(atPath: receipt.path))
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDBBackupURL.path)))

    let recovered = try fs.readDatabase()
    #expect((Set(recovered.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousArtworkDatabase))
    #expect(!(FileManager.default.fileExists(atPath: receipt.path)))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testUnclassifiableDeferredArtworkIsQuarantinedWithoutBlockingDatabaseRead() throws {
    _ = try leaveDeferredArtworkTransaction(fileSystem: fs)
    var thirdGeneration = ITunesDatabase()
    var unrelatedTrack = ITDBTrack()
    unrelatedTrack.dbid = 99
    unrelatedTrack.title = "Managed Elsewhere"
    thirdGeneration.tracks = [unrelatedTrack]
    try fs.writeDatabase(thirdGeneration)

    let read = try fs.readDatabase()

    #expect((read.tracks.map(\.title)) == (["Managed Elsewhere"]))
    let contents = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
    #expect((contents.filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
    #expect((contents.filter { $0.hasPrefix(".nightdrive-quarantined-artwork-") }.count) == (1))
    #expect((try fs.readDatabase().tracks.map(\.title)) == (["Managed Elsewhere"]))
  }

  @Test
  func testInvalidDeferredArtworkFilesAreQuarantinedWithoutBlockingDatabaseRead() throws {
    let generations = try leaveDeferredArtworkTransaction(fileSystem: fs)
    try fs.writeDatabase(generations.intended)
    try Data("tampered artwork".utf8).write(to: fs.artworkDBURL, options: .atomic)

    let read = try fs.readDatabase()

    #expect((read.tracks.map(\.title)) == (["Updated", "Added"]))
    let contents = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
    #expect((contents.filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
    #expect((contents.filter { $0.hasPrefix(".nightdrive-quarantined-artwork-") }.count) == (1))
    #expect((try fs.readDatabase().tracks.map(\.title)) == (["Updated", "Added"]))
  }

  @Test
  func testMarkerlessArtworkTransactionIsGarbageCollected() throws {
    try fs.writeDatabase(ITunesDatabase())
    try FileManager.default.createDirectory(
      at: fs.artworkDir, withIntermediateDirectories: true)
    let orphan = fs.artworkDir.appendingPathComponent(
      ".nightdrive-artwork-\(UUID().uuidString)", isDirectory: true)
    let previous = orphan.appendingPathComponent("previous", isDirectory: true)
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    try Data().write(to: orphan.appendingPathComponent("owner.lock"))
    let retainedTile = previous.appendingPathComponent("F1061_1.ithmb")
    try Data(repeating: 0xAB, count: 1_024 * 1_024).write(to: retainedTile)

    _ = try fs.readDatabase()

    #expect(!(FileManager.default.fileExists(atPath: orphan.path)))
    #expect(!(FileManager.default.fileExists(atPath: retainedTile.path)))
  }

  @Test
  func testCommittedDatabaseWithFailedImmediateReadRecoversArtworkOnLaterConcurrentRead()
    async throws
  {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)

    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 0, blue: 1))
    let before = try fs.readDatabase()
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir),
      library: library, device: before.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: before.tracks, links: links)

    struct InjectedLateDatabaseError: Error {}
    struct InjectedVerificationReadFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { fileSystem, database in
            try fileSystem.writeDatabase(database)
            throw InjectedLateDatabaseError()
          },
          databaseVerificationReader: { _ in throw InjectedVerificationReadFailure() }))
      Issue.record("the injected late database error must escape")
    } catch {
      #expect(error is InjectedLateDatabaseError, Comment(rawValue: "\(error)"))
    }

    let pending = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
    #expect((pending.count) == (1), Comment(rawValue: "the unknown result must retain one recovery transaction"))
    let installedArtwork = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((installedArtwork.count) == (2), Comment(rawValue: "deinit must not roll committed artwork back"))

    let trackCounts = try await withThrowingTaskGroup(of: Int.self) { group in
      for _ in 0..<2 {
        group.addTask { try fs.readDatabase().tracks.count }
      }
      var counts: [Int] = []
      for try await count in group { counts.append(count) }
      return counts
    }
    #expect((trackCounts.sorted()) == ([2, 2]))
    let recovered = try fs.readDatabase()
    #expect((Set(recovered.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    #expect(
      (Set(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).map(\.trackDbid)))
        == (Set(recovered.tracks.map(\.dbid))))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousArtworkDatabase))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testDeferredRecoveryReReadsDatabaseAfterStraddlingWriter() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))
    let previousArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)

    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 0, blue: 1))
    let before = try fs.readDatabase()
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: before.databaseID, libraryFolder: libraryDir),
      library: library, device: before.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: before.tracks, links: links)

    final class ReaderBarrier: Sendable {
      let readersParsedOldDatabase = DispatchSemaphore(value: 0)
      let allowResolverRecovery = DispatchSemaphore(value: 0)
      let allowWaitingReaderToObserve = DispatchSemaphore(value: 0)
      let waitingReaderObservedDeferred = DispatchSemaphore(value: 0)
      let allowWaitingReaderLock = DispatchSemaphore(value: 0)
    }
    struct UnexpectedInitialDatabase: Error {}
    struct ReaderBarrierTimeout: Error {}
    let barrier = ReaderBarrier()
    let resolver = Task.detached {
      try fs.readDatabase(afterInitialRead: { database in
        barrier.readersParsedOldDatabase.signal()
        guard database.tracks.count == 1 else { throw UnexpectedInitialDatabase() }
        guard barrier.allowResolverRecovery.wait(timeout: .now() + 10) == .success else {
          throw ReaderBarrierTimeout()
        }
      })
    }
    let waitingReader = Task.detached {
      try fs.readDatabase(
        afterInitialRead: { database in
          barrier.readersParsedOldDatabase.signal()
          guard database.tracks.count == 1 else { throw UnexpectedInitialDatabase() }
          guard barrier.allowWaitingReaderToObserve.wait(timeout: .now() + 10) == .success else {
            throw ReaderBarrierTimeout()
          }
        },
        afterDeferredTransactionsObserved: {
          barrier.waitingReaderObservedDeferred.signal()
          guard barrier.allowWaitingReaderLock.wait(timeout: .now() + 10) == .success else {
            throw ReaderBarrierTimeout()
          }
        })
    }
    defer {
      barrier.allowResolverRecovery.signal()
      barrier.allowWaitingReaderToObserve.signal()
      barrier.allowWaitingReaderLock.signal()
    }
    let firstReaderParsed = await waitForSemaphore(
      barrier.readersParsedOldDatabase, timeout: .now() + 10)
    let secondReaderParsed = await waitForSemaphore(
      barrier.readersParsedOldDatabase, timeout: .now() + 10)
    #expect(firstReaderParsed == .success)
    #expect(secondReaderParsed == .success)

    struct InjectedLateDatabaseError: Error {}
    struct InjectedVerificationReadFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { fileSystem, database in
            try fileSystem.writeDatabase(database)
            throw InjectedLateDatabaseError()
          },
          databaseVerificationReader: { _ in throw InjectedVerificationReadFailure() }))
      Issue.record("the injected late database error must escape")
    } catch {
      #expect(error is InjectedLateDatabaseError, Comment(rawValue: "\(error)"))
    }

    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }.count) == (1))
    barrier.allowWaitingReaderToObserve.signal()
    let waitingReaderObservedDeferred = await waitForSemaphore(
      barrier.waitingReaderObservedDeferred, timeout: .now() + 10)
    #expect(waitingReaderObservedDeferred == .success)
    barrier.allowResolverRecovery.signal()

    let resolved = try await resolver.value
    #expect((Set(resolved.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    barrier.allowWaitingReaderLock.signal()

    let recoveredAfterWaiting = try await waitingReader.value
    #expect((Set(recoveredAfterWaiting.tracks.compactMap(\.title))) == (["Alpha", "Beta"]))
    #expect(
      (Set(try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).map(\.trackDbid)))
        == (Set(recoveredAfterWaiting.tracks.map(\.dbid))),
      Comment(rawValue: "the stale initial parse must not roll committed artwork back"))
    #expect((try Data(contentsOf: fs.artworkDBBackupURL)) == (previousArtworkDatabase))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testRecoveryMarkerFailureRollsArtworkBackBeforeDatabaseWrite() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))

    let originalDatabase = try Data(contentsOf: fs.databaseURL)
    let originalArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let specs = try requireArtworkSpecs()
    let originalTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })
    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 1, blue: 0))
    let device = try fs.readDatabase()
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: device.databaseID, libraryFolder: libraryDir),
      library: library, device: device.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: device.tracks, links: links)

    struct InjectedMarkerFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          artworkRecoveryMarkerWriter: { data, url in
            try ArtworkDBTransaction.writeRecoveryMarker(data, to: url)
            throw InjectedMarkerFailure()
          }))
      Issue.record("the injected recovery marker failure must escape")
    } catch {
      #expect(error is InjectedMarkerFailure, Comment(rawValue: "\(error)"))
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (originalDatabase))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (originalArtworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (originalTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testFailedDatabaseWithFailedImmediateReadRollsArtworkBackOnLaterRead() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let original = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [original], device: []))

    let originalDatabase = try Data(contentsOf: fs.databaseURL)
    let originalArtworkDatabase = try Data(contentsOf: fs.artworkDBURL)
    let specs = try requireArtworkSpecs()
    let originalTiles = try Dictionary(
      uniqueKeysWithValues: specs.map { ($0.ithmbName, try Data(contentsOf: fs.ithmbURL(for: $0))) })
    let added = try await makeLibraryMP3(
      title: "Beta", artist: "New Artist", album: "New Album",
      artwork: pngData(red: 0, green: 1, blue: 0))
    let device = try fs.readDatabase()
    let library = [original, added]
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: device.databaseID, libraryFolder: libraryDir),
      library: library, device: device.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: library, device: device.tracks, links: links)

    struct InjectedDatabaseFailure: Error {}
    struct InjectedVerificationReadFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { _, _ in throw InjectedDatabaseFailure() },
          databaseVerificationReader: { _ in throw InjectedVerificationReadFailure() }))
      Issue.record("the injected database failure must escape")
    } catch {
      #expect(error is InjectedDatabaseFailure, Comment(rawValue: "\(error)"))
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (originalDatabase))
    #expect(
      (try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL)).count) == (2),
      Comment(rawValue: "unknown outcome must remain installed until iTunesDB is readable"))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }.count) == (1))

    let recovered = try fs.readDatabase()
    #expect((recovered.tracks.compactMap(\.title)) == (["Alpha"]))
    #expect((try Data(contentsOf: fs.artworkDBURL)) == (originalArtworkDatabase))
    for spec in specs {
      #expect(
        (try Data(contentsOf: fs.ithmbURL(for: spec))) == (originalTiles[spec.ithmbName]),
        Comment(rawValue: spec.ithmbName))
    }
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
        .filter { $0.hasPrefix(".nightdrive-artwork-") }) == ([]))
  }

  @Test
  func testDatabaseFailureKeepsArtworkRepairWhenLinksWereAlreadyCompatible() async throws {
    try fs.writeDatabase(ITunesDatabase())
    let track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    _ = try await runSync(SyncEngine.makePlan(library: [track], device: []))

    let spec = try #require(requireArtworkSpecs().first)
    let tileURL = fs.ithmbURL(for: spec)
    let expectedTile = try Data(contentsOf: tileURL)
    try FileManager.default.removeItem(at: tileURL)

    let database = try fs.readDatabase()
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: database.databaseID, libraryFolder: libraryDir),
      library: [track], device: database.tracks, libraryFolder: libraryDir)
    let plan = SyncEngine.makePlan(library: [track], device: database.tracks, links: links)

    struct InjectedDatabaseFailure: Error {}
    do {
      _ = try await runSync(
        request: SyncExecutionRequest(plan),
        effects: SyncEngineEffects(
          tagWriter: { _, _ in },
          databaseWriter: { _, _ in throw InjectedDatabaseFailure() }))
      Issue.record("the injected database failure must escape")
    } catch {
      #expect(error is InjectedDatabaseFailure, Comment(rawValue: "\(error)"))
    }

    #expect((try Data(contentsOf: tileURL)) == (expectedTile))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: fs.artworkDir.path)
      .filter { $0.hasPrefix(".nightdrive-artwork-") }
    #expect((leftovers) == ([]))
  }

  @Test
  func testRemovedCoverClearsDeviceArtwork() async throws {
    try fs.writeDatabase(ITunesDatabase())
    var track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    let plan = SyncEngine.makePlan(library: [track], device: [])
    _ = try await runSync(plan)
    #expect(try fs.readDatabase().tracks.first?.artwork != nil)

    track = try await makeLibraryMP3(title: "Alpha", artist: "Band", album: "One", artwork: nil)
    let device = try fs.readDatabase()
    let plan2 = SyncEngine.makePlan(library: [track], device: device.tracks)
    let result2 = try await runSync(plan2)
    #expect((result2.failures) == ([]))
    #expect((result2.updatedOnDevice) == (1))
    #expect((result2.artworkImagesWritten) == (0))

    let after = try fs.readDatabase()
    #expect(after.tracks.first?.artwork == nil)
    let parsed = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
    #expect((parsed) == ([]))
    let specs = try requireArtworkSpecs()
    for spec in specs {
      let size =
        try FileManager.default.attributesOfItem(
          atPath: fs.ithmbURL(for: spec).path)[.size] as? Int
      #expect((size) == (0), Comment(rawValue: spec.ithmbName))
    }

    let artworkDBDate = try modificationDate(of: fs.artworkDBURL)
    let databaseDate = try modificationDate(of: fs.databaseURL)
    let plan3 = SyncEngine.makePlan(library: [track], device: after.tracks)
    let result3 = try await runSync(plan3)
    #expect((result3.failures) == ([]))
    #expect((result3.artworkImagesWritten) == (0))
    #expect((try modificationDate(of: fs.artworkDBURL)) == (artworkDBDate))
    #expect((try modificationDate(of: fs.databaseURL)) == (databaseDate))
  }

  @Test
  func testUnknownModelWritesNoArtworkAndSaysSo() async throws {
    try fs.writeDatabase(ITunesDatabase())
    try setModelNumber("Z9999")
    let track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    let plan = SyncEngine.makePlan(library: [track], device: [])
    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.artworkImagesWritten) == (0))
    #expect((result.artworkNotes.count) == (1))
    #expect(result.artworkNotes[0].contains("does not know"), Comment(rawValue: "\(result.artworkNotes)"))
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDir.path)))
    #expect(try fs.readDatabase().tracks.first?.artwork == nil)
  }

  @Test
  func testMonochromeModelWritesNoArtworkSilently() async throws {
    try setModelNumber("M9282")
    try fs.writeDatabase(ITunesDatabase())
    let track = try await makeLibraryMP3(
      title: "Alpha", artist: "Band", album: "One",
      artwork: pngData(red: 1, green: 0, blue: 0))
    let plan = SyncEngine.makePlan(library: [track], device: [])
    let result = try await runSync(plan)
    #expect((result.failures) == ([]))
    #expect((result.artworkImagesWritten) == (0))
    #expect((result.artworkNotes) == ([]))
    #expect(!(FileManager.default.fileExists(atPath: fs.artworkDir.path)))
  }
}
