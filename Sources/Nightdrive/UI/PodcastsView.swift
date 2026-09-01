import SwiftUI

struct PodcastsView: View {
  @Environment(\.deckContentSpacing) private var deckContentSpacing
  @Bindable var app: AppState

  @State private var searchText = ""
  @State private var results: [PodcastDirectoryResult] = []
  @State private var isSearching = false
  @State private var hasSearched = false
  @State private var isRefreshing = false
  @State private var selectedFeedURL: URL?
  @State private var subscribingFeedURLs: Set<URL> = []
  @State private var expandedEpisodeIDs: Set<String> = []
  @FocusState private var searchFocused: Bool

  private var store: PodcastStore { app.podcasts }

  private struct ShowItem: Identifiable, Equatable {
    var feedURL: URL
    var title: String
    var author: String?
    var artworkURL: URL?
    var subtitle: String

    var id: URL { feedURL }

    init(feedURL: URL, title: String, author: String?, artworkURL: URL?, subtitle: String) {
      self.feedURL = feedURL
      self.title = title
      self.author = author
      self.artworkURL = artworkURL
      self.subtitle = subtitle
    }

    init(result: PodcastDirectoryResult, subtitle: String) {
      self.init(
        feedURL: result.feedURL, title: result.title, author: result.author,
        artworkURL: result.artworkURL, subtitle: subtitle)
    }

    init(subscription: PodcastSubscription, subtitle: String = "") {
      self.init(
        feedURL: subscription.feedURL, title: subscription.title, author: subscription.author,
        artworkURL: subscription.artworkURL, subtitle: subtitle)
    }
  }

  var body: some View {
    if !app.onlineServices.isPodcastsEnabled && store.subscriptions.isEmpty {
      consentEmptyState
    } else {
      HSplitView {
        showList
        detail
      }
      .task {
        await app.preloadPodcastEpisodes()
      }
      .onChange(of: selectedFeedURL) {
        guard app.onlineServices.isPodcastsEnabled,
          let url = selectedFeedURL, store.feeds[url] == nil
        else { return }
        Task { _ = await store.loadFeed(url: url) }
      }
      .onChange(of: store.subscriptions, initial: true) {
        // Selecting is pure UI state; the fetch itself stays consent-gated
        // in the selectedFeedURL handler above.
        guard selectedFeedURL == nil, !hasSearched, !isSearching else { return }
        selectedFeedURL = store.subscriptions.first?.feedURL
      }
      // A quick-search reveal wins over the default first-show selection.
      .onChange(of: app.pendingPodcastReveal, initial: true) {
        guard let feedURL = app.pendingPodcastReveal else { return }
        app.pendingPodcastReveal = nil
        selectedFeedURL = feedURL
      }
    }
  }

  // MARK: - Show list

  private var subscriptionItems: [ShowItem] {
    store.subscriptions.map {
      ShowItem(subscription: $0, subtitle: subscriptionSubtitle($0))
    }
  }

  /// The popular chart, minus shows the user already subscribes to.
  private var popularItems: [ShowItem] {
    let subscribed = Set(store.subscriptions.map(\.feedURL))
    return store.popular
      .filter { !subscribed.contains($0.feedURL) }
      .map { ShowItem(result: $0, subtitle: resultSubtitle($0)) }
  }

  private var showItems: [ShowItem] {
    if hasSearched || isSearching {
      return results.map { ShowItem(result: $0, subtitle: resultSubtitle($0)) }
    }
    return subscriptionItems + popularItems
  }

