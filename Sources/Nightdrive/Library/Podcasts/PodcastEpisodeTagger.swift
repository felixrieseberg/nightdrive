import Foundation

/// Stamps downloaded episode files with the metadata the library and sync
/// pipeline key on. Genre "Podcast" and album = show title are always
/// forced so episodes are detected as podcasts and grouped by show.
enum PodcastEpisodeTagger {
  static let maximumCommentLength = 250

  static func tag(fileURL: URL, episode: PodcastEpisode, feedAuthor: String?) throws {
    let author = feedAuthor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let year: Int
    if let publishedAt = episode.publishedAt {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
      year = calendar.component(.year, from: publishedAt)
    } else {
      year = 0
    }
    let metadata = TrackMetadata(
      title: episode.title,
      artist: author.isEmpty ? episode.showTitle : author,
      album: episode.showTitle,
      albumArtist: "",
      composer: "",
      genre: "Podcast",
      grouping: "",
      year: year,
      bpm: 0,
      trackNumber: episode.episodeNumber ?? 0,
      trackCount: 0,
      discNumber: 0,
      discCount: 0,
      comment: truncatedComment(episode.episodeDescription),
      lyrics: "",
      compilation: false,
      releaseDate: episode.publishedAt)
    try TrackFileMetadataWriter.write(metadata, to: fileURL)
  }

  static func truncatedComment(_ description: String?) -> String {
    let flattened = description?.collapsingWhitespace ?? ""
    guard flattened.count > maximumCommentLength else { return flattened }
    return String(flattened.prefix(maximumCommentLength - 1))
      .trimmingCharacters(in: .whitespaces) + "…"
  }
}
