import Darwin
import Foundation

enum LibraryRootUnavailableReason: Equatable, Sendable {
  case missing
  case notDirectory
  case unreadable
  case replaced
}

enum LibraryRootAvailability: Equatable, Sendable {
  case notConfigured
  case checking
  case available
  case unavailable(LibraryRootUnavailableReason)
}

struct LibraryRootIdentity: Equatable, Sendable {
  let device: UInt64
  let inode: UInt64
  let fileType: UInt16
}

struct LibraryRootToken: Equatable, Sendable {
  let url: URL
  let identity: LibraryRootIdentity
}

struct LibraryRootPreflightError: LocalizedError, Equatable, Sendable {
  let reason: LibraryRootUnavailableReason

  var errorDescription: String? {
    switch reason {
    case .missing:
      String(
        localized:
          "The music library folder is unavailable. Reconnect or restore it, then rescan.")
    case .notDirectory:
      String(
        localized:
          "The selected music library path is no longer a folder. Restore it, then rescan.")
    case .unreadable:
      String(localized: "The music library folder cannot be read. Restore access, then rescan.")
    case .replaced:
      String(
        localized: "The music library folder was replaced. Choose it again to use the replacement.")
    }
  }
}

typealias LibraryRootInspector = @Sendable (URL) -> Result<LibraryRootToken, LibraryRootPreflightError>

enum LibraryRootPreflight {
  static let liveInspector: LibraryRootInspector = { inspect($0) }

  static func inspect(_ url: URL) -> Result<LibraryRootToken, LibraryRootPreflightError> {
    let root = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
      return .failure(LibraryRootPreflightError(reason: .missing))
    }
    guard isDirectory.boolValue else {
      return .failure(LibraryRootPreflightError(reason: .notDirectory))
    }
    guard Darwin.access(root.path, R_OK | X_OK) == 0 else {
      return .failure(LibraryRootPreflightError(reason: .unreadable))
    }

    var status = stat()
    guard Darwin.lstat(root.path, &status) == 0 else {
      return .failure(LibraryRootPreflightError(reason: .missing))
    }
    return .success(
      LibraryRootToken(
        url: root,
        identity: LibraryRootIdentity(
          device: UInt64(bitPattern: Int64(status.st_dev)),
          inode: UInt64(status.st_ino),
          fileType: UInt16(status.st_mode & S_IFMT))))
  }

  static func validate(
    _ token: LibraryRootToken,
    using inspector: LibraryRootInspector = liveInspector
  ) -> Result<LibraryRootToken, LibraryRootPreflightError> {
    switch inspector(token.url) {
    case .success(let current) where current.identity == token.identity:
      return .success(current)
    case .success:
      return .failure(LibraryRootPreflightError(reason: .replaced))
    case .failure(let error):
      return .failure(error)
    }
  }

  static func createDirectoryHierarchy(
    at directory: URL,
    in token: LibraryRootToken,
    fileManager: FileManager = .default
  ) throws {
    _ = try validate(token).get()
    let rootComponents = token.url.standardizedFileURL.pathComponents
    let directoryComponents = directory.standardizedFileURL.pathComponents
    guard directoryComponents.count >= rootComponents.count,
      directoryComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    else {
      throw LibraryRootPreflightError(reason: .replaced)
    }

    var current = token.url
    for component in directoryComponents.dropFirst(rootComponents.count) {
      _ = try validate(token).get()
      current.appendPathComponent(component, isDirectory: true)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
          throw CocoaError(.fileWriteFileExists)
        }
      } else {
        try fileManager.createDirectory(at: current, withIntermediateDirectories: false)
      }
    }
  }
}
