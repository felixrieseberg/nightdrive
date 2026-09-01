import Foundation
import Testing

@testable import Nightdrive

struct DeviceViewPreparationTests {
  @Test
  func testRowsBuildDeviceSongPresentationAndFilterWithoutChangingOrder() {
    var first = ITDBTrack()
    first.dbid = 10
    first.title = "First Song"
    first.artist = "Alpha"
    first.album = "Opening"
    first.lengthMS = 1_500

    var second = ITDBTrack()
    second.dbid = 20
    second.title = "Second Song"
    second.artist = "Beta"
    second.album = "Closing"
    second.lengthMS = 2_500

    let all = DeviceViewPreparation.rows(from: [second, first], matching: "")
    #expect(all.map(\.id) == [20, 10])
    #expect(all.map(\.durationMS) == [2_500, 1_500])

    let filtered = DeviceViewPreparation.rows(from: [second, first], matching: "alpha")
    #expect(filtered.map(\.id) == [10])
    #expect(filtered.first?.title == "First Song")
  }
}
