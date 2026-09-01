import Foundation

struct MusicBrainzRecordingCandidate: Identifiable, Equatable, Sendable {
  let recordingID: String
  let score: Int
  let title: String
  let artistName: String
  let artistID: String
  let releaseID: String
  let releaseTitle: String
  let date: String
  let trackNumber: Int
  let discNumber: Int
  let trackCount: Int

  var id: String { "\(recordingID)/\(releaseID)" }

  var year: Int { Int(date.prefix(4)) ?? 0 }
}

struct MusicBrainzReleaseCandidate: Identifiable, Equatable, Sendable {
  let id: String
  let score: Int
  let title: String
  let artistName: String
  let date: String
  let country: String
  let trackCount: Int

  var year: Int { Int(date.prefix(4)) ?? 0 }
}

extension [MusicBrainzReleaseCandidate] {
  func sortedForLocalTrackCount(_ count: Int) -> [MusicBrainzReleaseCandidate] {
    sorted {
      let leftMatches = $0.trackCount == count
      let rightMatches = $1.trackCount == count
      if leftMatches != rightMatches { return leftMatches }
      return $0.score > $1.score
    }
  }
}

struct MusicBrainzReleaseTrack: Equatable, Sendable {
  let recordingID: String
  let title: String
  let artistName: String
  let artistID: String
  let discNumber: Int
  let trackNumber: Int
  let trackCount: Int
}

struct MusicBrainzRelease: Equatable, Sendable {
  let id: String
  let title: String
  let artistName: String
  let artistID: String
  let date: String
  let discCount: Int
  let tracks: [MusicBrainzReleaseTrack]

  var year: Int { Int(date.prefix(4)) ?? 0 }
}

enum MusicBrainzParser {
  // MARK: - Wire format

  private struct ArtistCredit: Decodable {
    var name: String?
    var joinphrase: String?
    var artist: Artist?

    struct Artist: Decodable {
      var id: String?
      var name: String?
    }
  }

  private struct RecordingSearchResponse: Decodable {
    var recordings: [Recording]?

    struct Recording: Decodable {
      var id: String?
      var score: Int?
      var title: String?
      var artistCredit: [ArtistCredit]?
      var releases: [Release]?
    }

    struct Release: Decodable {
      var id: String?
      var title: String?
      var date: String?
      var trackCount: Int?
      var media: [Medium]?
    }

    struct Medium: Decodable {
      var position: Int?
      var trackCount: Int?
      var track: [Track]?
    }

    struct Track: Decodable {
      var number: String?
      var title: String?
    }
  }

  private struct ReleaseSearchResponse: Decodable {
    var releases: [Release]?

    struct Release: Decodable {
      var id: String?
      var score: Int?
      var title: String?
      var date: String?
      var country: String?
      var trackCount: Int?
      var artistCredit: [ArtistCredit]?
    }
  }

  private struct ReleaseLookupResponse: Decodable {
    var id: String?
    var title: String?
    var date: String?
    var artistCredit: [ArtistCredit]?
    var media: [Medium]?

    struct Medium: Decodable {
      var position: Int?
      var trackCount: Int?
      var tracks: [Track]?
    }

    struct Track: Decodable {
      var position: Int?
      var number: String?
      var title: String?
      var artistCredit: [ArtistCredit]?
      var recording: Recording?
    }

    struct Recording: Decodable {
      var id: String?
      var title: String?
      var artistCredit: [ArtistCredit]?
    }
  }

  // MARK: - Parsing

  static func recordingCandidates(from data: Data) throws -> [MusicBrainzRecordingCandidate] {
    let response = try decode(RecordingSearchResponse.self, from: data)
    var candidates: [MusicBrainzRecordingCandidate] = []
    for recording in response.recordings ?? [] {
      guard let recordingID = recording.id, !recordingID.isEmpty else { continue }
      let (artistName, artistID) = credit(recording.artistCredit)
      let releases = (recording.releases ?? []).filter { $0.id?.isEmpty == false }
      for release in releases.isEmpty ? [nil] : releases.map(Optional.some) {
        let medium = release?.media?.first
        candidates.append(
          MusicBrainzRecordingCandidate(
            recordingID: recordingID,
            score: recording.score ?? 0,
            title: recording.title ?? "",
            artistName: artistName,
            artistID: artistID,
            releaseID: release?.id ?? "",
            releaseTitle: release?.title ?? "",
            date: release?.date ?? "",
            trackNumber: medium?.track?.first?.number.flatMap { Int($0) } ?? 0,
            discNumber: medium?.position ?? 0,
            trackCount: release?.trackCount ?? medium?.trackCount ?? 0))
      }
    }
    return candidates.sorted { $0.score > $1.score }
  }

  static func releaseCandidates(from data: Data) throws -> [MusicBrainzReleaseCandidate] {
    let response = try decode(ReleaseSearchResponse.self, from: data)
    return (response.releases ?? []).compactMap { release in
      guard let id = release.id, !id.isEmpty else { return nil }
      return MusicBrainzReleaseCandidate(
        id: id,
        score: release.score ?? 0,
        title: release.title ?? "",
        artistName: credit(release.artistCredit).name,
        date: release.date ?? "",
        country: release.country ?? "",
        trackCount: release.trackCount ?? 0)
    }
  }

  static func release(from data: Data) throws -> MusicBrainzRelease {
    let response = try decode(ReleaseLookupResponse.self, from: data)
    guard let id = response.id, !id.isEmpty else {
      throw MusicBrainzError.malformedResponse("The release lookup returned no release ID.")
    }
    let (releaseArtist, releaseArtistID) = credit(response.artistCredit)
    var tracks: [MusicBrainzReleaseTrack] = []
    let media = response.media ?? []
    for (index, medium) in media.enumerated() {
      let disc = medium.position ?? (index + 1)
      let mediumTracks = medium.tracks ?? []
      let count = medium.trackCount ?? mediumTracks.count
      for (trackIndex, track) in mediumTracks.enumerated() {
        var (artistName, artistID) = credit(track.artistCredit)
        if artistName.isEmpty {
          (artistName, artistID) = credit(track.recording?.artistCredit)
        }
        if artistName.isEmpty {
          (artistName, artistID) = (releaseArtist, releaseArtistID)
        }
        tracks.append(
          MusicBrainzReleaseTrack(
            recordingID: track.recording?.id ?? "",
            title: track.title ?? track.recording?.title ?? "",
            artistName: artistName,
            artistID: artistID,
            discNumber: disc,
            trackNumber: track.position ?? track.number.flatMap { Int($0) } ?? (trackIndex + 1),
            trackCount: count))
      }
    }
    return MusicBrainzRelease(
      id: id,
      title: response.title ?? "",
      artistName: releaseArtist,
      artistID: releaseArtistID,
      date: response.date ?? "",
      discCount: media.count,
      tracks: tracks)
  }

  private struct Key: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init(intValue: Int) {
      self.stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .custom { keys in
      let parts = keys.last!.stringValue.split(separator: "-")
      return Key(
        stringValue: parts.dropFirst().reduce(String(parts.first ?? "")) {
          $0 + String($1).capitalized
        })
    }
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw MusicBrainzError.malformedResponse(
        "The MusicBrainz response could not be read: \(error.localizedDescription)")
    }
  }

  private static func credit(_ credits: [ArtistCredit]?) -> (name: String, id: String) {
    guard let credits, !credits.isEmpty else { return ("", "") }
    let name = credits.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }
      .joined()
    return (name, credits.first?.artist?.id ?? "")
  }
}
