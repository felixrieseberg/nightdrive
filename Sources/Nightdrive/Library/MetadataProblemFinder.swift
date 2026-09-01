import CryptoKit
import Foundation

struct MetadataProblem: Identifiable, Sendable, Equatable {
  enum Confidence: Int, Sendable, Comparable {
    case medium
    case high

    static func < (lhs: Confidence, rhs: Confidence) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  enum Reason: Sendable {
    case copiedTags
    case filenameConflict
    case trackNumberConflict
    case matchingAudio

    var title: String {
      switch self {
      case .copiedTags:
        String(localized: "Tags duplicated from another file")
      case .filenameConflict:
        String(localized: "Filename and embedded tags conflict")
      case .trackNumberConflict:
        String(localized: "Track number conflict")
      case .matchingAudio:
        String(localized: "Matching audio has different tags")
      }
    }
  }

  struct Correction: Sendable, Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var discNumber: Int?
    var trackNumber: Int?

    var isEmpty: Bool {
      title == nil && artist == nil && album == nil && discNumber == nil && trackNumber == nil
    }

    func applying(to metadata: TrackMetadata) -> TrackMetadata {
      var result = metadata
      if let title { result.title = title }
      if let artist { result.artist = artist }
      if let album { result.album = album }
      if let discNumber { result.discNumber = discNumber }
      if let trackNumber { result.trackNumber = trackNumber }
      return result.normalized
    }
  }

  let track: LibraryTrack
  let reason: Reason
  let confidence: Confidence
  let evidence: [String]
  let proposedCorrection: Correction?

  var id: TrackID { track.id }
}

/// Looks for metadata that conflicts with independent, local evidence. A bare
/// filename/title disagreement is intentionally insufficient: downloads,
/// remasters, disc prefixes, and personal naming schemes are too varied for
/// that to be a safe signal on their own.
enum MetadataProblemFinder {
  private static let durationToleranceMS = 2_000

  typealias AudioContentHash = @Sendable (URL) throws -> String?

