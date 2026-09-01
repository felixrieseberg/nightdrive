import AppKit

@main
struct IdleBenchmarkCover {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)

    guard let screen = NSScreen.main else {
      FileHandle.standardError.write(Data("idle benchmark: no main screen\n".utf8))
      Foundation.exit(1)
    }

    let window = NSWindow(
      contentRect: screen.frame,
      styleMask: .borderless,
      backing: .buffered,
      defer: false,
      screen: screen)
    window.backgroundColor = .black
    window.isOpaque = true
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.orderFrontRegardless()

    FileHandle.standardOutput.write(Data("ready\n".utf8))
    application.run()
    _ = window
  }
}
