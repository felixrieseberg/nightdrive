import Foundation

struct VisualizerPluginFolder: Sendable {
  static let maximumScriptCount = 32
  static let maximumScriptBytes = 512 * 1024
  static let maximumAggregateScriptBytes = 2 * 1024 * 1024

  var url: URL

  var approvalStore = VisualizerApprovalStore()

  struct ScriptDiscovery: Sendable {
    var scripts: [VisualizerScript]
    var issues: [VisualizerScriptIssue]
    var pending: [PendingScript] = []
  }

  struct PendingScript: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var hash: String
  }

  var requiresApproval = true

  var examples: [VisualizerExamples.Example] = VisualizerExamples.all

  static let `default`: VisualizerPluginFolder = {
    if let override = ProcessInfo.processInfo.environment["NIGHTDRIVE_VISUALIZER_DIR"],
      !override.isEmpty
    {
      return VisualizerPluginFolder(url: URL(fileURLWithPath: override, isDirectory: true))
    }
    let support = try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false)
    return VisualizerPluginFolder(
      url: support?
        .appendingPathComponent("Nightdrive", isDirectory: true)
        .appendingPathComponent("Visualizers", isDirectory: true)
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("NightdriveVisualizers", isDirectory: true))
  }()

  func createIfNeeded() {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: url.path) else { return }
    guard (try? manager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
    else { return }
    for example in examples {
      let file = url.appendingPathComponent(example.name)
      try? Data(example.contents.utf8).write(to: file, options: .withoutOverwriting)
    }
  }

  func scripts() -> [VisualizerScript] {
    discoverScripts().scripts
  }

  func discoverScripts() -> ScriptDiscovery {
    let manager = FileManager.default
    guard
      let entries = manager.enumerator(
        at: url, includingPropertiesForKeys: nil,
        options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in true })
    else { return ScriptDiscovery(scripts: [], issues: []) }
    var candidates: [String] = []
    var extraCandidateCount = 0

    func insertCandidate(_ name: String) {
      let insertion = candidates.firstIndex { name < $0 } ?? candidates.endIndex
      candidates.insert(name, at: insertion)
      if candidates.count > Self.maximumScriptCount {
        candidates.removeLast()
      }
    }

    for case let file as URL in entries {
      let name = file.lastPathComponent
      guard name.hasSuffix(".js"), !name.hasPrefix(".") else { continue }
      if candidates.count < Self.maximumScriptCount {
        insertCandidate(name)
        continue
      }
      if extraCandidateCount < Int.max {
        extraCandidateCount += 1
      }
      if let last = candidates.last, name < last {
        insertCandidate(name)
      }
    }

    var scripts: [VisualizerScript] = []
    var issues: [VisualizerScriptIssue] = []
    var pending: [PendingScript] = []
    var bytesRead = 0

    let trustedHashes = Dictionary(
      uniqueKeysWithValues: examples.map {
        ($0.name, VisualizerApprovals.hash(of: $0.contents))
      })
    var approvals = requiresApproval ? approvalStore.load() : nil
    var approvalsChanged = false

    if extraCandidateCount > 0 {
      issues.append(
        VisualizerScriptIssue(
          source: "plugins",
          message: String(
            localized:
              "only the first \(Self.maximumScriptCount) JavaScript plugin files were loaded; \(extraCandidateCount) exceeded the folder limit"
          )))
    }

    for name in candidates {
      let remaining = Self.maximumAggregateScriptBytes - bytesRead
      guard remaining > 0 else {
        issues.append(
          VisualizerScriptIssue(
            source: name,
            message: String(
              localized: "plugin was not loaded because the folder byte limit was reached")))
        continue
      }

      let file = url.appendingPathComponent(name)
      let readLimit = min(Self.maximumScriptBytes, remaining)
      guard let handle = try? FileHandle(forReadingFrom: file) else {
        issues.append(
          VisualizerScriptIssue(
            source: name, message: String(localized: "plugin file could not be read")))
        continue
      }
      var data: Data?
      do {
        data = try handle.read(upToCount: readLimit + 1)
        try handle.close()
      } catch {
        try? handle.close()
        data = nil
      }
      guard let data else {
        issues.append(
          VisualizerScriptIssue(
            source: name, message: String(localized: "plugin file could not be read")))
        continue
      }
      bytesRead += data.count
      guard data.count <= readLimit else {
        let message =
          readLimit < Self.maximumScriptBytes
          ? String(localized: "plugin was not loaded because the folder byte limit was reached")
          : String(localized: "plugin exceeds the \(Self.maximumScriptBytes)-byte file limit")
        issues.append(VisualizerScriptIssue(source: name, message: message))
        continue
      }
      guard let source = String(data: data, encoding: .utf8) else {
        issues.append(
          VisualizerScriptIssue(
            source: name,
            message: String(localized: "plugin file could not be read as valid UTF-8")))
        continue
      }
      if requiresApproval {
        let hash = VisualizerApprovals.hash(of: source)
        let shipped = trustedHashes[name] == hash
        let approved = approvals?.approves(name: name, hash: hash) == true
        let trusted = shipped || approved
        guard trusted else {
          pending.append(PendingScript(name: name, hash: hash))
          continue
        }
        if shipped, !approved {
          approvals?[name] = hash
          approvalsChanged = true
        }
      }
      scripts.append(VisualizerScript(name: name, source: source))
    }
    if approvalsChanged, let approvals { approvalStore.save(approvals) }
    return ScriptDiscovery(scripts: scripts, issues: issues, pending: pending)
  }

  @discardableResult
  func approve(_ script: PendingScript) -> Bool {
    var approvals = approvalStore.load()
    approvals[script.name] = script.hash
    return approvalStore.save(approvals)
  }
}

enum VisualizerExamples {
  struct Example: Equatable, Sendable {
    var name: String
    var source: String

    var contents: String { source.hasSuffix("\n") ? source : source + "\n" }
  }

  static let shippedNames: [String] = [
    "README.md", "constellation.js", "eq-ladder.js", "glyph-rain.js",
    "hyperwarp.js", "radar.js", "vectorscope.js", "wireframe.js",
  ]

  static let all: [Example] = {
    guard
      let bundle = Bundle.nightdriveResources,
      let folder = bundle.url(forResource: "VisualizerExamples", withExtension: nil)
    else { return [] }
    return shippedNames.compactMap { name in
      guard
        let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
        let source = String(data: data, encoding: .utf8)
      else { return nil }
      return Example(name: name, source: source)
    }
  }()

  static let ids: [String] = [
    "constellation", "eqladder", "glyphrain", "hyperwarp",
    "radar", "vectorscope", "wireframe",
  ]
}
