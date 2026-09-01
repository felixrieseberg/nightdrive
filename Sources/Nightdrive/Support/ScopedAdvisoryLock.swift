import CryptoKit
import Darwin
import Foundation
import Synchronization

/// Process- and app-wide advisory lock over one filesystem mutation scope.
/// POSIX record locks are process-owned, so the in-process scope set is also
/// needed to keep sibling tasks out of the same critical section.
final class ScopedAdvisoryLock: Sendable {
  enum Namespace: Sendable {
    case device
    case library
    case libraryWorkflow
    case transcodeCache
    case transcodeKey

    fileprivate var directoryName: String {
      switch self {
      case .device: "DeviceLocks"
      case .library, .libraryWorkflow: "SyncLocks"
      case .transcodeCache, .transcodeKey: "TranscodeLocks"
      }
    }

    fileprivate var filePrefix: String {
      switch self {
      case .device, .library: ""
      case .libraryWorkflow: "workflow-"
      case .transcodeCache: "cache-"
      case .transcodeKey: "key-"
      }
    }

    fileprivate var scopeLength: Int {
      switch self {
      case .device, .transcodeCache, .transcodeKey: 16
      case .library, .libraryWorkflow: 12
      }
    }
  }

  private static let retryDelay = Duration.milliseconds(10)
  /// Held only for a set lookup or mutation; contended waiters suspend with
  /// `Task.sleep`, so no cooperative-executor thread blocks here.
  private static let activeScopes = Mutex<Set<String>>([])

  private struct Resources {
    var descriptor: Int32 = -1
    var holdsProcessScope = false
  }

  private let processScope: String
  private let lockFileURL: URL
  private let resources = Mutex(Resources())

  static func acquire(for url: URL, namespace: Namespace) async throws -> ScopedAdvisoryLock {
    let lock = ScopedAdvisoryLock(url: url, namespace: namespace)
    try await lock.acquireResources()
    return lock
  }

  static func scopeIdentifier(for url: URL, namespace: Namespace) -> String {
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    return SHA256.hash(data: Data(path.utf8)).prefix(namespace.scopeLength).hexString
  }

  static func lockFileURL(for url: URL, namespace: Namespace) -> URL {
    let fm = FileManager.default
    let directory =
      (fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
      .appendingPathComponent("Nightdrive/\(namespace.directoryName)", isDirectory: true)
    return directory.appendingPathComponent(
      "\(namespace.filePrefix)\(scopeIdentifier(for: url, namespace: namespace)).lock")
  }

  private init(url: URL, namespace: Namespace) {
    let scope = Self.scopeIdentifier(for: url, namespace: namespace)
    processScope = "\(namespace.directoryName)/\(namespace.filePrefix)\(scope)"
    lockFileURL = Self.lockFileURL(for: url, namespace: namespace)
  }

  private func acquireResources() async throws {
    var pendingDescriptor: Int32 = -1
    var pendingDescriptorHoldsLock = false
    do {
      try await acquireProcessScope()
      try FileManager.default.createDirectory(
        at: lockFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      pendingDescriptor = Darwin.open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
      guard pendingDescriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try await Self.acquireFileLock(pendingDescriptor)
      pendingDescriptorHoldsLock = true

      resources.withLock {
        $0.descriptor = pendingDescriptor
        pendingDescriptor = -1
      }
      try Task.checkCancellation()
    } catch {
      if pendingDescriptor >= 0 {
        if pendingDescriptorHoldsLock {
          Darwin.lockf(pendingDescriptor, F_ULOCK, 0)
        }
        Darwin.close(pendingDescriptor)
      }
      unlock()
      throw error
    }
  }

  func unlock() {
    let released = resources.withLock { resources in
      defer { resources = Resources() }
      return resources
    }

    if released.descriptor >= 0 {
      Darwin.lockf(released.descriptor, F_ULOCK, 0)
      Darwin.close(released.descriptor)
    }
    if released.holdsProcessScope { Self.releaseProcessScope(processScope) }
  }

  deinit { unlock() }

  private func acquireProcessScope() async throws {
    while true {
      try Task.checkCancellation()
      if Self.tryAcquireProcessScope(processScope) {
        resources.withLock { $0.holdsProcessScope = true }
        try Task.checkCancellation()
        return
      }
      try await Task.sleep(for: Self.retryDelay)
    }
  }

  private static func acquireFileLock(_ descriptor: Int32) async throws {
    while true {
      try Task.checkCancellation()
      if Darwin.lockf(descriptor, F_TLOCK, 0) == 0 {
        return
      }
      let lockError = errno
      guard lockError == EACCES || lockError == EAGAIN else {
        throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
      }
      try await Task.sleep(for: retryDelay)
    }
  }

  private static func tryAcquireProcessScope(_ scope: String) -> Bool {
    activeScopes.withLock { $0.insert(scope).inserted }
  }

  private static func releaseProcessScope(_ scope: String) {
    activeScopes.withLock { _ = $0.remove(scope) }
  }
}
