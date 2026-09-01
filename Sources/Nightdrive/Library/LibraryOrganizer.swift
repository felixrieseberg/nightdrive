import Foundation

/// One building block of an organized path — a folder level derived from a
/// track's tags. Users compose these into their own structure.
enum LibraryPathBlock: String, CaseIterable, Identifiable, Codable, Sendable {
  case artist
  case trackArtist
  case album
  case title
  case genre
  case composer
  case grouping
  case year
  case yearAlbum
  case decade
  case disc
  case bpm

  var id: String { rawValue }

  var label: String {
    switch self {
    case .artist: String(localized: "Artist")
    case .trackArtist: String(localized: "Track Artist")
    case .album: String(localized: "Album")
    case .title: String(localized: "Title")
    case .genre: String(localized: "Genre")
    case .composer: String(localized: "Composer")
    case .grouping: String(localized: "Grouping")
    case .year: String(localized: "Year")
    case .yearAlbum: String(localized: "Year – Album")
    case .decade: String(localized: "Decade")
    case .disc: String(localized: "Disc")
    case .bpm: String(localized: "BPM")
    }
  }

  /// What the block renders for the example path in the builder.
  var exampleValue: String {
    switch self {
    case .artist: "Daft Punk"
    case .trackArtist: "Daft Punk"
    case .album: "Discovery"
    case .title: "One More Time"
    case .genre: "Electronic"
    case .composer: "Bangalter, de Homem-Christo"
    case .grouping: "House"
    case .year: "2001"
    case .yearAlbum: "2001 – Discovery"
    case .decade: "2000s"
    case .disc: "Disc 1"
    case .bpm: "123 BPM"
    }
  }

  /// A short explanation for pickers and palettes.
  var detail: String {
    switch self {
    case .artist:
      String(localized: "Album artist when tagged; Various Artists for compilations")
    case .trackArtist: String(localized: "Each song’s own artist, even on compilations")
    case .album: String(localized: "Album title")
    case .title: String(localized: "Song title")
    case .genre: String(localized: "Genre")
    case .composer: String(localized: "Composer")
    case .grouping: String(localized: "Grouping tag")
    case .year: String(localized: "Release year")
    case .yearAlbum: String(localized: "Year and album in one folder")
    case .decade: String(localized: "Release decade, like 1990s")
    case .disc: String(localized: "Disc number, like Disc 1")
    case .bpm: String(localized: "Tempo, like 123 BPM")
    }
  }

  static func decodeList(_ value: String) -> [LibraryPathBlock]? {
    let names = value.split(separator: "/").map(String.init)
    let blocks = names.compactMap(LibraryPathBlock.init(rawValue:))
    return blocks.count == names.count ? blocks : nil
  }

  static func encodeList(_ blocks: [LibraryPathBlock]) -> String {
    blocks.map(\.rawValue).joined(separator: "/")
  }
}

enum LibraryOrganizePattern: String, CaseIterable, Identifiable, Sendable {
  case artistAlbum
  case albumArtistYearAlbum
  case genreArtistAlbum

  var id: String { rawValue }

  var label: String {
    blocks.map(\.label).joined(separator: " / ")
  }

  var blocks: [LibraryPathBlock] {
    switch self {
    case .artistAlbum: [.artist, .album]
    case .albumArtistYearAlbum: [.artist, .yearAlbum]
    case .genreArtistAlbum: [.genre, .artist, .album]
    }
  }
}

/// What to do with an out-of-place track when its organized destination is
/// already occupied. Moving to Trash is intentionally recoverable: organizer
/// conflicts can identify an extra file, but they do not prove byte-for-byte
/// duplication.
enum LibraryOrganizeConflictPolicy: String, Sendable {
  case rename
  case moveToTrash
}

struct LibraryOrganizePlanItem: Identifiable, Sendable, Equatable {
  enum Status: Sendable, Equatable {
    /// The file moves to `relativeDestination`.
    case move
    /// The file already sits at its organized location.
    case alreadyOrganized
    /// An unrelated file occupies the destination; the plan appended a
    /// numeric suffix to keep the move safe.
    case renamedToAvoidConflict
    /// Another file has claimed the organized destination, so this
    /// out-of-place source will be moved to Trash.
    case moveToTrash
  }

  let track: LibraryTrack
  let relativeDestination: String
  let status: Status
  /// The library track claiming `relativeDestination`, when the conflict is
  /// with another scanned track rather than an unrelated filesystem entry.
  let conflictKeeper: LibraryTrack?

  init(
    track: LibraryTrack,
    relativeDestination: String,
    status: Status,
    conflictKeeper: LibraryTrack? = nil
  ) {
    self.track = track
    self.relativeDestination = relativeDestination
    self.status = status
    self.conflictKeeper = conflictKeeper
  }

  var id: TrackID { track.id }
}

struct LibraryOrganizeConflictRemoval: Sendable, Equatable {
  let track: LibraryTrack
  let keeper: LibraryTrack
  let occupiedDestination: URL
}

