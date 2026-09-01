import AVFoundation
import AppKit
import Darwin
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.serialized)
final class DeviceFormatSyncTests {
  private var scratch: URL!
  private var libraryDir: URL!
  private var cacheDir: URL!
  private var handoffRoot: URL!

  init() throws {
    scratch = TestScratch.directory()
    libraryDir = scratch.appendingPathComponent("library", isDirectory: true)
    cacheDir = scratch.appendingPathComponent("transcode-cache", isDirectory: true)
    try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
    handoffRoot = scratch.appendingPathComponent("transcode-handoffs", isDirectory: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func makeTranscodeCache(
    directory: URL? = nil,
    encoder: (any TranscodeEncoder)? = nil,
    inspectionHook: (@Sendable (TranscodeCacheInspectionOperation) throws -> Void)? = nil
  ) -> TranscodeCache {
    TranscodeCache(
      directory: directory, encoder: encoder, inspectionHook: inspectionHook,
      handoffRoot: handoffRoot)
  }

  @Test
  func testPlanSeparatesLocalOnlyFormatsFromDeviceCopies() {
    let mp3 = track(named: "Compatible.mp3")
    let flac = track(named: "Local Only.flac")

    let modernPlan = SyncEngine.makePlan(
      library: [mp3, flac], device: [], deviceFamily: .thirdGenerationOrLater)
    #expect((modernPlan.copyToDevice.map(\.url)) == ([mp3.url, flac.url]))
    #expect(modernPlan.unsupportedForDevice.isEmpty)

    let earlyPlan = SyncEngine.makePlan(
      library: [mp3, flac], device: [], deviceFamily: .firstOrSecondGeneration)
    #expect((earlyPlan.copyToDevice.map(\.url)) == ([mp3.url]))
    #expect((earlyPlan.unsupportedForDevice.map(\.url)) == ([flac.url]))
  }

  @Test
  func testM4ATrackUsesAACDatabaseMetadata() {
    let source = track(named: "Song.m4a")

    let databaseTrack = SyncEngine.makeDBTrack(
      from: source, ipodPath: ":iPod_Control:Music:F00:SONG.m4a")

    #expect((databaseTrack.filetypeDescription) == ("AAC audio file"))
    #expect((databaseTrack.type2) == (0))
    #expect((databaseTrack.filetypeMarker) == (SyncEngine.filetypeMarker(for: "m4a")))
  }

  @Test(
    arguments: [
      ("mp3", .mp3, 301, 1),
      ("m4a", .aac, 502, 0),
      ("m4b", .aac, 502, 0),
      ("wav", .pcm, 0, nil),
      ("aif", .pcm, 0, nil),
      ("aiff", .pcm, 0, nil),
      ("opus", .unknown, 0, nil),
    ] as [(String, ITDBAudioCodec, Int64, UInt8?)])
  func testExplicitCodecClassificationUsesNanoReferenceValues(
    _ testCase: (extensionName: String, codec: ITDBAudioCodec, nanoFormat: Int64, type2: UInt8?)
  ) {
    let marker = SyncEngine.filetypeMarker(for: testCase.extensionName)
    let classified = ITDBAudioCodec(filetypeMarker: marker)
    #expect(classified == testCase.codec)
    #expect(classified.nanoAudioFormat == testCase.nanoFormat)
    #expect(classified.binaryType2 == testCase.type2)
  }

  @Test
  func testImportedTrackCodecFallsBackFromMarkerToPathThenType2() {
    var track = ITDBTrack()
    track.filetypeMarker = 0
    track.type2 = 0
    track.ipodPath = ":iPod_Control:Music:F00:IMPORTED.mp3"
    #expect((track.audioCodec) == (.mp3), Comment(rawValue: "recognized path extension wins over type2"))

    track.ipodPath = ":iPod_Control:Music:F00:IMPORTED.wav"
    track.type2 = 1
    #expect((track.audioCodec) == (.pcm), Comment(rawValue: "PCM must not inherit the MP3-only type2 default"))

    track.ipodPath = ":iPod_Control:Music:F00:IMPORTED.bin"
    track.type2 = 0
    #expect((track.audioCodec) == (.aac))

    track.type2 = 17
    #expect((track.audioCodec) == (.unknown))
  }

  @Test(
    arguments: [
      ("M8541", .firstOrSecondGeneration),
      ("M8737LL", .firstOrSecondGeneration),
      ("M9282", .thirdGenerationOrLater),
      (nil, .thirdGenerationOrLater),
    ] as [(String?, IpodDeviceFamily)])
  func testDeviceFamilyIsDetectedFromModelNumber(
    _ testCase: (modelNumber: String?, expectedFamily: IpodDeviceFamily)
  ) {
    #expect(IpodDeviceFamily(modelNumber: testCase.modelNumber) == testCase.expectedFamily)
    if testCase.modelNumber == nil {
      #expect(!IpodDeviceFamily.firstOrSecondGeneration.playsAAC)
      #expect(IpodDeviceFamily.thirdGenerationOrLater.playsAAC)
    }
  }

  @Test
  func testEarlyIpodsClearlyRejectFormatsThatWouldNeedMP3Transcoding() {
    let flac = track(named: "Lossless.flac")
    #expect(
      (flac.deviceDelivery(for: .firstOrSecondGeneration))
        == (.unsupported(
          reason:
            "FLAC cannot be converted for this iPod: 1st- and 2nd-generation models play "
            + "only MP3, which Nightdrive cannot encode.")))
  }

  @Test
  func testFLACSyncsToAACCapableIpodAsPlayableM4A() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Golden Hour.flac")
    try writeFLAC(to: flacURL)
    let flacHash = try SyncSignature.fileSHA256(url: flacURL)
    let library = await LibraryStore.loadTracks(at: [flacURL])
    #expect((library.first?.audioFormat) == (.flac))
    #expect((library.first?.mediaValidation) == (.valid))

    let plan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)
    #expect((plan.copyToDevice.map(\.url)) == ([flacURL]))

