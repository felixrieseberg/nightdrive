import Foundation

/// Maps podcast shows and episodes onto library-safe file names under
/// `<library>/Podcasts/<Show>/<Episode>.<ext>`.
enum PodcastFileNaming {
  static let podcastsFolderName = "Podcasts"
  static let maximumComponentLength = 100

  /// The audio file extensions the downloader will accept, matching the
  /// formats the library scanner indexes and can retag.
  static let downloadableExtensions: Set<String> = ["mp3", "m4a"]

  /// Turns arbitrary feed text into a single safe path component: path
  /// separators and control characters removed, whitespace collapsed,
  /// leading dots stripped, and length capped.
  static func sanitizedComponent(_ value: String, fallback: String) -> String {
    var cleaned = ""
    cleaned.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar {
      case "/", ":", "\\", "\u{0}"..."\u{1F}", "\u{7F}":
        cleaned.append(" ")
      default:
        cleaned.unicodeScalars.append(scalar)
      }
    }
    var collapsed = cleaned.collapsingWhitespace
    while collapsed.hasPrefix(".") {
      collapsed.removeFirst()
    }
    collapsed = collapsed.trimmingCharacters(in: .whitespaces)
    if collapsed.count > maximumComponentLength {
      collapsed = String(collapsed.prefix(maximumComponentLength))
        .trimmingCharacters(in: .whitespaces)
    }
    return collapsed.isEmpty ? fallback : collapsed
  }

  /// The extension a downloaded episode file should carry. A recognized
  /// MIME type disambiguates extensionless URLs; absent or generic types
  /// retain the conventional MP3 fallback.
  static func downloadExtension(forEnclosure url: URL, mimeType: String? = nil) -> String? {
    let ext = url.pathExtension.lowercased()
    if !ext.isEmpty { return downloadableExtensions.contains(ext) ? ext : nil }
    guard let mimeType = normalizedMimeType(mimeType), !mimeType.isEmpty else { return "mp3" }
    if let fileExtension = downloadExtension(forMimeType: mimeType) { return fileExtension }
    // Generic and nonstandard types are common on redirecting podcast CDNs.
    // Only a type that clearly describes unsupported media overrides the
    // historical extensionless-MP3 fallback.
    return mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/")
      || mimeType.hasPrefix("text/") ? nil : "mp3"
  }

  static func downloadExtension(forMimeType mimeType: String?) -> String? {
    switch normalizedMimeType(mimeType) {
    case "audio/mpeg", "audio/mp3", "audio/x-mp3", "audio/x-mpeg": "mp3"
    case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
    default: nil
    }
  }

  private static func normalizedMimeType(_ mimeType: String?) -> String? {
    mimeType?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The library-relative path a downloaded episode file lives at. The
  /// store persists this per completed download so the file survives a
  /// library folder move and publisher renames of show or episode titles.
  static func episodeRelativePath(
    showTitle: String, episodeTitle: String, episodeID: String, fileExtension: String
  ) -> String {
    let show = sanitizedComponent(showTitle, fallback: String(localized: "Untitled Show"))
    let title = sanitizedComponent(
      episodeTitle, fallback: String(localized: "Untitled Episode"))
    // Feeds reuse episode titles (rebroadcasts, trailers), so a stable
    // fingerprint of the episode's identity keeps distinct episodes from
    // claiming — and deleting — each other's file.
    return "\(podcastsFolderName)/\(show)/\(title) [\(fingerprint(episodeID))].\(fileExtension)"
  }

  /// Eight stable hex digits (FNV-1a) identifying an episode across runs.
  static func fingerprint(_ episodeID: String) -> String {
    var hash: UInt32 = 2_166_136_261
    for byte in episodeID.utf8 {
      hash ^= UInt32(byte)
      hash = hash &* 16_777_619
    }
    return String(format: "%08x", hash)
  }
}
