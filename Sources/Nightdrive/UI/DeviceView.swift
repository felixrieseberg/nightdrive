import AppKit
import SwiftUI

struct DeviceView: View {
  @Environment(\.deckContentSpacing) private var deckContentSpacing
  @Bindable var app: AppState
  let device: IpodDevice
  @State private var trackToEdit: DeviceTrackEditItem?
  @State private var bulkEditItem: DeviceBulkEditItem?
  @State private var trackAlert: DeviceTrackAlert?
  @State private var showingScopePlaylists = false
  @State private var showingScopeRules = false
  @State private var syncConfirmation: SyncConfirmationInfo?
  @State private var isRenaming = false
  @State private var draftName = ""
  @State private var showingRepairConfirmation = false
  @State private var repairSummary: String?
  @State private var preparedRows: PreparedDeviceRows?
  @State private var preparedPlan: PreparedDevicePlan?

  var body: some View {
    let rowsRequest = DeviceRowsRequest(
      deviceURL: device.volumeURL,
      deviceRevision: device.derivedDataRevision,
      searchText: app.searchText)
    let planRequest = DevicePlanRequest(
      deviceURL: device.volumeURL,
      deviceRevision: device.derivedDataRevision,
      libraryRevision: app.library.derivedDataRevision,
      playlistsRevision: app.playlists.revision,
      listeningHistoryRevision: app.listeningHistory.revision,
      syncSettingsRevision: app.syncSettingsLedger.revision,
      libraryIsSettled: app.library.isSettled)
    let rows = preparedRows.flatMap {
      $0.request.deviceURL == rowsRequest.deviceURL ? $0.rows : nil
    }
    let plan = preparedPlan.flatMap { $0.request == planRequest ? $0.plan : nil }

    VStack(spacing: 0) {
      header(plan: plan, isPreparingPlan: app.library.isSettled && plan == nil)
      Bodywork.Seam()
      if let rows {
        TrackTable(
          rows: rows,
          nowPlayingID: nil,
          onShowInFinder: { selectedRows in
            do {
              let urls = try selectedRows.compactMap { row in
                try track(for: row).map(fileURL(for:))
              }
              NSWorkspace.shared.activateFileViewerSelecting(urls)
            } catch {
              trackAlert = .error(error.localizedDescription)
            }
          },
          onSearchArtist: { row in search(for: row.artist) },
          onSearchAlbum: { row in search(for: row.album) },
          onEditInfo: { selectedRows in
            let selectedTracks = selectedRows.compactMap { track(for: $0) }
            if selectedTracks.count > 1 {
              prepareBulkEdit(selectedTracks)
              return
            }
            guard let track = selectedTracks.first else { return }
            do {
              let url = try fileURL(for: track)
              Task {
                let fileTrack = await MetadataLoader.load(url: url)
                trackToEdit = DeviceTrackEditItem(
                  track: track,
                  fileURL: url,
                  metadata: TrackMetadata(fileTrack: fileTrack, databaseTrack: track))
              }
            } catch {
              trackAlert = .error(error.localizedDescription)
            }
          },
          isEditInfoEnabled: { row in
            // Derived from the row alone: statting every selected file on the
            // device volume would hang the main thread while the menu opens.
            guard !row.location.isEmpty else { return false }
            let ext = (row.location as NSString).pathExtension.lowercased()
            return LibraryAudioFormat(rawValue: ext)?.supportsMetadataEditing == true
          },
          onDelete: { selectedRows in
            if let row = selectedRows.first, let track = track(for: row) {
              trackAlert = .delete(track)
            }
          },
          allowsBulkDelete: false,
          deleteTitle: "Delete from iPod…",
          mutationsDisabled: app.isDeviceOperationActive || device.writeError != nil,
          searchText: app.searchText,
          onClearSearch: { app.searchText = "" }
        )
        .overlay(alignment: .topTrailing) {
          if preparedRows?.request != rowsRequest {
            ProgressView()
              .controlSize(.small)
              .padding(10)
          }
        }
      } else {
        VStack(spacing: 12) {
          ProgressView()
          Text("Loading songs from \(app.displayName(for: device))…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .sheet(item: $trackToEdit) { item in
      TrackInfoEditor(
        metadata: item.metadata,
        fileInfo: TrackFileInfo(item.track, fileURL: item.fileURL),
        fileURL: item.fileURL,
        genreSuggestions: GenreMetadata.libraryValues(from: app.library.tracks)
      ) { metadata, artworkChange in
        try await app.deviceManager.updateMetadata(
          for: item.track,
          on: device,
          from: item.metadata,
          to: metadata,
          artworkChange: artworkChange)
      }
    }
    .sheet(item: $bulkEditItem) { item in
      BulkTrackInfoEditor(
        metadata: item.edits.map(\.metadata),
        genreSuggestions: GenreMetadata.libraryValues(from: app.library.tracks)
      ) { changes in
        try await app.deviceManager.updateMetadata(
          for: item.edits, on: device, applying: changes)
      }
    }
    .alert(item: $trackAlert) { alert in
      switch alert {
      case .delete(let track):
        let trackTitle = track.title ?? String(localized: "this track")
        return Alert(
          title: Text(String(localized: "Delete “\(trackTitle)” from \(device.name)?")),
          message: Text(
            "This permanently removes the audio file from the iPod. If the song is still in your library, a later two-way sync may copy it back."
          ),
          primaryButton: .destructive(Text("Delete from iPod")) {
            delete(track)
          },
          secondaryButton: .cancel())
      case .error(let message):
        return Alert(
          title: Text("The track couldn’t be changed"),
          message: Text(message),
          dismissButton: .default(Text("OK")))
      }
    }
    .sheet(isPresented: $showingScopePlaylists) {
      ScopePlaylistPickerView(
        playlists: app.playlists.playlists,
        initiallySelected: currentScopePlaylistIDs
      ) { ids in
        app.updateSyncSettings(for: device) { $0.scope = .playlists(ids) }
      }
    }
    .sheet(isPresented: $showingScopeRules) {
      SmartRuleEditorView(
        title: String(localized: "Sync Rules"), confirmLabel: String(localized: "Use Rules"),
        rule: currentScopeRule
      ) { _, rule in
        app.updateSyncSettings(for: device) { $0.scope = .rules(rule) }
      }
    }
    .confirmationDialog(
      "Sync \(device.name)?",
      isPresented: Binding(
        get: { syncConfirmation != nil },
        set: { if !$0 { syncConfirmation = nil } }),
      titleVisibility: .visible,
      presenting: syncConfirmation
    ) { info in
      Button(info.primaryLabel, role: info.removalCount > 0 ? .destructive : nil) {
        app.sync(device, options: info.options(confirmRemovals: info.removalCount > 0))
      }
      if info.removalCount > 0 {
        Button("Sync Without Removing") {
          app.sync(device, options: info.options(confirmRemovals: false))
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { info in
      Text(info.message(deviceName: device.name))
    }
    .confirmationDialog(
      "Repair the database on \(app.displayName(for: device))?",
      isPresented: $showingRepairConfirmation,
      titleVisibility: .visible
    ) {
      Button("Rebuild Database") { repairDatabase() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Nightdrive rebuilds the iPod's database from the audio files on the device, "
          + "keeping every entry whose file still exists and re-reading tags for files "
          + "the database no longer mentions. The current database file is preserved "
          + "next to the new one. Use this when another tool has damaged the database.")
    }
    .alert(
      "Database repaired",
      isPresented: Binding(
        get: { repairSummary != nil },
        set: { if !$0 { repairSummary = nil } })
    ) {
      Button("OK") { repairSummary = nil }
    } message: {
      Text(repairSummary ?? "")
    }
    .clearsTrackSelection($app.selectedTrackIDs, when: true)
    .task(id: rowsRequest) { await prepareRows(for: rowsRequest) }
    .task(id: planRequest) { await preparePlan(for: planRequest) }
  }

  private func header(plan: SyncPlan?, isPreparingPlan: Bool) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 16) {
        IpodIllustration(device: device)
          .frame(width: 56, height: 72)
        VStack(alignment: .leading, spacing: 2) {
          if isRenaming {
            TextField("Device name", text: $draftName)
              .textFieldStyle(.roundedBorder)
              .font(.headline)
              .frame(maxWidth: 260)
              .onSubmit { commitRename() }
              .onExitCommand { isRenaming = false }
          } else {
            HStack(spacing: 6) {
              Text(app.displayName(for: device))
                .font(.headline)
              Button {
                draftName = app.displayName(for: device)
                isRenaming = true
              } label: {
                Image(systemName: "pencil")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.borderless)
              .help("Rename this iPod (the name is remembered by Nightdrive)")
            }
          }
          Text("\(device.modelDescription) · \(device.tracks.count) songs")
            .font(.subheadline)
            .foregroundStyle(.secondary)
          planText(plan, isPreparing: isPreparingPlan)
            .font(.caption)
            .foregroundStyle(.secondary)
          if let error = device.databaseError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          if let error = device.writeError {
            Label("Read only: \(error)", systemImage: "lock.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
        Spacer()
        if app.latestSyncResult != nil {
          Button("Details") { app.showLatestSyncDetails() }
        }
        Button {
          requestSync(plan)
        } label: {
          Label("Sync", systemImage: "arrow.triangle.2.circlepath")
        }
        .buttonStyle(.lit)
        .demoTarget("device.sync") { requestSync(plan) }
        .disabled(
          app.isDeviceOperationActive || !app.library.isSettled
            || plan == nil
            || (device.writeError != nil && planNeedsDeviceWrite(plan)))
      }
      scopeControls
      ergonomicsControls
      CapacityBar(device: device)
    }
    .padding(.horizontal, 20)
    .padding(.top, max(0, 14 - deckContentSpacing))
    .padding(.bottom, 14)
    .background(Bodywork.raised)
  }

  private func track(for row: SongRow<UInt64>) -> ITDBTrack? {
    device.tracks.first { $0.dbid == row.id }
  }

  private func fileURL(for track: ITDBTrack) throws -> URL {
    guard let path = track.ipodPath else {
      throw ITunesDBError.notFound("Track has no file path")
    }
    return try IpodFileSystem(volumeURL: device.volumeURL)
      .validatedMusicFileURL(forIpodPath: path)
  }

  private func search(for value: String) {
    app.searchText = value
    app.searchFocusRequest += 1
  }

  private func prepareRows(for request: DeviceRowsRequest) async {
    let tracks = device.tracks
    let worker = Task.detached(priority: .userInitiated) {
      DeviceViewPreparation.rows(from: tracks, matching: request.searchText)
    }
    let rows = await withTaskCancellationHandler {
      await worker.value
    } onCancel: {
      worker.cancel()
    }
    guard !Task.isCancelled else { return }
    preparedRows = PreparedDeviceRows(request: request, rows: rows)
  }

  private func preparePlan(for request: DevicePlanRequest) async {
    guard request.libraryIsSettled else {
      preparedPlan = PreparedDevicePlan(request: request, plan: nil)
      return
    }
    let plan = await app.syncPlanAsync(for: device)
    guard !Task.isCancelled else { return }
    preparedPlan = PreparedDevicePlan(request: request, plan: plan)
  }

  private func delete(_ track: ITDBTrack) {
    Task {
      do {
        try await app.deviceManager.delete(track, from: device)
      } catch {
        trackAlert = .error(error.localizedDescription)
      }
    }
  }

  private func prepareBulkEdit(_ tracks: [ITDBTrack]) {
    Task {
      do {
        var edits: [DeviceTrackMetadataEdit] = []
        for track in tracks {
          let url = try fileURL(for: track)
          guard LibraryAudioFormat(url: url)?.supportsMetadataEditing == true else {
            throw LibraryStoreError.metadataEditingUnsupported(
              url.pathExtension.uppercased())
          }
          let fileTrack = await MetadataLoader.load(url: url)
          edits.append(
            DeviceTrackMetadataEdit(
              dbid: track.dbid,
              metadata: TrackMetadata(fileTrack: fileTrack, databaseTrack: track)))
        }
        if edits.count > 1 {
          bulkEditItem = DeviceBulkEditItem(edits: edits)
        }
      } catch {
        trackAlert = .error(error.localizedDescription)
      }
    }
  }

  private func planNeedsDeviceWrite(_ plan: SyncPlan?) -> Bool {
    guard let plan else { return false }
    return !plan.copyToDevice.isEmpty || !plan.updateOnDevice.isEmpty
      || !plan.removeFromDevice.isEmpty
  }

  private var scopeControls: some View {
    let settings = app.syncSettings(for: device)
    let trackSyncHelp: LocalizedStringKey =
      switch settings.trackSyncMode {
      case .twoWay:
        "Copy new songs and tag edits in either direction"
      case .libraryToIpod:
        "Treat library song files and tags as authoritative; never copy songs from this iPod"
      case .ipodToLibrary:
        "Copy new songs and tag edits from this iPod; never copy, update, or remove iPod songs"
      }
    return HStack(spacing: 14) {
      Menu {
        Button {
          app.updateSyncSettings(for: device) { $0.scope = .everything }
        } label: {
          if case .everything = settings.scope {
            Label("Everything", systemImage: "checkmark")
          } else {
            Text("Everything")
          }
        }
        Button {
          showingScopePlaylists = true
        } label: {
          if case .playlists = settings.scope {
            Label("Chosen Playlists…", systemImage: "checkmark")
          } else {
            Text("Chosen Playlists…")
          }
        }
        Button {
          showingScopeRules = true
        } label: {
          if case .rules = settings.scope {
            Label("Rules…", systemImage: "checkmark")
          } else {
            Text("Rules…")
          }
        }
      } label: {
        Label("Sync: \(settings.scope.summary)", systemImage: "scope")
          .font(.caption)
      }
      .fixedSize()
      .help("Which part of the library this iPod receives")

      Menu {
        Button {
          app.updateSyncSettings(for: device) {
            $0.trackSyncMode = .twoWay
            $0.removesSongsNotInLibrary = false
            $0.removesSongsOutsideSyncScope = false
          }
        } label: {
          if settings.trackSyncMode == .twoWay {
            Label("Two-way", systemImage: "checkmark")
          } else {
            Text("Two-way")
          }
        }
        Button {
          app.updateSyncSettings(for: device) {
            $0.trackSyncMode = .ipodToLibrary
            $0.removesSongsNotInLibrary = false
            $0.removesSongsOutsideSyncScope = false
          }
        } label: {
          if settings.trackSyncMode == .ipodToLibrary {
            Label("One-way (iPod to Library)", systemImage: "checkmark")
          } else {
            Text("One-way (iPod to Library)")
          }
        }
        Button {
          app.updateSyncSettings(for: device) {
            if $0.trackSyncMode != .libraryToIpod {
              $0.removesSongsNotInLibrary = false
              $0.removesSongsOutsideSyncScope = false
            }
            $0.trackSyncMode = .libraryToIpod
          }
        } label: {
          if settings.trackSyncMode == .libraryToIpod {
            Label("One-way (Library to iPod)", systemImage: "checkmark")
          } else {
            Text("One-way (Library to iPod)")
          }
        }
      } label: {
        Label("Songs: \(settings.trackSyncMode.summary)", systemImage: "arrow.left.arrow.right")
          .font(.caption)
      }
      .fixedSize()
      .help(trackSyncHelp)
      .demoTarget("device.songsMode")

      if settings.trackSyncMode == .libraryToIpod {
        VStack(alignment: .leading, spacing: 3) {
          Toggle(
            "Delete songs not in library from iPod",
            isOn: Binding(
              get: { app.syncSettings(for: device).removesSongsNotInLibrary },
              set: { value in
                app.updateSyncSettings(for: device) { $0.removesSongsNotInLibrary = value }
              })
          )
          .help("Deletes iPod songs that Nightdrive cannot match to the library")

          Toggle(
            "Delete songs not in this sync from iPod",
            isOn: Binding(
              get: { app.syncSettings(for: device).removesSongsOutsideSyncScope },
              set: { value in
                app.updateSyncSettings(for: device) { $0.removesSongsOutsideSyncScope = value }
              })
          )
          .help("Deletes library songs on the iPod that are not included in this sync")
        }
        .toggleStyle(.checkbox)
        .font(.caption)
      }
      Spacer()
    }
    .disabled(!app.library.isSettled)
  }

  private var ergonomicsControls: some View {
    HStack(spacing: 14) {
      Toggle(
        "Sync when connected",
        isOn: Binding(
          get: { app.syncSettings(for: device).autoSyncOnConnect },
          set: { value in app.updateSyncSettings(for: device) { $0.autoSyncOnConnect = value } })
      )
      .toggleStyle(.checkbox)
      .font(.caption)
      .help("Start a sync automatically whenever this iPod appears")
      .disabled(!app.library.isSettled)

      Toggle(
        "Eject when finished",
        isOn: Binding(
          get: { app.syncSettings(for: device).ejectAfterSync },
          set: { value in app.updateSyncSettings(for: device) { $0.ejectAfterSync = value } })
      )
      .toggleStyle(.checkbox)
      .font(.caption)
      .help("Eject the iPod after a sync completes without errors")
      .disabled(!app.library.isSettled)

      Spacer()

      Button("Repair Database…") {
        showingRepairConfirmation = true
      }
      .font(.caption)
      .disabled(app.isDeviceOperationActive || device.writeError != nil)
      .help("Rebuild the iPod's database from the audio files on the device")
    }
  }

  private func commitRename() {
    app.setDisplayName(draftName, for: device)
    isRenaming = false
  }

  private func repairDatabase() {
    Task {
      do {
        let outcome = try await app.repairDatabase(device)
        repairSummary = outcome.summary
      } catch {
        trackAlert = .error(error.localizedDescription)
      }
    }
  }

  private var currentScopePlaylistIDs: Set<UUID> {
    if case .playlists(let ids) = app.syncSettings(for: device).scope {
      return Set(ids)
    }
    return []
  }

  private var currentScopeRule: SmartPlaylistRule {
    if case .rules(let rule) = app.syncSettings(for: device).scope {
      return rule
    }
    return SmartPlaylistRule()
  }

  private func requestSync(_ plan: SyncPlan?) {
    guard let plan else { return }
    let removalCount = plan.removeFromDevice.count
    if let shortfall = plan.capacityShortfall {
      syncConfirmation = SyncConfirmationInfo(
        shortfall: shortfall, trimTracks: plan.suggestedCapacityTrim,
        removalCount: removalCount, plan: plan)
    } else if removalCount > 0 {
      syncConfirmation = SyncConfirmationInfo(
        shortfall: nil, trimTracks: [], removalCount: removalCount, plan: plan)
    } else {
      app.sync(device)
    }
  }

  @ViewBuilder
  private func planText(_ plan: SyncPlan?, isPreparing: Bool) -> some View {
    if isPreparing {
      HStack(spacing: 5) {
        ProgressView()
          .controlSize(.mini)
        Text("Preparing sync preview…")
      }
    } else if let plan {
      if plan.isEmpty, plan.unsupportedForDevice.isEmpty {
        if plan.scopeInput.trackSyncMode == .ipodToLibrary {
          Text("In sync with your iPod")
        } else if case .everything = plan.scopeInput.scope {
          Text("In sync with your library")
        } else {
          Text("Selected library songs are in sync")
        }
      } else if plan.isEmpty {
        Text(
          plan.unsupportedForDevice.count == 1
            ? String(localized: "In sync · 1 local-only track")
            : String(
              localized:
                "In sync · \(plan.unsupportedForDevice.count) local-only tracks"))
      } else {
        let parts = [
          plan.copyToDevice.isEmpty
            ? nil : String(localized: "\(plan.copyToDevice.count) to iPod"),
          plan.copyToFolder.isEmpty
            ? nil : String(localized: "\(plan.copyToFolder.count) to library"),
          plan.updateOnDevice.isEmpty
            ? nil : String(localized: "\(plan.updateOnDevice.count) updated on iPod"),
          plan.updateInFolder.isEmpty
            ? nil : String(localized: "\(plan.updateInFolder.count) updated in library"),
          plan.removeFromDevice.isEmpty
            ? nil : String(localized: "\(plan.removeFromDevice.count) removed from iPod"),
          plan.unsupportedForDevice.isEmpty
            ? nil : String(localized: "\(plan.unsupportedForDevice.count) local-only"),
        ].compactMap(\.self)
        let summary = parts.joined(separator: ", ")
        Text(String(localized: "Will sync \(summary)"))
      }
      if !plan.notInLibraryOnDevice.isEmpty {
        Text(
          plan.notInLibraryOnDevice.count == 1
            ? String(localized: "1 track on iPod not in library (kept)")
            : String(
              localized:
                "\(plan.notInLibraryOnDevice.count) tracks on iPod not in library (kept)"))
      }
      if !plan.outOfScopeOnDevice.isEmpty {
        Text(
          plan.outOfScopeOnDevice.count == 1
            ? String(localized: "1 track on iPod not in this sync (kept)")
            : String(
              localized:
                "\(plan.outOfScopeOnDevice.count) tracks on iPod not in this sync (kept)"))
      }
      if !plan.excludedByScope.isEmpty {
        Text(
          plan.excludedByScope.count == 1
            ? String(localized: "1 library track excluded by the sync scope")
            : String(
              localized:
                "\(plan.excludedByScope.count) library tracks excluded by the sync scope"))
      }
      if !plan.localOnlyInLibrary.isEmpty {
        Text(
          plan.localOnlyInLibrary.count == 1
            ? String(localized: "1 library-only track kept locally")
            : String(
              localized: "\(plan.localOnlyInLibrary.count) library-only tracks kept locally"))
      }
      if let shortfall = plan.capacityShortfall {
        let trimCount = plan.suggestedCapacityTrim.count
        Label(
          trimCount == 1
            ? String(localized: "\(shortfall.byteText) over capacity — syncing would drop 1 song")
            : String(
              localized:
                "\(shortfall.byteText) over capacity — syncing would drop \(trimCount) songs"),
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      }
    } else {
      Text("Choose a library folder to sync")
    }
  }
}

private struct SyncConfirmationInfo {
  let shortfall: Int64?
  let trimTracks: [LibraryTrack]
  let removalCount: Int
  let notInLibraryRemovalCount: Int
  let outsideScopeRemovalCount: Int
  let scopeInput: SyncScopeInput
  let removalDbids: Set<UInt64>

  init(shortfall: Int64?, trimTracks: [LibraryTrack], removalCount: Int, plan: SyncPlan) {
    self.shortfall = shortfall
    self.trimTracks = trimTracks
    self.removalCount = removalCount
    self.notInLibraryRemovalCount = plan.removeFromDeviceNotInLibrary.count
    self.outsideScopeRemovalCount = plan.removeFromDeviceOutsideScope.count
    self.scopeInput = plan.scopeInput
    self.removalDbids = Set(plan.removeFromDevice.map(\.dbid))
  }

  func options(confirmRemovals: Bool) -> AppState.SyncDispatchOptions {
    AppState.SyncDispatchOptions(
      confirmRemovals: confirmRemovals,
      applySuggestedTrim: shortfall != nil,
      confirmedScopeInput: scopeInput,
      confirmedRemovalDbids: confirmRemovals ? removalDbids : nil,
      confirmedTrimKeys: shortfall != nil
        ? Set(trimTracks.map(\.id.rawValue)) : nil)
  }

  var primaryLabel: String {
    switch (shortfall, removalCount) {
    case (.some, let removals) where removals > 0:
      String(localized: "Trim \(trimTracks.count) & Remove \(removals)")
    case (.some, _):
      trimTracks.count == 1
        ? String(localized: "Sync, Dropping 1 Song")
        : String(localized: "Sync, Dropping \(trimTracks.count) Songs")
    default:
      String(localized: "Remove \(removalCount) & Sync")
    }
  }

  func message(deviceName: String) -> String {
    var parts: [String] = []
    if let shortfall {
      let sample = trimTracks.prefix(3).map(\.displayTitle).joined(separator: ", ")
      if trimTracks.count == 1 {
        let suggestion =
          sample.isEmpty
          ? String(localized: "Nightdrive suggests dropping the lowest-rated, least-recently-played song.")
          : String(
            localized:
              "Nightdrive suggests dropping the lowest-rated, least-recently-played song (\(sample)…).")
        parts.append(
          String(
            localized:
              "The planned copies are \(shortfall.byteText) over \(deviceName)’s free space. \(suggestion)"))
      } else {
        let suggestion =
          sample.isEmpty
          ? String(
            localized:
              "Nightdrive suggests dropping the \(trimTracks.count) lowest-rated, least-recently-played songs.")
          : String(
            localized:
              "Nightdrive suggests dropping the \(trimTracks.count) lowest-rated, least-recently-played songs (\(sample)…)."
          )
        parts.append(
          String(
            localized:
              "The planned copies are \(shortfall.byteText) over \(deviceName)’s free space. \(suggestion)"))
      }
    }
    if notInLibraryRemovalCount > 0 {
      parts.append(
        notInLibraryRemovalCount == 1
          ? String(
            localized:
              "1 song on \(deviceName) is not in your library and would be permanently deleted from the iPod."
          )
          : String(
            localized:
              "\(notInLibraryRemovalCount) songs on \(deviceName) are not in your library and would be permanently deleted from the iPod."
          ))
    }
    if outsideScopeRemovalCount > 0 {
      parts.append(
        outsideScopeRemovalCount == 1
          ? String(
            localized:
              "1 song on \(deviceName) is still in your library but not in this sync, and would be permanently deleted from the iPod."
          )
          : String(
            localized:
              "\(outsideScopeRemovalCount) songs on \(deviceName) are still in your library but not in this sync, and would be permanently deleted from the iPod."
          ))
    }
    return parts.joined(separator: "\n\n")
  }
}

private struct ScopePlaylistPickerView: View {
  @Environment(\.dismiss) private var dismiss
  let playlists: [LocalPlaylist]
  let onSave: ([UUID]) -> Void
  @State private var selection: Set<UUID>

  init(
    playlists: [LocalPlaylist],
    initiallySelected: Set<UUID>,
    onSave: @escaping ([UUID]) -> Void
  ) {
    self.playlists = playlists
    self.onSave = onSave
    _selection = State(initialValue: initiallySelected)
  }

  var body: some View {
    VStack(spacing: 0) {
      if playlists.isEmpty {
        ContentUnavailableView(
          "No Playlists",
          systemImage: "music.note.list",
          description: Text("Create a playlist first, then choose it here."))
      } else {
        List(playlists) { playlist in
          Toggle(
            isOn: Binding(
              get: { selection.contains(playlist.id) },
              set: { chosen in
                if chosen {
                  selection.insert(playlist.id)
                } else {
                  selection.remove(playlist.id)
                }
              })
          ) {
            HStack {
              Text(playlist.name)
              Spacer()
              Text(verbatim: "\(playlist.trackIDs.count)")
                .foregroundStyle(.secondary)
            }
          }
          .toggleStyle(.checkbox)
        }
      }
      Divider()
      HStack {
        Text("\(selection.count) selected")
          .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Use Playlists") {
          onSave(playlists.map(\.id).filter(selection.contains))
          dismiss()
        }
        .buttonStyle(.lit)
        .disabled(selection.isEmpty)
      }
      .padding()
    }
    .frame(minWidth: 380, minHeight: 360)
  }
}

private struct DeviceRowsRequest: Hashable {
  let deviceURL: URL
  let deviceRevision: UInt64
  let searchText: String
}

private struct PreparedDeviceRows {
  let request: DeviceRowsRequest
  let rows: [SongRow<UInt64>]
}

private struct DevicePlanRequest: Hashable {
  let deviceURL: URL
  let deviceRevision: UInt64
  let libraryRevision: UInt64
  let playlistsRevision: UInt64
  let listeningHistoryRevision: UInt64
  let syncSettingsRevision: UInt64
  let libraryIsSettled: Bool
}

private struct PreparedDevicePlan {
  let request: DevicePlanRequest
  let plan: SyncPlan?
}

enum DeviceViewPreparation {
  nonisolated static func rows(
    from tracks: [ITDBTrack], matching searchText: String
  ) -> [SongRow<UInt64>] {
    var rows: [SongRow<UInt64>] = []
    rows.reserveCapacity(tracks.count)
    for track in tracks {
      guard !Task.isCancelled else { break }
      let row = SongRow(deviceTrack: track)
      if row.matches(searchText) { rows.append(row) }
    }
    return rows
  }
}

private struct DeviceTrackEditItem: Identifiable {
  var id: UInt64 { track.dbid }
  let track: ITDBTrack
  let fileURL: URL
  let metadata: TrackMetadata
}

private struct DeviceBulkEditItem: Identifiable {
  let id = UUID()
  let edits: [DeviceTrackMetadataEdit]
}

private enum DeviceTrackAlert: Identifiable {
  case delete(ITDBTrack)
  case error(String)

  var id: String {
    switch self {
    case .delete(let track): "delete-\(track.dbid)"
    case .error(let message): "error-\(message)"
    }
  }
}

struct CapacityBar: View {
  let device: IpodDevice

  var body: some View {
    let total = max(device.totalCapacity, 1)
    let audio = min(device.usedByAudioBytes, total)
    let used = max(total - device.availableCapacity, 0)
    let other = max(used - audio, 0)
    let free = max(total - used, 0)

    VStack(alignment: .leading, spacing: 6) {
      GeometryReader { geo in
        HStack(spacing: 1) {
          Rectangle().fill(.tint)
            .frame(width: geo.size.width * CGFloat(audio) / CGFloat(total))
          Rectangle().fill(.tint.opacity(0.35))
            .frame(width: geo.size.width * CGFloat(other) / CGFloat(total))
          Rectangle().fill(.quaternary)
        }
        .clipShape(Capsule())
      }
      .frame(height: 6)

      HStack(spacing: 14) {
        legend(style: AnyShapeStyle(.tint), text: String(localized: "Audio \(audio.byteText)"))
        legend(
          style: AnyShapeStyle(.tint.opacity(0.35)),
          text: String(localized: "Other \(other.byteText)"))
        legend(style: AnyShapeStyle(.quaternary), text: String(localized: "Free \(free.byteText)"))
        Spacer()
        Text(total.byteText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  private func legend(style: AnyShapeStyle, text: String) -> some View {
    HStack(spacing: 4) {
      Circle().fill(style).frame(width: 6, height: 6)
      Text(text)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

extension Int64 {
  var byteText: String {
    ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
  }
}

extension Int {
  var byteText: String { Int64(self).byteText }
}
