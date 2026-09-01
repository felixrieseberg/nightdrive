import SwiftUI

@MainActor
struct MusicBrainzLookupContext {
  let policy: OnlineServicesPolicy
  let service: any MusicBrainzService
}

private struct MusicBrainzConsentGate: View {
  let policy: OnlineServicesPolicy
  let onAllowed: () -> Void
  let onDeclined: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label("Look up metadata online?", systemImage: "network")
        .font(.title3.weight(.semibold))
      Text(
        policy.consent == .disabled
          ? String(
            localized:
              "Online lookups are currently turned off in Settings → Online. Turning them on lets Nightdrive search MusicBrainz when you ask it to."
          )
          : String(
            localized:
              "Nightdrive can search MusicBrainz, an open, non-profit music encyclopedia, for better tags.")
      )
      .fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: 6) {
        bullet(String(localized: "Only the artist, album, and song title tags are sent."))
        bullet(
          String(localized: "Your audio files, file paths, and listening history never leave this Mac."))
        bullet(
          String(
            localized:
              "After enabling, Nightdrive also looks up albums missing MusicBrainz tags in the background and queues the matches as suggestions for your review — turn this off anytime in Settings → Online."
          ))
        bullet(String(localized: "Nothing is written to your files until you approve it."))
      }
      Link(
        "MetaBrainz privacy policy",
        destination: URL(string: "https://metabrainz.org/privacy")!
      )
      .font(.callout)

      Spacer(minLength: 0)
      HStack {
        Spacer()
        Button("Don't Allow", role: .cancel) {
          if policy.consent == .unset { policy.setConsent(.disabled) }
          onDeclined()
        }
        .keyboardShortcut(.cancelAction)
        Button("Allow Lookups") {
          policy.setConsent(.enabled)
          onAllowed()
        }
        .buttonStyle(.lit)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
  }

  private func bullet(_ text: String) -> some View {
    HStack(alignment: .top, spacing: 7) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 12))
        .foregroundStyle(.tint)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct MetadataFieldChange: Identifiable, Equatable {
  let field: String
  let current: String
  let proposed: String

  var id: String { field }
}

func metadataFieldChanges(
  from current: TrackMetadata, to proposed: TrackMetadata
) -> [MetadataFieldChange] {
  var changes: [MetadataFieldChange] = []
  func text(_ field: String, _ keyPath: KeyPath<TrackMetadata, String>) {
    let old = current[keyPath: keyPath]
    let new = proposed[keyPath: keyPath]
    if old != new { changes.append(MetadataFieldChange(field: field, current: old, proposed: new)) }
  }
  func number(_ field: String, _ keyPath: KeyPath<TrackMetadata, Int>) {
    let old = current[keyPath: keyPath]
    let new = proposed[keyPath: keyPath]
    if old != new {
      changes.append(
        MetadataFieldChange(
          field: field,
          current: old == 0 ? "—" : String(old),
          proposed: new == 0 ? "—" : String(new)))
    }
  }
  text(String(localized: "Title"), \.title)
  text(String(localized: "Artist"), \.artist)
  text(String(localized: "Album"), \.album)
  text(String(localized: "Album Artist"), \.albumArtist)
  number(String(localized: "Year"), \.year)
  number(String(localized: "Track"), \.trackNumber)
  number(String(localized: "Track Count"), \.trackCount)
  number(String(localized: "Disc"), \.discNumber)
  number(String(localized: "Disc Count"), \.discCount)
  let hadIDs = !current.musicBrainzRecordingID.isEmpty || !current.musicBrainzReleaseID.isEmpty
  let hasIDs = !proposed.musicBrainzRecordingID.isEmpty || !proposed.musicBrainzReleaseID.isEmpty
  if (current.musicBrainzRecordingID, current.musicBrainzReleaseID, current.musicBrainzArtistID)
    != (proposed.musicBrainzRecordingID, proposed.musicBrainzReleaseID, proposed.musicBrainzArtistID)
  {
    changes.append(
      MetadataFieldChange(
        field: String(localized: "MusicBrainz IDs"),
        current: hadIDs ? String(localized: "Tagged") : "—",
        proposed: hasIDs ? String(localized: "Updated") : "—"))
  }
  return changes
}

