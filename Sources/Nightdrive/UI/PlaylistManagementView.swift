import SwiftUI
import UniformTypeIdentifiers

struct PlaylistManagementView: View {
  @Bindable var store: PlaylistStore
  let catalog: LibraryCatalog
  var trackSelection: Binding<Set<TrackID>>
  var onPlay: ((LibraryTrack, [LibraryTrack]) -> Void)?
  var onAddTracks: (([TrackID], UUID) throws -> Void)?
  var syncStatus: ((LocalPlaylist) -> PlaylistSyncDisplayStatus?)?
  var listeningFacts: [String: SmartRuleFacts]

  @Binding var selectedPlaylistID: UUID?
  @State private var showingCreate = false
  @State private var showingSmartCreate = false
  @State private var showingRuleEditor = false
  @State private var showingRename = false
  @State private var showingTrackPicker = false
  @State private var showingImport = false
  @State private var showingExport = false
  @State private var exportDocument: M3UPlaylistDocument?
  @State private var draftName = ""
  @State private var errorMessage: String?
  @State private var playlistPendingDeletion: LocalPlaylist?

  private static let m3uType = UTType(filenameExtension: "m3u") ?? .plainText

  init(
    store: PlaylistStore,
    catalog: LibraryCatalog,
    selectedPlaylistID: Binding<UUID?>,
    trackSelection: Binding<Set<TrackID>> = .constant([]),
    onPlay: ((LibraryTrack, [LibraryTrack]) -> Void)? = nil,
    onAddTracks: (([TrackID], UUID) throws -> Void)? = nil,
    syncStatus: ((LocalPlaylist) -> PlaylistSyncDisplayStatus?)? = nil,
    listeningFacts: [String: SmartRuleFacts] = [:]
  ) {
    self.store = store
    self.catalog = catalog
    self._selectedPlaylistID = selectedPlaylistID
    self.trackSelection = trackSelection
    self.onPlay = onPlay
    self.onAddTracks = onAddTracks
    self.syncStatus = syncStatus
    self.listeningFacts = listeningFacts
  }

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(
        String(localized: "Playlists"), subtitle: String(localized: "Your own and smart playlists"))
      Bodywork.Seam()
      HSplitView {
        playlistList
          .frame(minWidth: 180, idealWidth: 220)
        playlistDetail
          .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
          .overlay(alignment: .leading) {
            Bodywork.Seam(
              axis: .vertical, verticalHitPlacement: .insideLeadingEdge,
              showsSeparator: false)
          }
      }
    }
    .frame(minWidth: 650, minHeight: 420)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      if selectedPlaylistID == nil {
        selectedPlaylistID = store.playlists.first?.id
      }
      if let persistenceError = store.persistenceError {
        errorMessage = persistenceError
      }
    }
    .onChange(of: store.playlists) {
      if let selectedPlaylistID,
        !store.playlists.contains(where: { $0.id == selectedPlaylistID })
      {
        self.selectedPlaylistID = store.playlists.first?.id
      }
    }
    .onChange(of: store.persistenceError) {
      if let persistenceError = store.persistenceError {
        errorMessage = persistenceError
      }
    }
    .alert("New Playlist", isPresented: $showingCreate) {
      TextField("Playlist name", text: $draftName)
      Button("Cancel", role: .cancel) {}
      Button("Create") { createPlaylist() }
    }
    .confirmationDialog(
      "Delete “\(playlistPendingDeletion?.name ?? "")”?",
      isPresented: Binding(
        get: { playlistPendingDeletion != nil },
        set: { if !$0 { playlistPendingDeletion = nil } }),
      titleVisibility: .visible,
      presenting: playlistPendingDeletion
    ) { playlist in
      Button("Delete Playlist", role: .destructive) { delete(playlist.id) }
      Button("Cancel", role: .cancel) {}
    } message: { playlist in
      Text("The playlist “\(playlist.name)” is removed from the library. Its songs stay.")
    }
    .alert("Rename Playlist", isPresented: $showingRename) {
      TextField("Playlist name", text: $draftName)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { renamePlaylist() }
    }
    .alert("Playlist Couldn’t Be Changed", isPresented: errorPresented) {
      if store.canReloadDiscardingPendingChanges {
        Button("Discard Edits and Reload", role: .destructive) {
          Task {
            do {
              try store.reloadFromPersistence(discardingPendingChanges: true)
              errorMessage = nil
            } catch {
              errorMessage = error.localizedDescription
            }
          }
        }
      }
      Button("OK") {
        errorMessage = nil
        store.dismissPersistenceError()
      }
    } message: {
      Text(errorMessage ?? "")
    }
    .sheet(isPresented: $showingTrackPicker) {
      if let selectedPlaylistID {
        PlaylistTrackPickerView(
          library: catalog.tracks,
          initiallySelected: Set(
            store.playlist(withID: selectedPlaylistID)?.trackIDs ?? [])
        ) { ids in
          perform {
            if let onAddTracks {
              try onAddTracks(ids, selectedPlaylistID)
            } else {
              try store.add(ids, to: selectedPlaylistID)
            }
          }
        }
      }
    }
    .sheet(isPresented: $showingSmartCreate) {
      SmartRuleEditorView(
        title: String(localized: "New Smart Playlist"),
        confirmLabel: String(localized: "Create"), showsName: true
      ) { name, rule in
        perform {
          selectedPlaylistID = try store.createSmart(
            name: name, rule: rule, library: catalog.tracks, facts: listeningFacts)
        }
      }
    }
    .sheet(isPresented: $showingRuleEditor) {
      if let playlist = selectedPlaylist, let rule = playlist.smartRule {
        SmartRuleEditorView(
          title: String(localized: "Edit Rules"), confirmLabel: String(localized: "Save"),
          rule: rule
        ) { _, newRule in
          perform {
            try store.setSmartRule(
              newRule, for: playlist.id, library: catalog.tracks, facts: listeningFacts)
          }
        }
      }
    }
    .fileImporter(
      isPresented: $showingImport,
      allowedContentTypes: [Self.m3uType, .plainText],
      allowsMultipleSelection: false
    ) { result in
      importPlaylist(result)
    }
    .fileExporter(
      isPresented: $showingExport,
      document: exportDocument,
      contentType: Self.m3uType,
      defaultFilename: exportFilename
    ) { result in
      if case .failure(let error) = result {
        errorMessage = error.localizedDescription
      }
      exportDocument = nil
    }
    .clearsTrackSelection(trackSelection, when: store.playlists.isEmpty)
  }

  private var playlistList: some View {
    VStack(spacing: 0) {
      List(selection: playlistSelection) {
        ForEach(store.playlists) { playlist in
          Label {
            HStack {
              Text(playlist.name)
              Spacer()
              Text(verbatim: "\(playlist.trackIDs.count)")
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: playlist.smartRule == nil ? "music.note.list" : "gearshape")
              .foregroundStyle(VFD.accent)
          }
          .tag(playlist.id)
          .contextMenu {
            Button("Rename…") { beginRename(playlist) }
            if playlist.smartRule != nil {
              Button("Edit Rules…") {
                selectedPlaylistID = playlist.id
                showingRuleEditor = true
              }
            }
            Button("Delete…", role: .destructive) { playlistPendingDeletion = playlist }
          }
        }
      }
      Bodywork.Seam()
      HStack {
        Button {
          draftName = ""
          showingCreate = true
        } label: {
          Image(systemName: "plus")
        }
        .help("New Playlist")

        Button {
          showingSmartCreate = true
        } label: {
          Image(systemName: "gearshape")
        }
        .help("New Smart Playlist")

        Button {
          if let playlist = selectedPlaylist {
            beginRename(playlist)
          }
        } label: {
          Image(systemName: "pencil")
        }
        .disabled(selectedPlaylist == nil)
        .help("Rename Playlist")

        Button(role: .destructive) {
          if let playlist = selectedPlaylist { playlistPendingDeletion = playlist }
        } label: {
          Image(systemName: "minus")
        }
        .disabled(selectedPlaylist == nil)
        .help("Delete Playlist")
        Spacer()
        Button {
          showingImport = true
        } label: {
          Image(systemName: "square.and.arrow.down")
        }
        .help("Import M3U Playlist")
      }
      .buttonStyle(.borderless)
      .padding(8)
      .background(Bodywork.raised)
    }
    .background(Bodywork.well)
    .overlay(alignment: .trailing) {
      Bodywork.Seam(axis: .vertical, verticalHitPlacement: .insideTrailingEdge)
    }
  }

  @ViewBuilder
  private var playlistDetail: some View {
    if let playlist = selectedPlaylist {
      let memberTracks = playlist.trackIDs.map { catalog[$0] }
      let queue = memberTracks.compactMap { $0 }
      let isSmart = playlist.smartRule != nil
      VStack(spacing: 0) {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(playlist.name)
              .font(.headline)
            HStack(spacing: 6) {
              Text(memberSummary(total: playlist.trackIDs.count, available: queue.count))
              if let status = syncStatus?(playlist) {
                Text(verbatim: "·")
                Text(status.label)
                  .foregroundStyle(status == .synced ? AnyShapeStyle(VFD.accent) : AnyShapeStyle(.secondary))
              }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let rule = playlist.smartRule {
              Label(rule.summary, systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Toggle(
              "Sync to iPod",
              isOn: Binding(
                get: { playlist.syncEnabled },
                set: { enabled in
                  perform { try store.setSyncEnabled(enabled, for: playlist.id) }
                })
            )
            .toggleStyle(.checkbox)
            .font(.caption)
          }
          Spacer()
          Button("Export M3U…") { prepareExport(playlist) }
          if isSmart {
            Button("Edit Rules…") { showingRuleEditor = true }
          } else {
            Button("Add Songs…") { showingTrackPicker = true }
          }
          Button("Play") { playSelection(queue: queue) }
            .disabled(queue.isEmpty)
        }
        .padding(.leading, 20)
        .padding(.trailing, ChassisMetrics.edgeInset)
        .padding(.vertical, 12)
        .background(Bodywork.raised)
        Bodywork.Seam()
        List(selection: trackSelection) {
          ForEach(Array(zip(playlist.trackIDs, memberTracks)), id: \.0) { id, track in
            PlaylistMemberRow(track: track, id: id)
              .tag(id)
              .contextMenu {
                if !isSmart {
                  Button("Remove from Playlist", role: .destructive) {
                    perform { try store.remove(id, from: playlist.id) }
                  }
                }
              }
          }
          .onMove { offsets, destination in
            guard !isSmart else { return }
            perform {
              try store.move(from: offsets, to: destination, in: playlist.id)
            }
          }
          .onDelete { offsets in
            guard !isSmart else { return }
            perform { try store.remove(at: offsets, from: playlist.id) }
          }
        }
        .trackCommands(
          selection: trackSelection,
          visibleIDs: Set(playlist.trackIDs))
        Bodywork.Seam()
        HStack {
          if !isSmart {
            Button("Remove", role: .destructive) {
              perform {
                try store.remove(Array(selectedMemberIDs), from: playlist.id)
                trackSelection.wrappedValue.subtract(selectedMemberIDs)
              }
            }
            .disabled(selectedMemberIDs.isEmpty)
          }
          Spacer()
          Text(
            isSmart
              ? String(localized: "Membership follows the rules")
              : String(localized: "Drag songs to reorder")
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Bodywork.raised)
      }
    } else {
      ContentUnavailableView {
        Label("No Playlist Selected", systemImage: "music.note.list")
      } description: {
        Text("Create a playlist to arrange songs in your own order.")
      } actions: {
        Button("New Playlist…") {
          draftName = ""
          showingCreate = true
        }
      }
    }
  }

  private var selectedPlaylist: LocalPlaylist? {
    selectedPlaylistID.flatMap(store.playlist(withID:))
  }

  private var playlistSelection: Binding<UUID?> {
    Binding(
      get: { selectedPlaylistID },
      set: { selectedPlaylistID = $0 ?? store.playlists.first?.id })
  }

  private var selectedMemberIDs: Set<TrackID> {
    guard let selectedPlaylist else { return [] }
    return Set(
      selectedPlaylist.trackIDs.filter {
        trackSelection.wrappedValue.contains($0)
      })
  }

  private var errorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: {
        if !$0 {
          errorMessage = nil
          store.dismissPersistenceError()
        }
      })
  }

  private func memberSummary(total: Int, available: Int) -> String {
    if available == total {
      return total == 1 ? String(localized: "1 song") : String(localized: "\(total) songs")
    }
    return String(localized: "\(available) of \(total) songs available")
  }

  private func playSelection(queue: [LibraryTrack]) {
    guard !queue.isEmpty else { return }
    let selectedID = selectedMemberIDs.first
    let first =
      selectedID.flatMap { id in
        queue.first { $0.id == id }
      } ?? queue[0]
    onPlay?(first, queue)
  }

  private func createPlaylist() {
    perform {
      selectedPlaylistID = try store.create(name: draftName)
    }
  }

  private func beginRename(_ playlist: LocalPlaylist) {
    draftName = playlist.name
    showingRename = true
  }

  private func renamePlaylist() {
    guard let selectedPlaylistID else { return }
    perform { try store.rename(selectedPlaylistID, to: draftName) }
  }

  private func delete(_ playlistID: UUID) {
    perform { try store.delete(playlistID) }
  }

  private var exportFilename: String {
    let name = selectedPlaylist?.name ?? String(localized: "Playlist")
    return name.replacingOccurrences(of: "/", with: "-") + ".m3u"
  }

  private func importPlaylist(_ result: Result<[URL], Error>) {
    do {
      guard let url = try result.get().first else { return }
      let isScoped = url.startAccessingSecurityScopedResource()
      defer {
        if isScoped { url.stopAccessingSecurityScopedResource() }
      }
      let data = try Data(contentsOf: url)
      let name = url.deletingPathExtension().lastPathComponent
      selectedPlaylistID = try store.importM3U(
        data,
        named: name,
        relativeTo: url.deletingLastPathComponent())
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func prepareExport(_ playlist: LocalPlaylist) {
    do {
      exportDocument = M3UPlaylistDocument(data: try store.exportM3U(playlist.id))
      showingExport = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func perform(_ operation: () throws -> Void) {
    attempt(operation) { errorMessage = $0 }
  }
}

private struct M3UPlaylistDocument: FileDocument {
  static var readableContentTypes: [UTType] {
    [UTType(filenameExtension: "m3u") ?? .plainText]
  }

  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct PlaylistMemberRow: View {
  let track: LibraryTrack?
  let id: TrackID

  var body: some View {
    HStack {
      VStack(alignment: .leading) {
        Text(
          track?.displayTitle
            ?? id.fileURL?.deletingPathExtension().lastPathComponent
            ?? id.rawValue)
        Text(
          track.map { [$0.artist, $0.album].filter { !$0.isEmpty }.joined(separator: " — ") }
            ?? String(localized: "File not currently in the library")
        )
        .font(.caption)
        .foregroundStyle(track == nil ? .red : .secondary)
      }
      Spacer()
      if let track {
        Text(LibraryTrack.formatDuration(ms: track.durationMS))
          .monospacedDigit()
          .foregroundStyle(.secondary)
      } else {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.red)
      }
    }
  }
}

private struct PlaylistTrackPickerView: View {
  @Environment(\.dismiss) private var dismiss
  let library: [LibraryTrack]
  let initiallySelected: Set<TrackID>
  let onAdd: ([TrackID]) -> Void

  @State private var selection: Set<TrackID>
  @State private var searchText = ""
  @State private var filterCache = FilteredTracksCache()

  init(
    library: [LibraryTrack],
    initiallySelected: Set<TrackID>,
    onAdd: @escaping ([TrackID]) -> Void
  ) {
    self.library = library
    self.initiallySelected = initiallySelected
    self.onAdd = onAdd
    _selection = State(initialValue: initiallySelected)
  }

  var body: some View {
    VStack(spacing: 0) {
      List(filteredTracks, selection: $selection) { track in
        VStack(alignment: .leading) {
          Text(track.displayTitle)
          Text(track.artist)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tag(track.id)
      }
      .searchable(text: $searchText, prompt: "Search songs")
      Divider()
      HStack {
        Text("\(selection.count) selected")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Add") {
          onAdd(
            orderedPlaylistPickerAdditions(
              library: library,
              selection: selection,
              initiallySelected: initiallySelected))
          dismiss()
        }
        .buttonStyle(.lit)
        .disabled(
          orderedPlaylistPickerAdditions(
            library: library,
            selection: selection,
            initiallySelected: initiallySelected
          ).isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 520, minHeight: 480)
  }

  private var filteredTracks: [LibraryTrack] {
    guard !searchText.isEmpty else { return library }
    return filterCache.tracks(matching: searchText, in: library)
  }
}

private final class FilteredTracksCache {
  private var searchText: String?
  private var library: [LibraryTrack] = []
  private var results: [LibraryTrack] = []

  func tracks(matching searchText: String, in library: [LibraryTrack]) -> [LibraryTrack] {
    if searchText != self.searchText || library != self.library {
      self.searchText = searchText
      self.library = library
      results = library.filter {
        $0.displayTitle.localizedCaseInsensitiveContains(searchText)
          || $0.artist.localizedCaseInsensitiveContains(searchText)
          || $0.album.localizedCaseInsensitiveContains(searchText)
      }
    }
    return results
  }
}

func orderedPlaylistPickerAdditions(
  library: [LibraryTrack],
  selection: Set<TrackID>,
  initiallySelected: Set<TrackID>
) -> [TrackID] {
  var emittedIDs: Set<TrackID> = []
  return library.compactMap { track in
    guard selection.contains(track.id), !initiallySelected.contains(track.id),
      emittedIDs.insert(track.id).inserted
    else { return nil }
    return track.id
  }
}
