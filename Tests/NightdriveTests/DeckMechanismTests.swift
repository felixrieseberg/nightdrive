import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct DeckMechanismTests {
  private final class MemoryPersistence: RemovableAppDataPersistence, Sendable {
    private let stored = Mutex<Data?>(nil)
    func load() throws -> Data? { stored.withLock { $0 } }
    func save(_ data: Data) throws { stored.withLock { $0 = data } }
    func remove() throws { stored.withLock { $0 = nil } }
  }

  @Test
  func testWarmupLatchResumesWhenRenderingFinishes() async {
    let latch = await MainActor.run { DeckSceneWarmupLatch() }
    let waiter = Task { @MainActor in await latch.wait() }

    await MainActor.run { latch.finish() }
    await waiter.value

    let finished = await MainActor.run { latch.isFinished }
    #expect(finished)
  }

  @Test
  func testWarmupLatchResumesCancelledWaiterWithoutFinishing() async {
    let latch = await MainActor.run { DeckSceneWarmupLatch() }
    let waiter = Task { @MainActor in await latch.wait() }

    waiter.cancel()
    await waiter.value

    let finished = await MainActor.run { latch.isFinished }
    #expect(!(finished))
  }

  @MainActor
  @Test
  func testSceneDismantleReleasesWaitersAndArmsAFreshLatchForTheNextOpen() async {
    let app = AppState(
      library: LibraryStore(),
      playlists: PlaylistStore(persistence: MemoryPersistence()),
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()),
      playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()))
    let deck = app.deck

    // A finished warmup from a mounted scene must not satisfy the next
    // mount: dismantling re-arms the latch so a later open waits again.
    deck.sceneWarmupDidFinish()
    deck.sceneWasDismantled()

    let waiter = Task { @MainActor in
      deck.open()
      await deck.waitToSettle()
    }
    defer { waiter.cancel() }

    // The remounted scene's coordinator reports warmup afresh.
    try? await Task.sleep(for: .milliseconds(50))
    deck.sceneWarmupDidFinish()

    let settled = await waitUntil(timeout: .seconds(10)) {
      deck.isExpanded && deck.isSeated
    }
    #expect(settled, "the remounted scene did not settle within 10 seconds")
    if settled { await waiter.value }
    #expect(deck.isExpanded)
    #expect(deck.isSeated)
  }

  @Test
  func testAngleSweepsFromFoldedToSeatedToOvershoot() {
    #expect(abs((DeckMechanism.angle(0)) - (88 * .pi / 180)) <= 1e-9)
    #expect(abs((DeckMechanism.angle(1)) - (0)) <= 1e-9)
    #expect(DeckMechanism.angle(1.115) < 0)
  }

  @Test
  func testReservedHeightClosesFlushAndOpensToTheFullSlot() {
    #expect(abs((DeckMechanism.reservedHeight(0)) - (0)) <= 1e-9)
    #expect(abs((DeckMechanism.reservedHeight(1)) - (DeckMechanism.openHeight)) <= 1e-9)
    #expect(abs((DeckMechanism.reservedHeight(1.115)) - (DeckMechanism.openHeight)) <= 1e-9)
    #expect(abs((DeckMechanism.reservedHeight(-0.2)) - (0)) <= 1e-9)
  }

  @Test
  func testReservedHeightIsMonotonicOverTheWholeStroke() {
    var previous = DeckMechanism.reservedHeight(0)
    for step in 1...240 {
      let progress = CGFloat(step) / 240 * 1.2
      let reserved = DeckMechanism.reservedHeight(progress)
      #expect(reserved + 1e-9 >= previous, Comment(rawValue: "backtracked at \(progress)"))
      previous = reserved
    }
  }

  @Test
  func testContentSpacingMatchesTheHingeGapOnlyWhileTheDeckIsOpen() {
    #expect(abs((DeckMechanism.contentSpacing(0)) - (0)) <= 1e-9)
    #expect(abs((DeckMechanism.contentSpacing(1)) - (DeckMechanism.hingeGap)) <= 1e-9)
    #expect(abs((DeckMechanism.contentSpacing(1.115)) - (DeckMechanism.hingeGap)) <= 1e-9)
    #expect(abs((DeckMechanism.contentSpacing(-0.2)) - (0)) <= 1e-9)
  }

  @Test
  func testSeatedFaceProjectsOneToOneOntoTheOverlayPlane() {
    for u in stride(from: CGFloat(0), through: DeckMechanism.faceHeight, by: 10) {
      #expect(abs((DeckMechanism.projectedY(u: u, progress: 1)) - (DeckMechanism.hingeGap + u)) <= 1e-9)
      #expect(abs((DeckMechanism.projectedScale(u: u, progress: 1)) - (1)) <= 1e-9)
    }
  }

  @Test
  func testTiltedFaceNarrowsTowardItsBottomEdge() {
    let top = DeckMechanism.projectedScale(u: 0, progress: 0.5)
    let bottom = DeckMechanism.projectedScale(
      u: DeckMechanism.faceHeight, progress: 0.5)

    #expect(top > bottom)
    #expect(bottom < 1)
  }

  @Test
  func testLiveFaceProjectionMatchesSceneKitCameraGeometryThroughoutTravel() {
    let size = CGSize(width: 860, height: DeckMechanism.faceHeight)
    let localPoints = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: size.width / 2, y: DeckMechanism.faceHeight / 2),
      CGPoint(x: size.width, y: DeckMechanism.faceHeight),
    ]

    for progress in [CGFloat(0.12), 0.5, 1, 1.08] {
      let transform = DeckFaceProjection(progress: progress).effectValue(size: size)
      for point in localPoints {
        let denominator =
          transform.m13 * point.x + transform.m23 * point.y + transform.m33
        let projected = CGPoint(
          x: (transform.m11 * point.x + transform.m21 * point.y + transform.m31)
            / denominator,
          y: (transform.m12 * point.x + transform.m22 * point.y + transform.m32)
            / denominator)
        let faceX = point.x - size.width / 2

        #expect(
          abs(
            (projected.x)
              - (size.width / 2
                + faceX * DeckMechanism.projectedScale(u: point.y, progress: progress))) <= 1e-8,
          Comment(rawValue: "horizontal projection drifted at progress \(progress), point \(point)"))
        #expect(
          abs(
            (projected.y)
              - (DeckMechanism.projectedY(u: point.y, progress: progress)
                - DeckMechanism.hingeGap)) <= 1e-8,
          Comment(rawValue: "vertical projection drifted at progress \(progress), point \(point)"))
      }
    }
  }

  @Test
  func testDoorNeverProjectsPastTheReservedSlot() {
    for step in 180...240 {
      let progress = CGFloat(step) / 200
      let front = DeckMechanism.projectedY(
        u: DeckMechanism.faceHeight, w: DeckMechanism.thickness / 2, progress: progress)
      let back = DeckMechanism.projectedY(
        u: DeckMechanism.faceHeight, w: -DeckMechanism.thickness / 2, progress: progress)
      let reserved = DeckMechanism.reservedHeight(progress)
      #expect(max(front, back) <= reserved + 0.5, Comment(rawValue: "clipped at \(progress)"))
    }
  }

  @Test
  func testDogsParkThenDriveHomeAtTheEndOfTravel() {
    #expect(DeckMechanism.dogTravel(0) == 0)
    #expect(DeckMechanism.dogTravel(0.79) == 0)
    #expect(DeckMechanism.dogTravel(0.9) > 0)
    #expect(abs((DeckMechanism.dogTravel(0.99)) - (1)) <= 1e-9)
    #expect(DeckMechanism.dogTravel(1.115) == 1)
  }
}
