import Foundation
import Testing

@testable import Nightdrive

struct AtomicFileRewriterTests {
  private enum TestError: Error, Equatable {
    case changed
    case injected
  }

  @Test
  func testRewritesSelectedBytesAndPreservesPermissions() throws {
    let directory = try makeScratchDirectory()
    defer { FileManager.default.bestEffortRemoveItem(at: directory) }
    let url = directory.appendingPathComponent("track.mp3")
    let original = Data((0..<1_100_000).map { UInt8($0 % 251) })
    try original.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
    let generation = try #require(FileGenerationStamp(url: url))

    try AtomicFileRewriter.rewrite(
      contentsOf: url, expectedGeneration: generation,
      fileChangedError: TestError.changed
    ) { input, output in
      try AtomicFileRewriter.copy(
        byteCount: 23, from: input, to: output,
        unexpectedEndOfFileError: TestError.injected)
      try output.write(contentsOf: Data("replacement".utf8))
      try input.seek(toOffset: 41)
      try AtomicFileRewriter.copyRemaining(from: input, to: output)
    }

    var expected = original.prefix(23)
    expected.append(contentsOf: Data("replacement".utf8))
    expected.append(contentsOf: original.suffix(from: 41))
    #expect(try Data(contentsOf: url) == Data(expected))
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
  }

  @Test
  func testFailureLeavesOriginalInPlaceAndRemovesTemporaryFile() throws {
    let directory = try makeScratchDirectory()
    defer { FileManager.default.bestEffortRemoveItem(at: directory) }
    let url = directory.appendingPathComponent("track.m4a")
    let original = Data("original".utf8)
    try original.write(to: url)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try AtomicFileRewriter.rewrite(
          contentsOf: url, fileChangedError: TestError.changed
        ) { _, output in
          try output.write(contentsOf: Data("partial".utf8))
          throw TestError.injected
        }
      }
      if let caughtError {
        #expect(caughtError as? TestError == .injected)
      }
    }

    #expect(try Data(contentsOf: url) == original)
    #expect(try temporaryFiles(in: directory) == [])
  }

  @Test
  func testGenerationMismatchLeavesExternalChangeInPlace() throws {
    let directory = try makeScratchDirectory()
    defer { FileManager.default.bestEffortRemoveItem(at: directory) }
    let url = directory.appendingPathComponent("track.mp3")
    try Data("original".utf8).write(to: url)
    let generation = try #require(FileGenerationStamp(url: url))
    let externalChange = Data("changed externally".utf8)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try AtomicFileRewriter.rewrite(
          contentsOf: url, expectedGeneration: generation,
          fileChangedError: TestError.changed
        ) { input, output in
          try AtomicFileRewriter.copyRemaining(from: input, to: output)
          try externalChange.write(to: url)
        }
      }
      if let caughtError {
        #expect(caughtError as? TestError == .changed)
      }
    }

    #expect(try Data(contentsOf: url) == externalChange)
    #expect(try temporaryFiles(in: directory) == [])
  }

  private func temporaryFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.contains(".nightdrive-") }
  }

  private func makeScratchDirectory() throws -> URL {
    let directory = TestScratch.directory(prefix: "AtomicFileRewriterTests")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}
