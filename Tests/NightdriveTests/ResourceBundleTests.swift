import Foundation
import Testing

@testable import Nightdrive

struct ResourceBundleTests {
  @Test
  func testShippedResourcesResolveWithoutTrapping() throws {
    let bundle = try #require(Bundle.nightdriveResources)
    #expect(bundle.url(forResource: "VisualizerExamples", withExtension: nil) != nil)
    #expect(bundle.url(forResource: "ThirdPartyNotices", withExtension: nil) != nil)
    #expect(bundle.url(forResource: "DockIconFrames", withExtension: nil) != nil)
  }

  /// `Bundle.module` traps when the resource bundle is missing, which turns a
  /// half-copied app into a crash inside `AppState.init()` before any window
  /// can report it. Shipped resources go through `Bundle.nightdriveResources`,
  /// which returns nil instead.
  @Test
  func testSourcesNeverUseTheTrappingModuleAccessor() throws {
    let sources = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // NightdriveTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // package root
      .appending(path: "Sources/Nightdrive")
    let files = try #require(
      FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
    var offenders: [String] = []
    for case let url as URL in files
    where url.pathExtension == "swift" && url.lastPathComponent != "ResourceBundle.swift" {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      if text.contains("Bundle.module") { offenders.append(url.lastPathComponent) }
    }
    #expect(offenders.isEmpty)
  }
}
