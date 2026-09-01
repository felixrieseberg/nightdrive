import Foundation

/// One show found in the iTunes podcast directory.
struct PodcastDirectoryResult: Identifiable, Equatable, Sendable {
  var id: Int
  var title: String
  var author: String
  var feedURL: URL
  var artworkURL: URL?
  var episodeCount: Int
  var genre: String?
}

/// One entry of a parsed podcast RSS feed.
struct PodcastEpisode: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var showTitle: String
  var enclosureURL: URL
  var enclosureType: String? = nil
  var publishedAt: Date?
  var durationSeconds: Int?
  var episodeDescription: String?
  var episodeNumber: Int?
  var sizeBytes: Int64?
}

/// A parsed podcast RSS feed with its episodes ordered newest first.
struct PodcastFeed: Equatable, Sendable {
  var title: String
  var author: String?
  var feedDescription: String?
  var artworkURL: URL?
  var episodes: [PodcastEpisode]
}

/// A persisted podcast subscription, identified by its feed URL.
struct PodcastSubscription: Identifiable, Codable, Equatable, Sendable {
  var id: URL { feedURL }
  var feedURL: URL
  var title: String
  var author: String?
  var artworkURL: URL?
  var addedAt: Date
  /// How many of the newest episodes to download automatically; 0 is off.
  var autoDownloadCount: Int = 0
  /// How many of the newest episodes are exempt from automatic age-based
  /// deletion; 0 leaves downloaded episodes untouched.
  var autoDeleteKeepCount: Int = 0
  /// Remove downloaded episodes once they have been listened to (in the app
  /// or on a synced iPod).
  var removePlayedEpisodes: Bool = false
}

extension PodcastSubscription {
  private enum CodingKeys: String, CodingKey {
    case feedURL
    case title
    case author
    case artworkURL
    case addedAt
    case autoDownloadCount
    case autoDeleteKeepCount
    case removePlayedEpisodes
  }

  /// Automation fields have been added over time. Decode them explicitly so
  /// an older saved subscription remains valid and each new policy defaults
  /// to off instead of making the entire subscription list fail to load.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    feedURL = try values.decode(URL.self, forKey: .feedURL)
    title = try values.decode(String.self, forKey: .title)
    author = try values.decodeIfPresent(String.self, forKey: .author)
    artworkURL = try values.decodeIfPresent(URL.self, forKey: .artworkURL)
    addedAt = try values.decode(Date.self, forKey: .addedAt)
    autoDownloadCount = max(
      0, try values.decodeIfPresent(Int.self, forKey: .autoDownloadCount) ?? 0)
    autoDeleteKeepCount = max(
      0, try values.decodeIfPresent(Int.self, forKey: .autoDeleteKeepCount) ?? 0)
    removePlayedEpisodes =
      try values.decodeIfPresent(Bool.self, forKey: .removePlayedEpisodes) ?? false
  }

  func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(feedURL, forKey: .feedURL)
    try values.encode(title, forKey: .title)
    try values.encodeIfPresent(author, forKey: .author)
    try values.encodeIfPresent(artworkURL, forKey: .artworkURL)
    try values.encode(addedAt, forKey: .addedAt)
    try values.encode(autoDownloadCount, forKey: .autoDownloadCount)
    try values.encode(autoDeleteKeepCount, forKey: .autoDeleteKeepCount)
    try values.encode(removePlayedEpisodes, forKey: .removePlayedEpisodes)
  }
}

/// The local download lifecycle of one episode.
enum PodcastEpisodeState: Equatable, Sendable {
  case notDownloaded
  case downloading(progress: Double)
  case downloaded(fileURL: URL)
  case failed(message: String)
}
