import AppKit
import SwiftUI

@MainActor
func ejectErrorPresentationBinding(for manager: DeviceManager) -> Binding<Bool> {
  Binding(
    get: { manager.ejectError != nil },
    set: { if !$0 { manager.dismissEjectError() } })
}

struct ContentView: View {
  @Bindable var app: AppState

  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var infoEditor: LibraryInfoEditor?
  @State private var albumLookup: AlbumLookupRequest?
  @State private var listeningSection = ListeningHistoryView.Section.favorites
  @State private var libraryTableCache = LibraryView.TableModelCache()
  @State private var artistTableCache = LibraryView.TableModelCache()
  @State private var albumTableCache = LibraryView.TableModelCache()
  @State private var genreTableCache = LibraryView.TableModelCache()
  @State private var audiobooksTableCache = LibraryView.TableModelCache()
  @State private var artistSelection: Set<LibraryCollection.ID> = []
  @State private var albumSelection: Set<LibraryCollection.ID> = []
  @State private var genreSelection: Set<LibraryCollection.ID> = []
  @State private var audiobookSelection: Set<LibraryCollection.ID> = []
  @State private var artworkCache = LibraryArtworkCache()
  @State private var quickSearchMusic = QuickSearchMusicModel()
  @State private var librarySearchFilter = LibraryTrackFilterModel()
  @State private var defaultAudioAppFailure: DefaultAudioAppChangeFailure?

