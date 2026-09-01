import AVFoundation
import Foundation

enum LoudnessAnalyzer {
  static let referenceLUFS: Double = -18.0
  static let maxGainDB: Double = 24.0

  struct Biquad {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
    private var z1: Double = 0
    private var z2: Double = 0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
      self.b0 = b0
      self.b1 = b1
      self.b2 = b2
      self.a1 = a1
      self.a2 = a2
    }

    mutating func process(_ x: Double) -> Double {
      let y = b0 * x + z1
      z1 = b1 * x - a1 * y + z2
      z2 = b2 * x - a2 * y
      return y
    }
  }

  static func kWeightingShelf(sampleRate: Double) -> Biquad {
    let gainDB = 3.999843853973347
    let f0 = 1681.974450955533
    let q = 0.7071752369554196
    let k = tan(.pi * f0 / sampleRate)
    let vh = pow(10.0, gainDB / 20.0)
    let vb = pow(vh, 0.4996667741545416)
    let a0 = 1 + k / q + k * k
    return Biquad(
      b0: (vh + vb * k / q + k * k) / a0,
      b1: 2 * (k * k - vh) / a0,
      b2: (vh - vb * k / q + k * k) / a0,
      a1: 2 * (k * k - 1) / a0,
      a2: (1 - k / q + k * k) / a0)
  }

  static func kWeightingHighPass(sampleRate: Double) -> Biquad {
    let f0 = 38.13547087602444
    let q = 0.5003270373238773
    let k = tan(.pi * f0 / sampleRate)
    let a0 = 1 + k / q + k * k
    return Biquad(
      b0: 1, b1: -2, b2: 1,
      a1: 2 * (k * k - 1) / a0,
      a2: (1 - k / q + k * k) / a0)
  }

  static func measureLoudness(url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    guard format.sampleRate > 0, channelCount > 0, file.length > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65536)
    else { return nil }

    var shelves = [Biquad](
      repeating: kWeightingShelf(sampleRate: format.sampleRate), count: channelCount)
    var highPasses = [Biquad](
      repeating: kWeightingHighPass(sampleRate: format.sampleRate), count: channelCount)
    var sumSquares = [Double](repeating: 0, count: channelCount)
    var totalFrames = 0

    while file.framePosition < file.length {
      do {
        try file.read(into: buffer)
      } catch {
        break
      }
      let frames = Int(buffer.frameLength)
      guard frames > 0, let channels = buffer.floatChannelData else { break }
      for channel in 0..<channelCount {
        let samples = channels[channel]
        var acc = 0.0
        for i in 0..<frames {
          let weighted = highPasses[channel].process(
            shelves[channel].process(Double(samples[i])))
          acc += weighted * weighted
        }
        sumSquares[channel] += acc
      }
      totalFrames += frames
    }
    guard totalFrames > 0 else { return nil }
    let energy = sumSquares.reduce(0, +) / Double(totalFrames)
    guard energy > 0 else { return nil }
    return -0.691 + 10 * log10(energy)
  }

  static func gainDB(forMeasuredLoudness lufs: Double) -> Double {
    min(max(referenceLUFS - lufs, -maxGainDB), maxGainDB)
  }

  static func measureGain(url: URL) -> Double? {
    measureLoudness(url: url).map(gainDB(forMeasuredLoudness:))
  }

  static func soundcheckValue(gainDB: Double) -> UInt32 {
    let clamped = min(max(gainDB, -maxGainDB), maxGainDB)
    let value = (1000.0 * pow(10.0, -clamped / 10.0)).rounded()
    return UInt32(clamping: Int64(max(1, value)))
  }

  static func playbackScale(gainDB: Double) -> Double {
    pow(10.0, min(max(gainDB, -maxGainDB), maxGainDB) / 20.0)
  }
}
