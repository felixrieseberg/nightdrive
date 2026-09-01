#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import Foundation
  import Synchronization

  enum DevelopmentSyncPacing {
    static let stepDelay: Duration = .milliseconds(600)

    private static let slowed = Mutex<Bool>(false)

    static var isSlowed: Bool {
      get { slowed.withLock { $0 } }
      set { slowed.withLock { $0 = newValue } }
    }

    static func pauseIfSlowed() async {
      guard isSlowed else { return }
      await Task.pause(for: stepDelay)
    }
  }
#endif
