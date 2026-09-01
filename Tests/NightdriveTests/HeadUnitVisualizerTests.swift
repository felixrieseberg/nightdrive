import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Nightdrive

struct HeadUnitVisualizerTests {

  @Test
  func testCapSnapsUpImmediatelyAndHoldsBeforeFalling() {
    var caps = PeakCaps(hold: 0.5, gravity: 2)
    caps.update([0.2], at: 0)
    #expect(abs((caps.value(0)) - (0.2)) <= 1e-9)

    caps.update([0.9], at: 1.0 / 60)
    #expect(abs((caps.value(0)) - (0.9)) <= 1e-9)

    var time = 1.0 / 60
    while time < 0.5 {
      time += 1.0 / 60
      caps.update([0.0], at: time)
    }
    #expect(abs((caps.value(0)) - (0.9)) <= 1e-9, Comment(rawValue: "the cap must hang, not sag"))
  }

  @Test
  func testCapAcceleratesOnTheWayDown() {
    var caps = PeakCaps(hold: 0.2, gravity: 2)
    caps.update([0.95], at: 0)
    var time = 0.0

    func run(until end: TimeInterval) -> Double {
      let before = caps.value(0)
      while time < end {
        time += 1.0 / 60
        caps.update([0.0], at: time)
      }
      return before - caps.value(0)
    }

    _ = run(until: 0.25)
    let first = run(until: 0.45)
    let second = run(until: 0.65)
    #expect(first > 0, Comment(rawValue: "past the hold, the cap falls"))
    #expect(second > first * 1.5, Comment(rawValue: "a falling cap accelerates rather than sliding at a fixed rate"))
  }

  @Test
  func testCapNeverSinksThroughTheBarUnderIt() {
    var caps = PeakCaps(hold: 0, gravity: 40)
    caps.update([0.9], at: 0)
    var time = 0.0
    while time < 1 {
      time += 1.0 / 60
      caps.update([0.4], at: time)
    }
    #expect(caps.value(0) >= 0.4)
  }

  @Test
  func testCapSurvivesAClockThatRestarts() {
    var caps = PeakCaps(hold: 0.1, gravity: 2)
    caps.update([0.8], at: 10)
    caps.update([0.0], at: 10.2)
    caps.update([0.0], at: 0)
    #expect(caps.value(0) > 0.5)
    #expect(caps.value(0) <= 0.8)
  }

  @MainActor
  @Test
  func testTheBridgeReadsTheSameScaleTheFaceIsEngravedWith() {
    for (fraction, engraved) in [(0.0, -20.0), (0.28, -10.0), (0.47, -5.0), (0.71, 0.0)] {
      #expect(
        abs((VUVisualizer.decibels(at: fraction)) - (engraved)) <= 1e-9,
        Comment(rawValue: "the needle at \(fraction) is pointing straight at \(engraved) on the face"))
    }
    #expect(abs((VUVisualizer.decibels(at: 1)) - (3)) <= 1e-9)

