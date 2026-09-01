import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Nightdrive

struct VisualizerTests: PluginFolderFixtureProviding {
  let pluginFixture = PluginFolderFixture()
  private var seeded: VisualizerPluginFolder {
    VisualizerPluginFolder(
      url: folder,
      approvalStore: VisualizerApprovalStore(
        defaults: UserDefaults(suiteName: approvalSuite) ?? .standard))
  }

  private var frame: VisualizerFrame {
    frame(time: 2, boot: nil, isPlaying: true, level: 0.5)
  }

  private func frame(
    time: Double, boot: Double?, isPlaying: Bool, level: Double
  ) -> VisualizerFrame {
    let spectrum = (0..<SpectrumAnalyzer.bandCount).map { Float($0) / 28 }
    return VisualizerFrame(
      size: CGSize(width: 400, height: 100),
      time: time,
      spectrum: spectrum,
      peaks: spectrum,
      waveform: (0..<96).map { Float(sin(Double($0) / 8)) },
      level: level,
      elapsed: 30,
      duration: 200,
      isPlaying: isPlaying,
      title: "Title", artist: "Artist", album: "Album",
      boot: boot)
  }

  @MainActor
  @Test
  func testBuiltInModesAreRegistered() {
    let registry = VisualizerRegistry(
      folder: unseeded, loadPlugins: false)
    let ids = registry.descriptors.map(\.id)
    #expect((Array(ids.prefix(3))) == (["spectrum", "scope", "waterfall"]))
    for id in ids {
      #expect(registry.visualizer(id: id) != nil, Comment(rawValue: "\(id) must resolve to an instance"))
    }
    #expect((Set(ids).count) == (ids.count), Comment(rawValue: "every mode needs its own id"))
    #expect(registry.descriptors.allSatisfy { !$0.isPlugin })
    #expect(registry.visualizer(id: "nonexistent") == nil)
  }

  @MainActor
  @Test
  func testNightDriveIsTheDefaultVisualizer() {
    #expect((VisualizerSelection.defaultVisualizerID) == ("nightdrive"))
    let registry = VisualizerRegistry(folder: unseeded, loadPlugins: false)
    #expect((registry.visualizer(id: VisualizerSelection.defaultVisualizerID)?.descriptor.name) == ("NIGHT DRIVE"))
  }

