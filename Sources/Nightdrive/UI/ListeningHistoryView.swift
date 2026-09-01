import SwiftUI

struct TrackRatingControl: View {
  @Bindable var store: ListeningHistoryStore
  let trackID: TrackID
  let mutationErrors: ListeningHistoryMutationErrors
  var mutationsDisabled = false
  var onToggleFavorite: ((TrackID) throws -> Void)?
  var onSetRating: ((Int, TrackID) throws -> Void)?

  var body: some View {
    HStack(spacing: 3) {
      Button {
        mutations.toggleFavorite(trackID)
      } label: {
        Image(systemName: store.isFavorite(trackID) ? "heart.fill" : "heart")
          .foregroundStyle(store.isFavorite(trackID) ? .red : .secondary)
      }
      .buttonStyle(.borderless)
      .disabled(mutationsDisabled)
      .help(
        store.isFavorite(trackID)
          ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"))

      ForEach(1...5, id: \.self) { rating in
        Button {
          let newRating = store.rating(for: trackID) == rating ? 0 : rating
          mutations.setRating(newRating, for: trackID)
        } label: {
          Image(systemName: rating <= store.rating(for: trackID) ? "star.fill" : "star")
            .foregroundStyle(rating <= store.rating(for: trackID) ? .yellow : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(mutationsDisabled)
        .help(rating == 1 ? String(localized: "1 star") : String(localized: "\(rating) stars"))
      }
    }
  }

  private var mutations: ListeningHistoryMutationActions {
    ListeningHistoryMutationActions(
      store: store,
      errors: mutationErrors,
      onToggleFavorite: onToggleFavorite,
      onSetRating: onSetRating)
  }
}

struct ListeningHistoryView: View {
  static let headerHeight: CGFloat = ChassisMetrics.paneHeaderHeight

  enum Section: String, CaseIterable, Identifiable {
    case favorites = "Favorites"
    case recent = "Recently Played"

    var id: Self { self }
  }

  @Bindable var store: ListeningHistoryStore
  let catalog: LibraryCatalog
  @Binding var section: Section
  var trackSelection: Binding<Set<TrackID>> = .constant([])
  var mutationsDisabled = false
  var onToggleFavorite: ((TrackID) throws -> Void)?
  var onSetRating: ((Int, TrackID) throws -> Void)?
  var onResetStatistics: ((TrackID) throws -> Void)?
  var onPlay: ((LibraryTrack) -> Void)?

  @State private var mutationErrors = ListeningHistoryMutationErrors()

  var body: some View {
    VStack(spacing: 0) {
      header
      Bodywork.Seam()

      if rows.isEmpty {
        ContentUnavailableView {
          Label(
            section == .favorites
              ? String(localized: "No Favorites") : String(localized: "Nothing Played Yet"),
            systemImage: section == .favorites ? "heart" : "clock")
        } description: {
          Text(
            section == .favorites
              ? String(localized: "Mark songs with the heart button to see them here.")
              : String(localized: "Songs appear here after playback is recorded."))
        } actions: {
          if section == .favorites && recentPlayCount > 0 {
            Button(recentPlaysButtonTitle) { section = .recent }
              .buttonStyle(.lit)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(rows, selection: trackSelection) { row in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(row.track.displayTitle)
              HStack {
                Text(row.track.artist)
                if let date = row.playedAt {
                  Text("•")
                  LastPlayedLabel(date: date)
                }
                if row.source == .device {
                  Image(systemName: "ipod")
                    .accessibilityLabel("Played on iPod")
                    .help("Played on iPod")
                }
                if row.metadata.playCount > 0 {
                  Text(
                    row.metadata.playCount == 1
                      ? String(localized: "• 1 play")
                      : String(localized: "• \(row.metadata.playCount) plays"))
                }
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
            Spacer()
            TrackRatingControl(
              store: store,
              trackID: row.track.id,
              mutationErrors: mutationErrors,
              mutationsDisabled: mutationsDisabled,
              onToggleFavorite: onToggleFavorite,
              onSetRating: onSetRating)
          }
          .contentShape(Rectangle())
          .tag(row.track.id)
          .onTapGesture(count: 2) { onPlay?(row.track) }
          .contextMenu {
            Button("Play") { onPlay?(row.track) }
            if section == .recent {
              Button("Reset Play Statistics", role: .destructive) {
                mutations.resetStatistics(for: row.track.id)
              }
              .disabled(mutationsDisabled)
            }
          }
        }
        .trackCommands(selection: trackSelection, visibleIDs: visibleTrackIDs)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onChange(of: visibleTrackIDs) {
      trackSelection.wrappedValue.formIntersection(visibleTrackIDs)
    }
    .clearsTrackSelection(trackSelection, when: rows.isEmpty)
    .errorAlert("Listening History Couldn’t Be Changed", message: Bindable(mutationErrors).message)
  }

  private var mutations: ListeningHistoryMutationActions {
    ListeningHistoryMutationActions(
      store: store,
      errors: mutationErrors,
      onToggleFavorite: onToggleFavorite,
      onSetRating: onSetRating,
      onResetStatistics: onResetStatistics)
  }

  private var header: some View {
    PaneHeader(
      String(localized: "Listening"), subtitle: String(localized: "Favorites and recent plays"))
  }

  private var recentPlaysButtonTitle: String {
    recentPlayCount == 1
      ? String(localized: "View 1 Recent Play")
      : String(localized: "View \(recentPlayCount) Recent Plays")
  }

  private var recentPlayCount: Int {
    store.recentTracks(from: catalog).count
  }

  private var visibleTrackIDs: Set<TrackID> {
    Set(rows.map(\.track.id))
  }

  private var rows: [ListeningHistoryRow] {
    switch section {
    case .favorites:
      return store.favoriteTracks(from: catalog.tracks).map {
        ListeningHistoryRow(
          id: "favorite-\($0.id.rawValue)",
          track: $0,
          metadata: store.metadata(for: $0.id),
          playedAt: store.metadata(for: $0.id).lastPlayedAt,
          source: nil)
      }
    case .recent:
      return store.history.compactMap { entry in
        guard let track = catalog[entry.trackID] else { return nil }
        return ListeningHistoryRow(
          id: entry.id.uuidString,
          track: track,
          metadata: store.metadata(for: track.id),
          playedAt: entry.playedAt,
          source: entry.source)
      }
    }
  }
}

@Observable
@MainActor
final class ListeningHistoryMutationErrors {
  var message: String?

  func perform(_ operation: () throws -> Void) {
    message = nil
    attempt(operation) { message = $0 }
  }

  func dismiss() {
    message = nil
  }
}

/// Routes every listening-history control through the same persistence-error
/// boundary, whether the control mutates the store directly or delegates to
/// AppState so transition guards can run first.
@MainActor
struct ListeningHistoryMutationActions {
  let store: ListeningHistoryStore
  let errors: ListeningHistoryMutationErrors
  var onToggleFavorite: ((TrackID) throws -> Void)? = nil
  var onSetRating: ((Int, TrackID) throws -> Void)? = nil
  var onResetStatistics: ((TrackID) throws -> Void)? = nil

  func toggleFavorite(_ trackID: TrackID) {
    errors.perform {
      if let onToggleFavorite {
        try onToggleFavorite(trackID)
      } else {
        try store.toggleFavorite(trackID)
      }
    }
  }

  func setRating(_ rating: Int, for trackID: TrackID) {
    errors.perform {
      if let onSetRating {
        try onSetRating(rating, trackID)
      } else {
        try store.setRating(rating, for: trackID)
      }
    }
  }

  func resetStatistics(for trackID: TrackID) {
    errors.perform {
      if let onResetStatistics {
        try onResetStatistics(trackID)
      } else {
        try store.resetStatistics(for: trackID)
      }
    }
  }
}

private struct LastPlayedLabel: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      Text(lastPlayedText(for: date, relativeTo: context.date))
    }
  }
}

func lastPlayedText(
  for date: Date,
  relativeTo now: Date = Date(),
  calendar: Calendar = .autoupdatingCurrent,
  locale: Locale = .autoupdatingCurrent
) -> String {
  let playedDay = calendar.startOfDay(for: date)
  let today = calendar.startOfDay(for: now)

  if playedDay == today {
    return String(localized: "Last played today")
  }
  if playedDay == calendar.date(byAdding: .day, value: -1, to: today) {
    return String(localized: "Last played yesterday")
  }
  if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: today),
    playedDay >= sixDaysAgo, playedDay < today
  {
    let weekday = formatted(date, template: "EEEE", calendar: calendar, locale: locale)
    return String(localized: "Last played on \(weekday)")
  }

  let includeYear = calendar.component(.year, from: date) != calendar.component(.year, from: now)
  let template = includeYear ? "MMMMdyyyy" : "MMMMd"
  let formattedDate = formatted(date, template: template, calendar: calendar, locale: locale)
  return String(localized: "Last played on \(formattedDate)")
}

private func formatted(
  _ date: Date,
  template: String,
  calendar: Calendar,
  locale: Locale
) -> String {
  let formatter = DateFormatter()
  formatter.calendar = calendar
  formatter.locale = locale
  formatter.timeZone = calendar.timeZone
  formatter.setLocalizedDateFormatFromTemplate(template)
  return formatter.string(from: date)
}

private struct ListeningHistoryRow: Identifiable {
  let id: String
  let track: LibraryTrack
  let metadata: TrackListeningMetadata
  let playedAt: Date?
  let source: ListeningHistorySource?
}
