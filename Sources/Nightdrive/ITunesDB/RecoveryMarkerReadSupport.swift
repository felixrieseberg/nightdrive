import Darwin
import Foundation
import OSLog

struct RecoveryMarkerMetadataError: Error {
  let underlying: ITunesDBError

  init(_ underlying: ITunesDBError) {
    self.underlying = underlying
  }
}

/// Owns the recovery policy shared by database writers that use a fixed
/// transaction marker. The writer-specific closure still validates and
/// restores its database generation; this coordinator keeps locking, strict
/// error propagation, and read-time quarantine behavior identical.
struct RecoveryMarkerCoordinator {
  let marker: URL
  let quarantinedMarkerPrefix: String
  let recoveryName: String

  func recoverStrictly<Lock, Result>(
    acquiringLock: () throws -> Lock,
    recovery: () throws -> Result
  ) throws -> Result {
    let lock = try acquiringLock()
    return try withExtendedLifetime(lock) {
      try rejectQuarantinedMarkers()
      return try runStrictly(recovery)
    }
  }

  func runStrictly<Result>(_ recovery: () throws -> Result) throws -> Result {
    do {
      return try recovery()
    } catch let error as RecoveryMarkerMetadataError {
      throw error.underlying
    }
  }

  func recoverForRead<Lock>(
    acquiringLock: () throws -> Lock,
    recovery: () throws -> Void
  ) throws {
    guard FileManager.default.fileExists(atPath: marker.path) else { return }
    let lock: Lock
    do {
      lock = try acquiringLock()
    } catch  where RecoveryMarkerReadSupport.isReadOnlyAccessError(error) {
      RecoveryMarkerReadSupport.report(
        "Could not acquire the \(recoveryName) recovery lock on a read-only device: \(error)")
      return
    }
    try withExtendedLifetime(lock) {
      do {
        try recovery()
      } catch let error as RecoveryMarkerMetadataError {
        do {
          let quarantined = try RecoveryMarkerReadSupport.quarantineFixedMarker(
            marker, prefix: quarantinedMarkerPrefix)
          RecoveryMarkerReadSupport.report(
            "Quarantined unreadable \(recoveryName) recovery marker as "
              + "\(quarantined.lastPathComponent): \(error.underlying.localizedDescription)")
        } catch  where RecoveryMarkerReadSupport.isReadOnlyAccessError(error) {
          RecoveryMarkerReadSupport.report(
            "Could not quarantine \(recoveryName) recovery metadata on a read-only device: \(error)")
        }
      }
    }
  }

  func rejectQuarantinedMarkers() throws {
    try RecoveryMarkerReadSupport.rejectQuarantinedMarkers(
      in: marker.deletingLastPathComponent(), prefix: quarantinedMarkerPrefix,
      failure:
        "A quarantined \(recoveryName) database recovery marker must be resolved before writing")
  }

  var hasPendingTransaction: Bool {
    FileManager.default.fileExists(atPath: marker.path)
      || RecoveryMarkerReadSupport.hasQuarantinedMarkers(
        in: marker.deletingLastPathComponent(), prefix: quarantinedMarkerPrefix)
  }
}

enum RecoveryMarkerReadSupport {
  private static let logger = Logger(
    subsystem: "dev.nightdrive.Nightdrive", category: "DatabaseRecovery")

  static func quarantineFixedMarker(_ marker: URL, prefix: String) throws -> URL {
    let directory = marker.deletingLastPathComponent()
    for _ in 0..<8 {
      let destination = directory.appendingPathComponent(prefix + UUID().uuidString + ".plist")
      if Darwin.renamex_np(marker.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
        try DurableIO.synchronize(at: directory)
        return destination
      }
      let code = errno
      if code == EEXIST { continue }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    throw POSIXError(.EEXIST)
  }

  static func readFixedMarker(
    _ marker: URL, maximumBytes: Int, invalidFailure: String, oversizedFailure: String
  ) throws -> Data {
    let descriptor = Darwin.open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        throw RecoveryMarkerMetadataError(.badHeader(invalidFailure))
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw RecoveryMarkerMetadataError(.badHeader(invalidFailure))
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: min(4_096, maximumBytes + 1))
    while data.count <= maximumBytes {
      let remaining = maximumBytes + 1 - data.count
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, remaining))
      }
      if count == 0 { return data }
      if count < 0 {
        let code = errno
        if code == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    throw RecoveryMarkerMetadataError(.badHeader(oversizedFailure))
  }

  static func readBoundedJournal(
    at url: URL, maximumBytes: Int, oversizedFailure: String
  ) throws -> Data {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= maximumBytes {
      let remaining = maximumBytes + 1 - data.count
      let chunk = try handle.read(upToCount: min(4_096, remaining)) ?? Data()
      if chunk.isEmpty { return data }
      data.append(chunk)
    }
    throw ITunesDBError.badHeader(oversizedFailure)
  }

  static func rejectQuarantinedMarkers(
    in directory: URL, prefix: String, failure: String
  ) throws {
    guard try !quarantinedMarkers(in: directory, prefix: prefix).isEmpty else { return }
    throw ITunesDBError.badHeader(failure)
  }

  static func hasQuarantinedMarkers(in directory: URL, prefix: String) -> Bool {
    (try? !quarantinedMarkers(in: directory, prefix: prefix).isEmpty) == true
  }

  static func isReadOnlyAccessError(_ error: Error) -> Bool {
    if let error = error as? POSIXError {
      return error.code == .EROFS || error.code == .EACCES || error.code == .EPERM
    }
    let error = error as NSError
    if error.domain == NSPOSIXErrorDomain {
      return error.code == Int(EROFS) || error.code == Int(EACCES) || error.code == Int(EPERM)
    }
    guard error.domain == NSCocoaErrorDomain else { return false }
    let code = CocoaError.Code(rawValue: error.code)
    return code == .fileWriteVolumeReadOnly || code == .fileWriteNoPermission
      || code == .fileReadNoPermission
  }

  static func report(_ message: String) {
    logger.warning("\(message, privacy: .public)")
  }

  private static func quarantinedMarkers(in directory: URL, prefix: String) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).filter { url in
      let name = url.lastPathComponent
      return name.hasPrefix(prefix) && name.hasSuffix(".plist")
    }
  }
}
