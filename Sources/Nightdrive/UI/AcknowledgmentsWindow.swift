import AppKit
import SwiftUI

@MainActor
enum AcknowledgmentsWindowPresenter {
  private static var window: NSWindow?

  @discardableResult
  static func show() -> NSWindow {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return window
    }

    let acknowledgmentsWindow = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false)
    acknowledgmentsWindow.identifier = NSUserInterfaceItemIdentifier("nightdrive-acknowledgments")
    acknowledgmentsWindow.title = String(localized: "Acknowledgments")
    acknowledgmentsWindow.isExcludedFromWindowsMenu = true
    acknowledgmentsWindow.isReleasedWhenClosed = false
    acknowledgmentsWindow.contentViewController = NSHostingController(rootView: AcknowledgmentsWindow())
    acknowledgmentsWindow.setContentSize(NSSize(width: 620, height: 560))
    acknowledgmentsWindow.minSize = NSSize(width: 480, height: 360)
    acknowledgmentsWindow.center()
    window = acknowledgmentsWindow
    acknowledgmentsWindow.makeKeyAndOrderFront(nil)
    return acknowledgmentsWindow
  }

  static func close() {
    window?.close()
  }
}

struct AcknowledgmentsWindow: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Acknowledgments")
        .font(.title2.weight(.semibold))

      Text("Nightdrive is made possible in part by these projects and services.")
        .foregroundStyle(.secondary)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          sparkleSection
          Divider()
          musicBrainzSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 8)
      }
    }
    .padding(24)
    .frame(minWidth: 480, minHeight: 360)
  }

  private var sparkleSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Sparkle")
        .font(.headline)

      Text("Secure application updates for macOS.")
        .foregroundStyle(.secondary)

      Link("Visit the Sparkle project", destination: AppLinks.sparkle)

      Text(ThirdPartyNotices.sparkleLicense)
        .font(.system(size: 10.5, design: .monospaced))
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var musicBrainzSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("MusicBrainz")
        .font(.headline)

      Text(
        "Metadata lookup powered by MusicBrainz, operated by the MetaBrainz Foundation."
      )
      .foregroundStyle(.secondary)

      Link("Visit MusicBrainz", destination: AppLinks.musicBrainz)
    }
  }
}

enum ThirdPartyNotices {
  static let sparkleLicense: String = {
    guard
      let directory = Bundle.module.url(
        forResource: "ThirdPartyNotices", withExtension: nil),
      let text = try? String(
        contentsOf: directory.appending(path: "Sparkle.txt"), encoding: .utf8)
    else {
      assertionFailure("The bundled Sparkle license is missing or unreadable.")
      return String(localized: "The Sparkle license could not be loaded.")
    }
    return text
  }()
}
