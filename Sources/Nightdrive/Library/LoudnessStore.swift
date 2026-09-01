import CryptoKit
import Foundation

private struct SourceIdentity: Equatable, Sendable {
  let canonicalPath: String
  let stamp: FileGenerationStamp

  var sourceURL: URL { URL(fileURLWithPath: canonicalPath) }

  static func capture(_ url: URL) -> SourceIdentity? {
    let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
    guard let stamp = FileGenerationStamp(url: canonicalURL) else { return nil }
    return SourceIdentity(
      canonicalPath: canonicalURL.path,
      stamp: stamp)
  }

  static func captured(originalURL: URL, stamp: FileGenerationStamp) -> SourceIdentity {
    SourceIdentity(
      canonicalPath: originalURL.resolvingSymlinksInPath().standardizedFileURL.path,
      stamp: stamp)
  }
}

struct LoudnessStore: Sendable {
  static let directoryEnvironmentKey = "NIGHTDRIVE_LOUDNESS_CACHE"

  let directory: URL
  private let measureGain: @Sendable (URL) -> Double?

  init(
    directory: URL? = nil,
    measureGain: @escaping @Sendable (URL) -> Double? = {
      LoudnessAnalyzer.measureGain(url: $0)
    }
  ) {
    self.directory =
      directory
      ?? Self.defaultDirectory(environment: ProcessInfo.processInfo.environment)
    self.measureGain = measureGain
  }

  static func defaultDirectory(environment: [String: String]) -> URL {
    CacheDirectory.resolve(
      environment: environment, overrideKey: directoryEnvironmentKey,
      subdirectory: "Nightdrive/LoudnessCache")
  }

  func cachedGain(forSource url: URL) -> Double? {
    guard let identity = SourceIdentity.capture(url) else { return nil }
    return cachedGain(for: identity)
  }

  private func cachedGain(for identity: SourceIdentity) -> Double? {
    let entry = entryURL(for: identity)
    guard
      let text = try? String(contentsOf: entry, encoding: .utf8),
      let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
      value.isFinite
    else { return nil }
    return value
  }

  func gain(forSource url: URL) -> Double? {
    guard let identity = SourceIdentity.capture(url) else { return nil }
    return gain(for: identity, retryIfChanged: true)
  }

  private func gain(for identity: SourceIdentity, retryIfChanged: Bool) -> Double? {
    if let cached = cachedGain(for: identity) { return cached }
    let gain = measureGain(identity.sourceURL)
    guard let currentIdentity = SourceIdentity.capture(identity.sourceURL) else { return nil }
    guard currentIdentity == identity else {
      guard retryIfChanged else { return nil }
      return self.gain(for: currentIdentity, retryIfChanged: false)
    }
    guard let gain else { return nil }
    store(gain: gain, for: identity)
    return gain
  }

  func gain(
    forCapturedSource originalURL: URL,
    fileGenerationStamp: FileGenerationStamp,
    measuring snapshotURL: URL
  ) -> Double? {
    let identity = SourceIdentity.captured(
      originalURL: originalURL, stamp: fileGenerationStamp)
    if let cached = cachedGain(for: identity) { return cached }
    guard let gain = measureGain(snapshotURL) else { return nil }
    store(gain: gain, for: identity)
    return gain
  }

  func store(gain: Double, forSource url: URL) {
    guard let identity = SourceIdentity.capture(url) else { return }
    store(gain: gain, for: identity)
  }

  private func store(gain: Double, for identity: SourceIdentity) {
    guard gain.isFinite else { return }
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    try? Data(String(gain).utf8).write(to: entryURL(for: identity), options: .atomic)
  }

  private func entryURL(for identity: SourceIdentity) -> URL {
    let key = "\(identity.canonicalPath)|\(identity.stamp.cacheKey)"
    let name = SHA256.hash(data: Data(key.utf8)).hexString
    return directory.appendingPathComponent("\(name).gain")
  }
}
