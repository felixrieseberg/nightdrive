import AppKit
import Testing

@testable import Nightdrive

@MainActor
struct DockIconAnimatorTests {
  @Test
  func testFrameLoopIsPresentAndUniform() throws {
    let frames = DockIconAnimator.loadFrames()
    #expect(frames.count == 12)

    var sizes: Set<String> = []
    for image in frames {
      let rep = try #require(image.representations.first)
      #expect(rep.pixelsWide == rep.pixelsHigh)
      #expect(rep.hasAlpha)
      sizes.insert("\(rep.pixelsWide)x\(rep.pixelsHigh)")

      // Frames must carry the Dock tile squircle: transparent corners,
      // opaque centre (the system does not mask custom Dock images).
      let bitmap = try #require(rep as? NSBitmapImageRep)
      let corner = try #require(bitmap.colorAt(x: 0, y: 0))
      let centre = try #require(
        bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
      #expect(corner.alphaComponent == 0)
      #expect(centre.alphaComponent == 1)
    }
    #expect(sizes.count == 1)
  }
}