  private var showList: some View {
    VStack(spacing: 0) {
      searchField
      if let error = store.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.bottom, 6)
      }
      Bodywork.Seam()
      List(selection: $selectedFeedURL) {
        if isSearching {
          HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Searching…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } else if hasSearched && results.isEmpty {
          Text("No shows matched “\(searchText)”.")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if hasSearched {
          ForEach(showItems) { item in
            showRow(item)
              .tag(item.feedURL)
          }
        } else {
          if !subscriptionItems.isEmpty {
            Section("Subscriptions") {
              ForEach(subscriptionItems) { item in
                showRow(item)
                  .tag(item.feedURL)
              }
            }
          }
          if !popularItems.isEmpty {
            Section("Popular") {
              ForEach(popularItems) { item in
                showRow(item)
                  .tag(item.feedURL)
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .background(Bodywork.well)
    .overlay(alignment: .trailing) {
      Bodywork.Seam(axis: .vertical, verticalHitPlacement: .insideTrailingEdge)
    }
    .frame(minWidth: 210, idealWidth: 260)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
        TextField("Search Podcasts", text: $searchText)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit { search() }
          .disabled(!app.onlineServices.isPodcastsEnabled)
        if hasSearched || !searchText.isEmpty {
          Button {
            searchText = ""
            results = []
            hasSearched = false
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.borderless)
          .help("Clear search and show subscriptions")
        }
      }
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(.black.opacity(0.35))
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .strokeBorder(
                searchFocused ? VFD.accent.opacity(0.45) : .white.opacity(0.09),
                lineWidth: 1))
      )
      if !store.subscriptions.isEmpty && searchText.isEmpty && !hasSearched {
        Button {
          Task { await refreshAllFeeds() }
        } label: {
          if isRefreshing {
            ProgressView().controlSize(.small)
          } else {
            Image(systemName: "arrow.clockwise")
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.borderless)
        .disabled(!app.onlineServices.isPodcastsEnabled || isRefreshing)
        .help("Check all shows for new episodes")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func showRow(_ item: ShowItem) -> some View {
    HStack(spacing: 10) {
      artwork(url: item.artworkURL, size: 40, cornerRadius: 4)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .lineLimit(1)
        Text(item.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 2)
  }

  private static func episodeCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 episode") : String(localized: "\(count) episodes")
  }

  private func resultSubtitle(_ result: PodcastDirectoryResult) -> String {
    var parts: [String] = []
    if !result.author.isEmpty { parts.append(result.author) }
    if result.episodeCount > 0 {
      parts.append(Self.episodeCountText(result.episodeCount))
    }
    return parts.joined(separator: " · ")
  }

  private func subscriptionSubtitle(_ subscription: PodcastSubscription) -> String {
    if let feed = store.feeds[subscription.feedURL] {
      return Self.episodeCountText(feed.episodes.count)
    }
    return subscription.author ?? ""
  }

  // MARK: - Detail

  private var selectedItem: ShowItem? {
    guard let url = selectedFeedURL else { return nil }
    if let item = showItems.first(where: { $0.feedURL == url }) { return item }
    if let subscription = store.subscriptions.first(where: { $0.feedURL == url }) {
      return ShowItem(subscription: subscription)
    }
    if let feed = store.feeds[url] {
      return ShowItem(
        feedURL: url, title: feed.title, author: feed.author, artworkURL: feed.artworkURL,
        subtitle: "")
    }
    return nil
  }

  @ViewBuilder
  private var detail: some View {
    // A stable greedy backdrop keeps the split divider where the user put it
    // when the branches below swap (empty state <-> show view).
    ZStack {
      Color.clear
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      if let item = selectedItem {
        VStack(spacing: 0) {
          showHeader(item)
          Bodywork.Seam()
          episodeList(item)
        }
      } else if store.subscriptions.isEmpty && store.popular.isEmpty && !hasSearched
        && !isSearching
      {
        ContentUnavailableView {
          Label("No Subscriptions", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
          Text(
            "Search for a show and subscribe. Downloaded episodes join your library and sync to your iPod's Podcasts menu."
          )
        }
      } else {
        ContentUnavailableView(
          "No Show Selected",
          systemImage: "antenna.radiowaves.left.and.right",
          description: Text("Choose a show to browse its episodes."))
      }
    }
    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .leading) {
      Bodywork.Seam(
        axis: .vertical, verticalHitPlacement: .insideLeadingEdge,
        showsSeparator: false)
    }
  }

  private func showHeader(_ item: ShowItem) -> some View {
    let feed = store.feeds[item.feedURL]
    let subscription = store.subscriptions.first { $0.feedURL == item.feedURL }
    let subscribing = subscribingFeedURLs.contains(item.feedURL)
    return HStack(spacing: 16) {
      // Prefer the artwork URL the show list already displayed so the image
      // does not reload (and flash) when the feed finishes loading and
      // contributes its own artwork URL.
      artwork(url: item.artworkURL ?? feed?.artworkURL, size: 76, cornerRadius: 7)
        .shadow(color: .black.opacity(0.16), radius: 3, y: 2)
      VStack(alignment: .leading, spacing: 4) {
        Text(String(localized: "Podcast").uppercased())
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.secondary)
        Text(feed?.title ?? item.title)
          .font(.title2)
          .fontWeight(.semibold)
          .lineLimit(2)
        Text(showSummary(item, feed: feed))
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if subscribing {
        ProgressView()
          .controlSize(.small)
      }
      if let subscription {
        automationMenu(subscription)
        Button("Unsubscribe") { store.unsubscribe(subscription) }
          .help("Stop following this show; downloaded episodes stay in your library")
      } else {
        Button("Subscribe") { subscribe(item) }
          .buttonStyle(.lit)
          .disabled(subscribing || !app.onlineServices.isPodcastsEnabled)
          .help("Follow this show and check it for new episodes")
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, max(0, 14 - deckContentSpacing))
    .padding(.bottom, 14)
    .background(Bodywork.raised)
  }

  private static let autoDownloadChoices = [0, 1, 3, 5, 10]

  private func automationMenu(_ subscription: PodcastSubscription) -> some View {
    Menu {
      Picker(
        "Download new episodes",
        selection: Binding(
          get: { subscription.autoDownloadCount },
          set: {
            store.setAutoDownloadCount($0, for: subscription)
            runMaintenanceNow()
          })
      ) {
        ForEach(Self.autoDownloadChoices, id: \.self) { count in
          Text(Self.autoDownloadLabel(count)).tag(count)
        }
      }
      Menu("Delete episodes") {
        Toggle(
          "Delete played episodes",
          isOn: Binding(
            get: { subscription.removePlayedEpisodes },
            set: {
              store.setRemovePlayedEpisodes($0, for: subscription)
              runMaintenanceNow()
            }))
        Picker(
          "Delete older episodes",
          selection: Binding(
            get: { subscription.autoDeleteKeepCount },
            set: {
              store.setAutoDeleteKeepCount($0, for: subscription)
              runMaintenanceNow()
            })
        ) {
          ForEach(Self.autoDownloadChoices, id: \.self) { count in
            Text(Self.autoDeleteLabel(count)).tag(count)
          }
        }
      }
    } label: {
      Image(systemName: "gearshape")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .accessibilityLabel("Automation")
    .help(
      "Automatically download new episodes and delete played or older downloads"
    )
  }

  /// Changed automation settings take effect immediately rather than on the
  /// next refresh or sync.
  private func runMaintenanceNow() {
    guard app.onlineServices.isPodcastsEnabled else { return }
    Task { await store.performMaintenance() }
  }

  private static func autoDownloadLabel(_ count: Int) -> String {
    switch count {
    case 0: String(localized: "Off")
    case 1: String(localized: "Latest episode")
    default: String(localized: "Latest \(count) episodes")
    }
  }

  private static func autoDeleteLabel(_ count: Int) -> String {
    switch count {
    case 0: String(localized: "Never delete older episodes")
    case 1: String(localized: "Delete all but latest episode")
    default: String(localized: "Delete all but latest \(count) episodes")
    }
  }

  private func showSummary(_ item: ShowItem, feed: PodcastFeed?) -> String {
    var parts: [String] = []
    if let author = feed?.author ?? item.author, !author.isEmpty { parts.append(author) }
    if let feed {
      parts.append(Self.episodeCountText(feed.episodes.count))
      let downloaded = feed.episodes.filter {
        if case .downloaded = store.episodeStates[$0.id] { return true }
        return false
      }.count
      if downloaded > 0 {
        parts.append(String(localized: "\(downloaded) downloaded"))
      }
    }
    return parts.joined(separator: " · ")
  }

  @ViewBuilder
  private func episodeList(_ item: ShowItem) -> some View {
    if let feed = store.feeds[item.feedURL] {
      if feed.episodes.isEmpty {
        ContentUnavailableView(
          "No Episodes",
          systemImage: "antenna.radiowaves.left.and.right",
          description: Text("This feed has no episodes."))
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(feed.episodes) { episode in
              episodeRow(episode)
              Divider()
                .padding(.leading, 20)
            }
          }
        }
      }
    } else if !app.onlineServices.isPodcastsEnabled {
      podcastsOffState(
        "Turn on podcasts in Online settings to load this show's episodes.")
    } else {
      VStack(spacing: 8) {
        ProgressView()
        Text("Loading episodes…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  // MARK: - Episodes

  private func episodeRow(_ episode: PodcastEpisode) -> some View {
    let expanded = expandedEpisodeIDs.contains(episode.id)
    return HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(episode.title)
          .font(.system(size: 12, weight: .medium))
        Text(episodeSubtitle(episode))
          .font(.caption)
          .foregroundStyle(.secondary)
        if case .downloaded = store.episodeStates[episode.id] ?? .notDownloaded {
          downloadedLine(episode)
        }
        if let description = episode.episodeDescription, !description.isEmpty {
          Text(Self.linkified(description))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(expanded ? nil : 2)
            .textSelection(.enabled)
          if expanded || Self.likelyTruncated(description) {
            Button(expanded ? String(localized: "Less") : String(localized: "More")) {
              toggleExpanded(episode)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(VFD.accent)
            .demoTarget("podcast.episode.more") { toggleExpanded(episode) }
          }
        }
      }
      Spacer()
      episodeAction(episode)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private func episodeAction(_ episode: PodcastEpisode) -> some View {
    switch store.episodeStates[episode.id] ?? .notDownloaded {
    case .notDownloaded:
      Button("Download") {
        Task { await store.download(episode) }
      }
      .buttonStyle(.lit)
      .disabled(app.libraryMutationsDisabled || !app.onlineServices.isPodcastsEnabled)
      .help("Download this episode into your library")
    case .downloading(let progress):
      ProgressView(value: max(progress, 0.02))
        .progressViewStyle(.linear)
        .frame(width: 72)
        .help("Downloading…")
    case .downloaded:
      if let track = libraryTrack(for: episode) {
        playButton(for: track)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(VFD.accent)
          .help("Downloaded")
      }
    case .failed(let message):
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .help(message)
        Button("Retry") {
          Task { await store.download(episode) }
        }
        .disabled(app.libraryMutationsDisabled || !app.onlineServices.isPodcastsEnabled)
      }
    }
  }

  @ViewBuilder
  private func playButton(for track: LibraryTrack) -> some View {
    let isCurrent = app.player.currentTrack?.id == track.id
    let showsPause = isCurrent && app.player.isPlaying
    Button {
      if isCurrent {
        app.player.togglePlayPause()
      } else {
        app.player.play(track, in: episodeQueue(containing: track))
      }
    } label: {
      Label(
        showsPause ? String(localized: "Pause") : String(localized: "Play"),
        systemImage: showsPause ? "pause.fill" : "play.fill")
    }
    .buttonStyle(.lit)
    .help(
      showsPause
        ? String(localized: "Pause")
        : String(localized: "Play this episode"))
  }

  /// Sits with the episode's metadata so the trailing edge keeps a single
  /// primary action: the downloaded marker doubles as the home of Remove.
  private func downloadedLine(_ episode: PodcastEpisode) -> some View {
    HStack(spacing: 5) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(VFD.accent)
      Text("Downloaded")
        .foregroundStyle(.secondary)
      Button("Remove") { store.deleteDownload(episode) }
        .buttonStyle(.borderless)
        .foregroundStyle(VFD.accent)
        .disabled(app.libraryMutationsDisabled)
        .help("Delete the downloaded file from your library")
    }
    .font(.caption)
  }

  /// The downloaded episodes of the selected show, in feed order, so
  /// playback continues with the next downloaded episode.
  private func episodeQueue(containing track: LibraryTrack) -> [LibraryTrack] {
    guard let feedURL = selectedFeedURL, let feed = store.feeds[feedURL] else { return [track] }
    let tracks = feed.episodes.compactMap { libraryTrack(for: $0) }
    return tracks.contains { $0.id == track.id } ? tracks : [track]
  }

  private func libraryTrack(for episode: PodcastEpisode) -> LibraryTrack? {
    guard let url = store.localFileURL(for: episode) else { return nil }
    return app.library.track(at: url)
  }

  private func toggleExpanded(_ episode: PodcastEpisode) {
    if expandedEpisodeIDs.contains(episode.id) {
      expandedEpisodeIDs.remove(episode.id)
    } else {
      expandedEpisodeIDs.insert(episode.id)
    }
  }

  /// Two caption lines hold roughly this much text; anything longer earns the
  /// More toggle. Exact truncation depends on the pane width, so a slightly
  /// eager toggle is preferable to a missing one.
  private static func likelyTruncated(_ description: String) -> Bool {
    description.count > 120 || description.contains("\n")
  }

  /// Marks bare URLs in a plain-text description as tappable links.
  private static let linkDetector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)

  private static func linkified(_ description: String) -> AttributedString {
    var attributed = AttributedString(description)
    guard let detector = linkDetector else { return attributed }
    let fullRange = NSRange(description.startIndex..., in: description)
    for match in detector.matches(in: description, options: [], range: fullRange) {
      guard let url = match.url,
        let stringRange = Range(match.range, in: description),
        let range = Range(stringRange, in: attributed)
      else { continue }
      attributed[range].link = url
      attributed[range].foregroundColor = VFD.accent
      attributed[range].underlineStyle = .single
    }
    return attributed
  }

  private func episodeSubtitle(_ episode: PodcastEpisode) -> String {
    var parts: [String] = []
    if let date = episode.publishedAt {
      parts.append(date.formatted(date: .abbreviated, time: .omitted))
    }
    if let seconds = episode.durationSeconds, seconds > 0 {
      parts.append(Self.durationText(seconds: seconds))
    }
    if let number = episode.episodeNumber {
      parts.append(String(localized: "Episode \(number)"))
    }
    return parts.joined(separator: " · ")
  }

  private static func durationText(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
  }

  // MARK: - Shared pieces

  private func podcastsOffState(_ description: LocalizedStringKey) -> some View {
    ContentUnavailableView {
      Label("Podcasts are Turned Off", systemImage: "network.slash")
    } description: {
      Text(description)
    } actions: {
      Button("Open Online Settings") { app.openSettings(tab: .online) }
        .buttonStyle(.lit)
    }
  }

  private var consentEmptyState: some View {
    podcastsOffState(
      "Turn on podcasts in Online settings to search for shows and download episodes."
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Bodywork.panel)
  }

  private func artwork(url: URL?, size: CGFloat, cornerRadius: CGFloat) -> some View {
    // Artwork is remote content too: while podcast consent is off, show the
    // placeholder instead of fetching from Apple's CDN or the publisher.
    AsyncImage(url: app.onlineServices.isPodcastsEnabled ? url : nil) { phase in
      if let image = phase.image {
        image.resizable().aspectRatio(contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: cornerRadius)
          .fill(.quaternary)
          .overlay(
            Image(systemName: "antenna.radiowaves.left.and.right")
              .foregroundStyle(.secondary))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
  }

  // MARK: - Actions

  private func refreshAllFeeds() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    await store.refreshAll()
    await store.performMaintenance()
    isRefreshing = false
  }

  private func search() {
    let term = searchText.trimmingCharacters(in: .whitespaces)
    guard !term.isEmpty, !isSearching else { return }
    isSearching = true
    hasSearched = true
    Task {
      results = await store.search(term: term)
      isSearching = false
      if let selectedFeedURL, !results.contains(where: { $0.feedURL == selectedFeedURL }) {
        self.selectedFeedURL = results.first?.feedURL
      } else if selectedFeedURL == nil {
        selectedFeedURL = results.first?.feedURL
      }
    }
  }

  private func subscribe(_ item: ShowItem) {
    guard subscribingFeedURLs.insert(item.feedURL).inserted else { return }
    Task {
      if let result = results.first(where: { $0.feedURL == item.feedURL }) {
        await store.subscribe(result)
      } else {
        await store.subscribe(feedURL: item.feedURL)
      }
      subscribingFeedURLs.remove(item.feedURL)
    }
  }
}
