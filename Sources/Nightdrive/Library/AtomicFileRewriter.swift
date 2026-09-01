import Foundation

enum AtomicFileRewriter {
  private static let copyChunkSize = 1_048_576

  static func rewrite(
    contentsOf url: URL,
    expectedGeneration: FileGenerationStamp? = nil,
    fileChangedError: @autoclosure () -> any Error,
    write: (FileHandle, FileHandle) throws -> Void
  ) throws {
    let fileManager = FileManager.default
    let temporary = url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).nightdrive-\(UUID().uuidString)")
    guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }

    do {
      try withFileHandles(inputURL: url, outputURL: temporary, write: write)
      preservePermissions(from: url, to: temporary, fileManager: fileManager)
      if let expectedGeneration {
        guard let liveGeneration = FileGenerationStamp(url: url),
          expectedGeneration.matchesStableIdentity(liveGeneration)
        else { throw fileChangedError() }
      }
      _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
    } catch {
      fileManager.bestEffortRemoveItem(at: temporary)
      throw error
    }
  }

  static func copyRemaining(from input: FileHandle, to output: FileHandle) throws {
    while let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty {
      try output.write(contentsOf: chunk)
    }
  }

  static func copy(
    byteCount: Int, from input: FileHandle, to output: FileHandle,
    unexpectedEndOfFileError: @autoclosure () -> any Error
  ) throws {
    var remaining = byteCount
    while remaining > 0 {
      guard let chunk = try input.read(upToCount: min(remaining, copyChunkSize)),
        !chunk.isEmpty
      else { throw unexpectedEndOfFileError() }
      try output.write(contentsOf: chunk)
      remaining -= chunk.count
    }
  }

  private static func withFileHandles(
    inputURL: URL, outputURL: URL,
    write: (FileHandle, FileHandle) throws -> Void
  ) throws {
    var input: FileHandle?
    var output: FileHandle?
    do {
      let inputHandle = try FileHandle(forReadingFrom: inputURL)
      input = inputHandle
      let outputHandle = try FileHandle(forWritingTo: outputURL)
      output = outputHandle
      try write(inputHandle, outputHandle)
      try outputHandle.synchronize()
      try inputHandle.close()
      try outputHandle.close()
    } catch {
      try? input?.close()
      try? output?.close()
      throw error
    }
  }

  private static func preservePermissions(
    from source: URL, to destination: URL, fileManager: FileManager
  ) {
    guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
      let permissions = attributes[.posixPermissions]
    else { return }
    try? fileManager.setAttributes(
      [.posixPermissions: permissions], ofItemAtPath: destination.path)
  }
}
