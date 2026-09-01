import Foundation

enum DuplicateSearchDepth: String, CaseIterable, Identifiable, Sendable {
  case shallow
  case deep

  var id: Self { self }
}

struct DuplicateScanProgress: Sendable, Equatable {
  enum Phase: Sendable, Equatable {
    case preparing(DuplicateSearchDepth)
    case comparingFileContents(completed: Int, total: Int)
    case comparingSongInformation(completed: Int, total: Int)
    case preparingAudioComparison
    case comparingAudio(completed: Int, total: Int)
    case finishing
    case complete
  }

  let fraction: Double
  let phase: Phase
}

struct DuplicateGroup: Identifiable, Sendable, Equatable {
  enum Tier: Int, Sendable, Equatable, Comparable {
    /// Byte-for-byte identical files.
    case exactContent
    /// Same normalized title, artist, album, and disc/track position with
    /// durations within tolerance.
    case matchingMetadata
    /// Same normalized title, artist, and album with durations within
    /// tolerance, but different disc/track positions. Position tags are not
    /// reliable enough to hide the match or prevent suggesting a removal.
    case differentTrackPosition
    /// Same title family, artist, and album, but substantially different
    /// durations. This may be a truncated file, but can also be a legitimate
    /// edit or mix, so it must always be reviewed manually.
    case possiblePartialCopy
    /// Same title family, artist, and album with substantially different
    /// durations, but no contiguous audio overlap could be confirmed.
    case durationMismatch
    /// Same normalized title and artist with similar duration but a
    /// different album — likely a greatest-hits or compilation copy. Never
    /// auto-selected for removal.
    case alternateAlbum

    static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
  }

  /// Tracks with the suggested keeper first, remaining copies by path.
  let tracks: [LibraryTrack]
  let tier: Tier
  let suggestedKeeperID: TrackID

  var id: String {
    "\(tier)|\(tracks.map(\.id.rawValue).min() ?? "")"
  }

  var suggestedRemovals: [LibraryTrack] {
    tracks.filter { $0.id != suggestedKeeperID }
  }

  var preselectedRemovals: [LibraryTrack] {
    switch tier {
    case .exactContent, .matchingMetadata, .differentTrackPosition:
      suggestedRemovals
    case .possiblePartialCopy, .durationMismatch, .alternateAlbum:
      []
    }
  }
}

enum DuplicateFinder {
  static let durationToleranceMS = 2000

  /// Finds duplicate groups in six tiers. Exact-content matches hash only
  /// files whose sizes collide, so a clean library costs no hashing at all.
  /// Tracks consumed by a stronger tier never reappear in a weaker one, so a
  /// re-rip alongside two byte-identical copies surfaces only after the
  /// exact pair is resolved and the scan runs again.
  static func findGroups(
    in tracks: [LibraryTrack],
    contentHash: (URL) throws -> String = SyncSignature.fileSHA256
  ) -> [DuplicateGroup] {
    let partialAudioMatcher = PartialAudioMatcher()
    return findGroups(
      in: tracks, depth: .deep,
      partialContentMatch: { partialAudioMatcher.matches($0, $1) },
      progress: nil,
      contentHash: contentHash)
  }

  static func findGroups(
    in tracks: [LibraryTrack], depth: DuplicateSearchDepth,
    progress: @escaping (DuplicateScanProgress) -> Void,
    isCancelled: @escaping () -> Bool = { false }
  ) -> [DuplicateGroup] {
    let partialAudioMatcher = PartialAudioMatcher()
    return findGroups(
      in: tracks, depth: depth,
      partialContentMatch: {
        partialAudioMatcher.matches($0, $1, isCancelled: isCancelled)
      },
      progress: progress, isCancelled: isCancelled,
      contentHash: {
        try SyncSignature.fileSHA256(url: $0, isCancelled: isCancelled)
      })
  }

  static func findGroups(
    in tracks: [LibraryTrack],
    partialContentMatch: (URL, URL) -> Bool,
    contentHash: (URL) throws -> String = SyncSignature.fileSHA256
  ) -> [DuplicateGroup] {
    findGroups(
      in: tracks, depth: .deep, partialContentMatch: partialContentMatch,
      progress: nil, contentHash: contentHash)
  }

