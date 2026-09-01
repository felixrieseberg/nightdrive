import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct DeckPanelTests {
  @Test
  func testDetachedArtworkKeepsNaturalSizeAtNaturalPanelHeight() {
    #expect(
      DeckPanel.artworkSize(
        in: CGSize(width: 486, height: DeckPanel.glassHeight))
        == DeckPanel.naturalArtworkSize)
  }

  @Test
  func testDetachedArtworkGrowsWithAvailableSpace() {
    #expect(DeckPanel.artworkSize(in: CGSize(width: 876, height: 242)) == 200)
  }

  @Test
  func testDetachedArtworkStopsAtTheRenderedMaximum() {
    #expect(
      DeckPanel.artworkSize(in: CGSize(width: 2_000, height: 1_000))
        == DeckPanel.maximumArtworkSize)
  }

  @Test
  func testDetachedArtworkShrinksToFitEitherDimension() {
    #expect(DeckPanel.artworkSize(in: CGSize(width: 248, height: 100)) == 50)
    #expect(DeckPanel.artworkSize(in: CGSize(width: 600, height: 82)) == 40)
  }
}