  var body: some View {
    let selectedLibraryTracks = selectedLibraryTracks()
    let deckContentSpacing = DeckMechanism.contentSpacing(app.deck.progress)
    let enqueuesAudioDrops = app.selection == .upNext
    NavigationSplitView(columnVisibility: $columnVisibility) {
      sidebar
    } detail: {
      VStack(spacing: 0) {
        detail
        if app.selectedTrackIDs.count > 1 {
          selectionBar(selectedLibraryTracks)
        }
        statusBar
      }
      .toolbar(removing: .title)
    }
    .animation(.default, value: columnVisibility)
    .modifier(DeckAwareTopPadding(progress: app.deck.progress))
    .overlay(alignment: .top) {
      HeadUnitBar(app: app) {
        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
      }
    }
    .overlay(alignment: .topTrailing) {
      if app.selection == .listening {
        listeningSectionPicker
          .frame(height: max(0, ListeningHistoryView.headerHeight - deckContentSpacing))
          .modifier(DeckAwareTopPadding(progress: app.deck.progress))
          .padding(.trailing, ChassisMetrics.edgeInset)
      }
    }
    .environment(\.deckContentSpacing, deckContentSpacing)
    .ignoresSafeArea(.container, edges: .top)
    .scrollContentBackground(.hidden)
    .background(Bodywork.panel)
    .tint(VFD.accent)
    .overlay {
      if app.isQuickSearchPresented {
        QuickSearchPalette(app: app, music: quickSearchMusic)
      }
    }
    .demoOverlays(app: app)
    .frame(minWidth: 900, minHeight: 540)
    .audioFileDropTarget(
      prompt: enqueuesAudioDrops
        ? String(localized: "Drop to Add to Up Next") : String(localized: "Drop to Play"),
      accessibilityHint: enqueuesAudioDrops
        ? String(localized: "Release to add the audio files and folders to Up Next")
        : String(localized: "Release to play the audio files and folders")
    ) { urls in
      Task {
        if enqueuesAudioDrops {
          await app.enqueueDroppedAudioFiles(urls)
        } else {
          await app.playDroppedAudioFiles(urls)
        }
      }
    }
    .sheet(item: $infoEditor) { editor in
      switch editor {
      case .single(let track):
        TrackInfoEditor(
          metadata: TrackMetadata(track),
          fileInfo: TrackFileInfo(track),
          fileURL: track.url,
          musicBrainzLookup: MusicBrainzLookupContext(
            policy: app.onlineServices, service: app.musicBrainz),
          genreSuggestions: GenreMetadata.libraryValues(from: app.library.tracks)
        ) { metadata, artworkChange in
          try await app.library.updateMetadata(
            for: track, to: metadata, artworkChange: artworkChange)
          if let updated = app.library.catalog[track.id] {
            app.player.replaceTrack(updated)
          }
        }
      case .multiple(let tracks):
        BulkTrackInfoEditor(
          metadata: tracks.map(TrackMetadata.init),
          genreSuggestions: GenreMetadata.libraryValues(from: app.library.tracks)
        ) { changes in
          let selectedIDs = Set(tracks.map(\.id))
          try await app.library.updateMetadata(for: tracks, applying: changes)
          for track in app.library.tracks where selectedIDs.contains(track.id) {
            app.player.replaceTrack(track)
          }
        }
      }
    }
    .sheet(isPresented: $app.isSyncDetailsPresented) {
      if let result = app.latestSyncResult {
        SyncDetailsView(result: result)
      }
    }
    .sheet(isPresented: $app.isFindDuplicatesPresented) {
      let identity = app.library.identityRevision
      FindDuplicatesSheet(
        tracks: { app.library.tracks },
        libraryFolder: app.library.folderURL
      ) { resolutions in
        await app.resolveDuplicateTracks(resolutions, expectedLibraryIdentity: identity)
      }
    }
    .sheet(isPresented: $app.isCleanUpGenresPresented) {
      CleanUpGenresSheet(
        tracks: { app.library.tracks },
        musicBrainz: app.musicBrainz,
        genreSuggestions: GenreMetadata.libraryValues(from: app.library.tracks)
      ) { edits in
        try await app.applyGenreCleanup(edits)
      }
    }
    .sheet(isPresented: $app.isFindMetadataProblemsPresented) {
      let identity = app.library.identityRevision
      FindMetadataProblemsSheet(
        tracks: { app.library.tracks },
        libraryFolder: app.library.folderURL,
        musicBrainzLookup: MusicBrainzLookupContext(
          policy: app.onlineServices, service: app.musicBrainz)
      ) { edits in
        try await app.applyMetadataProblemCorrections(
          edits, expectedLibraryIdentity: identity)
      } onEdit: { track, metadata, artworkChange in
        try await app.library.updateMetadata(
          for: track, to: metadata, artworkChange: artworkChange)
        if let updated = app.library.catalog[track.id] {
          app.player.replaceTrack(updated)
        }
      }
    }
    .sheet(isPresented: $app.isOrganizeLibraryPresented) {
      if let folder = app.library.folderURL {
        let identity = app.library.identityRevision
        OrganizeLibrarySheet(
          tracks: { app.library.tracks },
          libraryFolder: folder
        ) { changes in
          await app.organizeLibraryTracks(changes, expectedLibraryIdentity: identity)
        }
      }
    }
    .alert(
      "Make Nightdrive Your Default Music Player?",
      isPresented: Binding(
        get: { app.defaultAudioApp.isPromptPresented },
        set: { if !$0 { app.defaultAudioApp.declinePrompt() } })
    ) {
      Button("Make Default") {
        Task { defaultAudioAppFailure = await app.defaultAudioApp.makeDefault() }
      }
      Button("Keep Current Defaults", role: .cancel) { app.defaultAudioApp.declinePrompt() }
    } message: {
      Text(
        String(
          localized:
            "Supported audio files you double-click in Finder will open in Nightdrive. macOS may ask you to confirm each audio format. You can change this later in Settings."
        ))
    }
    .alert(item: $defaultAudioAppFailure) { failure in
      Alert(
        title: Text(failure.title),
        message: Text(failure.message),
        dismissButton: .default(Text("OK")))
    }
    .alert(
      "Sync ledger couldn’t be read",
      isPresented: Binding(
        get: { app.isSyncLedgerRecoveryPromptPresented },
        set: { if !$0 { app.dismissSyncLedgerRecoveryPromptPresentation() } })
    ) {
      Button("Use Empty Ledger", role: .destructive) {
        app.assumeEmptySyncLedger()
      }
      Button("Abort", role: .cancel) { app.abortSyncLedgerRecovery() }
    } message: {
      if let prompt = app.syncLedgerRecoveryPrompt {
        Text(
          prompt.message
            + "\n\nUsing an empty ledger can duplicate copies and change which songs are eligible for removal. The current file will be preserved at \(prompt.quarantinePath). Review the refreshed sync settings before syncing again."
        )
      }
    }
    .alert(
      "Sync settings couldn’t be saved",
      isPresented: Binding(
        get: { app.syncSettingsError != nil },
        set: { if !$0 { app.dismissSyncSettingsError() } })
    ) {
      Button("OK") { app.dismissSyncSettingsError() }
    } message: {
      Text(app.syncSettingsError ?? "")
    }
    .alert(
      "Library folder couldn’t be selected",
      isPresented: Binding(
        get: { app.libraryFolderError != nil },
        set: { if !$0 { app.dismissLibraryFolderError() } })
    ) {
      Button("OK") { app.dismissLibraryFolderError() }
    } message: {
      Text(app.libraryFolderError ?? "")
    }
    .alert(
      "Listening history couldn’t be saved",
      isPresented: Binding(
        get: {
          app.listeningHistoryError != nil || app.listeningHistory.persistenceError != nil
        },
        set: {
          if !$0 {
            app.dismissListeningHistoryError()
            app.listeningHistory.dismissPersistenceError()
          }
        })
    ) {
      if app.listeningHistory.canReloadDiscardingPendingChanges {
        Button("Discard Edits and Reload", role: .destructive) {
          Task { app.reloadListeningHistoryDiscardingPendingChanges() }
        }
      }
      Button("OK") {
        app.dismissListeningHistoryError()
        app.listeningHistory.dismissPersistenceError()
      }
    } message: {
      Text(app.listeningHistoryError ?? app.listeningHistory.persistenceError ?? "")
    }
    .alert(
      "iPod couldn’t be ejected",
      isPresented: ejectErrorPresentationBinding(for: app.deviceManager)
    ) {
      Button("OK") {}
    } message: {
      Text(app.deviceManager.ejectError ?? "")
    }
    .musicBrainzAlbumLookup($albumLookup, app: app)
    .onChange(of: app.editInfoRequest) {
      presentInfoEditor()
    }
    .onChange(of: app.editInfoDismissRequest) {
      infoEditor = nil
      albumLookup = nil
    }
    .onChange(of: app.library.identityRevision) {
      infoEditor = nil
      albumLookup = nil
      app.isFindDuplicatesPresented = false
      app.isCleanUpGenresPresented = false
      app.isFindMetadataProblemsPresented = false
      app.isOrganizeLibraryPresented = false
      artistSelection.removeAll()
      albumSelection.removeAll()
      genreSelection.removeAll()
    }
    .onChange(of: app.library.tracks) {
      app.selectedTrackIDs.formIntersection(app.library.tracks.map(\.id))
    }
  }

