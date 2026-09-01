import Foundation
import Testing

@testable import Nightdrive

/// The snapshot tour is split across processes now, so which part a launch
/// shoots is parsed from the environment rather than implied. A mistake here
/// silently drops images, which the script would report as a missing file.
struct DebugSnapshotScopeTests {
  @Test
  func testUnsetOrEmptyScopeShootsTheWholeTour() {
    #expect(DebugSnapshot.requestedScopes(nil) == DebugSnapshot.Scope.allCases)
    #expect(DebugSnapshot.requestedScopes("") == DebugSnapshot.Scope.allCases)
    #expect(DebugSnapshot.requestedScopes("full") == DebugSnapshot.Scope.allCases)
  }

  @Test
  func testNamedScopesAreShotInTourOrder() {
    #expect(DebugSnapshot.requestedScopes("settings") == [.settings])
    #expect(DebugSnapshot.requestedScopes("settings,library") == [.library, .settings])
    #expect(DebugSnapshot.requestedScopes(" Deck , VISUALIZERS ") == [.deck, .visualizers])
  }

  @Test
  func testAnUnrecognisedScopeFallsBackToTheWholeTour() {
    #expect(DebugSnapshot.requestedScopes("nonsense") == DebugSnapshot.Scope.allCases)
  }

  @Test
  func testShardsCoverEveryItemExactlyOnce() {
    let items = Array(0..<26)
    for count in 1...5 {
      let slices = (1...count).map { DebugSnapshot.shard(items, "\($0)/\(count)") }
      #expect(slices.flatMap { $0 }.sorted() == items)
      // Round-robin dealing keeps the slices within one item of each other.
      let sizes = slices.map(\.count)
      #expect(sizes.max()! - sizes.min()! <= 1)
    }
  }

  @Test
  func testAnUnusableShardTakesEverything() {
    let items = Array(0..<5)
    for value in [nil, "", "0/3", "4/3", "1/0", "1", "a/b", "1/2/3"] {
      #expect(
        DebugSnapshot.shard(items, value) == items, Comment(rawValue: "shard(\(value ?? "nil")) should not drop items"))
    }
  }

  @Test
  func testSnapshotDeviceWithoutExtraVolumesSkipsRealVolumes() throws {
    let fakeVolume = TestScratch.directory()
    try FileManager.default.createDirectory(at: fakeVolume, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fakeVolume) }

    let selected = DebugSnapshot.snapshotDevice(
      from: [device(at: URL(fileURLWithPath: "/")), device(at: fakeVolume)],
      extraVolumes: nil)

    #expect(selected?.volumeURL == fakeVolume)
  }

  @Test
  func testSnapshotDeviceRejectsNamedRealVolumes() throws {
    let fakeVolume = TestScratch.directory()
    try FileManager.default.createDirectory(at: fakeVolume, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fakeVolume) }

    let realVolume = URL(fileURLWithPath: "/")
    #expect(
      DebugSnapshot.snapshotDevice(
        from: [device(at: realVolume)], extraVolumes: realVolume.path) == nil)
    #expect(
      DebugSnapshot.snapshotDevice(
        from: [device(at: realVolume), device(at: fakeVolume)],
        extraVolumes: "\(realVolume.path):\(fakeVolume.path)")?.volumeURL == fakeVolume)
  }

  private func device(at volumeURL: URL) -> IpodDevice {
    IpodDevice(
      volumeURL: volumeURL,
      name: volumeURL.lastPathComponent,
      modelDescription: "Test iPod",
      totalCapacity: 1,
      availableCapacity: 1)
  }
}
