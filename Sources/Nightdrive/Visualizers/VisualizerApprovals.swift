import CryptoKit
import Foundation

struct VisualizerApprovals: Equatable, Sendable {
  var records: [String: String] = [:]

  subscript(name: String) -> String? {
    get { records[name] }
    set { records[name] = newValue }
  }

  static func hash(of contents: String) -> String {
    SHA256.hash(data: Data(contents.utf8)).hexString
  }

  func approves(name: String, hash: String) -> Bool {
    records[name] == hash
  }
}

/// Approvals persist in the app's preferences domain, never in the plugins
/// folder they guard. Injectable so tests use their own suite.
struct VisualizerApprovalStore: @unchecked Sendable {
  static let defaultsKey = "visualizerPluginApprovals"

  var defaults: UserDefaults = NightdriveDefaults.current

  func load() -> VisualizerApprovals {
    guard let data = defaults.data(forKey: Self.defaultsKey),
      let records = try? JSONDecoder().decode([String: String].self, from: data)
    else { return VisualizerApprovals() }
    return VisualizerApprovals(records: records)
  }

  @discardableResult
  func save(_ approvals: VisualizerApprovals) -> Bool {
    guard let data = try? JSONEncoder().encode(approvals.records)
    else { return false }
    defaults.set(data, forKey: Self.defaultsKey)
    return true
  }
}