  @Test
  func testVisualizerReportSizeParserRejectsMalformedAndOversizedInput() {
    #expect((CLI.parseVisualizerSize("320x44")) == (CGSize(width: 320, height: 44)))
    #expect((CLI.parseVisualizerSize("320.5X44.25")) == (CGSize(width: 320.5, height: 44.25)))

    for invalid in [
      "", "320", "x44", "320x", "320xbadx44", "320x44px", "nanx44", "320xinf",
      "16x44", "320x8", "8193x32", "4096x4096",
    ] {
      #expect(CLI.parseVisualizerSize(invalid) == nil, Comment(rawValue: invalid))
    }
    #expect(
      CLI.parseVisualizerSize("2048x480") != nil, Comment(rawValue: "a large but bounded strip should remain useful"))
  }

  @MainActor
  @Test
  func testEveryBuiltInDrawsAtAnySize() {
    let registry = VisualizerRegistry(
      folder: unseeded, loadPlugins: false)
    let sizes = [
      CGSize(width: 888, height: 52), CGSize(width: 120, height: 20),
      CGSize(width: 1600, height: 40),
    ]
    for descriptor in registry.descriptors {
      let mode = try! #require(registry.visualizer(id: descriptor.id))
      for size in sizes {
        for step in 0..<3 {
          var probe = frame
          probe.size = size
          probe.time = Double(step) / 24
          probe.boot = step == 0 ? 0.4 : nil
          probe.isPlaying = step != 2
          VisualizerProbe.draw(mode, probe)
        }
      }
      mode.reset()
    }
  }

  @MainActor
  @Test
  func testDolphinsResetRestocksTheOriginalScene() {
    let dolphins = DolphinsVisualizer()

    func run() -> [UInt8] {
      for step in 0..<24 {
        var probe = frame
        probe.time = Double(step) / 24
        VisualizerProbe.draw(dolphins, probe)
      }
      return dolphins.raster.pixels
    }

    let firstRun = run()
    dolphins.reset()
    #expect((run()) == (firstRun))
  }

  @MainActor
  @Test
  func testRasterVisualizerRetainsBeatWhileRasterIsEmpty() {
    let visualizer = BeatProbeVisualizer()
    var time = 0.0

    func draw(size: CGSize, level: Float) {
      time += 1 / 24.0
      var probe = frame
      probe.size = size
      probe.time = time
      probe.spectrum = [Float](repeating: level, count: SpectrumAnalyzer.bandCount)
      probe.level = Double(level)
      VisualizerProbe.draw(visualizer, probe)
    }

    let empty = CGSize(width: 0.5, height: 0.5)
    for _ in 0..<48 { draw(size: empty, level: 0.2) }
    for _ in 0..<3 { draw(size: empty, level: 1) }
    #expect((visualizer.energy.beatCount) > (0))

    draw(size: frame.size, level: 1)
    #expect(visualizer.observedBeat)
  }

  @MainActor
  @Test
  func testRippleSurvivesNonFiniteFrameTime() {
    let registry = VisualizerRegistry(
      folder: unseeded, loadPlugins: false)
    let ripple = try! #require(registry.visualizer(id: "ripple"))
    var loud = frame
    loud.spectrum = [Float](repeating: 1, count: SpectrumAnalyzer.bandCount)
    loud.peaks = loud.spectrum
    for time in [600.0, 600.5] {
      var probe = loud
      probe.time = time
      VisualizerProbe.draw(ripple, probe)
    }
    for time in [Double.nan, .infinity, -.infinity, 601.0, .nan, 601.5] {
      var probe = frame
      probe.time = time
      VisualizerProbe.draw(ripple, probe)
    }
  }

  @MainActor
  @Test
  func testMarqueeScrollRecoversFromNonFiniteFrameTime() {
    let registry = VisualizerRegistry(
      folder: unseeded, loadPlugins: false)
    let marquee = try! #require(registry.visualizer(id: "marquee") as? MarqueeVisualizer)
    var probe = frame
    probe.title = String(repeating: "A VERY LONG TITLE ", count: 8)

    probe.time = 1.0 / 24
    VisualizerProbe.draw(marquee, probe)
    probe.time = .nan
    VisualizerProbe.draw(marquee, probe)
    probe.time = 2.0 / 24
    VisualizerProbe.draw(marquee, probe)
    #expect(marquee.scroll.isFinite, Comment(rawValue: "a NaN frame must not poison the crawl"))

    marquee.scroll = .nan
    probe.time = 3.0 / 24
    VisualizerProbe.draw(marquee, probe)
    #expect(marquee.scroll.isFinite, Comment(rawValue: "a poisoned crawl distance must restart"))
    let before = marquee.scroll
    probe.time = 4.0 / 24
    VisualizerProbe.draw(marquee, probe)
    #expect((marquee.scroll) > (before), Comment(rawValue: "the crawl must keep moving afterwards"))
  }

  @MainActor
  @Test
  func testFreshFolderIsSeededWithWorkingExamples() async {
    let registry = await loadedRegistry(folder: seeded)
    #expect(
      FileManager.default.fileExists(atPath: folder.appendingPathComponent("README.md").path),
      Comment(rawValue: "a fresh folder gets the getting-started document too"))
    #expect((registry.issues) == ([]), Comment(rawValue: "the shipped examples must load cleanly"))

    let plugins = registry.descriptors.filter(\.isPlugin).map(\.id)
    #expect((plugins.sorted()) == (VisualizerExamples.ids.sorted()))

    for id in plugins {
      switch registry.smokeTest(id: id, frame: frame) {
      case .success(let list):
        #expect(!(list.isEmpty), Comment(rawValue: "\(id) drew nothing"))
      case .failure(let issue):
        Issue.record("\(id) failed: \(issue.message)")
      }
    }
  }

  @MainActor
  @Test
  func testEveryShippedExampleDrawsAcrossAFullRun() async throws {
    let registry = await loadedRegistry(folder: seeded)
    #expect((registry.issues) == ([]))

    for id in VisualizerExamples.ids {
      let visualizer = try #require(registry.visualizer(id: id), Comment(rawValue: "\(id) is missing"))
      for stage in 0..<12 {
        let boot: Double? = stage < 3 ? Double(stage) / 3 : nil
        let playing = stage < 9
        let moment = frame(
          time: Double(stage) / 8, boot: boot, isPlaying: playing,
          level: playing ? 0.6 : 0)
        switch registry.smokeTest(id: id, frame: moment) {
        case .success(let list):
          #expect((list.ops.count) < (60_000), Comment(rawValue: "\(id) draws too much for one frame"))
          for value in list.ops {
            #expect(!(value.isNaN), Comment(rawValue: "\(id) emitted NaN into the display list"))
          }
        case .failure(let issue):
          Issue.record("\(id) failed at stage \(stage): \(issue.message)")
        }
      }
      visualizer.reset()
      guard case .success(let list) = registry.smokeTest(id: id, frame: frame) else {
        Issue.record("\(id) failed to draw after reset")
        return
      }
      #expect(!(list.isEmpty), Comment(rawValue: "\(id) drew nothing after reset"))
    }
  }

  @MainActor
  @Test
  func testReloadPicksUpAddedAndRemovedPlugins() async throws {
    try write("one.js", "registerVisualizer({ id: 'one', name: 'One', draw() {} });")
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.descriptors.filter(\.isPlugin).map(\.id)) == (["one"]))

    try write("two.js", "registerVisualizer({ id: 'two', name: 'Two', draw() {} });")
    try FileManager.default.removeItem(at: folder.appendingPathComponent("one.js"))
    await registry.reloadPluginsAndWait()
    #expect((registry.descriptors.filter(\.isPlugin).map(\.id)) == (["two"]))
  }

  @MainActor
  @Test
  func testOversizedPluginIsReportedWithoutHidingAHealthyPlugin() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(repeating: 0x20, count: VisualizerPluginFolder.maximumScriptBytes + 1)
      .write(to: folder.appendingPathComponent("oversized.js"))
    try write("working.js", "registerVisualizer({ id: 'working', draw() {} });")

    let registry = await loadedRegistry(folder: unseeded)

    #expect((registry.descriptors.filter(\.isPlugin).map(\.id)) == (["working"]))
    let issue = try #require(registry.issues.first { $0.source == "oversized.js" })
    #expect(issue.message.contains("file limit"), Comment(rawValue: issue.message))
  }

  @Test
  func testPluginDiscoveryEnforcesFileCountAndAggregateByteLimits() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let extraCount = 7
    for index in stride(
      from: VisualizerPluginFolder.maximumScriptCount + extraCount - 1, through: 0, by: -1)
    {
      try write(String(format: "%03d.js", index), "// plugin \(index)")
    }
    var discovery = unseeded.discoverScripts()
    #expect(
      (discovery.scripts.map(\.name))
        == ((0..<VisualizerPluginFolder.maximumScriptCount).map { String(format: "%03d.js", $0) }),
      Comment(rawValue: "discovery should retain the lexicographically first bounded set"))
    let countIssue = try #require(discovery.issues.first { $0.source == "plugins" })
    #expect(countIssue.message.contains("\(extraCount) exceeded"), Comment(rawValue: countIssue.message))

    for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
    let chunk = Data(repeating: 0x20, count: VisualizerPluginFolder.maximumScriptBytes)
    let fittingCount =
      VisualizerPluginFolder.maximumAggregateScriptBytes
      / VisualizerPluginFolder.maximumScriptBytes
    for index in 0...fittingCount {
      try chunk.write(to: folder.appendingPathComponent("aggregate-\(index).js"))
    }

    discovery = unseeded.discoverScripts()
    #expect((discovery.scripts.count) == (fittingCount))
    #expect(discovery.issues.contains { $0.message.contains("folder byte limit") })
  }

  @MainActor
  @Test
  func testPluginResolvesToItsSourceFileForFinderActions() async throws {
    try write("some-file.js", "registerVisualizer({ id: 'mode-id', draw() {} });")
    let registry = VisualizerRegistry(folder: unseeded)
    await registry.waitUntilReady()

    #expect((registry.pluginURL(for: "mode-id")) == (folder.appendingPathComponent("some-file.js")))
    #expect(registry.pluginURL(for: "spectrum") == nil, Comment(rawValue: "built-ins do not have plugin files"))
    #expect(registry.pluginURL(for: "missing") == nil)
  }

  @MainActor
  @Test
  func testPluginWithSyntaxErrorIsReportedAndOthersStillLoad() async throws {
    try write("bad.js", "registerVisualizer({ id: 'bad',")
    try write("good.js", "registerVisualizer({ id: 'good', name: 'Good', draw() {} });")
    let registry = await loadedRegistry(folder: unseeded)

    #expect((registry.descriptors.filter(\.isPlugin).map(\.id)) == (["good"]))
    #expect((registry.issues.count) == (1))
    #expect((registry.issues.first?.source) == ("bad.js"))
    #expect(registry.descriptors.contains { $0.id == "spectrum" })
  }

  @MainActor
  @Test
  func testNonUTF8PluginIsReportedAndDoesNotHideHealthyPlugins() async throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data([0xff, 0xfe, 0x00, 0x80]).write(to: folder.appendingPathComponent("binary.js"))
    try write("good.js", "registerVisualizer({ id: 'good', draw() {} });")

    let registry = await loadedRegistry(folder: unseeded)

    #expect((registry.descriptors.filter(\.isPlugin).map(\.id)) == (["good"]))
    let issue = try #require(registry.issues.first { $0.source == "binary.js" })
    #expect(issue.message.contains("valid UTF-8"), Comment(rawValue: issue.message))
  }

  @MainActor
  @Test
  func testPreviewWarmupsResetPluginStateForEveryColorway() async throws {
    try write(
      "bounded.js",
      """
      let frames = 0;
      registerVisualizer({
        id: 'bounded',
        reset() { frames = 0; },
        draw(frame, gfx) {
          frames += 1;
          if (frames > 57) throw new Error('preview state leaked');
          gfx.rect(0, 0, 2, 2);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    let mode = try #require(registry.visualizer(id: "bounded"))
    let previews = folder.appendingPathComponent("previews", isDirectory: true)
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)

    mode.reset()
    guard case .success = registry.smokeTest(id: "bounded", frame: frame) else {
      Issue.record("smoke test failed")
      return
    }
    for (index, colorway) in VisualizerColorway.all.prefix(2).enumerated() {
      let written = VisualizerReport.writePreview(
        visualizer: nil,
        list: { frame in
          guard case .success(let list) = registry.smokeTest(id: "bounded", frame: frame)
          else { return nil }
          return list
        },
        reset: { mode.reset() }, palette: colorway.palette,
        size: CGSize(width: 320, height: 44),
        to: previews.appendingPathComponent("\(index).png"))
      #expect(written, Comment(rawValue: "colorway \(index) inherited state from an earlier pass"))
    }
  }

  @MainActor
  @Test
  func testPluginCannotShadowABuiltInMode() async throws {
    try write("impostor.js", "registerVisualizer({ id: 'scope', name: 'Nope', draw() {} });")
    let registry = await loadedRegistry(folder: unseeded)

    #expect((registry.descriptors.filter { $0.id == "scope" }.count) == (1))
    #expect(!(registry.visualizer(id: "scope")?.descriptor.isPlugin ?? true))
    #expect((registry.issues.count) == (1))
  }

  @MainActor
  @Test
  func testThrowingPluginSurfacesTheErrorWithItsLineNumber() async throws {
    try write(
      "throws.js",
      """
      registerVisualizer({
        id: 'throws',
        name: 'Throws',
        draw() { missingGlobal.boom(); }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]), Comment(rawValue: "it loads fine; it only fails while drawing"))

    switch registry.smokeTest(id: "throws", frame: frame) {
    case .success:
      Issue.record("a throwing draw must be reported as a failure")
    case .failure(let issue):
      #expect(issue.message.contains("missingGlobal"), Comment(rawValue: issue.message))
      #expect(issue.message.contains("line 4"), Comment(rawValue: issue.message))
    }
  }

  @MainActor
  @Test
  func testPluginsAreIsolatedFromEachOther() async throws {
    try write("first.js", "var shared = 1; registerVisualizer({ id: 'a', draw() {} });")
    try write(
      "second.js",
      """
      registerVisualizer({
        id: 'b',
        draw(frame, gfx) {
          gfx.text(typeof shared, 10, 10);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))

    guard case .success(let list) = registry.smokeTest(id: "b", frame: frame) else {
      Issue.record("second plugin failed to draw")
      return
    }
    #expect(
      (list.texts) == (["undefined"]), Comment(rawValue: "one plugin's globals must not leak into another's scope"))
  }

  @MainActor
  @Test
  func testPluginCannotMutateOrInflateThePrivateRegistryThroughList() async throws {
    try write(
      "registry-probe.js",
      """
      registerVisualizer({ id: 'safe', name: 'Safe', draw() {} });
      const leaked = __list();
      leaked[0].id = 'poisoned';
      leaked[0].name = 'POISONED';
      leaked.push({ id: 'injected', name: 'INJECTED', continuous: true, file: 'fake.js' });
      leaked.length = 4294967294;
      registerVisualizer({ id: 'after', name: 'After', draw() {} });
      """)

    let registry = await loadedRegistry(folder: unseeded)
    let plugins = registry.descriptors.filter(\.isPlugin)

    #expect((plugins.map(\.id)) == (["safe", "after"]))
    #expect((plugins.map(\.name)) == (["SAFE", "AFTER"]))
    #expect((registry.issues) == ([]))
  }

  @MainActor
  @Test
  func testPluginCannotSpoofOrInflateItsRegistrySourceFile() async throws {
    try write(
      "source-file.js",
      """
      globalThis.__file = 'x'.repeat(1048576);
      registerVisualizer({
        id: 'source-file',
        draw() { throw new Error('draw failed'); }
      });
      """)

    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))

    guard case .failure(let issue) = registry.smokeTest(id: "source-file", frame: frame) else {
      Issue.record("the throwing plugin must fail its smoke test")
      return
    }
    #expect(issue.message.contains("source-file.js"), Comment(rawValue: issue.message))
    #expect(!(issue.message.contains(String(repeating: "x", count: 257))), Comment(rawValue: issue.message))
  }

  @MainActor
  @Test
  func testRegistryRejectsOversizedSourceFileMetadata() async {
    let runtime = VisualizerScriptRuntime()
    let result = await runtime.load([
      VisualizerScript(
        name: String(repeating: "x", count: 257),
        source: "registerVisualizer({ id: 'oversized-file', draw() {} });")
    ])

    #expect(result.descriptors.isEmpty)
    #expect((result.issues.count) == (1))
    #expect(result.issues[0].message.contains("source file exceeds"), Comment(rawValue: result.issues[0].message))
  }

  @MainActor
  @Test
  func testDuplicateIdWithinTheSameLoadIsRejected() async throws {
    try write(
      "dupes.js",
      """
      registerVisualizer({ id: 'dupe', draw() {} });
      registerVisualizer({ id: 'dupe', draw() {} });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.descriptors.filter { $0.id == "dupe" }.count) == (1))
    #expect((registry.issues.count) == (1))
  }

  @MainActor
  @Test
  func testGfxCallsSurviveTheRoundTripToADisplayList() async throws {
    try write(
      "shapes.js",
      """
      registerVisualizer({
        id: 'shapes',
        name: 'Shapes',
        continuous: false,
        draw(frame, gfx) {
          gfx.rect(1, 2, 3, 4, { color: 'amber', glow: true });
          gfx.line(0, 0, frame.width, frame.height, { width: 2 });
          gfx.path([[0, 0], [10, 10], [20, 0]], { closed: true, fill: true });
          gfx.circle(50, 50, 8, { color: '#ff0000' });
          gfx.text('HELLO', 5, 5, { size: 9, align: 'center' });
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))

    let descriptor = try #require(registry.descriptors.first { $0.id == "shapes" })
    #expect((descriptor.name) == ("SHAPES"), Comment(rawValue: "names are upper-cased for the VFD"))
    #expect(!(descriptor.wantsContinuousRedraw), Comment(rawValue: "continuous: false must be honoured"))

    guard case .success(let list) = registry.smokeTest(id: "shapes", frame: frame) else {
      Issue.record("shapes failed to draw")
      return
    }
    #expect((list.texts) == (["HELLO"]))

    let opcodes = Self.opcodes(in: list)
    #expect((opcodes) == ([.rect, .line, .path, .ellipse, .text]))

    #expect(abs((list.ops[5]) - (VisualizerPalette.vfd.amber.red)) <= 0.001)
    #expect(abs((list.ops[6]) - (VisualizerPalette.vfd.amber.green)) <= 0.001)
    #expect((list.ops[9]) == (2), Comment(rawValue: "glow: true becomes a blur radius"))
  }

  @MainActor
  @Test
  func testBatchedPrimitivesCrossTheBridgeAsSingleOps() async throws {
    try write(
      "batches.js",
      """
      registerVisualizer({
        id: 'batches',
        draw(frame, gfx) {
          gfx.dots([[1, 2], [3, 4], [5, 6]], { size: 3, round: true });
          gfx.segments([[0, 0, 1, 1], [2, 2, 3, 3]], { width: 2, color: 'amber' });
          gfx.arc(50, 50, 20, 10, 0, Math.PI, { fill: true });
          gfx.text('W' + gfx.measure('MMMM', 10).toFixed(0), 0, 0);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))

    guard case .success(let list) = registry.smokeTest(id: "batches", frame: frame) else {
      Issue.record("batches failed to draw")
      return
    }
    #expect((Self.opcodes(in: list)) == ([.dots, .segments, .path, .text]))
    #expect((list.ops[1]) == (3))
    #expect((Array(list.ops[2..<8])) == ([1, 2, 3, 4, 5, 6]))
    #expect((list.texts.first) == ("W24"), Comment(rawValue: "measure() reports the monospace advance"))
  }

  @MainActor
  @Test
  func testBatchesLargerThanTheLimitAreClampedBeforeCrossingTheBridge() async throws {
    try write(
      "huge.js",
      """
      registerVisualizer({
        id: 'huge',
        draw(frame, gfx) {
          const points = [];
          for (let i = 0; i < 90000; i++) points.push([i, i]);
          gfx.dots(points, {});
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    guard case .success(let list) = registry.smokeTest(id: "huge", frame: frame) else {
      Issue.record("huge failed to draw")
      return
    }
    #expect((list.ops[1]) == (Double(DisplayList.batchLimit)))
    #expect((Self.opcodes(in: list)) == ([.dots]), Comment(rawValue: "the op stays decodable after clamping"))
  }

  @MainActor
  @Test
  func testPluginCannotReachTheDisplayListsPrivateBackingArrays() async throws {
    try write(
      "private.js",
      """
      registerVisualizer({
        id: 'private',
        draw(frame, gfx) {
          gfx.ops = [];
          gfx.ops.length = 100000000;
          gfx.texts = ['not bridged'];
          gfx.rect(1, 2, 3, 4);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)

    guard case .success(let list) = registry.smokeTest(id: "private", frame: frame) else {
      Issue.record("private backing-array probe failed")
      return
    }
    #expect((Self.opcodes(in: list)) == ([.rect]))
    #expect((list.texts) == ([]))
    #expect((list.ops.count) < (VisualizerScriptRuntime.maximumOperationValues))
  }

  @MainActor
  @Test
  func testPluginOperationAndTextBudgetsAreEnforcedBeforeBridging() async throws {
    try write(
      "operation-flood.js",
      """
      registerVisualizer({
        id: 'operation-flood',
        draw(frame, gfx) {
          for (let i = 0; i < 20001; i++) gfx.rect(0, 0, 1, 1);
        }
      });
      """)
    try write(
      "text-flood.js",
      """
      registerVisualizer({
        id: 'text-flood',
        draw(frame, gfx) { gfx.text('x'.repeat(\(VisualizerScriptRuntime.maximumTextBytes + 1)), 0, 0); }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)

    guard case .success(let operations) = registry.smokeTest(id: "operation-flood", frame: frame)
    else {
      Issue.record("operation helpers should truncate safely at their budget")
      return
    }
    #expect((operations.ops.count) == (VisualizerScriptRuntime.maximumOperationValues))

    guard case .failure(let issue) = registry.smokeTest(id: "text-flood", frame: frame) else {
      Issue.record("oversized text crossed the bridge despite exceeding its byte budget")
      return
    }
    #expect(issue.message.contains("budget"), Comment(rawValue: issue.message))
  }

  @MainActor
  @Test
  func testFrameExposesEnergyAndOnsetHelpers() async throws {
    try write(
      "sense.js",
      """
      registerVisualizer({
        id: 'sense',
        draw(frame, gfx) {
          const parts = [
            frame.bass.toFixed(3), frame.mid.toFixed(3), frame.treble.toFixed(3),
            frame.energy(0, 1).toFixed(3), frame.energy(-9, 9).toFixed(3),
            (frame.beat >= 0 && frame.beat <= 1) ? 'ok' : 'bad',
            String(frame.beats)
          ];
          gfx.text(parts.join('|'), 0, 0);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))
    guard case .success(let list) = registry.smokeTest(id: "sense", frame: frame) else {
      Issue.record("sense failed to draw")
      return
    }
    let parts = try #require(list.texts.first).split(separator: "|").map(String.init)
    #expect((parts.count) == (7))
    let bass = try #require(Double(parts[0]))
    let mid = try #require(Double(parts[1]))
    let treble = try #require(Double(parts[2]))
    #expect((bass) < (mid))
    #expect((mid) < (treble))
    #expect((parts[3]) == (parts[4]), Comment(rawValue: "energy() clamps its range instead of misbehaving"))
    #expect((parts[5]) == ("ok"), Comment(rawValue: "beat stays inside 0…1"))
    #expect((parts[6]) == ("0"), Comment(rawValue: "no onset from a single frame"))
  }

  @MainActor
  @Test
  func testPluginAudioHelpersScrubNonFiniteFramesAndRecoverForTheNextBeat() async throws {
    try write(
      "finite.js",
      """
      registerVisualizer({
        id: 'finite',
        draw(frame, gfx) {
          const values = [
            frame.width, frame.height, frame.time, frame.level,
            frame.elapsed, frame.duration, frame.boot === null ? 0 : frame.boot,
            frame.palette.glow[0], frame.palette.glow[3],
            frame.spectrum[0], frame.peaks[0], frame.waveform[0]
          ];
          frame.spectrum[0] = NaN;
          frame.spectrum[1] = Infinity;
          frame.peaks[1] = -Infinity;
          frame.waveform[1] = NaN;
          frame.waveform[2] = Infinity;
          values.push(
            frame.band(0, 4), frame.peak(1, 4),
            frame.wave(0.5), frame.wave(NaN), frame.energy(0, 1),
            frame.beat, frame.beats
          );
          gfx.text(
            values.every(function (value) { return isFinite(value); })
              ? values.join('|') : 'poisoned',
            0, 0);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    #expect((registry.issues) == ([]))

    var poisoned = frame
    poisoned.size = CGSize(width: CGFloat.nan, height: CGFloat.infinity)
    poisoned.time = .nan
    poisoned.spectrum = [.nan, .infinity, -.infinity, .nan]
    poisoned.peaks = [.infinity, .nan, -.infinity, .nan]
    poisoned.waveform = [-.infinity, .nan, .infinity, .nan]
    poisoned.level = .infinity
    poisoned.elapsed = -.infinity
    poisoned.duration = .nan
    poisoned.boot = .infinity
    poisoned.palette.glow = VisualizerColor(
      red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)

    guard case .success(let poisonedList) = registry.smokeTest(id: "finite", frame: poisoned)
    else {
      Issue.record("a non-finite frame must still reach the plugin as finite values")
      return
    }
    let poisonedValues = try #require(poisonedList.texts.first).split(separator: "|")
    #expect((poisonedValues.count) == (19))
    #expect(
      poisonedValues.allSatisfy { Double($0)?.isFinite == true },
      Comment(rawValue: "the Swift boundary and every JS helper must scrub non-finite values"))
    #expect((poisonedValues[6]) == ("0"), Comment(rawValue: "a non-finite optional boot becomes null"))

    var silence = frame(time: 1.0 / 24, boot: nil, isPlaying: true, level: 0)
    silence.spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    _ = registry.smokeTest(id: "finite", frame: silence)

    var kick = frame(time: 2.0 / 24, boot: nil, isPlaying: true, level: 1)
    kick.spectrum = [Float](repeating: 1, count: SpectrumAnalyzer.bandCount)
    guard case .success(let recovered) = registry.smokeTest(id: "finite", frame: kick)
    else {
      Issue.record("the plugin must recover on the next valid frames")
      return
    }
    let recoveredValues = try #require(recovered.texts.first).split(separator: "|")
    #expect((recoveredValues.last) == ("1"), Comment(rawValue: "valid audio after poison must still detect a beat"))
    #expect((recoveredValues[17]) == ("1"), Comment(rawValue: "the recovered onset must expose a full beat pulse"))
  }

  @MainActor
  @Test
  func testDrawErrorsNameTheFileTheyCameFrom() async throws {
    try write(
      "guilty.js",
      """
      registerVisualizer({
        id: 'guilty',
        draw() { throw new Error('nope'); }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    switch registry.smokeTest(id: "guilty", frame: frame) {
    case .success:
      Issue.record("a throwing draw must be reported as a failure")
    case .failure(let issue):
      #expect(issue.message.contains("guilty.js"), Comment(rawValue: issue.message))
      #expect(issue.message.contains("line 3"), Comment(rawValue: issue.message))
    }
  }

  @MainActor
  @Test
  func testPluginSeesTheAudioItWasGiven() async throws {
    try write(
      "echo.js",
      """
      registerVisualizer({
        id: 'echo',
        draw(frame, gfx) {
          gfx.text(
            [frame.width, frame.spectrum.length, frame.title,
             frame.isPlaying, frame.band(0, 4).toFixed(2)].join('|'),
            0, 0);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    guard case .success(let list) = registry.smokeTest(id: "echo", frame: frame) else {
      Issue.record("echo failed to draw")
      return
    }
    #expect((list.texts.first) == ("400|\(SpectrumAnalyzer.bandCount)|Title|true|0.00"))
  }

  @MainActor
  @Test
  func testRunawayPluginOutputIsCapped() async throws {
    try write(
      "flood.js",
      """
      registerVisualizer({
        id: 'flood',
        draw(frame, gfx) {
          for (let i = 0; i < 500000; i++) gfx.rect(i, 0, 1, 1);
        }
      });
      """)
    let registry = await loadedRegistry(folder: unseeded)
    guard case .success(let list) = registry.smokeTest(id: "flood", frame: frame) else {
      Issue.record("flood failed to draw")
      return
    }
    #expect(
      (list.ops.count) < (210_000), Comment(rawValue: "a plugin must not be able to grow the display list unbounded"))
  }

  @Test
  func testMalformedDisplayListsAreRejectedRatherThanCrashing() {
    for list in Self.hostileLists {
      #expect(throws: Never.self) { Self.opcodes(in: list) }
    }
  }

  @MainActor
  @Test
  func testMalformedDisplayListsSurviveARealRenderPass() {
    for list in Self.hostileLists {
      let renderer = ImageRenderer(
        content: Canvas { context, _ in
          var ctx = context
          list.render(into: &ctx)
        }
        .frame(width: 40, height: 20))
      #expect(renderer.cgImage != nil, Comment(rawValue: "a malformed list must still produce a frame"))
    }
  }

  private static let hostileLists: [DisplayList] = [
    DisplayList(ops: [0, 1, 2], texts: []),
    DisplayList(ops: [99, 1, 2, 3], texts: []),
    DisplayList(ops: [4, 0, 0, 10, 1, 1, 1, 1, 0, 0, 7], texts: []),
    DisplayList(ops: [0, .nan, .infinity, 5, 5, 1, 1, 1, 1, 0], texts: []),
    DisplayList(ops: [2, 3, 0, 0, 1], texts: []),
    DisplayList(ops: [2, -5, 1, 1, 1, 1, 1, 1, 1, 1], texts: []),
    DisplayList(ops: [5, 4, 0, 0], texts: []),
    DisplayList(ops: [5, -1, 0, 0, 1, 1, 1, 1, 1, 0, 0], texts: []),
    DisplayList(ops: [5, 1e9, 0, 0, 1, 1, 1, 1, 1, 0, 0], texts: []),
    DisplayList(ops: [5, 1, .nan, .infinity, 2, 1, 1, 1, 1, 0, 1], texts: []),
    DisplayList(ops: [6, 2, 0, 0, 1, 1], texts: []),
    DisplayList(ops: [6, -3, 0, 0, 1, 1, 1, 1, 1, 1, 0], texts: []),
    DisplayList(ops: [6, 1, .nan, 0, 1, .infinity, 1, 1, 1, 1, 1, 0], texts: []),
    DisplayList(ops: [2, .nan, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0], texts: []),
    DisplayList(ops: [5, .infinity, 0, 0, 1, 1, 1, 1, 1, 0, 0], texts: []),
    DisplayList(ops: [6, -.infinity, 0, 0, 1, 1, 1, 1, 1, 1, 0], texts: []),
    DisplayList(ops: [5, 1e300, 0, 0, 1, 1, 1, 1, 1, 0, 0], texts: []),
    DisplayList(ops: [4, 0, 0, .nan, 1, 1, 1, 1, 0, .nan, .nan], texts: ["a"]),
    DisplayList(ops: [4, 0, 0, 8, 1, 1, 1, 1, 0, 0, .infinity], texts: ["a"]),
  ]

  private static func opcodes(in list: DisplayList) -> [DisplayList.Op] {
    var found: [DisplayList.Op] = []
    var i = 0
    while i < list.ops.count {
      guard let op = DisplayList.Op(rawValue: list.ops[i]) else { return found }
      i += 1
      let arguments: Int
      switch op {
      case .rect: arguments = 9
      case .line, .ellipse, .text: arguments = 10
      case .path, .dots, .segments:
        guard i < list.ops.count, list.ops[i].isFinite, list.ops[i].magnitude < 1e9
        else { return found }
        let count = Int(list.ops[i])
        let minimum = op == .path ? 2 : 1
        guard count >= minimum, count <= DisplayList.batchLimit else { return found }
        switch op {
        case .path: arguments = 1 + count * 2 + 8
        case .dots: arguments = 1 + count * 2 + 7
        default: arguments = 1 + count * 4 + 6
        }
      }
      guard i + arguments <= list.ops.count else { return found }
      i += arguments
      found.append(op)
    }
    return found
  }
}

@MainActor
private final class BeatProbeVisualizer: RasterVisualizer {
  private(set) var observedBeat = false

  init() {
    super.init(id: "beat-probe", rows: 8, levels: 2)
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    observedBeat = observedBeat || didBeat
  }
}

@MainActor
enum VisualizerProbe {
  static func draw(_ visualizer: any Visualizer, _ frame: VisualizerFrame) {
    let renderer = ImageRenderer(
      content: VisualizerProbeView(visualizer: visualizer, frame: frame)
        .frame(width: frame.size.width, height: frame.size.height))
    _ = renderer.cgImage
  }
}

private struct VisualizerProbeView: View {
  let visualizer: any Visualizer
  let frame: VisualizerFrame

  var body: some View {
    Canvas { context, size in
      var probe = frame
      probe.size = size
      visualizer.draw(probe, into: &context)
    }
  }
}
