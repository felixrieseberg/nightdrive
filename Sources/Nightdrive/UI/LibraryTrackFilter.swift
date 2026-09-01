import Foundation

/// Case-folded searchable fields for every library track, built once per
/// library revision off the main actor so each filter keystroke scans
/// pre-folded strings instead of running four localized case-insensitive
/// searches per track.
struct LibraryTrackSearchIndex: Sendable {
  struct Entry: Sendable {
    let id: TrackID
    let title: String
    let artist: String
    let album: String
    let genre: String
  }

  let entries: [Entry]

  static func fold(_ value: String) -> String {
    value.folding(options: .caseInsensitive, locale: .current)
  }

  init(tracks: [LibraryTrack]) {
    entries = tracks.map { track in
      Entry(
        id: track.id,
        title: Self.fold(track.displayTitle),
        artist: Self.fold(track.artist),
        album: Self.fold(track.album),
        genre: Self.fold(track.genre))
    }
  }

  /// IDs of tracks whose title, artist, album, or genre contains the query,
  /// mirroring `SongRow.matches`. Throws `CancellationError` when a newer
  /// keystroke cancels the scan.
  func matchingIDs(for query: String) throws -> Set<TrackID> {
    let folded = Self.fold(query)
    guard !folded.isEmpty else { return Set(entries.map(\.id)) }
    var ids = Set<TrackID>()
    for (offset, entry) in entries.enumerated() {
      if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
      if entry.title.contains(folded) || entry.artist.contains(folded)
        || entry.album.contains(folded) || entry.genre.contains(folded)
      {
        ids.insert(entry.id)
      }
    }
    return ids
  }
}

/// Resolves the library search box off the main actor: the fold-once index
/// above plus debounced, cancellable matching. One instance is shared by the
/// Music view and every browse detail pane, so the index is built once per
/// library revision.
typealias LibraryTrackFilterModel = DebouncedSearchModel<LibraryTrackSearchIndex, Set<TrackID>>
