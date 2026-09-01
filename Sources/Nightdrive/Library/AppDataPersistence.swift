import Foundation

/// The running app's preferences domain: the normal application domain, or a
/// disposable suite when a GUI tour opts in so it cannot touch real state.
/// Resolved once and never reassigned, so the `nonisolated(unsafe)` global
/// behaves as a `let`.
enum NightdriveDefaults {
  static let suiteEnvironmentKey = "NIGHTDRIVE_DEFAULTS_SUITE"

  nonisolated(unsafe) static let current = resolve(
    environment: ProcessInfo.processInfo.environment)

  static func resolve(environment: [String: String]) -> UserDefaults {
    guard
      let suite = environment[suiteEnvironmentKey]?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      !suite.isEmpty,
      let defaults = UserDefaults(suiteName: suite)
    else {
      return .standard
    }
    return defaults
  }
}

protocol AppDataPersistence: Sendable {
  func load() throws -> Data?
  func save(_ data: Data) throws
}

/// Encodes app data JSON with sorted keys so saved files are byte-stable.
func encodeAppDataJSON<Value: Encodable>(_ value: Value) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  return try encoder.encode(value)
}

protocol RemovableAppDataPersistence: AppDataPersistence {
  func remove() throws
}

/// Serializes and writes app-data snapshots without occupying the main actor.
/// Stores debounce before handing a value to this actor, so the actor only
/// receives snapshots that are actually candidates for persistence.
actor AppDataSnapshotWriter<Value: Encodable & Sendable> {
  private let persistence: any AppDataPersistence
  private let fileURL: URL?
  private let parentURL: URL?
  private let expectedParentIdentity: LibraryRootIdentity?
  private var expectedFileGeneration: FileGenerationStamp?
  private var latestSavedGeneration: UInt64?

  init(persistence: any AppDataPersistence) {
    self.persistence = persistence
    let filePersistence = persistence as? FileDataPersistence
    self.fileURL = filePersistence?.fileURL
    // Library sidecars deliberately refuse to create their parent. Pin that
    // directory too, so a delayed write cannot land in a replacement library
    // after the original sidecar disappears with the old root.
    let parentURL =
      filePersistence?.createsParentDirectories == false
      ? filePersistence?.fileURL.deletingLastPathComponent() : nil
    self.parentURL = parentURL
    self.expectedParentIdentity = parentURL.flatMap {
      try? LibraryRootPreflight.inspect($0.resolvingSymlinksInPath()).get().identity
    }
    self.expectedFileGeneration = fileURL.flatMap(FileGenerationStamp.init(url:))
  }

  func save(_ value: Value, generation: UInt64) throws {
    if let latestSavedGeneration, generation <= latestSavedGeneration { return }
    try validateParentIdentity()
    try validateFileGeneration()
    try persistence.save(encodeAppDataJSON(value))
    expectedFileGeneration = fileURL.flatMap(FileGenerationStamp.init(url:))
    latestSavedGeneration = generation
  }

  private func validateParentIdentity() throws {
    guard let parentURL, let expectedParentIdentity else { return }
    let current = try LibraryRootPreflight.inspect(
      parentURL.resolvingSymlinksInPath()
    ).get()
    guard current.identity == expectedParentIdentity else {
      throw LibraryRootPreflightError(reason: .replaced)
    }
  }

  private func validateFileGeneration() throws {
    guard let fileURL else { return }
    let current = FileGenerationStamp(url: fileURL)
    if let current, let expectedFileGeneration,
      !sameFileContents(current, expectedFileGeneration)
    {
      throw AppDataDeferredWriteError(
        reason: String(
          localized:
            "Saved library data changed outside Nightdrive. Reload the library before saving more changes."))
    }
    if current != nil, expectedFileGeneration == nil {
      throw AppDataDeferredWriteError(
        reason: String(
          localized:
            "Saved library data appeared outside Nightdrive. Reload the library before saving more changes."))
    }
    if current != nil, !FileManager.default.isReadableFile(atPath: fileURL.path) {
      throw AppDataDeferredWriteError(
        reason: String(
          localized:
            "Saved library data could not be read. Restore access to the library folder and reload the library before saving more changes."
        ))
    }
  }

  private func sameFileContents(
    _ first: FileGenerationStamp, _ second: FileGenerationStamp
  ) -> Bool {
    first.deviceID == second.deviceID && first.inode == second.inode
      && first.sizeBytes == second.sizeBytes
      && first.modificationSeconds == second.modificationSeconds
      && first.modificationNanoseconds == second.modificationNanoseconds
      && first.generation == second.generation
  }
}

struct AppDataDeferredWriteError: LocalizedError, Sendable {
  let reason: String

  var errorDescription: String? { reason }
}

struct AppDataRetiredWriteError: LocalizedError, Sendable {
  let reason: String

  var errorDescription: String? { reason }
}

struct AppDataLibraryNotSelectedError: LocalizedError, Sendable {
  var errorDescription: String? {
    String(localized: "Choose a library folder before saving library data.")
  }
}

enum NightdriveAppData {
  static let directoryEnvironmentKey = "NIGHTDRIVE_APP_DATA_DIR"

  static let defaultDirectoryURL = directoryURL()

  static func directoryURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL {
    if let override = environment[directoryEnvironmentKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines), !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
    }
    let root =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return
      root
      .appendingPathComponent("Nightdrive", isDirectory: true)
      .standardizedFileURL
  }
}

struct FileDataPersistence: RemovableAppDataPersistence {
  let fileURL: URL
  let createsParentDirectories: Bool

  init(fileURL: URL, createsParentDirectories: Bool = true) {
    self.fileURL = fileURL.standardizedFileURL
    self.createsParentDirectories = createsParentDirectories
  }

