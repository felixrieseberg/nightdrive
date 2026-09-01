import SwiftUI

/// The Cmd+K palette: a Spotlight-style overlay that fuzzy-searches app
/// commands, artists, albums, and songs. Command matching is cheap and stays
/// synchronous; music matching runs debounced off the main actor through
/// `QuickSearchMusicModel`.
struct QuickSearchPalette: View {
  @Bindable var app: AppState
  let music: QuickSearchMusicModel
  @State private var selectedIndex = 0
  @State private var listContentHeight: CGFloat = 0
  @State private var commandsCache = CommandsCache()
  @FocusState private var searchFocused: Bool

  private static let maxListHeight: CGFloat = 320

  private struct Item: Identifiable {
    enum Activation {
      case music(QuickSearchResult)
      case command(QuickSearchCommand.Action)
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let category: String
    let shortcut: String?
    let isEnabled: Bool
    let activation: Activation
  }

  private struct CommandsCache {
    var query: String?
    var items: [Item] = []
  }

  private struct MusicRequest: Equatable {
    let query: String
    let libraryRevision: UInt64
  }

  private var trimmedQuery: String {
    app.quickSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var results: [Item] {
    guard commandsCache.query == app.quickSearchQuery else { return [] }
    return commandsCache.items + musicItems
  }

  /// The latest resolved music hits. While a newer query is still resolving
  /// these lag one debounce interval behind, which keeps the list stable
  /// instead of blanking on every keystroke — but stale hits are disabled so
  /// pressing Return mid-debounce can't play the previous query's result.
  private var musicItems: [Item] {
    guard !trimmedQuery.isEmpty, let resolved = music.resolved else { return [] }
    let isCurrent =
      resolved.query == app.quickSearchQuery
      && resolved.revision == app.library.derivedDataRevision
    return resolved.value.map { result in
      Item(
        id: "music:\(result.id)", title: result.title, subtitle: result.subtitle,
        systemImage: glyph(for: result.collectionID?.kind),
        category: label(for: result.collectionID?.kind), shortcut: nil,
        isEnabled: isCurrent, activation: .music(result))
    }
  }

  private func commandItems(matching query: String) -> [Item] {
    let stateCommands = QuickSearch.commands.map {
      $0.resolvingPlayerState(
        isPlaying: app.player.isPlaying,
        isShuffleEnabled: app.player.isShuffleEnabled,
        repeatMode: app.player.repeatMode,
        isMuted: app.player.isMuted)
    }
    return QuickSearch.commands(
      matching: query, baseCommands: stateCommands,
      additionalCommands: contextualCommands
    ).map { command in
      Item(
        id: "command:\(command.id)", title: command.title, subtitle: command.subtitle,
        systemImage: command.systemImage, category: label(for: command.kind),
        shortcut: command.shortcut, isEnabled: isEnabled(command),
        activation: .command(command.action))
    }
  }

  private func cacheCommands(for query: String) {
    guard commandsCache.query != query else { return }
    commandsCache = CommandsCache(query: query, items: commandItems(matching: query))
  }

  private var contextualCommands: [QuickSearchCommand] {
    let devices = app.deviceManager.devices.enumerated().map { index, device in
      QuickSearchCommand(
        id: "view:device:\(device.volumeURL.standardizedFileURL.path)",
        kind: .navigation,
        title: app.displayName(for: device),
        subtitle: String(localized: "Open \(device.modelDescription)"),
        systemImage: "ipod",
        keywords: ["device", "ipod", "navigation", device.name, device.modelDescription],
        action: .navigate(.device(device.volumeURL)),
        shortcut: index == 0 ? "⌘0" : nil)
    }
    let playlists = app.playlists.playlists.map { playlist in
      let songCount =
        playlist.trackIDs.count == 1
        ? String(localized: "1 song") : String(localized: "\(playlist.trackIDs.count) songs")
      return QuickSearchCommand(
        id: "view:playlist:\(playlist.id.uuidString)",
        kind: .navigation,
        title: playlist.name,
        subtitle: String(localized: "Open playlist · \(songCount)"),
        systemImage: playlist.smartRule == nil ? "music.note.list" : "gearshape.2",
        keywords: ["playlist", "navigation", "view"],
        action: .navigatePlaylist(playlist.id),
        shortcut: nil)
    }
    let podcasts = app.podcasts.subscriptions.map { subscription in
      QuickSearchCommand(
        id: "view:podcast:\(subscription.feedURL.absoluteString)",
        kind: .navigation,
        title: subscription.title,
        subtitle: String(localized: "Open podcast"),
        systemImage: "antenna.radiowaves.left.and.right",
        keywords: ["podcast", "show", "navigation", subscription.author ?? ""],
        action: .navigatePodcast(subscription.feedURL),
        shortcut: nil)
    }
    return devices + playlists + podcasts
  }

  var body: some View {
    let results = self.results
    ZStack(alignment: .top) {
      Color.black.opacity(0.45)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .accessibilityHidden(true)
      VStack(spacing: 0) {
        searchField
        if !results.isEmpty {
          Rectangle()
            .fill(.white.opacity(0.07))
            .frame(height: 1)
          resultsList(results)
        } else if !trimmedQuery.isEmpty, music.resolved?.query == app.quickSearchQuery {
          // Only declare a miss once music matching for this exact query has
          // resolved; while it is still debouncing or matching off-main the
          // palette keeps the previous list instead of flashing "no matches".
          Text("NO MATCHES")
            .font(VFD.label(10))
            .kerning(1)
            .foregroundStyle(VFD.ghost)
            .padding(.vertical, 18)
        }
      }
      .frame(width: 560)
      .background(
        RoundedRectangle(cornerRadius: 10)
          .fill(Bodywork.raised)
      )
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(
        RoundedRectangle(cornerRadius: 10)
          .strokeBorder(.white.opacity(0.1), lineWidth: 1)
      )
      .compositingGroup()
      .shadow(color: .black.opacity(0.75), radius: 34, y: 14)
      .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
      .padding(.top, 110)
    }
    .onChange(of: app.quickSearchQuery, initial: true) {
      selectedIndex = 0
      cacheCommands(for: app.quickSearchQuery)
    }
    .task(
      id: MusicRequest(
        query: app.quickSearchQuery, libraryRevision: app.library.derivedDataRevision)
    ) {
      let query = app.quickSearchQuery
      let artists = app.library.collections(for: .artist)
      let albums = app.library.collections(for: .album)
      let genres = app.library.collections(for: .genre)
      let audiobooks = app.library.collections(for: .audiobook)
      let tracks = app.library.tracks
      await music.resolve(
        query: query, revision: app.library.derivedDataRevision,
        buildIndex: {
          QuickSearchIndex(
            artists: artists, albums: albums, genres: genres, audiobooks: audiobooks,
            tracks: tracks)
        },
        match: { try QuickSearch.results(matching: query, in: $0) })
    }
    .onExitCommand { dismiss() }
    .task { searchFocused = true }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(VFD.dim)
      TextField(
        String(), text: $app.quickSearchQuery,
        prompt: Text("SEARCH NIGHTDRIVE").foregroundStyle(VFD.ghost)
      )
      .textFieldStyle(.plain)
      .font(VFD.label(13))
      .kerning(0.5)
      .foregroundStyle(VFD.glow)
      .tint(VFD.glow)
      .focused($searchFocused)
      .onSubmit { activate(results) }
      .onKeyPress(.downArrow) {
        moveSelection(by: 1)
        return .handled
      }
      .onKeyPress(.upArrow) {
        moveSelection(by: -1)
        return .handled
      }
      .onExitCommand { dismiss() }
      .accessibilityLabel("Command Palette")
    }
    .padding(.horizontal, 14)
    .frame(height: 44)
  }

