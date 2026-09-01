import CoreGraphics
import Foundation

enum VisualizerSample {
  static let defaultPreviewSize = CGSize(width: 900, height: 64)

  static func frame(
    size: CGSize, at time: TimeInterval = 0, palette: VisualizerPalette = .vfd,
    boot: Double? = nil
  ) -> VisualizerFrame {
    var frame = base(size: size)
    frame.time = time
    frame.palette = palette
    frame.boot = boot

    let beat = pow(max(0, sin(time * .pi * 2)), 6)
    frame.spectrum = frame.spectrum.enumerated().map { index, value in
      let phase = time * 2.2 + Double(index) * 0.22
      let kick = index < 6 ? beat * 0.5 : 0
      return Float(min(1, max(0, Double(value) * (0.55 + 0.45 * sin(phase)) + kick)))
    }
    frame.peaks = frame.spectrum.map { min(1, $0 + 0.08) }
    frame.level = min(1, frame.level * (0.7 + 0.3 * sin(time * 1.7)) + beat * 0.3)
    frame.waveform = frame.waveform.enumerated().map { index, value in
      value * Float(cos(time * 3 + Double(index) * 0.05))
    }
    let sinceBeat = time.truncatingRemainder(dividingBy: 0.5)
    if sinceBeat < 1.0 / 24.0 {
      frame.spectrum = frame.spectrum.enumerated().map { index, value in
        index < 6 ? min(1, value + 0.55) : value
      }
    }
    return frame
  }

  static func base(size: CGSize) -> VisualizerFrame {
    let bands = SpectrumAnalyzer.bandCount
    let spectrum = (0..<bands).map { band -> Float in
      let position = Double(band) / Double(bands - 1)
      let tilt = pow(1 - position, 1.4)
      let peaks =
        0.35 * exp(-pow((position - 0.35) * 9, 2))
        + 0.25 * exp(-pow((position - 0.68) * 12, 2))
      return Float(min(1, max(0.02, tilt * 0.85 + peaks)))
    }
    return VisualizerFrame(
      size: size,
      time: 3.5,
      spectrum: spectrum,
      peaks: spectrum.map { min(1, $0 + 0.08) },
      waveform: (0..<96).map { index in
        let t = Double(index) / 96
        return Float(
          (sin(t * .pi * 8) * 0.55 + sin(t * .pi * 23) * 0.2) * (0.6 + 0.4 * sin(t * .pi * 2)))
      },
      level: 0.62,
      elapsed: 42,
      duration: 210,
      isPlaying: true,
      title: "Sample Track",
      artist: "Sample Artist",
      album: "Sample Album",
      boot: nil)
  }
}