func metadataApplying(
  candidate: MusicBrainzRecordingCandidate, to current: TrackMetadata
) -> TrackMetadata {
  var proposed = current
  if !candidate.title.isEmpty { proposed.title = candidate.title }
  if !candidate.artistName.isEmpty { proposed.artist = candidate.artistName }
  if !candidate.releaseTitle.isEmpty { proposed.album = candidate.releaseTitle }
  if candidate.year > 0 { proposed.year = candidate.year }
  if candidate.trackNumber > 0 { proposed.trackNumber = candidate.trackNumber }
  if candidate.trackCount > 0 { proposed.trackCount = candidate.trackCount }
  if candidate.discNumber > 0 { proposed.discNumber = candidate.discNumber }
  proposed.musicBrainzRecordingID = candidate.recordingID
  proposed.musicBrainzReleaseID = candidate.releaseID
  proposed.musicBrainzArtistID = candidate.artistID
  return proposed.normalized
}

// MARK: - Shared sheet chrome

private func lookupHeader(_ title: String) -> some View {
  HStack {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
    Spacer()
  }
  .padding(.horizontal, 16)
  .padding(.vertical, 12)
}

private func lookupRowText(_ title: String, _ subtitle: String) -> some View {
  VStack(alignment: .leading, spacing: 2) {
    Text(title)
      .font(.system(size: 13, weight: .medium))
    Text(subtitle)
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

private func lookupSubtitle(_ parts: [String?], score: Int) -> String {
  (parts.compactMap { $0 } + ["Score \(score)"]).joined(separator: " · ")
}

@MainActor
private func lookupStep<T>(
  _ work: @escaping () async throws -> T,
  onSuccess: @escaping @MainActor (T) -> Void,
  onFailure: @escaping @MainActor (String) -> Void
) -> Task<Void, Never> {
  Task {
    do {
      let value = try await work()
      guard !Task.isCancelled else { return }
      onSuccess(value)
    } catch {
      guard !Task.isCancelled else { return }
      onFailure(error.localizedDescription)
    }
  }
}

private struct LookupProgressView: View {
  let label: String
  var note: String?
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 10) {
      ProgressView()
      Text(label)
        .font(.callout)
        .foregroundStyle(.secondary)
      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      Button("Cancel", role: .cancel, action: onCancel)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct LookupFailureView: View {
  let message: String
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
      Button("Close", action: onClose)
    }
    .padding(20)
    .frame(maxHeight: .infinity)
  }
}

private struct LookupEmptyView: View {
  let title: String
  let description: String
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      ContentUnavailableView(
        title, systemImage: "magnifyingglass", description: Text(description))
      Button("Close", action: onClose)
        .padding(.bottom, 16)
    }
  }
}

private struct LookupCandidateList<Candidate: Identifiable, Row: View>: View {
  let candidates: [Candidate]
  let onPick: (Candidate) -> Void
  let onCancel: () -> Void
  @ViewBuilder let row: (Candidate) -> Row

  var body: some View {
    VStack(spacing: 0) {
      List(candidates) { candidate in
        Button {
          onPick(candidate)
        } label: {
          row(candidate)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Divider()
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
      }
      .padding(12)
    }
  }
}

// MARK: - Single-track lookup

struct MusicBrainzRecordingLookupSheet: View {
  @Environment(\.dismiss) private var dismiss

  let context: MusicBrainzLookupContext
  let current: TrackMetadata
  let onApply: (TrackMetadata) -> Void

  private enum Phase {
    case consent
    case searching
    case candidates([MusicBrainzRecordingCandidate])
    case failed(String)
  }

