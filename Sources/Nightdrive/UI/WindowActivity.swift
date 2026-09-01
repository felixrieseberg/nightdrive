import AppKit
import SwiftUI

private struct WindowIsVisibleKey: EnvironmentKey {
  static let defaultValue = true
}

/// True for the duration of a mouse-driven window resize. A drag already
/// repaints every view on the main thread once per mouse event; the continuous
/// renderers read this and hold still rather than animating underneath it.
private struct WindowIsLiveResizingKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var windowIsVisible: Bool {
    get { self[WindowIsVisibleKey.self] }
    set { self[WindowIsVisibleKey.self] = newValue }
  }

  var windowIsLiveResizing: Bool {
    get { self[WindowIsLiveResizingKey.self] }
    set { self[WindowIsLiveResizingKey.self] = newValue }
  }
}

enum WindowVisibility {
  static func isVisible(
    isOrderedVisible: Bool,
    isMiniaturized: Bool,
    occlusionState: NSWindow.OcclusionState
  ) -> Bool {
    isOrderedVisible && !isMiniaturized && occlusionState.contains(.visible)
  }

  @MainActor
  static func isVisible(_ window: NSWindow) -> Bool {
    isVisible(
      isOrderedVisible: window.isVisible,
      isMiniaturized: window.isMiniaturized,
      occlusionState: window.occlusionState)
  }
}

struct WindowActivity<Content: View>: View {
  private let content: Content
  @State private var isVisible = true
  @State private var isLiveResizing = false

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .environment(\.windowIsVisible, isVisible)
      .environment(\.windowIsLiveResizing, isLiveResizing)
      .background(
        WindowActivityObserver(isVisible: $isVisible, isLiveResizing: $isLiveResizing)
          .frame(width: 0, height: 0))
  }
}

private struct WindowActivityObserver: NSViewRepresentable {
  @Binding var isVisible: Bool
  @Binding var isLiveResizing: Bool

  final class ObserverView: NSView {
    var publish: (Bool) -> Void = { _ in }
    var onLiveResizeChanged: (Bool) -> Void = { _ in }
    private var lastVisibility: Bool?
    private var lastLiveResize: Bool?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      lastVisibility = nil
      lastLiveResize = nil
      guard let window else { return }

      for name in [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.willCloseNotification,
      ] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(windowActivityChanged), name: name, object: window)
      }
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowWillStartLiveResize),
        name: NSWindow.willStartLiveResizeNotification, object: window)
      NotificationCenter.default.addObserver(
        self, selector: #selector(windowDidEndLiveResize),
        name: NSWindow.didEndLiveResizeNotification, object: window)
      DispatchQueue.main.async { [weak self] in self?.publishCurrentVisibility() }
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowActivityChanged() {
      publishCurrentVisibility()
    }

    @objc private func windowWillStartLiveResize() {
      publishLiveResize(true)
    }

    @objc private func windowDidEndLiveResize() {
      publishLiveResize(false)
    }

    func publishCurrentVisibility() {
      guard let window else { return }
      let visibility = WindowVisibility.isVisible(window)
      guard visibility != lastVisibility else { return }
      lastVisibility = visibility
      publish(visibility)
    }

    func publishLiveResize(_ resizing: Bool) {
      guard resizing != lastLiveResize else { return }
      lastLiveResize = resizing
      onLiveResizeChanged(resizing)
    }
  }

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.publish = { isVisible = $0 }
    view.onLiveResizeChanged = { isLiveResizing = $0 }
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.publish = { isVisible = $0 }
    view.onLiveResizeChanged = { isLiveResizing = $0 }
  }
}
