import Foundation
import Testing

@testable import Nightdrive

struct SyncExecutionRequestTests {
  @Test
  func testRequestCarriesConfirmedSafetyBoundsAndNoPreviewReportFields() {
    var preview = SyncPlan(librarySnapshot: [])
    preview.capacityShortfall = 42
    preview.scopeInput.confirmedRemovalDbids = [11, 22]
    preview.scopeInput.excludedURLKeys = ["trimmed-a", "trimmed-b"]

    let request = SyncExecutionRequest(preview)

    #expect(request.scopeInput.confirmedRemovalDbids == [11, 22])
    #expect(request.scopeInput.excludedURLKeys == ["trimmed-a", "trimmed-b"])
    #expect(
      Set(Mirror(reflecting: request).children.compactMap(\.label)) == [
        "librarySnapshot", "localPlaylists", "localRatings", "scopeInput",
      ])
  }
}
