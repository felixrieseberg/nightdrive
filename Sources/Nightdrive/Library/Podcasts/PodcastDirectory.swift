import Foundation

/// Builds iTunes Search API podcast queries and decodes their responses.
/// The endpoint is anonymous — no API key — but callers must still gate the
/// request behind the user's online-services consent before hitting it.
enum PodcastDirectory {
  static func searchURL(term: String) -> URL? {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    var components = URLComponents(string: "https://itunes.apple.com/search")
    components?.queryItems = [
      URLQueryItem(name: "media", value: "podcast"),
      URLQueryItem(name: "entity", value: "podcast"),
      URLQueryItem(name: "limit", value: "25"),
      URLQueryItem(name: "term", value: trimmed),
    ]
    return components?.url
  }

  static func results(from data: Data) throws -> [PodcastDirectoryResult] {
    let response = try JSONDecoder().decode(SearchResponse.self, from: data)
    return response.results.compactMap { result in
      guard let id = result.collectionId,
        let feedString = result.feedUrl,
        let feedURL = URL(string: feedString),
        feedURL.scheme != nil
      else { return nil }
      let artwork = result.artworkUrl600 ?? result.artworkUrl100
      return PodcastDirectoryResult(
        id: id,
        title: result.collectionName ?? "",
        author: result.artistName ?? "",
        feedURL: feedURL,
        artworkURL: artwork.flatMap(URL.init(string:)),
        episodeCount: result.trackCount ?? 0,
        genre: result.primaryGenreName)
    }
  }

  // MARK: - Top charts

  /// Apple's marketing-tools chart feed: anonymous JSON listing the current
  /// top podcasts for a storefront. It carries chart IDs but no feed URLs,
  /// so entries must be resolved through `lookupURL(ids:)` afterwards.
  static func topChartURL(limit: Int = 25, storefront: String = "us") -> URL? {
    URL(
      string:
        "https://rss.applemarketingtools.com/api/v2/\(storefront)/podcasts/top/\(limit)/podcasts.json"
    )
  }

  static func chartIDs(from data: Data) throws -> [Int] {
    let response = try JSONDecoder().decode(ChartResponse.self, from: data)
    return response.feed.results.compactMap { Int($0.id) }
  }

  /// Batched iTunes Lookup call resolving chart IDs to full podcast records
  /// (including their RSS feed URLs). Responses decode via `results(from:)`.
  static func lookupURL(ids: [Int]) -> URL? {
    guard !ids.isEmpty else { return nil }
    var components = URLComponents(string: "https://itunes.apple.com/lookup")
    components?.queryItems = [
      URLQueryItem(name: "id", value: ids.map(String.init).joined(separator: ",")),
      URLQueryItem(name: "entity", value: "podcast"),
    ]
    return components?.url
  }

  /// Lookup responses are not guaranteed to preserve request order; put the
  /// resolved records back into chart order.
  static func ordered(
    _ results: [PodcastDirectoryResult], byChartIDs ids: [Int]
  ) -> [PodcastDirectoryResult] {
    let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return ids.compactMap { byID[$0] }
  }

  private struct ChartResponse: Decodable {
    var feed: ChartFeed
  }

  private struct ChartFeed: Decodable {
    var results: [ChartEntry]
  }

  private struct ChartEntry: Decodable {
    var id: String
  }

  private struct SearchResponse: Decodable {
    var results: [SearchResult]
  }

  private struct SearchResult: Decodable {
    var collectionId: Int?
    var collectionName: String?
    var artistName: String?
    var feedUrl: String?
    var artworkUrl600: String?
    var artworkUrl100: String?
    var trackCount: Int?
    var primaryGenreName: String?
  }
}