  private var listeningSectionPicker: some View {
    Picker("Listening section", selection: $listeningSection) {
      ForEach(ListeningHistoryView.Section.allCases) { section in
        Text(section.rawValue).tag(section)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }

  private var sidebar: some View {
    List(selection: $app.selection) {
      Section("Library") {
        row("Music", "music.note", .library)
        row("Artists", "music.mic", .artists)
        row("Albums", "square.stack", .albums)
        row("Genres", "guitars", .genres)
        row("Audiobooks", "books.vertical", .audiobooks)
        row("Podcasts", "antenna.radiowaves.left.and.right", .podcasts)
        row("Up Next", "text.line.last.and.arrowtriangle.forward", .upNext)
        row("Listening", "heart", .listening)
        row(
          "Suggestions", "sparkles", .suggestions,
          badge: app.musicBrainzSuggestions.suggestions.count)
      }
      Section("Playlists") {
        row("All Playlists", "music.note.list", .playlists)
      }
      Section("Devices") {
        if app.deviceManager.devices.isEmpty {
          Text("Connect an iPod")
            .foregroundStyle(.tertiary)
        }
        ForEach(app.deviceManager.devices) { device in
          HStack {
            sidebarLabel(app.displayName(for: device), "ipod")
            Spacer()
            Button {
              Task { await app.deviceManager.eject(device) }
            } label: {
              Image(systemName: "eject.fill")
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Eject \(app.displayName(for: device))")
          }
          .demoTarget("sidebar.device.\(device.volumeURL.lastPathComponent)") {
            app.selection = .device(device.volumeURL)
          }
          .tag(SidebarItem.device(device.volumeURL))
        }
      }
    }
    .navigationSplitViewColumnWidth(min: 170, ideal: 200)
    .background(Bodywork.well)
    .overlay(alignment: .trailing) {
      Bodywork.Seam(axis: .vertical)
        .ignoresSafeArea(.container, edges: .top)
    }
    .toolbar(removing: .sidebarToggle)
  }

  private func row(
    _ title: String, _ symbol: String, _ item: SidebarItem, badge: Int = 0
  ) -> some View {
    // The badge must come before .tag: modifiers applied after it hide the
    // tag trait from the List, leaving the row unselectable.
    sidebarLabel(title, symbol)
      .badge(badge)
      .demoTarget(Self.demoTargetID(for: item)) { app.selection = item }
      .tag(item)
  }

  private static func demoTargetID(for item: SidebarItem) -> String {
    switch item {
    case .library: "sidebar.music"
    case .artists: "sidebar.artists"
    case .albums: "sidebar.albums"
    case .genres: "sidebar.genres"
    case .audiobooks: "sidebar.audiobooks"
    case .upNext: "sidebar.upNext"
    case .playlists: "sidebar.playlists"
    case .listening: "sidebar.listening"
    case .suggestions: "sidebar.suggestions"
    case .podcasts: "sidebar.podcasts"
    case .device(let url): "sidebar.device.\(url.lastPathComponent)"
    }
  }

  private func sidebarLabel(_ title: String, _ symbol: String) -> some View {
    Label {
      Text(title)
    } icon: {
      Image(systemName: symbol).foregroundStyle(VFD.accent)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch app.selection {
    case .artists:
      LibraryBrowserView(
        app: app,
        kind: .artist,
        selectedCollectionIDs: $artistSelection,
        tableModelCache: artistTableCache,
        searchFilter: librarySearchFilter,
        artworkCache: artworkCache)
    case .albums:
      LibraryBrowserView(
        app: app,
        kind: .album,
        selectedCollectionIDs: $albumSelection,
        tableModelCache: albumTableCache,
        searchFilter: librarySearchFilter,
        artworkCache: artworkCache)
    case .genres:
      LibraryBrowserView(
        app: app,
        kind: .genre,
        selectedCollectionIDs: $genreSelection,
        tableModelCache: genreTableCache,
        searchFilter: librarySearchFilter,
        artworkCache: artworkCache)
    case .audiobooks:
      LibraryBrowserView(
        app: app,
        kind: .audiobook,
        selectedCollectionIDs: $audiobookSelection,
        tableModelCache: audiobooksTableCache,
        searchFilter: librarySearchFilter,
        artworkCache: artworkCache)
    case .upNext:
      UpNextView(player: app.player, trackSelection: $app.selectedTrackIDs) { name, tracks in
        _ = try app.createPlaylist(name: name, tracks: tracks)
      }
    case .playlists:
      PlaylistManagementView(
        store: app.playlists,
        catalog: app.library.catalog,
        selectedPlaylistID: $app.selectedPlaylistID,
        trackSelection: $app.selectedTrackIDs,
        onPlay: { track, queue in
          app.player.play(track, in: queue)
        },
        onAddTracks: { ids, playlistID in
          try app.addToPlaylist(ids, playlistID: playlistID)
        },
        syncStatus: { playlist in
          app.playlistSyncDisplayStatus(for: playlist)
        },
        listeningFacts: app.smartRuleFacts
      )
      .disabled(app.libraryMutationsDisabled)
    case .listening:
      ListeningHistoryView(
        store: app.listeningHistory,
        catalog: app.library.catalog,
        section: $listeningSection,
        trackSelection: $app.selectedTrackIDs,
        mutationsDisabled: app.libraryMutationsDisabled,
        onToggleFavorite: { try app.toggleFavorite(for: $0) },
        onSetRating: { try app.setRating($0, for: [$1]) },
        onResetStatistics: { try app.resetListeningStatistics(for: $0) },
        onPlay: { track in app.player.play(track, in: app.library.tracks) })
    case .suggestions:
      MusicBrainzInboxView(app: app)
    case .podcasts:
      PodcastsView(app: app)
    case .device:
      if let device = app.selectedDevice {
        DeviceView(app: app, device: device)
      } else {
        LibraryView(
          app: app, tableModelCache: libraryTableCache, searchFilter: librarySearchFilter
        )
        .onAppear { app.selection = .library }
      }
    default:
      LibraryView(app: app, tableModelCache: libraryTableCache, searchFilter: librarySearchFilter)
    }
  }

  private var statusBar: some View {
    HStack(spacing: 8) {
      Spacer()
      if let progress = app.library.scanProgress {
        if let fraction = progress.fractionCompleted {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .frame(width: 72)
        } else {
          ProgressView().controlSize(.mini)
        }
        Text(progress.statusText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
        Button("Cancel") { app.library.cancelScan() }
          .buttonStyle(.borderless)
          .controlSize(.small)
      } else if app.library.scanState == .cancelled {
        Text("Library scan canceled — rescan to use the library")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(statsText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .padding(.vertical, 6)
    .background(Bodywork.raised)
    .overlay(alignment: .top) { Bodywork.Seam() }
  }

  private func selectionBar(_ selectedLibraryTracks: [LibraryTrack]) -> some View {
    HStack(spacing: 12) {
      Label(
        selectedLibraryTracks.count == 1
          ? String(localized: "1 song selected")
          : String(localized: "\(selectedLibraryTracks.count) songs selected"),
        systemImage: "checkmark.circle.fill"
      )
      .font(.callout.weight(.medium))
      if selectedLibraryTracks.count != app.selectedTrackIDs.count {
        Text("Some selected songs are no longer in the library")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Clear Selection") { app.selectedTrackIDs.removeAll() }
      Button("Look Up Album…") { albumLookup = AlbumLookupRequest(tracks: selectedLibraryTracks) }
        .disabled(
          app.libraryMutationsDisabled
            || !canEditInfo(selectedLibraryTracks)
            || !AlbumLookupRequest.canLookUp(selectedLibraryTracks)
        )
        .help(
          AlbumLookupRequest.canLookUp(selectedLibraryTracks)
            ? String(localized: "Match the selected songs against a MusicBrainz release")
            : String(localized: "Album lookup needs a selection of MP3s that share one album"))
      Button(editInfoTitle(for: selectedLibraryTracks.count)) { app.requestEditInfo() }
        .buttonStyle(.lit)
        .disabled(app.libraryMutationsDisabled || !canEditInfo(selectedLibraryTracks))
        .help(editInfoHelp(selectedLibraryTracks))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Bodywork.raised)
    .overlay(alignment: .top) { Bodywork.Seam() }
  }

  private func selectedLibraryTracks() -> [LibraryTrack] {
    app.library.catalog.tracksInLibraryOrder(for: app.selectedTrackIDs)
  }

  private func canEditInfo(_ selectedLibraryTracks: [LibraryTrack]) -> Bool {
    !selectedLibraryTracks.isEmpty
      && selectedLibraryTracks.count == app.selectedTrackIDs.count
      && selectedLibraryTracks.allSatisfy(\.supportsMetadataEditing)
  }

  private func editInfoHelp(_ selectedLibraryTracks: [LibraryTrack]) -> String {
    if selectedLibraryTracks.isEmpty {
      return String(localized: "Select one or more songs to edit")
    }
    if !selectedLibraryTracks.allSatisfy(\.supportsMetadataEditing) {
      return String(
        localized:
          "Bulk metadata editing is available only when every selected song is an MP3 or MPEG-4 file")
    }
    if selectedLibraryTracks.count == 1 {
      return String(localized: "Edit this song's metadata and artwork")
    }
    return String(localized: "Change selected metadata fields for all selected songs")
  }

  private func presentInfoEditor() {
    let tracks = selectedLibraryTracks()
    guard canEditInfo(tracks) else { return }
    infoEditor = tracks.count == 1 ? .single(tracks[0]) : .multiple(tracks)
  }

  private var statsText: String {
    switch app.selection {
    case .artists:
      let count = app.library.collections(for: .artist).count
      return count == 1 ? String(localized: "1 artist") : String(localized: "\(count) artists")
    case .albums:
      let count = app.library.collections(for: .album).count
      return count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums")
    case .genres:
      let count = app.library.collections(for: .genre).count
      return count == 1 ? String(localized: "1 genre") : String(localized: "\(count) genres")
    case .upNext:
      let count = app.player.upNextTracks.count
      return count == 1
        ? String(localized: "1 song up next") : String(localized: "\(count) songs up next")
    case .playlists:
      let count = app.playlists.playlists.count
      return count == 1
        ? String(localized: "1 playlist") : String(localized: "\(count) playlists")
    case .listening:
      switch listeningSection {
      case .favorites:
        let count = app.listeningHistory.favoriteTracks(from: app.library.tracks).count
        return count == 1
          ? String(localized: "1 favorite") : String(localized: "\(count) favorites")
      case .recent:
        let count = app.listeningHistory.recentTracks(from: app.library.catalog).count
        return count == 1
          ? String(localized: "1 recent play") : String(localized: "\(count) recent plays")
      }
    case .device:
      guard let device = app.selectedDevice else { return "" }
      return libraryStatsText(
        count: device.tracks.count, durationMS: device.trackDurationMS,
        sizeBytes: Int(device.usedByAudioBytes))
    case .suggestions:
      let count = app.musicBrainzSuggestions.suggestions.count
      return count == 1
        ? String(localized: "1 album suggestion")
        : String(localized: "\(count) album suggestions")
    case .podcasts:
      let count = app.podcasts.subscriptions.count
      return count == 1
        ? String(localized: "1 podcast") : String(localized: "\(count) podcasts")
    default:
      let stats = app.library.totalStats
      return libraryStatsText(
        count: stats.count, durationMS: stats.durationMS, sizeBytes: stats.sizeBytes)
    }
  }
}

private enum LibraryInfoEditor: Identifiable {
  case single(LibraryTrack)
  case multiple([LibraryTrack])

  var id: String {
    switch self {
    case .single(let track):
      "single-\(track.id.rawValue)"
    case .multiple(let tracks):
      "multiple-\(tracks.map(\.id.rawValue).joined(separator: "|"))"
    }
  }
}

struct LibraryView: View {
  @Bindable var app: AppState
  var scopedTracks: [LibraryTrack]? = nil
  var trackSelection: Binding<Set<TrackID>>? = nil
  fileprivate let tableModelCache: TableModelCache
  let searchFilter: LibraryTrackFilterModel
  @State private var trackAlert: LibraryTrackAlert?

  private struct FilterRequest: Equatable {
    let query: String
    let libraryRevision: UInt64
  }

  var body: some View {
    let model = tableModel
    return Group {
      if app.library.folderURL == nil {
        ContentUnavailableView {
          Label("Choose your music folder", systemImage: "folder.badge.plus")
        } description: {
          Text(
            "Choose a music folder for your library, or drop audio files and folders here to play them without changing your library."
          )
        } actions: {
          Button("Choose Folder…") { app.chooseLibraryFolder() }
            .buttonStyle(.lit)
            .keyboardShortcut("o")
        }
      } else {
        TrackTable(
          rows: model.rows,
          visibleRowIDs: model.visibleRowIDs,
          nowPlayingID: app.player.currentTrack?.id,
          onActivate: { selectedRows, visibleRows in
            let selectedTracks = model.tracks(for: selectedRows)
            if let first = selectedTracks.first {
              app.player.play(
                first,
                in: selectedRows.count > 1 ? selectedTracks : model.tracks(for: visibleRows))
            }
          },
          onPlayNext: { selectedRows in
            if let track = selectedRows.first.flatMap(model.track(for:)) {
              app.player.playNext(track)
            }
          },
          onAddToUpNext: { selectedRows in
            for track in model.tracks(for: selectedRows) {
              app.player.addToUpNext(track)
            }
          },
          onShowInFinder: { selectedRows in
            NSWorkspace.shared.activateFileViewerSelecting(
              model.tracks(for: selectedRows).map(\.url))
          },
          onSearchArtist: { row in search(for: row.artist) },
          onSearchAlbum: { row in search(for: row.album) },
          onEditInfo: { rows in app.requestEditInfo(for: Set(rows.map(\.id))) },
          isEditInfoEnabled: { row in model.track(for: row)?.supportsMetadataEditing == true },
          onSetMediaKind: { selectedRows, kind in
            let tracks = model.tracks(for: selectedRows)
            let libraryIdentity = app.library.identityRevision
            Task {
              guard app.library.identityRevision == libraryIdentity else { return }
              do {
                try await app.setMediaKind(kind, for: tracks)
              } catch {
                trackAlert = .error(error.localizedDescription)
              }
            }
          },
          mediaKind: { row in model.track(for: row)?.mediaKind },
          canSetMediaKind: { row, kind in
            model.track(for: row).map { AppState.canSetMediaKind(kind, for: $0) } ?? false
          },
          onSetFavorite: { selectedRows, isFavorite in
            let ids = model.tracks(for: selectedRows).map(\.id)
            perform { try app.setFavorite(isFavorite, for: ids) }
          },
          onSetRating: { selectedRows, rating in
            let ids = model.tracks(for: selectedRows).map(\.id)
            perform { try app.setRating(rating, for: ids) }
          },
          playlistMenuItems: app.playlists.playlists.map {
            PlaylistMenuItem(id: $0.id, title: $0.name)
          },
          onAddToPlaylist: { selectedRows, playlistID in
            let ids = model.tracks(for: selectedRows).map(\.id)
            perform { try app.addToPlaylist(ids, playlistID: playlistID) }
          },
          onDelete: { selectedRows in
            let tracks = model.tracks(for: selectedRows)
            if let track = tracks.first, tracks.count == 1 {
              trackAlert = .delete(track)
            } else if !tracks.isEmpty {
              trackAlert = .deleteMany(tracks)
            }
          },
          deleteTitle: "Move to Trash…",
          mutationsDisabled: app.libraryMutationsDisabled,
          selectionBinding: trackSelection ?? $app.selectedTrackIDs,
          rowsForSelection: model.rows(for:),
          searchText: app.searchText,
          onClearSearch: { app.searchText = "" })
      }
    }
    .alert(item: $trackAlert) { alert in
      switch alert {
      case .delete(let track):
        return Alert(
          title: Text("Move “\(track.displayTitle)” to Trash?"),
          message: Text(
            "This removes the audio file from your library. If the song is still on an iPod, a later two-way sync may copy it back."
          ),
          primaryButton: .destructive(Text("Move to Trash")) {
            delete(track)
          },
          secondaryButton: .cancel())
      case .deleteMany(let tracks):
        return Alert(
          title: Text("Move \(tracks.count) Songs to Trash?"),
          message: Text(
            "This removes the selected audio files from your library. Songs still on an iPod may be copied back by a later two-way sync."
          ),
          primaryButton: .destructive(Text("Move to Trash")) {
            delete(tracks)
          },
          secondaryButton: .cancel())
      case .error(let message):
        return Alert(
          title: Text("The track couldn’t be changed"),
          message: Text(message),
          dismissButton: .default(Text("OK")))
      }
    }
    .onChange(of: app.library.identityRevision) { trackAlert = nil }
    .clearsTrackSelection($app.selectedTrackIDs, when: app.library.folderURL == nil)
    .task(
      id: FilterRequest(
        query: app.searchText, libraryRevision: app.library.derivedDataRevision)
    ) {
      // An empty search box needs no index; skipping the call also skips the
      // model's index warm-up, which the always-visible field shouldn't pay
      // for on every library revision.
      let query = app.searchText
      guard !query.isEmpty else { return }
      let tracks = app.library.tracks
      await searchFilter.resolve(
        query: query, revision: app.library.derivedDataRevision,
        buildIndex: { LibraryTrackSearchIndex(tracks: tracks) },
        match: { try $0.matchingIDs(for: query) })
    }
  }

  fileprivate struct TableModel {
    var rows: [SongRow<TrackID>] = []
    var visibleRowIDs: Set<TrackID>?

    fileprivate var visibleTracksByID: [TrackID: LibraryTrack] = [:]
    fileprivate var catalog = LibraryCatalog()
    fileprivate var libraryTracks: [LibraryTrack] = []
    fileprivate var listeningMetadata: [TrackID: TrackListeningMetadata] = [:]

    func track(for row: SongRow<TrackID>) -> LibraryTrack? {
      visibleTracksByID[row.id] ?? catalog[row.id]
    }

    func tracks(for rows: [SongRow<TrackID>]) -> [LibraryTrack] {
      rows.compactMap(track(for:))
    }

    func rows(for ids: Set<TrackID>) -> [SongRow<TrackID>] {
      libraryTracks.compactMap { track in
        guard ids.contains(track.id) else { return nil }
        return SongRow(track: track, listening: listeningMetadata[track.id])
      }
    }
  }

  fileprivate struct TableModelInputs: Equatable {
    var libraryRevision: UInt64
    var scopedTracks: [LibraryTrack]?
    var listeningMetadata: [TrackID: TrackListeningMetadata]
  }

  fileprivate final class TableModelCache {
    private var inputs: TableModelInputs?
    private var model = TableModel()
    private var latestVisibleRowIDs: Set<TrackID>?

    /// The last built model, shown while a debounced filter is resolving so
    /// typing never blanks the table or changes the visible results per
    /// keystroke.
    var latestModel: TableModel {
      var latest = model
      latest.visibleRowIDs = latestVisibleRowIDs
      return latest
    }

    func model(
      for inputs: TableModelInputs, visibleRowIDs: Set<TrackID>?,
      rebuild: (TableModelInputs) -> TableModel
    ) -> TableModel {
      if inputs != self.inputs {
        model = rebuild(inputs)
        self.inputs = inputs
      }
      latestVisibleRowIDs = visibleRowIDs
      var presented = model
      presented.visibleRowIDs = visibleRowIDs
      return presented
    }
  }

  private var tableModel: TableModel {
    let query = app.searchText
    let libraryRevision = app.library.derivedDataRevision
    var matchedIDs: Set<TrackID>?
    if !query.isEmpty {
      guard let resolved = searchFilter.resolved,
        resolved.query == query, resolved.revision == libraryRevision
      else {
        // The off-main filter for this exact query hasn't landed yet; keep
        // the previous visible result until the `.task(id:)` resolution publishes.
        return tableModelCache.latestModel
      }
      matchedIDs = resolved.value
    }
    let inputs = TableModelInputs(
      libraryRevision: libraryRevision,
      scopedTracks: scopedTracks,
      listeningMetadata: app.listeningHistory.metadataByID)
    return tableModelCache.model(for: inputs, visibleRowIDs: matchedIDs) { inputs in
      buildTableModel(inputs: inputs)
    }
  }

  private func buildTableModel(inputs: TableModelInputs) -> TableModel {
    var model = TableModel()
    model.catalog = app.library.catalog
    model.libraryTracks = app.library.tracks
    model.listeningMetadata = inputs.listeningMetadata

    let visible = inputs.scopedTracks ?? model.libraryTracks
    model.rows.reserveCapacity(visible.count)
    model.visibleTracksByID.reserveCapacity(visible.count)
    for track in visible {
      let row = SongRow(track: track, listening: inputs.listeningMetadata[track.id])
      model.rows.append(row)
      model.visibleTracksByID[row.id] = track
    }
    return model
  }

  private func search(for value: String) {
    app.searchText = value
    app.searchFocusRequest += 1
  }

  private func delete(_ track: LibraryTrack) {
    delete([track])
  }

  private func delete(_ tracks: [LibraryTrack]) {
    let libraryIdentity = app.library.identityRevision
    Task {
      guard
        let result = await app.moveLibraryTracksToTrash(
          tracks, expectedLibraryIdentity: libraryIdentity)
      else { return }
      if let firstFailure = result.failed.first {
        let succeeded = result.succeeded.count
        let summary =
          succeeded == 0
          ? String(localized: "No songs were moved to Trash.")
          : succeeded == 1
            ? String(localized: "1 song moved to Trash.")
            : String(localized: "\(succeeded) songs moved to Trash.")
        trackAlert = .error(
          String(
            localized:
              "\(summary) \(result.failed.count) failed, including “\(firstFailure.track.displayTitle)”: \(firstFailure.message)"
          )
        )
      }
    }
  }

  private func perform(_ operation: () throws -> Void) {
    attempt(operation) { trackAlert = .error($0) }
  }
}

private enum LibraryTrackAlert: Identifiable {
  case delete(LibraryTrack)
  case deleteMany([LibraryTrack])
  case error(String)

  var id: String {
    switch self {
    case .delete(let track): "delete-\(track.url.absoluteString)"
    case .deleteMany(let tracks):
      "delete-many-\(tracks.map { $0.url.absoluteString }.joined(separator: "|"))"
    case .error(let message): "error-\(message)"
    }
  }
}

struct LibraryBrowserView: View {
  @Environment(\.deckContentSpacing) private var deckContentSpacing
  @Bindable var app: AppState
  let kind: LibraryBrowseKind
  @Binding var selectedCollectionIDs: Set<LibraryCollection.ID>
  fileprivate let tableModelCache: LibraryView.TableModelCache
  let searchFilter: LibraryTrackFilterModel
  fileprivate let artworkCache: LibraryArtworkCache
  @State private var albumLookup: AlbumLookupRequest?

  private var collections: [LibraryCollection] {
    app.library.collections(for: kind)
  }

  var body: some View {
    let collections = collections
    let selectedCollections = app.library.collections(
      for: kind, matching: selectedCollectionIDs)
    let selectedTracks = LibraryCollection.combinedTracks(from: selectedCollections)
    if app.library.folderURL == nil {
      LibraryView(app: app, tableModelCache: tableModelCache, searchFilter: searchFilter)
    } else if collections.isEmpty {
      // ContentUnavailableView hugs its content, which would center the
      // detail column and float the status bar mid-window.
      ContentUnavailableView(
        "No \(kind.pluralTitle)",
        systemImage: kind.systemImage,
        description: Text(kind.emptyDescription)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clearsTrackSelection($app.selectedTrackIDs, when: true)
    } else {
      HSplitView {
        ScrollViewReader { proxy in
          List(collections, selection: collectionSelection) { collection in
            collectionRow(collection)
              .tag(collection.id)
          }
          .listStyle(.sidebar)
          .contextMenu(forSelectionType: LibraryCollection.ID.self) { ids in
            collectionContextMenu(for: ids)
          }
          .background(Bodywork.well)
          .overlay(alignment: .trailing) {
            Bodywork.Seam(axis: .vertical, verticalHitPlacement: .insideTrailingEdge)
          }
          .onAppear {
            if !consumeCollectionReveal(scrollingWith: proxy) {
              applySelectionChange(.destination)
            }
          }
          .onChange(of: app.pendingCollectionReveal) {
            _ = consumeCollectionReveal(scrollingWith: proxy)
          }
        }
        .frame(minWidth: 210, idealWidth: 260)

        Group {
          if !selectedCollections.isEmpty {
            VStack(spacing: 0) {
              collectionHeader(selectedCollections, tracks: selectedTracks)
              Bodywork.Seam()
              LibraryView(
                app: app,
                scopedTracks: selectedTracks,
                trackSelection: scopedTrackSelection,
                tableModelCache: tableModelCache,
                searchFilter: searchFilter)
            }
          } else {
            ContentUnavailableView(
              "No \(kind.pluralTitle)",
              systemImage: kind.systemImage,
              description: Text(kind.emptyDescription)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
        .frame(minWidth: 420)
        .overlay(alignment: .leading) {
          Bodywork.Seam(
            axis: .vertical, verticalHitPlacement: .insideLeadingEdge,
            showsSeparator: false)
        }
      }
      .onChange(of: kind) { applySelectionChange(.destination) }
      .onChange(of: collections) { applySelectionChange(.collectionData) }
      .clearsTrackSelection($app.selectedTrackIDs, when: collections.isEmpty)
      .musicBrainzAlbumLookup($albumLookup, app: app)
      .onChange(of: app.library.identityRevision) { albumLookup = nil }
    }
  }

  @ViewBuilder
  private func collectionRow(_ collection: LibraryCollection) -> some View {
    HStack(spacing: 10) {
      if kind.showsArtwork {
        LibraryArtworkView(
          trackURL: collection.artworkTrackURL,
          libraryRevision: app.library.derivedDataRevision,
          cache: artworkCache
        )
        .frame(width: 40, height: 40)
        .clipShape(.rect(cornerRadius: 4))
      } else {
        Image(systemName: kind.systemImage)
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(width: 40, height: 40)
          .background(.quaternary, in: .rect(cornerRadius: 4))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(collection.title)
          .lineLimit(1)
        Text(collection.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func collectionContextMenu(for ids: Set<LibraryCollection.ID>) -> some View {
    let contextCollections = collectionsForContextMenu(ids)
    let tracks = LibraryCollection.combinedTracks(from: contextCollections)
    if tracks.isEmpty {
      Button("Edit Info…") {}
        .disabled(true)
    } else {
      Button(editInfoTitle(for: tracks.count)) {
        applySelectionChange(.collections(Set(contextCollections.map(\.id))))
        app.requestEditInfo(for: Set(tracks.map(\.id)))
      }
      .disabled(
        app.libraryMutationsDisabled
          || tracks.contains { !$0.supportsMetadataEditing })
    }
  }

  private func collectionsForContextMenu(
    _ ids: Set<LibraryCollection.ID>
  ) -> [LibraryCollection] {
    let effectiveIDs = LibraryBrowserSelection.contextCollectionIDs(
      for: ids,
      selectedCollectionIDs: selectedCollectionIDs,
      collections: collections)
    return app.library.collections(for: kind, matching: effectiveIDs)
  }

  private func collectionHeader(
    _ selection: [LibraryCollection], tracks: [LibraryTrack]
  ) -> some View {
    let singleCollection = selection.count == 1 ? selection[0] : nil
    return HStack(spacing: 16) {
      if kind.showsArtwork, let singleCollection {
        LibraryArtworkView(
          trackURL: singleCollection.artworkTrackURL,
          libraryRevision: app.library.derivedDataRevision,
          cache: artworkCache
        )
        .frame(width: 76, height: 76)
        .clipShape(.rect(cornerRadius: 7))
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
      } else {
        Image(systemName: kind.systemImage)
          .font(.system(size: 30))
          .foregroundStyle(.secondary)
          .frame(width: 76, height: 76)
          .background(.quaternary, in: .rect(cornerRadius: 7))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text((singleCollection == nil ? kind.pluralTitle : kind.singularTitle).uppercased())
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Text(singleCollection?.title ?? "\(selection.count) \(kind.pluralTitle)")
          .font(.title2)
          .fontWeight(.semibold)
          .lineLimit(2)
        Text(collectionSummary(singleCollection, tracks: tracks))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if kind == .album, singleCollection != nil {
        Button {
          albumLookup = AlbumLookupRequest(tracks: tracks)
        } label: {
          Label("Look Up", systemImage: "network")
        }
        .disabled(app.libraryMutationsDisabled || !AlbumLookupRequest.canLookUp(tracks))
        .help(
          AlbumLookupRequest.canLookUp(tracks)
            ? String(localized: "Match this album's songs against a MusicBrainz release")
            : String(localized: "Album lookup is available when every song is an MP3"))
      }
      Button {
        guard let first = tracks.first else { return }
        app.player.play(first, in: tracks)
      } label: {
        Label(
          singleCollection == nil ? String(localized: "Play All") : String(localized: "Play"),
          systemImage: "play.fill")
      }
      .buttonStyle(.lit)
      .disabled(tracks.isEmpty)
    }
    .padding(.horizontal, 20)
    .padding(.top, max(0, 14 - deckContentSpacing))
    .padding(.bottom, 14)
    .background(Bodywork.raised)
  }

  private var collectionSelection: Binding<Set<LibraryCollection.ID>> {
    Binding(
      get: { selectedCollectionIDs },
      set: { applySelectionChange(.collections($0)) })
  }

  /// Applies a quick-search reveal aimed at this browse kind: select the
  /// collection and scroll its row into view. Returns false when no reveal
  /// for this kind is pending.
  private func consumeCollectionReveal(scrollingWith proxy: ScrollViewProxy) -> Bool {
    guard let collectionID = app.pendingCollectionReveal, collectionID.kind == kind
    else { return false }
    app.pendingCollectionReveal = nil
    applySelectionChange(.collections([collectionID]))
    // On first appearance the list has no geometry yet; scroll a tick later.
    DispatchQueue.main.async {
      proxy.scrollTo(collectionID, anchor: .center)
    }
    return true
  }

  private var scopedTrackSelection: Binding<Set<TrackID>> {
    Binding(
      get: { app.selectedTrackIDs },
      set: { applySelectionChange(.tracks($0)) })
  }

  private func applySelectionChange(_ change: LibraryBrowserSelectionChange) {
    let transition = LibraryBrowserSelection.transition(
      for: change,
      currentCollectionIDs: selectedCollectionIDs,
      selectedTrackIDs: app.selectedTrackIDs,
      collections: collections,
      projectedCollectionIDs: app.library.collectionIDs(
        containingAny: app.selectedTrackIDs, for: kind),
      isValidCollectionID: { app.library.containsCollection($0, for: kind) })
    selectedCollectionIDs = transition.collectionIDs
    if app.selectedTrackIDs != transition.trackIDs {
      app.selectedTrackIDs = transition.trackIDs
    }
  }

  private func collectionSummary(
    _ singleCollection: LibraryCollection?, tracks: [LibraryTrack]
  ) -> String {
    let duration = LibraryTrack.formatDuration(ms: tracks.reduce(0) { $0 + $1.durationMS })
    if let singleCollection {
      return "\(singleCollection.subtitle) · \(duration)"
    }
    let songs =
      tracks.count == 1 ? String(localized: "1 song") : String(localized: "\(tracks.count) songs")
    return String(localized: "\(songs) · \(duration)")
  }
}

func editInfoTitle(for songCount: Int) -> String {
  switch songCount {
  case 1: String(localized: "Edit Info for 1 Song…")
  case 2...: String(localized: "Edit Info for \(songCount) Songs…")
  default: String(localized: "Edit Info for Selected Songs…")
  }
}

@MainActor
fileprivate final class LibraryArtworkCache {
  private final class Entry {
    let image: NSImage?

    init(_ image: NSImage?) {
      self.image = image
    }
  }

  private let entries = NSCache<NSString, Entry>()
  private var libraryRevision: UInt64?

  init() {
    entries.countLimit = 500
  }

  func lookup(
    _ url: URL, libraryRevision: UInt64
  ) -> (isCached: Bool, image: NSImage?) {
    prepare(for: libraryRevision)
    guard let entry = entries.object(forKey: url.absoluteString as NSString) else {
      return (false, nil)
    }
    return (true, entry.image)
  }

  func insert(_ image: NSImage?, for url: URL, libraryRevision: UInt64) {
    guard libraryRevision == self.libraryRevision else { return }
    entries.setObject(Entry(image), forKey: url.absoluteString as NSString)
  }

  private func prepare(for revision: UInt64) {
    guard revision != libraryRevision else { return }
    entries.removeAllObjects()
    libraryRevision = revision
  }
}

private struct LibraryArtworkView: View {
  let trackURL: URL?
  let libraryRevision: UInt64
  let cache: LibraryArtworkCache
  @State private var artwork: NSImage?

  var body: some View {
    Group {
      if let artwork {
        Image(nsImage: artwork)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "music.note")
          .font(.title3)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary)
      }
    }
    .task(id: ArtworkRequest(trackURL: trackURL, libraryRevision: libraryRevision)) {
      artwork = nil
      guard let trackURL else { return }
      let cached = cache.lookup(trackURL, libraryRevision: libraryRevision)
      if cached.isCached {
        artwork = cached.image
        return
      }
      let data = await MetadataLoader.loadArtwork(url: trackURL)
      guard !Task.isCancelled else { return }
      let image = data.flatMap(NSImage.init(data:))
      cache.insert(image, for: trackURL, libraryRevision: libraryRevision)
      artwork = image
    }
  }

  private struct ArtworkRequest: Equatable {
    let trackURL: URL?
    let libraryRevision: UInt64
  }
}

private extension LibraryBrowseKind {
  var singularTitle: String {
    switch self {
    case .artist: String(localized: "Artist")
    case .album: String(localized: "Album")
    case .genre: String(localized: "Genre")
    case .audiobook: String(localized: "Audiobook")
    }
  }

  var pluralTitle: String {
    switch self {
    case .artist: String(localized: "Artists")
    case .album: String(localized: "Albums")
    case .genre: String(localized: "Genres")
    case .audiobook: String(localized: "Audiobooks")
    }
  }

  var systemImage: String {
    switch self {
    case .artist: "music.mic"
    case .album: "square.stack"
    case .genre: "guitars"
    case .audiobook: "books.vertical"
    }
  }

  var emptyDescription: String {
    switch self {
    case .audiobook:
      String(
        localized:
          "Files marked as audiobooks will appear here. Mark songs from the library's context menu."
      )
    default:
      String(localized: "Songs with \(singularTitle.lowercased()) metadata will appear here.")
    }
  }

  /// Audiobook collections are albums of chapters, so they share album artwork.
  var showsArtwork: Bool {
    self == .album || self == .audiobook
  }
}

func libraryStatsText(count: Int, durationMS: Int, sizeBytes: Int) -> String {
  guard count > 0 else { return String(localized: "No songs") }
  let songs = count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
  let totalSeconds = durationMS / 1000
  let time: String
  if totalSeconds >= 86400 {
    let days = (Double(totalSeconds) / 86400).formatted(.number.precision(.fractionLength(1)))
    time = String(localized: "\(days) days")
  } else if totalSeconds >= 3600 {
    let hours = (Double(totalSeconds) / 3600).formatted(.number.precision(.fractionLength(1)))
    time = String(localized: "\(hours) hours")
  } else {
    let minutes = (Double(totalSeconds) / 60).formatted(.number.precision(.fractionLength(1)))
    time = String(localized: "\(minutes) minutes")
  }
  return String(localized: "\(songs), \(time), \(sizeBytes.byteText)")
}
