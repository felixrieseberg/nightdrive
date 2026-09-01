import Testing

@testable import Nightdrive

@MainActor
struct ControlsWindowTests {
  @Test
  func testEverySectionHasCompleteRows() {
    let sections = ControlsReference.sections
    #expect(!sections.isEmpty)
    for section in sections {
      #expect(!section.title.isEmpty)
      #expect(!section.items.isEmpty)
      for item in section.items {
        #expect(!item.input.isEmpty)
        #expect(!item.action.isEmpty)
      }
    }
  }

  @Test
  func testRowIdentifiersAreUnique() {
    let ids = ControlsReference.sections.flatMap(\.items).map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test
  func testDocumentsVisualizerScrubGesture() {
    let gestures = ControlsReference.sections.flatMap(\.items).filter(\.isGesture)
    #expect(
      gestures.contains { item in
        item.input.localizedCaseInsensitiveContains("visualizer")
          && item.action.localizedCaseInsensitiveContains("scrub")
      })
  }

  @Test
  func testInputTokenizerSplitsModifiersAndConnectors() {
    #expect(
      ControlsReference.tokens(for: "⇧⌘O") == [.key("⇧"), .key("⌘"), .key("O")])
    #expect(
      ControlsReference.tokens(for: "⌘1 – ⌘9")
        == [.key("⌘"), .key("1"), .separator("–"), .key("⌘"), .key("9")])
    #expect(
      ControlsReference.tokens(for: "↑ / ↓") == [.key("↑"), .separator("/"), .key("↓")])
    #expect(ControlsReference.tokens(for: "Space") == [.key("Space")])
    #expect(ControlsReference.tokens(for: "⌘,") == [.key("⌘"), .key(",")])
  }

  @Test
  func testEveryRegisteredShortcutIsDocumented() {
    let documented = Set(ControlsReference.sections.flatMap(\.items).map(\.input))
    for shortcut in AppShortcuts.all {
      let display = AppShortcuts.display(shortcut)
      #expect(documented.contains(display), "\(display) is registered but not documented")
    }
  }

  @Test
  func testShortcutDisplayFormatting() {
    #expect(AppShortcuts.display(AppShortcuts.playPause) == "Space")
    #expect(AppShortcuts.display(AppShortcuts.nextTrack) == "⌘→")
    #expect(AppShortcuts.display(AppShortcuts.chooseLibraryFolder) == "⇧⌘O")
    #expect(AppShortcuts.display(AppShortcuts.toggleMute) == "⌥⌘M")
  }

  @Test
  func testSidebarShortcutRangeMatchesCommandOrder() {
    // The Navigation row documents exactly the sidebar items that actually
    // register a ⌘-digit — commandShortcutDigit caps at nine — so a tenth
    // View-menu item can't widen the documented range past what exists.
    let registered = SidebarItem.commandOrder.filter { $0.commandShortcutDigit != nil }
    #expect(!registered.isEmpty)
    #expect(registered.last?.commandShortcutDigit == Character("\(registered.count)"))
    let navigation = ControlsReference.sections.first { $0.title == "Navigation" }
    let range = navigation?.items.first
    #expect(range?.input == "⌘1 – ⌘\(registered.count)")
    #expect(range?.action == registered.map(\.menuTitle).joined(separator: ", "))
    #expect(registered.allSatisfy { !$0.menuTitle.isEmpty })
    #expect(
      navigation?.items.contains {
        $0.input == "⌘," && $0.action.contains("⌘1 – ⌘\(SettingsTab.allCases.count)")
      } == true)
  }
}