    var progressDetails: [String] = []
    let progressBox = ProgressBox()
    let result = try await SyncEngine.execute(
      plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: TranscodeContext(cache: makeTranscodeCache(directory: cacheDir))
    ) { progress in progressBox.append(progress.detail) }
    progressDetails = progressBox.all()
    #expect((result.failures) == ([]))
    #expect((result.copiedToDevice) == (1))
    #expect(
      progressDetails.contains { $0.hasPrefix("Copying to iPod:") },
      Comment(rawValue: "expected a copy progress step after conversion, got \(progressDetails)"))

    let fs = IpodFileSystem(volumeURL: ipodDir)
    let db = try fs.readDatabase()
    #expect((db.tracks.count) == (1))
    let row = try #require(db.tracks.first)
    #expect((row.filetypeMarker) == (SyncEngine.filetypeMarker(for: "m4a")))
    #expect((row.type2) == (0))
    #expect((row.audioCodec) == (.aac))
    #expect((row.filetypeDescription) == ("AAC audio file"))
    #expect((row.title) == ("Golden Hour"))

    let deviceFile = try fs.validatedMusicFileURL(forIpodPath: try #require(row.ipodPath))
    #expect((deviceFile.pathExtension.lowercased()) == ("m4a"))
    let published = await MetadataLoader.load(url: deviceFile)
    #expect((published.mediaValidation) == (.valid))
    #expect((published.durationMS) > (500))

    let entries = SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
    #expect((entries.count) == (1))
    #expect((entries.first?.contentSHA256) == (flacHash))
    #expect((entries.first?.transcodeProfile) == ("aac-256"))

    let refreshed = await LibraryStore.loadTracks(at: [flacURL])
    let links = SyncLedgerStore.resolveLinks(
      entries: entries, library: refreshed, device: db.tracks, libraryFolder: libraryDir)
    let secondPlan = SyncEngine.makePlan(
      library: refreshed, device: db.tracks, links: links,
      deviceFamily: .thirdGenerationOrLater)
    #expect(secondPlan.copyToDevice.isEmpty)
    #expect(secondPlan.updateOnDevice.isEmpty)
    #expect(secondPlan.copyToFolder.isEmpty)
    #expect(secondPlan.unsupportedForDevice.isEmpty)
  }

  @Test
  func testTranscodedM4ACarriesTagsAndArtwork() async throws {
    let flacURL = libraryDir.appendingPathComponent("Tagged.flac")
    try writeFLAC(to: flacURL)
    let metadata = TrackMetadata(
      title: "Golden Hour", artist: "The Prisms", album: "Refraction",
      albumArtist: "Prisms Collective", composer: "A. Composer", genre: "Electronic",
      grouping: "Set One", year: 2_021, bpm: 118, trackNumber: 3, trackCount: 12,
      discNumber: 1, discCount: 2, comment: "Late take", lyrics: "Shine on",
      compilation: true)
    let artwork = pngArtwork(color: .systemRed)

    let destination = scratch.appendingPathComponent("tagged.m4a")
    try await AVFoundationAACEncoder().encode(
      source: flacURL, destination: destination,
      profile: TranscodeProfile(bitrateKbps: 256),
      metadata: metadata, artwork: artwork)

    let loaded = await MetadataLoader.load(url: destination)
    #expect((loaded.title) == ("Golden Hour"))
    #expect((loaded.artist) == ("The Prisms"))
    #expect((loaded.album) == ("Refraction"))
    #expect((loaded.albumArtist) == ("Prisms Collective"))
    #expect((loaded.composer) == ("A. Composer"))
    #expect((loaded.genre) == ("Electronic"))
    #expect((loaded.grouping) == ("Set One"))
    #expect((loaded.year) == (2_021))
    #expect((loaded.trackNumber) == (3))
    #expect((loaded.trackCount) == (12))
    #expect((loaded.discNumber) == (1))
    #expect((loaded.discCount) == (2))
    #expect(loaded.compilation)
    #expect((loaded.mediaValidation) == (.valid))
    let roundTripped = await MetadataLoader.loadArtwork(url: destination)
    #expect((roundTripped) == (artwork))
  }

  @Test
  func testCacheHitSkipsReencodingForASecondDevice() async throws {
    let flacURL = libraryDir.appendingPathComponent("Once Encoded.flac")
    try writeFLAC(to: flacURL)
    let counter = EncodeCounter()
    let transcoding = TranscodeContext(
      cache: makeTranscodeCache(directory: cacheDir, encoder: CountingAACEncoder(counter: counter)))

    for model in ["M9282", "M9585"] {
      let ipodDir = try makeFakeIpod(model: model)
      let library = await LibraryStore.loadTracks(at: [flacURL])
      let plan = SyncEngine.makePlan(
        library: library, device: [], deviceFamily: .thirdGenerationOrLater)
      let result = try await SyncEngine.execute(
        plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
        transcoding: transcoding
      ) { _ in }
      #expect((result.failures) == ([]))
      #expect((result.copiedToDevice) == (1))
    }

    let encodes = await counter.count
    #expect((encodes) == (1), Comment(rawValue: "the second device must reuse the cached conversion"))
  }

  @Test
  func testEncoderCancellationErrorFailsOnlyItsTrack() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Encoder Failure.flac")
    try writeFLAC(to: flacURL)
    let library = await LibraryStore.loadTracks(at: [flacURL])
    let plan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)

    let result = try await SyncEngine.execute(
      plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: TranscodeContext(
        cache: makeTranscodeCache(directory: cacheDir, encoder: CancellationFailingEncoder()))
    ) { _ in }

    #expect((result.copiedToDevice) == (0))
    #expect((result.failures.count) == (1))
    #expect((result.failures.first?.operation) == (.copyToDevice))
    let fs = IpodFileSystem(volumeURL: ipodDir)
    #expect(try fs.readDatabase().tracks.isEmpty)
    #expect(!(FileManager.default.fileExists(atPath: fs.syncTransactionsDirectory.path)))
  }

  @Test
  func testSourceEditInvalidatesCacheAndResyncsTheDeviceCopy() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Evolving.flac")
    try writeFLAC(to: flacURL, seconds: 1.0, frequency: 440)
    let counter = EncodeCounter()
    let transcoding = TranscodeContext(
      cache: makeTranscodeCache(directory: cacheDir, encoder: CountingAACEncoder(counter: counter)))

    var library = await LibraryStore.loadTracks(at: [flacURL])
    let firstPlan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)
    _ = try await SyncEngine.execute(
      plan: firstPlan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: transcoding
    ) { _ in }

    try FileManager.default.removeItem(at: flacURL)
    try writeFLAC(to: flacURL, seconds: 1.4, frequency: 660)
    let newHash = try SyncSignature.fileSHA256(url: flacURL)

    let fs = IpodFileSystem(volumeURL: ipodDir)
    var db = try fs.readDatabase()
    library = await LibraryStore.loadTracks(at: [flacURL])
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir),
      library: library, device: db.tracks, libraryFolder: libraryDir)
    let secondPlan = SyncEngine.makePlan(
      library: library, device: db.tracks, links: links,
      deviceFamily: .thirdGenerationOrLater)
    #expect((secondPlan.updateOnDevice.count) == (1))

    let result = try await SyncEngine.execute(
      plan: secondPlan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: transcoding
    ) { _ in }
    #expect((result.failures) == ([]))
    #expect((result.updatedOnDevice) == (1))

    let encodes = await counter.count
    #expect((encodes) == (2), Comment(rawValue: "the edited source must be re-encoded"))

    db = try fs.readDatabase()
    let entries = SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir)
    #expect((entries.first?.contentSHA256) == (newHash))
    #expect((entries.first?.transcodeProfile) == ("aac-256"))
  }

  @Test
  func testTranscodeCannotCacheChangedSourceUnderCapturedHash() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Moving Target.flac")
    try writeFLAC(to: flacURL, seconds: 1.0, frequency: 440)
    let capturedBytes = try Data(contentsOf: flacURL)
    let capturedHash = try SyncSignature.fileSHA256(url: flacURL)

    let replacementURL = scratch.appendingPathComponent("replacement.flac")
    try writeFLAC(to: replacementURL, seconds: 1.4, frequency: 880)
    let replacementBytes = try Data(contentsOf: replacementURL)
    #expect((replacementBytes) != (capturedBytes))

    let library = await LibraryStore.loadTracks(at: [flacURL])
    let plan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)
    let profile = TranscodeProfile(bitrateKbps: 256)
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: SourceMutatingCopyEncoder(
        original: flacURL, replacement: replacementBytes))

    let result = try await SyncEngine.execute(
      plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: TranscodeContext(cache: cache)
    ) { _ in }

    #expect((result.failures) == ([]))
    #expect((try Data(contentsOf: flacURL)) == (replacementBytes))
    #expect(
      (try Data(contentsOf: cache.cachedFileURL(sourceHash: capturedHash, profile: profile))) == (capturedBytes),
      Comment(rawValue: "a cache key for generation A must never publish generation B"))

    let fs = IpodFileSystem(volumeURL: ipodDir)
    let db = try fs.readDatabase()
    let row = try #require(db.tracks.first)
    let deviceURL = try fs.validatedMusicFileURL(forIpodPath: try #require(row.ipodPath))
    #expect((try Data(contentsOf: deviceURL)) == (capturedBytes))
    let entry = try #require(SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir).first)
    #expect((entry.contentSHA256) == (capturedHash))
    #expect((entry.fileSize) == (capturedBytes.count))

    let refreshed = await LibraryStore.loadTracks(at: [flacURL])
    let links = SyncLedgerStore.resolveLinks(
      entries: [entry], library: refreshed, device: db.tracks, libraryFolder: libraryDir)
    let retry = SyncEngine.makePlan(
      library: refreshed, device: db.tracks, links: links,
      deviceFamily: .thirdGenerationOrLater)
    #expect((retry.updateOnDevice.count) == (1))
  }

  @Test
  func testBitrateChangeReplansTheDeviceCopyAsAnUpdate() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Requantized.flac")
    try writeFLAC(to: flacURL)
    let transcoding = TranscodeContext(cache: makeTranscodeCache(directory: cacheDir))

    var library = await LibraryStore.loadTracks(at: [flacURL])
    let firstPlan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)
    _ = try await SyncEngine.execute(
      plan: firstPlan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: transcoding
    ) { _ in }

    let fs = IpodFileSystem(volumeURL: ipodDir)
    let db = try fs.readDatabase()
    library = await LibraryStore.loadTracks(at: [flacURL])
    let links = SyncLedgerStore.resolveLinks(
      entries: SyncLedgerStore.entries(for: db.databaseID, libraryFolder: libraryDir),
      library: library, device: db.tracks, libraryFolder: libraryDir)

    var lowered = TranscodeSettings()
    lowered.bitrateKbps = 128
    let secondPlan = SyncEngine.makePlan(
      library: library, device: db.tracks, links: links,
      deviceFamily: .thirdGenerationOrLater, transcodeSettings: lowered)
    #expect((secondPlan.updateOnDevice.count) == (1))
    #expect((secondPlan.updateOnDevice.first?.delivery) == (.transcode(to: TranscodeProfile(bitrateKbps: 128))))

    let samePlan = SyncEngine.makePlan(
      library: library, device: db.tracks, links: links,
      deviceFamily: .thirdGenerationOrLater)
    #expect(samePlan.updateOnDevice.isEmpty)
  }

  @Test
  func testFirstAndSecondGenerationIpodsRefuseFLAC() async throws {
    let ipodDir = try makeFakeIpod(model: "M8541")
    let flacURL = libraryDir.appendingPathComponent("Refused.flac")
    try writeFLAC(to: flacURL)
    let library = await LibraryStore.loadTracks(at: [flacURL])
    let flac = try #require(library.first)

    guard case .unsupported(let reason) = flac.deviceDelivery(for: .firstOrSecondGeneration)
    else {
      Issue.record("Expected FLAC to be refused for a 2G iPod")
      return
    }
    #expect(reason.contains("MP3"), Comment(rawValue: "reason should explain the MP3-only limit: \(reason)"))

    let counter = EncodeCounter()
    let plan = SyncEngine.makePlan(
      library: library, device: [], deviceFamily: .thirdGenerationOrLater)
    let result = try await SyncEngine.execute(
      plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: TranscodeContext(
        cache: makeTranscodeCache(directory: cacheDir, encoder: CountingAACEncoder(counter: counter)))
    ) { _ in }
    #expect((result.copiedToDevice) == (0))
    let encodes = await counter.count
    #expect((encodes) == (0))
    #expect(try IpodFileSystem(volumeURL: ipodDir).readDatabase().tracks.isEmpty)
  }

  @Test
  func testSpaceCheckUsesTranscodeEstimateNotSourceSize() async throws {
    let ipodDir = try makeFakeIpod(model: "M9282")
    let flacURL = libraryDir.appendingPathComponent("Huge Lossless.flac")
    try writeFLAC(to: flacURL)
    var library = await LibraryStore.loadTracks(at: [flacURL])
    #expect((library.count) == (1))

    let available = Int64(
      (try? ipodDir.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        .volumeAvailableCapacity) ?? 0)
    library[0].sizeBytes = Int(available) + 1_000_000_000

    let plan = SyncEngine.makePlan(library: library, device: [])
    #expect(
      (SyncCapacity.plannedOutboundBytes(
        plan, family: .thirdGenerationOrLater, settings: TranscodeSettings())) < (Int64(library[0].sizeBytes)))
    let result = try await SyncEngine.execute(
      plan: plan, deviceVolume: ipodDir, libraryFolder: libraryDir,
      transcoding: TranscodeContext(cache: makeTranscodeCache(directory: cacheDir))
    ) { _ in }
    #expect((result.failures) == ([]))
    #expect((result.copiedToDevice) == (1))
    #expect((try IpodFileSystem(volumeURL: ipodDir).readDatabase().tracks.count) == (1))
  }

  @Test
  func testTranscodeCacheEvictsLeastRecentlyUsedFirst() async throws {
    let counter = EncodeCounter()
    let cache = makeTranscodeCache(
      directory: cacheDir, encoder: StubPayloadEncoder(counter: counter, payloadBytes: 1_000))
    let profile = TranscodeProfile(bitrateKbps: 256)
    var settings = TranscodeSettings()
    settings.cacheCeilingBytes = 2_500

    let source = libraryDir.appendingPathComponent("payload.bin")
    try Data("payload".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "Payload.flac"))

    func encode(hash: String) async throws -> URL {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil, settings: settings
      ) { _ in }
      return cache.cachedFileURL(sourceHash: hash, profile: profile)
    }

    let first = try await encode(hash: String(repeating: "a", count: 64))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: first.path)
    let second = try await encode(hash: String(repeating: "b", count: 64))
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: -1_800)], ofItemAtPath: second.path)

    _ = try await encode(hash: String(repeating: "a", count: 64))
    let hitCount = await counter.count
    #expect((hitCount) == (2), Comment(rawValue: "the hit must not re-encode"))

    let third = try await encode(hash: String(repeating: "c", count: 64))
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(!(FileManager.default.fileExists(atPath: second.path)))
    #expect(FileManager.default.fileExists(atPath: third.path))
    let sizeAfterEviction = try await cache.totalSizeBytes()
    #expect((sizeAfterEviction) <= (2_500))

    try await cache.clear()
    let sizeAfterClear = try await cache.totalSizeBytes()
    #expect((sizeAfterClear) == (0))
  }

  @Test
  func testClearDuringEncodeDoesNotRepopulateCacheAndConsumerUsesPrivateSnapshot() async throws {
    let encoderStarted = TestGate()
    let allowEncode = TestGate()
    let consumerStarted = TestGate()
    let allowConsumer = TestGate()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: PausingPayloadEncoder(started: encoderStarted, release: allowEncode))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let hash = String(repeating: "d", count: 64)
    let source = libraryDir.appendingPathComponent("paused.bin")
    let cacheDirectory = try #require(cacheDir)
    let metadata = TrackMetadata(track(named: "Paused.flac"))
    try Data("source".utf8).write(to: source)

    let consumer = Task<(Data, URL), any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { cached in
        #expect(!(cached.path.hasPrefix(cacheDirectory.path)))
        #expect(FileManager.default.fileExists(atPath: cached.path))
        await consumerStarted.signal()
        await allowConsumer.wait()
        return (try Data(contentsOf: cached), cached)
      }
    }
    await encoderStarted.wait()

    let sizeDuringEncode = try await cache.totalSizeBytes()
    #expect((sizeDuringEncode) == (0), Comment(rawValue: "private encoder output is not a cache entry"))
    try await cache.clear()

    await allowEncode.signal()
    await consumerStarted.wait()
    let cached = cache.cachedFileURL(sourceHash: hash, profile: profile)
    #expect(
      !(FileManager.default.fileExists(atPath: cached.path)),
      Comment(rawValue: "an encode from the previous generation must not repopulate a cleared cache"))

    await allowConsumer.signal()
    let (consumed, privateURL) = try await consumer.value
    #expect((consumed.count) == (1_000))
    #expect(
      !(FileManager.default.fileExists(atPath: privateURL.path)),
      Comment(rawValue: "the caller-private snapshot should be removed after consumption"))
    let sizeAfterClear = try await cache.totalSizeBytes()
    #expect((sizeAfterClear) == (0))
  }

  @Test
  func testConcurrentRequestsForSameKeyEncodeOnce() async throws {
    let counter = EncodeCounter()
    let encoderStarted = TestGate()
    let allowEncode = TestGate()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: PausingPayloadEncoder(
        counter: counter, started: encoderStarted, release: allowEncode))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let hash = String(repeating: "e", count: 64)
    let source = libraryDir.appendingPathComponent("same-key.bin")
    try Data("source".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "Same.flac"))

    func request() async throws -> Data {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { try Data(contentsOf: $0) }
    }

    let first = Task { try await request() }
    await encoderStarted.wait()
    let second = Task { try await request() }
    let encodedOnceWhileBlocked = await holds(for: .milliseconds(40)) {
      await counter.count == 1
    }
    #expect(encodedOnceWhileBlocked)
    await allowEncode.signal()

    let firstPayload = try await first.value
    let secondPayload = try await second.value
    #expect((firstPayload.count) == (1_000))
    #expect((secondPayload.count) == (1_000))
    let finalEncodes = await counter.count
    #expect((finalEncodes) == (1))
  }

  @Test
  func testDifferentKeysEncodeAndConsumeConcurrentlyBeforeEviction() async throws {
    let encodeCounter = EncodeCounter()
    let allowEncodes = TestGate()
    let consumerCounter = EncodeCounter()
    let allowConsumers = TestGate()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: HoldingPayloadEncoder(counter: encodeCounter, release: allowEncodes))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let settings: TranscodeSettings = {
      var settings = TranscodeSettings()
      settings.cacheCeilingBytes = 1_000
      return settings
    }()
    let source = libraryDir.appendingPathComponent("different-keys.bin")
    try Data("source".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "Different.flac"))
    let hashes = [String(repeating: "f", count: 64), String(repeating: "1", count: 64)]

    @Sendable func request(hash: String) async throws -> Data {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil, settings: settings
      ) { cached in
        await consumerCounter.record()
        await allowConsumers.wait()
        return try Data(contentsOf: cached)
      }
    }

    let first = Task { try await request(hash: hashes[0]) }
    let second = Task { try await request(hash: hashes[1]) }
    let encodedConcurrently = await waitUntil(timeout: .seconds(2)) {
      await encodeCounter.count == 2
    }
    #expect(encodedConcurrently)
    await allowEncodes.signal()
    let consumedConcurrently = await waitUntil(timeout: .seconds(2)) {
      await consumerCounter.count == 2
    }
    #expect(consumedConcurrently)
    for hash in hashes {
      let cached = cache.cachedFileURL(sourceHash: hash, profile: profile)
      #expect(FileManager.default.fileExists(atPath: cached.path))
    }

    await allowConsumers.signal()
    let firstPayload = try await first.value
    let secondPayload = try await second.value
    #expect((firstPayload.count) == (1_000))
    #expect((secondPayload.count) == (1_000))
    let sizeAfterEviction = try await cache.totalSizeBytes()
    #expect((sizeAfterEviction) <= (1_000))
  }

  @Test
  func testCancellingQueuedSameKeyRequestDoesNotStrandCacheGate() async throws {
    let encoderStarted = TestGate()
    let allowEncode = TestGate()
    let counter = EncodeCounter()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: PausingPayloadEncoder(
        counter: counter, started: encoderStarted, release: allowEncode))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let hash = String(repeating: "2", count: 64)
    let source = libraryDir.appendingPathComponent("cancellation.bin")
    try Data("source".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "Cancellation.flac"))

    let active = Task<Data, any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { try Data(contentsOf: $0) }
    }
    await encoderStarted.wait()

    let waitingConsumer = Task<Data, any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { try Data(contentsOf: $0) }
    }
    let stillSingleEncode = await holds(for: .milliseconds(40)) {
      await counter.count == 1
    }
    #expect(stillSingleEncode)
    waitingConsumer.cancel()
    do {
      _ = try await waitingConsumer.value
      Issue.record("a same-key request cancelled behind an encode should throw")
    } catch is CancellationError {
    }

    let replacement = Task<Data, any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { try Data(contentsOf: $0) }
    }
    await allowEncode.signal()
    let activePayload = try await active.value
    let replacementPayload = try await replacement.value
    let encodeCount = await counter.count
    #expect((activePayload.count) == (1_000))
    #expect((replacementPayload.count) == (1_000))
    #expect((encodeCount) == (1))
  }

  @Test
  func testCancellationDuringConsumptionRemovesPrivateSnapshot() async throws {
    let consumerStarted = TestGate()
    let capture = URLCapture()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: StubPayloadEncoder(counter: EncodeCounter(), payloadBytes: 1_000))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let source = libraryDir.appendingPathComponent("cancel-consumer.bin")
    let metadata = TrackMetadata(track(named: "Cancel Consumer.flac"))
    try Data("source".utf8).write(to: source)

    let consumer = Task<Void, any Error> {
      try await cache.withTranscodedFile(
        source: source,
        sourceHash: String(repeating: "c", count: 64),
        profile: profile,
        metadata: metadata,
        artwork: nil
      ) { snapshot in
        await capture.record(snapshot)
        await consumerStarted.signal()
        try await Task.sleep(for: .seconds(300))
      }
    }
    await consumerStarted.wait()
    let capturedURL = await capture.url
    let snapshot = try #require(capturedURL)
    #expect(FileManager.default.fileExists(atPath: snapshot.path))

    consumer.cancel()
    do {
      try await consumer.value
      Issue.record("a cancelled consumer should throw")
    } catch is CancellationError {
    }
    #expect(!(FileManager.default.fileExists(atPath: snapshot.path)))
    #expect(!(FileManager.default.fileExists(atPath: snapshot.deletingLastPathComponent().path)))
  }

  @Test
  func testCacheInspectionFailuresThrowWithoutRemovingEntries() async throws {
    let failures = InspectionFailureToggle()
    let cache = makeTranscodeCache(
      directory: cacheDir, inspectionHook: { try failures.inspect($0) })
    let profile = TranscodeProfile(bitrateKbps: 256)
    let artifact = cache.cachedFileURL(
      sourceHash: String(repeating: "3", count: 64), profile: profile)
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 1_000).write(to: artifact)

    failures.set(.enumeration)
    do {
      try await cache.clear()
      Issue.record("clear must report a directory enumeration failure")
    } catch is InjectedInspectionError {
    }
    #expect(FileManager.default.fileExists(atPath: artifact.path))

    failures.set(.metadata)
    do {
      _ = try await cache.totalSizeBytes()
      Issue.record("size must report a metadata read failure")
    } catch is InjectedInspectionError {
    }
    do {
      try await cache.clear()
      Issue.record("clear must report a metadata read failure")
    } catch is InjectedInspectionError {
    }
    #expect(FileManager.default.fileExists(atPath: artifact.path))
  }

  @Test
  func testPostConsumeEvictionFailureDoesNotReclassifySuccessfulHandoff() async throws {
    let failures = InspectionFailureToggle()
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: StubPayloadEncoder(counter: EncodeCounter(), payloadBytes: 1_000),
      inspectionHook: { try failures.inspect($0) })
    let profile = TranscodeProfile(bitrateKbps: 256)
    let hash = String(repeating: "7", count: 64)
    let source = libraryDir.appendingPathComponent("successful-handoff.bin")
    try Data("source".utf8).write(to: source)

    var privateURL: URL?
    let handoff = try await cache.withTranscodedFile(
      source: source, sourceHash: hash, profile: profile,
      metadata: TrackMetadata(track(named: "Successful Handoff.flac")), artwork: nil
    ) { cached in
      #expect(FileManager.default.fileExists(atPath: cached.path))
      privateURL = cached
      failures.set(.enumeration)
      return "staged"
    }

    #expect((handoff) == ("staged"))
    let completedPrivateURL = try #require(privateURL)
    #expect(!(FileManager.default.fileExists(atPath: completedPrivateURL.path)))
    #expect(
      !(FileManager.default.fileExists(
        atPath: completedPrivateURL.deletingLastPathComponent().path)))
    #expect(
      FileManager.default.fileExists(
        atPath: cache.cachedFileURL(sourceHash: hash, profile: profile).path))
  }

  @Test
  func testConsumerFailurePreservesItsErrorAndStillTrimsTheCache() async throws {
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: StubPayloadEncoder(counter: EncodeCounter(), payloadBytes: 1_000))
    let profile = TranscodeProfile(bitrateKbps: 256)
    var settings = TranscodeSettings()
    settings.cacheCeilingBytes = 1_000
    let source = libraryDir.appendingPathComponent("failed-handoff.bin")
    try Data("source".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "Failed Handoff.flac"))

    try await cache.withTranscodedFile(
      source: source, sourceHash: String(repeating: "8", count: 64),
      profile: profile, metadata: metadata, artwork: nil, settings: settings
    ) { _ in }

    var failedPrivateURL: URL?
    do {
      let _: Void = try await cache.withTranscodedFile(
        source: source, sourceHash: String(repeating: "9", count: 64),
        profile: profile, metadata: metadata, artwork: nil, settings: settings
      ) { cached in
        failedPrivateURL = cached
        throw InjectedConsumerError.stagingFailed
      }
      Issue.record("the consumer's staging failure must be preserved")
    } catch let error as InjectedConsumerError {
      #expect((error) == (.stagingFailed))
    }

    let rejectedPrivateURL = try #require(failedPrivateURL)
    #expect(!(FileManager.default.fileExists(atPath: rejectedPrivateURL.path)))
    #expect(!(FileManager.default.fileExists(atPath: rejectedPrivateURL.deletingLastPathComponent().path)))
    let cacheSize = try await cache.totalSizeBytes()
    #expect((cacheSize) <= (1_000))
  }

  @MainActor
  @Test
  func testAppStateRetainsMeasuredCacheSizeWhenClearInspectionFails() async throws {
    let failures = InspectionFailureToggle()
    let cache = makeTranscodeCache(
      directory: cacheDir, inspectionHook: { try failures.inspect($0) })
    let artifact = cache.cachedFileURL(
      sourceHash: String(repeating: "4", count: 64),
      profile: TranscodeProfile(bitrateKbps: 256))
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 1_000).write(to: artifact)
    let app = AppState(
      library: LibraryStore(folderURL: libraryDir), transcodeCache: cache)

    app.refreshTranscodeCacheSize()
    await waitUntil { app.transcodeCacheSizeBytes == 1_000 }
    #expect((app.transcodeCacheSizeBytes) == (1_000))
    #expect(app.transcodeCacheError == nil)

    failures.set(.enumeration)
    app.clearTranscodeCache()
    await waitUntil { !app.isClearingTranscodeCache }
    #expect(!(app.isClearingTranscodeCache))
    #expect((app.transcodeCacheSizeBytes) == (1_000))
    #expect(app.transcodeCacheError != nil)
    #expect(FileManager.default.fileExists(atPath: artifact.path))
  }

  @MainActor
  @Test
  func testClearSupersedesAnOlderInFlightCacheRefresh() async throws {
    let barriers = EnumerationBarriers()
    let cache = makeTranscodeCache(
      directory: cacheDir, inspectionHook: { try barriers.inspect($0) })
    let artifact = cache.cachedFileURL(
      sourceHash: String(repeating: "6", count: 64),
      profile: TranscodeProfile(bitrateKbps: 256))
    try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    try Data(repeating: 0xAB, count: 1_000).write(to: artifact)
    let app = AppState(
      library: LibraryStore(folderURL: libraryDir), transcodeCache: cache)

    app.refreshTranscodeCacheSize()
    await waitUntil { barriers.callCount >= 1 }
    #expect((barriers.callCount) == (1))

    app.clearTranscodeCache()
    barriers.release(1)
    await waitUntil { barriers.callCount >= 2 }
    #expect((barriers.callCount) == (2))
    let refreshResultIgnored = await holds(for: .milliseconds(40)) {
      app.transcodeCacheSizeBytes == 0
    }
    #expect(
      refreshResultIgnored, Comment(rawValue: "the refresh result must be ignored once a newer clear has started"))
    #expect(app.isClearingTranscodeCache)

    barriers.release(2)
    await waitUntil { !app.isClearingTranscodeCache }
    #expect(!(app.isClearingTranscodeCache))
    #expect((app.transcodeCacheSizeBytes) == (0))
    #expect(!(FileManager.default.fileExists(atPath: artifact.path)))
  }

  @MainActor
  @Test
  func testRefreshRequestedDuringClearCannotPublishPreClearSize() async throws {
    let clearStarted = TestGate()
    let allowClear = TestGate()
    let cache = PausingTranscodeCacheMaintenance(
      size: 1_000, clearStarted: clearStarted, allowClear: allowClear)
    let app = AppState(
      library: LibraryStore(folderURL: libraryDir), transcodeCache: cache)

    app.refreshTranscodeCacheSize()
    let initialSizeLoaded = await waitUntil {
      app.transcodeCacheSizeBytes == 1_000
    }
    #expect(initialSizeLoaded)

    app.clearTranscodeCache()
    await clearStarted.wait()
    #expect(app.isClearingTranscodeCache)

    app.refreshTranscodeCacheSize()
    let neverObservedStaleMeasurement = await holds(for: .seconds(1)) {
      !(await cache.observedPreClearMeasurement)
    }
    #expect(neverObservedStaleMeasurement)

    await allowClear.signal()
    let clearFinished = await waitUntil { !app.isClearingTranscodeCache }
    #expect(clearFinished)
    #expect((app.transcodeCacheSizeBytes) == (0))
    let currentSize = await cache.currentSize
    #expect((currentSize) == (0))
  }

  @MainActor
  @Test
  func testCanceledCacheRefreshCannotPublishLateFailure() async throws {
    let firstStarted = TestGate()
    let releaseFirst = TestGate()
    let firstFinished = TestGate()
    let cache = StaleFailingCacheMaintenance(
      firstStarted: firstStarted, releaseFirst: releaseFirst, firstFinished: firstFinished)
    let app = AppState(
      library: LibraryStore(folderURL: libraryDir), transcodeCache: cache)

    app.refreshTranscodeCacheSize()
    await firstStarted.wait()
    app.refreshTranscodeCacheSize()
    let replacementPublished = await waitUntil {
      app.transcodeCacheSizeBytes == 2_000
    }
    #expect(replacementPublished)
    #expect(app.transcodeCacheError == nil)

    await releaseFirst.signal()
    await firstFinished.wait()
    let lateFailureSuppressed = await holds(for: .milliseconds(40)) {
      app.transcodeCacheSizeBytes == 2_000 && app.transcodeCacheError == nil
    }
    #expect(lateFailureSuppressed)
  }

  @Test
  func testTranscodeHandoffScavengesOnlyDeadProcessDirectories() async throws {
    let fm = FileManager.default
    let root: URL = handoffRoot
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let dead = root.appendingPathComponent(
      "\(pid_t.max)-\(UUID().uuidString)", isDirectory: true)
    let live = root.appendingPathComponent(
      "\(Darwin.getpid())-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: dead, withIntermediateDirectories: false)
    try fm.createDirectory(at: live, withIntermediateDirectories: false)
    try Data(repeating: 0xAB, count: 1_000).write(
      to: dead.appendingPathComponent("encoded.m4a"))
    defer {
      try? fm.removeItem(at: dead)
      try? fm.removeItem(at: live)
    }

    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: StubPayloadEncoder(counter: EncodeCounter(), payloadBytes: 1_000))
    let source = libraryDir.appendingPathComponent("handoff-cleanup.bin")
    try Data("source".utf8).write(to: source)
    _ = try await cache.withTranscodedFile(
      source: source, sourceHash: String(repeating: "9", count: 64),
      profile: TranscodeProfile(), metadata: TrackMetadata(track(named: "Cleanup.flac")),
      artwork: nil
    ) { try Data(contentsOf: $0) }

    #expect(!(fm.fileExists(atPath: dead.path)))
    #expect(
      fm.fileExists(atPath: live.path), Comment(rawValue: "cleanup must not remove a handoff owned by a live process"))
  }

  @Test
  func testExternalProcessClearDoesNotInvalidatePrivateSnapshots() async throws {
    let cache = makeTranscodeCache(
      directory: cacheDir,
      encoder: StubPayloadEncoder(counter: EncodeCounter(), payloadBytes: 1_000))
    let profile = TranscodeProfile(bitrateKbps: 256)
    let hash = String(repeating: "5", count: 64)
    let source = libraryDir.appendingPathComponent("external-lock.bin")
    try Data("source".utf8).write(to: source)
    let metadata = TrackMetadata(track(named: "External Lock.flac"))
    try await cache.withTranscodedFile(
      source: source, sourceHash: hash, profile: profile,
      metadata: metadata, artwork: nil
    ) { _ in }

    let firstStarted = TestGate()
    let secondStarted = TestGate()
    let releaseFirst = TestGate()
    let releaseSecond = TestGate()
    let cacheDirectory = try #require(cacheDir)
    let first = Task<Data, any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { snapshot in
        #expect(!(snapshot.path.hasPrefix(cacheDirectory.path)))
        await firstStarted.signal()
        await releaseFirst.wait()
        return try Data(contentsOf: snapshot)
      }
    }
    let second = Task<Data, any Error> {
      try await cache.withTranscodedFile(
        source: source, sourceHash: hash, profile: profile,
        metadata: metadata, artwork: nil
      ) { snapshot in
        #expect(!(snapshot.path.hasPrefix(cacheDirectory.path)))
        await secondStarted.signal()
        await releaseSecond.wait()
        return try Data(contentsOf: snapshot)
      }
    }
    await firstStarted.wait()
    await secondStarted.wait()

    let productsDirectory = Bundle(for: DeviceFormatSyncTests.self).bundleURL
      .deletingLastPathComponent()
    let executable = productsDirectory.appendingPathComponent("Nightdrive")
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
    let marker = scratch.appendingPathComponent("external-clear-started")
    let process = Process()
    process.executableURL = executable
    process.arguments = ["__test-clear-transcode-cache", cacheDir.path, marker.path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    defer {
      if process.isRunning {
        process.terminate()
        process.waitUntilExit()
      }
    }

    let childStarted = await waitUntil(timeout: .seconds(5)) {
      FileManager.default.fileExists(atPath: marker.path)
    }
    #expect(childStarted)
    let childFinished = await waitUntil(timeout: .seconds(5)) { !process.isRunning }
    #expect(childFinished, Comment(rawValue: "clear should not wait for private snapshot consumers"))
    #expect((process.terminationStatus) == (0))
    let artifact = cache.cachedFileURL(sourceHash: hash, profile: profile)
    #expect(!(FileManager.default.fileExists(atPath: artifact.path)))

    await releaseFirst.signal()
    await releaseSecond.signal()
    let firstPayload = try await first.value
    let secondPayload = try await second.value
    #expect((firstPayload.count) == (1_000))
    #expect((secondPayload.count) == (1_000))
  }

  private func makeFakeIpod(model: String) throws -> URL {
    let dir = scratch.appendingPathComponent(
      "IPOD-\(model)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let fs = try makeFakeIpodVolume(at: dir)
    try fs.writeDatabase(ITunesDatabase())
    try Data("ModelNumStr: x\(model)\n".utf8).write(to: fs.sysInfoURL)
    return dir
  }

  private func writeFLAC(
    to url: URL, seconds: Double = 1.0, frequency: Double = 440
  ) throws {
    try writeAudioFixture(
      to: url, formatID: kAudioFormatFLAC, seconds: seconds, frequency: frequency)
  }

  private func track(named name: String) -> LibraryTrack {
    LibraryTrack(
      url: URL(fileURLWithPath: "/Music/\(name)"), title: name, artist: "Artist", album: "Album", genre: "Genre",
      trackNumber: 1, trackCount: 1, discNumber: 1, year: 2026, durationMS: 1_000, sizeBytes: 1_000, bitrate: 256,
      samplerate: 44_100)
  }
}