  func load() throws -> Data? {
    do {
      return try Data(contentsOf: fileURL)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }

  func save(_ data: Data) throws {
    let parent = fileURL.deletingLastPathComponent()
    if createsParentDirectories {
      try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    } else {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else {
        throw LibraryRootPreflightError(reason: .missing)
      }
    }
    try data.write(to: fileURL, options: .atomic)
  }

  func remove() throws {
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch CocoaError.fileNoSuchFile {
      return
    }
  }
}

/// UserDefaults is documented thread-safe, hence the unchecked marker.
struct UserDefaultsDataPersistence: RemovableAppDataPersistence, @unchecked Sendable {
  let defaults: UserDefaults
  let key: String

  init(defaults: UserDefaults = NightdriveDefaults.current, key: String) {
    self.defaults = defaults
    self.key = key
  }

  func load() throws -> Data? {
    defaults.data(forKey: key)
  }

  func save(_ data: Data) throws {
    defaults.set(data, forKey: key)
  }

  func remove() throws {
    defaults.removeObject(forKey: key)
  }
}

extension AppDataPersistence {
  func loadOutcome<Value: Decodable>(_ type: Value.Type) -> AppDataLoadOutcome<Value> {
    let data: Data?
    do {
      data = try load()
    } catch {
      return .unreadable(AppDataLoadFailure(reason: error.localizedDescription))
    }
    guard let data, !data.isEmpty else { return .missing }
    do {
      return .loaded(try JSONDecoder().decode(type, from: data))
    } catch {
      return .malformed(AppDataLoadFailure(reason: error.localizedDescription))
    }
  }

  func load<Value: Decodable>(_ type: Value.Type) throws -> Value? {
    guard let data = try load() else { return nil }
    return try JSONDecoder().decode(type, from: data)
  }

  func save<Value: Encodable>(_ value: Value) throws {
    try save(encodeAppDataJSON(value))
  }
}

enum AppDataLoadOutcome<Value> {
  case missing
  case loaded(Value)
  case malformed(AppDataLoadFailure)
  case unreadable(AppDataLoadFailure)
}

extension AppDataLoadOutcome {
  /// Unwraps a sidecar load outcome, substituting `whenMissing()` for an
  /// absent file and mapping a malformed or unreadable file to a
  /// `SidecarIntegrityError` for the sidecar at `url`.
  func unwrap(
    url: URL, whenMissing: @autoclosure () -> Value,
    malformedRecoveryInstruction: String? = nil
  ) throws -> Value {
    try unwrapIfPresent(url: url, malformedRecoveryInstruction: malformedRecoveryInstruction)
      ?? whenMissing()
  }

  /// Like `unwrap(url:whenMissing:malformedRecoveryInstruction:)`, but a
  /// missing file yields `nil`.
  func unwrapIfPresent(
    url: URL, malformedRecoveryInstruction: String? = nil
  ) throws -> Value? {
    switch self {
    case .missing:
      return nil
    case .loaded(let value):
      return value
    case .malformed(let failure):
      if let malformedRecoveryInstruction {
        throw SidecarIntegrityError(
          url: url, failure: failure, recoveryInstruction: malformedRecoveryInstruction)
      }
      throw SidecarIntegrityError(url: url, failure: failure)
    case .unreadable(let failure):
      throw SidecarIntegrityError(
        url: url, failure: failure,
        recoveryInstruction: SidecarIntegrityError.restoreAccessInstruction)
    }
  }
}

struct AppDataLoadFailure: LocalizedError, Equatable, Sendable {
  let reason: String

  var errorDescription: String? { reason }
}

struct SidecarIntegrityError: LocalizedError, Equatable, Sendable {
  let path: String
  let reason: String
  let recoveryInstruction: String

  static let restoreAccessInstruction = String(
    localized:
      "Restore access to it — check permissions and that its volume is available — then try again.")

  init(
    url: URL, failure: AppDataLoadFailure,
    recoveryInstruction: String = String(
      localized:
        "Repair it (or reset it with Nightdrive's reset-sidecar command) before syncing or saving library data.")
  ) {
    path = url.path
    reason = failure.reason
    self.recoveryInstruction = recoveryInstruction
  }

  var errorDescription: String? {
    String(
      localized:
        "Nightdrive could not read \(path). The file was left unchanged. \(recoveryInstruction) (\(reason))")
  }
}

struct AppDataMutationBlockedError: LocalizedError, Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case corrupt
    case unreadable
  }

  let reason: String
  var kind: Kind = .corrupt

  var errorDescription: String? {
    switch kind {
    case .corrupt:
      return String(
        localized:
          "Saved library data is damaged and was left unchanged. Repair its sidecar (or reset it with Nightdrive's reset-sidecar command) and reload the library before making changes. (\(reason))"
      )
    case .unreadable:
      return String(
        localized:
          "Saved library data could not be read and was left unchanged. Restore access to the library folder — check permissions and that its volume is available — and reload the library before making changes. (\(reason))"
      )
    }
  }
}

struct EmptyDataPersistence: AppDataPersistence {
  func load() throws -> Data? { nil }
  func save(_: Data) throws { throw PersistenceError.libraryNotSelected }

  private enum PersistenceError: LocalizedError {
    case libraryNotSelected

    var errorDescription: String? {
      String(localized: "Choose a library folder before saving library data.")
    }
  }
}

enum SidecarJSONFile {
  static func loadOutcome<Value: Decodable>(
    _ type: Value.Type, at url: URL
  ) -> AppDataLoadOutcome<Value> {
    FileDataPersistence(fileURL: url).loadOutcome(type)
  }

  static func save<Value: Encodable>(_ value: Value, to url: URL) throws {
    try FileDataPersistence(fileURL: url, createsParentDirectories: false).save(value)
  }
}
