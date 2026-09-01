import CryptoKit
import Darwin
import Foundation
import Synchronization

/// The current `errno` as a `POSIXError`, defaulting to EIO.
func posixError() -> POSIXError {
  POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

/// Same-volume workspace for an outbound sync's immutable sources: a sibling
/// of the library, outside the recursive watcher, or an owned hidden child
/// when the library is a volume root. Callers hold the per-library workflow
/// lock, so creating an area can reclaim leftovers from an interrupted run;
/// the process registry covers callers that use `SyncEngine` directly.
final class OutboundSnapshotArea: Sendable {
  static let containerPrefix = ".nightdrive-outbound-snapshots-"

  /// Also serializes workspace preparation and scavenging against concurrent
  /// area creation, so one create cannot sweep another's pre-registration
  /// directory.
  private static let activeDirectories = Mutex<Set<String>>([])

  let directory: URL
  private let activePath: String
  private let removed = Mutex(false)

  static func create(libraryFolder: URL) throws -> OutboundSnapshotArea {
    try activeDirectories.withLock { activeDirectories in
      let root = libraryFolder.resolvingSymlinksInPath().standardizedFileURL
      var rootStatus = stat()
      guard Darwin.lstat(root.path, &rootStatus) == 0,
        rootStatus.st_mode & S_IFMT == S_IFDIR
      else {
        throw ITunesDBError.notFound("Invalid library folder")
      }

      let fm = FileManager.default
      let workspaceRoot = try prepareWorkspaceRoot(
        libraryRoot: root, libraryDevice: rootStatus.st_dev, fileManager: fm)
      try scavenge(in: workspaceRoot, activeDirectories: activeDirectories, fileManager: fm)

      let directory = workspaceRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
      do {
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try Task.checkCancellation()
        let activePath = directory.standardizedFileURL.path
        activeDirectories.insert(activePath)
        return OutboundSnapshotArea(directory: directory, activePath: activePath)
      } catch {
        fm.bestEffortRemoveItem(at: directory)
        throw error
      }
    }
  }

  private init(directory: URL, activePath: String) {
    self.directory = directory
    self.activePath = activePath
  }

  func destination(fileExtension: String) -> URL {
    let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
    return directory.appendingPathComponent(UUID().uuidString + suffix)
  }

  func remove() {
    removed.withLock { removed in
      guard !removed else { return }
      removed = true
      FileManager.default.bestEffortRemoveItem(at: directory)
      Self.activeDirectories.withLock { _ = $0.remove(activePath) }
    }
  }

  deinit { remove() }

  private static func prepareWorkspaceRoot(
    libraryRoot: URL, libraryDevice: dev_t, fileManager fm: FileManager
  ) throws -> URL {
    let scope = ScopedAdvisoryLock.scopeIdentifier(
      for: libraryRoot, namespace: .libraryWorkflow)
    let name = containerPrefix + scope
    let parent = libraryRoot.deletingLastPathComponent()
    if parent.path != libraryRoot.path {
      let preferred = parent.appendingPathComponent(name, isDirectory: true)
      if let prepared = try? prepareOwnedDirectory(
        at: preferred, expectedDevice: libraryDevice, fileManager: fm)
      {
        return prepared
      }
    }
    return try prepareOwnedDirectory(
      at: libraryRoot.appendingPathComponent(name, isDirectory: true),
      expectedDevice: libraryDevice, fileManager: fm)
  }

  private static func prepareOwnedDirectory(
    at url: URL, expectedDevice: dev_t, fileManager fm: FileManager
  ) throws -> URL {
    var created = false
    if Darwin.mkdir(url.path, 0o700) == 0 {
      created = true
    } else if errno != EEXIST {
      throw posixError()
    }

    let descriptor = Darwin.open(
      url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else {
      let openError = errno
      if created { fm.bestEffortRemoveItem(at: url) }
      throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == Darwin.geteuid(),
      status.st_dev == expectedDevice,
      Darwin.fchmod(descriptor, 0o700) == 0
    else {
      if created { fm.bestEffortRemoveItem(at: url) }
      throw ITunesDBError.notFound("Invalid outbound snapshot workspace")
    }
    return url.standardizedFileURL
  }

  private static func scavenge(
    in root: URL, activeDirectories: Set<String>, fileManager fm: FileManager
  ) throws {
    let candidates = try fm.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    for candidate in candidates {
      let name = candidate.lastPathComponent
      guard let identifier = UUID(uuidString: name), identifier.uuidString == name,
        !activeDirectories.contains(candidate.standardizedFileURL.path),
        let values = try? candidate.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]),
        values.isDirectory == true, values.isSymbolicLink != true
      else { continue }

      fm.bestEffortRemoveItem(at: candidate)
    }
  }
}

/// A private, immutable generation of one outbound library file. The source is
/// opened without following a final symlink and cloned from that descriptor
/// where supported; the copy fallback is accepted only when stat identity and
/// independently hashed bytes agree before, during, and after.
final class OutboundSourceSnapshot: Sendable {
  struct StableSignature: Sendable {
    let contentSHA256: String
    let fileSize: Int
    let modificationDate: Date
    let fileGenerationStamp: FileGenerationStamp
  }

  struct FallbackTestSeam: Sendable {
    let forceCopyFallback: Bool
    let ignoreTimestampChanges: Bool
    let afterCopy: @Sendable (Int) throws -> Void

    init(
      forceCopyFallback: Bool = true,
      ignoreTimestampChanges: Bool = false,
      afterCopy: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) {
      self.forceCopyFallback = forceCopyFallback
      self.ignoreTimestampChanges = ignoreTimestampChanges
      self.afterCopy = afterCopy
    }
  }

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let generation: UInt32
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ status: stat) {
      device = status.st_dev
      inode = status.st_ino
      generation = status.st_gen
      size = status.st_size
      modifiedSeconds = status.st_mtimespec.tv_sec
      modifiedNanoseconds = status.st_mtimespec.tv_nsec
      changedSeconds = status.st_ctimespec.tv_sec
      changedNanoseconds = status.st_ctimespec.tv_nsec
    }

    var modificationDate: Date {
      Date(
        timeIntervalSince1970: Double(modifiedSeconds) + Double(modifiedNanoseconds) / 1_000_000_000)
    }

    var fileGenerationStamp: FileGenerationStamp {
      FileGenerationStamp(
        deviceID: UInt64(bitPattern: Int64(device)), inode: UInt64(inode),
        sizeBytes: Int(clamping: size),
        modificationSeconds: modifiedSeconds, modificationNanoseconds: modifiedNanoseconds,
        changeSeconds: changedSeconds, changeNanoseconds: changedNanoseconds,
        generation: generation)
    }

    func representsSameGeneration(
      as other: FileIdentity, ignoringTimestampChanges: Bool
    ) -> Bool {
      guard ignoringTimestampChanges else { return self == other }
      return device == other.device && inode == other.inode
        && generation == other.generation && size == other.size
    }
  }

  private struct CaptureResult {
    let identity: FileIdentity
    let contentSHA256: String?
  }

  let originalURL: URL
  let url: URL
  let fileSize: Int
  let modificationDate: Date
  let modificationSeconds: Int
  let modificationNanoseconds: Int
  let fileGenerationStamp: FileGenerationStamp
  let contentSHA256: String

  private let removed = Mutex(false)

  static func stableSignature(
    of validatedSource: URL, in libraryFolder: URL
  ) throws -> StableSignature {
    // Hash one open descriptor to avoid path and symlink races.
    let descriptor = try openContainedSource(validatedSource, in: libraryFolder)
    defer { Darwin.close(descriptor) }

    for _ in 0..<3 {
      var before = stat()
      guard Darwin.fstat(descriptor, &before) == 0 else { throw posixError() }
      guard before.st_mode & S_IFMT == S_IFREG else {
        throw ITunesDBError.notFound("Track file is missing")
      }
      let hash = try sha256(descriptor: descriptor)
      var after = stat()
      guard Darwin.fstat(descriptor, &after) == 0 else { throw posixError() }
      let identity = FileIdentity(after)
      if FileIdentity(before) == identity {
        return StableSignature(
          contentSHA256: hash,
          fileSize: Int(clamping: identity.size),
          modificationDate: identity.modificationDate,
          fileGenerationStamp: identity.fileGenerationStamp)
      }
    }
    throw CocoaError(.fileReadUnknown)
  }

  static func create(
    from validatedSource: URL, in libraryFolder: URL, area: OutboundSnapshotArea,
    fallbackTestSeam: FallbackTestSeam? = nil
  ) throws -> OutboundSourceSnapshot {
    let fm = FileManager.default
    let destination = area.destination(fileExtension: validatedSource.pathExtension)
    do {
      let captured = try capture(
        source: validatedSource, libraryFolder: libraryFolder,
        destinationDirectory: area.directory,
        destinationName: destination.lastPathComponent, destination: destination,
        fallbackTestSeam: fallbackTestSeam)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      let hash = try captured.contentSHA256 ?? SyncSignature.fileSHA256(url: destination)
      let identity = captured.identity
      return OutboundSourceSnapshot(
        originalURL: validatedSource, url: destination,
        fileSize: Int(clamping: identity.size), modificationDate: identity.modificationDate,
        modificationSeconds: identity.modifiedSeconds,
        modificationNanoseconds: identity.modifiedNanoseconds,
        fileGenerationStamp: identity.fileGenerationStamp,
        contentSHA256: hash)
    } catch {
      fm.bestEffortRemoveItem(at: destination)
      throw error
    }
  }

  private static func capture(
    source: URL, libraryFolder: URL, destinationDirectory: URL,
    destinationName: String, destination: URL,
    fallbackTestSeam: FallbackTestSeam?
  ) throws -> CaptureResult {
    let sourceDescriptor = try openContainedSource(source, in: libraryFolder)
    defer { Darwin.close(sourceDescriptor) }

    var sourceStatus = stat()
    guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0 else { throw posixError() }
    guard sourceStatus.st_mode & S_IFMT == S_IFREG else {
      throw ITunesDBError.notFound("Track file is missing")
    }

    let directoryDescriptor = Darwin.open(
      destinationDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryDescriptor >= 0 else { throw posixError() }
    defer { Darwin.close(directoryDescriptor) }

    if fallbackTestSeam?.forceCopyFallback != true,
      Darwin.fclonefileat(sourceDescriptor, directoryDescriptor, destinationName, 0) == 0
    {
      var afterClone = stat()
      if Darwin.fstat(sourceDescriptor, &afterClone) == 0,
        FileIdentity(sourceStatus) == FileIdentity(afterClone)
      {
        return CaptureResult(identity: FileIdentity(afterClone), contentSHA256: nil)
      }
    }
    FileManager.default.bestEffortRemoveItem(at: destination)

    for attempt in 0..<3 {
      var before = stat()
      guard Darwin.fstat(sourceDescriptor, &before) == 0 else { throw posixError() }
      guard before.st_mode & S_IFMT == S_IFREG else {
        throw ITunesDBError.notFound("Track file is missing")
      }
      let beforeIdentity = FileIdentity(before)
      let sourceHashBefore = try sha256(descriptor: sourceDescriptor)

      var beforeCopy = stat()
      guard Darwin.fstat(sourceDescriptor, &beforeCopy) == 0 else { throw posixError() }
      guard
        identitiesMatch(
          beforeIdentity, FileIdentity(beforeCopy), fallbackTestSeam: fallbackTestSeam)
      else { continue }
      guard Darwin.lseek(sourceDescriptor, 0, SEEK_SET) == 0 else { throw posixError() }

      let destinationDescriptor = Darwin.open(
        destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard destinationDescriptor >= 0 else { throw posixError() }
      let copied = Darwin.fcopyfile(
        sourceDescriptor, destinationDescriptor, nil, copyfile_flags_t(COPYFILE_DATA))
      let copyError = errno
      Darwin.close(destinationDescriptor)
      guard copied == 0 else {
        FileManager.default.bestEffortRemoveItem(at: destination)
        throw POSIXError(POSIXErrorCode(rawValue: copyError) ?? .EIO)
      }

      try fallbackTestSeam?.afterCopy(attempt)
      var afterCopy = stat()
      guard Darwin.fstat(sourceDescriptor, &afterCopy) == 0 else { throw posixError() }
      let destinationIdentity = try identity(of: destination)
      let destinationHash = try SyncSignature.fileSHA256(url: destination)
      let sourceHashAfter = try sha256(descriptor: sourceDescriptor)
      var afterValidation = stat()
      guard Darwin.fstat(sourceDescriptor, &afterValidation) == 0 else { throw posixError() }
      let finalIdentity = FileIdentity(afterValidation)

      if identitiesMatch(
        beforeIdentity, FileIdentity(afterCopy), fallbackTestSeam: fallbackTestSeam),
        identitiesMatch(
          beforeIdentity, finalIdentity, fallbackTestSeam: fallbackTestSeam),
        destinationIdentity.size == finalIdentity.size,
        sourceHashBefore == destinationHash,
        destinationHash == sourceHashAfter
      {
        return CaptureResult(identity: finalIdentity, contentSHA256: destinationHash)
      }
      FileManager.default.bestEffortRemoveItem(at: destination)
    }
    throw CocoaError(.fileReadUnknown)
  }

  private static func identitiesMatch(
    _ lhs: FileIdentity, _ rhs: FileIdentity,
    fallbackTestSeam: FallbackTestSeam?
  ) -> Bool {
    lhs.representsSameGeneration(
      as: rhs, ignoringTimestampChanges: fallbackTestSeam?.ignoreTimestampChanges == true)
  }

  private static func openContainedSource(_ source: URL, in libraryFolder: URL) throws -> Int32 {
    let root = libraryFolder.resolvingSymlinksInPath().standardizedFileURL
    let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
    guard
      let remainder = PathContainment.relativePath(
        of: canonicalSource.path, inside: root.path)
    else {
      throw ITunesDBError.notFound("Track is outside the library folder")
    }
    let components = remainder.split(separator: "/")
    guard !components.isEmpty,
      components.allSatisfy({ $0 != "." && $0 != ".." })
    else {
      throw ITunesDBError.notFound("Invalid track path")
    }

    var directoryDescriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryDescriptor >= 0 else { throw posixError() }
    for component in components.dropLast() {
      let next = Darwin.openat(
        directoryDescriptor, String(component),
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      if next < 0 {
        let error = posixError()
        Darwin.close(directoryDescriptor)
        throw error
      }
      Darwin.close(directoryDescriptor)
      directoryDescriptor = next
    }
    let descriptor = Darwin.openat(
      directoryDescriptor, String(components.last!), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    let openError = errno
    Darwin.close(directoryDescriptor)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
    }
    return descriptor
  }

  private static func sha256(descriptor: Int32) throws -> String {
    guard Darwin.lseek(descriptor, 0, SEEK_SET) == 0 else { throw posixError() }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1_048_576)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError()
      }
      if count == 0 { break }
      hasher.update(data: Data(buffer.prefix(count)))
    }
    return hasher.finalize().hexString
  }

  private static func identity(of url: URL) throws -> FileIdentity {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else { throw posixError() }
    guard status.st_mode & S_IFMT == S_IFREG else {
      throw ITunesDBError.notFound("Outbound snapshot is not a regular file")
    }
    return FileIdentity(status)
  }

  private init(
    originalURL: URL, url: URL, fileSize: Int,
    modificationDate: Date, modificationSeconds: Int,
    modificationNanoseconds: Int, fileGenerationStamp: FileGenerationStamp,
    contentSHA256: String
  ) {
    self.originalURL = originalURL
    self.url = url
    self.fileSize = fileSize
    self.modificationDate = modificationDate
    self.modificationSeconds = modificationSeconds
    self.modificationNanoseconds = modificationNanoseconds
    self.fileGenerationStamp = fileGenerationStamp
    self.contentSHA256 = contentSHA256
  }

  func remove() {
    removed.withLock { removed in
      guard !removed else { return }
      removed = true
      FileManager.default.bestEffortRemoveItem(at: url)
    }
  }

  deinit { remove() }
}