  private func resultsList(_ results: [Item]) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(spacing: 1) {
          ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
            resultRow(result, isSelected: index == clampedIndex(in: results))
              .id(result.id)
              .onTapGesture { activate(results, at: index) }
          }
        }
        .padding(6)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { height in
          listContentHeight = height
        }
      }
      .frame(height: min(listContentHeight, Self.maxListHeight))
      .onChange(of: selectedIndex) {
        guard !results.isEmpty else { return }
        proxy.scrollTo(results[clampedIndex(in: results)].id)
      }
    }
  }

  private func resultRow(_ result: Item, isSelected: Bool) -> some View {
    HStack(spacing: 10) {
      Image(systemName: result.systemImage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? VFD.glow : VFD.dim)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 1) {
        Text(result.title)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(result.subtitle)
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      Text(result.category)
        .font(VFD.label(8))
        .kerning(1)
        .foregroundStyle(VFD.dim)
      if let shortcut = result.shortcut {
        Text(shortcut)
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.055)))
      }
      if isSelected {
        Image(systemName: "return")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(VFD.dim)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 6)
        .fill(isSelected ? VFD.glow.opacity(0.16) : .clear)
    )
    .contentShape(Rectangle())
    .opacity(result.isEnabled ? 1 : 0.42)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func glyph(for kind: LibraryBrowseKind?) -> String {
    switch kind {
    case .artist: "music.microphone"
    case .album: "opticaldisc"
    case .genre: "guitars"
    case .audiobook: "books.vertical"
    case nil: "music.note"
    }
  }

  private func label(for kind: LibraryBrowseKind?) -> String {
    switch kind {
    case .artist: String(localized: "ARTIST")
    case .album: String(localized: "ALBUM")
    case .genre: String(localized: "GENRE")
    case .audiobook: String(localized: "AUDIOBOOK")
    case nil: String(localized: "SONG")
    }
  }

  private func label(for kind: QuickSearchCommand.Kind) -> String {
    switch kind {
    case .navigation: String(localized: "VIEW")
    case .player: String(localized: "PLAYER")
    case .tool: String(localized: "TOOL")
    }
  }

  private func isEnabled(_ command: QuickSearchCommand) -> Bool {
    switch command.action {
    case .findDuplicates, .cleanUpGenres, .findMetadataProblems, .organizeLibrary:
      app.library.isSettled && !app.libraryMutationsDisabled
    case .chooseLibraryFolder:
      !app.isDeviceOperationActive
    case .rescanLibrary:
      app.library.folderURL != nil && !app.library.isScanning
    case .syncIPod:
      !app.deviceManager.devices.isEmpty && app.library.isSettled && !app.isDeviceOperationActive
    default:
      true
    }
  }

  private func clampedIndex(in results: [Item]) -> Int {
    min(max(selectedIndex, 0), results.count - 1)
  }

  private func moveSelection(by delta: Int) {
    let results = self.results
    guard !results.isEmpty else { return }
    selectedIndex = (clampedIndex(in: results) + delta + results.count) % results.count
  }

  private func activate(_ results: [Item], at index: Int? = nil) {
    guard !results.isEmpty else { return }
    let result = results[index ?? clampedIndex(in: results)]
    guard result.isEnabled else { return }
    dismiss()
    switch result.activation {
    case .music(let music):
      app.player.play(music.start, in: music.tracks)
      // Activation also reveals the hit where it lives, so searching an
      // artist lands on Artists/<name> and a song lands in the Music view.
      if let collectionID = music.collectionID {
        app.revealCollection(collectionID)
      } else {
        app.revealLibraryTrack(music.start)
      }
    case .command(let command):
      app.performQuickSearchCommand(command)
    }
  }

  private func dismiss() {
    app.dismissQuickSearch()
  }
}

/// The Cmd+K music pipeline: a `QuickSearchIndex` cached across palette
/// openings until the library changes, resolving each query to the top hits.
typealias QuickSearchMusicModel = DebouncedSearchModel<QuickSearchIndex, [QuickSearchResult]>
