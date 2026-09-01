import Observation
import SwiftUI

@MainActor
final class DeckSceneWarmupLatch {
  private(set) var isFinished = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  func wait() async {
    guard !isFinished else { return }
    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !isFinished, !Task.isCancelled else {
          continuation.resume()
          return
        }
        waiters[waiterID] = continuation
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancel(waiterID)
      }
    }
  }

  func finish() {
    guard !isFinished else { return }
    isFinished = true
    let pending = waiters.values
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }

  private func cancel(_ waiterID: UUID) {
    waiters.removeValue(forKey: waiterID)?.resume()
  }

  deinit {
    for waiter in waiters.values {
      waiter.resume()
    }
  }
}

/// The cassette deck's presentation model: door open/close/detach animation
/// state, the launch and greeting preferences, and the detached faceplate
/// panel. Owned by `AppState` and reached as `app.deck`.
@Observable
@MainActor
final class DeckPresenter {
  /// The presenter is owned by `AppState` for its whole lifetime, and the
  /// detached faceplate panel renders a live faceplate that needs the player
  /// and the visualizer, so it takes the composition root.
  @ObservationIgnored private unowned let app: AppState
  @ObservationIgnored private var motion: Task<Void, Never>?
  @ObservationIgnored private var sceneWarmup = DeckSceneWarmupLatch()
  @ObservationIgnored private let faceplatePanel = FaceplatePanelController()

  var isExpanded = false
  var isDisplayPowered = false
  var progress: CGFloat = 0
  var isSeated = false
  var isDetached = false
  var detachedAt: Date?
  var greetedThisLaunch = false

  /// When the glass began booting, published so the snapshot tour can time
  /// ceremony frames from the animation's own origin.
  var bootStart: Date?

  var opensOnLaunch = DeckPresenter.storedOpensOnLaunchPreference() {
    didSet { NightdriveDefaults.current.set(opensOnLaunch, forKey: Self.opensOnLaunchKey) }
  }
  private static let opensOnLaunchKey = "opensDeckOnLaunch"

  private static func storedOpensOnLaunchPreference() -> Bool {
    (NightdriveDefaults.current.object(forKey: opensOnLaunchKey) as? Bool) ?? true
  }

  var greeting: String =
    NightdriveDefaults.current.string(forKey: greetingKey) ?? DeckCeremony.defaultGreeting
  {
    didSet {
      let capped = String(greeting.prefix(DeckCeremony.maxLength))
      if capped != greeting { greeting = capped }
      NightdriveDefaults.current.set(greeting, forKey: Self.greetingKey)
    }
  }
  private static let greetingKey = "deckGreeting"

  init(app: AppState) {
    self.app = app
  }

  deinit {
    motion?.cancel()
  }

  func toggle() {
    isExpanded ? close() : open()
  }

  func detach() {
    guard !isDetached else { return }
    motion?.cancel()
    let hadSeatedDoor = isExpanded && isSeated
    isSeated = false
    feedback(.generic)

    if !hadSeatedDoor || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      completeDetach()
      return
    }

