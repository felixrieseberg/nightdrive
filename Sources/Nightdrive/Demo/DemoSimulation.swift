import CoreGraphics
import Foundation

@MainActor
enum DemoSimulation {
  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    private(set) static var isActive = false
    private static let epoch = Date()

    static func begin() { isActive = true }
    static func end() { isActive = false }

    static func excite(_ frame: inout VisualizerFrame) {
      guard isActive, frame.isPlaying else { return }
      let sample = VisualizerSample.frame(
        size: VisualizerSample.defaultPreviewSize, at: frame.time, palette: frame.palette)
      frame.spectrum = sample.spectrum
      frame.peaks = sample.peaks
      frame.waveform = sample.waveform
      frame.level = sample.level
    }

    static func spectrum(_ real: [Float], active: Bool) -> [Float] {
      guard isActive, active else { return real }
      return sample.spectrum
    }

    static func peaks(_ real: [Float], active: Bool) -> [Float] {
      guard isActive, active else { return real }
      return sample.peaks
    }

    private static var sample: VisualizerFrame {
      VisualizerSample.frame(
        size: VisualizerSample.defaultPreviewSize, at: Date().timeIntervalSince(epoch))
    }
  #else
    static let isActive = false
    static func excite(_ frame: inout VisualizerFrame) {}
    static func spectrum(_ real: [Float], active: Bool) -> [Float] { real }
    static func peaks(_ real: [Float], active: Bool) -> [Float] { real }
  #endif
}
