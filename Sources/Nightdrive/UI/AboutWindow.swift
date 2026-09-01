import AppKit
import SwiftUI

/// Presents About as a compact AppKit window. Keeping it out of the SwiftUI
/// scene hierarchy prevents a utility window from adding itself to the Window
/// menu or disturbing the main window's commands.
@MainActor
enum AboutWindowPresenter {
  private static var window: NSWindow?

  @discardableResult
  static func show() -> NSWindow {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return window
    }

    let aboutWindow = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    aboutWindow.identifier = NSUserInterfaceItemIdentifier("nightdrive-about")
    aboutWindow.title = "About \(AppIdentity.appTitle)"
    aboutWindow.titleVisibility = .hidden
    aboutWindow.titlebarAppearsTransparent = true
    aboutWindow.isExcludedFromWindowsMenu = true
    aboutWindow.isReleasedWhenClosed = false
    aboutWindow.contentViewController = NSHostingController(rootView: AboutWindow())
    aboutWindow.center()
    window = aboutWindow
    aboutWindow.makeKeyAndOrderFront(nil)
    return aboutWindow
  }

  static func close() {
    window?.close()
  }
}

struct AboutWindow: View {
  var body: some View {
    VStack(spacing: 10) {
      icon
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)

      Text(AppIdentity.appTitle)
        .font(.title2.weight(.semibold))
        .lineLimit(1)

      Text(versionText)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .textSelection(.enabled)

      Text(copyrightText)
        .foregroundStyle(.secondary)

      Button("Nightdrive on GitHub") {
        NSWorkspace.shared.open(AppLinks.repository)
      }
      .buttonStyle(.link)
      .padding(.top, 4)

      Button("Acknowledgments…") {
        AcknowledgmentsWindowPresenter.show()
      }
      .buttonStyle(.link)
    }
    .multilineTextAlignment(.center)
    .padding(.horizontal, 44)
    .padding(.top, 42)
    .padding(.bottom, 30)
    .frame(width: 380)
  }

  @ViewBuilder
  private var icon: some View {
    if let bundled = NSImage(named: "AppIcon") ?? bundledApplicationIcon {
      Image(nsImage: bundled)
        .resizable()
        .aspectRatio(contentMode: .fit)
    } else {
      fallbackIcon
    }
  }

  private var fallbackIcon: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(
        LinearGradient(
          colors: [
            Color(red: 0.20, green: 0.21, blue: 0.23),
            Color(red: 0.07, green: 0.075, blue: 0.085),
          ],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay {
        GeometryReader { geometry in
          let side = min(geometry.size.width, geometry.size.height)
          let glass = RoundedRectangle(cornerRadius: side * 0.045, style: .continuous)
          glass
            .fill(Color(red: 0.015, green: 0.035, blue: 0.030))
            .overlay {
              HStack(alignment: .bottom, spacing: side * 0.029) {
                ForEach(Array(Self.bars.enumerated()), id: \.offset) { index, height in
                  VStack(spacing: side * 0.024) {
                    RoundedRectangle(cornerRadius: side * 0.008, style: .continuous)
                      .fill(VFD.amber)
                      .frame(height: side * 0.019)
                      .shadow(color: VFD.amber.opacity(0.7), radius: side * 0.024)
                      .opacity(Self.capped.contains(index) ? 1 : 0)
                    RoundedRectangle(cornerRadius: side * 0.009, style: .continuous)
                      .fill(VFD.glow)
                      .frame(height: side * 0.235 * height)
                      .shadow(color: VFD.glow.opacity(0.7), radius: side * 0.03)
                  }
                  .frame(width: side * 0.066)
                }
              }
              .frame(maxHeight: .infinity, alignment: .bottom)
              .padding(.bottom, side * 0.06)
            }
            .overlay(glass.strokeBorder(.black.opacity(0.85), lineWidth: 1))
            .frame(width: side * 0.582, height: side * 0.356)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
      }
  }

  private static let bars: [CGFloat] = [0.52, 0.86, 0.34, 0.68, 0.44]
  private static let capped: Set<Int> = [1, 3]

  private var bundledApplicationIcon: NSImage? {
    guard Bundle.main.infoDictionary?["CFBundleIconFile"] != nil else { return nil }
    return NSApp.applicationIconImage
  }

  private var versionText: String {
    Self.versionText(info: Bundle.main.infoDictionary)
  }

  private var copyrightText: String {
    Self.copyrightText(info: Bundle.main.infoDictionary)
  }

  static func versionText(info: [String: Any]?) -> String {
    guard let short = info?["CFBundleShortVersionString"] as? String else {
      return String(localized: "Development build")
    }
    let build = info?["CFBundleVersion"] as? String
    if short == "0.0.0", build == "0" {
      return String(localized: "Development build")
    }
    if let build {
      return String(localized: "Version \(short) (\(build))")
    }
    return String(localized: "Version \(short)")
  }

  static func copyrightText(info: [String: Any]?) -> String {
    info?["NSHumanReadableCopyright"] as? String ?? "© Felix Rieseberg"
  }
}
