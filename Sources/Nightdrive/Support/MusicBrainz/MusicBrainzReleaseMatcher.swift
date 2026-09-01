import Foundation

struct MusicBrainzTrackProposal: Identifiable, Equatable, Sendable {
  let track: LibraryTrack
  let current: TrackMetadata
  let proposed: TrackMetadata

  var id: String { track.id.rawValue }

  var hasChanges: Bool { proposed != current }
}

enum MusicBrainzReleaseMatcher {
  static func proposals(
    for tracks: [LibraryTrack], release: MusicBrainzRelease
  ) -> [MusicBrainzTrackProposal] {
    var unclaimed = Array(release.tracks.indices)

    func claim(where predicate: (MusicBrainzReleaseTrack) -> Bool) -> MusicBrainzReleaseTrack? {
      guard let slot = unclaimed.firstIndex(where: { predicate(release.tracks[$0]) })
      else { return nil }
      return release.tracks[unclaimed.remove(at: slot)]
    }

    var matches: [(track: LibraryTrack, releaseTrack: MusicBrainzReleaseTrack?)] = []

    for track in tracks {
      guard track.trackNumber > 0 else {
        matches.append((track, nil))
        continue
      }
      let disc = track.discNumber > 0 ? track.discNumber : 1
      let byPosition = claim {
        $0.trackNumber == track.trackNumber && $0.discNumber == disc
      }
      matches.append((track, byPosition))
    }

    for index in matches.indices where matches[index].releaseTrack == nil {
      let title = normalized(matches[index].track.displayTitle)
      guard !title.isEmpty else { continue }
      let byTitle =
        claim { normalized($0.title) == title }
        ?? claim { fuzzyContains(normalized($0.title), title) }
      matches[index].releaseTrack = byTitle
    }

    return matches.map { match in
      let current = TrackMetadata(match.track)
      guard let releaseTrack = match.releaseTrack else {
        return MusicBrainzTrackProposal(track: match.track, current: current, proposed: current)
      }
      return MusicBrainzTrackProposal(
        track: match.track,
        current: current,
        proposed: proposedMetadata(current: current, release: release, track: releaseTrack))
    }
  }

  static func proposedMetadata(
    current: TrackMetadata, release: MusicBrainzRelease, track: MusicBrainzReleaseTrack
  ) -> TrackMetadata {
    var proposed = current
    if !track.title.isEmpty { proposed.title = track.title }
    if !track.artistName.isEmpty { proposed.artist = track.artistName }
    if !release.title.isEmpty { proposed.album = release.title }
    if !release.artistName.isEmpty { proposed.albumArtist = release.artistName }
    if release.year > 0 { proposed.year = release.year }
    if track.trackNumber > 0 { proposed.trackNumber = track.trackNumber }
    if track.trackCount > 0 { proposed.trackCount = track.trackCount }
    if track.discNumber > 0 { proposed.discNumber = track.discNumber }
    if release.discCount > 0 { proposed.discCount = release.discCount }
    proposed.musicBrainzRecordingID = track.recordingID
    proposed.musicBrainzReleaseID = release.id
    proposed.musicBrainzArtistID = track.artistID
    return proposed.normalized
  }

  private static func normalized(_ value: String) -> String {
    value.lowercased()
      .folding(options: [.diacriticInsensitive], locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static func fuzzyContains(_ a: String, _ b: String) -> Bool {
    guard !a.isEmpty, !b.isEmpty else { return false }
    return a.contains(b) || b.contains(a)
  }
}
