import SwiftUI

/// Every keyboard shortcut the app registers, in one place. The menu
/// commands consume these constants and Help ▸ Controls renders them, so a
/// shortcut cannot change without its documentation following. Register new
/// shortcuts here and document them in ControlsReference — a test holds
/// `all` and the documented inputs together.
enum AppShortcuts {
  static let playPause = KeyboardShortcut(.space, modifiers: [])
  static let nextTrack = KeyboardShortcut(.rightArrow, modifiers: .command)
  static let previousTrack = KeyboardShortcut(.leftArrow, modifiers: .command)
  static let toggleMute = KeyboardShortcut("m", modifiers: [.command, .option])
  static let nextEqualizerPreset = KeyboardShortcut("e", modifiers: [.command, .option])
  static let syncIpod = KeyboardShortcut("s")
  static let openAudioFiles = KeyboardShortcut("o")
  static let chooseLibraryFolder = KeyboardShortcut("o", modifiers: [.command, .shift])
  static let rescanLibrary = KeyboardShortcut("r")
  static let editInfo = KeyboardShortcut("i")
  static let find = KeyboardShortcut("f")
  static let commandPalette = KeyboardShortcut("k")
  static let toggleDeck = KeyboardShortcut("d")
  static let toggleFaceplate = KeyboardShortcut("d", modifiers: [.command, .shift])
  static let nextVisualizer = KeyboardShortcut("v", modifiers: [.command, .shift])

  static let all: [KeyboardShortcut] = [
    playPause, nextTrack, previousTrack, toggleMute, nextEqualizerPreset, syncIpod,
    openAudioFiles, chooseLibraryFolder, rescanLibrary, editInfo, find, commandPalette,
    toggleDeck, toggleFaceplate, nextVisualizer,
  ]

  /// The combo as the Controls window shows it, modifiers in the standard
  /// macOS ⌃⌥⇧⌘ order.
  static func display(_ shortcut: KeyboardShortcut) -> String {
    var text = ""
    if shortcut.modifiers.contains(.control) { text += "⌃" }
    if shortcut.modifiers.contains(.option) { text += "⌥" }
    if shortcut.modifiers.contains(.shift) { text += "⇧" }
    if shortcut.modifiers.contains(.command) { text += "⌘" }
    return text + keyLabel(shortcut.key)
  }

  private static func keyLabel(_ key: KeyEquivalent) -> String {
    if key == .space { return String(localized: "Space") }
    if key == .return { return String(localized: "Return") }
    if key == .escape { return String(localized: "Esc") }
    if key == .leftArrow { return "←" }
    if key == .rightArrow { return "→" }
    if key == .upArrow { return "↑" }
    if key == .downArrow { return "↓" }
    return String(key.character).uppercased()
  }
}
