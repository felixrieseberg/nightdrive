import CoreGraphics
import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct VisualizerMathTests {

  @Test
  func testSineTableMatchesFoundationInTurns() {
    for step in 0...200 {
      let turns = Double(step) / 200 * 3 - 1.5
      #expect(abs((VFDTrig.sin(turns)) - (sin(turns * 2 * .pi))) <= 0.002)
      #expect(abs((VFDTrig.cos(turns)) - (cos(turns * 2 * .pi))) <= 0.002)
    }
  }

  @Test
  func testWaveIsTheUnitIntervalVersionOfSine() {
    for step in 0...100 {
      let turns = Double(step) / 100 * 2
      #expect(abs((VFDTrig.wave(turns)) - ((VFDTrig.sin(turns) + 1) / 2)) <= 0.002)
    }
    #expect(VFDTrig.wave(0.25) >= 0.99)
    #expect(VFDTrig.wave(0.75) <= 0.01)
  }

  @Test
  func testTrigSurvivesRidiculousAngles() {
    for turns in [1e6, -1e6, 12_345.678, -0.0] {
      #expect(VFDTrig.sin(turns).isFinite)
      #expect(abs(VFDTrig.sin(turns)) <= 1)
      #expect(abs(VFDTrig.cos(turns)) <= 1)
    }
  }

  @Test
  func testRotationPreservesLength() {
    let matrix = Mat3.rotation(x: 0.12, y: -0.31, z: 0.44)
    for point in [Vec3(x: 1, y: 0, z: 0), Vec3(x: 0.3, y: -0.7, z: 0.5)] {
      let turned = matrix(point)
      #expect(abs((turned.length) - (point.length)) <= 0.005)
    }
  }

  @Test
  func testQuarterTurnAboutZSendsXToY() {
    let turned = Mat3.rotation(x: 0, y: 0, z: 0.25)(Vec3(x: 1, y: 0, z: 0))
    #expect(abs((turned.x) - (0)) <= 0.005)
    #expect(abs((abs(turned.y)) - (1)) <= 0.005)
    #expect(abs((turned.z) - (0)) <= 0.005)
  }

  @Test
  func testProjectionShrinksWithDistanceAndFitsALetterbox() {
    var camera = VFDCamera(size: CGSize(width: 880, height: 52))
    camera.distance = 3

    let near = camera.project(Vec3(x: 0.5, y: 0, z: -0.5))
    let far = camera.project(Vec3(x: 0.5, y: 0, z: 0.5))
    #expect(near != nil)
    #expect(far != nil)
    #expect(abs(near!.point.x - 440) > abs(far!.point.x - 440))
    #expect(near!.scale > far!.scale)

    let corner = camera.project(Vec3(x: 1, y: 1, z: 0))
    #expect(corner != nil)
    #expect(abs(corner!.point.y - 26) < 52)
  }

  @Test
  func testPointsBehindTheCameraAreDropped() {
    var camera = VFDCamera(size: CGSize(width: 400, height: 40))
    camera.distance = 1
    #expect(camera.project(Vec3(x: 0, y: 0, z: -1.5)) == nil)
  }

  private func frame(_ time: Double, bass: Float, treble: Float = 0.1, level: Double = 0.5)
    -> VisualizerFrame
  {
    let bands = SpectrumAnalyzer.bandCount
    let spectrum = (0..<bands).map { index -> Float in
      Double(index) / Double(bands - 1) < 0.25 ? bass : treble
    }
    return VisualizerFrame(
      size: CGSize(width: 880, height: 52),
      time: time,
      spectrum: spectrum,
      peaks: spectrum,
      waveform: [Float](repeating: 0, count: 96),
      level: level,
      elapsed: time,
      duration: 200,
      isPlaying: true,
      title: "", artist: "", album: "",
      boot: nil)
  }

  @Test
  func testEnvelopesRiseFastAndFallSlowly() {
    let energy = AudioEnergy()
    var time = 0.0
    for _ in 0..<12 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 0.9))
    }
    let peak = energy.bass
    #expect(peak > 0.6, Comment(rawValue: "attack must reach the signal within half a second"))

    time += 1 / 24.0
    energy.update(frame(time, bass: 0.0, treble: 0.0, level: 0))
    #expect(energy.bass < peak)
    #expect(energy.bass > peak * 0.5)
  }

  @Test
  func testUpdateIgnoresRepeatedFramesAtTheSameTime() {
    let energy = AudioEnergy()
    #expect(energy.update(frame(1 / 24.0, bass: 0.5)) > 0)
    #expect(energy.update(frame(1 / 24.0, bass: 0.5)) == 0)
  }

  @Test
  func testAStepChangeInBassCountsAsABeatAndASteadyToneDoesNot() {
    let energy = AudioEnergy()
    var time = 0.0
    for _ in 0..<48 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 0.2, level: 0.2))
    }
    let quiet = energy.beatCount
    var detected = false

    for _ in 0..<3 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 1.0, level: 0.9))
      detected = detected || energy.didBeat
    }
    #expect(detected)
    #expect(energy.beatCount > quiet, Comment(rawValue: "a step in low-band energy is an onset"))
    #expect(energy.beat > 0.5, Comment(rawValue: "and it must be hot right after it fires"))

    for _ in 0..<12 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 1.0, level: 0.9))
    }
    #expect(energy.beat < 0.35)
  }

  @Test
  func testResetClearsEverything() {
    let energy = AudioEnergy()
    var time = 0.0
    for _ in 0..<24 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 0.9, treble: 0.9, level: 0.9))
    }
    #expect(energy.level > 0)
    energy.reset()
    #expect(energy.bass == 0)
    #expect(energy.mid == 0)
    #expect(energy.treble == 0)
    #expect(energy.level == 0)
    #expect(energy.beat == 0)
    #expect(energy.beatCount == 0)
    #expect(!(energy.didBeat))
    #expect(energy.update(frame(500, bass: 0.5)) <= 0.2)
  }

  @Test
  func testEnvelopesStayInRangeForAbsurdInput() {
    let energy = AudioEnergy()
    var time = 0.0
    for _ in 0..<40 {
      time += 1 / 24.0
      energy.update(frame(time, bass: 12, treble: -4, level: 9))
    }
    for value in [energy.bass, energy.mid, energy.treble, energy.level, energy.beat] {
      #expect(value.isFinite)
      #expect(value >= 0)
      #expect(value <= 1.001)
    }
  }

  @Test
  func testDotFontMeasuresAndLightsGlyphs() {
    #expect(VFDDotFont.width(of: "") == 0)
    #expect(VFDDotFont.width(of: "A") == 5)
    #expect(VFDDotFont.width(of: "AB") == 11)
    #expect(VFDDotFont.width(of: "ab") == VFDDotFont.width(of: "AB"))

    let litInA = (0..<VFDDotFont.width(of: "A")).reduce(0) { total, x in
      total + (0..<VFDDotFont.glyphHeight).filter { VFDDotFont.isLit("A", x: x, y: $0) }.count
    }
    #expect(litInA > 8, Comment(rawValue: "a letter must actually have dots in it"))
    #expect(!(VFDDotFont.isLit(" ", x: 0, y: 0)))
    #expect(!(VFDDotFont.isLit("A", x: -1, y: 0)))
    #expect(!(VFDDotFont.isLit("A", x: 0, y: 99)))
    #expect(!(VFDDotFont.isLit("\u{1F600}", x: 1, y: 3)))
  }
}
