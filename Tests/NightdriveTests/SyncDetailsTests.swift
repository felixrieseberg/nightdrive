import Foundation
import Testing

@testable import Nightdrive

struct SyncDetailsTests {
  @Test
  func testFailureDescriptionIncludesOperationPathAndReason() {
    let failure = SyncFailure(
      operation: .copyToDevice,
      path: "/Music/Artist/Unreadable.flac",
      reason: "The audio file could not be read.")

    #expect(failure.operation.title == "Copy to iPod")
    #expect(failure.operation.systemImage == "arrow.up.doc")
    #expect(failure.description == "Copy to iPod — /Music/Artist/Unreadable.flac: The audio file could not be read.")
  }

  @Test
  func testFailedSyncSummaryUsesCountsAndPluralization() {
    let result = SyncResult(
      copiedToDevice: 2,
      copiedToFolder: 1,
      failures: [
        SyncFailure(operation: .copyToDevice, path: "/one.flac", reason: "Unreadable."),
        SyncFailure(operation: .reconstructMetadata, path: "/two.mp3", reason: "Malformed."),
      ])

    let details = SyncDetailsModel(result: result)
    #expect(details.title == "Sync Completed with Issues")
    #expect(details.summary == "2 tracks copied to iPod · 1 track copied to library · 2 failed operations")
    #expect(details.headUnitSummary == "2 TO IPOD · 1 TO LIBRARY · 2 FAILED")
  }

  @Test
  func testSuccessfulNoOpSyncHasCompactSummary() {
    let details = SyncDetailsModel(result: SyncResult())

    #expect(details.title == "Sync Complete")
    #expect(details.summary == "Everything was already in sync.")
    #expect(details.headUnitSummary == "ALREADY IN SYNC")
  }
}
