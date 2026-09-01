import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct SystemSleepWakeControllerTests {
  private let willSleep = Notification.Name("NightdriveTests.willSleep")
  private let didWake = Notification.Name("NightdriveTests.didWake")

  @Test
  func sleepPausesBeforeFlushAndWakeWaitsForDurability() async {
    let center = NotificationCenter()
    let allowFlush = TestGate()
    var events: [String] = []
    let controller = makeController(
      center: center,
      operations: .init(
        prepareForSleep: {
          events.append("pause")
          return true
        },
        flush: {
          events.append("flush")
          await allowFlush.wait()
        },
        resumeAfterWake: { events.append("resume:\($0)") }))

    center.post(name: willSleep, object: nil)
    #expect(events == ["pause"])
    await waitUntil { events == ["pause", "flush"] }
    center.post(name: didWake, object: nil)
    #expect(events == ["pause", "flush"])

    await allowFlush.signal()
    await waitUntil { events.count == 3 }
    #expect(events == ["pause", "flush", "resume:true"])
    _ = controller
  }

  @Test
  func pausedPlaybackStaysPausedAfterWake() async {
    let center = NotificationCenter()
    var resumeIntents: [Bool] = []
    let controller = makeController(
      center: center,
      operations: .init(
        prepareForSleep: { false },
        flush: {},
        resumeAfterWake: { resumeIntents.append($0) }))

    center.post(name: willSleep, object: nil)
    center.post(name: didWake, object: nil)
    await waitUntil { resumeIntents.count == 1 }

    #expect(resumeIntents == [false])
    _ = controller
  }

  @Test
  func repeatedNotificationsProduceOneLifecycleTransition() async {
    let center = NotificationCenter()
    var prepareCount = 0
    var flushCount = 0
    var resumeCount = 0
    let controller = makeController(
      center: center,
      operations: .init(
        prepareForSleep: {
          prepareCount += 1
          return true
        },
        flush: { flushCount += 1 },
        resumeAfterWake: { _ in resumeCount += 1 }))

    center.post(name: willSleep, object: nil)
    center.post(name: willSleep, object: nil)
    await waitUntil { flushCount == 1 }
    center.post(name: didWake, object: nil)
    center.post(name: didWake, object: nil)
    await waitUntil { resumeCount == 1 }

    #expect(prepareCount == 1)
    #expect(flushCount == 1)
    #expect(resumeCount == 1)
    _ = controller
  }

  @Test
  func sleepingAgainWithdrawsAResumeQueuedBehindTheFlush() async {
    let center = NotificationCenter()
    let allowFlush = TestGate()
    var resumeCount = 0
    let controller = makeController(
      center: center,
      operations: .init(
        prepareForSleep: { true },
        flush: { await allowFlush.wait() },
        resumeAfterWake: { _ in resumeCount += 1 }))

    center.post(name: willSleep, object: nil)
    center.post(name: didWake, object: nil)
    center.post(name: willSleep, object: nil)
    await allowFlush.signal()
    #expect(await holds { resumeCount == 0 })

    center.post(name: didWake, object: nil)
    await waitUntil { resumeCount == 1 }
    _ = controller
  }

  @Test
  func invalidationPreventsAQueuedWakeResume() async {
    let center = NotificationCenter()
    let allowFlush = TestGate()
    var resumeCount = 0
    var prepareCount = 0
    let controller = makeController(
      center: center,
      operations: .init(
        prepareForSleep: {
          prepareCount += 1
          return true
        },
        flush: { await allowFlush.wait() },
        resumeAfterWake: { _ in resumeCount += 1 }))

    center.post(name: willSleep, object: nil)
    center.post(name: didWake, object: nil)
    controller.invalidate()
    await allowFlush.signal()
    center.post(name: willSleep, object: nil)

    #expect(await holds { resumeCount == 0 })
    #expect(prepareCount == 1)
  }

  @Test
  func unavailableOrLostOutputRejectsTheCapturedResumeIntent() {
    let outputBeforeSleep = (deviceUID: "headphones", lossGeneration: UInt64(3))

    #expect(
      !PlayerController.shouldResumeAfterSystemWake(
        playbackWasActive: true,
        outputBeforeSleep: outputBeforeSleep,
        outputAfterWake: (nil, 3),
        routeIsAvailable: false))
    #expect(
      !PlayerController.shouldResumeAfterSystemWake(
        playbackWasActive: true,
        outputBeforeSleep: outputBeforeSleep,
        outputAfterWake: ("headphones", 4),
        routeIsAvailable: true))
    #expect(
      !PlayerController.shouldResumeAfterSystemWake(
        playbackWasActive: true,
        outputBeforeSleep: outputBeforeSleep,
        outputAfterWake: ("speakers", 3),
        routeIsAvailable: true))
    #expect(
      PlayerController.shouldResumeAfterSystemWake(
        playbackWasActive: true,
        outputBeforeSleep: outputBeforeSleep,
        outputAfterWake: outputBeforeSleep,
        routeIsAvailable: true))
  }

  private func makeController(
    center: NotificationCenter, operations: SystemSleepWakeOperations
  ) -> SystemSleepWakeController {
    SystemSleepWakeController(
      notificationCenter: center,
      willSleepNotification: willSleep,
      didWakeNotification: didWake,
      operations: operations)
  }
}
