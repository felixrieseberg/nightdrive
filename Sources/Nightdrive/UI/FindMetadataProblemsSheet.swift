import SwiftUI

/// Read-only scan followed by an opt-in review. Findings without a strongly
/// supported correction open Song Info for a manual edit instead.
struct FindMetadataProblemsSheet: View {
  @Environment(\.dismiss) private var dismiss

  let tracks: () -> [LibraryTrack]
  let libraryFolder: URL?
  let musicBrainzLookup: MusicBrainzLookupContext?
  let onApply: ([TrackMetadataEdit]) async throws -> Void
  let onEdit: (LibraryTrack, TrackMetadata, ArtworkChange) async throws -> Void

  @State private var findings: [MetadataProblem]?
  @State private var selected: Set<TrackID> = []
  @State private var editorTrack: LibraryTrack?
  @State private var shouldRescanAfterEditor = false
  @State private var isApplying = false
  @State private var isConfirming = false
  @State private var selectionBeforeBulkConfirmation: Set<TrackID>?
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
    .frame(width: 820, height: 640)
    .task { await scan() }
    .alert(confirmationTitle, isPresented: $isConfirming) {
      Button("Cancel", role: .cancel) { cancelConfirmation() }
      Button("Apply Changes") { applyConfirmed() }
    } message: {
      Text(
        "Only the checked fields will be written. Nightdrive will preserve all other metadata and will not rename or move any files."
      )
    }
    .sheet(item: $editorTrack, onDismiss: editorDidDismiss) { track in
      TrackInfoEditor(
        metadata: TrackMetadata(track),
        fileInfo: TrackFileInfo(track),
        fileURL: track.url,
        musicBrainzLookup: musicBrainzLookup
      ) { metadata, artworkChange in
        try await onEdit(track, metadata, artworkChange)
        shouldRescanAfterEditor = true
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Find Metadata Problems")
        .font(.headline)
      Text(headerDetail)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  private var headerDetail: String {
    guard let findings else {
      return String(localized: "Scanning \(tracks().count) songs without changing files…")
    }
    if findings.isEmpty { return String(localized: "No suspicious metadata found.") }
    return findings.count == 1
      ? String(
        localized:
          "1 song needs review. Nothing is changed until you select and confirm a correction.")
      : String(
        localized:
          "\(findings.count) songs need review. Nothing is changed until you select and confirm corrections.")
  }

  @ViewBuilder
  private var content: some View {
    if let findings {
      if findings.isEmpty {
        AllClearView(message: "Filenames, tags, and local library evidence look consistent.")
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(findings) { finding in
              findingView(finding)
            }
          }
          .padding(16)
        }
      }
    } else {
      VStack(spacing: 12) {
        ProgressView()
        Text("Comparing filenames, tags, neighboring tracks, and local audio…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func findingView(_ finding: MetadataProblem) -> some View {
    let canApply = finding.proposedCorrection != nil && finding.track.supportsMetadataEditing
    return VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if canApply {
          Toggle("Apply proposed correction", isOn: $selected.contains(finding.id))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Select this correction for the final confirmation step")
        } else {
          Image(systemName: "exclamationmark.magnifyingglass")
            .foregroundStyle(.secondary)
            .frame(width: 14)
        }
        Text(displayPath(for: finding.track))
          .font(.callout.weight(.semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        confidenceBadge(finding.confidence)
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(finding.reason.title)
          .font(.callout.weight(.semibold))
        metadataLine("Title", finding.track.title)
        metadataLine("Artist", finding.track.artist)
        metadataLine("Album", finding.track.album)
        Text(
          "Disc: \(displayNumber(finding.track.discNumber))  ·  Track: \(displayNumber(finding.track.trackNumber))"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      .padding(.leading, 22)

      VStack(alignment: .leading, spacing: 3) {
        Text("Evidence")
          .font(.callout.weight(.semibold))
        ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
          Text("• \(item)")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.leading, 22)

      VStack(alignment: .leading, spacing: 3) {
        Text("Proposed correction")
          .font(.callout.weight(.semibold))
        if let correction = finding.proposedCorrection {
          correctionView(correction, current: finding.track.metadata)
        } else {
          Text("No automatic correction — the evidence is not strong enough to supply values safely.")
            .font(.callout)
            .foregroundStyle(.secondary)
          if finding.track.supportsMetadataEditing {
            Button("Review in Song Info…") {
              editorTrack = finding.track
            }
            .padding(.top, 3)
          }
        }
        if !finding.track.supportsMetadataEditing {
          Text("This file format does not support metadata editing in Nightdrive.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.leading, 22)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.04)))
  }

  private func metadataLine(_ label: String, _ value: String) -> some View {
    Text("\(label): \(display(value))")
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(1)
  }

  @ViewBuilder
  private func correctionView(
    _ correction: MetadataProblem.Correction, current: TrackMetadata
  ) -> some View {
    if let title = correction.title, title != current.title {
      correctionLine("Title", from: current.title, to: title)
    }
    if let artist = correction.artist, artist != current.artist {
      correctionLine("Artist", from: current.artist, to: artist)
    }
    if let album = correction.album, album != current.album {
      correctionLine("Album", from: current.album, to: album)
    }
    if let disc = correction.discNumber, disc != current.discNumber {
      correctionLine("Disc", from: displayNumber(current.discNumber), to: String(disc))
    }
    if let track = correction.trackNumber, track != current.trackNumber {
      correctionLine("Track", from: displayNumber(current.trackNumber), to: String(track))
    }
  }

  private func correctionLine(_ label: String, from: String, to: String) -> some View {
    Text("\(label): \(display(from)) → \(to)")
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func confidenceBadge(_ confidence: MetadataProblem.Confidence) -> some View {
    let color = confidence == .high ? VFD.accent : VFD.amber
    return Text(
      confidence == .high
        ? String(localized: "High confidence") : String(localized: "Medium confidence")
    )
    .font(.caption.weight(.medium))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(color.opacity(0.14)))
    .overlay(Capsule().strokeBorder(color.opacity(0.3)))
    .foregroundStyle(color)
  }

  private var footer: some View {
    HStack {
      Text(footerSummary)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      Button("Cancel", role: .cancel) { dismiss() }
        .keyboardShortcut(.cancelAction)
      if correctableIDs.count > 1 {
        Button("Apply All Corrections…") { applyAllCorrections() }
          .disabled(isApplying)
      }
      Button(applyButtonTitle) {
        selectionBeforeBulkConfirmation = nil
        isConfirming = true
      }
      .buttonStyle(.lit)
      .keyboardShortcut(.defaultAction)
      .disabled(selected.isEmpty || isApplying)
      if isApplying { ProgressView().controlSize(.small) }
    }
    .padding(16)
  }

  private var footerSummary: String {
    guard findings?.isEmpty == false else { return "" }
    return switch selected.count {
    case 0: String(localized: "Select only the corrections you want to apply.")
    case 1: String(localized: "1 correction selected.")
    default: String(localized: "\(selected.count) corrections selected.")
    }
  }

  private var applyButtonTitle: String {
    switch selected.count {
    case 0: String(localized: "Apply Corrections…")
    case 1: String(localized: "Apply 1 Correction…")
    default: String(localized: "Apply \(selected.count) Corrections…")
    }
  }

  private var confirmationTitle: String {
    selected.count == 1
      ? String(localized: "Apply 1 metadata correction?")
      : String(localized: "Apply \(selected.count) metadata corrections?")
  }

  private var correctableIDs: Set<TrackID> {
    Set(
      (findings ?? []).compactMap { finding in
        finding.proposedCorrection != nil && finding.track.supportsMetadataEditing
          ? finding.id : nil
      })
  }

  private func applyAllCorrections() {
    let all = correctableIDs
    guard !all.isEmpty else { return }
    selectionBeforeBulkConfirmation = selected
    selected = all
    isConfirming = true
  }

  private func cancelConfirmation() {
    if let previousSelection = selectionBeforeBulkConfirmation {
      selected = previousSelection
    }
    selectionBeforeBulkConfirmation = nil
  }

  private func scan(preservingSelection: Bool = false) async {
    errorMessage = nil
    let previousSelection = selected
    let snapshot = tracks()
    let found = await Task.detached(priority: .userInitiated) {
      MetadataProblemFinder.findProblems(in: snapshot)
    }.value
    findings = found
    selected =
      preservingSelection
      ? previousSelection.intersection(found.map(\.id))
      : []
  }

  private func editorDidDismiss() {
    guard shouldRescanAfterEditor else { return }
    shouldRescanAfterEditor = false
    Task { await scan(preservingSelection: true) }
  }

  private func applyConfirmed() {
    guard !isApplying, let findings else { return }
    selectionBeforeBulkConfirmation = nil
    let edits = findings.compactMap { finding -> TrackMetadataEdit? in
      guard selected.contains(finding.id), let correction = finding.proposedCorrection else {
        return nil
      }
      return TrackMetadataEdit(
        track: finding.track,
        metadata: correction.applying(to: finding.track.metadata))
    }
    guard !edits.isEmpty else { return }
    runSheetSave(isSaving: $isApplying, errorMessage: $errorMessage, dismiss: dismiss) {
      try await onApply(edits)
    }
  }

  private func displayPath(for track: LibraryTrack) -> String {
    guard let libraryFolder else { return track.url.path }
    return SyncLedgerStore.relativePath(for: track.url, in: libraryFolder) ?? track.url.path
  }

  private func display(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : value
  }

  private func displayNumber(_ value: Int) -> String {
    value > 0 ? String(value) : "—"
  }
}
