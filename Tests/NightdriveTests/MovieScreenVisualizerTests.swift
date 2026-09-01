import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct MovieScreenVisualizerTests {

  @Test
  func testThePackRegistersItsBuiltInScenes() {
    let pack = MovieScreenVisualizers.all().map(\.descriptor)
    #expect(pack.map(\.id) == ["aquarium", "nightdrive", "fireworks", "dolphins"])
    #expect(pack.allSatisfy { $0.group == .builtIn })
    #expect(pack.allSatisfy { $0.wantsContinuousRedraw })
  }

  @Test
  func testTheSkylineIsDeterministicAndNeverLeavesAGap() {
    let skyline = CitySkyline(seed: 0xC17_15EA, blockWidth: 7, maxRise: 6)
    let again = CitySkyline(seed: 0xC17_15EA, blockWidth: 7, maxRise: 6)
    for x in -64...640 {
      let rise = skyline.rise(at: x)
      #expect(rise == again.rise(at: x), Comment(rawValue: "same seed, same city"))
      #expect((1...6).contains(rise), Comment(rawValue: "a hole in the skyline reads as a bug"))
    }
  }

  @Test
  func testWindowsAreSparseStableAndOnlyBelowTheRoof() {
    let skyline = CitySkyline(seed: 1, blockWidth: 5, maxRise: 8)
    var lit = 0
    var total = 0
    for x in 0..<320 {
      #expect(skyline.window(atColumn: x, rowsBelowRoof: 0) == 0)
      for row in 1...8 {
        let value = skyline.window(atColumn: x, rowsBelowRoof: row)
        #expect(value == skyline.window(atColumn: x, rowsBelowRoof: row), Comment(rawValue: "no churn"))
        #expect(value == 0 || (0.55...1).contains(value))
        total += 1
        if value > 0 { lit += 1 }
      }
    }
    #expect(lit > total / 10)
    #expect(lit < total / 2)
  }
}