  static func findGroups(
    in tracks: [LibraryTrack], depth: DuplicateSearchDepth,
    partialContentMatch: (URL, URL) -> Bool,
    progress: ((DuplicateScanProgress) -> Void)?,
    isCancelled: () -> Bool = { false },
    contentHash: (URL) throws -> String
  ) -> [DuplicateGroup] {
    var groups: [DuplicateGroup] = []
    var consumed: Set<TrackID> = []

    func report(_ fraction: Double, _ phase: DuplicateScanProgress.Phase) {
      progress?(
        DuplicateScanProgress(
          fraction: min(1, max(0, fraction)), phase: phase))
    }

    func phaseFraction(
      from start: Double, to end: Double, completed: Int, total: Int
    ) -> Double {
      guard total > 0 else { return end }
      return start + (end - start) * Double(completed) / Double(total)
    }

    func shouldReport(completed: Int, total: Int) -> Bool {
      guard total > 0 else { return true }
      let interval = max(1, (total + 99) / 100)
      return completed == 0 || completed == total || completed.isMultiple(of: interval)
    }

    report(0, .preparing(depth))
    guard !isCancelled() else { return [] }

    // Tier 1: identical content.
    var bySize: [Int: [LibraryTrack]] = [:]
    for track in tracks {
      guard !isCancelled() else { return [] }
      bySize[track.sizeBytes, default: []].append(track)
    }
    let hashCandidateCount = bySize.values
      .filter { $0.count > 1 }
      .reduce(0) { $0 + $1.count }
    let hashEnd = depth == .shallow ? 0.65 : 0.30
    var hashedCount = 0
    report(0.05, .comparingFileContents(completed: 0, total: hashCandidateCount))
    for (_, candidates) in bySize where candidates.count > 1 {
      guard !isCancelled() else { return [] }
      var byHash: [String: [LibraryTrack]] = [:]
      for track in candidates {
        guard !isCancelled() else { return [] }
        let hash = try? contentHash(track.url)
        hashedCount += 1
        if shouldReport(completed: hashedCount, total: hashCandidateCount) {
          report(
            phaseFraction(
              from: 0.05, to: hashEnd, completed: hashedCount,
              total: hashCandidateCount),
            .comparingFileContents(
              completed: hashedCount, total: hashCandidateCount))
        }
        if let hash { byHash[hash, default: []].append(track) }
      }
      for (_, matches) in byHash where matches.count > 1 {
        groups.append(group(tier: .exactContent, tracks: matches))
        consumed.formUnion(matches.map(\.id))
      }
    }
    // Tier 2: matching metadata with similar duration. Only tracks with a
    // tagged title and artist qualify — untagged files fall back to
    // filename-stem keys, and "01.mp3" in two folders is no evidence of a
    // duplicate. Untagged copies still surface through tier 1 when their
    // bytes match.
    let remaining = tracks.filter {
      !consumed.contains($0.id) && hasMeaningfulMetadata($0)
    }
    report(
      hashEnd,
      .comparingSongInformation(completed: 0, total: remaining.count))
    var byKey: [MetadataKey: [LibraryTrack]] = [:]
    let metadataEnd = depth == .shallow ? 0.90 : 0.40
    for (index, track) in remaining.enumerated() {
      guard !isCancelled() else { return [] }
      byKey[MetadataKey(track), default: []].append(track)
      let completed = index + 1
      if shouldReport(completed: completed, total: remaining.count) {
        report(
          phaseFraction(
            from: hashEnd, to: metadataEnd, completed: completed,
            total: remaining.count),
          .comparingSongInformation(
            completed: completed, total: remaining.count))
      }
    }
    for (_, candidates) in byKey where candidates.count > 1 {
      for cluster in durationClusters(candidates) where cluster.count > 1 {
        let positions = Set(cluster.map(TrackPosition.init))
        let tier: DuplicateGroup.Tier =
          positions.count == 1 ? .matchingMetadata : .differentTrackPosition
        groups.append(group(tier: tier, tracks: cluster))
        consumed.formUnion(cluster.map(\.id))
      }
    }

    // Tier 3: a possible truncated or otherwise incomplete copy. A trailing
    // parenthetical or bracketed version label is ignored only when a bare
    // title is also present in the group. These groups are review-only: a
    // short radio edit or a long remix can be perfectly legitimate.
    let partialCandidates = tracks.filter {
      !consumed.contains($0.id) && hasMeaningfulMetadata($0)
        && !TrackMatcher.normalize($0.album).isEmpty
    }
    var byPartialKey: [PartialKey: [LibraryTrack]] = [:]
    for track in partialCandidates {
      guard !isCancelled() else { return [] }
      byPartialKey[PartialKey(track), default: []].append(track)
    }
    var audioComparisonCount = 0
    if depth == .deep {
      for entry in byPartialKey {
        guard !isCancelled() else { return [] }
        audioComparisonCount += partialPairCount(
          entry.value, titleStem: entry.key.titleStem, isCancelled: isCancelled)
      }
    }
    var audioComparisonsCompleted = 0
    if depth == .deep {
      report(metadataEnd, .preparingAudioComparison)
    }
    for (key, candidates) in byPartialKey where candidates.count > 1 {
      guard !isCancelled() else { return [] }
      for match in partialContentGroups(
        candidates, titleStem: key.titleStem, compareAudio: depth == .deep,
        contentMatch: partialContentMatch,
        didCompareAudio: {
          audioComparisonsCompleted += 1
          if shouldReport(
            completed: audioComparisonsCompleted, total: audioComparisonCount)
          {
            report(
              phaseFraction(
                from: metadataEnd, to: 0.95,
                completed: audioComparisonsCompleted, total: audioComparisonCount),
              .comparingAudio(
                completed: audioComparisonsCompleted, total: audioComparisonCount))
          }
        }, isCancelled: isCancelled)
      {
        guard !isCancelled() else { return [] }
        let tier: DuplicateGroup.Tier =
          match.hasAudioOverlap ? .possiblePartialCopy : .durationMismatch
        groups.append(group(tier: tier, tracks: match.tracks))
        consumed.formUnion(match.tracks.map(\.id))
      }
    }
    report(0.95, .finishing)

    // Tier 5: same song on a different album, flagged but never
    // auto-selected.
    let flaggable = tracks.filter { !consumed.contains($0.id) }
    var byTitleArtist: [AlternateKey: [LibraryTrack]] = [:]
    for track in flaggable {
      guard !isCancelled() else { return [] }
      guard let key = AlternateKey(track) else { continue }
      byTitleArtist[key, default: []].append(track)
    }
    for (_, candidates) in byTitleArtist where candidates.count > 1 {
      for cluster in durationClusters(candidates) where cluster.count > 1 {
        let albums = Set(cluster.map { TrackMatcher.normalize($0.album) })
        guard albums.count > 1 else { continue }
        groups.append(group(tier: .alternateAlbum, tracks: cluster))
      }
    }

    let sorted = groups.sorted { lhs, rhs in
      if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
      let lhsName = lhs.tracks.first.map { "\($0.artist)|\($0.displayTitle)".lowercased() } ?? ""
      let rhsName = rhs.tracks.first.map { "\($0.artist)|\($0.displayTitle)".lowercased() } ?? ""
      if lhsName != rhsName { return lhsName < rhsName }
      return lhs.id < rhs.id
    }
    guard !isCancelled() else { return [] }
    report(1, .complete)
    return sorted
  }

