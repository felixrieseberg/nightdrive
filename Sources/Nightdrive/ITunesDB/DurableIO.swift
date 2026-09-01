import CryptoKit
import Darwin
import Foundation

enum DurableIO {
  static func synchronize(descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  static func synchronize(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    try synchronize(descriptor: descriptor)
  }

  static func synchronizeWithBarrier(at url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    let fullSyncError = errno
    guard fullSyncError == ENOTSUP || fullSyncError == EINVAL else {
      throw POSIXError(POSIXErrorCode(rawValue: fullSyncError) ?? .EIO)
    }
    guard Darwin.fsync(descriptor) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  static func write(_ data: Data, to url: URL, barrier: Bool = false) throws {
    try data.write(to: url, options: .atomic)
    try synchronizeFileAndParent(at: url, barrier: barrier)
  }

  static func synchronizeFileAndParent(at url: URL, barrier: Bool = false) throws {
    try barrier ? synchronizeWithBarrier(at: url) : synchronize(at: url)
    try synchronize(at: url.deletingLastPathComponent())
  }

  static func sha256(of url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
  }
}
