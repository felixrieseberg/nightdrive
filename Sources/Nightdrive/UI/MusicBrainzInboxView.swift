import SwiftUI

struct MusicBrainzInboxView: View {
  @Bindable var app: AppState

  @State private var busyAlbumIDs: Set<String> = []
  @State private var isApprovingAll = false
  @State private var errorMessage: String?

  private var store: MusicBrainzSuggestionStore { app.musicBrainzSuggestions }

  var body: some View {
    VStack(spacing: 0) {
      header
      Bodywork.Seam()
      if store.suggestions.isEmpty {
        emptyState
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(store.suggestions) { suggestion in
              albumCard(suggestion)
            }
          }
          .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Bodywork.panel)
    .onChange(of: app.library.identityRevision) {
      busyAlbumIDs.removeAll()
      isApprovingAll = false
      errorMessage = nil
    }
  }

  private var header: some View {
    PaneHeader(String(localized: "Suggestions"), subtitle: headerSubtitle) {
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(2)
      }
      if app.musicBrainzAutoLookup.isRunning {
        ProgressView()
          .controlSize(.small)
          .help("Looking up albums in the background")
      }
      Button("Approve All") { approveAll() }
        .buttonStyle(.lit)
        .disabled(
          app.libraryMutationsDisabled || store.suggestions.isEmpty || isApprovingAll
            || !busyAlbumIDs.isEmpty)
    }
  }

  private var headerSubtitle: String {
    if !app.onlineServices.isEnabled {
      return String(localized: "MusicBrainz metadata lookup is turned off.")
    }
    if !app.onlineServices.isAutoLookupActive {
      return String(localized: "Automatic metadata lookup is turned off.")
    }
    return String(localized: "Matches found by automatic lookup.")
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label(emptyStateTitle, systemImage: emptyStateSymbol)
    } description: {
      Text(emptyStateDescription)
    } actions: {
      if !app.onlineServices.isAutoLookupActive {
        Button("Open Online Settings") { app.openSettings(tab: .online) }
          .buttonStyle(.lit)
      }
    }
  }

  private var emptyStateTitle: String {
    if !app.onlineServices.isEnabled { return String(localized: "MusicBrainz is Turned Off") }
    if !app.onlineServices.isAutoLookupActive {
      return String(localized: "Automatic Lookup is Turned Off")
    }
    return String(localized: "No Suggestions")
  }

  private var emptyStateSymbol: String {
    app.onlineServices.isAutoLookupActive ? "sparkles" : "network.slash"
  }

  private var emptyStateDescription: String {
    if !app.onlineServices.isEnabled {
      return String(
        localized: "Turn on MusicBrainz in Online settings to look up metadata for your library.")
    }
    if !app.onlineServices.isAutoLookupActive {
      return String(localized: "Turn on automatic lookup in Online settings to fill this inbox.")
    }
    return String(
      localized:
        "There are no metadata changes to review. New suggestions appear after your library is scanned.")
  }

  private func albumCard(_ suggestion: MusicBrainzAlbumSuggestion) -> some View {
    let isBusy = busyAlbumIDs.contains(suggestion.id) || isApprovingAll
    let libraryIdentity = app.library.identityRevision
    return VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        VStack(alignment: .leading, spacing: 1) {
          Text(suggestion.albumTitle)
            .font(.system(size: 13, weight: .semibold))
          Text(albumSubtitle(suggestion))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isBusy {
          ProgressView()
            .controlSize(.small)
        }
        Button("Dismiss") {
          dismiss(suggestion, expectedLibraryIdentity: libraryIdentity)
        }
        .disabled(app.libraryMutationsDisabled || isBusy)
        .help("Hide this suggestion and don't propose this album again")
        Button("Approve") { approve(suggestion) }
          .buttonStyle(.lit)
          .disabled(app.libraryMutationsDisabled || isBusy)
          .help("Write the proposed tags to this album's files")
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        ForEach(suggestion.tracks) { track in
          VStack(alignment: .leading, spacing: 3) {
            Text(track.displayTitle)
              .font(.system(size: 12, weight: .medium))
            MetadataChangeLines(
              changes: metadataFieldChanges(from: track.current.normalized, to: track.proposed))
          }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(.background.opacity(0.5))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.separator, lineWidth: 1)))
  }

  private func albumSubtitle(_ suggestion: MusicBrainzAlbumSuggestion) -> String {
    var parts = [suggestion.artistName]
    var release = suggestion.releaseTitle
    if suggestion.releaseYear > 0 { release += " (\(suggestion.releaseYear))" }
    parts.append(String(localized: "matched to \(release)"))
    let count = suggestion.tracks.count
    parts.append(count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs"))
    return parts.joined(separator: " · ")
  }

  private func approve(_ suggestion: MusicBrainzAlbumSuggestion) {
    guard busyAlbumIDs.insert(suggestion.id).inserted else { return }
    errorMessage = nil
    let libraryIdentity = app.library.identityRevision
    Task {
      defer {
        if app.library.identityRevision == libraryIdentity {
          busyAlbumIDs.remove(suggestion.id)
        }
      }
      do {
        try await app.approveMusicBrainzSuggestion(
          suggestion, expectedLibraryIdentity: libraryIdentity)
      } catch {
        guard app.library.identityRevision == libraryIdentity else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  private func approveAll() {
    guard !isApprovingAll else { return }
    isApprovingAll = true
    errorMessage = nil
    let pending = store.suggestions
    let libraryIdentity = app.library.identityRevision
    Task {
      defer {
        if app.library.identityRevision == libraryIdentity {
          isApprovingAll = false
        }
      }
      for suggestion in pending {
        do {
          try await app.approveMusicBrainzSuggestion(
            suggestion, expectedLibraryIdentity: libraryIdentity)
        } catch {
          guard app.library.identityRevision == libraryIdentity else { return }
          errorMessage = error.localizedDescription
          return
        }
      }
    }
  }

  private func dismiss(
    _ suggestion: MusicBrainzAlbumSuggestion,
    expectedLibraryIdentity: UInt64
  ) {
    do {
      try app.dismissMusicBrainzSuggestion(
        suggestion, expectedLibraryIdentity: expectedLibraryIdentity)
    } catch {
      guard app.library.identityRevision == expectedLibraryIdentity else { return }
      errorMessage = error.localizedDescription
    }
  }
}
