import AppKit
import SwiftUI
import Testing

@testable import Nightdrive

struct BodyworkTests {
  private func channels(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let srgb = color.usingColorSpace(.sRGB)!
    return (srgb.redComponent, srgb.greenComponent, srgb.blueComponent)
  }

  @Test
  func testEverySurfaceIsCool() {
    for value in stride(from: 0.02, through: 0.5, by: 0.02) {
      let (r, g, b) = channels(Bodywork.nsGrey(value))
      #expect(g > r, "green should sit above red at \(value)")
      #expect(b > g, "blue should sit above green at \(value)")
      #expect(abs((b / r) - (1.217)) <= 0.001, "the ratio should not drift with value")
    }
  }

  @Test
  func testBodyMeetsTheFaceplateWithoutAStep() {
    #expect(Bodywork.panel == Bodywork.faceplateBottom)
  }

  @Test
  func testLevelsAndTheColoursCutFromThemAgree() {
    let pairs: [(CGFloat, Color)] = [
      (Bodywork.Level.cavity, Bodywork.cavity),
      (Bodywork.Level.hairline, Bodywork.hairline),
      (Bodywork.Level.well, Bodywork.well),
      (Bodywork.Level.panel, Bodywork.panel),
      (Bodywork.Level.raised, Bodywork.raised),
      (Bodywork.Level.faceplate, Bodywork.faceplateTop),
    ]
    for (value, color) in pairs {
      #expect(abs((channels(NSColor(color)).r) - (channels(Bodywork.nsGrey(value)).r)) <= 0.001)
    }
    let levels = [
      Bodywork.Level.cavity, Bodywork.Level.hairline, Bodywork.Level.well, Bodywork.Level.panel,
      Bodywork.Level.raised, Bodywork.Level.faceplate,
    ]
    #expect(levels == levels.sorted())
  }

  @Test
  func testMixHasHeadroomForEverySurfaceItIsAskedFor() {
    let deepest: CGFloat = 0.520
    let (_, _, b) = channels(Bodywork.nsGrey(deepest))
    #expect(b < 1, "the chassis mix clips above this value")
  }
}