    motion = Task { @MainActor [weak self] in
      guard let self else { return }
      withAnimation(.easeIn(duration: 0.09)) { self.progress = 1.06 }
      guard await self.pause(for: .milliseconds(100)) else { return }
      self.completeDetach()
    }
  }

  private func completeDetach() {
    isDisplayPowered = false
    isDetached = true
    detachedAt = .now
    progress = isExpanded ? 1 : 0
    feedback(.levelChange)
    faceplatePanel.show(app: app)
  }

  func attach() {
    guard isDetached else { return }
    motion?.cancel()
    faceplatePanel.close()
    isDetached = false
    detachedAt = nil
    isSeated = false

    NSApp.activate()
    app.openMainWindow?()

    guard isExpanded else {
      isDisplayPowered = false
      progress = 0
      return
    }

    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      isDisplayPowered = true
      progress = 1
      isSeated = true
      return
    }

    var offered = Transaction()
    offered.disablesAnimations = true
    withTransaction(offered) {
      isDisplayPowered = true
      progress = 0.94
    }

    motion = Task { @MainActor [weak self] in
      guard let self else { return }
      self.feedback(.generic)
      withAnimation(.easeIn(duration: 0.07)) { self.progress = 1.045 }
      guard await self.pause(for: .milliseconds(75)) else { return }

      withAnimation(.easeOut(duration: 0.10)) { self.progress = 1 }
      guard await self.pause(for: .milliseconds(105)) else { return }

      guard self.isExpanded, !self.isDetached else { return }
      self.isSeated = true
      self.feedback(.levelChange)
    }
  }

  func open() {
    guard !isExpanded else { return }
    motion?.cancel()
    isExpanded = true
    isSeated = false

    if isDetached {
      isDisplayPowered = false
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        progress = 1
        return
      }
      feedback(.alignment)
      withAnimation(.easeOut(duration: 0.45)) { progress = 1 }
      return
    }

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      isDisplayPowered = true
      progress = 1
      isSeated = true
      return
    }

    let warmup = sceneWarmup
    motion = Task { @MainActor [weak self, warmup] in
      if !warmup.isFinished {
        await warmup.wait()
        guard !Task.isCancelled else { return }
      }
      guard let self else { return }

      self.feedback(.alignment)
      if self.progress < 1.08 {
        guard self.isExpanded, !self.isDetached else { return }
        self.isDisplayPowered = true
        withAnimation(.linear(duration: 0.9)) { self.progress = 1.115 }
        guard await self.pause(for: .milliseconds(905)) else { return }
      }

      self.feedback(.generic)
      withAnimation(.easeOut(duration: 0.09)) { self.progress = 0.965 }
      guard await self.pause(for: .milliseconds(95)) else { return }

      self.feedback(.alignment)
      withAnimation(.easeIn(duration: 0.075)) { self.progress = 1.035 }
      guard await self.pause(for: .milliseconds(80)) else { return }

      withAnimation(.easeOut(duration: 0.11)) { self.progress = 1 }
      guard await self.pause(for: .milliseconds(115)) else { return }

      guard self.isExpanded, !self.isDetached else { return }
      self.isSeated = true
      self.feedback(.levelChange)
    }
  }

  func close() {
    guard isExpanded else { return }
    motion?.cancel()
    isExpanded = false
    isSeated = false

    if isDetached {
      isDisplayPowered = false
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        progress = 0
        return
      }
      feedback(.alignment)
      withAnimation(.easeOut(duration: 0.4)) { progress = 0 }
      return
    }

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      isDisplayPowered = false
      progress = 0
      return
    }

    motion = Task { @MainActor [weak self] in
      guard let self else { return }

      self.feedback(.alignment)
      if self.progress > 0.07 {
        withAnimation(.linear(duration: 0.82)) { self.progress = 0.018 }
        guard await self.pause(for: .milliseconds(825)) else { return }
      }

      self.feedback(.generic)
      withAnimation(.spring(duration: 0.07, bounce: 0.2)) { self.progress = 0.043 }
      guard await self.pause(for: .milliseconds(75)) else { return }

      withAnimation(.easeOut(duration: 0.07)) { self.progress = 0 }
      guard await self.pause(for: .milliseconds(75)) else { return }
      guard !self.isExpanded else { return }
      self.isDisplayPowered = false
    }
  }

  func waitToSettle() async {
    let motion = self.motion
    await motion?.value
  }

  func sceneWarmupDidFinish() {
    sceneWarmup.finish()
  }

  /// The deck scene view is unmounted whenever the door is fully closed to
  /// release its SceneKit render buffers. Arm a fresh latch so the next open
  /// waits for the remounted scene to warm up before animating.
  func sceneWasDismantled() {
    sceneWarmup.finish()
    sceneWarmup = DeckSceneWarmupLatch()
  }

  func present(progress: CGFloat, seated: Bool) {
    motion?.cancel()
    if isDetached {
      faceplatePanel.close()
    }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isDetached = false
      detachedAt = nil
      isExpanded = progress > 0
      isDisplayPowered = progress > 0
      self.progress = progress
      isSeated = seated
    }
  }

  func presentDetached() {
    motion?.cancel()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      isExpanded = true
      isDisplayPowered = false
      progress = 1
      isSeated = false
      isDetached = true
      detachedAt = .now
    }
    faceplatePanel.show(app: app, pinnedToNaturalSize: true)
  }

  private func pause(for duration: Duration) async -> Bool {
    do {
      try await Task.sleep(for: duration)
      return !Task.isCancelled
    } catch {
      return false
    }
  }

  private func feedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
  }
}
