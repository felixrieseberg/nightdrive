import AppKit
import SwiftUI

struct PlaylistMenuItem: Identifiable {
  let id: UUID
  let title: String
}

struct TrackTable<ID: Hashable & Sendable>: View {
  let rows: [SongRow<ID>]
  var nowPlayingID: ID?
  var onActivate: (([SongRow<ID>], [SongRow<ID>]) -> Void)?
  var onPlayNext: (([SongRow<ID>]) -> Void)?
  var onAddToUpNext: (([SongRow<ID>]) -> Void)?
  var onShowInFinder: (([SongRow<ID>]) -> Void)?
  var onSearchArtist: ((SongRow<ID>) -> Void)?
  var onSearchAlbum: ((SongRow<ID>) -> Void)?
  var onEditInfo: (([SongRow<ID>]) -> Void)?
  var isEditInfoEnabled: ((SongRow<ID>) -> Bool)?
  var onSetMediaKind: (([SongRow<ID>], LibraryMediaKind) -> Void)?
  var mediaKind: ((SongRow<ID>) -> LibraryMediaKind?)?
  var canSetMediaKind: ((SongRow<ID>, LibraryMediaKind) -> Bool)?
  var onSetFavorite: (([SongRow<ID>], Bool) -> Void)?
  var onSetRating: (([SongRow<ID>], Int) -> Void)?
  var playlistMenuItems: [PlaylistMenuItem] = []
  var onAddToPlaylist: (([SongRow<ID>], UUID) -> Void)?
  var onDelete: (([SongRow<ID>]) -> Void)?
  var allowsBulkDelete = true
  var deleteTitle = "Delete…"
  var mutationsDisabled = false
  var selectionBinding: Binding<Set<ID>>?
  var rowsForSelection: ((Set<ID>) -> [SongRow<ID>])?
  var searchText = ""
  var onClearSearch: (() -> Void)?

  @State private var localSelection: Set<ID> = []
  @State private var sortOrder = [
    KeyPathComparator(\SongRow<ID>.artist),
    KeyPathComparator(\SongRow<ID>.album),
    KeyPathComparator(\SongRow<ID>.title),
  ]
  @State private var sortedRows: [SongRow<ID>] = []
  @State private var sortGeneration: UInt64 = 0
  @State private var isSorting = true
  @AppStorage(Self.columnCustomizationKey, store: NightdriveDefaults.current)
  private var columnCustomization = TableColumnCustomization<SongRow<ID>>()

  static var columnCustomizationKey: String { "songTableColumns" }

