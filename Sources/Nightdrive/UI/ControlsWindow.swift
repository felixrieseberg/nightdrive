import AppKit
import SwiftUI

/// The Help ▸ Controls reference. The inventory lives apart from the view so
/// tests can hold it against the commands the app actually registers.
enum ControlsReference {
  struct Item: Identifiable {
    let input: String
    let action: String
    var isGesture = false

    var id: String { input + action }
  }

  struct Section: Identifiable {
    let title: String
    let items: [Item]

    var id: String { title }
  }

  /// How a shortcut string breaks into keycaps: each modifier symbol and each
  /// final key gets its own cap, while connectors like "/" or "–" stay plain.
  enum InputToken: Equatable {
    case key(String)
    case separator(String)
  }

  private static let modifierSymbols: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
  private static let separators: Set<Substring> = ["/", "–", "-"]

  static func tokens(for input: String) -> [InputToken] {
    var result: [InputToken] = []
    for word in input.split(separator: " ") {
      if separators.contains(word) {
        result.append(.separator(String(word)))
        continue
      }
      var pending = ""
      for character in word {
        if modifierSymbols.contains(character) {
          if !pending.isEmpty {
            result.append(.key(pending))
            pending = ""
          }
          result.append(.key(String(character)))
        } else {
          pending.append(character)
        }
      }
      if !pending.isEmpty {
        result.append(.key(pending))
      }
    }
    return result
  }

  static var sections: [Section] {
    [
      Section(
        title: String(localized: "Playback"),
        items: [
          Item(
            input: AppShortcuts.display(AppShortcuts.playPause),
            action: String(localized: "Play or pause")),
          Item(
            input: AppShortcuts.display(AppShortcuts.nextTrack),
            action: String(localized: "Next track")),
          Item(
            input: AppShortcuts.display(AppShortcuts.previousTrack),
            action: String(localized: "Previous track")),
          Item(
            input: AppShortcuts.display(AppShortcuts.toggleMute),
            action: String(localized: "Mute or unmute")),
          Item(
            input: AppShortcuts.display(AppShortcuts.nextEqualizerPreset),
            action: String(localized: "Next equalizer preset")),
          Item(
            input: AppShortcuts.display(AppShortcuts.syncIpod),
            action: String(localized: "Sync iPod")),
        ]),
      Section(
        title: String(localized: "Library"),
        items: [
          Item(
            input: AppShortcuts.display(AppShortcuts.openAudioFiles),
            action: String(localized: "Open audio files")),
          Item(
            input: AppShortcuts.display(AppShortcuts.chooseLibraryFolder),
            action: String(localized: "Choose library folder")),
          Item(
            input: AppShortcuts.display(AppShortcuts.rescanLibrary),
            action: String(localized: "Rescan library")),
          Item(
            input: AppShortcuts.display(AppShortcuts.editInfo),
            action: String(localized: "Edit info for the selected tracks")),
          Item(
            input: AppShortcuts.display(AppShortcuts.find),
            action: String(localized: "Find in the current view")),
          Item(
            input: AppShortcuts.display(AppShortcuts.commandPalette),
            action: String(localized: "Open the command palette")),
        ]),
      Section(
        title: String(localized: "Navigation"),
        items: [
          Item(
            input:
              "⌘1 – ⌘\(SidebarItem.commandOrder.filter { $0.commandShortcutDigit != nil }.count)",
            action: SidebarItem.commandOrder
              .filter { $0.commandShortcutDigit != nil }
              .map(\.menuTitle).joined(separator: ", ")),
          Item(input: "⌘0", action: String(localized: "First connected iPod")),
          Item(
            input: "⌘,",
            action: String(
              localized: "Settings (⌘1 – ⌘\(SettingsTab.allCases.count) pick a tab there)")),
        ]),
      Section(
        title: String(localized: "Deck & Visualizers"),
        items: [
          Item(
            input: AppShortcuts.display(AppShortcuts.toggleDeck),
            action: String(localized: "Open or close the deck display")),
          Item(
            input: AppShortcuts.display(AppShortcuts.toggleFaceplate),
            action: String(localized: "Detach or reattach the faceplate")),
          Item(
            input: AppShortcuts.display(AppShortcuts.nextVisualizer),
            action: String(localized: "Next visualizer")),
        ]),
      Section(
        title: String(localized: "Command Palette"),
        items: [
          Item(input: "↑ / ↓", action: String(localized: "Move the selection")),
          Item(input: "Return", action: String(localized: "Open the selected result")),
          Item(input: "Esc", action: String(localized: "Close the palette")),
        ]),
      Section(
        title: String(localized: "Mouse & Trackpad"),
        items: [
          Item(
            input: String(localized: "Drag across the visualizer"),
            action: String(localized: "Scrub through the current track"), isGesture: true),
          Item(
            input: String(localized: "Drag the deck seek bar"),
            action: String(localized: "Scrub through the current track"), isGesture: true),
          Item(
            input: String(localized: "Click the deck visualizer"),
            action: String(localized: "Switch to the next visualizer"), isGesture: true),
          Item(
            input: String(localized: "Right-click the deck"),
            action: String(localized: "Visualizer and tube color options"), isGesture: true),
          Item(
            input: String(localized: "Drag the volume slider"),
            action: String(localized: "Adjust the volume"), isGesture: true),
          Item(
            input: String(localized: "Double-click a track"),
            action: String(localized: "Play it"), isGesture: true),
          Item(
            input: String(localized: "Click the empty faceplate bay"),
            action: String(localized: "Reattach the detached faceplate"), isGesture: true),
        ]),
    ]
  }
}

/// Presents the controls reference as a compact AppKit window, mirroring the
/// About window: keeping it out of the SwiftUI scene hierarchy prevents a
/// utility window from adding itself to the Window menu or disturbing the
/// main window's commands.
@MainActor
enum ControlsWindowPresenter {
  private static var window: NSWindow?

  @discardableResult
  static func show() -> NSWindow {
    if let window {
      window.makeKeyAndOrderFront(nil)
      return window
    }

    let controlsWindow = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    controlsWindow.identifier = NSUserInterfaceItemIdentifier("nightdrive-controls")
    controlsWindow.title = String(localized: "Controls")
    controlsWindow.isExcludedFromWindowsMenu = true
    controlsWindow.isReleasedWhenClosed = false
    controlsWindow.contentViewController = NSHostingController(rootView: ControlsWindow())
    controlsWindow.center()
    window = controlsWindow
    controlsWindow.makeKeyAndOrderFront(nil)
    return controlsWindow
  }

  static func close() {
    window?.close()
  }
}

struct ControlsWindow: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ForEach(ControlsReference.sections) { section in
          VStack(alignment: .leading, spacing: 6) {
            Text(section.title)
              .font(.headline)
            VStack(spacing: 0) {
              ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                  Divider()
                }
                row(item)
              }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
      .padding(20)
    }
    .frame(width: 460, height: 560)
  }

  private func row(_ item: ControlsReference.Item) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(item.action)
        .frame(maxWidth: .infinity, alignment: .leading)
      if item.isGesture {
        Text(item.input)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      } else {
        keycaps(item.input)
      }
    }
    .font(.callout)
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
  }

  private func keycaps(_ input: String) -> some View {
    HStack(spacing: 3) {
      ForEach(Array(ControlsReference.tokens(for: input).enumerated()), id: \.offset) { _, token in
        switch token {
        case .key(let label):
          Text(label)
            .font(.callout.weight(.medium))
            .monospaced()
            .frame(minWidth: 9)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        case .separator(let label):
          Text(label)
            .foregroundStyle(.secondary)
        }
      }
    }
  }
}