struct LibraryOrganizeChanges: Sendable, Equatable {
  let relocations: [LibraryRelocationMove]
  let conflictRemovals: [LibraryOrganizeConflictRemoval]
}

struct LibraryOrganizePlan: Sendable, Equatable {
  let items: [LibraryOrganizePlanItem]

  var actionItems: [LibraryOrganizePlanItem] {
    items.filter { $0.status != .alreadyOrganized }
  }

  var moves: [LibraryOrganizePlanItem] {
    items.filter { $0.status == .move || $0.status == .renamedToAvoidConflict }
  }

  var conflictRemovals: [LibraryOrganizePlanItem] {
    items.filter { $0.status == .moveToTrash }
  }

  var alreadyOrganizedCount: Int {
    items.filter { $0.status == .alreadyOrganized }.count
  }

  func relocationMoves(root: URL) -> [LibraryRelocationMove] {
    moves.map {
      LibraryRelocationMove(
        track: $0.track,
        destination: root.appendingPathComponent($0.relativeDestination))
    }
  }

  func changes(root: URL) -> LibraryOrganizeChanges {
    LibraryOrganizeChanges(
      relocations: relocationMoves(root: root),
      conflictRemovals: conflictRemovals.compactMap {
        guard let keeper = $0.conflictKeeper else { return nil }
        return LibraryOrganizeConflictRemoval(
          track: $0.track,
          keeper: keeper,
          occupiedDestination: root.appendingPathComponent($0.relativeDestination))
      })
  }
}