  var body: some View {
    Table(
      sortedRows, selection: selection, sortOrder: $sortOrder,
      columnCustomization: $columnCustomization
    ) {
      identityColumns
      catalogColumns
      fileColumns
    }
    .alternatingRowBackgrounds(.disabled)
    .tableStyle(.bordered)
    .overlay {
      Rectangle()
        .strokeBorder(Bodywork.panel, lineWidth: 1)
        .allowsHitTesting(false)
    }
    .contextMenu(forSelectionType: ID.self) { ids in
      contextMenu(for: selectedRows(for: ids))
    } primaryAction: { ids in
      if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
        onActivate?([row], sortedRows)
      }
    }
    .task(id: sortGeneration) { await sortRows() }
    .onChange(of: rows) {
      sortGeneration &+= 1
      if selectionBinding == nil {
        localSelection.formIntersection(Set(rows.map(\.id)))
      }
    }
    .onChange(of: sortOrder) { sortGeneration &+= 1 }
    .trackCommands(
      selection: selection,
      visibleIDs: Set(rows.map(\.id)),
      mutationsDisabled: mutationsDisabled,
      canEditInfo: { ids in
        exactRows(for: ids).allSatisfy { isEditInfoEnabled?($0) ?? true }
      },
      editInfo: onEditInfo.map { edit in
        { ids in edit(exactRows(for: ids)) }
      }
    )
    .background(FixedTableRowHeights())
    .overlay {
      if isSorting {
        VStack(spacing: 8) {
          ProgressView()
          Text("Sorting songs…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if rows.isEmpty, !searchText.isEmpty, let onClearSearch {
        ContentUnavailableView {
          Label("No Results for “\(searchText)”", systemImage: "magnifyingglass")
        } description: {
          Text("Check the spelling, or clear the search to see every song here.")
        } actions: {
          Button("Clear Search") { onClearSearch() }
        }
      }
    }
  }

  private func sortRows() async {
    let requestedRows = rows
    let requestedOrder = sortOrder
    isSorting = !requestedRows.isEmpty
    let worker = Task.detached(priority: .userInitiated) {
      requestedRows.sorted(using: requestedOrder)
    }
    let sorted = await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
    guard !Task.isCancelled else { return }
    sortedRows = sorted
    isSorting = false
  }

  @TableColumnBuilder<SongRow<ID>, KeyPathComparator<SongRow<ID>>>
  private var identityColumns:
    some TableColumnContent<
      SongRow<ID>, KeyPathComparator<SongRow<ID>>
    >
  {
    TableColumn("Title", value: \.title) { row in
      HStack(spacing: 5) {
        if row.id == nowPlayingID {
          Image(systemName: "speaker.wave.2.fill")
            .font(.caption2)
            .foregroundStyle(.tint)
        }
        Text(row.title)
      }
    }
    .width(min: 140, ideal: 280)
    .customizationID("song.title")
    .disabledCustomizationBehavior(.visibility)

    TableColumn(SongTableColumn.time.title, value: \.durationMS) { row in
      Self.number(row.timeText)
    }
    .width(min: 44, ideal: 52, max: 68)
    .alignment(.trailing)
    .songColumn(.time)

    TableColumn(SongTableColumn.artist.title, value: \.artist)
      .width(min: 100, ideal: 180)
      .songColumn(.artist)
    TableColumn(SongTableColumn.album.title, value: \.album)
      .width(min: 100, ideal: 180)
      .songColumn(.album)
    TableColumn(SongTableColumn.genre.title, value: \.genre)
      .width(min: 80, ideal: 120)
      .songColumn(.genre)
    TableColumn(SongTableColumn.albumArtist.title, value: \.albumArtist)
      .width(min: 100, ideal: 160)
      .songColumn(.albumArtist)
    TableColumn(SongTableColumn.composer.title, value: \.composer)
      .width(min: 100, ideal: 160)
      .songColumn(.composer)
  }

  @TableColumnBuilder<SongRow<ID>, KeyPathComparator<SongRow<ID>>>
  private var catalogColumns:
    some TableColumnContent<
      SongRow<ID>, KeyPathComparator<SongRow<ID>>
    >
  {
    TableColumn(SongTableColumn.year.title, value: \.year) { row in
      Self.number(row.yearText)
    }
    .width(min: 44, ideal: 56, max: 80)
    .alignment(.trailing)
    .songColumn(.year)

    TableColumn(SongTableColumn.trackNumber.title, value: \.trackNumber) { row in
      Self.number(row.trackNumberText)
    }
    .width(min: 40, ideal: 48, max: 72)
    .alignment(.trailing)
    .songColumn(.trackNumber)

    TableColumn(SongTableColumn.discNumber.title, value: \.discNumber) { row in
      Self.number(row.discNumberText)
    }
    .width(min: 36, ideal: 44, max: 72)
    .alignment(.trailing)
    .songColumn(.discNumber)

    TableColumn(SongTableColumn.rating.title, value: \.rating) { row in
      Text(row.ratingText)
        .foregroundStyle(.secondary)
    }
    .width(min: 52, ideal: 68, max: 88)
    .songColumn(.rating)

    TableColumn(SongTableColumn.playCount.title, value: \.playCount) { row in
      Self.number(row.playCountText)
    }
    .width(min: 44, ideal: 52, max: 80)
    .alignment(.trailing)
    .songColumn(.playCount)

    TableColumn(SongTableColumn.lastPlayed.title, value: \.lastPlayedSortKey) { row in
      Self.timestamp(row.lastPlayedText)
    }
    .width(min: 96, ideal: 132, max: 200)
    .songColumn(.lastPlayed)

    TableColumn(SongTableColumn.bpm.title, value: \.bpm) { row in
      Self.number(row.bpmText)
    }
    .width(min: 40, ideal: 48, max: 72)
    .alignment(.trailing)
    .songColumn(.bpm)

    TableColumn(SongTableColumn.comment.title, value: \.comment)
      .width(min: 100, ideal: 180)
      .songColumn(.comment)
  }

  @TableColumnBuilder<SongRow<ID>, KeyPathComparator<SongRow<ID>>>
  private var fileColumns:
    some TableColumnContent<
      SongRow<ID>, KeyPathComparator<SongRow<ID>>
    >
  {
    TableColumn(SongTableColumn.kind.title, value: \.kind)
      .width(min: 80, ideal: 120, max: 200)
      .songColumn(.kind)

    TableColumn(SongTableColumn.size.title, value: \.sizeBytes) { row in
      Self.number(row.sizeText)
    }
    .width(min: 56, ideal: 72, max: 104)
    .alignment(.trailing)
    .songColumn(.size)

    TableColumn(SongTableColumn.bitrate.title, value: \.bitrate) { row in
      Self.number(row.bitrateText)
    }
    .width(min: 60, ideal: 76, max: 108)
    .alignment(.trailing)
    .songColumn(.bitrate)

    TableColumn(SongTableColumn.samplerate.title, value: \.samplerate) { row in
      Self.number(row.samplerateText)
    }
    .width(min: 68, ideal: 88, max: 120)
    .alignment(.trailing)
    .songColumn(.samplerate)

    TableColumn(SongTableColumn.dateModified.title, value: \.dateModifiedSortKey) { row in
      Self.timestamp(row.dateModifiedText)
    }
    .width(min: 96, ideal: 132, max: 200)
    .songColumn(.dateModified)

    TableColumn(SongTableColumn.location.title, value: \.location) { row in
      Text(row.location)
        .foregroundStyle(.secondary)
        .truncationMode(.head)
        .help(row.location)
    }
    .width(min: 120, ideal: 260)
    .songColumn(.location)
  }

  private static func number(_ text: String) -> some View {
    Text(text)
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private static func timestamp(_ text: String) -> some View {
    Text(text)
      .monospacedDigit()
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func contextMenu(for selectedRows: [SongRow<ID>]) -> some View {
    if let row = selectedRows.first {
      selectionContextMenu(for: selectedRows, primaryRow: row)
    }
  }

  @ViewBuilder
  private func selectionContextMenu(for selectedRows: [SongRow<ID>], primaryRow row: SongRow<ID>)
    -> some View
  {
    let multiple = selectedRows.count > 1
    let canEdit = onEditInfo != nil
    let canDelete = onDelete != nil && (!multiple || allowsBulkDelete)
    if let onActivate {
      Button(multiple ? String(localized: "Play Selection") : String(localized: "Play")) {
        onActivate(selectedRows, sortedRows)
      }
    }
    if let onPlayNext, !multiple {
      Button("Play Next") { onPlayNext([row]) }
    }
    if let onAddToUpNext {
      Button(
        multiple ? String(localized: "Add Selection to Up Next") : String(localized: "Add to Up Next")
      ) {
        onAddToUpNext(selectedRows)
      }
    }
    if onActivate != nil || onPlayNext != nil || onAddToUpNext != nil {
      Divider()
    }
    if let onShowInFinder {
      Button("Show in Finder") {
        onShowInFinder(selectedRows)
      }
    }
    if let onSearchArtist, !multiple {
      Button("Search for Artist") { onSearchArtist(row) }
        .disabled(row.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    if let onSearchAlbum, !multiple {
      Button("Search for Album") { onSearchAlbum(row) }
        .disabled(row.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    if onSetFavorite != nil || onSetRating != nil || onAddToPlaylist != nil {
      Divider()
    }
    if let onSetFavorite {
      let shouldFavorite = !selectedRows.allSatisfy(\.isFavorite)
      Button(
        shouldFavorite ? String(localized: "Add to Favorites") : String(localized: "Remove from Favorites")
      ) {
        onSetFavorite(selectedRows, shouldFavorite)
      }
      .disabled(mutationsDisabled)
    }
    if let onSetRating {
      Menu("Rating") {
        let current = row.rating
        Button("None") { onSetRating(selectedRows, 0) }
        Divider()
        ForEach(1...5, id: \.self) { rating in
          Button {
            onSetRating(selectedRows, rating)
          } label: {
            Label(
              rating == 1 ? String(localized: "1 Star") : String(localized: "\(rating) Stars"),
              systemImage: !multiple && current == rating ? "checkmark" : "star")
          }
        }
      }
      .disabled(mutationsDisabled)
    }
    if let onAddToPlaylist, !playlistMenuItems.isEmpty {
      Menu("Add to Playlist") {
        ForEach(playlistMenuItems) { playlist in
          Button(playlist.title) {
            onAddToPlaylist(selectedRows, playlist.id)
          }
        }
      }
      .disabled(mutationsDisabled)
    }
    if let onSetMediaKind, let mediaKind {
      let allAudiobooks = selectedRows.allSatisfy { mediaKind($0) == .audiobook }
      let targetKind: LibraryMediaKind = allAudiobooks ? .song : .audiobook
      Button(
        allAudiobooks
          ? String(localized: "Mark as Song")
          : String(localized: "Mark as Audiobook")
      ) {
        onSetMediaKind(selectedRows, targetKind)
      }
      .disabled(
        mutationsDisabled
          || !selectedRows.contains { canSetMediaKind?($0, targetKind) ?? true })
    }
    if canEdit || canDelete {
      Divider()
    }
    if canEdit {
      Button(
        multiple
          ? String(localized: "Edit Info for \(selectedRows.count) Songs…")
          : String(localized: "Edit Info…")
      ) {
        onEditInfo?(selectedRows)
      }
      .disabled(
        mutationsDisabled
          || selectedRows.contains { isEditInfoEnabled?($0) == false })
    }
    if canDelete {
      Button(
        multiple ? String(localized: "Move \(selectedRows.count) Songs to Trash…") : deleteTitle,
        role: .destructive
      ) {
        onDelete?(selectedRows)
      }
      .disabled(mutationsDisabled)
    }
  }

  private func selectedRows(for ids: Set<ID>) -> [SongRow<ID>] {
    let boundIDs = selection.wrappedValue
    let effectiveIDs = ids.isSubset(of: boundIDs) ? boundIDs : ids
    return exactRows(for: effectiveIDs)
  }

  private func exactRows(for ids: Set<ID>) -> [SongRow<ID>] {
    if let rowsForSelection {
      return rowsForSelection(ids)
    }
    return sortedRows.filter { ids.contains($0.id) }
  }

  private var selection: Binding<Set<ID>> {
    selectionBinding ?? $localSelection
  }

}

extension TableColumnContent {
  @MainActor
  func songColumn(
    _ column: SongTableColumn
  ) -> some TableColumnContent<TableRowValue, TableColumnSortComparator> {
    customizationID(column.customizationID)
      .defaultVisibility(column.isVisibleByDefault ? .visible : .hidden)
  }
}

private struct FixedTableRowHeights: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.isHidden = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    DispatchQueue.main.async { Self.pinRowHeight(near: view) }
  }

  private static func pinRowHeight(near probe: NSView) {
    guard let tableView = nearestTableView(from: probe),
      tableView.usesAutomaticRowHeights,
      tableView.numberOfRows > 0
    else { return }
    let measured =
      tableView.rowView(atRow: 0, makeIfNecessary: false)?.frame.height
      ?? (tableView.rect(ofRow: 0).height - tableView.intercellSpacing.height)
    guard measured > 0 else { return }
    tableView.rowHeight = measured
    tableView.usesAutomaticRowHeights = false
  }

  private static func nearestTableView(from probe: NSView) -> NSTableView? {
    var previous: NSView = probe
    var ancestor = probe.superview
    while let current = ancestor {
      var queue = current.subviews.filter { $0 !== previous }
      var index = 0
      while index < queue.count {
        if let table = queue[index] as? NSTableView { return table }
        queue.append(contentsOf: queue[index].subviews)
        index += 1
      }
      previous = current
      ancestor = current.superview
    }
    return nil
  }
}
