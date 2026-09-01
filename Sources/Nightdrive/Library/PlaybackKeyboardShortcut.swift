import AppKit

enum PlaybackKeyboardShortcut {
  enum Disposition: Equatable {
    case passThrough
    case perform
    case consume
  }

  private static let spaceKeyCode: UInt16 = 49
  private static let disallowedModifiers: NSEvent.ModifierFlags = [
    .command, .control, .option, .shift, .function,
  ]

  @MainActor
  static func disposition(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags,
    isARepeat: Bool,
    firstResponder: NSResponder?
  ) -> Disposition {
    guard keyCode == spaceKeyCode else { return .passThrough }
    guard modifierFlags.intersection(disallowedModifiers).isEmpty else {
      return .passThrough
    }
    guard !isEditingText(firstResponder) else { return .passThrough }
    return isARepeat ? .consume : .perform
  }

  @MainActor
  static func isEditingText(_ responder: NSResponder?) -> Bool {
    if let textView = responder as? NSTextView {
      return textView.isEditable
    }
    if let textField = responder as? NSTextField {
      return textField.isEditable
    }
    return false
  }
}
