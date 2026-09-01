import Foundation

/// The interoperable genre field in older audio formats is a string, while
/// newer taggers frequently treat it as an ordered list. Keep that wire format
/// at the file boundary and give the rest of Nightdrive one canonical parser.
enum GenreMetadata {
  static let separator = "; "

  static func values(from rawValue: String) -> [String] {
    var seen: Set<String> = []
    var values: [String] = []
    for part in rawValue.split(
      omittingEmptySubsequences: true,
      whereSeparator: { $0 == ";" || $0 == "\0" })
    {
      let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
      let key = normalizedKey(value)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      values.append(value)
    }
    return values
  }

  static func joined(_ values: [String]) -> String {
    canonicalValues(values).joined(separator: separator)
  }

  static func primary(from rawValue: String) -> String {
    values(from: rawValue).first ?? ""
  }

  static func canonicalValues(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for rawValue in values {
      for value in self.values(from: rawValue) {
        let key = normalizedKey(value)
        guard seen.insert(key).inserted else { continue }
        result.append(value)
      }
    }
    return result
  }

  static func normalizedKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }

  /// The conventional genre spelling that marks a file as an audiobook, used
  /// when a format (like MP3) has no dedicated media-kind field.
  static let audiobookGenre = "Audiobook"
  private static let audiobookGenreKeys: Set<String> = ["audiobook", "audiobooks"]

  static func isAudiobookGenre(_ value: String) -> Bool {
    audiobookGenreKeys.contains(normalizedKey(value))
  }

  static func libraryValues(from tracks: [LibraryTrack]) -> [String] {
    var valuesByKey: [String: (value: String, count: Int)] = [:]
    for track in tracks {
      for value in track.genres {
        let key = normalizedKey(value)
        guard !key.isEmpty else { continue }
        if let existing = valuesByKey[key] {
          valuesByKey[key] = (existing.value, existing.count + 1)
        } else {
          valuesByKey[key] = (value, 1)
        }
      }
    }
    return valuesByKey.values.sorted {
      if $0.count != $1.count { return $0.count > $1.count }
      return $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
    }.map(\.value)
  }

  static func completions(
    for query: String,
    from candidates: [String],
    excluding excludedValues: [String] = [],
    limit: Int = 8
  ) -> [String] {
    guard limit > 0 else { return [] }
    let queryKey = normalizedKey(query)
    let excludedKeys = Set(excludedValues.map(normalizedKey))
    var seen: Set<String> = []
    var prefixMatches: [String] = []
    var otherMatches: [String] = []
    for candidate in candidates {
      let key = normalizedKey(candidate)
      guard !key.isEmpty, !excludedKeys.contains(key), seen.insert(key).inserted,
        queryKey.isEmpty || key.contains(queryKey)
      else { continue }
      if queryKey.isEmpty || key.hasPrefix(queryKey) {
        prefixMatches.append(candidate)
      } else {
        otherMatches.append(candidate)
      }
    }
    return Array((prefixMatches + otherMatches).prefix(limit))
  }
}

extension TrackMetadata {
  var genres: [String] {
    get { GenreMetadata.values(from: genre) }
    set { genre = GenreMetadata.joined(newValue) }
  }

  var primaryGenre: String {
    GenreMetadata.primary(from: genre)
  }

  var hasAudiobookGenre: Bool {
    genres.contains(where: GenreMetadata.isAudiobookGenre)
  }
}

extension LibraryTrack {
  var genres: [String] { metadata.genres }
  var primaryGenre: String { metadata.primaryGenre }
}

struct GenreCleanupGroup: Identifiable, Sendable {
  let id: String
  let genres: [String]
  let tracks: [LibraryTrack]
  let suggestedPrimary: String
  let recognizedGenres: Set<String>
  let wasComparedWithRecognizedGenres: Bool

  var songCount: Int { tracks.count }
  var hasUnrecognizedGenres: Bool {
    wasComparedWithRecognizedGenres && genres.contains { !recognizedGenres.contains($0) }
  }

