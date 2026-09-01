import AVFoundation
import Foundation
import Testing

@testable import Nightdrive

struct PartialAudioMatcherTests {
  @Test
  func testMatchesContiguousExcerptButRejectsDifferentAudio() throws {
    let folder = TestScratch.directory(prefix: "PartialAudioMatcher")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let sampleRate = 8_000
    let longSamples = samples(seconds: 32, sampleRate: sampleRate, variant: 0)
    let excerptRange = (5 * sampleRate)..<(25 * sampleRate)
    let excerptSamples = Array(longSamples[excerptRange])
    let differentSamples = samples(seconds: 20, sampleRate: sampleRate, variant: 1)

    let longURL = folder.appendingPathComponent("long.wav")
    let excerptURL = folder.appendingPathComponent("excerpt.wav")
    let differentURL = folder.appendingPathComponent("different.wav")
    try write(longSamples, sampleRate: sampleRate, to: longURL)
    try write(excerptSamples, sampleRate: sampleRate, to: excerptURL)
    try write(differentSamples, sampleRate: sampleRate, to: differentURL)

    let matcher = PartialAudioMatcher()
    #expect(matcher.matches(excerptURL, longURL))
    #expect(!(matcher.matches(differentURL, longURL)))
  }

  @Test
  func testCancellationSkipsAudioDecoding() {
    let matcher = PartialAudioMatcher()
    #expect(
      !(matcher.matches(
        URL(fileURLWithPath: "/does-not-need-to-exist-a.wav"),
        URL(fileURLWithPath: "/does-not-need-to-exist-b.wav"),
        isCancelled: { true })))
  }

  private func samples(seconds: Int, sampleRate: Int, variant: Int) -> [Float] {
    (0..<(seconds * sampleRate)).map { index in
      let time = Double(index) / Double(sampleRate)
      let window = Int(time * 2)
      let amplitudeStep = (window * (variant == 0 ? 17 : 7) + variant * 3) % 13
      let amplitude = 0.08 + Double(amplitudeStep) * 0.025
      let frequencyStep = (window * (variant == 0 ? 5 : 11) + variant * 7) % 9
      let frequency = 180.0 + Double(frequencyStep) * 47.0
      return Float(amplitude * sin(2 * .pi * frequency * time))
    }
  }

  private func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
    let format = AVAudioFormat(
      standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = buffer.frameCapacity
    let destination = buffer.floatChannelData![0]
    for index in samples.indices { destination[index] = samples[index] }
    try file.write(from: buffer)
  }
}
