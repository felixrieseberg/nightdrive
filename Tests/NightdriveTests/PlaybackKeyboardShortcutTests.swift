import AppKit
import Testing

@testable import Nightdrive

@MainActor
struct PlaybackKeyboardShortcutTests {
  @Test
  func freshUnmodifiedSpacePerformsPlaybackToggle() {
    #expect(
      disposition(keyCode: 49, modifierFlags: [], isARepeat: false) == .perform)
  }

  @Test
  func spaceKeyRepeatIsConsumedWithoutTogglingAgain() {
    #expect(
      disposition(keyCode: 49, modifierFlags: [], isARepeat: true) == .consume)
  }

  @Test
  func modifiedSpaceAndOtherKeysPassThrough() {
    for modifier: NSEvent.ModifierFlags in [.command, .control, .option, .shift, .function] {
      #expect(
        disposition(keyCode: 49, modifierFlags: modifier, isARepeat: false) == .passThrough)
    }
    #expect(
      disposition(keyCode: 36, modifierFlags: [], isARepeat: false) == .passThrough)
  }

  @Test
  func editableTextInputsKeepSpace() {
    let textView = NSTextView()
    textView.isEditable = true
    #expect(
      disposition(firstResponder: textView) == .passThrough)

    let textField = NSTextField()
    textField.isEditable = true
    #expect(
      disposition(firstResponder: textField) == .passThrough)
  }

  @Test
  func readOnlyTextDoesNotBlockPlaybackShortcut() {
    let textView = NSTextView()
    textView.isEditable = false
    #expect(
      disposition(firstResponder: textView) == .perform)
  }

  private func disposition(
    keyCode: UInt16 = 49,
    modifierFlags: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false,
    firstResponder: NSResponder? = nil
  ) -> PlaybackKeyboardShortcut.Disposition {
    PlaybackKeyboardShortcut.disposition(
      keyCode: keyCode,
      modifierFlags: modifierFlags,
      isARepeat: isARepeat,
      firstResponder: firstResponder)
  }
}
