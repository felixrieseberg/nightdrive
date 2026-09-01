import AppKit

@MainActor
enum DarkAppearance {
  static func install() {
    apply()
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil,
      queue: .main
    ) { _ in
      Task { @MainActor in apply() }
    }
  }

  private static func apply() {
    let name: NSAppearance.Name =
      NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
      ? .accessibilityHighContrastDarkAqua
      : .darkAqua
    NSApplication.shared.appearance = NSAppearance(named: name)
  }
}
