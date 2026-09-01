import AppKit
import Foundation

struct SystemSleepWakeOperations {
  var prepareForSleep: @MainActor () -> Bool
  var flush: @MainActor () async -> Void
  var resumeAfterWake: @MainActor (_ playbackWasActive: Bool) -> Void
}

/// Serializes macOS sleep/wake notifications with Nightdrive's durable playback state.
@MainActor
final class SystemSleepWakeController {
  private let notificationCenter: NotificationCenter
  private let operations: SystemSleepWakeOperations
  private var observers: [any NSObjectProtocol] = []
  private var flushTask: Task<Void, Never>?
  private var isSleeping = false
  private var wakeRequested = false
  private var playbackWasActive = false
  private var isInvalidated = false

  init(
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    willSleepNotification: Notification.Name = NSWorkspace.willSleepNotification,
    didWakeNotification: Notification.Name = NSWorkspace.didWakeNotification,
    operations: SystemSleepWakeOperations
  ) {
    self.notificationCenter = notificationCenter
    self.operations = operations
    observers = [
      notificationCenter.addObserver(
        forName: willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.systemWillSleep() }
      },
      notificationCenter.addObserver(
        forName: didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.systemDidWake() }
      },
    ]
  }

  isolated deinit {
    removeObservers()
  }

  func systemWillSleep() {
    guard !isInvalidated else { return }
    if isSleeping {
      // A second sleep can arrive while the first wake still awaits its flush.
      // Keep the player paused and withdraw that queued resume.
      wakeRequested = false
      return
    }
    isSleeping = true
    playbackWasActive = operations.prepareForSleep()
    let flush = operations.flush
    flushTask = Task { @MainActor [weak self] in
      await flush()
      self?.flushFinished()
    }
  }

  func systemDidWake() {
    guard !isInvalidated, isSleeping, !wakeRequested else { return }
    wakeRequested = true
    if flushTask == nil { finishWake() }
  }

  func invalidate() {
    guard !isInvalidated else { return }
    isInvalidated = true
    isSleeping = false
    wakeRequested = false
    playbackWasActive = false
    flushTask = nil
    removeObservers()
  }

  private func flushFinished() {
    guard !isInvalidated else { return }
    flushTask = nil
    if wakeRequested { finishWake() }
  }

  private func finishWake() {
    let playbackWasActive = playbackWasActive
    isSleeping = false
    wakeRequested = false
    self.playbackWasActive = false
    operations.resumeAfterWake(playbackWasActive)
  }

  private func removeObservers() {
    observers.forEach(notificationCenter.removeObserver)
    observers.removeAll()
  }
}
