import AppKit
import SwiftUI

private struct WindowIsVisibleKey: EnvironmentKey {
  static let defaultValue = true
}

extension EnvironmentValues {
  var windowIsVisible: Bool {
    get { self[WindowIsVisibleKey.self] }
    set { self[WindowIsVisibleKey.self] = newValue }
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

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .environment(\.windowIsVisible, isVisible)
      .background(WindowActivityObserver(isVisible: $isVisible).frame(width: 0, height: 0))
  }
}

private struct WindowActivityObserver: NSViewRepresentable {
  @Binding var isVisible: Bool

  final class ObserverView: NSView {
    var publish: (Bool) -> Void = { _ in }
    private var lastVisibility: Bool?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      NotificationCenter.default.removeObserver(self)
      lastVisibility = nil
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
      DispatchQueue.main.async { [weak self] in self?.publishCurrentVisibility() }
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowActivityChanged() {
      publishCurrentVisibility()
    }

    func publishCurrentVisibility() {
      guard let window else { return }
      let visibility = WindowVisibility.isVisible(window)
      guard visibility != lastVisibility else { return }
      lastVisibility = visibility
      publish(visibility)
    }
  }

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.publish = { isVisible = $0 }
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.publish = { isVisible = $0 }
  }
}
