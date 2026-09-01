import Foundation

struct PodcastFeedError: LocalizedError, Equatable, Sendable {
  let reason: String

  var errorDescription: String? { reason }
}

/// Parses podcast RSS feeds with Foundation's XMLParser — no dependencies.
/// Understands the common `itunes:` extensions, tolerates missing optional
/// fields, and returns episodes ordered newest first.
enum PodcastFeedParser {
  static func parse(data: Data, feedURL: URL) throws -> PodcastFeed {
    let delegate = FeedDelegate()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    guard parser.parse() else {
      throw PodcastFeedError(
        reason: String(localized: "The feed could not be read as podcast RSS."))
    }
    guard delegate.sawChannel else {
      throw PodcastFeedError(
        reason: String(localized: "The feed does not contain a podcast channel."))
    }
    let showTitle = delegate.channelTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let episodes = delegate.items.compactMap {
      episode(from: $0, showTitle: showTitle, feedURL: feedURL)
    }
    return PodcastFeed(
      title: showTitle,
      author: nonEmpty(delegate.channelAuthor),
      feedDescription: nonEmpty(plainText(fromHTML: delegate.channelDescription)),
      artworkURL: delegate.channelArtwork.flatMap(URL.init(string:)),
      episodes: newestFirst(episodes))
  }

  /// Feed-scoped episode identity. RSS GUIDs are only unique within one
  /// feed, so two shows reusing the same guid must never share download
  /// state, file fingerprints, or author attribution.
  static func episodeID(feedURL: URL, itemIdentifier: String) -> String {
    "\(feedURL.absoluteString)#\(itemIdentifier)"
  }

  private static func episode(
    from item: FeedDelegate.Item, showTitle: String, feedURL: URL
  ) -> PodcastEpisode? {
    guard let enclosure = item.enclosureURL.flatMap(URL.init(string:)),
      isAudioEnclosure(type: item.enclosureType, url: enclosure)
    else { return nil }
    let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let guid = item.guid.trimmingCharacters(in: .whitespacesAndNewlines)
    let description = plainText(
      fromHTML: item.contentEncoded.isEmpty
        ? item.itemDescription : item.contentEncoded)
    return PodcastEpisode(
      id: episodeID(
        feedURL: feedURL, itemIdentifier: guid.isEmpty ? enclosure.absoluteString : guid),
      title: title.isEmpty ? String(localized: "Untitled Episode") : title,
      showTitle: showTitle,
      enclosureURL: enclosure,
      enclosureType: item.enclosureType,
      publishedAt: item.pubDate.flatMap(date(fromRFC822:)),
      durationSeconds: item.duration.flatMap(durationSeconds(from:)),
      episodeDescription: nonEmpty(description),
      episodeNumber: item.episodeNumber.flatMap { Int($0) },
      sizeBytes: item.enclosureLength.flatMap { Int64($0) })
  }

  private static func newestFirst(_ episodes: [PodcastEpisode]) -> [PodcastEpisode] {
    episodes.enumerated()
      .sorted { first, second in
        let lhs = first.element.publishedAt ?? .distantPast
        let rhs = second.element.publishedAt ?? .distantPast
        if lhs != rhs { return lhs > rhs }
        return first.offset < second.offset
      }
      .map(\.element)
  }

  static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff"]

  static func isAudioEnclosure(type: String?, url: URL) -> Bool {
    if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !type.isEmpty
    {
      if type.hasPrefix("audio/") { return true }
      if type.hasPrefix("video/") || type.hasPrefix("text/") { return false }
    }
    let ext = url.pathExtension.lowercased()
    return ext.isEmpty || audioExtensions.contains(ext)
  }

