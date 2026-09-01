import Testing

@testable import Nightdrive

struct TrackTableRowProjectionTests {
  @Test
  func testSearchProjectsAnAlreadySortedSource() {
    let alpha = row(id: 1, title: "Alpha")
    let beta = row(id: 2, title: "Beta")
    let gamma = row(id: 3, title: "Gamma")
    let sorted = [alpha, beta, gamma]

    let visible = TrackTableRowProjection.visibleRows(in: sorted, matching: [3, 1])

    #expect(visible.map(\.id) == [1, 3])
    #expect(visible[0] === alpha)
    #expect(visible[1] === gamma)
  }

  @Test
  func testClearingSearchRestoresTheSortedSourceWithoutRebuildingRows() {
    let alpha = row(id: 1, title: "Alpha")
    let beta = row(id: 2, title: "Beta")
    let sorted = [alpha, beta]

    let restored = TrackTableRowProjection.visibleRows(in: sorted, matching: nil)

    #expect(restored.count == sorted.count)
    #expect(restored[0] === alpha)
    #expect(restored[1] === beta)
  }

  private func row(id: Int, title: String) -> SongRow<Int> {
    SongRow(
      id: id, title: title, durationMS: 0, artist: "", album: "", genre: "")
  }
}
