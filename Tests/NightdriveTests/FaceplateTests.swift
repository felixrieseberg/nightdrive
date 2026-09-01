import AppKit
import Testing

@testable import Nightdrive

struct FaceplateTests {
  @MainActor
  @Test
  func testSnapshotFaceplateStaysWithBackgroundWindows() {
    let main = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless], backing: .buffered, defer: false)
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    defer {
      main.removeChildWindow(panel)
      panel.orderOut(nil)
      main.orderOut(nil)
    }

    let presentation = FaceplatePanelController.presentation(
      environment: ["NIGHTDRIVE_SNAPSHOT_DIR": "/tmp/nightdrive-snapshots"])
    FaceplatePanelController.configure(panel, for: presentation)
    FaceplatePanelController.order(panel, for: presentation, relativeTo: main)

    #expect(presentation == .backgroundSnapshot)
    #expect(!(panel.isFloatingPanel))
    #expect(panel.level == .normal)
    #expect(!(panel.collectionBehavior.contains(.canJoinAllSpaces)))
    #expect(!(panel.collectionBehavior.contains(.fullScreenAuxiliary)))
    #expect(panel.parent === main)
  }

  @MainActor
  @Test
  func testOrdinaryFaceplateKeepsFloatingPresentation() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    #expect(FaceplatePanelController.presentation(environment: [:]) == .foreground)
    FaceplatePanelController.configure(panel, for: .foreground)

    #expect(panel.isFloatingPanel)
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
  }

  @Test
  func testFlashHoldsFullBrightness() {
    #expect(SecurityLED.intensity(at: 0) == 1)
    #expect(SecurityLED.intensity(at: SecurityLED.flash / 2) == 1)
    #expect(SecurityLED.intensity(at: SecurityLED.flash - 0.001) == 1)
  }

  @Test
  func testDecayFadesLinearlyToDark() {
    let midDecay = SecurityLED.flash + SecurityLED.decay / 2
    #expect(abs((SecurityLED.intensity(at: midDecay)) - (0.5)) <= 0.01)
    #expect(SecurityLED.intensity(at: SecurityLED.flash + SecurityLED.decay) == 0)
  }

  @Test
  func testDarkForRestOfCycle() {
    let dark = SecurityLED.flash + SecurityLED.decay + 0.01
    #expect(SecurityLED.intensity(at: dark) == 0)
    #expect(SecurityLED.intensity(at: SecurityLED.period - 0.001) == 0)
  }

  @Test
  func testCycleRepeats() {
    for cycles in 1...3 {
      let offset = Double(cycles) * SecurityLED.period
      #expect(SecurityLED.intensity(at: offset + 0.1) == SecurityLED.intensity(at: 0.1))
      let midDecay = offset + SecurityLED.flash + SecurityLED.decay / 2
      #expect(abs((SecurityLED.intensity(at: midDecay)) - (0.5)) <= 0.01)
    }
  }

  @Test
  func testNegativeElapsedStaysDark() {
    #expect(SecurityLED.intensity(at: -0.5) == 0)
  }

}
