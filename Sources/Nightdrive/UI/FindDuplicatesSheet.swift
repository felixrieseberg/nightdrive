import SwiftUI

/// Review sheet for duplicate files in the library. Each group keeps one
/// checked-off survivor; removed copies go to the Trash and their playlist
/// memberships and listening statistics fold into the keeper.
struct FindDuplicatesSheet: View {
  private struct ScanRequest: Hashable {
    let depth: DuplicateSearchDepth
    let generation: Int
  }

  @Environment(\.dismiss) private var dismiss

  /// Reads the live library so rescans after a partial failure see the
  /// files that were actually trashed, not the pre-removal snapshot.
  let tracks: () -> [LibraryTrack]
  let libraryFolder: URL?
  let onResolve: ([AppState.DuplicateResolution]) async -> AppState.LibraryMaintenanceOutcome?

  @State private var groups: [DuplicateGroup]?
  @State private var selectedForRemoval: Set<TrackID> = []
  @State private var isRemoving = false
  @State private var errorMessage: String?
  @State private var searchDepth = DuplicateSearchDepth.shallow
  @State private var scanGeneration = 0
  @State private var isScanning = false
  @State private var scanProgress = DuplicateScanProgress(
    fraction: 0, phase: .preparing(.shallow))

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      ErrorBanner(message: errorMessage)
      Divider()
      footer
    }
    .frame(width: 720, height: 560)
    .task(id: ScanRequest(depth: searchDepth, generation: scanGeneration)) {
      await scan(depth: searchDepth)
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Find Duplicates")
            .font(.headline)
          Text(headerDetail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Picker("Search depth", selection: $searchDepth) {
          Text("Shallow").tag(DuplicateSearchDepth.shallow)
          Text("Deep").tag(DuplicateSearchDepth.deep)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 180)
        .disabled(isRemoving)
      }
      Text(searchDepthDescription)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  private var headerDetail: String {
    if isScanning { return String(localized: "Scanning \(tracks().count) songs…") }
    guard let groups else { return String(localized: "Ready to search \(tracks().count) songs.") }
    if groups.isEmpty { return String(localized: "No duplicates found.") }
    let count = groups.count
    return count == 1
      ? String(localized: "1 group of duplicates found.")
      : String(localized: "\(count) groups of duplicates found.")
  }

  private var searchDepthDescription: String {
    switch searchDepth {
    case .shallow:
      String(localized: "Fast: compares file contents, tags, titles, and lengths.")
    case .deep:
      String(localized: "Thorough: also decodes candidate files to compare their audio.")
    }
  }

  @ViewBuilder
  private var content: some View {
    if let groups {
      if groups.isEmpty {
        AllClearView(message: "Every song in the library is unique.")
      } else {
        groupList(groups)
      }
    } else {
      VStack(spacing: 12) {
        ProgressView(value: scanProgress.fraction, total: 1)
          .frame(width: 280)
        Text(progressText(scanProgress.phase))
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func groupList(_ groups: [DuplicateGroup]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        ForEach(groups) { group in
          groupView(group)
        }
      }
      .padding(16)
    }
  }

  private func groupView(_ group: DuplicateGroup) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        if let first = group.tracks.first {
          Text("\(first.displayTitle) — \(first.artist)")
            .font(.callout.weight(.semibold))
            .lineLimit(1)
        }
        tierBadge(group.tier)
        Spacer()
      }
      ForEach(group.tracks, id: \.id) { track in
        trackRow(track, in: group)
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.04)))
  }

  private func tierBadge(_ tier: DuplicateGroup.Tier) -> some View {
    Text(tierLabel(tier))
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.primary.opacity(0.1)))
      .foregroundStyle(.secondary)
      .help(tierHelp(tier))
  }

  private func tierLabel(_ tier: DuplicateGroup.Tier) -> String {
    switch tier {
    case .exactContent: String(localized: "Identical files")
    case .matchingMetadata: String(localized: "Matching tags")
    case .differentTrackPosition: String(localized: "Different position")
    case .possiblePartialCopy: String(localized: "Partial audio match")
    case .durationMismatch: String(localized: "Different lengths")
    case .alternateAlbum: String(localized: "Different album")
    }
  }

  private func tierHelp(_ tier: DuplicateGroup.Tier) -> String {
    switch tier {
    case .exactContent:
      String(localized: "These files are byte-for-byte identical.")
    case .matchingMetadata:
      String(localized: "These files carry the same title, artist, album, and track position.")
    case .differentTrackPosition:
      String(
        localized:
          "These files carry the same title, artist, and album and have similar lengths, but their disc or track positions differ. The non-suggested copies are selected for removal."
      )
    case .possiblePartialCopy:
      String(
        localized:
          "Audio from the shorter file matches part of the longer file, but their lengths differ. Review them before removing anything."
      )
    case .durationMismatch:
      String(
        localized:
          "These files have matching song information but different lengths; the scan could not confirm overlapping audio."
      )
    case .alternateAlbum:
      String(localized: "The same song appears on different albums; review before removing.")
    }
  }

  private func trackRow(_ track: LibraryTrack, in group: DuplicateGroup) -> some View {
    // One copy always survives: the last unchecked row in a group locks so
    // the choice of survivor stays explicit rather than silent.
    let willRemove = selectedForRemoval.contains(track.id)
    let isLastSurvivor =
      !willRemove
      && group.tracks.allSatisfy { $0.id == track.id || selectedForRemoval.contains($0.id) }
    return HStack(spacing: 8) {
      Toggle("Remove \(track.displayTitle)", isOn: $selectedForRemoval.contains(track.id))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .disabled(isLastSurvivor)
        .help(
          isLastSurvivor
            ? String(localized: "One copy always stays — uncheck another copy to remove this one")
            : String(localized: "Move this copy to the Trash"))
      VStack(alignment: .leading, spacing: 1) {
        Text(displayPath(for: track))
          .font(.callout)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detailText(for: track))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 6) {
        Text(willRemove ? String(localized: "Move to Trash") : String(localized: "Keep"))
          .font(.caption.weight(.medium))
          .foregroundStyle(willRemove ? Color.red : Color.secondary)
        if !willRemove, track.id == group.suggestedKeeperID {
          Text("Suggested")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .foregroundStyle(.secondary)
        }
      }
      .help(rowDispositionHelp(for: track, in: group, willRemove: willRemove))
    }
  }

  private func rowDispositionHelp(
    for track: LibraryTrack, in group: DuplicateGroup, willRemove: Bool
  ) -> String {
    if willRemove { return String(localized: "This copy will move to the Trash.") }
    if track.id == group.suggestedKeeperID { return keeperHelp(for: group.tier) }
    return String(localized: "This copy will stay in your library.")
  }

  private func keeperHelp(for tier: DuplicateGroup.Tier) -> String {
    if tier == .possiblePartialCopy || tier == .durationMismatch {
      return String(localized: "Suggested copy to keep — longest recording, then highest quality")
    }
    return String(localized: "Suggested copy to keep — highest quality in the tidiest location")
  }

  private func displayPath(for track: LibraryTrack) -> String {
    guard let libraryFolder else { return track.url.path }
    return SyncLedgerStore.relativePath(for: track.url, in: libraryFolder) ?? track.url.path
  }

  private func detailText(for track: LibraryTrack) -> String {
    var parts: [String] = []
    if track.bitrate > 0 {
      parts.append(String(localized: "\(track.bitrate) kbps"))
    }
    parts.append(ByteCountFormatter.string(fromByteCount: Int64(track.sizeBytes), countStyle: .file))
    let seconds = track.durationMS / 1000
    parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
    return parts.joined(separator: " · ")
  }

  private var footer: some View {
    SheetFooter(
      summary: footerSummary,
      primaryTitle: removeButtonTitle,
      primaryDisabled: selectedForRemoval.isEmpty || isRemoving,
      isBusy: isRemoving,
      primaryAction: removeSelected)
  }

  private var footerSummary: String {
    guard groups?.isEmpty == false else { return "" }
    switch selectedForRemoval.count {
    case 0: return String(localized: "Check the copies to move to the Trash.")
    case 1: return String(localized: "1 copy selected.")
    default: return String(localized: "\(selectedForRemoval.count) copies selected.")
    }
  }

  private var removeButtonTitle: String {
    switch selectedForRemoval.count {
    case 0: String(localized: "Move Songs to Trash")
    case 1: String(localized: "Move 1 Song to Trash")
    default: String(localized: "Move \(selectedForRemoval.count) Songs to Trash")
    }
  }

  private func scan(depth: DuplicateSearchDepth) async {
    let tracks = tracks()
    groups = nil
    selectedForRemoval = []
    isScanning = true
    scanProgress = DuplicateScanProgress(
      fraction: 0,
      phase: .preparing(depth))

    let (updates, continuation) = AsyncStream.makeStream(
      of: DuplicateScanProgress.self, bufferingPolicy: .bufferingNewest(1))
    let worker = Task.detached(priority: .userInitiated) {
      defer { continuation.finish() }
      let found = DuplicateFinder.findGroups(
        in: tracks, depth: depth,
        progress: { continuation.yield($0) },
        isCancelled: { Task.isCancelled })
      return found
    }
    let found = await withTaskCancellationHandler {
      for await update in updates {
        guard !Task.isCancelled else { break }
        scanProgress = update
      }
      return await worker.value
    } onCancel: {
      worker.cancel()
      continuation.finish()
    }
    guard !Task.isCancelled, searchDepth == depth else { return }
    groups = found
    var preselected: Set<TrackID> = []
    for group in found {
      preselected.formUnion(group.preselectedRemovals.map(\.id))
    }
    selectedForRemoval = preselected
    isScanning = false
  }

  private func progressText(_ phase: DuplicateScanProgress.Phase) -> String {
    switch phase {
    case .preparing(.shallow):
      return String(localized: "Preparing shallow search…")
    case .preparing(.deep):
      return String(localized: "Preparing deep search…")
    case .comparingFileContents(let completed, let total):
      if total == 0 { return String(localized: "Comparing file contents…") }
      return String(localized: "Comparing file contents \(completed) of \(total)…")
    case .comparingSongInformation(let completed, let total):
      if total == 0 { return String(localized: "Comparing song information…") }
      return String(localized: "Comparing song information \(completed) of \(total)…")
    case .preparingAudioComparison:
      return String(localized: "Preparing audio comparison…")
    case .comparingAudio(let completed, let total):
      return String(localized: "Comparing audio \(completed) of \(total)…")
    case .finishing:
      return String(localized: "Finishing duplicate groups…")
    case .complete:
      return String(localized: "Search complete")
    }
  }

  private func removeSelected() {
    guard !isRemoving, let groups else { return }
    isRemoving = true
    errorMessage = nil
    var resolutions: [AppState.DuplicateResolution] = []
    for group in groups {
      let removals = group.tracks.filter { selectedForRemoval.contains($0.id) }
      guard !removals.isEmpty else { continue }
      let survivors = group.tracks.filter { !selectedForRemoval.contains($0.id) }
      let keeper =
        survivors.first { $0.id == group.suggestedKeeperID }
        ?? survivors.first
        ?? removals[0]
      resolutions.append(
        AppState.DuplicateResolution(
          keeper: keeper,
          duplicates: removals.filter { $0.id != keeper.id }))
    }
    Task {
      let outcome = await onResolve(resolutions)
      guard let outcome else {
        errorMessage = LibraryStoreError.libraryChanged.localizedDescription
        isRemoving = false
        return
      }
      if let failure = outcome.failures.first {
        errorMessage =
          outcome.failures.count == 1
          ? failure.message
          : "\(outcome.failures.count) files couldn’t be removed. \(failure.message)"
        isRemoving = false
        scanGeneration &+= 1
        return
      }
      if let warning = outcome.sidecarWarning {
        errorMessage = warning
        isRemoving = false
        scanGeneration &+= 1
        return
      }
      dismiss()
    }
  }
}
