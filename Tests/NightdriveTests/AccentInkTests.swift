import Testing

@testable import Nightdrive

struct AccentInkTests {
  private let black = VisualizerColor(red: 0, green: 0, blue: 0)
  private let white = VisualizerColor(red: 1, green: 1, blue: 1)

  @Test
  func testRelativeLuminanceMatchesWCAGEndpoints() {
    #expect(abs((black.relativeLuminance) - (0)) <= 0.0001)
    #expect(abs((white.relativeLuminance) - (1)) <= 0.0001)
    #expect(abs((VisualizerColor(red: 0.5, green: 0.5, blue: 0.5).relativeLuminance) - (0.2140)) <= 0.001)
  }

  @Test
  func testContrastRatioIsSymmetricAndPeaksAt21() {
    #expect(abs((black.contrastRatio(against: white)) - (21)) <= 0.001)
    #expect(abs((white.contrastRatio(against: black)) - (21)) <= 0.001)
    #expect(abs((white.contrastRatio(against: white)) - (1)) <= 0.001)
  }

  @Test
  func testEveryColorwayGetsALegibleLabelOnItsGlow() {
    for colorway in VisualizerColorway.all {
      let glow = colorway.palette.glow
      let ink = VFD.ink(on: glow)
      #expect(glow.contrastRatio(against: ink) >= 4.5, "\(colorway.name) label ink fails AA on its own glow")
    }
  }

  @Test
  func testLabelInkIsTheBetterOfTheTwoInks() {
    for colorway in VisualizerColorway.all {
      let glow = colorway.palette.glow
      let ink = VFD.ink(on: glow)
      let other = ink == VFD.maskInk ? white : VFD.maskInk
      #expect(
        glow.contrastRatio(against: ink) >= glow.contrastRatio(against: other),
        "\(colorway.name) picked the dimmer of the two inks")
    }
  }

  @Test
  func testAllShippingColorwaysLandOnTheMask() {
    for colorway in VisualizerColorway.all {
      #expect(
        VFD.ink(on: colorway.palette.glow) == VFD.maskInk,
        Comment(rawValue: colorway.name))
    }
  }

  @Test
  func testADarkTubeWouldGetALightLabel() {
    let midnight = VisualizerColor(red: 0.10, green: 0.16, blue: 0.42)
    #expect(VFD.ink(on: midnight) == VisualizerColor(red: 1, green: 1, blue: 1))
  }
}
