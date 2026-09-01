import SwiftUI

struct CleanUpGenresSheet: View {
  enum Mode: String, CaseIterable, Identifiable {
    case one = "One per song"
    case multiple = "Keep multiple"

    var id: Self { self }
  }

  @Environment(\.dismiss) private var dismiss

  let tracks: () -> [LibraryTrack]
  let musicBrainz: any MusicBrainzService
  let genreSuggestions: [String]
  let onApply: ([TrackMetadataEdit]) async throws -> Void

  @State private var groups: [GenreCleanupGroup]?
  @State private var selections: [String: GenreCleanupSelection] = [:]
  @State private var selectedGroupIDs: Set<String> = []
  @State private var mode: Mode = .one
  @State private var skippedUnsupportedCount = 0
  @State private var usedMusicBrainzGenres = false
  @State private var isSaving = false
  @State private var saveTask: Task<Void, Never>?
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      ErrorBanner(message: errorMessage)
      Divider()
      footer
    }
    .frame(width: 760, height: 620)
    .task { await scan() }
    .interactiveDismissDisabled(isSaving)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text("Clean Up Genres")
            .font(.headline)
          Text(headerDetail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Result", selection: $mode) {
          ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 240)
      }
      if skippedUnsupportedCount > 0 {
        Text(
          skippedUnsupportedCount == 1
            ? String(localized: "1 unsupported audio file was left unchanged.")
            : String(
              localized:
                "\(skippedUnsupportedCount) unsupported audio files were left unchanged.")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  private var headerDetail: String {
    guard let groups else { return String(localized: "Scanning genre tags…") }
    if groups.isEmpty { return String(localized: "No genre tags need review.") }
    let count = groups.reduce(0) { $0 + $1.songCount }
    let comparison =
      usedMusicBrainzGenres
      ? String(localized: "Compared with MusicBrainz genres.")
      : String(localized: "Choose explicitly; MusicBrainz matching is unavailable.")
    switch (count == 1, groups.count == 1) {
    case (true, true):
      return String(localized: "Review 1 song in 1 repeated tag pattern. \(comparison)")
    case (true, false):
      return String(
        localized: "Review 1 song in \(groups.count) repeated tag patterns. \(comparison)")
    case (false, true):
      return String(localized: "Review \(count) songs in 1 repeated tag pattern. \(comparison)")
    case (false, false):
      return String(
        localized: "Review \(count) songs in \(groups.count) repeated tag patterns. \(comparison)")
    }
  }

  @ViewBuilder
  private var content: some View {
    if let groups {
      if groups.isEmpty {
        AllClearView(message: "Your genre tags already look tidy.", spacing: 9)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(groups) { group in
              groupView(group)
            }
          }
          .padding(16)
        }
      }
    } else {
      VStack(spacing: 12) {
        ProgressView()
        Text("Separating genres from other tags…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func groupView(_ group: GenreCleanupGroup) -> some View {
    let isSelected = selectedGroupIDs.contains(group.id)
    return VStack(alignment: .leading, spacing: 9) {
      HStack {
        Toggle("Include tag pattern", isOn: $selectedGroupIDs.contains(group.id))
          .labelsHidden()
          .toggleStyle(.checkbox)
          .help("Include this group in the cleanup")
          .accessibilityLabel(
            "Include \(songCountText(group.songCount)): \(group.genres.joined(separator: GenreMetadata.separator))"
          )
        Text(songCountText(group.songCount))
          .font(.callout.weight(.semibold))
        if group.hasUnrecognizedGenres {
          Label("Other tags found", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Spacer()
        Text(group.tracks.prefix(2).map(\.displayTitle).joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Text(group.genres.joined(separator: GenreMetadata.separator))
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)

      GenreEditor(
        rawValue: genresBinding(for: group),
        suggestions: genreSuggestions,
        primaryGenre: primaryBinding(for: group)
      )
      .disabled(!isSelected)

      if selections[group.id]?.primary.isEmpty == true {
        Text("Choose a primary genre by clicking a chip.")
          .font(.caption)
          .foregroundStyle(.orange)
      } else if mode == .one {
        Text("Only the starred genre will be saved.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? VFD.accent.opacity(0.07) : Color.primary.opacity(0.035))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? VFD.accent.opacity(0.25) : Color.clear))
  }

  private var footer: some View {
    SheetFooter(
      summary: footerSummary,
      cancelTitle: isSaving ? "Stop" : "Cancel",
      cancelAction: { if isSaving { saveTask?.cancel() } else { dismiss() } },
      primaryTitle: updateButtonTitle,
      primaryDisabled: isSaving || pendingEdits.isEmpty,
      isBusy: isSaving,
      primaryAction: apply)
  }

  private var selectedSongCount: Int {
    groups?.filter { selectedGroupIDs.contains($0.id) }.reduce(0) { $0 + $1.songCount } ?? 0
  }

  private var footerSummary: String {
    if selectedSongCount == 0 {
      return String(localized: "Check each tag pattern you want to change.")
    }
    return selectedSongCount == 1
      ? String(localized: "1 song selected.")
      : String(localized: "\(selectedSongCount) songs selected.")
  }

  private var updateButtonTitle: String {
    let count = pendingEdits.count
    return count == 1
      ? String(localized: "Update 1 Song") : String(localized: "Update \(count) Songs")
  }

  private var pendingEdits: [TrackMetadataEdit] {
    guard let groups else { return [] }
    return GenreCleanupPlanner.edits(
      for: groups.filter { selectedGroupIDs.contains($0.id) },
      selections: selections,
      keepMultiple: mode == .multiple)
  }

  private func primaryBinding(for group: GenreCleanupGroup) -> Binding<String> {
    Binding(
      get: { selections[group.id]?.primary ?? "" },
      set: { value in
        var selection = selections[group.id] ?? GenreCleanupSelection(group: group)
        selection.primary = value
        selections[group.id] = selection
      })
  }

  private func genresBinding(for group: GenreCleanupGroup) -> Binding<String> {
    Binding(
      get: {
        GenreMetadata.joined(
          selections[group.id]?.genres ?? GenreCleanupSelection(group: group).genres)
      },
      set: { rawValue in
        var selection = selections[group.id] ?? GenreCleanupSelection(group: group)
        selection.genres = GenreMetadata.values(from: rawValue)
        if !selection.primary.isEmpty, !selection.genres.contains(selection.primary) {
          selection.primary = selection.genres.first ?? ""
        }
        selections[group.id] = selection
      })
  }

  private func scan() async {
    let liveTracks = tracks()
    let editable = liveTracks.filter(\.supportsMetadataEditing)
    let genreNames = (try? await musicBrainz.genreNames()) ?? []
    usedMusicBrainzGenres = !genreNames.isEmpty
    let recognizedKeys = Set(genreNames.map(GenreMetadata.normalizedKey))
    skippedUnsupportedCount =
      liveTracks.filter { track in
        guard !track.supportsMetadataEditing, !track.genres.isEmpty else { return false }
        return track.genres.count > 1
          || (!recognizedKeys.isEmpty
            && track.genres.contains {
              !recognizedKeys.contains(GenreMetadata.normalizedKey($0))
            })
      }.count
    let planned = await Task.detached(priority: .userInitiated) {
      GenreCleanupPlanner.groups(in: editable, recognizedGenreNames: genreNames)
    }.value
    groups = planned
    selections = Dictionary(
      uniqueKeysWithValues: planned.map { ($0.id, GenreCleanupSelection(group: $0)) })
    selectedGroupIDs.removeAll()
  }

  private func apply() {
    let edits = pendingEdits
    guard !isSaving, !edits.isEmpty else { return }
    isSaving = true
    errorMessage = nil
    saveTask = Task {
      do {
        try await onApply(edits)
        if Task.isCancelled {
          isSaving = false
          await scan()
          saveTask = nil
          return
        }
        dismiss()
      } catch is CancellationError {
        isSaving = false
        await scan()
      } catch {
        errorMessage = error.localizedDescription
        isSaving = false
        await scan()
      }
      saveTask = nil
    }
  }

  private func songCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
  }
}
