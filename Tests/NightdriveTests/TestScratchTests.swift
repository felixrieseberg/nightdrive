import Foundation
import Testing

@testable import Nightdrive

struct TestScratchTests {
  @Test
  func testDirectoryDefaultsToTemporaryDirectory() {
    let temporaryDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)

    let directory = TestScratch.directory(
      prefix: "Fixture", temporaryDirectory: temporaryDirectory)

    #expect(directory.deletingLastPathComponent() == temporaryDirectory)
    #expect(directory.lastPathComponent.hasPrefix("Fixture-"))
  }

  @Test
  func testCanonicalFileURLResolvesAliasesForMissingDescendants() {
    let missing = URL(fileURLWithPath: "/var/tmp/NightdriveTests-missing/child")

    #expect(missing.canonicalFileURL.path == "/private/var/tmp/NightdriveTests-missing/child")
  }
}
