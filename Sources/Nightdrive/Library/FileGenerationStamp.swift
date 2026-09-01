import Darwin
import Foundation

struct FileGenerationStamp: Codable, Equatable, Hashable, Sendable {
  let deviceID: UInt64
  let inode: UInt64
  let sizeBytes: Int
  let modificationSeconds: Int
  let modificationNanoseconds: Int
  let changeSeconds: Int
  let changeNanoseconds: Int
  let generation: UInt32?

  init(
    deviceID: UInt64, inode: UInt64, sizeBytes: Int,
    modificationSeconds: Int, modificationNanoseconds: Int,
    changeSeconds: Int, changeNanoseconds: Int, generation: UInt32?
  ) {
    self.deviceID = deviceID
    self.inode = inode
    self.sizeBytes = sizeBytes
    self.modificationSeconds = modificationSeconds
    self.modificationNanoseconds = modificationNanoseconds
    self.changeSeconds = changeSeconds
    self.changeNanoseconds = changeNanoseconds
    self.generation = generation.flatMap { $0 == 0 ? nil : $0 }
  }

  init(_ status: stat) {
    self.init(
      deviceID: UInt64(bitPattern: Int64(status.st_dev)), inode: UInt64(status.st_ino),
      sizeBytes: Int(clamping: status.st_size),
      modificationSeconds: status.st_mtimespec.tv_sec,
      modificationNanoseconds: status.st_mtimespec.tv_nsec,
      changeSeconds: status.st_ctimespec.tv_sec,
      changeNanoseconds: status.st_ctimespec.tv_nsec,
      generation: status.st_gen)
  }

  init?(url: URL) {
    let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
    var status = stat()
    guard Darwin.lstat(canonicalURL.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFREG
    else { return nil }
    self.init(status)
  }

  func matchesStableIdentity(_ other: FileGenerationStamp) -> Bool {
    inode == other.inode && sizeBytes == other.sizeBytes
      && modificationSeconds == other.modificationSeconds
      && modificationNanoseconds == other.modificationNanoseconds
      && changeSeconds == other.changeSeconds
      && changeNanoseconds == other.changeNanoseconds
      && generation == other.generation
  }

  var modificationDate: Date {
    Date(
      timeIntervalSince1970:
        Double(modificationSeconds) + Double(modificationNanoseconds) / 1_000_000_000)
  }

  var cacheKey: String {
    [
      String(deviceID), String(inode), String(sizeBytes),
      String(modificationSeconds), String(modificationNanoseconds),
      String(changeSeconds), String(changeNanoseconds),
      generation.map(String.init) ?? "-",
    ].joined(separator: "|")
  }
}
