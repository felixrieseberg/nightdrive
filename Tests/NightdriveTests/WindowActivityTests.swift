import AppKit
import Foundation
import Testing

@testable import Nightdrive

struct WindowActivityTests {
  @Test
  func testOnlyOrderedUnminimizedUnoccludedWindowIsVisible() {
    #expect(
      WindowVisibility.isVisible(
        isOrderedVisible: true, isMiniaturized: false, occlusionState: .visible))
    #expect(
      !(WindowVisibility.isVisible(
        isOrderedVisible: false, isMiniaturized: false, occlusionState: .visible)))
    #expect(
      !(WindowVisibility.isVisible(
        isOrderedVisible: true, isMiniaturized: true, occlusionState: .visible)))
    #expect(
      !(WindowVisibility.isVisible(
        isOrderedVisible: true, isMiniaturized: false, occlusionState: [])))
  }

  @Test
  func testIdleDeckKeepsASlowerHeartbeat() {
    #expect(VisualizerHeartbeat.interval(isPlaying: true, booting: false) == VisualizerHeartbeat.playing)
    #expect(VisualizerHeartbeat.interval(isPlaying: false, booting: true) == VisualizerHeartbeat.playing)
    #expect(VisualizerHeartbeat.interval(isPlaying: false, booting: false) == VisualizerHeartbeat.idle)
    #expect(VisualizerHeartbeat.idle > VisualizerHeartbeat.playing)
  }

  @Test
  func testIdleTimeScaleMatchesTheSlowerHeartbeat() {
    #expect(VisualizerHeartbeat.timeScale(isPlaying: true, booting: false) == 1)
    #expect(VisualizerHeartbeat.timeScale(isPlaying: false, booting: true) == 1)
    // At rest the virtual clock slows by exactly the heartbeat ratio, so each
    // rendered frame advances one simulation step instead of skipping several.
    #expect(
      abs(
        (VisualizerHeartbeat.timeScale(isPlaying: false, booting: false))
          - (VisualizerHeartbeat.playing / VisualizerHeartbeat.idle)) <= 1e-12)
  }

  @Test
  func testVisualizerClockAccumulatesScaledTime() {
    let clock = VisualizerClock()
    let start = Date(timeIntervalSinceReferenceDate: 100)
    #expect(clock.advance(to: start, scale: 1) == 0)
    #expect(abs((clock.advance(to: start.addingTimeInterval(1), scale: 1)) - (1)) <= 1e-12)
    #expect(abs((clock.advance(to: start.addingTimeInterval(2), scale: 0.5)) - (1.5)) <= 1e-12)
    // Wall clock moving backward must never rewind the virtual timeline.
    #expect(abs((clock.advance(to: start.addingTimeInterval(1), scale: 1)) - (1.5)) <= 1e-12)
    clock.reset()
    #expect(clock.advance(to: start, scale: 1) == 0)
  }
}
