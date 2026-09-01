#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI

  @MainActor
  enum DevelopmentWindowPresenter {
    private static var windows: [String: NSWindow] = [:]

    static func show(
      _ id: String,
      title: String,
      resizable: Bool = true,
      defaultSize: CGSize? = nil,
      @ViewBuilder content: () -> some View
    ) {
      if let window = windows[id] {
        window.makeKeyAndOrderFront(nil)
        return
      }
      var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
      if resizable { styleMask.insert(.resizable) }
      let window = NSWindow(
        contentRect: .zero,
        styleMask: styleMask,
        backing: .buffered,
        defer: false)
      window.title = title
      window.isExcludedFromWindowsMenu = true
      window.isReleasedWhenClosed = false
      window.contentViewController = NSHostingController(rootView: content())
      if let defaultSize { window.setContentSize(defaultSize) }
      window.center()
      windows[id] = window
      window.makeKeyAndOrderFront(nil)
    }

    static func showText(_ id: String, title: String, text: String) {
      let panel = DevelopmentTextPanel(text: text)
      if let window = windows[id] {
        window.contentViewController = NSHostingController(rootView: panel)
        window.makeKeyAndOrderFront(nil)
        return
      }
      show(id, title: title, defaultSize: CGSize(width: 760, height: 620)) { panel }
    }
  }

  private struct DevelopmentTextPanel: View {
    let text: String

    var body: some View {
      ScrollView([.horizontal, .vertical]) {
        Text(text)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
      }
    }
  }
#endif