  /// Parses "HH:MM:SS", "MM:SS", or plain seconds.
  static func durationSeconds(from value: String) -> Int? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: ":")
      .map { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count <= 3, !parts.isEmpty, parts.allSatisfy({ ($0 ?? -1) >= 0 }) else {
      return nil
    }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
  }

  /// RFC822 pubDate formatters, most common variant first. Feed loads parse
  /// off-main and can overlap, so access to these mutable formatters is locked.
  private static let rfc822Formatters: [DateFormatter] = [
    "EEE, dd MMM yyyy HH:mm:ss Z",
    "EEE, dd MMM yyyy HH:mm:ss zzz",
    "EEE, dd MMM yyyy HH:mm Z",
    "dd MMM yyyy HH:mm:ss Z",
  ].map { format in
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = format
    return formatter
  }
  private static let rfc822FormatterLock = NSLock()

  static func date(fromRFC822 value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return rfc822FormatterLock.withLock {
      for formatter in rfc822Formatters {
        if let date = formatter.date(from: trimmed) { return date }
      }
      return nil
    }
  }

  /// Reduces HTML show notes to plain text: tags removed, common entities
  /// decoded, block boundaries turned into newlines, whitespace collapsed.
  /// Anchor targets survive as a trailing "(url)" after their link text, so
  /// show-note links stay usable once the markup is gone.
  static func plainText(fromHTML html: String) -> String {
    var text = html
    for block in ["</p>", "<br>", "<br/>", "<br />", "</li>", "</div>"] {
      text = text.replacingOccurrences(of: block, with: "\n", options: .caseInsensitive)
    }
    var stripped = ""
    stripped.reserveCapacity(text.count)
    var insideTag = false
    var tag = ""
    var anchorHref: String?
    var anchorText = ""
    for character in text {
      switch character {
      case "<":
        insideTag = true
        tag = ""
      case ">":
        insideTag = false
        let lowered = tag.lowercased()
        if lowered == "a" || lowered.hasPrefix("a ") || lowered.hasPrefix("a\n") {
          anchorHref = href(fromAnchorTag: tag)
          anchorText = ""
        } else if lowered == "/a" {
          if let href = anchorHref,
            !anchorText.localizedCaseInsensitiveContains(href)
          {
            stripped.append(" (\(href))")
          }
          anchorHref = nil
        }
      default:
        if insideTag {
          tag.append(character)
        } else {
          stripped.append(character)
          if anchorHref != nil { anchorText.append(character) }
        }
      }
    }
    stripped = decodeEntities(stripped)
    let lines =
      stripped
      .components(separatedBy: .newlines)
      .map { line in
        line.components(separatedBy: .whitespaces)
          .filter { !$0.isEmpty }
          .joined(separator: " ")
      }
      .filter { !$0.isEmpty }
    return lines.joined(separator: "\n")
  }

  private static func href(fromAnchorTag tag: String) -> String? {
    guard
      let hrefRange = tag.range(
        of: #"href\s*=\s*("[^"]*"|'[^']*')"#,
        options: [.regularExpression, .caseInsensitive])
    else { return nil }
    let assignment = tag[hrefRange]
    guard let quoteIndex = assignment.firstIndex(where: { $0 == "\"" || $0 == "'" }) else {
      return nil
    }
    let value = decodeEntities(
      String(assignment[assignment.index(after: quoteIndex)..<assignment.index(before: assignment.endIndex)]))
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.lowercased().hasPrefix("http") else { return nil }
    return trimmed
  }

  private static func decodeEntities(_ value: String) -> String {
    guard value.contains("&") else { return value }
    var text = value
    for (entity, replacement) in [
      ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
      ("&apos;", "'"), ("&nbsp;", " "),
    ] {
      text = text.replacingOccurrences(of: entity, with: replacement)
    }
    while let range = text.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
      let body = text[range].dropFirst(2).dropLast()
      let scalarValue: UInt32?
      if body.first == "x" || body.first == "X" {
        scalarValue = UInt32(body.dropFirst(), radix: 16)
      } else {
        scalarValue = UInt32(body)
      }
      if let scalarValue, let scalar = Unicode.Scalar(scalarValue) {
        text.replaceSubrange(range, with: String(Character(scalar)))
      } else {
        text.replaceSubrange(range, with: "")
      }
    }
    // Last, so "&amp;lt;" correctly becomes the literal text "&lt;".
    return text.replacingOccurrences(of: "&amp;", with: "&")
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }

  private final class FeedDelegate: NSObject, XMLParserDelegate {
    struct Item {
      var title = ""
      var guid = ""
      var pubDate: String?
      var enclosureURL: String?
      var enclosureType: String?
      var enclosureLength: String?
      var duration: String?
      var episodeNumber: String?
      var itemDescription = ""
      var contentEncoded = ""
    }

    var sawChannel = false
    var channelTitle = ""
    var channelAuthor = ""
    var channelDescription = ""
    var channelArtwork: String?
    var items: [Item] = []

    private var currentItem: Item?
    private var insideChannelImage = false
    private var text = ""
    private var capturing = false

    func parser(
      _ parser: XMLParser, didStartElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?,
      attributes attributeDict: [String: String]
    ) {
      let element = elementName.lowercased()
      text = ""
      capturing = false
      switch element {
      case "channel":
        sawChannel = true
      case "item":
        currentItem = Item()
      case "image" where currentItem == nil:
        insideChannelImage = true
      case "itunes:image" where currentItem == nil:
        if let href = attributeDict["href"], channelArtwork == nil {
          channelArtwork = href
        }
      case "enclosure":
        if var item = currentItem, item.enclosureURL == nil {
          item.enclosureURL = attributeDict["url"]
          item.enclosureType = attributeDict["type"]
          item.enclosureLength = attributeDict["length"]
          currentItem = item
        }
      case "title", "guid", "pubdate", "description", "content:encoded",
        "itunes:author", "itunes:duration", "itunes:episode", "url":
        capturing = true
      default:
        break
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      if capturing { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
      if capturing, let string = String(data: CDATABlock, encoding: .utf8) {
        text += string
      }
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String,
      namespaceURI: String?, qualifiedName qName: String?
    ) {
      let element = elementName.lowercased()
      defer {
        text = ""
        capturing = false
      }
      if var item = currentItem {
        switch element {
        case "item":
          items.append(item)
          currentItem = nil
          return
        case "title": item.title = text
        case "guid": item.guid = text
        case "pubdate": item.pubDate = text
        case "description": item.itemDescription = text
        case "content:encoded": item.contentEncoded = text
        case "itunes:duration": item.duration = text
        case "itunes:episode": item.episodeNumber = text.trimmingCharacters(in: .whitespaces)
        default: break
        }
        currentItem = item
        return
      }
      switch element {
      case "title" where !insideChannelImage:
        if channelTitle.isEmpty { channelTitle = text }
      case "itunes:author":
        if channelAuthor.isEmpty { channelAuthor = text }
      case "description":
        if channelDescription.isEmpty { channelDescription = text }
      case "url" where insideChannelImage:
        if channelArtwork == nil {
          channelArtwork = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
      case "image":
        insideChannelImage = false
      default:
        break
      }
    }
  }
}
