import Darwin
import Foundation

/// Serializes device writers against other Nightdrive processes (via an
/// advisory `lockf` on a lock file in the iTunes directory) and against other
/// threads in this process (via a shared static lock).
final class IpodDeviceLock {
  private static let processLock = NSLock()
  private var descriptor: Int32 = -1
  private var holdsProcessLock = false

  static func nano(fileSystem: IpodFileSystem) throws -> IpodDeviceLock {
    try IpodDeviceLock(
      fileSystem: fileSystem, lockName: ".nightdrive-nano.lock", createsDirectory: true)
  }

  static func shuffle(fileSystem: IpodFileSystem) throws -> IpodDeviceLock {
    try IpodDeviceLock(fileSystem: fileSystem, lockName: ".nightdrive-shuffle.lock")
  }

  private init(fileSystem: IpodFileSystem, lockName: String, createsDirectory: Bool = false) throws {
    Self.processLock.lock()
    holdsProcessLock = true
    do {
      if createsDirectory {
        try FileManager.default.createDirectory(
          at: fileSystem.itunesDir, withIntermediateDirectories: true)
      }
      let url = fileSystem.itunesDir.appendingPathComponent(lockName)
      descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, 0o600)
      guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      if descriptor >= 0 { Darwin.close(descriptor) }
      descriptor = -1
      Self.processLock.unlock()
      holdsProcessLock = false
      throw error
    }
  }

  deinit {
    if descriptor >= 0 {
      Darwin.lockf(descriptor, F_ULOCK, 0)
      Darwin.close(descriptor)
    }
    if holdsProcessLock { Self.processLock.unlock() }
  }
}
