import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct MP3DurationValidationTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  @Test
  func testForgedHugeXingFallsBackToPhysicalFramesAndCachesSafeFacts() async throws {
    let url = scratch.appendingPathComponent("forged-xing.mp3")
    var bytes = fixture(seconds: 1)
    let xing = try #require(bytes.range(of: Data("Info".utf8))?.lowerBound)
    bytes.replaceSubrange(xing..<(xing + 4), with: Data("Xing".utf8))
    putU32(UInt32.max, into: &bytes, at: xing + 8)
    putU32(UInt32(bytes.count), into: &bytes, at: xing + 12)
    try bytes.write(to: url)

    let reportedSeconds = try await AVURLAsset(url: url).load(.duration).seconds
    #expect((reportedSeconds) > (100_000_000), Comment(rawValue: "fixture must reproduce the forged Xing"))

    let audioFile = try AVAudioFile(forReading: url)
    let decoderSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    var cancellationChecks = 0
    let guardedFacts = try #require(
      MP3DurationValidator.inspect(
        url: url, assetSeconds: reportedSeconds, decoderSeconds: decoderSeconds,
        isCancelled: {
          cancellationChecks += 1
          return false
        }))
    #expect((cancellationChecks) > (0), Comment(rawValue: "suspicious declarations must retain the frame walk"))
    #expect((guardedFacts.physicalFrameCount) == (39))

    let loaded = await MetadataLoader.load(url: url)
    #expect((loaded.mediaValidation) == (.valid))
    #expect((loaded.durationMS) > (800))
    #expect((loaded.durationMS) < (1_300))
    #expect((loaded.bitrate) > (100))
    #expect((loaded.bitrate) < (200))

    let facts = try #require(MP3DurationValidator.inspect(bytes))
    #expect((facts.declaredFrameCount) == (UInt32.max))
    #expect((facts.physicalFrameCount) == (39))
    #expect((try #require(facts.physicalDurationSeconds)) < (1.3))

    let row = SyncEngine.makeDBTrack(
      from: loaded, ipodPath: ":iPod_Control:Music:F00:FORGED.MP3")
    #expect((row.lengthMS) == (UInt32(loaded.durationMS)))
    #expect((row.bitrate) == (UInt32(loaded.bitrate)))
    #expect((row.lengthMS) != (UInt32.max))
    #expect((row.bitrate) > (0))

    let cold = await LibraryStore.scanTracks(at: [url], consulting: [:])
    #expect((cold.tracks.first?.durationMS) == (loaded.durationMS))
    #expect((cold.tracks.first?.bitrate) == (loaded.bitrate))
    let loaderCalled = LockedDurationFlag()
    let warm = await LibraryStore.scanTracks(at: [url], consulting: cold.entries) { candidate in
      loaderCalled.set()
      return await MetadataLoader.load(url: candidate)
    }
    #expect(!(loaderCalled.value))
    #expect((warm.tracks.first?.durationMS) == (loaded.durationMS))
    #expect((warm.tracks.first?.bitrate) == (loaded.bitrate))
  }

  @Test
  func testNormalXingKeepsItsReportedVBRDuration() async throws {
    let url = scratch.appendingPathComponent("normal-xing.mp3")
    var bytes = fixture(seconds: 1)
    let xing = try #require(bytes.range(of: Data("Info".utf8))?.lowerBound)
    let firstFrameOffset = xing - 36
    bytes.replaceSubrange(xing..<(xing + 4), with: Data("Xing".utf8))
    putU32(39, into: &bytes, at: xing + 8)
    putU32(UInt32(bytes.count - firstFrameOffset), into: &bytes, at: xing + 12)
    try bytes.write(to: url)

    let assetSeconds = try await AVURLAsset(url: url).load(.duration).seconds
    let audioFile = try AVAudioFile(forReading: url)
    let decoderSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
    var cancellationChecks = 0
    let boundedFacts = try #require(
      MP3DurationValidator.inspect(
        url: url, assetSeconds: assetSeconds, decoderSeconds: decoderSeconds,
        isCancelled: {
          cancellationChecks += 1
          return false
        }))
    let loaded = await MetadataLoader.load(url: url)
    let facts = try #require(MP3DurationValidator.inspect(bytes))

    #expect((cancellationChecks) == (0), Comment(rawValue: "valid agreeing declarations must not walk audio frames"))
    #expect(boundedFacts.physicalFrameCount == nil)
    #expect(boundedFacts.physicalDurationSeconds == nil)
    #expect((facts.declaredFrameCount) == (39))
    #expect((facts.physicalFrameCount) == (39))
    #expect((loaded.mediaValidation) == (.valid))
    #expect(abs((Double(loaded.durationMS) / 1_000) - (assetSeconds)) <= 0.01)
    #expect((loaded.bitrate) > (100))
  }

  @Test
  func testXingWithoutByteCountRetainsPhysicalValidation() throws {
    let url = scratch.appendingPathComponent("xing-without-byte-count.mp3")
    var bytes = fixture(seconds: 1)
    let xing = try #require(bytes.range(of: Data("Info".utf8))?.lowerBound)
    bytes.replaceSubrange(xing..<(xing + 4), with: Data("Xing".utf8))
    putU32(0x1, into: &bytes, at: xing + 4)
    putU32(78, into: &bytes, at: xing + 8)
    try bytes.write(to: url)

    let declaredSeconds = Double(78 * 1_152) / 44_100
    var cancellationChecks = 0
    let facts = try #require(
      MP3DurationValidator.inspect(
        url: url, assetSeconds: declaredSeconds, decoderSeconds: declaredSeconds,
        isCancelled: {
          cancellationChecks += 1
          return false
        }))

    #expect((cancellationChecks) > (0))
    #expect(facts.declaredByteCount == nil)
    #expect((facts.physicalFrameCount) == (39))
  }

  @Test
  func testTruncatedXingOptionalFieldsNeverReadPastAvailableData() throws {
    let xingOffset = 4 + 32
    let boundaries: [(flags: UInt32, completeBytes: Int, truncatedFieldBytes: Int)] = [
      (0x1, 0, 1),
      (0x3, 4, 1),
      (0x7, 8, 1),
      (0xF, 108, 1),
    ]

    for boundary in boundaries {
      var data = Data([0xFF, 0xFB, 0x90, 0x00]) + Data(count: 32)
      data.append(Data("Xing".utf8))
      appendU32(boundary.flags, to: &data)
      data.append(Data(count: boundary.completeBytes + boundary.truncatedFieldBytes))

      let facts = try #require(MP3DurationValidator.inspect(data))
      #expect((data.count) == (xingOffset + 8 + boundary.completeBytes + boundary.truncatedFieldBytes))
      #expect(facts.declaredFrameCount == nil, Comment(rawValue: "flags \(boundary.flags)"))
      #expect(facts.declaredByteCount == nil, Comment(rawValue: "flags \(boundary.flags)"))
      #expect(facts.physicalDurationSeconds == nil, Comment(rawValue: "flags \(boundary.flags)"))
    }
  }

  @Test
  func testXingOptionalFieldsCannotCrossTheDeclaredFrameBoundary() throws {
    var data = Data([0xFF, 0xE3, 0x18, 0x00]) + Data(count: 17)
    data.append(Data("Xing".utf8))
    appendU32(0x7, to: &data)
    appendU32(10, to: &data)
    appendU32(720, to: &data)
    data.append(Data(count: 100))

    let facts = try #require(MP3DurationValidator.inspect(data))
    #expect(facts.declaredFrameCount == nil)
    #expect(facts.declaredByteCount == nil)
  }

  @Test
  func testCancellationStopsSuspiciousPhysicalValidationBeforeWalkingFrames() throws {
    let url = scratch.appendingPathComponent("cancelled-xing.mp3")
    var bytes = fixture(seconds: 1)
    let xing = try #require(bytes.range(of: Data("Info".utf8))?.lowerBound)
    bytes.replaceSubrange(xing..<(xing + 4), with: Data("Xing".utf8))
    putU32(UInt32.max, into: &bytes, at: xing + 8)
    putU32(UInt32(bytes.count), into: &bytes, at: xing + 12)
    try bytes.write(to: url)

    var cancellationChecks = 0
    let facts = try #require(
      MP3DurationValidator.inspect(
        url: url, assetSeconds: .infinity, decoderSeconds: .infinity,
        isCancelled: {
          cancellationChecks += 1
          return true
        }))

    #expect((cancellationChecks) == (1))
    #expect(facts.physicalFrameCount == nil)
    #expect(facts.physicalDurationSeconds == nil)
  }

  @Test
  func testRealLongEightKilobitMP3RemainsValid() async throws {
    let url = scratch.appendingPathComponent("long-low-bitrate.mp3")
    let bytes = lowBitrateFixture(seconds: 10 * 60)
    try bytes.write(to: url)

    let loaded = await MetadataLoader.load(url: url)

    #expect((bytes.count) < (1_000_000))
    #expect((loaded.mediaValidation) == (.valid))
    #expect((loaded.durationMS) > (590_000))
    #expect((loaded.durationMS) < (610_000))
    #expect((loaded.bitrate) == (8))
  }

  @Test
  func testLegitimateLongEightKilobitBoundaryIsNotCapped() {
    let twelveHours = 12.0 * 60 * 60
    let bytesAtEightKilobits = 43_200_000
    let facts = MP3DurationFacts(
      minimumBitrate: 8_000,
      declaredFrameCount: nil, declaredByteCount: nil,
      physicalFrameCount: nil, physicalDurationSeconds: nil)

    #expect(
      (MP3DurationValidator.resolveDurationSeconds(
        assetSeconds: twelveHours, decoderSeconds: twelveHours,
        fileSizeBytes: bytesAtEightKilobits, facts: facts)) == (twelveHours))
    #expect((MP3DurationValidator.checkedMilliseconds(seconds: twelveHours)) == (43_200_000))
    #expect(
      (MP3DurationValidator.checkedBitrateKbps(
        sizeBytes: bytesAtEightKilobits, durationMS: 43_200_000)) == (8))
  }

  @Test
  func testDurationPlausibilityEnforcesTheLegalCodecBitrateFloor() {
    let facts = MP3DurationFacts(
      minimumBitrate: 8_000,
      declaredFrameCount: nil, declaredByteCount: nil,
      physicalFrameCount: nil, physicalDurationSeconds: nil)

    #expect(
      (MP3DurationValidator.resolveDurationSeconds(
        assetSeconds: 1, decoderSeconds: nil, fileSizeBytes: 1_000, facts: facts)) == (1),
      Comment(rawValue: "exactly 8 kbps is legal"))
    #expect(
      MP3DurationValidator.resolveDurationSeconds(
        assetSeconds: 2, decoderSeconds: nil, fileSizeBytes: 1_000, facts: facts) == nil,
      Comment(rawValue: "an 8 kbps stream cannot average 4 kbps"))
  }

  @Test
  func testDurationAndBitrateArithmeticRejectsUnsafeValuesWithoutTrapping() {
    #expect(MP3DurationValidator.checkedMilliseconds(seconds: -.infinity) == nil)
    #expect(MP3DurationValidator.checkedMilliseconds(seconds: .infinity) == nil)
    #expect(MP3DurationValidator.checkedMilliseconds(seconds: .nan) == nil)
    #expect(MP3DurationValidator.checkedMilliseconds(seconds: -1) == nil)
    #expect(MP3DurationValidator.checkedMilliseconds(seconds: Double.greatestFiniteMagnitude) == nil)
    #expect((MP3DurationValidator.checkedMilliseconds(seconds: 1.25)) == (1_250))

    #expect(MP3DurationValidator.checkedBitrateKbps(sizeBytes: -1, durationMS: 1) == nil)
    #expect(MP3DurationValidator.checkedBitrateKbps(sizeBytes: 1, durationMS: 0) == nil)
    #expect(
      MP3DurationValidator.resolveDurationSeconds(
        assetSeconds: .infinity, decoderSeconds: -.infinity,
        fileSizeBytes: Int.max, facts: nil) == nil)
  }

  private func fixture(seconds: Double) -> Data {
    MP3Builder.build(
      tags: .init(
        title: "Boundary", artist: "Tester", album: "Diagnostics",
        genre: "Test", trackNumber: 1, year: 2026),
      seconds: seconds, sampleRate: 44_100,
      gapless: .init(encoderDelay: 576, encoderPadding: 1_728))
  }

  private func lowBitrateFixture(seconds: Double) -> Data {
    let frame = Data([0xFF, 0xE3, 0x18, 0x00]) + Data(count: 68)
    let frameCount = Int((seconds / 0.072).rounded(.up))
    var data = Data(capacity: frame.count * frameCount)
    for _ in 0..<frameCount { data.append(frame) }
    return data
  }

  private func putU32(_ value: UInt32, into data: inout Data, at offset: Int) {
    data.replaceSubrange(
      offset..<(offset + 4),
      with: [
        UInt8(value >> 24), UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
      ])
  }

  private func appendU32(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
      UInt8(value >> 24), UInt8((value >> 16) & 0xff),
      UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
    ])
  }
}

private final class LockedDurationFlag: Sendable {
  private let storage = Mutex(false)

  func set() {
    storage.withLock { $0 = true }
  }

  var value: Bool {
    storage.withLock { $0 }
  }
}
