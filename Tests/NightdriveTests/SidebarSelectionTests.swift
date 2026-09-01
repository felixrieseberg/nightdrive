#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI
  import Synchronization
  import Testing

  @testable import Nightdrive

  /// Regression coverage for the sidebar's Suggestions row: a `.badge`
  /// applied after `.tag` hid the tag trait from the List, so selecting the
  /// row set the selection to nil and the row appeared unclickable.
  @MainActor
  struct SidebarSelectionTests {
    private final class MemoryPersistence: RemovableAppDataPersistence, Sendable {
      private let stored = Mutex<Data?>(nil)
      var data: Data? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
      }
      func load() throws -> Data? { data }
      func save(_ data: Data) throws { self.data = data }
      func remove() throws { data = nil }
    }

    private func pump(seconds: TimeInterval) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func firstPopulatedTableView(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView, table.numberOfRows > 0 { return table }
      return view.subviews.lazy.compactMap(firstPopulatedTableView(in:)).first
    }

    private func firstVerticalSplitView(in view: NSView) -> NSSplitView? {
      if let splitView = view as? NSSplitView, splitView.isVertical { return splitView }
      return view.subviews.lazy.compactMap(firstVerticalSplitView(in:)).first
    }

    private func dividerHandles(in view: NSView) -> [SplitViewDividerHandleView] {
      var handles = view.subviews.flatMap(dividerHandles(in:))
      if let handle = view as? SplitViewDividerHandleView { handles.append(handle) }
      return handles
    }

    @Test

    func testEverySidebarRowSelectsItsItem() throws {
      let suggestions = MusicBrainzSuggestionStore(persistence: MemoryPersistence())
      let metadata = TrackMetadata(ITDBTrack())
      suggestions.add(
        MusicBrainzAlbumSuggestion(
          id: "repro-album", albumTitle: "Repro Album", artistName: "Repro Artist",
          releaseID: "repro-release", releaseTitle: "Repro Album", releaseYear: 2004,
          tracks: [
            MusicBrainzTrackSuggestion(
              trackKey: "/tmp/repro.mp3", displayTitle: "Repro Song",
              current: metadata, proposed: metadata)
          ]))
      let app = AppState(
        library: LibraryStore(),
        playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()),
        onlineServices: OnlineServicesPolicy(persistence: MemoryPersistence()),
        musicBrainzSuggestions: suggestions)

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 700),
        styleMask: [.titled, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ContentView(app: app))
      window.orderBack(nil)
      defer { window.close() }
      pump(seconds: 1.0)

      let sidebarTable = try #require(
        firstPopulatedTableView(in: window.contentView!), Comment(rawValue: "sidebar list not laid out"))

      // Select every row the way a click does and record where the SwiftUI
      // selection binding lands. Rows whose tag trait is hidden (the original
      // bug) resolve to nil instead of their item.
      var selected: Set<SidebarItem> = []
      for row in 0..<sidebarTable.numberOfRows {
        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        pump(seconds: 0.05)
        if let item = app.selection { selected.insert(item) }
      }

      let expected: Set<SidebarItem> = [
        .library, .artists, .albums, .genres, .upNext, .listening, .suggestions, .playlists,
      ]
      #expect((expected.subtracting(selected)) == ([]), Comment(rawValue: "sidebar rows missing selection"))
    }

    @Test

    func testSuggestionsRowExistsWhenInboxIsEmptyAndMusicBrainzIsOff() throws {
      let app = AppState(
        library: LibraryStore(),
        playbackPersistence: PlaybackPersistenceStore(persistence: MemoryPersistence()),
        onlineServices: OnlineServicesPolicy(persistence: MemoryPersistence()),
        musicBrainzSuggestions: MusicBrainzSuggestionStore(persistence: MemoryPersistence()))

      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1000, height: 700),
        styleMask: [.titled, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: ContentView(app: app))
      window.orderBack(nil)
      defer { window.close() }
      pump(seconds: 1.0)

      let sidebarTable = try #require(
        firstPopulatedTableView(in: window.contentView!), Comment(rawValue: "sidebar list not laid out"))
      var selected: Set<SidebarItem> = []
      for row in 0..<sidebarTable.numberOfRows {
        sidebarTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        pump(seconds: 0.05)
        if let item = app.selection { selected.insert(item) }
      }

      #expect(selected.contains(.suggestions))
    }

    @Test

    func testSplitDividerHandleMovesTheRealDivider() {
      let splitView = NSSplitView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
      splitView.isVertical = true
      splitView.addArrangedSubview(NSView())
      splitView.addArrangedSubview(NSView())
      splitView.setPosition(220, ofDividerAt: 0)

      SplitViewDividerHandleView().moveDivider(in: splitView, to: 260)

      #expect(abs((splitView.arrangedSubviews[0].frame.maxX) - (260)) <= 0.5)
      #expect((Bodywork.Seam.verticalHitWidth) >= (10))
    }

    @Test

    func testSplitDividerHitRegionCoversBothSidesOfTheSeam() throws {
      let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 500),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(
        rootView: HSplitView {
          List(["Album"], id: \.self) { Text($0) }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 220)
            .overlay(alignment: .trailing) {
              Bodywork.Seam(axis: .vertical, verticalHitPlacement: .insideTrailingEdge)
            }
          Color.clear
            .frame(minWidth: 300)
            .overlay(alignment: .leading) {
              Bodywork.Seam(
                axis: .vertical, verticalHitPlacement: .insideLeadingEdge,
                showsSeparator: false)
            }
        })
      window.orderBack(nil)
      defer { window.close() }
      pump(seconds: 0.2)

      let contentView = try #require(window.contentView)
      let splitView = try #require(firstVerticalSplitView(in: contentView))
      let handles = dividerHandles(in: contentView)
      #expect((handles.count) == (2))
      #expect(handles.allSatisfy { $0.splitViewToResize() === splitView })
      let hitRegions = handles.map { $0.convert($0.bounds, to: splitView) }
      let seamX = splitView.arrangedSubviews[0].frame.maxX

      for hitRegion in hitRegions {
        #expect(abs((hitRegion.width) - (6)) <= 0.5)
      }
      #expect(abs((try #require(hitRegions.map(\.minX).min())) - (seamX - 6)) <= 0.5)
      #expect(abs((try #require(hitRegions.map(\.maxX).max())) - (splitView.arrangedSubviews[1].frame.minX + 6)) <= 0.5)

      let seamInContent = splitView.convert(NSPoint(x: seamX, y: splitView.bounds.midY), to: contentView)
      let missedOffsets = (-5...5).filter { offset in
        let point = NSPoint(x: seamInContent.x + CGFloat(offset), y: seamInContent.y)
        let hitView = contentView.hitTest(point)
        let hitsHandle = handles.contains { $0 === hitView }
        let hitsNativeDivider = hitView === splitView
        return !hitsHandle && !hitsNativeDivider
      }
      #expect((missedOffsets) == ([]))
    }
  }
#endif
