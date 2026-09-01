import Darwin
import Foundation

struct LibraryResourceIdentity: Codable, Equatable, Sendable {
  let volumeID: UInt64
  let resourceID: UInt64
}

struct LibraryFolderIdentity: Equatable, Sendable {
  let url: URL
  let volumeID: UInt64
  let resourceID: UInt64

  static func resolve(_ selectedURL: URL) throws -> LibraryFolderIdentity {
    let selected = selectedURL.standardizedFileURL
    let resolved = selected.resolvingSymlinksInPath().standardizedFileURL
    guard let resource = resource(at: resolved), resource.isDirectory else {
      throw LibraryStoreError.invalidLibraryFolder(selected.path)
    }
    return LibraryFolderIdentity(
      url: URL(fileURLWithPath: resolved.path, isDirectory: true).standardizedFileURL,
      volumeID: resource.volumeID,
      resourceID: resource.resourceID)
  }

  func referencesSameResource(as other: LibraryFolderIdentity) -> Bool {
    volumeID == other.volumeID && resourceID == other.resourceID
  }

  func stillReferencesSelectedResource() -> Bool {
    guard let resource = Self.resource(at: url), resource.isDirectory else { return false }
    return volumeID == resource.volumeID && resourceID == resource.resourceID
  }

  var resourceIdentity: LibraryResourceIdentity {
    LibraryResourceIdentity(volumeID: volumeID, resourceID: resourceID)
  }

  private static func resource(at url: URL) -> (
    volumeID: UInt64, resourceID: UInt64, isDirectory: Bool
  )? {
    var status = stat()
    let result = url.path.withCString { lstat($0, &status) }
    guard result == 0 else { return nil }
    return (
      volumeID: UInt64(truncatingIfNeeded: status.st_dev),
      resourceID: UInt64(status.st_ino),
      isDirectory: status.st_mode & S_IFMT == S_IFDIR
    )
  }
}