    #expect(
      abs((VUVisualizer.decibels(at: 0.375)) - (-7.5)) <= 1e-9, Comment(rawValue: "halfway between -10 and -5 is -7.5"))
    var last = -Double.infinity
    for step in 0...100 {
      let reading = VUVisualizer.decibels(at: Double(step) / 100)
      #expect(reading >= last)
      last = reading
    }
  }

  @MainActor
  @Test
  func testTheBridgeReadingIsPrintedTheWayADeckPrintedIt() {
    #expect(VUVisualizer.reading(0) == "-20")
    #expect(VUVisualizer.reading(0.71) == "0")
    #expect(VUVisualizer.reading(1) == "+3")
    #expect(VUVisualizer.reading(1.12) == "+3")
    #expect(VUVisualizer.reading(-0.06) == "-20")
    #expect(VUVisualizer.reading(0.7) == "0")
  }

  @Test
  func testNeedleOvershootsAndThenSettlesOnTheReading() {
    var needle = NeedleBallistics()
    var peak = 0.0
    var value = 0.0
    for _ in 0..<240 {
      value = needle.advance(toward: 0.6, by: 1.0 / 120)
      peak = max(peak, value)
    }
    #expect(peak > 0.63, Comment(rawValue: "an under-damped movement throws past the reading"))
    #expect(abs((value) - (0.6)) <= 0.02, Comment(rawValue: "and then settles on it"))
  }

  @Test
  func testNeedleFallsBackMoreSlowlyThanItSwingsUp() {
    var rising = NeedleBallistics()
    var riseSteps = 0
    while rising.advance(toward: 1, by: 1.0 / 120) < 0.5, riseSteps < 2000 { riseSteps += 1 }

    var falling = NeedleBallistics()
    for _ in 0..<400 { _ = falling.advance(toward: 1, by: 1.0 / 120) }
    var fallSteps = 0
    while falling.advance(toward: 0, by: 1.0 / 120) > 0.5, fallSteps < 2000 { fallSteps += 1 }

    #expect(fallSteps > riseSteps, Comment(rawValue: "the meter must sag back between beats, not snap down"))
  }

  @Test
  func testNeedleStopsAtTheEndStops() {
    var needle = NeedleBallistics()
    for _ in 0..<600 { _ = needle.advance(toward: 5, by: 1.0 / 120) }
    #expect(needle.position <= 1.12)

    for _ in 0..<600 { _ = needle.advance(toward: -5, by: 1.0 / 120) }
    #expect(needle.position >= -0.06)
  }

  @Test
  func testNeedleDoesNotExplodeOnASlowFrame() {
    var needle = NeedleBallistics()
    for _ in 0..<10 { _ = needle.advance(toward: 1, by: 2) }
    #expect(abs((needle.position) - (1)) <= 0.12)
    #expect(needle.position.isFinite)
  }

  @Test
  func testDotMatrixMetrics() {
    #expect(DotMatrix.height(dot: 2) == 14)
    #expect(DotMatrix.advance(dot: 2) == 12)
    #expect(DotMatrix.width(of: "AB", dot: 2) == 22)
    #expect(DotMatrix.width(of: "", dot: 2) == 0)
  }

  @Test
  func testDotMatrixFoldsWhatItCanAndBoxesWhatItCannot() {
    #expect(String(DotMatrix.normalized("Café")) == "CAFE")
    #expect(String(DotMatrix.normalized("a\u{2014}b")) == "A-B")
    #expect(String(DotMatrix.normalized("it\u{2019}s")) == "IT'S")
    #expect(DotMatrix.normalized("\u{6F22}") == ["\u{00A4}"], Comment(rawValue: "unknown glyphs show a box"))
  }

  @Test
  func testDotMatrixDrawsDotsAndSkipsWhatIsOffThePanel() {
    var text = Path()
    DotMatrix.draw("HI", at: .zero, dot: 2, into: &text)
    #expect(!(text.isEmpty))

    var blank = Path()
    DotMatrix.draw("   ", at: .zero, dot: 2, into: &blank)
    #expect(blank.isEmpty, Comment(rawValue: "spaces cost nothing to draw"))

    var offscreen = Path()
    DotMatrix.draw(
      "HI", at: CGPoint(x: -400, y: 0), dot: 2, into: &offscreen,
      clip: CGRect(x: 0, y: 0, width: 50, height: 20))
    #expect(offscreen.isEmpty, Comment(rawValue: "a marquee must not build dots it cannot show"))

    var grid = Path()
    DotMatrix.ghostGrid(
      in: CGRect(x: 0, y: 0, width: 20, height: 14), dot: 2, into: &grid)
    #expect(!(grid.isEmpty), Comment(rawValue: "the unlit grid is what makes the panel physical"))
  }

  @MainActor
  @Test
  func testMarqueeTextAddressesTheFixedLCDGrid() {
    let pitch: CGFloat = 3.5
    #expect(MarqueeVisualizer.scrollingGridOffset(0, pitch: pitch) == 0)
    #expect(
      MarqueeVisualizer.scrollingGridOffset(pitch - 0.01, pitch: pitch) == 0,
      Comment(rawValue: "a partial-cell scroll must not slide the glyph between LCD columns"))
    #expect(MarqueeVisualizer.scrollingGridOffset(pitch, pitch: pitch) == pitch)
    #expect(MarqueeVisualizer.scrollingGridOffset(pitch * 2.8, pitch: pitch) == pitch * 2)
  }

  @MainActor
  @Test
  func testMarqueeRepeatsShortTextAcrossThePanel() {
    let origins = MarqueeVisualizer.repeatingGridOrigins(
      panelWidth: 318, period: 70, offset: 21)

    #expect(origins == [-21, 49, 119, 189, 259])
    #expect(
      origins.last! + 70 >= 318, Comment(rawValue: "repeated copies must reach beyond the right edge of a wide panel"))
  }

  @MainActor
  @Test
  func testMarqueeScrollsEvenWhenTheEntireMessageFits() {
    let marquee = MarqueeVisualizer()
    var frame = Self.frame(size: CGSize(width: 900, height: 52))
    frame.artist = ""
    frame.title = "A"
    frame.album = ""
    frame.time = 0
    _ = Self.render(marquee, frame: frame)

    frame.time = 1.0 / 24.0
    _ = Self.render(marquee, frame: frame)

    #expect(marquee.scroll > 0, Comment(rawValue: "a short message must crawl instead of sitting still"))
  }

  @Test
  func testClockFormatsTheOnlyWayAHeadUnitEverDid() {
    #expect(VisualizerFrame.clock(0) == "0:00")
    #expect(VisualizerFrame.clock(61) == "1:01")
    #expect(VisualizerFrame.clock(3600) == "60:00")
    #expect(VisualizerFrame.clock(-5) == "0:00")
    #expect(VisualizerFrame.clock(.nan) == "0:00")
    #expect(VisualizerFrame.clock(.infinity) == "0:00")
  }

  @Test
  func testEnergyReadsTheSliceItWasAskedFor() {
    var frame = Self.frame(size: CGSize(width: 300, height: 40))
    frame.spectrum = (0..<SpectrumAnalyzer.bandCount).map { index in
      index < SpectrumAnalyzer.bandCount / 2 ? 1 : 0
    }
    #expect(frame.energy(from: 0, to: 0.3) > 0.9)
    #expect(frame.energy(from: 0.75, to: 1) < 0.1)
  }

  @Test
  func testSelfTestCrestSweepsTheWholePanel() {
    var frame = Self.frame(size: CGSize(width: 300, height: 40))
    frame.boot = nil
    #expect(frame.selfTestCrest(bar: 5, of: 24) == 0, Comment(rawValue: "no sweep once the tube has struck"))

    frame.boot = 0.15
    let start = (0..<24).map { frame.selfTestCrest(bar: $0, of: 24) }
    frame.boot = 0.85
    let end = (0..<24).map { frame.selfTestCrest(bar: $0, of: 24) }
    #expect(start[0] > end[0], Comment(rawValue: "the crest starts at the left"))
    #expect(end[23] > start[23], Comment(rawValue: "and finishes at the right"))
  }

  @Test
  func testColorwayLookupFallsBackToTheDefaultTube() {
    #expect(VisualizerColorway.colorway(id: "xplod").name == "XPLOD RED")
    #expect(VisualizerColorway.colorway(id: nil).id == VisualizerColorway.default.id)
    #expect(VisualizerColorway.colorway(id: "a-tube-from-the-future").id == VisualizerColorway.default.id)
    #expect(VisualizerColorway.palette(id: "vfd") == .vfd)
    #expect(VisualizerColorway.default.id == "vfd")
  }

  @Test
  func testEveryColorwayIsUsableAsATube() {
    let ids = VisualizerColorway.all.map(\.id)
    #expect(Set(ids).count == ids.count, Comment(rawValue: "ids are persisted, so they must be unique"))
    #expect(ids.count >= 5)

    for tube in VisualizerColorway.all {
      let palette = tube.palette
      #expect(tube.name == tube.name.uppercased(), Comment(rawValue: "\(tube.id) is shown on a VFD"))
      #expect(palette.glow != palette.amber, Comment(rawValue: "\(tube.id) needs a distinguishable overload ink"))
      #expect(abs((palette.glow.alpha) - (1)) <= 1e-9, Comment(rawValue: "\(tube.id) glow must be solid"))
      #expect(palette.ghost.alpha < palette.dim.alpha, Comment(rawValue: "\(tube.id) unlit cells must be the faintest"))
      for channel in [palette.glow.red, palette.glow.green, palette.glow.blue] {
        #expect((0...1).contains(channel), Comment(rawValue: "\(tube.id) is out of gamut"))
      }
    }
  }

  @Test
  func testColorwayChoicePersistsAndSurvivesAnUnknownID() throws {
    let suite = "nightdrive-colorway-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
      VisualizerColorway.stored(in: defaults).id == VisualizerColorway.default.id,
      Comment(rawValue: "a fresh install gets the default tube"))

    VisualizerColorway.store("ice", in: defaults)
    #expect(VisualizerColorway.stored(in: defaults).id == "ice")
    #expect(VisualizerColorway.stored(in: defaults).palette == .ice)

    defaults.set("removed-in-a-later-build", forKey: VisualizerColorway.defaultsKey)
    #expect(
      VisualizerColorway.stored(in: defaults).id == VisualizerColorway.default.id,
      Comment(rawValue: "an id that no longer exists must not leave the glass unpainted"))
  }

  @MainActor
  @Test
  func testHeadUnitPackIsRegistered() {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nightdrive-headunit-\(UUID().uuidString)", isDirectory: true)
    let registry = VisualizerRegistry(
      folder: VisualizerPluginFolder(url: folder, requiresApproval: false, examples: []), loadPlugins: false)
    let ids = Set(registry.descriptors.map(\.id))
    for id in ["vu", "eq", "ripple", "marquee", "combo"] {
      #expect(ids.contains(id), Comment(rawValue: "\(id) is missing from the registry"))
      #expect(registry.visualizer(id: id) != nil)
    }
  }

  @MainActor
  @Test
  func testEveryHeadUnitModeDrawsOnAnyGlassItIsHanded() throws {
    let sizes = [
      CGSize(width: 900, height: 52), CGSize(width: 318, height: 32),
      CGSize(width: 140, height: 20), CGSize(width: 24, height: 8),
    ]
    let states: [(boot: Double?, playing: Bool, tagged: Bool)] = [
      (0.0, true, true), (0.5, true, true), (nil, true, true),
      (nil, false, true), (nil, true, false),
    ]

    for mode in HeadUnitVisualizers.all() {
      #expect(!(mode.descriptor.id.isEmpty))
      #expect(mode.descriptor.name == mode.descriptor.name.uppercased())
      for size in sizes {
        mode.reset()
        for (index, state) in states.enumerated() {
          var frame = Self.frame(size: size)
          frame.time = Double(index) / 24
          frame.boot = state.boot
          frame.isPlaying = state.playing
          if !state.tagged {
            frame.title = ""
            frame.artist = ""
            frame.album = ""
          }
          #expect(
            Self.render(mode, frame: frame) != nil,
            Comment(rawValue: "\(mode.descriptor.id) failed at \(size) in state \(index)"))
        }
      }
    }
  }

  @MainActor
  @Test
  func testHeadUnitModesDrawInWhicheverTubeTheyAreGiven() throws {
    for tube in VisualizerColorway.all {
      for mode in HeadUnitVisualizers.all() {
        mode.reset()
        var frame = Self.frame(size: CGSize(width: 318, height: 32))
        frame.palette = tube.palette
        #expect(Self.render(mode, frame: frame) != nil, Comment(rawValue: "\(mode.descriptor.id) failed in \(tube.id)"))
      }
    }
  }

  @MainActor
  @Test
  func testHeadUnitModesSurviveANonFiniteFrame() throws {
    let poison: [Float] = (0..<SpectrumAnalyzer.bandCount).map { index in
      switch index % 3 {
      case 0: return .nan
      case 1: return .infinity
      default: return Float(index) / 28
      }
    }
    for mode in HeadUnitVisualizers.all() {
      mode.reset()
      var frame = Self.frame(size: CGSize(width: 318, height: 40))
      frame.spectrum = poison
      frame.peaks = poison
      frame.waveform = poison
      frame.level = .nan
      #expect(
        Self.render(mode, frame: frame) != nil, Comment(rawValue: "\(mode.descriptor.id) trapped on a non-finite frame")
      )
    }
  }

  private static func frame(size: CGSize) -> VisualizerFrame {
    let spectrum = (0..<SpectrumAnalyzer.bandCount).map { index -> Float in
      Float(0.9 * exp(-pow(Double(index) / 6, 2)) + 0.25)
    }
    return VisualizerFrame(
      size: size,
      time: 1.5,
      spectrum: spectrum,
      peaks: spectrum.map { min(1, $0 + 0.1) },
      waveform: (0..<96).map { Float(sin(Double($0) / 7)) },
      level: 0.55,
      elapsed: 42,
      duration: 210,
      isPlaying: true,
      title: "Sample Track",
      artist: "Sample Artist",
      album: "Sample Album",
      boot: nil)
  }

  @MainActor
  private static func render(_ mode: any Visualizer, frame: VisualizerFrame) -> CGImage? {
    let renderer = ImageRenderer(
      content: Canvas { context, size in
        var frame = frame
        frame.size = size
        mode.draw(frame, into: &context)
      }
      .frame(width: frame.width, height: frame.height))
    renderer.scale = 1
    return renderer.cgImage
  }
}
