import Foundation
import Testing

@testable import Nightdrive

struct DeckCeremonyTests {

  @Test
  func testDisplayUppercasesAndTrims() {
    #expect(DeckCeremony.display("  hello felix ", fallback: "HELLO") == "HELLO FELIX")
  }

  @Test
  func testDisplayFallsBackWhenEmptyOrWhitespace() {
    #expect(DeckCeremony.display("", fallback: "HELLO") == "HELLO")
    #expect(DeckCeremony.display("   \n", fallback: "SEE YOU") == "SEE YOU")
  }

  @Test
  func testDisplayCutsToTheCharacterGeneratorLine() {
    let long = String(repeating: "A", count: 40)
    #expect(DeckCeremony.display(long, fallback: "HELLO").count == DeckCeremony.maxLength)
  }

  @Test
  func testDefaultsFitTheLine() {
    #expect(DeckCeremony.defaultGreeting.count <= DeckCeremony.maxLength)
  }

  @Test
  func testGreetingRunsEveryStageInOrder() {
    var t: TimeInterval = 0
    func mid(_ duration: TimeInterval) -> TimeInterval {
      defer { t += duration }
      return t + duration / 2
    }
    guard
      case .ignite(let ignite) = DeckCeremony.greetingPhase(
        at: mid(DeckCeremony.igniteDuration))
    else {
      Issue.record("expected ignite")
      return
    }
    #expect(abs((ignite) - (0.5)) <= 0.01)

    guard
      case .cascade(let cascade) = DeckCeremony.greetingPhase(
        at: mid(DeckCeremony.cascadeDuration))
    else {
      Issue.record("expected cascade")
      return
    }
    #expect(abs((cascade) - (0.5)) <= 0.01)

    guard
      case .assemble(let assemble) = DeckCeremony.greetingPhase(
        at: mid(DeckCeremony.assembleDuration))
    else {
      Issue.record("expected assemble")
      return
    }
    #expect(abs((assemble) - (0.5)) <= 0.01)

    guard
      case .holding(let hold) = DeckCeremony.greetingPhase(
        at: mid(DeckCeremony.greetingHoldDuration))
    else {
      Issue.record("expected holding")
      return
    }
    #expect(abs((hold) - (0.5)) <= 0.01)

    guard
      case .releasing(let release) = DeckCeremony.greetingPhase(
        at: mid(DeckCeremony.releaseDuration))
    else {
      Issue.record("expected releasing")
      return
    }
    #expect(abs((release) - (0.5)) <= 0.01)

    #expect(DeckCeremony.greetingPhase(at: t + 0.001) == .done)
  }

  @Test
  func testGreetingBeforeItsClockStartsIsParkedDark() {
    #expect(DeckCeremony.greetingPhase(at: -1) == .ignite(progress: 0))
  }

  @Test
  func testGreetingDurationCoversEveryStage() {
    #expect(
      abs(
        (DeckCeremony.greetingDuration)
          - (DeckCeremony.igniteDuration + DeckCeremony.cascadeDuration
            + DeckCeremony.assembleDuration + DeckCeremony.greetingHoldDuration
            + DeckCeremony.releaseDuration)) <= 1e-9)
  }

  @Test
  func testGreetingProgressNeverBacktracksWithinAStage() {
    var previous: (stage: Int, progress: Double) = (-1, 0)
    for step in 0...400 {
      let elapsed = TimeInterval(step) / 100
      let (stage, progress): (Int, Double)
      switch DeckCeremony.greetingPhase(at: elapsed) {
      case .ignite(let p): (stage, progress) = (0, p)
      case .cascade(let p): (stage, progress) = (1, p)
      case .assemble(let p): (stage, progress) = (2, p)
      case .holding(let p): (stage, progress) = (3, p)
      case .releasing(let p): (stage, progress) = (4, p)
      case .done: (stage, progress) = (5, 0)
      }
      #expect(stage >= previous.stage, "stage backtracked at \(elapsed)")
      if stage == previous.stage {
        #expect(progress >= previous.progress, "progress backtracked at \(elapsed)")
      }
      #expect(progress <= 1)
      #expect(progress >= 0)
      previous = (stage, progress)
    }
  }

  @Test
  func testLitDotsMatchTheCharacterGenerator() {
    let text = "HI"
    let dots = DeckCeremony.litDots(text)
    #expect(!(dots.isEmpty))
    for dot in dots {
      #expect(VFDDotFont.isLit(text, x: dot.column, y: dot.row), "dot (\(dot.column),\(dot.row)) not lit in font")
    }
    let width = VFDDotFont.width(of: text)
    var expected = 0
    for x in 0..<width {
      for y in 0..<VFDDotFont.glyphHeight where VFDDotFont.isLit(text, x: x, y: y) {
        expected += 1
      }
    }
    #expect(dots.count == expected)
  }

  @Test
  func testLitDotsReadLeftToRight() {
    let columns = DeckCeremony.litDots("AB").map(\.column)
    #expect(columns == columns.sorted(), "dots must build the line left to right")
  }

  @Test
  func testStaggerPinsAtItsEndpointsAndStaysInBounds() {
    #expect(DeckCeremony.stagger(origin: 0.5, overlap: 0.4, progress: 0) == 0)
    #expect(DeckCeremony.stagger(origin: 0.5, overlap: 0.4, progress: 1) == 1)
    for step in 0...100 {
      let q = DeckCeremony.stagger(
        origin: 0.5, overlap: 0.4, progress: Double(step) / 100)
      #expect(q >= 0)
      #expect(q <= 1)
    }
    #expect(DeckCeremony.stagger(origin: 1.0, overlap: 0.3, progress: 1) == 1)
  }

  @Test
  func testScatterIsDeterministicBoundedAndSaltSensitive() {
    for index in 0..<200 {
      let value = DeckCeremony.scatter(index)
      #expect(value == DeckCeremony.scatter(index), "scatter must be deterministic")
      #expect(value >= 0)
      #expect(value < 1)
    }
    #expect(DeckCeremony.scatter(3) != DeckCeremony.scatter(3, salt: 7))
  }

  @Test
  func testEasingsHitTheirEndpoints() {
    #expect(abs((DeckCeremony.easeOutCubic(0)) - (0)) <= 1e-9)
    #expect(abs((DeckCeremony.easeOutCubic(1)) - (1)) <= 1e-9)
  }
}
