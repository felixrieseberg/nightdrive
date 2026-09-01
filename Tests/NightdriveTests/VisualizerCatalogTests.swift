import Foundation
import Testing

@testable import Nightdrive

final class VisualizerCatalogTests {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var folder: URL!

  init() {
    suiteName = "nightdrive-catalog-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)
    folder = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("nightdrive-catalog-\(UUID().uuidString)", isDirectory: true)
  }

  deinit {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
    if let folder, FileManager.default.fileExists(atPath: folder.path) {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  private func modes(_ ids: String...) -> [VisualizerDescriptor] {
    ids.map { VisualizerDescriptor(id: $0, name: $0.uppercased()) }
  }

  @MainActor
  private func makeCatalog() -> VisualizerCatalog {
    VisualizerCatalog(defaults: defaults)
  }

  @MainActor
  @Test
  func testCyclingSkipsDisabledModes() {
    let all = modes("a", "b", "c", "d")
    let catalog = makeCatalog()
    catalog.setEnabled(false, for: "b", in: all)
    catalog.setEnabled(false, for: "c", in: all)

    #expect((catalog.enabled(all).map(\.id)) == (["a", "d"]))
    #expect((catalog.nextID(after: "a", in: all)) == ("d"))
    #expect((catalog.nextID(after: "d", in: all)) == ("a"))
    #expect((catalog.nextID(after: "a", by: -1, in: all)) == ("d"))
  }

  @MainActor
  @Test
  func testCyclingFromAModeThatIsNoLongerOfferedStepsFromWhereItSat() {
    let all = modes("a", "b", "c", "d")
    let catalog = makeCatalog()
    catalog.setEnabled(false, for: "b", in: all)

    #expect((catalog.nextID(after: "b", in: all)) == ("c"))
    #expect((catalog.nextID(after: "b", by: -1, in: all)) == ("a"))
    #expect((catalog.nextID(after: "gone", in: all)) == ("a"))
    #expect((catalog.nextID(after: "gone", by: -1, in: all)) == ("d"))
  }

  @MainActor
  @Test
  func testCyclingWithOneModeLeftStaysPut() {
    let all = modes("a", "b", "c")
    let catalog = makeCatalog()
    catalog.disableAll(all, keeping: "b")
    #expect((catalog.enabled(all).map(\.id)) == (["b"]))
    #expect((catalog.nextID(after: "b", in: all)) == ("b"))
    #expect((catalog.nextID(after: "a", in: all)) == ("b"))
  }

  @MainActor
  @Test
  func testTheLastEnabledModeCannotBeSwitchedOff() {
    let all = modes("a", "b")
    let catalog = makeCatalog()
    #expect(catalog.setEnabled(false, for: "a", in: all))
    #expect(!(catalog.canDisable("b", in: all)))
    #expect(!(catalog.setEnabled(false, for: "b", in: all)), Comment(rawValue: "the deck must keep a mode"))
    #expect((catalog.enabled(all).map(\.id)) == (["b"]))
  }

  @MainActor
  @Test
  func testDisableAllKeepsOneAndNeverEmptiesTheDeck() {
    let all = modes("a", "b", "c")
    let catalog = makeCatalog()
    catalog.disableAll(all, keeping: "c")
    #expect((catalog.enabled(all).map(\.id)) == (["c"]))

    let other = makeCatalog()
    other.disableAll(all, keeping: "nonexistent")
    #expect((other.enabled(all).map(\.id)) == (["a"]))
  }

  @MainActor
  @Test
  func testEverythingDisabledFallsBackToTheWholeList() {
    defaults.set(["a", "b"], forKey: VisualizerCatalog.disabledDefaultsKey)
    let all = modes("a", "b")
    #expect((makeCatalog().enabled(all).map(\.id)) == (["a", "b"]))
    #expect((makeCatalog().nextID(after: "a", in: all)) == ("b"))
  }

  @MainActor
  @Test
  func testNothingRegisteredIsNotAnError() {
    let catalog = makeCatalog()
    #expect((catalog.enabled([]).count) == (0))
    #expect((catalog.nextID(after: "a", in: [])) == ("a"))
    #expect(!(catalog.canDisable("a", in: [])))
  }

  @MainActor
  @Test
  func testDisabledModesAndOrderSurviveARelaunch() {
    let all = modes("a", "b", "c")
    let first = makeCatalog()
    first.setEnabled(false, for: "b", in: all)
    first.reorder(to: modes("c", "a", "b"))

    let second = makeCatalog()
    #expect(!(second.isEnabled("b")))
    #expect((second.arranged(all).map(\.id)) == (["c", "a", "b"]))
    #expect((second.enabled(all).map(\.id)) == (["c", "a"]))
    #expect((second.nextID(after: "c", in: all)) == ("a"))
  }

  @MainActor
  @Test
  func testNewModesArriveEnabledAndAtTheEndOfTheOrder() {
    let before = modes("a", "b")
    let catalog = makeCatalog()
    catalog.setEnabled(false, for: "a", in: before)
    catalog.reorder(to: modes("b", "a"))

    let after = modes("a", "b", "new", "newer")
    #expect(catalog.isEnabled("new"))
    #expect((catalog.arranged(after).map(\.id)) == (["b", "a", "new", "newer"]))
    #expect((catalog.enabled(after).map(\.id)) == (["b", "new", "newer"]))
  }

  @MainActor
  @Test
  func testAModeThatDisappearsAndComesBackIsStillRemembered() {
    let all = modes("a", "plugin")
    let catalog = makeCatalog()
    catalog.setEnabled(false, for: "plugin", in: all)
    catalog.reorder(to: modes("plugin", "a"))

    let without = modes("a")
    #expect((catalog.enabled(without).map(\.id)) == (["a"]))
    catalog.reorder(to: without)

    let restored = makeCatalog()
    #expect(!(restored.isEnabled("plugin")), Comment(rawValue: "the choice must outlive the file"))
    #expect(restored.order.contains("plugin"), Comment(rawValue: "and so must its place in the order"))
  }

  @MainActor
  @Test
  func testGarbageInDefaultsIsIgnoredRatherThanFatal() {
    defaults.set(["ghost", "phantom"], forKey: VisualizerCatalog.disabledDefaultsKey)
    defaults.set(["ghost", "b", "phantom"], forKey: VisualizerCatalog.orderDefaultsKey)
    let all = modes("a", "b", "c")
    let catalog = makeCatalog()

    #expect((catalog.arranged(all).map(\.id)) == (["b", "a", "c"]))
    #expect((catalog.enabled(all).map(\.id)) == (["b", "a", "c"]))
    #expect(catalog.isEnabled("a"))
  }

  @MainActor
  @Test
  func testDuplicateOrderInDefaultsIsSanitizedWithoutTrapping() {
    defaults.set(["c", "a", "c", "b", "a"], forKey: VisualizerCatalog.orderDefaultsKey)

    let catalog = makeCatalog()

    #expect((catalog.order) == (["c", "a", "b"]))
    #expect((catalog.arranged(modes("a", "b", "c")).map(\.id)) == (["c", "a", "b"]))
    #expect(
      (defaults.stringArray(forKey: VisualizerCatalog.orderDefaultsKey)) == (["c", "a", "b"]),
      Comment(rawValue: "repair the persisted value so every later launch sees the safe order"))
  }

  @MainActor
  @Test
  func testEnableAllAndResetOrderPutEverythingBack() {
    let all = modes("a", "b", "c")
    let catalog = makeCatalog()
    catalog.disableAll(all, keeping: "a")
    catalog.reorder(to: modes("c", "b", "a"))

    catalog.enableAll(all)
    catalog.resetOrder()
    #expect((catalog.enabled(all).map(\.id)) == (["a", "b", "c"]))
    #expect((makeCatalog().arranged(all).map(\.id)) == (["a", "b", "c"]))
  }

  @MainActor
  @Test
  func testTheRegistryDrivesTheCatalogWithNoIdsHardCoded() {
    let registry = VisualizerRegistry(
      folder: VisualizerPluginFolder(url: folder, requiresApproval: false, examples: []), loadPlugins: false)
    let all = registry.descriptors
    let catalog = makeCatalog()

    #expect((catalog.enabled(all).count) == (all.count), Comment(rawValue: "everything is offered by default"))
    guard let showing = all.first?.id, all.count > 1 else {
      Issue.record("expected several built-in modes")
      return
    }

    #expect(catalog.setEnabled(false, for: showing, in: all))
    let next = catalog.nextID(after: showing, in: all)
    #expect((next) != (showing))
    #expect(catalog.isEnabled(next))

    #expect(all.allSatisfy { $0.group == .builtIn })
  }

  @MainActor
  @Test
  func testAFreshInstallOffersEveryModeAndCyclesThroughAllOfThem() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "registerVisualizer({ id: 'dropped-in', name: 'Dropped In', draw() {} });"
      .write(to: folder.appendingPathComponent("p.js"), atomically: true, encoding: .utf8)
    let registry = VisualizerRegistry(
      folder: VisualizerPluginFolder(url: folder, requiresApproval: false, examples: []))
    await registry.waitUntilReady()
    let all = registry.descriptors
    #expect((all.count) > (10), Comment(rawValue: "expected the full pack of modes"))

    let catalog = makeCatalog()
    #expect((catalog.enabled(all).map(\.id)) == (all.map(\.id)))
    #expect(all.allSatisfy { catalog.isEnabled($0.id) })

    var showing = try #require(all.first?.id)
    var visited = [showing]
    for _ in 1..<all.count {
      showing = catalog.nextID(after: showing, in: all)
      visited.append(showing)
    }
    #expect((Set(visited).count) == (all.count), Comment(rawValue: "the cycle skipped or repeated a mode"))
    #expect((catalog.nextID(after: showing, in: all)) == (all.first?.id))
  }