  /// Prefers higher bitrate, then larger file, then the shallower and
  /// shorter path, so the best-sounding copy in the tidiest location wins.
  static func suggestedKeeper(among tracks: [LibraryTrack]) -> LibraryTrack? {
    tracks.min(by: keeperPrecedes)
  }

  private static func hasMeaningfulMetadata(_ track: LibraryTrack) -> Bool {
    !TrackMatcher.normalize(track.title).isEmpty
      && !TrackMatcher.normalize(track.artist).isEmpty
  }

  /// Organizers and device imports commonly materialize a missing album as
  /// this placeholder. It carries no more identity than an empty tag, so it
  /// must not turn an otherwise strong match into an alternate-album review.
  private static func canonicalAlbum(_ album: String) -> String {
    let normalized = TrackMatcher.normalize(album)
    return normalized == "unknown album" ? "" : normalized
  }

  private struct MetadataKey: Hashable {
    let title: String
    let artist: String
    let album: String

    init(_ track: LibraryTrack) {
      title = TrackMatcher.normalize(track.title)
      artist = TrackMatcher.normalize(track.artist)
      album = DuplicateFinder.canonicalAlbum(track.album)
    }
  }

  private struct TrackPosition: Hashable {
    let discNumber: Int
    let trackNumber: Int

