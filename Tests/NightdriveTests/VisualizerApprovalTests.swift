import Foundation
import Testing

@testable import Nightdrive

struct VisualizerApprovalTests: PluginFolderFixtureProviding {
  let pluginFixture: PluginFolderFixture
  private let store: VisualizerApprovalStore

  init() throws {
    let fixture = PluginFolderFixture()
    pluginFixture = fixture
    try FileManager.default.createDirectory(
      at: fixture.folder, withIntermediateDirectories: true)
    store = VisualizerApprovalStore(
      defaults: try #require(UserDefaults(suiteName: fixture.approvalSuite)))
  }

  private var gated: VisualizerPluginFolder {
    VisualizerPluginFolder(url: folder, approvalStore: store, examples: [])
  }

  @Test
  func testAnUnapprovedPluginDoesNotLoadAndIsReportedAsPending() throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")

    let discovery = gated.discoverScripts()
    #expect(discovery.scripts.isEmpty, Comment(rawValue: "an unapproved plugin must never load"))
    #expect(discovery.issues.isEmpty, Comment(rawValue: "waiting for approval is not an error"))
    #expect((discovery.pending.map(\.name)) == (["dropin.js"]))
  }

  @Test
  func testApprovingAPendingPluginLoadsItOnTheNextDiscovery() throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")

    let pending = try #require(gated.discoverScripts().pending.first)
    #expect(gated.approve(pending))

    let after = gated.discoverScripts()
    #expect((after.scripts.map(\.name)) == (["dropin.js"]))
    #expect(after.pending.isEmpty)
  }

  @Test
  func testEditingAnApprovedPluginSendsItBackToPending() throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")
    let pending = try #require(gated.discoverScripts().pending.first)
    #expect(gated.approve(pending))

    try write("dropin.js", "registerVisualizer({ id: 'evil', name: 'E', draw() {} });\n")
    let after = gated.discoverScripts()
    #expect(after.scripts.isEmpty, Comment(rawValue: "approval covers the reviewed bytes, not the file name"))
    #expect((after.pending.map(\.name)) == (["dropin.js"]))
    #expect((after.pending.first?.hash) != (pending.hash))
  }

  @Test
  func testShippedExampleContentIsAutoApproved() throws {
    let example = try #require(VisualizerExamples.all.first { $0.name.hasSuffix(".js") })
    try write(example.name, example.contents)

    let discovery = VisualizerPluginFolder(
      url: folder, approvalStore: store, examples: [example]
    ).discoverScripts()
    #expect((discovery.scripts.map(\.name)) == ([example.name]))
    #expect(discovery.pending.isEmpty)
    #expect(
      store.load().approves(
        name: example.name, hash: VisualizerApprovals.hash(of: example.contents)))
  }

  @Test
  func testShippedContentUnderAnotherNameStillRequiresApproval() throws {
    let example = try #require(VisualizerExamples.all.first { $0.name.hasSuffix(".js") })
    try write("renamed.js", example.contents)

    let discovery = VisualizerPluginFolder(
      url: folder, approvalStore: store, examples: [example]
    ).discoverScripts()

    #expect(discovery.scripts.isEmpty)
    #expect((discovery.pending.map(\.name)) == (["renamed.js"]))
  }

  @Test
  func testAFreshlySeededFolderLoadsEverythingWithoutApprovals() {
    let plugins = VisualizerPluginFolder(url: folder, approvalStore: store)
    try! FileManager.default.removeItem(at: folder)
    plugins.createIfNeeded()

    let discovery = plugins.discoverScripts()
    #expect((discovery.scripts.count) == (VisualizerExamples.all.filter { $0.name.hasSuffix(".js") }.count))
    #expect(discovery.pending.isEmpty)
  }

  @Test
  func testACorruptApprovalRecordFailsClosed() throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")
    store.defaults.set(Data("{ not json".utf8), forKey: VisualizerApprovalStore.defaultsKey)

    let discovery = gated.discoverScripts()
    #expect(discovery.scripts.isEmpty)
    #expect((discovery.pending.map(\.name)) == (["dropin.js"]))
  }

  @Test
  func testForgedApprovalRecordInsideTheFolderGrantsNothing() throws {
    let source = "registerVisualizer({ id: 'evil', name: 'E', draw() {} });\n"
    try write("evil.js", source)
    let hash = VisualizerApprovals.hash(of: source)
    try write(
      ".nightdrive-approved.json",
      #"{"evil.js":"\#(hash)"}"#)

    let discovery = gated.discoverScripts()
    #expect(discovery.scripts.isEmpty, Comment(rawValue: "a forged in-folder record must not run code"))
    #expect((discovery.pending.map(\.name)) == (["evil.js"]))
  }

  @Test
  func testApprovalsPersistInPreferencesNotInTheGuardedFolder() throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")
    let pending = try #require(gated.discoverScripts().pending.first)
    #expect(gated.approve(pending))

    #expect(store.defaults.data(forKey: VisualizerApprovalStore.defaultsKey) != nil)
    let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect((contents.sorted()) == (["dropin.js"]), Comment(rawValue: "approving must not write into the folder"))
  }

  @MainActor
  @Test
  func testTheRegistrySurfacesPendingPluginsAndApprovesThem() async throws {
    try write("dropin.js", "registerVisualizer({ id: 'dropin', name: 'D', draw() {} });\n")

    let registry = VisualizerRegistry(folder: gated)
    await registry.waitUntilReady()
    #expect(registry.visualizer(id: "dropin") == nil)
    let pending = try #require(registry.pendingApproval.first)

    registry.approve(pending)
    await registry.waitUntilReady()
    #expect(registry.visualizer(id: "dropin") != nil)
    #expect(registry.pendingApproval.isEmpty)
  }

  @Test
  func testShippedExamplesLoadFromResources() {
    #expect(
      (VisualizerExamples.all.map(\.name)) == (VisualizerExamples.shippedNames),
      Comment(rawValue: "every shipped example file must load from the resource bundle"))
    for example in VisualizerExamples.all {
      #expect(!(example.source.isEmpty), Comment(rawValue: "\(example.name) read back empty"))
      #expect(
        example.source.hasSuffix("\n"),
        Comment(rawValue: "\(example.name) must end in a newline so installed bytes equal file bytes"))
    }
  }
}
