import AVFoundation
import Foundation

/// Confirms that one candidate is a contiguous excerpt of another by
/// comparing coarse decoded-audio fingerprints. Fingerprints live only for
/// one Find Duplicates scan and are never written to disk.
final class PartialAudioMatcher {
  private struct Fingerprint {
    let energy: [Double]
    let texture: [Double]
  }

  private static let windowSeconds = 0.5
  private static let minimumWindows = 30
  private static let edgeTrimWindows = 2

  private var fingerprints: [URL: Fingerprint?] = [:]

  func matches(
    _ lhs: URL, _ rhs: URL, isCancelled: () -> Bool = { false }
  ) -> Bool {
    guard !isCancelled(),
      let lhsFingerprint = fingerprint(for: lhs, isCancelled: isCancelled),
      !isCancelled(),
      let rhsFingerprint = fingerprint(for: rhs, isCancelled: isCancelled)
    else { return false }
    return Self.matches(lhsFingerprint, rhsFingerprint, isCancelled: isCancelled)
  }

  private func fingerprint(for url: URL, isCancelled: () -> Bool) -> Fingerprint? {
    if let cached = fingerprints[url] { return cached }
    let fingerprint = Self.readFingerprint(url: url, isCancelled: isCancelled)
    guard !isCancelled() else { return nil }
    fingerprints[url] = fingerprint
    return fingerprint
  }

  private static func readFingerprint(
    url: URL, isCancelled: () -> Bool
  ) -> Fingerprint? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    let windowFrames = Int(format.sampleRate * windowSeconds)
    guard format.commonFormat == .pcmFormatFloat32, channelCount > 0,
      windowFrames > 0,
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(max(windowFrames, 65_536)))
    else { return nil }

    var energy: [Double] = []
    var texture: [Double] = []
    var sumSquares = 0.0
    var sumDifferences = 0.0
    var samplesInWindow = 0
    var previousSample: Double?

    while file.framePosition < file.length {
      guard !isCancelled() else { return nil }
      do {
        try file.read(into: buffer)
      } catch {
        return nil
      }
      let frameCount = Int(buffer.frameLength)
      guard frameCount > 0, let channels = buffer.floatChannelData else { break }
      for frame in 0..<frameCount {
        var mono = 0.0
        for channel in 0..<channelCount {
          mono += Double(channels[channel][frame])
        }
        mono /= Double(channelCount)
        sumSquares += mono * mono
        if let previousSample {
          sumDifferences += abs(mono - previousSample)
        }
        previousSample = mono
        samplesInWindow += 1
        if samplesInWindow == windowFrames {
          energy.append(10 * log10(sumSquares / Double(windowFrames) + 1e-12))
          texture.append(sumDifferences / Double(windowFrames))
          sumSquares = 0
          sumDifferences = 0
          samplesInWindow = 0
        }
      }
    }
    guard energy.count >= minimumWindows else { return nil }
    return Fingerprint(energy: energy, texture: texture)
  }

  private static func matches(
    _ lhs: Fingerprint, _ rhs: Fingerprint, isCancelled: () -> Bool
  ) -> Bool {
    let shorter: Fingerprint
    let longer: Fingerprint
    if lhs.energy.count <= rhs.energy.count {
      shorter = lhs
      longer = rhs
    } else {
      shorter = rhs
      longer = lhs
    }

    let trim = min(edgeTrimWindows, max(0, shorter.energy.count / 10))
    let shortEnergy = Array(shorter.energy.dropFirst(trim).dropLast(trim))
    let shortTexture = Array(shorter.texture.dropFirst(trim).dropLast(trim))
    guard shortEnergy.count >= minimumWindows else { return false }

    let lastOffset = longer.energy.count - trim - shortEnergy.count
    guard lastOffset >= trim else { return false }
    for offset in trim...lastOffset {
      guard !isCancelled() else { return false }
      let energyCorrelation = correlation(shortEnergy, longer.energy, offset: offset)
      guard energyCorrelation >= 0.92 else { continue }
      let textureCorrelation = correlation(shortTexture, longer.texture, offset: offset)
      if textureCorrelation >= 0.70 { return true }
    }
    return false
  }

  private static func correlation(
    _ needle: [Double], _ haystack: [Double], offset: Int
  ) -> Double {
    let count = Double(needle.count)
    let needleMean = needle.reduce(0, +) / count
    var haystackMean = 0.0
    for index in needle.indices { haystackMean += haystack[offset + index] }
    haystackMean /= count

    var covariance = 0.0
    var needleVariance = 0.0
    var haystackVariance = 0.0
    for index in needle.indices {
      let lhs = needle[index] - needleMean
      let rhs = haystack[offset + index] - haystackMean
      covariance += lhs * rhs
      needleVariance += lhs * lhs
      haystackVariance += rhs * rhs
    }
    let denominator = sqrt(needleVariance * haystackVariance)
    guard denominator > 1e-12 else { return -1 }
    return covariance / denominator
  }
}
