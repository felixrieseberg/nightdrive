import AVFoundation
import Accelerate
import CAudioTapRing
import Foundation

final class SpectrumAnalyzer {
  static let bandCount = 28
  static let size = 2048
  private static let halfSize = size / 2

  /// Caller-owned buffers for allocation-free repeated analysis. Keeping this
  /// mutable workspace outside the analyzer leaves an initialized analyzer
  /// immutable and lets each caller control its own isolation.
  struct Workspace {
    fileprivate var windowed = [Float](repeating: 0, count: size)
    fileprivate var real = [Float](repeating: 0, count: halfSize)
    fileprivate var imaginary = [Float](repeating: 0, count: halfSize)
    fileprivate var magnitudes = [Float](repeating: 0, count: halfSize)
  }

  private let fft: vDSP.FFT<DSPSplitComplex>
  private let window: [Float]
  private let bandBins: [ClosedRange<Int>]

  init?(sampleRate: Double) {
    guard
      let fft = vDSP.FFT(
        log2n: vDSP_Length(log2(Double(Self.size))),
        radix: .radix2, ofType: DSPSplitComplex.self)
    else { return nil }
    self.fft = fft
    window = vDSP.window(
      ofType: Float.self, usingSequence: .hanningDenormalized,
      count: Self.size, isHalfWindow: false)
    let binHz = sampleRate / Double(Self.size)
    bandBins = (0..<Self.bandCount).map { band in
      let f0 = 40.0 * pow(16000.0 / 40.0, Double(band) / Double(Self.bandCount))
      let f1 = 40.0 * pow(16000.0 / 40.0, Double(band + 1) / Double(Self.bandCount))
      let lo = min(Self.halfSize - 1, max(1, Int(f0 / binHz)))
      let hi = min(Self.halfSize - 1, max(lo, Int(f1 / binHz)))
      return lo...hi
    }
  }

  func bands(from samples: [Float]) -> [Float] {
    var workspace = Workspace()
    var result = [Float](repeating: 0, count: Self.bandCount)
    bands(from: samples, into: &result, workspace: &workspace)
    return result
  }

  /// Writes into caller-owned storage so the playback ticker can reuse all of
  /// its FFT buffers instead of allocating several arrays for every frame.
  func bands(from samples: [Float], into result: inout [Float], workspace: inout Workspace) {
    if result.count != Self.bandCount {
      result = [Float](repeating: 0, count: Self.bandCount)
    }
    guard samples.count == Self.size else {
      result.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }
      return
    }
    vDSP.multiply(samples, window, result: &workspace.windowed)
    workspace.real.withUnsafeMutableBufferPointer { re in
      workspace.imaginary.withUnsafeMutableBufferPointer { im in
        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
        workspace.windowed.withUnsafeBytes { raw in
          let complex = raw.bindMemory(to: DSPComplex.self)
          vDSP_ctoz(complex.baseAddress!, 2, &split, 1, vDSP_Length(Self.halfSize))
        }
        fft.forward(input: split, output: &split)
        vDSP_zvmags(&split, 1, &workspace.magnitudes, 1, vDSP_Length(Self.halfSize))
      }
    }
    for (band, bins) in bandBins.enumerated() {
      var sum: Float = 0
      for bin in bins { sum += workspace.magnitudes[bin] }
      let normalized = sum / Float(bins.count) / Float(Self.size * Self.size)
      let db = 10 * log10(normalized + .leastNormalMagnitude)
      result[band] = min(1, max(0, (db + 54) / 48))
    }
  }
}

/// Preallocated lock-free ring of the most recently rendered samples. The
/// audio tap is the single producer; the main-thread ticker snapshots it and
/// retries if the producer wraps mid-copy.
final class TapRing: @unchecked Sendable {
  private static let snapshotAttempts = 8
  private static let scratchCapacity = 4_096
  private let storage: OpaquePointer
  private let scratch: UnsafeMutablePointer<Float>

  init() {
    guard let storage = CWAudioTapRingCreate(SpectrumAnalyzer.size) else {
      preconditionFailure("Could not allocate audio analysis ring")
    }
    self.storage = storage
    self.scratch = .allocate(capacity: Self.scratchCapacity)
  }

  deinit {
    CWAudioTapRingDestroy(storage)
    scratch.deallocate()
  }

  func push(_ buffer: AVAudioPCMBuffer) {
    guard buffer.format.commonFormat == .pcmFormatFloat32,
      let channelData = buffer.floatChannelData
    else { return }
    let count = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard count > 0, channelCount > 0 else { return }
    if channelCount == 1 {
      CWAudioTapRingPush(storage, channelData[0], count)
      return
    }

    let downmixScale = 1 / Float(channelCount)
    var frame = 0
    while frame < count {
      let chunk = min(Self.scratchCapacity, count - frame)
      if buffer.format.isInterleaved {
        let samples = channelData[0]
        for offset in 0..<chunk {
          var mono: Float = 0
          let firstSample = (frame + offset) * channelCount
          for channel in 0..<channelCount {
            mono += samples[firstSample + channel]
          }
          scratch[offset] = mono * downmixScale
        }
      } else {
        for offset in 0..<chunk {
          var mono: Float = 0
          for channel in 0..<channelCount {
            mono += channelData[channel][frame + offset]
          }
          scratch[offset] = mono * downmixScale
        }
      }
      CWAudioTapRingPush(storage, scratch, chunk)
      frame += chunk
    }
  }

  func snapshot() -> [Float] {
    var samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    snapshot(into: &samples)
    return samples
  }

  func snapshot(into samples: inout [Float]) {
    if samples.count != SpectrumAnalyzer.size {
      samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
    }
    for _ in 0..<Self.snapshotAttempts {
      let copied = samples.withUnsafeMutableBufferPointer { buffer in
        CWAudioTapRingSnapshot(storage, buffer.baseAddress, buffer.count)
      }
      if copied { return }
    }
    samples.withUnsafeMutableBufferPointer { buffer in
      buffer.initialize(repeating: 0)
    }
  }

  func reset() {
    CWAudioTapRingReset(storage)
  }
}
