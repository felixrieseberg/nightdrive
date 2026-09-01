import AVFoundation
import Foundation
import Testing

@testable import Nightdrive

struct SpectrumAnalyzerTests {
  private func tone(_ frequency: Double, sampleRate: Double = 44100) -> [Float] {
    (0..<SpectrumAnalyzer.size).map {
      Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate))
    }
  }

  private func expectedBand(for f: Double) -> Int {
    Int(Double(SpectrumAnalyzer.bandCount) * log(f / 40) / log(16000.0 / 40.0))
  }

  @Test
  func testToneLandsInItsBand() throws {
    let analyzer = try #require(SpectrumAnalyzer(sampleRate: 44100))
    for frequency in [100.0, 1000.0, 8000.0] {
      let bands = analyzer.bands(from: tone(frequency))
      #expect(bands.count == SpectrumAnalyzer.bandCount)
      let loudest = try #require(bands.indices.max(by: { bands[$0] < bands[$1] }))
      #expect(
        abs(loudest - expectedBand(for: frequency)) <= 1, Comment(rawValue: "\(frequency) Hz peaked in band \(loudest)")
      )
      #expect(bands[loudest] > 0.5, Comment(rawValue: "\(frequency) Hz tone should light the meter"))
      let far = (loudest + SpectrumAnalyzer.bandCount / 2) % SpectrumAnalyzer.bandCount
      #expect(bands[far] < bands[loudest] / 2)
    }
  }

  @Test
  func testSilenceReadsFlat() throws {
    let analyzer = try #require(SpectrumAnalyzer(sampleRate: 44100))
    let bands = analyzer.bands(from: [Float](repeating: 0, count: SpectrumAnalyzer.size))
    #expect(bands == [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
  }

  @Test
  func testAnalyzerWritesIntoReusableBandStorage() throws {
    let analyzer = try #require(SpectrumAnalyzer(sampleRate: 44100))
    var workspace = SpectrumAnalyzer.Workspace()
    var bands = [Float](repeating: -1, count: SpectrumAnalyzer.bandCount)

    analyzer.bands(
      from: [Float](repeating: 0, count: SpectrumAnalyzer.size), into: &bands,
      workspace: &workspace)

    #expect(bands == [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
  }

  @Test
  func testAnalyzerKeepsReusableBandStorageSizedForInvalidInput() throws {
    let analyzer = try #require(SpectrumAnalyzer(sampleRate: 44100))
    var workspace = SpectrumAnalyzer.Workspace()
    var bands = [Float](repeating: 1, count: SpectrumAnalyzer.bandCount)

    analyzer.bands(from: [0], into: &bands, workspace: &workspace)

    #expect(bands == [Float](repeating: 0, count: SpectrumAnalyzer.bandCount))
  }

  @Test
  func testLouderToneReadsHigher() throws {
    let analyzer = try #require(SpectrumAnalyzer(sampleRate: 44100))
    let quiet = tone(1000).map { $0 * 0.05 }
    let band = expectedBand(for: 1000)
    let loudValue = analyzer.bands(from: tone(1000))[band]
    let quietValue = analyzer.bands(from: quiet)[band]
    #expect(loudValue > quietValue)
    #expect(quietValue > 0, Comment(rawValue: "a quiet tone still registers"))
  }

  @Test
  func testTapRingKeepsNewestSamplesInOldestToNewestOrder() throws {
    let ring = TapRing()
    let values = (1...(SpectrumAnalyzer.size + 17)).map(Float.init)

    ring.push(try Self.audioBuffer(values))

    #expect(ring.snapshot() == Array(values.suffix(SpectrumAnalyzer.size)))
  }

  @Test
  func testTapRingResetHidesEarlierSamplesWithoutReallocation() throws {
    let ring = TapRing()
    ring.push(try Self.audioBuffer([1, 2, 3]))

    ring.reset()
    #expect(ring.snapshot() == [Float](repeating: 0, count: SpectrumAnalyzer.size))

    ring.push(try Self.audioBuffer([4, 5]))
    let snapshot = ring.snapshot()
    #expect(snapshot.dropLast(2) == [Float](repeating: 0, count: SpectrumAnalyzer.size - 2))
    #expect(snapshot.suffix(2) == [4, 5])
  }

  @Test
  func testTapRingSnapshotsRemainOrderedDuringConcurrentPushes() async throws {
    let ring = TapRing()
    async let writer: Void = Self.pushConcurrentSamples(into: ring)
    async let readerResult = Self.readConcurrentSamples(from: ring)

    await writer
    let snapshotsStayedOrdered = await readerResult
    #expect(snapshotsStayedOrdered)
  }

  private static func pushConcurrentSamples(into ring: TapRing) async {
    for batch in 0..<2_000 {
      let first = batch * 32 + 1
      let values = (first..<(first + 32)).map(Float.init)
      ring.push(try! audioBuffer(values))
      if batch.isMultiple(of: 8) { await Task.yield() }
    }
  }

  private static func readConcurrentSamples(from ring: TapRing) async -> Bool {
    var sawSamples = false
    for _ in 0..<2_000 {
      let samples = ring.snapshot().drop { $0 == 0 }
      if let first = samples.first {
        sawSamples = true
        for (offset, sample) in samples.enumerated()
        where sample != first + Float(offset) {
          return false
        }
      }
      await Task.yield()
    }
    return sawSamples
  }

  private static func audioBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
        channels: 1, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try #require(buffer.floatChannelData?[0])
    for (index, sample) in samples.enumerated() {
      channel[index] = sample
    }
    return buffer
  }

  @Test
  func testTapRingDownmixesRightOnlyStereo() throws {
    let buffer = try makeBuffer(channels: 2, frameCount: 4)
    let channels = try #require(buffer.floatChannelData)
    for frame in 0..<4 {
      channels[0][frame] = 0
      channels[1][frame] = Float(frame + 1)
    }

    let ring = TapRing()
    ring.push(buffer)

    #expect(Array(ring.snapshot().suffix(4)) == [0.5, 1, 1.5, 2])
  }

  @Test
  func testTapRingPreservesMonoSamples() throws {
    let buffer = try makeBuffer(channels: 1, frameCount: 4)
    let channel = try #require(buffer.floatChannelData)[0]
    let expected: [Float] = [-0.75, -0.25, 0.25, 0.75]
    for frame in expected.indices {
      channel[frame] = expected[frame]
    }

    let ring = TapRing()
    ring.push(buffer)

    #expect(Array(ring.snapshot().suffix(expected.count)) == expected)
  }

  @Test
  func testTapRingDownmixesInterleavedStereo() throws {
    let buffer = try makeBuffer(channels: 2, frameCount: 3, interleaved: true)
    let samples = try #require(buffer.floatChannelData)[0]
    let stereo: [Float] = [0, 0.5, 0.25, 0.75, 0.5, 1]
    for index in stereo.indices {
      samples[index] = stereo[index]
    }

    let ring = TapRing()
    ring.push(buffer)

    #expect(Array(ring.snapshot().suffix(3)) == [0.25, 0.5, 0.75])
  }

  private func makeBuffer(
    channels: AVAudioChannelCount,
    frameCount: AVAudioFrameCount,
    interleaved: Bool = false
  ) throws -> AVAudioPCMBuffer {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 44_100,
        channels: channels,
        interleaved: interleaved))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
    buffer.frameLength = frameCount
    return buffer
  }
}