private actor EncodeCounter {
  private(set) var count = 0
  func record() { count += 1 }
}

private struct CountingAACEncoder: TranscodeEncoder {
  let counter: EncodeCounter

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    await counter.record()
    try await AVFoundationAACEncoder().encode(
      source: source, destination: destination, profile: profile,
      metadata: metadata, artwork: artwork)
  }
}

private struct StubPayloadEncoder: TranscodeEncoder {
  let counter: EncodeCounter
  let payloadBytes: Int

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    await counter.record()
    try Data(repeating: 0xAB, count: payloadBytes).write(to: destination)
  }
}

private struct CancellationFailingEncoder: TranscodeEncoder {
  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    throw CancellationError()
  }
}

private struct SourceMutatingCopyEncoder: TranscodeEncoder {
  let original: URL
  let replacement: Data

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    try replacement.write(to: original, options: .atomic)
    try FileManager.default.copyItem(at: source, to: destination)
  }
}

private actor PausingTranscodeCacheMaintenance: TranscodeCacheMaintenance {
  private var size: Int64
  private var clearIsWaiting = false
  private(set) var observedPreClearMeasurement = false
  let clearStarted: TestGate
  let allowClear: TestGate

  init(size: Int64, clearStarted: TestGate, allowClear: TestGate) {
    self.size = size
    self.clearStarted = clearStarted
    self.allowClear = allowClear
  }

  var currentSize: Int64 { size }

  func totalSizeBytes() async throws -> Int64 {
    if clearIsWaiting { observedPreClearMeasurement = true }
    return size
  }

  func clear() async throws {
    clearIsWaiting = true
    await clearStarted.signal()
    await allowClear.wait()
    size = 0
    clearIsWaiting = false
  }
}

