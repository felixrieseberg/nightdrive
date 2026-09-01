#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit

  @MainActor
  enum DemoInput {
    static var mainWindow: NSWindow? {
      let windows = NSApplication.shared.windows
      return windows.first(where: { $0.isVisible && !($0 is NSPanel) })
        ?? windows.first(where: \.isVisible)
    }

    private static func windowPoint(_ point: CGPoint, in window: NSWindow) -> CGPoint {
      CGPoint(x: point.x, y: window.frame.height - point.y)
    }

    private static func mouseEvent(
      _ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow,
      clickCount: Int = 1, pressure: Float = 0
    ) -> NSEvent? {
      NSEvent.mouseEvent(
        with: type, location: windowPoint(point, in: window), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: clickCount, pressure: pressure)
    }

    static func mouseDown(at point: CGPoint) {
      guard let window = mainWindow,
        let event = mouseEvent(.leftMouseDown, at: point, in: window, pressure: 1)
      else { return }
      window.sendEvent(event)
    }

    static func mouseUp(at point: CGPoint) {
      guard let window = mainWindow,
        let event = mouseEvent(.leftMouseUp, at: point, in: window)
      else { return }
      window.sendEvent(event)
    }

    @discardableResult
    static func focusTextInput(at point: CGPoint) -> Bool {
      guard let window = mainWindow, let root = window.contentView?.superview else { return false }
      let inWindow = windowPoint(point, in: window)
      guard let hit = root.hitTest(inWindow) else { return false }
      var view: NSView? = hit
      while let current = view {
        if current is NSTextField || current is NSTextView {
          return window.makeFirstResponder(current)
        }
        view = current.superview
      }
      return false
    }

    /// Scrolls the NSScrollView under `point` by `deltaY` pixels (positive
    /// scrolls down). Scrolling the clip view directly is deterministic
    /// where synthesized wheel events depend on event routing the demo's
    /// unfocused window doesn't reliably get. The clip view constrains the
    /// proposed bounds itself: content insets can make the legal resting
    /// origin negative, so a naive clamp to zero would jump on frame one.
    static func scroll(at point: CGPoint, byY deltaY: Double) {
      guard let window = mainWindow, let root = window.contentView?.superview,
        let hit = root.hitTest(windowPoint(point, in: window))
      else { return }
      var view: NSView? = hit
      while let current = view {
        if let scrollView = current as? NSScrollView {
          let clip = scrollView.contentView
          let flipped = scrollView.documentView?.isFlipped ?? true
          var proposed = clip.bounds
          proposed.origin.y += flipped ? deltaY : -deltaY
          let constrained = clip.constrainBoundsRect(proposed)
          guard constrained.origin != clip.bounds.origin else { return }
          clip.scroll(to: constrained.origin)
          scrollView.reflectScrolledClipView(clip)
          return
        }
        view = current.superview
      }
    }

    /// Clicks a menu button, leaves its menu open for `linger` seconds, then
    /// performs the item with the given title (if any) and dismisses it.
    /// Menu tracking blocks main-actor jobs, so the dismissal is a run-loop
    /// timer registered for the tracking mode, armed when tracking begins —
    /// and the menu may only begin tracking a run-loop turn after the click,
    /// so the observer stays armed past this call and is torn down later.
    static func flashOpenMenu(
      at point: CGPoint, linger: TimeInterval, selecting itemTitle: String? = nil
    ) {
      nonisolated(unsafe) var observer: NSObjectProtocol?
      observer = NotificationCenter.default.addObserver(
        forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
      ) { note in
        guard let menu = note.object as? NSMenu else { return }
        if let observer {
          NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        // The timer fires on the main run loop while the menu tracks there;
        // the unsafe capture only carries the menu into that main-thread
        // closure.
        nonisolated(unsafe) let trackedMenu = menu
        let timer = Timer(timeInterval: linger, repeats: false) { _ in
          MainActor.assumeIsolated {
            if let itemTitle,
              let index = trackedMenu.items.firstIndex(where: { $0.title == itemTitle })
            {
              trackedMenu.performActionForItem(at: index)
            }
            trackedMenu.cancelTracking()
          }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
      }
      // If the menu opens synchronously this blocks until the timer above
      // dismisses it; if it opens on a later turn, the observer arms then.
      mouseDown(at: point)
      mouseUp(at: point)
      let failsafe = Timer(timeInterval: linger + 4, repeats: false) { _ in
        if let observer {
          NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
      }
      RunLoop.main.add(failsafe, forMode: .common)
    }
  }

  enum DemoLog {
    static func note(_ message: String) {
      FileHandle.standardError.write(Data("demo: \(message)\n".utf8))
    }
  }
#endif