    init(_ track: LibraryTrack) {
      discNumber = track.discNumber
      trackNumber = track.trackNumber
    }
  }

  private struct AlternateKey: Hashable {
    let title: String
    let artist: String

    init?(_ track: LibraryTrack) {
      let title = TrackMatcher.normalize(track.title)
      let artist = TrackMatcher.normalize(track.artist)
      guard !title.isEmpty, !artist.isEmpty else { return nil }
      self.title = title
      self.artist = artist
    }
  }

  private struct PartialKey: Hashable {
    let titleStem: String
    let artist: String
    let album: String

    init(_ track: LibraryTrack) {
      titleStem = partialTitleStem(track.title)
      artist = TrackMatcher.normalize(track.artist)
      album = TrackMatcher.normalize(track.album)
    }
  }

  private static func partialTitleStem(_ title: String) -> String {
    TrackMatcher.normalize(title)
      .replacingOccurrences(
        of: #"\s*[\(\[][\s\S]*[\)\]]\s*$"#,
        with: "",
        options: .regularExpression
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func group(
    tier: DuplicateGroup.Tier, tracks: [LibraryTrack]
  ) -> DuplicateGroup {
    let keeper =
      if tier == .possiblePartialCopy || tier == .durationMismatch {
        suggestedCompleteCopy(among: tracks) ?? tracks[0]
      } else {
        suggestedKeeper(among: tracks) ?? tracks[0]
      }
    let ordered =
      [keeper]
      + tracks.filter { $0.id != keeper.id }
      .sorted { $0.url.path < $1.url.path }
    return DuplicateGroup(tracks: ordered, tier: tier, suggestedKeeperID: keeper.id)
  }

  private static func suggestedCompleteCopy(among tracks: [LibraryTrack]) -> LibraryTrack? {
    tracks.min { lhs, rhs in
      if lhs.durationMS != rhs.durationMS { return lhs.durationMS > rhs.durationMS }
      return keeperPrecedes(lhs, rhs)
    }
  }

  private struct PartialContentGroup {
    let tracks: [LibraryTrack]
    let hasAudioOverlap: Bool
  }

  private struct CandidatePair: Hashable {
    let first: Int
    let second: Int

    init(_ lhs: Int, _ rhs: Int) {
      first = min(lhs, rhs)
      second = max(lhs, rhs)
    }
  }

  private static func partialContentGroups(
    _ tracks: [LibraryTrack], titleStem: String,
    compareAudio: Bool, contentMatch: (URL, URL) -> Bool,
    didCompareAudio: () -> Void, isCancelled: () -> Bool
  ) -> [PartialContentGroup] {
    var neighbors = Array(repeating: Set<Int>(), count: tracks.count)
    var audioMatches: Set<CandidatePair> = []
    for first in tracks.indices {
      for second in tracks.indices where second > first {
        guard !isCancelled() else { return [] }
        let lhs = tracks[first]
        let rhs = tracks[second]
        guard isPartialPair(lhs, rhs, titleStem: titleStem) else { continue }
        let audioMatchesPair = compareAudio && contentMatch(lhs.url, rhs.url)
        if compareAudio { didCompareAudio() }
        guard audioMatchesPair || filenamesCorroborate(lhs, rhs, titleStem: titleStem)
        else { continue }
        neighbors[first].insert(second)
        neighbors[second].insert(first)
        if audioMatchesPair {
          audioMatches.insert(CandidatePair(first, second))
        }
      }
    }

    var visited: Set<Int> = []
    var groups: [PartialContentGroup] = []
    for start in tracks.indices where !visited.contains(start) && !neighbors[start].isEmpty {
      var pending = [start]
      var component: [Int] = []
      visited.insert(start)
      while let current = pending.popLast() {
        component.append(current)
        for neighbor in neighbors[current] where visited.insert(neighbor).inserted {
          pending.append(neighbor)
        }
      }
      let hasAudioOverlap = component.contains { first in
        component.contains { second in
          second > first && audioMatches.contains(CandidatePair(first, second))
        }
      }
      groups.append(
        PartialContentGroup(
          tracks: component.map { tracks[$0] }, hasAudioOverlap: hasAudioOverlap))
    }
    return groups
  }

  private static func partialPairCount(
    _ tracks: [LibraryTrack], titleStem: String, isCancelled: () -> Bool
  ) -> Int {
    var count = 0
    for first in tracks.indices {
      for second in tracks.indices where second > first {
        guard !isCancelled() else { return count }
        if isPartialPair(tracks[first], tracks[second], titleStem: titleStem) {
          count += 1
        }
      }
    }
    return count
  }

  private static func isPartialPair(
    _ lhs: LibraryTrack, _ rhs: LibraryTrack, titleStem: String
  ) -> Bool {
    let lhsIsBare = TrackMatcher.normalize(lhs.title) == titleStem
    let rhsIsBare = TrackMatcher.normalize(rhs.title) == titleStem
    return (lhsIsBare || rhsIsBare)
      && abs(lhs.durationMS - rhs.durationMS) > durationToleranceMS
  }

  /// Badly copied tags often make unrelated compilation tracks look like the
  /// same song. A metadata-only match therefore needs independent support
  /// from both filenames. Deep search can bypass this check only after the
  /// decoded audio itself matches.
  private static func filenamesCorroborate(
    _ lhs: LibraryTrack, _ rhs: LibraryTrack, titleStem: String
  ) -> Bool {
    filename(lhs.url, containsTitle: titleStem)
      && filename(rhs.url, containsTitle: titleStem)
  }

  private static func filename(_ url: URL, containsTitle title: String) -> Bool {
    let titleTokens = significantTokens(in: title)
    guard !titleTokens.isEmpty else { return false }
    let filenameTokens = Set(tokens(in: url.deletingPathExtension().lastPathComponent))
    return titleTokens.allSatisfy(filenameTokens.contains)
  }

  private static func significantTokens(in value: String) -> [String] {
    let all = tokens(in: value)
    let significant = all.filter { $0.count >= 3 }
    return significant.isEmpty ? all : significant
  }

  private static func tokens(in value: String) -> [String] {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
  }

  private static func keeperPrecedes(_ lhs: LibraryTrack, _ rhs: LibraryTrack) -> Bool {
    if lhs.bitrate != rhs.bitrate { return lhs.bitrate > rhs.bitrate }
    if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
    let lhsDepth = lhs.url.pathComponents.count
    let rhsDepth = rhs.url.pathComponents.count
    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
    if lhs.url.path.count != rhs.url.path.count {
      return lhs.url.path.count < rhs.url.path.count
    }
    return lhs.url.path < rhs.url.path
  }

  private static func durationClusters(
    _ tracks: [LibraryTrack]
  ) -> [[LibraryTrack]] {
    let sorted = tracks.sorted { $0.durationMS < $1.durationMS }
    var clusters: [[LibraryTrack]] = []
    for track in sorted {
      if let anchor = clusters.last?.first,
        track.durationMS - anchor.durationMS <= durationToleranceMS
      {
        clusters[clusters.count - 1].append(track)
      } else {
        clusters.append([track])
      }
    }
    return clusters
  }
}