  func isRecognized(_ genre: String) -> Bool {
    !wasComparedWithRecognizedGenres || recognizedGenres.contains(genre)
  }
}

enum GenreCleanupPlanner {
  static func groups(
    in tracks: [LibraryTrack],
    recognizedGenreNames: Set<String> = []
  ) -> [GenreCleanupGroup] {
    let recognizedKeys = Set(recognizedGenreNames.map(GenreMetadata.normalizedKey))
    let tokenFrequency = tracks.reduce(into: [String: Int]()) { result, track in
      for genre in track.genres {
        result[GenreMetadata.normalizedKey(genre), default: 0] += 1
      }
    }

    var buckets: [String: (genres: [String], tracks: [LibraryTrack])] = [:]
    for track in tracks {
      let genres = track.genres
      guard !genres.isEmpty else { continue }
      let unrecognized =
        !recognizedKeys.isEmpty
        && genres.contains { !recognizedKeys.contains(GenreMetadata.normalizedKey($0)) }
      guard genres.count > 1 || unrecognized else { continue }
      let id = genres.map(GenreMetadata.normalizedKey).joined(separator: "\0")
      if buckets[id] == nil { buckets[id] = (genres, []) }
      buckets[id]?.tracks.append(track)
    }

    return buckets.map { id, bucket in
      let recognized = Set(
        bucket.genres.filter { recognizedKeys.contains(GenreMetadata.normalizedKey($0)) })
      let candidates = recognized.isEmpty ? bucket.genres : bucket.genres.filter(recognized.contains)
      let primary =
        candidates.enumerated().max { left, right in
          let leftCount = tokenFrequency[GenreMetadata.normalizedKey(left.element), default: 0]
          let rightCount = tokenFrequency[GenreMetadata.normalizedKey(right.element), default: 0]
          if leftCount != rightCount { return leftCount < rightCount }
          return left.offset > right.offset
        }?.element ?? bucket.genres[0]
      return GenreCleanupGroup(
        id: id,
        genres: bucket.genres,
        tracks: bucket.tracks.sorted {
          $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        },
        suggestedPrimary: primary,
        recognizedGenres: recognized,
        wasComparedWithRecognizedGenres: !recognizedKeys.isEmpty)
    }.sorted {
      if $0.songCount != $1.songCount { return $0.songCount > $1.songCount }
      return $0.genres.joined(separator: GenreMetadata.separator)
        .localizedCaseInsensitiveCompare($1.genres.joined(separator: GenreMetadata.separator))
        == .orderedAscending
    }
  }

  static func edits(
    for groups: [GenreCleanupGroup],
    selections: [String: GenreCleanupSelection],
    keepMultiple: Bool
  ) -> [TrackMetadataEdit] {
    groups.flatMap { group -> [TrackMetadataEdit] in
      guard let selection = selections[group.id] else { return [] }
      guard !selection.primary.isEmpty, selection.genres.contains(selection.primary) else {
        return []
      }
      let kept =
        keepMultiple
        ? [selection.primary]
          + selection.genres.filter { $0 != selection.primary }
        : [selection.primary]
      let genre = GenreMetadata.joined(kept)
      return group.tracks.compactMap { track in
        guard track.genre != genre else { return nil }
        var metadata = TrackMetadata(track)
        metadata.genre = genre
        return TrackMetadataEdit(track: track, metadata: metadata)
      }
    }
  }
}

struct GenreCleanupSelection: Equatable, Sendable {
  var primary: String
  var genres: [String]

  init(group: GenreCleanupGroup) {
    let initialPrimary = group.recognizedGenres.isEmpty ? "" : group.suggestedPrimary
    primary = initialPrimary
    let selectedGenres =
      group.recognizedGenres.isEmpty
      ? group.genres
      : group.genres.filter(group.recognizedGenres.contains)
    genres =
      initialPrimary.isEmpty
      ? selectedGenres
      : [initialPrimary] + selectedGenres.filter { $0 != initialPrimary }
  }
}
