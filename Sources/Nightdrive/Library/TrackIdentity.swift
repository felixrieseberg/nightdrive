import Foundation

struct TrackID: Hashable, Sendable, RawRepresentable, Codable {
  let rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

  init(url: URL) {
    self.rawValue = url.standardizedFileURL.absoluteString
  }

  var fileURL: URL? {
    URL(string: rawValue)
  }
}

struct LibraryCatalog: Sendable, Equatable {
  let tracks: [LibraryTrack]
  private let positionsByID: [TrackID: Int]

  init(_ tracks: [LibraryTrack] = []) {
    self.tracks = tracks
    var positionsByID: [TrackID: Int] = [:]
    positionsByID.reserveCapacity(tracks.count)
    for (position, track) in tracks.enumerated() {
      if positionsByID[track.id] == nil {
        positionsByID[track.id] = position
      }
    }
    self.positionsByID = positionsByID
  }

  subscript(id: TrackID) -> LibraryTrack? {
    positionsByID[id].map { tracks[$0] }
  }

  func tracks(for ids: [TrackID]) -> [LibraryTrack] {
    ids.compactMap { self[$0] }
  }

  func tracksInLibraryOrder(for ids: Set<TrackID>) -> [LibraryTrack] {
    ids.compactMap { positionsByID[$0] }
      .sorted()
      .map { tracks[$0] }
  }
}
