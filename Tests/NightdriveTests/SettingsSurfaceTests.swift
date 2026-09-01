import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Nightdrive

struct SettingsSurfaceTests {
  private func dark(_ color: Color) -> NSColor {
    let appearance = NSAppearance(named: .darkAqua)!
    var resolved = NSColor.black
    appearance.performAsCurrentDrawingAppearance {
      resolved = NSColor(color).usingColorSpace(.sRGB)!
    }
    return resolved
  }

  private func level(_ value: CGFloat) -> NSColor {
    Bodywork.nsGrey(value).usingColorSpace(.sRGB)!
  }

  private func assertSame(_ color: Color, _ value: CGFloat, _ label: String) {
    let got = dark(color)
    let want = level(value)
    #expect(abs((got.redComponent) - (want.redComponent)) <= 0.001, Comment(rawValue: label))
    #expect(abs((got.greenComponent) - (want.greenComponent)) <= 0.001, Comment(rawValue: label))
    #expect(abs((got.blueComponent) - (want.blueComponent)) <= 0.001, Comment(rawValue: label))
  }

  @Test
  func testEverySettingsSurfaceIsCutFromTheChassis() {
    assertSame(SettingsSurface.rail, Bodywork.Level.panel, "rail")
    assertSame(SettingsSurface.list, Bodywork.Level.panel, "list")
    assertSame(SettingsSurface.pane, Bodywork.Level.panel, "pane")
    assertSame(SettingsSurface.bar, Bodywork.Level.raised, "bar")
    assertSame(SettingsSurface.card, Bodywork.Level.raised, "card")
    assertSame(SettingsSurface.hairline, Bodywork.Level.hairline, "hairline")
  }

}
