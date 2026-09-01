import AppKit
import Foundation
import Testing

@testable import Nightdrive

struct NightdriveLaunchModeTests {
  @Test
  func testSnapshotTourUsesAccessoryActivationPolicy() {
    #expect(
      NightdriveLaunchMode.activationPolicy(
        environment: ["NIGHTDRIVE_SNAPSHOT_DIR": "/tmp/nightdrive-snapshots"]) == .accessory)
  }

  @Test
  func testOrdinaryLaunchKeepsDefaultActivationPolicy() {
    #expect(NightdriveLaunchMode.activationPolicy(environment: [:]) == nil)
  }

  @Test
  func testSingleSnapshotDoesNotChangeNormalLaunchMode() {
    #expect(
      NightdriveLaunchMode.activationPolicy(
        environment: ["NIGHTDRIVE_SNAPSHOT": "/tmp/nightdrive.png"]) == nil)
  }
}
