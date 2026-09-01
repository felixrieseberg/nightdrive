import Foundation
import Testing

@testable import Nightdrive

struct PathContainmentTests {
  @Test
  func testSiblingWithSharedPrefixIsNotContained() {
    #expect(!PathContainment.path("/Volumes/iPod2", isInside: "/Volumes/iPod", allowRoot: true))
    #expect(
      !PathContainment.path(
        "/Volumes/iPod2/iPod_Control", isInside: "/Volumes/iPod", allowRoot: true))
    #expect(PathContainment.relativePath(of: "/Volumes/iPod2/a.mp3", inside: "/Volumes/iPod") == nil)
  }

  @Test
  func testChildAndDescendantAreContained() {
    #expect(PathContainment.path("/Volumes/iPod/a", isInside: "/Volumes/iPod", allowRoot: false))
    #expect(
      PathContainment.path("/Volumes/iPod/a/b/c.mp3", isInside: "/Volumes/iPod", allowRoot: false))
  }

  @Test
  func testRootItselfRespectsAllowRoot() {
    #expect(PathContainment.path("/Volumes/iPod", isInside: "/Volumes/iPod", allowRoot: true))
    #expect(!PathContainment.path("/Volumes/iPod", isInside: "/Volumes/iPod", allowRoot: false))
    #expect(PathContainment.relativePath(of: "/Volumes/iPod", inside: "/Volumes/iPod") == nil)
  }

  @Test
  func testParentAndUnrelatedPathsAreNotContained() {
    #expect(!PathContainment.path("/Volumes", isInside: "/Volumes/iPod", allowRoot: true))
    #expect(!PathContainment.path("/Users/me/a.mp3", isInside: "/Volumes/iPod", allowRoot: true))
    #expect(!PathContainment.path("", isInside: "/Volumes/iPod", allowRoot: true))
  }

  @Test
  func testRelativePathReturnsRemainder() {
    #expect(
      PathContainment.relativePath(of: "/Library/a/b.mp3", inside: "/Library") == "a/b.mp3")
    #expect(PathContainment.relativePath(of: "/Library/b.mp3", inside: "/Library") == "b.mp3")
  }

  @Test
  func testURLContainmentStandardizesBothSides() {
    let root = URL(fileURLWithPath: "/Volumes/iPod")
    #expect(URL(fileURLWithPath: "/Volumes/iPod/Music/./a.mp3").isContained(in: root))
    #expect(!URL(fileURLWithPath: "/Volumes/iPod/../iPod2/a.mp3").isContained(in: root))
    #expect(URL(fileURLWithPath: "/Volumes/iPod").isContained(in: root))
    #expect(!URL(fileURLWithPath: "/Volumes/iPod").isContained(in: root, allowRoot: false))
    #expect(!URL(fileURLWithPath: "/Volumes/iPod2").isContained(in: root))
  }
}
