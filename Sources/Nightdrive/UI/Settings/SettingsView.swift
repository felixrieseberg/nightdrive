import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
  case general
  case ipodSync = "ipod-sync"
  case visualizers
  case online

  var id: String { rawValue }

  var title: String {
    switch self {
    case .general: String(localized: "General")
    case .ipodSync: String(localized: "iPod Sync")
    case .visualizers: String(localized: "Visualizers")
    case .online: String(localized: "Online")
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape.fill"
    case .ipodSync: "ipod"
    case .visualizers: "waveform"
    case .online: "network"
    }
  }

  var shortcut: KeyEquivalent {
    switch self {
    case .general: "1"
    case .ipodSync: "2"
    case .visualizers: "3"
    case .online: "4"
    }
  }
}

struct SettingsView: View {
  @Bindable var app: AppState

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  static let windowSize = CGSize(width: 900, height: 620)

  var body: some View {
    HStack(spacing: 0) {
      SettingsRail(selection: $app.settingsTab)
      pane(app.settingsTab)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsSurface.pane)
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: app.settingsTab)
    }
    .frame(width: Self.windowSize.width, height: Self.windowSize.height)
    .tint(VFD.accent)
    .background(SettingsSurface.pane)
    .background(SettingsWindowChrome(title: app.settingsTab.title))
    .toolbar {
      SettingsToolbar()
    }
  }

  @ViewBuilder
  private func pane(_ tab: SettingsTab) -> some View {
    switch tab {
    case .general: GeneralSettingsView(app: app)
    case .ipodSync: IPodSyncSettingsView(app: app)
    case .visualizers: VisualizerSettingsView(app: app)
    case .online:
      OnlineSettingsView(
        policy: app.onlineServices,
        openSuggestions: { app.openSuggestionsInbox() },
        openPodcasts: { app.openSidebarItem(.podcasts) })
    }
  }
}

private struct SettingsToolbar: ToolbarContent {
  @ToolbarContentBuilder
  var body: some ToolbarContent {
    if #available(macOS 26.0, *) {
      toolbarItem
        .sharedBackgroundVisibility(.hidden)
    } else {
      toolbarItem
    }
  }

  private var toolbarItem: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Color.clear
        .frame(
          width: SettingsMetrics.toolbarReservationWidth,
          height: SettingsMetrics.toolbarReservationHeight
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }
}

@MainActor
enum SettingsWindow {
  @discardableResult
  static func open() -> Bool {
    if let item = menuItem(), let action = item.action,
      NSApp.sendAction(action, to: item.target, from: item)
    {
      return true
    }
    for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
      if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return true }
    }
    return false
  }

  private static func menuItem() -> NSMenuItem? {
    guard let menu = NSApp.mainMenu else { return nil }
    for top in menu.items {
      guard let submenu = top.submenu else { continue }
      if let match = submenu.items.first(where: {
        let title = $0.title
        return title.hasPrefix("Settings") || title.hasPrefix("Preferences")
      }) {
        return match
      }
    }
    return nil
  }
}