enum LibraryOrganizer {
  /// Builds a dry-run plan mapping every track to its organized location.
  /// Planning is idempotent: running it over an already-organized library
  /// yields zero moves. An empty block list flattens the library into the
  /// root folder.
  static func plan(
    tracks: [LibraryTrack],
    root: URL,
    blocks: [LibraryPathBlock],
    renameFiles: Bool,
    conflictPolicy: LibraryOrganizeConflictPolicy = .rename,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> LibraryOrganizePlan {
    let root = root.standardizedFileURL
    var claimed: Set<String> = []
    var ownerByClaimedPath: [String: LibraryTrack] = [:]
    var items: [LibraryOrganizePlanItem] = []

    let ordered = tracks.sorted { $0.url.path < $1.url.path }

    // First pass: tracks already in place claim their paths so later
    // conflicting tracks uniquify against them deterministically.
    var desiredByID: [TrackID: String] = [:]
    for track in ordered {
      let destination = desiredRelativePath(
        for: track, blocks: blocks, renameFiles: renameFiles)
      desiredByID[track.id] = destination
      if isCurrentLocation(track: track, relativePath: destination, root: root) {
        let key = destination.lowercased()
        claimed.insert(key)
        ownerByClaimedPath[key] = track
      }
    }

    for track in ordered {
      let desired = desiredByID[track.id] ?? track.url.lastPathComponent
      if isCurrentLocation(track: track, relativePath: desired, root: root) {
        items.append(
          LibraryOrganizePlanItem(
            track: track, relativeDestination: desired, status: .alreadyOrganized))
        continue
      }
      let desiredKey = desired.lowercased()
      let conflictKeeper = ownerByClaimedPath[desiredKey]
      if conflictPolicy == .moveToTrash, let conflictKeeper {
        items.append(
          LibraryOrganizePlanItem(
            track: track,
            relativeDestination: desired,
            status: .moveToTrash,
            conflictKeeper: conflictKeeper))
        continue
      }
      let resolved = uniquePath(
        desired: desired, track: track, root: root,
        claimed: &claimed, fileExists: fileExists)
      ownerByClaimedPath[resolved.path.lowercased()] = track
      items.append(
        LibraryOrganizePlanItem(
          track: track,
          relativeDestination: resolved.path,
          status: resolved.renamed ? .renamedToAvoidConflict : .move))
    }
    return LibraryOrganizePlan(items: items)
  }

  /// Convenience for planning against a built-in preset.
  static func plan(
    tracks: [LibraryTrack],
    root: URL,
    pattern: LibraryOrganizePattern,
    renameFiles: Bool,
    conflictPolicy: LibraryOrganizeConflictPolicy = .rename,
    fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> LibraryOrganizePlan {
    plan(
      tracks: tracks, root: root, blocks: pattern.blocks, renameFiles: renameFiles,
      conflictPolicy: conflictPolicy,
      fileExists: fileExists)
  }

  static func desiredRelativePath(
    for track: LibraryTrack, blocks: [LibraryPathBlock], renameFiles: Bool
  ) -> String {
    let directories = blocks.map { sanitizeComponent(value(of: $0, for: track)) }
    let filename = renameFiles ? organizedFilename(for: track) : track.url.lastPathComponent
    // Sanitize the stem alone so a long title never truncates away the
    // audio extension the library scanner keys on.
    let ext = (filename as NSString).pathExtension
    let stem = ext.isEmpty ? filename : String(filename.dropLast(ext.count + 1))
    let sanitized = ext.isEmpty ? sanitizeComponent(stem) : "\(sanitizeComponent(stem)).\(ext)"
    return (directories + [sanitized]).joined(separator: "/")
  }

  private static func value(
    of block: LibraryPathBlock, for track: LibraryTrack
  ) -> String {
    switch block {
    case .artist:
      return resolvedAlbumArtist(for: track)
    case .trackArtist:
      return displayValue(track.artist, fallback: "Unknown Artist")
    case .album:
      return displayValue(track.album, fallback: "Unknown Album")
    case .title:
      return displayValue(track.title, fallback: "Unknown Title")
    case .genre:
      return displayValue(track.primaryGenre, fallback: "Unknown Genre")
    case .composer:
      return displayValue(track.composer, fallback: "Unknown Composer")
    case .grouping:
      return displayValue(track.grouping, fallback: "No Grouping")
    case .year:
      return track.year > 0 ? String(track.year) : "Unknown Year"
    case .yearAlbum:
      let album = displayValue(track.album, fallback: "Unknown Album")
      return track.year > 0 ? "\(track.year) – \(album)" : album
    case .decade:
      guard track.year > 0 else { return "Unknown Decade" }
      return "\(track.year / 10 * 10)s"
    case .disc:
      return track.discNumber > 0 ? "Disc \(track.discNumber)" : "Disc 1"
    case .bpm:
      return track.bpm > 0 ? "\(track.bpm) BPM" : "Unknown BPM"
    }
  }

  private static func resolvedAlbumArtist(for track: LibraryTrack) -> String {
    let tagged = LibraryStore.taggedAlbumArtist(for: track)
    return tagged.isEmpty ? LibraryStore.fallbackAlbumArtist(for: track) : tagged
  }

  private static func organizedFilename(for track: LibraryTrack) -> String {
    let ext = track.url.pathExtension
    var stem = track.displayTitle
    if track.trackNumber > 0 {
      let number = String(format: "%02d", track.trackNumber)
      let disc = track.discNumber > 0 && track.discCount > 1 ? "\(track.discNumber)-" : ""
      stem = "\(disc)\(number) \(stem)"
    }
    // Podcast download ownership is encoded in this suffix. Preserve it
    // through organizer renames so the download sidecar remains safe to use.
    let fingerprint = track.url.deletingPathExtension().lastPathComponent.suffix(10)
    if track.mediaKind == .podcast, fingerprint.isPodcastFingerprint {
      stem += " \(fingerprint)"
    }
    return ext.isEmpty ? stem : "\(stem).\(ext)"
  }

  /// Replaces filesystem-hostile characters, collapses whitespace, trims
  /// leading dots so files stay visible, and caps length so paths remain
  /// portable.
  static func sanitizeComponent(_ component: String) -> String {
    var value = component.replacingOccurrences(of: "/", with: "-")
    value = value.replacingOccurrences(of: ":", with: "-")
    value = value.replacingOccurrences(of: "\0", with: "")
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasPrefix(".") { value.removeFirst() }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.count > 100 {
      value = String(value.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return value.isEmpty ? "Unknown" : value
  }

  private static func displayValue(_ value: String, fallback: String) -> String {
    LibraryStore.displayValue(value, fallback: fallback)
  }

  private static func isCurrentLocation(
    track: LibraryTrack, relativePath: String, root: URL
  ) -> Bool {
    let destination = root.appendingPathComponent(relativePath).standardizedFileURL
    return destination.path == track.url.standardizedFileURL.path
  }

  private static func uniquePath(
    desired: String,
    track: LibraryTrack,
    root: URL,
    claimed: inout Set<String>,
    fileExists: (URL) -> Bool
  ) -> (path: String, renamed: Bool) {
    func isFree(_ candidate: String) -> Bool {
      guard !claimed.contains(candidate.lowercased()) else { return false }
      let url = root.appendingPathComponent(candidate).standardizedFileURL
      // Case-insensitive self-check: on APFS the track's own file "exists"
      // at a case-only variant of its path, but relocate handles that as a
      // rename, so it must not count as an obstruction.
      if url.path.lowercased() == track.url.standardizedFileURL.path.lowercased() {
        return true
      }
      return !fileExists(url)
    }
    if isFree(desired) {
      claimed.insert(desired.lowercased())
      return (desired, false)
    }
    let ext = (desired as NSString).pathExtension
    let stem = ext.isEmpty ? desired : String(desired.dropLast(ext.count + 1))
    for attempt in 2...99 {
      let candidate = ext.isEmpty ? "\(stem) \(attempt)" : "\(stem) \(attempt).\(ext)"
      if isFree(candidate) {
        claimed.insert(candidate.lowercased())
        return (candidate, true)
      }
    }
    let fallback =
      ext.isEmpty
      ? "\(stem) \(UUID().uuidString)"
      : "\(stem) \(UUID().uuidString).\(ext)"
    claimed.insert(fallback.lowercased())
    return (fallback, true)
  }
}

private extension Substring {
  var isPodcastFingerprint: Bool {
    count == 10 && first == "[" && last == "]"
      && dropFirst().dropLast().unicodeScalars.allSatisfy {
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
      }
  }
}
