import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Nightdrive

@MainActor
struct PluginHangSafetyTests: PluginFolderFixtureProviding {
  let pluginFixture = PluginFolderFixture()
  private var frame: VisualizerFrame {
    let spectrum = (0..<SpectrumAnalyzer.bandCount).map { Float($0) / 28 }
    return VisualizerFrame(
      size: CGSize(width: 400, height: 100),
      time: 2,
      spectrum: spectrum,
      peaks: spectrum,
      waveform: (0..<96).map { Float(sin(Double($0) / 8)) },
      level: 0.5,
      elapsed: 30,
      duration: 200,
      isPlaying: true,
      title: "Title", artist: "Artist", album: "Album",
      boot: nil)
  }

  @Test
  func testTopLevelInfiniteLoopDoesNotHangLoadingAndIsReportedFailed() async throws {
    try write("evil.js", "while (true) {}")
    try write("good.js", "registerVisualizer({ id: 'good', name: 'Good', draw() {} });")

    let started = Date()
    let registry = VisualizerRegistry(folder: unseeded)
    let initializationElapsed = Date().timeIntervalSince(started)

    #expect(
      (initializationElapsed) < (0.25),
      Comment(rawValue: "registry initialization must publish built-ins without waiting for plugin JavaScript"))
    #expect(registry.descriptors.allSatisfy { !$0.isPlugin })
    #expect(registry.descriptors.contains { $0.id == "spectrum" })
    #expect(registry.isLoadingPlugins)

    await registry.waitUntilReady()
    let readinessElapsed = Date().timeIntervalSince(started)
    #expect(!(registry.isLoadingPlugins))

    #expect((readinessElapsed) < (15), Comment(rawValue: "loading a runaway plugin must not hang the load path"))

