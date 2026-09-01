import Foundation
import Observation

@Observable
@MainActor
final class VisualizerRegistry {
  static let shared = VisualizerRegistry()

  private(set) var visualizers: [any Visualizer] = []
  private(set) var issues: [VisualizerScriptIssue] = []
  private(set) var pendingApproval: [VisualizerPluginFolder.PendingScript] = []
  private(set) var isLoadingPlugins = false

  let folder: VisualizerPluginFolder
  private let runtime = VisualizerScriptRuntime()
  private let builtIns: [any Visualizer]
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(folder: VisualizerPluginFolder = .default, loadPlugins: Bool = true) {
    self.folder = folder
    builtIns = Self.makeBuiltIns()
    visualizers = builtIns
    if loadPlugins { reloadPlugins() }
  }

  private static func makeBuiltIns() -> [any Visualizer] {
    [
      SpectrumVisualizer(),
      ScopeVisualizer(),
      WaterfallVisualizer(),
      PlasmaVisualizer(),
      FireVisualizer(),
      TunnelVisualizer(),
      RotozoomVisualizer(),
      VectorVisualizer(),
      MetaballVisualizer(),
    ] + HeadUnitVisualizers.all() + MovieScreenVisualizers.all()
  }

  var descriptors: [VisualizerDescriptor] { visualizers.map(\.descriptor) }

  func visualizer(id: String) -> (any Visualizer)? {
    visualizers.first { $0.descriptor.id == id }
  }

  func pluginURL(for id: String) -> URL? {
    guard visualizers.first(where: { $0.descriptor.id == id })?.descriptor.isPlugin == true,
      let fileName = runtime.fileName(for: id), fileName.hasSuffix(".js"),
      URL(fileURLWithPath: fileName).lastPathComponent == fileName
    else { return nil }
    return folder.url.appendingPathComponent(fileName, isDirectory: false)
  }

  func reloadPlugins() {
    loadGeneration += 1
    let generation = loadGeneration
    isLoadingPlugins = true
    let folder = folder
    let runtime = runtime
    let priorLoad = loadTask
    loadTask = Task {
      await priorLoad?.value
      let discovery = await Task.detached(priority: .userInitiated) {
        folder.createIfNeeded()
        return folder.discoverScripts()
      }.value
      let loaded = await runtime.load(discovery.scripts)
      guard generation == loadGeneration else { return }
      publish(discovery: discovery, loaded: loaded)
    }
  }

  func waitUntilReady() async {
    await loadTask?.value
  }

  func reloadPluginsAndWait() async {
    reloadPlugins()
    await waitUntilReady()
  }

  private func publish(
    discovery: VisualizerPluginFolder.ScriptDiscovery, loaded: VisualizerScriptLoadResult
  ) {
    var issues = discovery.issues + loaded.issues

    let reserved = Set(builtIns.map(\.descriptor.id))
    var plugins: [any Visualizer] = []
    for descriptor in loaded.descriptors {
      guard !reserved.contains(descriptor.id) else {
        issues.append(
          VisualizerScriptIssue(
            source: descriptor.id,
            message: String(
              localized: "id \"\(descriptor.id)\" is taken by a built-in mode")))
        continue
      }
      plugins.append(ScriptVisualizer(descriptor: descriptor, runtime: runtime))
    }

    visualizers = builtIns + plugins
    self.issues = issues
    pendingApproval = discovery.pending
    isLoadingPlugins = false
  }

  func approve(_ script: VisualizerPluginFolder.PendingScript) {
    guard folder.approve(script) else { return }
    reloadPlugins()
  }

  func smokeTest(id: String, frame: VisualizerFrame) -> Result<
    DisplayList, VisualizerScriptIssue
  > {
    runtime.renderSynchronously(id: id, frame: frame)
  }
}
