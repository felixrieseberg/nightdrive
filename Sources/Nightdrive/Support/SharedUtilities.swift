import Darwin
import Foundation

extension URL {
  /// Resolve the deepest existing ancestor with `realpath`, then restore any
  /// missing descendants. Foundation otherwise switches between `/var` and
  /// `/private/var` depending on whether the final component exists.
  var canonicalFileURL: URL {
    var normalizedComponents: [Substring] = []
    for component in path.split(separator: "/", omittingEmptySubsequences: true) {
      if component == "." { continue }
      if component == ".." {
        if !normalizedComponents.isEmpty { normalizedComponents.removeLast() }
      } else {
        normalizedComponents.append(component)
      }
    }
    let normalizedPath = "/" + normalizedComponents.joined(separator: "/")
    var existingAncestor = URL(fileURLWithPath: normalizedPath)
    var missingComponents: [String] = []
    var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))

    while realpath(existingAncestor.path, &resolvedPath) == nil {
      let parent = existingAncestor.deletingLastPathComponent()
      guard parent.path != existingAncestor.path else {
        return URL(fileURLWithPath: normalizedPath)
      }
      missingComponents.append(existingAncestor.lastPathComponent)
      existingAncestor = parent
    }

    let terminator = resolvedPath.firstIndex(of: 0) ?? resolvedPath.endIndex
    let path = String(
      decoding: resolvedPath[..<terminator].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var resolved = URL(fileURLWithPath: path)
    for component in missingComponents.reversed() {
      resolved.appendPathComponent(component)
    }
    return resolved
  }
}

/// Component-safe path containment: `/Volumes/iPod2` is never inside
/// `/Volumes/iPod`. Callers must normalize both paths the same way first
/// (standardized, symlink-resolved, or canonical); no resolution happens here.
enum PathContainment {
  static func path(_ childPath: String, isInside rootPath: String, allowRoot: Bool) -> Bool {
    (allowRoot && childPath == rootPath) || childPath.hasPrefix(rootPath + "/")
  }

  /// The remainder of `childPath` below `rootPath`, or nil when the child is
  /// not strictly inside the root.
  static func relativePath(of childPath: String, inside rootPath: String) -> String? {
    let prefix = rootPath + "/"
    guard childPath.hasPrefix(prefix) else { return nil }
    return String(childPath.dropFirst(prefix.count))
  }
}

extension URL {
  /// Containment on standardized paths. Standardizing does not resolve
  /// symlinks; callers that need symlink safety must resolve both URLs first.
  func isContained(in root: URL, allowRoot: Bool = true) -> Bool {
    PathContainment.path(
      standardizedFileURL.path, isInside: root.standardizedFileURL.path, allowRoot: allowRoot)
  }
}

extension Task where Success == Never, Failure == Never {
  /// Sleep without surfacing cancellation as an error. Callers that need to
  /// stop early should check `Task.isCancelled` after the pause.
  static func pause(for duration: Duration) async {
    try? await sleep(for: duration)
  }
}

extension FileManager {
  /// Remove an item where failure is acceptable and deliberately ignored,
  /// such as clearing temporaries, staging directories, or cache entries.
  func bestEffortRemoveItem(at url: URL) {
    try? removeItem(at: url)
  }
}

extension Sequence where Element == UInt8 {
  var hexString: String {
    map { String(format: "%02x", $0) }.joined()
  }
}

enum CacheDirectory {
  static func resolve(
    environment: [String: String], overrideKey: String, subdirectory: String
  ) -> URL {
    if let override = environment[overrideKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent(subdirectory, isDirectory: true)
  }
}

extension String {
  /// Collapses every whitespace-and-newline run into a single space and
  /// drops leading/trailing runs entirely.
  var collapsingWhitespace: String {
    components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