  @State private var phase: Phase = .searching
  @State private var selected: MusicBrainzRecordingCandidate?
  @State private var lookupTask: Task<Void, Never>?

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .frame(width: 520, height: 480)
    .onAppear {
      if context.policy.isEnabled {
        beginSearch()
      } else {
        phase = .consent
      }
    }
    .onDisappear { lookupTask?.cancel() }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .consent:
      MusicBrainzConsentGate(
        policy: context.policy,
        onAllowed: { beginSearch() },
        onDeclined: { dismiss() })
    case .searching:
      LookupProgressView(label: String(localized: "Searching MusicBrainz…")) {
        lookupTask?.cancel()
        dismiss()
      }
    case .failed(let message):
      LookupFailureView(message: message) { dismiss() }
    case .candidates(let candidates):
      if candidates.isEmpty {
        LookupEmptyView(
          title: String(localized: "No matches"),
          description: String(
            localized: "MusicBrainz found nothing for this song's artist and title.")
        ) { dismiss() }
      } else if let selected {
        reviewPane(selected)
      } else {
        candidatePicker(candidates)
      }
    }
  }

  private func candidatePicker(_ candidates: [MusicBrainzRecordingCandidate]) -> some View {
    VStack(spacing: 0) {
      lookupHeader("Pick the matching recording")
      LookupCandidateList(
        candidates: candidates,
        onPick: { selected = $0 },
        onCancel: { dismiss() }
      ) { candidate in
        lookupRowText(candidate.title, candidateSubtitle(candidate))
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func reviewPane(_ candidate: MusicBrainzRecordingCandidate) -> some View {
    let proposed = metadataApplying(candidate: candidate, to: current)
    let changes = metadataFieldChanges(from: current.normalized, to: proposed)
    return VStack(spacing: 0) {
      lookupHeader("Review the proposed changes")
      if changes.isEmpty {
        ContentUnavailableView(
          "Already matching",
          systemImage: "checkmark.circle",
          description: Text("This song's tags already match the selected recording."))
      } else {
        MetadataChangeTable(changes: changes)
      }
      Divider()
      HStack {
        Button("Back") { selected = nil }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Use These Values") {
          onApply(proposed)
          dismiss()
        }
        .buttonStyle(.lit)
        .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
  }

  private func candidateSubtitle(_ candidate: MusicBrainzRecordingCandidate) -> String {
    lookupSubtitle(
      [
        candidate.artistName.isEmpty ? nil : candidate.artistName,
        candidate.releaseTitle.isEmpty ? nil : candidate.releaseTitle,
        candidate.year > 0 ? String(candidate.year) : nil,
        candidate.trackNumber > 0 ? String(localized: "Track \(candidate.trackNumber)") : nil,
      ],
      score: candidate.score)
  }

  private func beginSearch() {
    phase = .searching
    let service = context.service
    let current = current
    lookupTask = lookupStep {
      try await service.searchRecordings(
        title: current.title, artist: current.artist, album: current.album)
    } onSuccess: { candidates in
      phase = .candidates(candidates)
    } onFailure: { message in
      phase = .failed(message)
    }
  }
}

struct MetadataChangeLines: View {
  let changes: [MetadataFieldChange]

  var body: some View {
    ForEach(changes) { change in
      HStack(spacing: 6) {
        Text(change.field)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 105, alignment: .leading)
        Text(change.current.isEmpty ? "—" : change.current)
          .foregroundStyle(.secondary)
        Image(systemName: "arrow.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(change.proposed.isEmpty ? "—" : change.proposed)
      }
      .font(.system(size: 11))
    }
  }
}

private struct MetadataChangeTable: View {
  let changes: [MetadataFieldChange]

  var body: some View {
    List(changes) { change in
      VStack(alignment: .leading, spacing: 2) {
        Text(change.field)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          Text(change.current.isEmpty ? "—" : change.current)
            .strikethrough(change.current != change.proposed && !change.current.isEmpty)
            .foregroundStyle(.secondary)
          Image(systemName: "arrow.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(change.proposed.isEmpty ? "—" : change.proposed)
            .foregroundStyle(.primary)
        }
        .font(.system(size: 12))
      }
      .padding(.vertical, 2)
    }
  }
}

// MARK: - Album lookup

struct AlbumLookupRequest: Identifiable {
  let tracks: [LibraryTrack]

  var id: String {
    tracks.map { $0.id.rawValue }.joined(separator: "|")
  }

  @MainActor
  static func canLookUp(_ tracks: [LibraryTrack]) -> Bool {
    guard !tracks.isEmpty, tracks.allSatisfy(\.supportsMetadataEditing),
      tracks.allSatisfy({ !$0.album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { return false }
    return LibraryStore.resolveAlbums(in: tracks).count == 1
  }
}

extension View {
  func musicBrainzAlbumLookup(_ request: Binding<AlbumLookupRequest?>, app: AppState) -> some View {
    sheet(item: request) { request in
      let libraryIdentity = app.library.identityRevision
      MusicBrainzAlbumLookupSheet(
        context: MusicBrainzLookupContext(policy: app.onlineServices, service: app.musicBrainz),
        tracks: request.tracks
      ) { edits in
        try app.library.validateCurrentIdentity(libraryIdentity)
        try await app.applyMusicBrainzEdits(edits)
        try app.library.validateCurrentIdentity(libraryIdentity)
      }
    }
  }
}

struct MusicBrainzAlbumLookupSheet: View {
  @Environment(\.dismiss) private var dismiss

  let context: MusicBrainzLookupContext
  let tracks: [LibraryTrack]
  let onApply: ([TrackMetadataEdit]) async throws -> Void

  private enum Phase {
    case consent
    case alreadyTagged
    case searching
    case releases([MusicBrainzReleaseCandidate])
    case fetching
    case review([ReviewRow])
    case applying
    case failed(String)
  }

  private struct ReviewRow: Identifiable {
    let proposal: MusicBrainzTrackProposal
    var included: Bool

    var id: String { proposal.id }
  }

  @State private var phase: Phase = .searching
  @State private var lookupTask: Task<Void, Never>?
  @State private var applyTask: Task<Void, Never>?
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      content
    }
    .frame(width: 640, height: 560)
    .onAppear { start() }
    .onDisappear {
      lookupTask?.cancel()
      applyTask?.cancel()
    }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .consent:
      MusicBrainzConsentGate(
        policy: context.policy,
        onAllowed: { start(consentSettled: true) },
        onDeclined: { dismiss() })
    case .alreadyTagged:
      VStack(spacing: 12) {
        ContentUnavailableView(
          "Already matched",
          systemImage: "checkmark.seal",
          description: Text(
            "Every selected song already carries a MusicBrainz release. Look it up again anyway?"))
        HStack {
          Button("Cancel", role: .cancel) { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button("Look Up Anyway") { beginSearch() }
            .buttonStyle(.lit)
        }
        .padding(.bottom, 16)
      }
    case .searching:
      progress("Searching MusicBrainz for this album…")
    case .fetching:
      progress("Fetching the release's track listing…")
    case .applying:
      progress("Writing tags…")
    case .failed(let message):
      LookupFailureView(message: message) { dismiss() }
    case .releases(let candidates):
      if candidates.isEmpty {
        LookupEmptyView(
          title: String(localized: "No releases found"),
          description: String(
            localized: "MusicBrainz found no release matching this album's artist and title.")
        ) { dismiss() }
      } else {
        releasePicker(candidates)
      }
    case .review(let rows):
      reviewPane(rows)
    }
  }

  private func progress(_ label: String) -> some View {
    LookupProgressView(
      label: label,
      note: String(
        localized: "MusicBrainz allows one request per second, so large lookups take a moment.")
    ) {
      lookupTask?.cancel()
      applyTask?.cancel()
      dismiss()
    }
  }

  private func releasePicker(_ candidates: [MusicBrainzReleaseCandidate]) -> some View {
    VStack(spacing: 0) {
      lookupHeader("Pick the matching release")
      Text(
        tracks.count == 1
          ? String(
            localized:
              "1 local song — releases with the same number of tracks are listed first.")
          : String(
            localized:
              "\(tracks.count) local songs — releases with the same number of tracks are listed first.")
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.bottom, 6)
      LookupCandidateList(
        candidates: candidates,
        onPick: { fetchRelease($0) },
        onCancel: { dismiss() }
      ) { candidate in
        HStack {
          lookupRowText(candidate.title, releaseSubtitle(candidate))
          Spacer()
          if candidate.trackCount == tracks.count {
            Label("\(candidate.trackCount) tracks", systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.tint)
          } else if candidate.trackCount > 0 {
            Text("\(candidate.trackCount) tracks")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  private func reviewPane(_ rows: [ReviewRow]) -> some View {
    let matched = rows.filter { $0.proposal.hasChanges }
    let selectedCount = matched.filter(\.included).count
    return VStack(spacing: 0) {
      lookupHeader("Review the proposed changes")
      List(rows) { row in
        reviewRow(row)
      }
      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 6)
      }
      Divider()
      HStack {
        Text(
          matched.isEmpty
            ? String(localized: "Nothing to change")
            : matched.count == 1
              ? String(localized: "\(selectedCount) of 1 song selected")
              : String(localized: "\(selectedCount) of \(matched.count) songs selected")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Apply") { apply(rows) }
          .buttonStyle(.lit)
          .keyboardShortcut(.defaultAction)
          .disabled(selectedCount == 0)
      }
      .padding(12)
    }
  }

  @ViewBuilder
  private func reviewRow(_ row: ReviewRow) -> some View {
    let changes = metadataFieldChanges(
      from: row.proposal.current.normalized, to: row.proposal.proposed)
    HStack(alignment: .top, spacing: 10) {
      Toggle("Include \(row.proposal.track.displayTitle)", isOn: inclusionBinding(for: row.id))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .disabled(!row.proposal.hasChanges)
      VStack(alignment: .leading, spacing: 3) {
        Text(row.proposal.track.displayTitle)
          .font(.system(size: 13, weight: .medium))
        if !row.proposal.hasChanges {
          Text(
            changes.isEmpty
              ? String(localized: "No match on this release")
              : String(localized: "Already matching")
          )
          .font(.caption)
          .foregroundStyle(.tertiary)
        } else {
          MetadataChangeLines(changes: changes)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
  }

  private func releaseSubtitle(_ candidate: MusicBrainzReleaseCandidate) -> String {
    lookupSubtitle(
      [
        candidate.artistName.isEmpty ? nil : candidate.artistName,
        candidate.year > 0 ? String(candidate.year) : nil,
        candidate.country.isEmpty ? nil : candidate.country,
      ],
      score: candidate.score)
  }

  private func inclusionBinding(for id: String) -> Binding<Bool> {
    Binding(
      get: {
        guard case .review(let rows) = phase else { return false }
        return rows.first { $0.id == id }?.included ?? false
      },
      set: { included in
        guard case .review(var rows) = phase,
          let index = rows.firstIndex(where: { $0.id == id })
        else { return }
        rows[index].included = included
        phase = .review(rows)
      })
  }

  private func start(consentSettled: Bool = false) {
    guard consentSettled || context.policy.isEnabled else {
      phase = .consent
      return
    }
    if tracks.allSatisfy({ !$0.musicBrainzReleaseID.isEmpty }) {
      phase = .alreadyTagged
      return
    }
    beginSearch()
  }

  private func beginSearch() {
    phase = .searching
    let service = context.service
    let album = mostCommonValue(of: tracks.map(\.album)) ?? ""
    let artist =
      mostCommonValue(of: tracks.map { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist }) ?? ""
    let localCount = tracks.count
    lookupTask = lookupStep {
      try await service.searchReleases(artist: artist, releaseTitle: album)
        .sortedForLocalTrackCount(localCount)
    } onSuccess: { candidates in
      phase = .releases(candidates)
    } onFailure: { message in
      phase = .failed(message)
    }
  }

  private func mostCommonValue(of values: [String]) -> String? {
    let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var counts: [String: Int] = [:]
    for value in trimmed { counts[value, default: 0] += 1 }
    return counts.max { $0.value < $1.value }?.key
  }

  private func fetchRelease(_ candidate: MusicBrainzReleaseCandidate) {
    phase = .fetching
    let service = context.service
    let tracks = tracks
    lookupTask = lookupStep {
      try await service.release(withID: candidate.id)
    } onSuccess: { release in
      let proposals = MusicBrainzReleaseMatcher.proposals(for: tracks, release: release)
      phase = .review(proposals.map { ReviewRow(proposal: $0, included: $0.hasChanges) })
    } onFailure: { message in
      phase = .failed(message)
    }
  }

  private func apply(_ rows: [ReviewRow]) {
    let edits = rows.filter { $0.included && $0.proposal.hasChanges }.map {
      TrackMetadataEdit(track: $0.proposal.track, metadata: $0.proposal.proposed)
    }
    guard !edits.isEmpty else { return }
    phase = .applying
    errorMessage = nil
    applyTask = Task {
      do {
        try await onApply(edits)
        guard !Task.isCancelled else { return }
        dismiss()
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
        phase = .review(rows)
      }
    }
  }
}
