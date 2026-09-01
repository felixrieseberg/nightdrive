import AppKit
import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct RecentAndDockIntegrationTests {
  @Test
  func recentAudioDocumentsFilterDedupeReorderAndClear() throws {
    let root = TestScratch.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let first = root.appendingPathComponent("First.mp3")
    let second = root.appendingPathComponent("Second.m4a")
    let unsupported = root.appendingPathComponent("Notes.txt")
    let folder = root.appendingPathComponent("Folder.mp3")
    let missing = root.appendingPathComponent("Missing.mp3")
    let remote = try #require(URL(string: "https://example.com/Remote.mp3"))
    for url in [first, second, unsupported] { try Data([0]).write(to: url) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = RecentDocumentStore(
      urls: [first, first, missing, folder, unsupported, remote, second])
    let recent = RecentAudioDocuments(operations: store.operations)

    #expect(recent.urls == [first, second])
    recent.record([second, missing, first, second])
    #expect(store.noted == [first, second])
    #expect(recent.urls == [second, first])

    try FileManager.default.removeItem(at: second)
    #expect(recent.urlForOpening(second) == nil)
    #expect(recent.urls == [first])
    try FileManager.default.removeItem(at: first)
    recent.refresh()
    #expect(recent.urls.isEmpty)
    #expect(recent.canClear)
    recent.clear()
    #expect(store.clearCount == 1)
    #expect(recent.urls.isEmpty)
    #expect(!recent.canClear)
  }

  @Test
  func externalOpenAndFolderDropRecordOnlyResolvedAudioFiles() async throws {
    let root = TestScratch.directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryRoot = root.appendingPathComponent("Library")
    let dropRoot = root.appendingPathComponent("Drop")
    try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dropRoot, withIntermediateDirectories: true)
    let opened = root.appendingPathComponent("Opened.mp3")
    let dropped = dropRoot.appendingPathComponent("Dropped.mp3")
    try writeTestSong(title: "Opened", to: opened)
    try writeTestSong(title: "Dropped", to: dropped)
    let store = RecentDocumentStore()
    let recent = RecentAudioDocuments(operations: store.operations)
    let app = AppState(
      library: LibraryStore(folderURL: libraryRoot),
      playbackPersistence: PlaybackPersistenceStore(
        fileURL: root.appendingPathComponent("playback.json")),
      recentAudioDocuments: recent)

    await app.openAudioFiles([opened, root.appendingPathComponent("Missing.mp3")])
    #expect(recent.urls == [opened])
    await app.enqueueDroppedAudioFiles([dropRoot])
    #expect(recent.urls == [dropped, opened])
    #expect(!recent.urls.contains(dropRoot))
    app.player.stop()
  }

  @Test
  func dockMenuUsesFreshModelAndDispatchesOnlyEnabledActions() throws {
    let delegate = NightdriveApplicationDelegate { _, _ in }
    let source = DockModelSource(
      DockPlaybackMenuModel(
        nowPlaying: "Midnight Drive — The Signals", isPlaying: false,
        capabilities: capabilities(canPlay: true, canPrevious: false, canNext: true),
        isRouteAvailable: true))
    var actions: [DockMenuAction] = []
    delegate.dockMenuModel = { source.model }
    delegate.performDockMenuAction = { actions.append($0) }

    var menu = try #require(delegate.applicationDockMenu(.shared))
    #expect(menu.items.first?.title == "Now Playing: Midnight Drive — The Signals")
    #expect(menu.item(withTitle: "Play")?.isEnabled == true)
    #expect(menu.item(withTitle: "Previous")?.isEnabled == false)
    #expect(menu.item(withTitle: "Next")?.isEnabled == true)
    let previousIndex = try #require(menu.items.firstIndex { $0.title == "Previous" })
    menu.items[previousIndex].isEnabled = true
    menu.performActionForItem(at: previousIndex)
    #expect(actions.isEmpty)
    let nextIndex = try #require(menu.items.firstIndex { $0.title == "Next" })
    menu.performActionForItem(at: nextIndex)
    #expect(actions == [.next])

    source.model = DockPlaybackMenuModel(
      nowPlaying: "Midnight Drive", isPlaying: true,
      capabilities: capabilities(canPlay: false, canPrevious: true, canNext: false),
      isRouteAvailable: false)
    menu.performActionForItem(at: nextIndex)
    #expect(actions == [.next])
    menu = try #require(delegate.applicationDockMenu(.shared))
    #expect(menu.item(withTitle: "Pause")?.isEnabled == true)
    #expect(menu.item(withTitle: "Previous")?.isEnabled == false)
    #expect(menu.item(withTitle: "Show Nightdrive")?.isEnabled == true)
    #expect(menu.item(withTitle: "Show Up Next")?.isEnabled == true)
  }

  private func capabilities(
    canPlay: Bool, canPrevious: Bool, canNext: Bool
  ) -> SystemMediaCapabilities {
    SystemMediaCapabilities(
      canPlay: canPlay, canPause: !canPlay, canStop: true,
      canGoNext: canNext, canGoPrevious: canPrevious, canSeek: true,
      canSkip: false, canChangeRate: true, canChangeShuffle: true,
      canChangeRepeat: true, canGiveFeedback: false)
  }
}

@MainActor
private final class DockModelSource {
  var model: DockPlaybackMenuModel

  init(_ model: DockPlaybackMenuModel) { self.model = model }
}

@MainActor
private final class RecentDocumentStore {
  var urls: [URL]
  private(set) var noted: [URL] = []
  private(set) var clearCount = 0

  init(urls: [URL] = []) { self.urls = urls }

  var operations: RecentDocumentOperations {
    RecentDocumentOperations(
      recentURLs: { self.urls },
      note: { url in
        self.noted.append(url)
        self.urls.removeAll { $0 == url }
        self.urls.insert(url, at: 0)
      },
      clear: {
        self.clearCount += 1
        self.urls = []
      })
  }
}