private actor StaleFailingCacheMaintenance: TranscodeCacheMaintenance {
  private let firstStarted: TestGate
  private let releaseFirst: TestGate
  private let firstFinished: TestGate
  private var measurements = 0

  init(firstStarted: TestGate, releaseFirst: TestGate, firstFinished: TestGate) {
    self.firstStarted = firstStarted
    self.releaseFirst = releaseFirst
    self.firstFinished = firstFinished
  }

  func totalSizeBytes() async throws -> Int64 {
    measurements += 1
    guard measurements == 1 else { return 2_000 }
    await firstStarted.signal()
    await releaseFirst.wait()
    await firstFinished.signal()
    throw InjectedInspectionError.failure
  }

  func clear() async throws {}
}

private actor URLCapture {
  private(set) var url: URL?

  func record(_ url: URL) {
    self.url = url
  }
}

private struct PausingPayloadEncoder: TranscodeEncoder {
  var counter: EncodeCounter?
  let started: TestGate
  let release: TestGate

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    if let counter { await counter.record() }
    try Data(repeating: 0xAB, count: 1_000).write(to: destination)
    await started.signal()
    await release.wait()
  }
}

private struct HoldingPayloadEncoder: TranscodeEncoder {
  let counter: EncodeCounter
  let release: TestGate

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    await counter.record()
    try Data(repeating: 0xAB, count: 1_000).write(to: destination)
    await release.wait()
  }
}