  @MainActor
  @Test
  func testTheOnlyThingThatShortensTheCycleIsSwitchingSomethingOff() {
    let all = modes("a", "b", "c", "d", "e")
    let catalog = makeCatalog()
    #expect((catalog.enabled(all).count) == (5))

    catalog.setEnabled(false, for: "c", in: all)
    #expect((catalog.enabled(all).map(\.id)) == (["a", "b", "d", "e"]))

    catalog.setEnabled(true, for: "c", in: all)
    #expect((catalog.enabled(all).map(\.id)) == (["a", "b", "c", "d", "e"]))
  }

  @MainActor
  @Test
  func testPluginsAreGroupedAsPluginsAndCanBeSwitchedOff() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try "registerVisualizer({ id: 'only', name: 'Only', draw() {} });"
      .write(to: folder.appendingPathComponent("only.js"), atomically: true, encoding: .utf8)
    let registry = VisualizerRegistry(
      folder: VisualizerPluginFolder(url: folder, requiresApproval: false, examples: []))
    await registry.waitUntilReady()
    let all = registry.descriptors
    #expect((all.filter { $0.group == .plugin }.map(\.id)) == (["only"]))

    let catalog = makeCatalog()
    catalog.setEnabled(false, for: "only", in: all)
    #expect(!(catalog.enabled(all).contains { $0.id == "only" }))
    #expect((catalog.nextID(after: all[all.count - 2].id, in: all)) != ("only"))
  }
}
