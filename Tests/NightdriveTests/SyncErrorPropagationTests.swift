import Foundation
import Testing

@testable import Nightdrive

/// Errors that used to be swallowed by `try?` must now reach the user with
/// the underlying cause intact.
@Suite(.tags(.fakeIpod))
final class SyncErrorPropagationTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }

  @Test
  func deviceCapacityErrorCarriesUnderlyingDescription() {
    let error = SyncError.deviceCapacityUnavailable(underlying: "The disk went away.")
    #expect(error.localizedDescription.contains("free space"))
    #expect(error.localizedDescription.contains("The disk went away."))
  }

  @Test
  func inboundCopyFailureCarriesUnderlyingValidationError() async throws {
    // A recorded path that escapes iPod_Control/Music used to be reported as
    // "Source file is missing on the iPod." — the real validation error is
    // more specific and must survive into the per-track failure.
    var stray = ITDBTrack()
    stray.title = "Stray"
    stray.artist = "Device"
    stray.ipodPath = ":stray.mp3"
    stray.sizeBytes = 1_000
    stray.lengthMS = 2_000
    var db = ITunesDatabase()
    db.tracks = [stray]
    try fs.writeDatabase(db)
    try writeTestSong(title: "Stray", to: ipodDir.appendingPathComponent("stray.mp3"))

    let device = try fs.readDatabase()
    let plan = SyncEngine.makePlan(library: [], device: device.tracks)
    #expect(plan.copyToFolder.count == 1)

    let result = try await runSync(plan)
    let failure = try #require(result.failures.first)
    #expect(failure.operation == .copyToLibrary)
    #expect(failure.reason.contains("outside iPod_Control/Music"))
  }
}