private enum InjectedInspectionError: Error {
  case failure
}

private enum InjectedConsumerError: Error, Equatable {
  case stagingFailed
}

private final class InspectionFailureToggle: Sendable {
  enum Mode {
    case none
    case enumeration
    case metadata
  }

  private let mode = Mutex(Mode.none)

  func set(_ mode: Mode) {
    self.mode.withLock { $0 = mode }
  }

  func inspect(_ operation: TranscodeCacheInspectionOperation) throws {
    switch (mode.withLock { $0 }, operation) {
    case (.enumeration, .enumerateDirectory), (.metadata, .readMetadata):
      throw InjectedInspectionError.failure
    default:
      break
    }
  }
}

private final class EnumerationBarriers: @unchecked Sendable {
  private let condition = NSCondition()
  private var calls = 0
  private var released: Set<Int> = []

  var callCount: Int {
    condition.lock()
    defer { condition.unlock() }
    return calls
  }

  func inspect(_ operation: TranscodeCacheInspectionOperation) throws {
    guard case .enumerateDirectory = operation else { return }
    condition.lock()
    calls += 1
    let call = calls
    condition.broadcast()
    while call <= 2, !released.contains(call) { condition.wait() }
    condition.unlock()
  }

  func release(_ call: Int) {
    condition.lock()
    released.insert(call)
    condition.broadcast()
    condition.unlock()
  }
}

private final class ProgressBox: Sendable {
  private let details = Mutex<[String]>([])

  func append(_ detail: String) {
    details.withLock { $0.append(detail) }
  }

  func all() -> [String] {
    details.withLock { $0 }
  }
}