    #expect(
      (registry.descriptors.filter(\.isPlugin).map(\.id)) == (["good"]),
      Comment(rawValue: "the healthy plugin must still load"))
    #expect(registry.descriptors.contains { $0.id == "spectrum" }, Comment(rawValue: "the built-ins must be untouched"))
    #expect((registry.issues.map(\.source)) == (["evil.js"]))
    #expect(
      registry.issues.first?.message.contains("terminated") ?? false,
      Comment(rawValue: registry.issues.first?.message ?? "no issue recorded"))
  }

  @Test
  func testInfiniteLoopInDrawFailsInsteadOfHanging() async throws {
    try write(
      "spin.js",
      """
      registerVisualizer({ id: 'spin', draw() { while (true) {} } });
      """)
    let registry = await loadedRegistry()
    #expect((registry.issues) == ([]), Comment(rawValue: "it loads fine; it only hangs while drawing"))

    let started = Date()
    let result = registry.smokeTest(id: "spin", frame: frame)
    #expect((Date().timeIntervalSince(started)) < (15), Comment(rawValue: "a runaway draw must not hang render"))

    switch result {
    case .success:
      Issue.record("a runaway draw must be reported as a failure")
    case .failure(let issue):
      #expect(issue.message.contains("terminated"), Comment(rawValue: issue.message))
    }

    try write("ok.js", "registerVisualizer({ id: 'ok', draw(f, g) { g.rect(0, 0, 1, 1); } });")
    await registry.reloadPluginsAndWait()
    guard case .success = registry.smokeTest(id: "ok", frame: frame) else {
      Issue.record("the runtime must keep working after interrupting a runaway plugin")
      return
    }
  }

  @Test
  func testThrowingPluginLatchesOffAndDrawsItsErrorCard() async throws {
    try write(
      "boom.js",
      """
      registerVisualizer({ id: 'boom', name: 'Boom', draw() { missing.boom(); } });
      """)
    let registry = await loadedRegistry()
    guard let visualizer = registry.visualizer(id: "boom") as? ScriptVisualizer else {
      Issue.record("the plugin should have registered")
      return
    }
    #expect(visualizer.failure == nil, Comment(rawValue: "it hasn't drawn yet"))

    VisualizerProbe.draw(visualizer, frame)
    let failureArrived = await waitUntil { visualizer.failure != nil }
    #expect(failureArrived, Comment(rawValue: "the throwing draw should latch a failure"))
    #expect(visualizer.failure?.contains("missing") ?? false, Comment(rawValue: visualizer.failure ?? "nil"))

    VisualizerProbe.draw(visualizer, frame)
  }

  @Test
  func testHealthyPluginRendersThroughTheAsyncPath() async throws {
    try write(
      "dot.js",
      """
      registerVisualizer({ id: 'dot', draw(frame, gfx) { gfx.rect(1, 1, 2, 2); } });
      """)
    let registry = await loadedRegistry()
    guard let visualizer = registry.visualizer(id: "dot") as? ScriptVisualizer else {
      Issue.record("the plugin should have registered")
      return
    }

    VisualizerProbe.draw(visualizer, frame)
    let stayedHealthy = await holds(for: .milliseconds(300), pollInterval: .milliseconds(20)) {
      visualizer.failure == nil
    }
    VisualizerProbe.draw(visualizer, frame)
    #expect(stayedHealthy, Comment(rawValue: "a healthy plugin must not latch a failure"))
    #expect(visualizer.failure == nil, Comment(rawValue: "a healthy plugin must not latch a failure"))
  }

  @Test
  func testResetDiscardsCompletionFromThePreviousGeneration() async throws {
    try write(
      "generation.js",
      """
      let beforeReset = true;
      registerVisualizer({
        id: 'generation',
        reset() { beforeReset = false; },
        draw(frame, gfx) {
          if (beforeReset) throw new Error('stale generation');
          gfx.rect(1, 1, 2, 2);
        }
      });
      """)
    let registry = await loadedRegistry()
    guard let visualizer = registry.visualizer(id: "generation") as? ScriptVisualizer else {
      Issue.record("the plugin should have registered")
      return
    }

    VisualizerProbe.draw(visualizer, frame)
    visualizer.reset()
    VisualizerProbe.draw(visualizer, frame)
    let staleCompletionDiscarded = await holds(
      for: .milliseconds(300), pollInterval: .milliseconds(20)
    ) {
      visualizer.failure == nil
    }

    #expect(
      staleCompletionDiscarded,
      Comment(rawValue: "the throwing completion queued before reset must not latch onto the new generation"))
  }

  @Test
  func testWatchdogUnavailableStillLoadsPluginsAndReportsIt() async {
    let runtime = VisualizerScriptRuntime(watchdogEnabled: false)
    #expect(!(runtime.watchdogAvailable))

    let script = VisualizerScript(
      name: "ok.js",
      source: "registerVisualizer({ id: 'ok', name: 'Ok', draw(f, g) { g.rect(0, 0, 1, 1); } });")
    let result = await runtime.load([script])

    #expect(
      (result.descriptors.map(\.id)) == (["ok"]), Comment(rawValue: "plugins must still load without the watchdog"))
    #expect(
      result.issues.contains {
        $0.source == "runtime" && $0.message.contains("watchdog unavailable")
      }, Comment(rawValue: "the missing guard must be reported, not silent: \(result.issues)"))
    guard case .success = runtime.renderSynchronously(id: "ok", frame: frame) else {
      Issue.record("a healthy plugin must still render without the watchdog")
      return
    }
  }

  @Test
  func testWatchdogUnavailableIsSilentWithNoPlugins() async {
    let runtime = VisualizerScriptRuntime(watchdogEnabled: false)
    let result = await runtime.load([])
    #expect((result.issues) == ([]), Comment(rawValue: "an empty folder needs no watchdog warning"))
  }

  @Test
  func testWatchdogIsAvailableOnThisSystem() {
    #expect(
      VisualizerScriptRuntime().watchdogAvailable,
      Comment(rawValue: "the execution time limit should be present on a supported macOS"))
  }
}