  static func findProblems(
    in tracks: [LibraryTrack],
    audioContentHash: AudioContentHash = encodedAudioSHA256
  ) -> [MetadataProblem] {
    guard !tracks.isEmpty else { return [] }

    let parsed = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, parseFilename($0.url)) })
    let folders = Dictionary(grouping: tracks) { $0.url.deletingLastPathComponent().path }
    var folderContexts: [String: FolderContext] = [:]
    for (folder, members) in folders {
      folderContexts[folder] = folderContext(for: members, parsed: parsed)
    }

    var byTags: [TagKey: [LibraryTrack]] = [:]
    for track in tracks {
      if let key = TagKey(track) { byTags[key, default: []].append(track) }
    }
    let mp3sByDurationBucket = Dictionary(
      grouping: tracks.filter { $0.audioFormat == .mp3 },
      by: { $0.durationMS / durationToleranceMS })

    let candidates = tracks.filter { track in
      guard let filename = parsed[track.id] else { return false }
      let context = folderContexts[track.url.deletingLastPathComponent().path] ?? .empty
      let resolved = filename.resolved(for: track, folderUsesArtistTitle: context.usesArtistTitle)
      return titleConflicts(resolved.title, track.title)
        || numberConflicts(resolved.trackNumber, track.trackNumber)
        || numberConflicts(resolved.discNumber, track.discNumber)
        || artistConflicts(resolved.artist, track.artist)
    }

    // Hash only suspicious tracks and plausible same-duration references.
    // The hash excludes MP3 tag blocks, so identical encodes with different
    // ID3 metadata can corroborate a correction without decoding audio.
    var hashCache: [TrackID: String?] = [:]
    var audioMatches: [TrackID: [LibraryTrack]] = [:]
    for candidate in candidates where candidate.audioFormat == .mp3 {
      let bucket = candidate.durationMS / durationToleranceMS
      let nearbyBuckets = [bucket - 1, bucket, bucket + 1]
      let nearbyTracks: [LibraryTrack] = nearbyBuckets.flatMap {
        mp3sByDurationBucket[$0] ?? []
      }
      let possibleReferences = nearbyTracks.filter {
        $0.id != candidate.id && $0.audioFormat == .mp3
          && abs($0.durationMS - candidate.durationMS) <= durationToleranceMS
      }
      guard !possibleReferences.isEmpty else { continue }
      let candidateHash = cachedHash(
        for: candidate, cache: &hashCache, audioContentHash: audioContentHash)
      guard let candidateHash else { continue }
      for reference in possibleReferences {
        if cachedHash(for: reference, cache: &hashCache, audioContentHash: audioContentHash)
          == candidateHash
        {
          audioMatches[candidate.id, default: []].append(reference)
        }
      }
    }

    var findings: [MetadataProblem] = []
    for track in candidates {
      guard let filename = parsed[track.id] else { continue }
      let folder = track.url.deletingLastPathComponent().path
      let context = folderContexts[folder] ?? .empty
      let resolved = filename.resolved(for: track, folderUsesArtistTitle: context.usesArtistTitle)

      let titleMismatch = titleConflicts(resolved.title, track.title)
      let artistMismatch = artistConflicts(resolved.artist, track.artist)
      let trackMismatch = numberConflicts(resolved.trackNumber, track.trackNumber)
      let discMismatch = numberConflicts(resolved.discNumber, track.discNumber)
      guard titleMismatch || artistMismatch || trackMismatch || discMismatch else { continue }

      let duplicatePeers = TagKey(track).flatMap { byTags[$0] }?.filter { $0.id != track.id } ?? []
      let copiedFromPeer = duplicatePeers.first { peer in
        // Similar-duration copies belong in Find Duplicates. A tag set on
        // substantially different audio is the copied-tag signal here.
        guard abs(peer.durationMS - track.durationMS) > durationToleranceMS else { return false }
        guard let peerFilename = parsed[peer.id] else { return false }
        let peerContext = folderContexts[peer.url.deletingLastPathComponent().path] ?? .empty
        let peerResolved = peerFilename.resolved(
          for: peer, folderUsesArtistTitle: peerContext.usesArtistTitle)
        return titlesMatch(peerResolved.title, peer.title)
          && (!trackMismatch || numbersMatch(peerResolved.trackNumber, peer.trackNumber))
      }

      let audioReference = audioMatches[track.id]?.first { reference in
        guard let referenceFilename = parsed[reference.id] else { return false }
        let referenceContext =
          folderContexts[reference.url.deletingLastPathComponent().path] ?? .empty
        let referenceResolved = referenceFilename.resolved(
          for: reference, folderUsesArtistTitle: referenceContext.usesArtistTitle)
        return titlesMatch(referenceResolved.title, reference.title)
          && titlesMatch(resolved.title, reference.title)
      }

      var evidence: [String] = []
      var score = 0
      if titleMismatch, let filenameTitle = resolved.title {
        evidence.append(
          String(
            localized:
              "Filename identifies the title as “\(filenameTitle),” but the embedded title is “\(display(track.title)).”"
          ))
        score += 1
      }
      if artistMismatch, let filenameArtist = resolved.artist {
        evidence.append(
          String(
            localized:
              "Filename explicitly identifies the artist as “\(filenameArtist),” but the embedded artist is “\(display(track.artist)).”"
          )
        )
        score += 1
      }
      if trackMismatch, let filenameTrack = resolved.trackNumber {
        evidence.append(
          String(
            localized:
              "Filename starts with track \(filenameTrack), but the embedded track number is \(display(track.trackNumber))."
          )
        )
        score += 1
      }
      if discMismatch, let filenameDisc = resolved.discNumber {
        evidence.append(
          String(
            localized:
              "Filename identifies disc \(filenameDisc), but the embedded disc number is \(display(track.discNumber))."
          ))
        score += 1
      }

      if let copiedFromPeer {
        evidence.append(
          String(
            localized:
              "Its title, artist, album, disc, and track tags duplicate “\(copiedFromPeer.url.lastPathComponent),” whose filename agrees with those tags."
          )
        )
        score += 2
      }
      if context.supportsTitleConvention, titleMismatch {
        evidence.append(
          String(
            localized:
              "Other files in this folder consistently use filenames that agree with their titles."
          ))
        score += 1
      }
      if context.supportsNumberConvention, trackMismatch || discMismatch {
        evidence.append(
          String(
            localized:
              "Other numbered files in this folder agree with their embedded disc and track numbers."
          ))
        score += 1
      }
      if let audioReference {
        evidence.append(
          String(
            localized:
              "The encoded audio payload exactly matches “\(audioReference.url.lastPathComponent),” whose filename and title agree."
          )
        )
        score += 3
      }

      guard score >= 2 else { continue }
      let confidence: MetadataProblem.Confidence = score >= 3 ? .high : .medium
      let reason: MetadataProblem.Reason
      if audioReference != nil {
        reason = .matchingAudio
      } else if copiedFromPeer != nil {
        reason = .copiedTags
      } else if trackMismatch || discMismatch {
        reason = .trackNumberConflict
      } else {
        reason = .filenameConflict
      }

      var correction = MetadataProblem.Correction()
      if confidence == .high {
        let hasStrongFilenameSupport =
          copiedFromPeer != nil || audioReference != nil
          || context.supportsTitleConvention
        if titleMismatch, hasStrongFilenameSupport {
          correction.title = resolved.title
        }
        if artistMismatch, resolved.artist != nil,
          audioReference != nil || (context.usesArtistTitle && context.supportsTitleConvention)
        {
          // Artist values come only from an explicit Artist - Title filename
          // convention or a matching-audio reference, never from title text.
          correction.artist = resolved.artist
        }
        if trackMismatch,
          copiedFromPeer != nil || audioReference != nil || context.supportsNumberConvention
        {
          correction.trackNumber = resolved.trackNumber
        }
        if discMismatch,
          copiedFromPeer != nil || audioReference != nil || context.supportsNumberConvention
        {
          correction.discNumber = resolved.discNumber
        }
      }

      findings.append(
        MetadataProblem(
          track: track,
          reason: reason,
          confidence: confidence,
          evidence: evidence,
          proposedCorrection: correction.isEmpty ? nil : correction))
    }

    return findings.sorted { lhs, rhs in
      if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
      return lhs.track.url.path.localizedStandardCompare(rhs.track.url.path) == .orderedAscending
    }
  }

  // MARK: - Filename interpretation

  private struct ParsedFilename {
    var remainder: String?
    var splitArtist: String?
    var splitTitle: String?
    var discNumber: Int?
    var trackNumber: Int?

    func resolved(for track: LibraryTrack, folderUsesArtistTitle: Bool) -> ResolvedFilename {
      guard let remainder else {
        return ResolvedFilename(title: nil, artist: nil, discNumber: discNumber, trackNumber: trackNumber)
      }
      if titlesMatch(remainder, track.title) {
        return ResolvedFilename(
          title: remainder, artist: nil, discNumber: discNumber, trackNumber: trackNumber)
      }
      if let splitArtist, let splitTitle,
        folderUsesArtistTitle || titlesMatch(splitTitle, track.title)
          || textKey(splitArtist) == textKey(track.artist)
      {
        return ResolvedFilename(
          title: splitTitle, artist: splitArtist, discNumber: discNumber,
          trackNumber: trackNumber)
      }
      return ResolvedFilename(
        title: remainder, artist: nil, discNumber: discNumber, trackNumber: trackNumber)
    }
  }

  private struct ResolvedFilename {
    var title: String?
    var artist: String?
    var discNumber: Int?
    var trackNumber: Int?
  }

  private struct FolderContext {
    var supportsTitleConvention: Bool
    var supportsNumberConvention: Bool
    var usesArtistTitle: Bool

    static let empty = FolderContext(
      supportsTitleConvention: false, supportsNumberConvention: false,
      usesArtistTitle: false)
  }

  private static func folderContext(
    for tracks: [LibraryTrack], parsed: [TrackID: ParsedFilename]
  ) -> FolderContext {
    var titleMatches = 0
    var titleComparisons = 0
    var numberMatches = 0
    var numberComparisons = 0
    var artistTitleMatches = 0

    for track in tracks {
      guard let filename = parsed[track.id] else { continue }
      if let remainder = filename.remainder {
        titleComparisons += 1
        if titlesMatch(remainder, track.title) { titleMatches += 1 }
      }
      if let splitArtist = filename.splitArtist, let splitTitle = filename.splitTitle,
        textKey(splitArtist) == textKey(track.artist), titlesMatch(splitTitle, track.title)
      {
        artistTitleMatches += 1
        if !titlesMatch(filename.remainder, track.title) { titleMatches += 1 }
      }
      if let number = filename.trackNumber, track.trackNumber > 0 {
        numberComparisons += 1
        if number == track.trackNumber { numberMatches += 1 }
      }
    }

    return FolderContext(
      supportsTitleConvention: titleMatches >= 2
        && titleMatches * 4 >= max(titleComparisons, 1) * 3,
      supportsNumberConvention: numberMatches >= 2
        && numberMatches * 4 >= max(numberComparisons, 1) * 3,
      usesArtistTitle: artistTitleMatches >= 2)
  }

  private static let discTrackPattern = try! NSRegularExpression(
    pattern:
      #"(?i)^\s*(?:cd|disc)?\s*(\d{1,2})\s*[-_.]\s*(\d{1,2})\s*(?:[-–—._]\s*|\s+)(.+)$"#)
  private static let trackPattern = try! NSRegularExpression(
    pattern: #"^\s*(\d{1,3})\s*(?:[-–—._]\s*|\s+)(.+)$"#)
  private static let artistTitlePattern = try! NSRegularExpression(
    pattern: #"^\s*(.+?)\s+[-–—]\s+(.+?)\s*$"#)

  private static func parseFilename(_ url: URL) -> ParsedFilename {
    let rawStem = url.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "_", with: " ")
    var stem = rawStem.replacingOccurrences(
      of: #"(?i)^\s*copy(?:\s+\d+)?\s+of\s+"#, with: "",
      options: .regularExpression)
    stem = stem.replacingOccurrences(
      of: #"(?i)\s+(?:\(\d+\)|copy(?:\s+\d+)?)\s*$"#, with: "",
      options: .regularExpression)
    var remainder = stem
    var discNumber: Int?
    var trackNumber: Int?

    if let groups = captures(discTrackPattern, in: stem), groups.count == 3 {
      discNumber = Int(groups[0])
      trackNumber = Int(groups[1])
      remainder = groups[2]
    } else if let groups = captures(trackPattern, in: stem), groups.count == 2 {
      trackNumber = Int(groups[0])
      remainder = groups[1]
    }

    remainder = cleanCandidate(remainder)
    guard isMeaningfulText(remainder) else {
      return ParsedFilename(
        remainder: nil, splitArtist: nil, splitTitle: nil,
        discNumber: discNumber, trackNumber: trackNumber)
    }

    let split = captures(artistTitlePattern, in: remainder)
    return ParsedFilename(
      remainder: remainder,
      splitArtist: split.flatMap { $0.count == 2 ? cleanCandidate($0[0]) : nil },
      splitTitle: split.flatMap { $0.count == 2 ? cleanCandidate($0[1]) : nil },
      discNumber: discNumber,
      trackNumber: trackNumber)
  }

  private static func captures(_ regex: NSRegularExpression, in text: String) -> [String]? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { return nil }
    return (1..<match.numberOfRanges).compactMap { index in
      guard let range = Range(match.range(at: index), in: text) else { return nil }
      return String(text[range])
    }
  }

  private static func cleanCandidate(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  private static func isMeaningfulText(_ value: String) -> Bool {
    let tokens = textTokens(value)
    return !tokens.isEmpty && !(tokens.count == 1 && Int(tokens[0]) != nil)
  }

  private static func titleConflicts(_ filename: String?, _ tagged: String) -> Bool {
    guard let filename, isMeaningfulText(filename), isMeaningfulText(tagged) else { return false }
    return !titlesMatch(filename, tagged)
  }

  private static func artistConflicts(_ filename: String?, _ tagged: String) -> Bool {
    guard let filename, isMeaningfulText(filename), isMeaningfulText(tagged) else { return false }
    return textKey(filename) != textKey(tagged)
  }

  private static func numberConflicts(_ filename: Int?, _ tagged: Int) -> Bool {
    guard let filename, filename > 0, tagged > 0 else { return false }
    return filename != tagged
  }

  private static func numbersMatch(_ filename: Int?, _ tagged: Int) -> Bool {
    guard let filename, filename > 0, tagged > 0 else { return true }
    return filename == tagged
  }

  private static func titlesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
    let left = textTokens(lhs ?? "")
    let right = textTokens(rhs ?? "")
    guard !left.isEmpty, !right.isEmpty else { return false }
    if left == right { return true }

    // Ignore only common file-copy decorations, not musical qualifiers such
    // as remix, live, radio edit, or remaster, which can identify a recording.
    let decorations: Set<String> = ["copy", "audio", "official"]
    return left.filter { !decorations.contains($0) } == right.filter { !decorations.contains($0) }
  }

  private static func textKey(_ value: String) -> String {
    textTokens(value).joined(separator: " ")
  }

  private static func textTokens(_ value: String) -> [String] {
    let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    return folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
  }

  // MARK: - Corroborating tag and audio evidence

  private struct TagKey: Hashable {
    let title: String
    let artist: String
    let album: String
    let discNumber: Int
    let trackNumber: Int

    init?(_ track: LibraryTrack) {
      title = textKey(track.title)
      artist = textKey(track.artist)
      album = textKey(track.album)
      discNumber = track.discNumber
      trackNumber = track.trackNumber
      guard !title.isEmpty, !artist.isEmpty else { return nil }
    }
  }

  private static func cachedHash(
    for track: LibraryTrack,
    cache: inout [TrackID: String?],
    audioContentHash: AudioContentHash
  ) -> String? {
    if let cached = cache[track.id] { return cached }
    let value = try? audioContentHash(track.url)
    cache[track.id] = value ?? nil
    return value ?? nil
  }

  /// Hashes the MPEG payload while excluding ID3v2 and ID3v1 blocks. This
  /// catches the same local encode carrying different metadata without ever
  /// uploading or altering a file.
  static func encodedAudioSHA256(_ url: URL) throws -> String? {
    guard url.pathExtension.lowercased() == "mp3" else { return nil }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let fileSize = try handle.seekToEnd()
    guard fileSize > 0 else { return nil }

    try handle.seek(toOffset: 0)
    let header = try handle.read(upToCount: 10) ?? Data()
    var start: UInt64 = 0
    if header.count == 10, header.starts(with: Data("ID3".utf8)),
      header[6...9].allSatisfy({ $0 & 0x80 == 0 })
    {
      let tagSize = header[6...9].reduce(0) { ($0 << 7) | UInt64($1) }
      let hasFooter = header[5] & 0x10 != 0
      start = 10 + tagSize + (hasFooter ? 10 : 0)
    }

    var end = fileSize
    if fileSize >= 128 {
      try handle.seek(toOffset: fileSize - 128)
      if (try handle.read(upToCount: 3)) == Data("TAG".utf8) { end -= 128 }
    }
    guard start < end else { return nil }

    try handle.seek(toOffset: start)
    var remaining = end - start
    var hasher = SHA256()
    while remaining > 0 {
      let count = min(Int(remaining), 1_048_576)
      guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return nil }
      hasher.update(data: chunk)
      remaining -= UInt64(chunk.count)
    }
    return hasher.finalize().hexString
  }

  private static func display(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? String(localized: "blank") : value
  }

  private static func display(_ value: Int) -> String {
    value > 0 ? String(value) : String(localized: "blank")
  }
}
