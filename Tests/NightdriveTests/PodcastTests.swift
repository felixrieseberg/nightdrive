import AVFoundation
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

// MARK: - Feed parsing

struct PodcastFeedParserTests {
  static let feedURL = URL(string: "https://example.com/feed.xml")!

  @Test
  func testParsesChannelAndEpisodes() throws {
    let feed = try PodcastFeedParser.parse(data: Data(Self.feedXML.utf8), feedURL: Self.feedURL)

    #expect((feed.title) == ("Baywatch Berlin"))
    #expect((feed.author) == ("Schmitt, Heufer-Umlauf & Lundt"))
    #expect((feed.feedDescription) == ("Talk & Entertainment from Berlin."))
    #expect((feed.artworkURL) == (URL(string: "https://example.com/cover.jpg")))

    // The video enclosure and the enclosure-less item are excluded.
    #expect((feed.episodes.count) == (3))
    for episode in feed.episodes {
      #expect((episode.showTitle) == ("Baywatch Berlin"))
    }
  }

  @Test
  func testOrdersEpisodesNewestFirstWithUndatedLast() throws {
    let feed = try PodcastFeedParser.parse(data: Data(Self.feedXML.utf8), feedURL: Self.feedURL)

    #expect((feed.episodes[0].title) == ("Folge 13: Neuer Kram"))
    #expect((feed.episodes[1].title) == ("Folge 12: Alter Kram"))
    #expect((feed.episodes[2].title) == ("Bonus ohne Datum"))
  }

  @Test
  func testParsesEpisodeFields() throws {
    let feed = try PodcastFeedParser.parse(data: Data(Self.feedXML.utf8), feedURL: Self.feedURL)

    let newest = feed.episodes[0]
    // Episode identity is namespaced by the feed URL so identical guids in
    // two different feeds never collide.
    #expect((newest.id) == ("https://example.com/feed.xml#guid-13"))
    #expect((newest.durationSeconds) == (45 * 60 + 10))
    #expect((newest.episodeNumber) == (13))
    #expect((newest.sizeBytes) == (52_428_800))
    #expect((newest.enclosureURL) == (URL(string: "https://example.com/ep13.mp3")))
    #expect(newest.enclosureType == "audio/mpeg")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let published = try #require(newest.publishedAt)
    #expect((calendar.component(.year, from: published)) == (2026))
    #expect((calendar.component(.day, from: published)) == (12))

    let older = feed.episodes[1]
    #expect((older.durationSeconds) == (3723))
    #expect((older.episodeDescription) == ("Highlights & lowlights.\nSee you soon."))

    let undated = feed.episodes[2]
    #expect((undated.publishedAt) == (nil))
    #expect((undated.durationSeconds) == (90))
    // No guid: the enclosure URL is the identity, still feed-scoped.
    #expect(
      (undated.id)
        == (PodcastFeedParser.episodeID(
          feedURL: Self.feedURL, itemIdentifier: "https://example.com/bonus.mp3")))
    // content:encoded CDATA HTML is reduced to plain text.
    #expect((undated.episodeDescription) == ("A \"quoted\" bonus\nwith lines."))
  }

  @Test
  func testRejectsNonFeedData() {
    #expect(throws: PodcastFeedError.self) {
      try PodcastFeedParser.parse(data: Data("not xml at all".utf8), feedURL: Self.feedURL)
    }
    #expect(throws: PodcastFeedError.self) {
      try PodcastFeedParser.parse(
        data: Data("<html><body>nope</body></html>".utf8), feedURL: Self.feedURL)
    }
    #expect(throws: PodcastFeedError.self) {
      try PodcastFeedParser.parse(
        data: Data("<rss><channel><title>Truncated".utf8), feedURL: Self.feedURL)
    }
  }

  @Test
  func testDurationVariants() {
    #expect((PodcastFeedParser.durationSeconds(from: "1:02:03")) == (3723))
    #expect((PodcastFeedParser.durationSeconds(from: "45:10")) == (2710))
    #expect((PodcastFeedParser.durationSeconds(from: "90")) == (90))
    #expect((PodcastFeedParser.durationSeconds(from: " 07:05 ")) == (425))
    #expect((PodcastFeedParser.durationSeconds(from: "abc")) == (nil))
    #expect((PodcastFeedParser.durationSeconds(from: "1:2:3:4")) == (nil))
    #expect((PodcastFeedParser.durationSeconds(from: "")) == (nil))
  }

  @Test
  func testDurationRejectsOverflowAndImplausibleLengths() {
    // Publisher-controlled components must never trap the process.
    #expect(PodcastFeedParser.durationSeconds(from: "9223372036854775807:00") == nil)
    #expect(PodcastFeedParser.durationSeconds(from: "9223372036854775807") == nil)
    #expect(PodcastFeedParser.durationSeconds(from: "1:9223372036854775807:00") == nil)
    #expect(PodcastFeedParser.durationSeconds(from: "99999999999999999999") == nil)
    #expect(PodcastFeedParser.durationSeconds(from: "00:00:40000000") == nil)
    let max = PodcastFeedParser.maxDurationSeconds
    #expect(PodcastFeedParser.durationSeconds(from: String(max)) == max)
    #expect(PodcastFeedParser.durationSeconds(from: String(max + 1)) == nil)
  }

  @Test
  func testPubDateVariants() {
    let numericZone = PodcastFeedParser.date(
      fromRFC822: "Mon, 12 Jan 2026 06:00:00 +0100")
    #expect((numericZone) == (Date(timeIntervalSince1970: 1_768_194_000)))
    let namedZone = PodcastFeedParser.date(fromRFC822: "Mon, 12 Jan 2026 05:00:00 GMT")
    #expect((namedZone) == (Date(timeIntervalSince1970: 1_768_194_000)))
    #expect((PodcastFeedParser.date(fromRFC822: "sometime soon")) == (nil))
    #expect((PodcastFeedParser.date(fromRFC822: "")) == (nil))
  }

  @Test
  func testHTMLStripping() {
    #expect(
      (PodcastFeedParser.plainText(
        fromHTML: "<p>Hello <b>world</b></p><p>Tom &amp; Jerry &#8212; &quot;hi&quot;</p>"))
        == ("Hello world\nTom & Jerry \u{2014} \"hi\""))
    #expect(
      (PodcastFeedParser.plainText(fromHTML: "line one<br/>line   two"))
        == ("line one\nline two"))
    #expect((PodcastFeedParser.plainText(fromHTML: "plain")) == ("plain"))
    // Hex entities decode; double-escaped entities decode exactly one level.
    #expect(
      PodcastFeedParser.plainText(fromHTML: "It&#x2019;s here &amp;lt;soon&amp;gt;")
        == "It\u{2019}s here &lt;soon&gt;")
  }

  @Test
  func testAnchorHrefsSurviveStripping() {
    // Anchor targets trail their link text so they stay usable as plain text.
    #expect(
      PodcastFeedParser.plainText(
        fromHTML: #"See the <a class="x" HREF="https://example.com/notes?a=1&amp;b=2">show notes</a>!"#)
        == "See the show notes (https://example.com/notes?a=1&b=2)!")
    // A bare URL as the link text is not repeated.
    #expect(
      PodcastFeedParser.plainText(
        fromHTML: #"Visit <a href="https://example.com">https://example.com</a> today"#)
        == "Visit https://example.com today")
    // Non-web schemes are dropped rather than surfaced.
    #expect(
      PodcastFeedParser.plainText(fromHTML: #"<a href="mailto:x@y.z">write us</a>"#)
        == "write us")
  }

  @Test
  func testAudioEnclosureDetection() throws {
    let mp3 = try #require(URL(string: "https://example.com/a.mp3"))
    let video = try #require(URL(string: "https://example.com/a.mp4"))
    #expect(PodcastFeedParser.isAudioEnclosure(type: "audio/mpeg", url: mp3))
    #expect(PodcastFeedParser.isAudioEnclosure(type: nil, url: mp3))
    #expect(PodcastFeedParser.isAudioEnclosure(type: "audio/x-m4a", url: video))
    #expect(PodcastFeedParser.isAudioEnclosure(type: "application/octet-stream", url: mp3))
    #expect(!PodcastFeedParser.isAudioEnclosure(type: "video/mp4", url: mp3))
    #expect(!PodcastFeedParser.isAudioEnclosure(type: nil, url: video))
  }

  static let feedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
         xmlns:content="http://purl.org/rss/1.0/modules/content/">
      <channel>
        <title>Baywatch Berlin</title>
        <itunes:author>Schmitt, Heufer-Umlauf &amp; Lundt</itunes:author>
        <description>Talk &amp; Entertainment from Berlin.</description>
        <itunes:image href="https://example.com/cover.jpg"/>
        <image>
          <url>https://example.com/legacy.jpg</url>
          <title>Baywatch Berlin</title>
        </image>
        <item>
          <title>Folge 12: Alter Kram</title>
          <guid isPermaLink="false">guid-12</guid>
          <pubDate>Mon, 05 Jan 2026 06:00:00 GMT</pubDate>
          <enclosure url="https://example.com/ep12.mp3" length="41943040" type="audio/mpeg"/>
          <itunes:duration>1:02:03</itunes:duration>
          <itunes:episode>12</itunes:episode>
          <description>&lt;p&gt;Highlights &amp;amp; lowlights.&lt;/p&gt;&lt;p&gt;See you soon.&lt;/p&gt;</description>
        </item>
        <item>
          <title>Folge 13: Neuer Kram</title>
          <guid>guid-13</guid>
          <pubDate>Mon, 12 Jan 2026 06:00:00 +0000</pubDate>
          <enclosure url="https://example.com/ep13.mp3" length="52428800" type="audio/mpeg"/>
          <itunes:duration>45:10</itunes:duration>
          <itunes:episode>13</itunes:episode>
          <description>Fresh stuff.</description>
        </item>
        <item>
          <title>Bonus ohne Datum</title>
          <enclosure url="https://example.com/bonus.mp3" length="1048576" type="audio/mpeg"/>
          <itunes:duration>90</itunes:duration>
          <content:encoded><![CDATA[<p>A &quot;quoted&quot; bonus</p><p>with lines.</p>]]></content:encoded>
        </item>
        <item>
          <title>Video Special</title>
          <guid>guid-video</guid>
          <enclosure url="https://example.com/video.mp4" length="99" type="video/mp4"/>
        </item>
        <item>
          <title>Announcement without enclosure</title>
          <guid>guid-empty</guid>
        </item>
      </channel>
    </rss>
    """
}

// MARK: - Directory search

struct PodcastDirectoryTests {
  @Test
  func testSearchURL() throws {
    let url = try #require(PodcastDirectory.searchURL(term: "Baywatch Berlin"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect((components.host) == ("itunes.apple.com"))
    #expect((components.path) == ("/search"))
    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "media", value: "podcast")))
    #expect(items.contains(URLQueryItem(name: "entity", value: "podcast")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "25")))
    #expect(items.contains(URLQueryItem(name: "term", value: "Baywatch Berlin")))
    #expect((PodcastDirectory.searchURL(term: "   ")) == (nil))
  }

  @Test
  func testDecodesSearchResponse() throws {
    let results = try PodcastDirectory.results(from: Data(Self.searchJSON.utf8))

    // The entry without a feedUrl is skipped.
    #expect((results.count) == (2))

    let best = results[0]
    #expect((best.id) == (1_461_705_468))
    #expect((best.title) == ("Baywatch Berlin"))
    #expect((best.author) == ("Klaas Heufer-Umlauf"))
    #expect((best.feedURL) == (URL(string: "https://example.com/baywatch.xml")))
    #expect((best.artworkURL) == (URL(string: "https://example.com/art600.jpg")))
    #expect((best.episodeCount) == (312))
    #expect((best.genre) == ("Comedy"))

    // Falls back to the small artwork when 600 px art is missing.
    #expect((results[1].artworkURL) == (URL(string: "https://example.com/art100.jpg")))
    #expect((results[1].genre) == (nil))
  }

  static let searchJSON = """
    {
      "resultCount": 3,
      "results": [
        {
          "collectionId": 1461705468,
          "collectionName": "Baywatch Berlin",
          "artistName": "Klaas Heufer-Umlauf",
          "feedUrl": "https://example.com/baywatch.xml",
          "artworkUrl100": "https://example.com/art100.jpg",
          "artworkUrl600": "https://example.com/art600.jpg",
          "trackCount": 312,
          "primaryGenreName": "Comedy"
        },
        {
          "collectionId": 42,
          "collectionName": "No Feed Show",
          "artistName": "Nobody",
          "trackCount": 5
        },
        {
          "collectionId": 77,
          "collectionName": "Small Art Show",
          "artistName": "Someone",
          "feedUrl": "https://example.com/small.xml",
          "artworkUrl100": "https://example.com/art100.jpg",
          "trackCount": 10
        }
      ]
    }
    """

  @Test
  func testTopChartURL() throws {
    let url = try #require(PodcastDirectory.topChartURL())
    #expect(
      url.absoluteString
        == "https://rss.applemarketingtools.com/api/v2/us/podcasts/top/25/podcasts.json")
  }

  @Test
  func testDecodesChartIDs() throws {
    let json = """
      {
        "feed": {
          "title": "Top Shows",
          "results": [
            { "id": "77", "name": "Small Art Show" },
            { "id": "1461705468", "name": "Baywatch Berlin" },
            { "id": "not-a-number", "name": "Broken Entry" }
          ]
        }
      }
      """
    let ids = try PodcastDirectory.chartIDs(from: Data(json.utf8))
    #expect(ids == [77, 1_461_705_468])
  }

  @Test
  func testLookupURLBatchesIDs() throws {
    let url = try #require(PodcastDirectory.lookupURL(ids: [77, 42]))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "itunes.apple.com")
    #expect(components.path == "/lookup")
    let items = try #require(components.queryItems)
    #expect(items.contains(URLQueryItem(name: "id", value: "77,42")))
    #expect(items.contains(URLQueryItem(name: "entity", value: "podcast")))
    #expect(PodcastDirectory.lookupURL(ids: []) == nil)
  }

  @Test
  func testOrderedRestoresChartOrderAndDropsUnresolvedIDs() throws {
    // The lookup response (searchJSON) yields ids 1461705468 and 77; the
    // chart wants 77 first and also names an id the lookup didn't resolve.
    let results = try PodcastDirectory.results(from: Data(Self.searchJSON.utf8))
    let ordered = PodcastDirectory.ordered(results, byChartIDs: [77, 999, 1_461_705_468])
    #expect(ordered.map(\.id) == [77, 1_461_705_468])
  }
}

// MARK: - File naming

struct PodcastFileNamingTests {
  @Test
  func testSanitizationEdgeCases() {
    #expect(
      (PodcastFileNaming.sanitizedComponent("AC/DC: Back in Black", fallback: "x"))
        == ("AC DC Back in Black"))
    #expect((PodcastFileNaming.sanitizedComponent("...hidden", fallback: "x")) == ("hidden"))
    #expect((PodcastFileNaming.sanitizedComponent("a\u{01}b\u{7F}c", fallback: "x")) == ("a b c"))
    #expect(
      (PodcastFileNaming.sanitizedComponent("  spaced \n\n  out \t words  ", fallback: "x"))
        == ("spaced out words"))
    #expect((PodcastFileNaming.sanitizedComponent("/:\\", fallback: "Untitled")) == ("Untitled"))
    #expect((PodcastFileNaming.sanitizedComponent("", fallback: "Untitled")) == ("Untitled"))
    let long = PodcastFileNaming.sanitizedComponent(
      String(repeating: "watch ", count: 60), fallback: "x")
    #expect(long.count <= PodcastFileNaming.maximumComponentLength)
    #expect(!long.hasSuffix(" "))
  }

  @Test
  func testEpisodeFileURL() {
    let library = URL(fileURLWithPath: "/library", isDirectory: true)
    let url = PodcastFileNaming.episodeFileURL(
      libraryFolder: library, showTitle: "Baywatch Berlin",
      episodeTitle: "Folge 1: Sp\u{00E4}ti", episodeID: "guid-1", fileExtension: "mp3")
    let fingerprint = PodcastFileNaming.fingerprint("guid-1")
    #expect(
      url.path == "/library/Podcasts/Baywatch Berlin/Folge 1 Sp\u{00E4}ti [\(fingerprint)].mp3")
  }

  @Test
  func testEpisodesWithIdenticalTitlesGetDistinctFiles() {
    let library = URL(fileURLWithPath: "/library", isDirectory: true)
    func url(_ episodeID: String) -> URL {
      PodcastFileNaming.episodeFileURL(
        libraryFolder: library, showTitle: "Show", episodeTitle: "Trailer",
        episodeID: episodeID, fileExtension: "mp3")
    }
    #expect(url("guid-a") != url("guid-b"))
    // Stable across calls so reconciliation finds existing downloads.
    #expect(url("guid-a") == url("guid-a"))
  }

  @Test
  func testDownloadExtension() throws {
    func ext(_ path: String, mimeType: String? = nil) throws -> String? {
      PodcastFileNaming.downloadExtension(
        forEnclosure: try #require(URL(string: "https://example.com/\(path)")),
        mimeType: mimeType)
    }
    #expect((try ext("a.mp3")) == ("mp3"))
    #expect((try ext("a.MP3")) == ("mp3"))
    #expect((try ext("a.m4a")) == ("m4a"))
    #expect((try ext("stream")) == ("mp3"))
    #expect((try ext("stream", mimeType: "")) == ("mp3"))
    #expect((try ext("stream", mimeType: "application/octet-stream")) == ("mp3"))
    #expect((try ext("stream", mimeType: "audio/mpeg")) == ("mp3"))
    #expect((try ext("stream", mimeType: "audio/mp4; charset=binary")) == ("m4a"))
    #expect((try ext("stream", mimeType: "audio/ogg")) == (nil))
    #expect((try ext("stream", mimeType: "text/html")) == (nil))
    #expect((try ext("a.ogg")) == (nil))
    #expect((try ext("a.mp4")) == (nil))
  }
}

// MARK: - Tagging

struct PodcastEpisodeTaggerTests {
  @Test
  func testStampsPodcastMetadataOnDownloadedMP3() throws {
    let scratch = TestScratch.directory(prefix: "NightdrivePodcastTagger")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    // The "downloaded" file arrives with unrelated tags already present.
    let fileURL = scratch.appendingPathComponent("episode.mp3")
    let mp3 = MP3Builder.build(
      tags: MP3Builder.Tags(
        title: "Server Title", artist: "Server Artist", album: "Server Album",
        genre: "Speech", trackNumber: 9, year: 2001),
      seconds: 1)
    try mp3.write(to: fileURL)

    let episode = PodcastEpisode(
      id: "guid-13",
      title: "Folge 13: Neuer Kram",
      showTitle: "Baywatch Berlin",
      enclosureURL: try #require(URL(string: "https://example.com/ep13.mp3")),
      publishedAt: PodcastFeedParser.date(fromRFC822: "Mon, 12 Jan 2026 06:00:00 +0000"),
      durationSeconds: 2710,
      episodeDescription: "Fresh stuff.",
      episodeNumber: 13,
      sizeBytes: nil)
    try PodcastEpisodeTagger.tag(
      fileURL: fileURL, episode: episode, feedAuthor: "Schmitt, Heufer-Umlauf & Lundt")

    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
    #expect((textFrame(frames, "TIT2")) == ("Folge 13: Neuer Kram"))
    #expect((textFrame(frames, "TPE1")) == ("Schmitt, Heufer-Umlauf & Lundt"))
    #expect((textFrame(frames, "TALB")) == ("Baywatch Berlin"))
    #expect((textFrame(frames, "TCON")) == ("Podcast"))
    #expect((textFrame(frames, "TYER")) == ("2026"))
    #expect((textFrame(frames, "TRCK")) == ("13"))
  }

  @Test
  func testFallsBackToShowTitleAsArtist() throws {
    let scratch = TestScratch.directory(prefix: "NightdrivePodcastTagger")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let fileURL = scratch.appendingPathComponent("episode.mp3")
    try MP3Builder.build(
      tags: MP3Builder.Tags(
        title: "", artist: "", album: "", genre: "", trackNumber: 0, year: 0),
      seconds: 1
    ).write(to: fileURL)

    let episode = PodcastEpisode(
      id: "e", title: "Episode", showTitle: "Baywatch Berlin",
      enclosureURL: try #require(URL(string: "https://example.com/e.mp3")))
    try PodcastEpisodeTagger.tag(fileURL: fileURL, episode: episode, feedAuthor: nil)

    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
    #expect((textFrame(frames, "TPE1")) == ("Baywatch Berlin"))
    #expect((textFrame(frames, "TCON")) == ("Podcast"))
  }

  @Test
  func testCommentTruncation() {
    #expect((PodcastEpisodeTagger.truncatedComment(nil)) == (""))
    #expect((PodcastEpisodeTagger.truncatedComment("short  note")) == ("short note"))
    let long = PodcastEpisodeTagger.truncatedComment(String(repeating: "words ", count: 100))
    #expect(long.count <= PodcastEpisodeTagger.maximumCommentLength)
    #expect(long.hasSuffix("\u{2026}"))
  }

  private func textFrame(_ frames: [MP3MetadataWriter.Frame], _ id: String) -> String? {
    guard let frame = frames.first(where: { $0.id == id }) else { return nil }
    let payload = frame.payload
    guard payload.first == 0x01 else { return nil }
    return String(data: payload.dropFirst(), encoding: .utf16)
  }
}

// MARK: - Store

/// Shared in-memory persistence double for the store and policy suites.
private final class InMemoryPersistence: AppDataPersistence, Sendable {
  private let stored = Mutex<Data?>(nil)
  var data: Data? {
    get { stored.withLock { $0 } }
    set { stored.withLock { $0 = newValue } }
  }
  func load() throws -> Data? { data }
  func save(_ data: Data) throws { self.data = data }
}

/// URLSession fixture that can deliberately omit Content-Length so tests
/// exercise the streaming ceiling rather than only the up-front header check.
private final class PodcastResponseProbe: @unchecked Sendable {
  private struct State {
    var active = 0
    var bytesSent = 0
    var wasStopped = false
    var maximumActive = 0
  }

  private let state = Mutex(State())
  var maximumActive: Int { state.withLock { $0.maximumActive } }

  func begin() {
    state.withLock {
      $0.active += 1
      $0.maximumActive = max($0.maximumActive, $0.active)
    }
  }

  func record(_ count: Int) {
    state.withLock { $0.bytesSent += count }
  }

  func finish(stopped: Bool = false) {
    state.withLock {
      $0.active = max(0, $0.active - 1)
      $0.wasStopped = $0.wasStopped || stopped
    }
  }

  var snapshot: (bytesSent: Int, wasStopped: Bool) {
    state.withLock { ($0.bytesSent, $0.wasStopped) }
  }
}

private struct PodcastUncheckedSendable<Value>: @unchecked Sendable {
  let value: Value
}

private final class PodcastResponseURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub: Sendable {
    let data: Data
    let headers: [String: String]
    let probe: PodcastResponseProbe
    let chunkSize: Int
    let chunkDelay: Duration

    init(
      data: Data, headers: [String: String], probe: PodcastResponseProbe,
      chunkSize: Int = 128, chunkDelay: Duration = .milliseconds(2)
    ) {
      precondition(chunkSize > 0)
      self.data = data
      self.headers = headers
      self.probe = probe
      self.chunkSize = chunkSize
      self.chunkDelay = chunkDelay
    }
  }

  private static let stubs = Mutex<[URL: Stub]>([:])
  private let stopped = Mutex(false)

  static func register(_ stub: Stub, for url: URL) {
    stubs.withLock { $0[url] = stub }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "podcast-response.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let stub = Self.stubs.withLock({ $0[url] }) else {
      client?.urlProtocol(
        self,
        didFailWithError: URLError(.resourceUnavailable))
      return
    }
    guard
      let response = HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: stub.headers)
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    stub.probe.begin()
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

    let loader = PodcastUncheckedSendable(value: self)
    Task.detached { [loader] in
      let loader = loader.value
      var offset = 0
      while offset < stub.data.count, !loader.stopped.withLock({ $0 }) {
        let end = min(offset + stub.chunkSize, stub.data.count)
        let chunk = stub.data.subdata(in: offset..<end)
        loader.client?.urlProtocol(loader, didLoad: chunk)
        stub.probe.record(chunk.count)
        offset = end
        if offset < stub.data.count {
          try? await Task.sleep(for: stub.chunkDelay)
        }
      }
      guard !loader.stopped.withLock({ $0 }) else { return }
      loader.client?.urlProtocolDidFinishLoading(loader)
      stub.probe.finish()
    }
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
    if let url = request.url, let stub = Self.stubs.withLock({ $0[url] }) {
      stub.probe.finish(stopped: true)
    }
  }
}

private final class PodcastURLProtocolStub: URLProtocol, @unchecked Sendable {
  private struct State {
    var responses: [URL: Data] = [:]
    var requests: [URL] = []
    var onRequest: (@Sendable (URL) -> Void)?
    var responseDelays: [URL: TimeInterval] = [:]
  }

  private static let state = Mutex(State())
  private let stopped = Mutex(false)

  static var requests: [URL] { state.withLock { $0.requests } }

  static func reset(
    responses: [URL: Data] = [:], onRequest: (@Sendable (URL) -> Void)? = nil,
    responseDelays: [URL: TimeInterval] = [:]
  ) {
    state.withLock {
      $0.responses = responses
      $0.requests = []
      $0.onRequest = onRequest
      $0.responseDelays = responseDelays
    }
  }

  static func clearRequests() {
    state.withLock { $0.requests = [] }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    let (data, onRequest, delay) = Self.state.withLock {
      state -> (Data?, (@Sendable (URL) -> Void)?, TimeInterval) in
      state.requests.append(url)
      return (state.responses[url], state.onRequest, state.responseDelays[url] ?? 0)
    }
    onRequest?(url)
    guard let data else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
      return
    }
    if delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.deliver(data: data, for: url)
      }
    } else {
      deliver(data: data, for: url)
    }
  }

  private func deliver(data: Data, for url: URL) {
    guard !stopped.withLock({ $0 }) else { return }
    let response = HTTPURLResponse(
      url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/octet-stream"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {
    stopped.withLock { $0 = true }
  }
}

@Suite(.serialized)
@MainActor
final class PodcastStoreTests {
  private let scratch: URL
  private let library: URL

  init() throws {
    scratch = TestScratch.directory(prefix: "NightdrivePodcastStore")
    library = scratch.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
  }

  deinit {
    let scratch = self.scratch
    try? FileManager.default.removeItem(at: scratch)
  }

  private func store(
    persistence: any AppDataPersistence,
    urlSession: URLSession = .shared,
    resourceLimits: PodcastResourceLimits = .standard
  ) -> PodcastStore {
    let store = PodcastStore(
      persistence: persistence, urlSession: urlSession, resourceLimits: resourceLimits)
    let library = self.library
    store.libraryFolderProvider = { library }
    return store
  }

  private func writeFeedFixture(episodeURL: URL? = nil) throws -> URL {
    var xml = PodcastFeedParserTests.feedXML
    if let episodeURL {
      xml = xml.replacingOccurrences(
        of: "https://example.com/ep13.mp3", with: episodeURL.absoluteString)
    }
    let feedURL = scratch.appendingPathComponent("feed.xml")
    try xml.write(to: feedURL, atomically: true, encoding: .utf8)
    return feedURL
  }

  private func writeSourceMP3(named name: String = "source.mp3") throws -> URL {
    let sourceURL = scratch.appendingPathComponent(name)
    try MP3Builder.build(
      tags: MP3Builder.Tags(
        title: "", artist: "", album: "", genre: "", trackNumber: 0, year: 0),
      seconds: 1
    ).write(to: sourceURL)
    return sourceURL
  }

  /// A single-episode feed fixture with controllable titles, author, and
  /// guid, for identity- and rename-focused tests.
  private func writeCustomFeed(
    named name: String, showTitle: String, author: String?,
    episodeTitle: String, guid: String, enclosure: URL,
    enclosureType: String? = "audio/mpeg"
  ) throws -> URL {
    let authorXML = author.map { "<itunes:author>\($0)</itunes:author>" } ?? ""
    let typeAttribute = enclosureType.map { " type=\"\($0)\"" } ?? ""
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>\(showTitle)</title>
          \(authorXML)
          <item>
            <title>\(episodeTitle)</title>
            <guid>\(guid)</guid>
            <pubDate>Mon, 12 Jan 2026 06:00:00 +0000</pubDate>
            <enclosure url="\(enclosure.absoluteString)" length="1000"\(typeAttribute)/>
          </item>
        </channel>
      </rss>
      """
    let feedURL = scratch.appendingPathComponent(name)
    try xml.write(to: feedURL, atomically: true, encoding: .utf8)
    return feedURL
  }

  private func makeOtherLibrary() throws -> URL {
    let other = scratch.appendingPathComponent("OtherLibrary", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    return other
  }

  private func artistTag(of fileURL: URL) throws -> String? {
    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: fileURL))
    guard let frame = frames.first(where: { $0.id == "TPE1" }), frame.payload.first == 0x01
    else { return nil }
    return String(data: frame.payload.dropFirst(), encoding: .utf16)
  }

  private func responseSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PodcastResponseURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func waitForStop(_ probe: PodcastResponseProbe) async throws
    -> (bytesSent: Int, wasStopped: Bool)
  {
    for _ in 0..<100 {
      let snapshot = probe.snapshot
      if snapshot.wasStopped { return snapshot }
      try await Task.sleep(for: .milliseconds(10))
    }
    return probe.snapshot
  }

  private func assertStreamingLimitCancels(
    fileExtension: String, contentType: String,
    limits: PodcastResourceLimits,
    operation: (PodcastStore, URL) async throws -> Void
  ) async throws {
    let responseData = Data(repeating: 0x41, count: 64 * 1_024)
    let probe = PodcastResponseProbe()
    let url = try #require(
      URL(string: "https://podcast-response.test/\(UUID().uuidString).\(fileExtension)"))
    PodcastResponseURLProtocol.register(
      .init(data: responseData, headers: ["Content-Type": contentType], probe: probe),
      for: url)
    let session = responseSession()
    defer { session.invalidateAndCancel() }
    let store = store(
      persistence: InMemoryPersistence(), urlSession: session, resourceLimits: limits)

    try await operation(store, url)

    #expect(store.lastError?.localizedCaseInsensitiveContains("limit") == true)
    let stopped = try await waitForStop(probe)
    #expect(stopped.wasStopped)
    #expect(stopped.bytesSent < responseData.count)
  }

  @Test
  func testSubscriptionPersistenceRoundTrip() async throws {
    let persistence = InMemoryPersistence()
    let feedURL = try writeFeedFixture()
    let first = store(persistence: persistence)

    await first.subscribe(
      PodcastDirectoryResult(
        id: 1, title: "Baywatch Berlin", author: "Klaas", feedURL: feedURL,
        artworkURL: nil, episodeCount: 3, genre: "Comedy"))
    #expect((first.subscriptions.count) == (1))
    #expect((first.feeds[feedURL]?.episodes.count) == (3))
    #expect((first.lastError) == (nil))

    // Subscribing again is a no-op for the subscription list.
    await first.subscribe(
      PodcastDirectoryResult(
        id: 1, title: "Baywatch Berlin", author: "Klaas", feedURL: feedURL,
        artworkURL: nil, episodeCount: 3, genre: "Comedy"))
    #expect((first.subscriptions.count) == (1))

    let second = store(persistence: persistence)
    #expect((second.subscriptions.count) == (1))
    #expect((second.subscriptions[0].title) == ("Baywatch Berlin"))
    #expect((second.subscriptions[0].author) == ("Klaas"))
    #expect((second.subscriptions[0].feedURL) == (feedURL))

    second.unsubscribe(second.subscriptions[0])
    #expect(second.subscriptions.isEmpty)
    let third = store(persistence: persistence)
    #expect(third.subscriptions.isEmpty)
  }

  @Test
  func testUnsubscribeKeepsLoadedFeedBrowsable() async throws {
    let feedURL = try writeFeedFixture()
    let store = store(persistence: InMemoryPersistence())
    await store.subscribe(feedURL: feedURL)
    let subscription = try #require(store.subscriptions.first)

    store.unsubscribe(subscription)

    // The show stays browsable like any other unsubscribed show.
    #expect(store.feeds[feedURL]?.episodes.count == 3)
  }

  @Test
  func testSubscribeFromRawFeedURLUsesFeedTitle() async throws {
    let feedURL = try writeFeedFixture()
    let store = store(persistence: InMemoryPersistence())

    await store.subscribe(feedURL: feedURL)

    #expect((store.subscriptions.count) == (1))
    #expect((store.subscriptions[0].title) == ("Baywatch Berlin"))
    #expect((store.subscriptions[0].author) == ("Schmitt, Heufer-Umlauf & Lundt"))
  }

  @Test
  func testSubscriptionsSortByTitle() async throws {
    let store = store(persistence: InMemoryPersistence())
    let otherFeed = try writeFeedFixture()

    await store.subscribe(
      PodcastDirectoryResult(
        id: 2, title: "Zebra Talk", author: "Z", feedURL: otherFeed,
        artworkURL: nil, episodeCount: 0, genre: nil))
    await store.subscribe(
      PodcastDirectoryResult(
        id: 3, title: "Aardvark Hour", author: "A",
        feedURL: try #require(URL(string: "file:///nonexistent/other.xml")),
        artworkURL: nil, episodeCount: 0, genre: nil))

    #expect((store.subscriptions.map(\.title)) == (["Aardvark Hour", "Zebra Talk"]))
  }

  @Test
  func testPreloadWarmsSubscriptionsAndPopularDirectoryOnce() async throws {
    let subscribedFeed = try #require(URL(string: "https://publisher.example/subscribed.xml"))
    let popularFeed1 = try #require(URL(string: "https://publisher.example/popular-1.xml"))
    let popularFeed2 = try #require(URL(string: "https://publisher.example/popular-2.xml"))
    let chartURL = try #require(PodcastDirectory.topChartURL())
    let lookupURL = try #require(PodcastDirectory.lookupURL(ids: [101, 202]))
    var responses = try Self.stubDirectory([
      (101, "Popular One", popularFeed1, 4),
      (202, "Popular Two", popularFeed2, 7),
    ])
    responses[subscribedFeed] = Self.stubFeed(title: "Subscribed", guid: "subscribed-episode")
    responses[popularFeed1] = Self.stubFeed(title: "Popular One", guid: "popular-episode-1")
    responses[popularFeed2] = Self.stubFeed(title: "Popular Two", guid: "popular-episode-2")
    PodcastURLProtocolStub.reset(responses: responses)
    defer { PodcastURLProtocolStub.reset() }

    let persistence = InMemoryPersistence()
    let seed = PodcastStore(persistence: persistence, urlSession: Self.stubSession)
    await seed.subscribe(
      PodcastDirectoryResult(
        id: 1, title: "Subscribed", author: "Host", feedURL: subscribedFeed,
        artworkURL: nil, episodeCount: 1, genre: nil))

    PodcastURLProtocolStub.clearRequests()
    let preloaded = PodcastStore(persistence: persistence, urlSession: Self.stubSession)
    await preloaded.preloadEpisodes(while: { true }, refreshSubscriptionsWhile: { true })

    #expect(preloaded.popular.map(\.title) == ["Popular One", "Popular Two"])
    #expect(preloaded.feeds[subscribedFeed]?.episodes.count == 1)
    #expect(preloaded.feeds[popularFeed1] == nil)
    #expect(preloaded.feeds[popularFeed2] == nil)
    #expect(
      Set(PodcastURLProtocolStub.requests)
        == Set([chartURL, lookupURL, subscribedFeed]))

    PodcastURLProtocolStub.clearRequests()
    await preloaded.preloadEpisodes(while: { true }, refreshSubscriptionsWhile: { true })
    #expect(PodcastURLProtocolStub.requests.isEmpty)
  }

  @Test
  func testPreloadStopsStartingSubscribedFeedsWhenAutoRefreshTurnsOff() async throws {
    let feedURLs = try (1...7).map { index in
      try #require(URL(string: "https://publisher.example/subscribed-\(index).xml"))
    }
    var responses = [
      try #require(PodcastDirectory.topChartURL()): Data(#"{"feed":{"results":[]}}"#.utf8)
    ]
    for (index, feedURL) in feedURLs.enumerated() {
      responses[feedURL] = Self.stubFeed(title: "Subscribed \(index)", guid: "episode-\(index)")
    }
    PodcastURLProtocolStub.reset(responses: responses)
    defer { PodcastURLProtocolStub.reset() }

    let persistence = InMemoryPersistence()
    let seed = PodcastStore(persistence: persistence, urlSession: Self.stubSession)
    for (index, feedURL) in feedURLs.enumerated() {
      await seed.subscribe(
        PodcastDirectoryResult(
          id: index, title: "Subscribed \(index)", author: "Host", feedURL: feedURL,
          artworkURL: nil, episodeCount: 1, genre: nil))
    }

    let autoRefreshEnabled = Mutex(true)
    let feedURLSet = Set(feedURLs)
    PodcastURLProtocolStub.reset(
      responses: responses,
      onRequest: { url in
        if feedURLSet.contains(url) {
          autoRefreshEnabled.withLock { $0 = false }
        }
      })
    let preloaded = PodcastStore(persistence: persistence, urlSession: Self.stubSession)
    await preloaded.preloadEpisodes(
      while: { true },
      refreshSubscriptionsWhile: { autoRefreshEnabled.withLock { $0 } })

    let subscribedRequests = PodcastURLProtocolStub.requests.filter(feedURLSet.contains)
    #expect(subscribedRequests.count <= 3)
    #expect(feedURLs.dropFirst(3).allSatisfy { !subscribedRequests.contains($0) })
    #expect(feedURLs.dropFirst(3).allSatisfy { preloaded.feeds[$0] == nil })
  }

  @Test
  func testInteractiveLoadSharesAFeedRequestWithPreload() async throws {
    let feedURL = try #require(URL(string: "https://publisher.example/shared.xml"))
    var responses = try Self.stubDirectory([(101, "Shared Show", feedURL, 1)])
    responses[feedURL] = Self.stubFeed(title: "Shared Show", guid: "shared-episode")
    defer { PodcastURLProtocolStub.reset() }
    let persistence = InMemoryPersistence()
    PodcastURLProtocolStub.reset(responses: responses)
    let seed = PodcastStore(persistence: persistence, urlSession: Self.stubSession)
    await seed.subscribe(
      PodcastDirectoryResult(
        id: 101, title: "Shared Show", author: "Host", feedURL: feedURL,
        artworkURL: nil, episodeCount: 1, genre: nil))

    PodcastURLProtocolStub.reset(responses: responses, responseDelays: [feedURL: 0.2])
    let store = PodcastStore(persistence: persistence, urlSession: Self.stubSession)

    let preload = Task {
      await store.preloadEpisodes(while: { true }, refreshSubscriptionsWhile: { true })
    }
    #expect(await waitUntil { PodcastURLProtocolStub.requests.contains(feedURL) })
    let interactive = Task { await store.loadFeed(url: feedURL) }
    await preload.value
    let loaded = await interactive.value

    #expect(loaded?.episodes.count == 1)
    #expect(PodcastURLProtocolStub.requests.filter { $0 == feedURL }.count == 1)
  }

  private static func stubFeed(title: String, guid: String) -> Data {
    Data(
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>\(title)</title><item>
        <title>Episode</title><guid>\(guid)</guid>
        <enclosure url="https://cdn.example/\(guid).mp3" type="audio/mpeg" length="1000"/>
      </item></channel></rss>
      """.utf8)
  }

  private static func stubDirectory(
    _ shows: [(id: Int, title: String, feedURL: URL, count: Int)]
  ) throws -> [URL: Data] {
    let ids = shows.map(\.id)
    let chart = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
    let results = shows.reversed().map {
      #"{"collectionId":\#($0.id),"collectionName":"\#($0.title)","artistName":"Host","feedUrl":"\#($0.feedURL.absoluteString)","trackCount":\#($0.count)}"#
    }.joined(separator: ",")
    return [
      try #require(PodcastDirectory.topChartURL()): Data(
        #"{"feed":{"results":[\#(chart)]}}"#.utf8),
      try #require(PodcastDirectory.lookupURL(ids: ids)): Data(
        #"{"results":[\#(results)]}"#.utf8),
    ]
  }

  private static let stubSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PodcastURLProtocolStub.self]
    return URLSession(configuration: configuration)
  }()

  @Test
  func testDownloadWritesTaggedFileIntoLibrary() async throws {
    let sourceURL = try writeSourceMP3()
    let feedURL = try writeFeedFixture(episodeURL: sourceURL)
    let store = store(persistence: InMemoryPersistence())

    let feed = try #require(await store.loadFeed(url: feedURL))
    let episode = try #require(feed.episodes.first { $0.id.hasSuffix("#guid-13") })

    await store.download(episode)

    let expected = library.appendingPathComponent(
      "Podcasts/Baywatch Berlin/Folge 13 Neuer Kram [\(PodcastFileNaming.fingerprint(episode.id))].mp3"
    )
    #expect((store.episodeStates[episode.id]) == (.downloaded(fileURL: expected)))
    #expect((store.localFileURL(for: episode)) == (expected))
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect((store.lastError) == (nil))

    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: expected))
    func text(_ id: String) -> String? {
      guard let frame = frames.first(where: { $0.id == id }), frame.payload.first == 0x01
      else { return nil }
      return String(data: frame.payload.dropFirst(), encoding: .utf16)
    }
    #expect((text("TIT2")) == ("Folge 13: Neuer Kram"))
    #expect((text("TALB")) == ("Baywatch Berlin"))
    #expect((text("TCON")) == ("Podcast"))
    #expect((text("TPE1")) == ("Schmitt, Heufer-Umlauf & Lundt"))
    #expect((text("TYER")) == ("2026"))

    // No stray partial files remain next to the episode.
    let contents = try FileManager.default.contentsOfDirectory(
      atPath: expected.deletingLastPathComponent().path)
    #expect((contents) == ([expected.lastPathComponent]))

    store.deleteDownload(episode)
    #expect((store.episodeStates[episode.id]) == (.notDownloaded))
    #expect(!FileManager.default.fileExists(atPath: expected.path))
    #expect((store.localFileURL(for: episode)) == (nil))
  }

  @Test
  func testExtensionlessM4ADownloadUsesDeclaredMIMEType() async throws {
    let sourceM4A = scratch.appendingPathComponent("source-m4a.m4a")
    try writeAudioFixture(to: sourceM4A, formatID: kAudioFormatMPEG4AAC)
    let extensionless = scratch.appendingPathComponent("m4a-stream")
    try Data(contentsOf: sourceM4A).write(to: extensionless)
    let feedURL = try writeCustomFeed(
      named: "m4a-feed.xml", showTitle: "M4A Show", author: "Host",
      episodeTitle: "M4A Episode", guid: "m4a-1", enclosure: extensionless,
      enclosureType: "audio/mp4")
    let store = store(persistence: InMemoryPersistence())
    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)

    await store.download(episode)

    let downloaded = try #require(store.localFileURL(for: episode))
    #expect(downloaded.pathExtension == "m4a")
    #expect(FileManager.default.fileExists(atPath: downloaded.path))
  }

  @Test
  func testExtensionlessDownloadWithoutMIMEFallsBackToMP3() async throws {
    let source = try writeSourceMP3(named: "mp3-stream")
    let feedURL = try writeCustomFeed(
      named: "mp3-stream-feed.xml", showTitle: "MP3 Show", author: "Host",
      episodeTitle: "MP3 Episode", guid: "mp3-stream-1", enclosure: source,
      enclosureType: nil)
    let store = store(persistence: InMemoryPersistence())
    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)

    await store.download(episode)

    let downloaded = try #require(store.localFileURL(for: episode))
    #expect(downloaded.pathExtension == "mp3")
    #expect(FileManager.default.fileExists(atPath: downloaded.path))
  }

  @Test
  func testDownloadRejectsContentThatIsNotPlayableAudio() async throws {
    let source = scratch.appendingPathComponent("html-response")
    try Data("<html>not audio</html>".utf8).write(to: source)
    let feedURL = try writeCustomFeed(
      named: "bad-audio-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "bad-1", enclosure: source)
    let store = store(persistence: InMemoryPersistence())
    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)

    await store.download(episode)

    guard case .failed(let message) = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    #expect(message.localizedCaseInsensitiveContains("audio"))
    #expect(store.localFileURL(for: episode) == nil)
  }

  @Test
  func testFeedResponseLimitRejectsOversizedFeed() async throws {
    try await assertStreamingLimitCancels(
      fileExtension: "xml", contentType: "application/rss+xml",
      limits: PodcastResourceLimits(maximumFeedBytes: 512)
    ) { store, url in
      #expect(await store.loadFeed(url: url) == nil)
    }
  }

  @Test
  func testFeedLoadsShareTheStoreWideConcurrencyLimit() async throws {
    let probe = PodcastResponseProbe()
    let responseData = Self.stubFeed(title: "Show", guid: "episode")
    let urls = try (0..<5).map { index in
      try #require(
        URL(string: "https://podcast-response.test/concurrent-feed-\(index)-\(UUID()).xml"))
    }
    for url in urls {
      PodcastResponseURLProtocol.register(
        .init(
          data: responseData, headers: ["Content-Type": "application/rss+xml"],
          probe: probe, chunkSize: 16, chunkDelay: .milliseconds(5)),
        for: url)
    }
    let session = responseSession()
    defer { session.invalidateAndCancel() }
    let store = store(
      persistence: InMemoryPersistence(), urlSession: session,
      resourceLimits: PodcastResourceLimits(maximumConcurrentFeedLoads: 2))

    let loadedCount = await withTaskGroup(of: PodcastFeed?.self) { group in
      for url in urls {
        group.addTask { await store.loadFeed(url: url) }
      }
      var count = 0
      for await feed in group where feed != nil { count += 1 }
      return count
    }

    #expect(loadedCount == urls.count)
    #expect(probe.maximumActive == 2)
  }

  @Test
  func testStandardFeedLimitAllowsLargeEstablishedCatalogs() throws {
    let url = try #require(URL(string: "https://example.com/large-feed.xml"))
    // Established catalogs in Apple's current chart exceed 12 MiB. Leave
    // enough room for those feeds to keep growing without removing the cap.
    let catalogBytes: Int64 = 16 * 1_024 * 1_024
    let response = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Length": "\(catalogBytes)"]))

    #expect(
      try PodcastStore.validatedContentLength(
        in: response, maximumBytes: PodcastResourceLimits.standard.maximumFeedBytes)
        == catalogBytes)
  }

  @Test
  func testStandardResourceLimitsBoundWorstCaseWork() {
    let limits = PodcastResourceLimits.standard
    #expect(limits.maximumFeedBytes == 32 * 1_024 * 1_024)
    #expect(limits.maximumDirectoryResponseBytes == 5 * 1_024 * 1_024)
    #expect(limits.maximumEnclosureBytes == 2 * 1_024 * 1_024 * 1_024)
    #expect(limits.minimumFreeDiskBytes == 1 * 1_024 * 1_024 * 1_024)
    #expect(limits.maximumConcurrentFeedLoads == 3)
    #expect(
      limits.maximumFeedBytes * Int64(limits.maximumConcurrentFeedLoads)
        == 96 * 1_024 * 1_024)
  }

  @Test
  func testContentLengthValidationRejectsMalformedAndOversizedHeaders() throws {
    let url = try #require(URL(string: "https://example.com/feed.xml"))
    let malformed = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Length": "12kb"]))
    let oversized = try #require(
      HTTPURLResponse(
        url: url, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Length": "65"]))

    #expect(throws: PodcastFeedError.self) {
      try PodcastStore.validatedContentLength(in: malformed, maximumBytes: 64)
    }
    #expect(throws: PodcastFeedError.self) {
      try PodcastStore.validatedContentLength(in: oversized, maximumBytes: 64)
    }
  }

  @Test
  func testEnclosureResponseLimitLeavesNoPartialFile() async throws {
    try await assertStreamingLimitCancels(
      fileExtension: "mp3", contentType: "audio/mpeg",
      limits: PodcastResourceLimits(
        maximumEnclosureBytes: 512, minimumFreeDiskBytes: 0)
    ) { store, url in
      let episode = PodcastEpisode(
        id: "oversized-1", title: "Oversized", showTitle: "Show", enclosureURL: url)

      await store.download(episode)

      guard case .failed = store.episodeStates[episode.id] else {
        Issue.record("expected a failed state")
        return
      }
      let showFolder = self.library.appendingPathComponent("Podcasts/Show")
      let contents =
        (try? FileManager.default.contentsOfDirectory(atPath: showFolder.path)) ?? []
      #expect(contents.isEmpty)
    }
  }

  @Test
  func testDownloadPreservesConfiguredDiskHeadroom() async throws {
    let source = try writeSourceMP3(named: "disk-headroom-source.mp3")
    let store = store(
      persistence: InMemoryPersistence(),
      resourceLimits: PodcastResourceLimits(
        maximumEnclosureBytes: 1 * 1_024 * 1_024,
        minimumFreeDiskBytes: Int64.max))
    let episode = PodcastEpisode(
      id: "disk-headroom-1", title: "Headroom", showTitle: "Show",
      enclosureURL: source)

    await store.download(episode)

    guard case .failed(let message) = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    #expect(message.localizedCaseInsensitiveContains("headroom"))
    #expect(store.localFileURL(for: episode) == nil)
  }

  @Test
  func testConcurrentDownloadsDoNotShareTheSameDiskBudget() async throws {
    let source = try writeSourceMP3(named: "concurrent-source.mp3")
    let sourceData = try Data(contentsOf: source)
    let concurrencyProbe = PodcastResponseProbe()
    let firstURL = try #require(
      URL(string: "https://podcast-response.test/\(UUID().uuidString)-1.mp3"))
    let secondURL = try #require(
      URL(string: "https://podcast-response.test/\(UUID().uuidString)-2.mp3"))
    for url in [firstURL, secondURL] {
      PodcastResponseURLProtocol.register(
        .init(
          data: sourceData, headers: ["Content-Type": "audio/mpeg"],
          probe: concurrencyProbe, chunkSize: 256, chunkDelay: .milliseconds(1)),
        for: url)
    }
    let session = responseSession()
    defer { session.invalidateAndCancel() }
    let store = store(
      persistence: InMemoryPersistence(), urlSession: session,
      resourceLimits: PodcastResourceLimits(minimumFreeDiskBytes: 0))
    let first = PodcastEpisode(
      id: "concurrent-1", title: "First", showTitle: "Show", enclosureURL: firstURL)
    let second = PodcastEpisode(
      id: "concurrent-2", title: "Second", showTitle: "Show", enclosureURL: secondURL)

    async let firstDownload: Void = store.download(first)
    async let secondDownload: Void = store.download(second)
    _ = await (firstDownload, secondDownload)

    #expect(concurrencyProbe.maximumActive == 1)
    #expect(store.localFileURL(for: first) != nil)
    #expect(store.localFileURL(for: second) != nil)
  }

  @Test
  func testLoadFeedReconcilesExistingDownloads() async throws {
    let feedURL = try writeFeedFixture()
    let store = store(persistence: InMemoryPersistence())

    let episodeID = PodcastFeedParser.episodeID(feedURL: feedURL, itemIdentifier: "guid-13")
    let expected = library.appendingPathComponent(
      "Podcasts/Baywatch Berlin/Folge 13 Neuer Kram [\(PodcastFileNaming.fingerprint(episodeID))].mp3"
    )
    try FileManager.default.createDirectory(
      at: expected.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: expected)

    let feed = try #require(await store.loadFeed(url: feedURL))
    let downloaded = try #require(feed.episodes.first { $0.id.hasSuffix("#guid-13") })
    let missing = try #require(feed.episodes.first { $0.id.hasSuffix("#guid-12") })

    #expect((store.episodeStates[downloaded.id]) == (.downloaded(fileURL: expected)))
    #expect((store.localFileURL(for: downloaded)) == (expected))
    #expect((store.localFileURL(for: missing)) == (nil))
  }

  @Test
  func testSameGUIDInDifferentFeedsKeepsDownloadsIndependent() async throws {
    let feedA = try writeCustomFeed(
      named: "feed-a.xml", showTitle: "Show A", author: "Author A",
      episodeTitle: "Pilot", guid: "1",
      enclosure: try writeSourceMP3(named: "source-a.mp3"))
    let feedB = try writeCustomFeed(
      named: "feed-b.xml", showTitle: "Show B", author: "Author B",
      episodeTitle: "Pilot", guid: "1",
      enclosure: try writeSourceMP3(named: "source-b.mp3"))
    let store = store(persistence: InMemoryPersistence())

    let episodeA = try #require(await store.loadFeed(url: feedA)?.episodes.first)
    let episodeB = try #require(await store.loadFeed(url: feedB)?.episodes.first)
    #expect(episodeA.id != episodeB.id)

    // Downloading one show's episode does not mark the other show's
    // same-guid episode as downloaded.
    await store.download(episodeA)
    #expect(store.localFileURL(for: episodeA) != nil)
    #expect(store.localFileURL(for: episodeB) == nil)
    #expect((store.episodeStates[episodeB.id] ?? .notDownloaded) == .notDownloaded)

    await store.download(episodeB)
    let fileA = try #require(store.localFileURL(for: episodeA))
    let fileB = try #require(store.localFileURL(for: episodeB))
    #expect(fileA != fileB)

    // Each file is attributed to its own feed's author.
    #expect(try artistTag(of: fileA) == "Author A")
    #expect(try artistTag(of: fileB) == "Author B")

    // Removing one show's episode leaves the other show's file alone.
    store.deleteDownload(episodeA)
    #expect(!FileManager.default.fileExists(atPath: fileA.path))
    #expect(FileManager.default.fileExists(atPath: fileB.path))
    #expect(store.episodeStates[episodeB.id] == .downloaded(fileURL: fileB))
  }

  @Test
  func testDownloadsSurvivePublisherRenamingShowAndEpisode() async throws {
    let persistence = InMemoryPersistence()
    let source = try writeSourceMP3(named: "source-rename.mp3")
    let feedURL = try writeCustomFeed(
      named: "rename-feed.xml", showTitle: "Original Show", author: "Author",
      episodeTitle: "Original Title", guid: "ep-1", enclosure: source)
    let first = store(persistence: persistence)
    await first.subscribe(feedURL: feedURL)
    first.setAutoDownloadCount(1, for: try #require(first.subscriptions.first))
    let original = try #require(first.feeds[feedURL]?.episodes.first)
    await first.download(original)
    let recorded = try #require(first.localFileURL(for: original))
    #expect(recorded.path.contains("Original Show"))

    // The publisher retitles both the show and the episode; the guid stays.
    _ = try writeCustomFeed(
      named: "rename-feed.xml", showTitle: "Renamed Show", author: "Author",
      episodeTitle: "Corrected Title", guid: "ep-1", enclosure: source)

    let reloaded = store(persistence: persistence)
    await reloaded.performMaintenance()

    let episode = try #require(reloaded.feeds[feedURL]?.episodes.first)
    #expect(episode.id == original.id)
    // The download stays at its recorded path instead of being orphaned.
    #expect(reloaded.episodeStates[episode.id] == .downloaded(fileURL: recorded))
    #expect(reloaded.localFileURL(for: episode) == recorded)
    #expect(FileManager.default.fileExists(atPath: recorded.path))
    // Automation did not re-download to the retitled path.
    let retitled = PodcastFileNaming.episodeFileURL(
      libraryFolder: library, showTitle: "Renamed Show", episodeTitle: "Corrected Title",
      episodeID: episode.id, fileExtension: "mp3")
    #expect(!FileManager.default.fileExists(atPath: retitled.path))
  }

  @Test
  func testLibrarySwitchMidDownloadPublishesNothing() async throws {
    let persistence = InMemoryPersistence()
    let source = try writeSourceMP3(named: "source-switch.mp3")
    let otherLibrary = try makeOtherLibrary()
    let store = PodcastStore(persistence: persistence)
    // The first read (capturing the download destination) sees the original
    // library; every later read sees the switched-to library.
    var providerCalls = 0
    let library = self.library
    store.libraryFolderProvider = {
      providerCalls += 1
      return providerCalls == 1 ? library : otherLibrary
    }
    let episode = PodcastEpisode(
      id: "\(source.absoluteString)#switch-1", title: "Episode", showTitle: "Show",
      enclosureURL: source)

    await store.download(episode)

    #expect(providerCalls >= 2)
    #expect(store.episodeStates[episode.id] == .notDownloaded)
    #expect(store.localFileURL(for: episode) == nil)
    // The file published into the old library was cleaned up, and nothing
    // landed in the new library.
    let staleDestination = PodcastFileNaming.episodeFileURL(
      libraryFolder: library, showTitle: "Show", episodeTitle: "Episode",
      episodeID: episode.id, fileExtension: "mp3")
    #expect(!FileManager.default.fileExists(atPath: staleDestination.path))
    let showFolderContents =
      (try? FileManager.default.contentsOfDirectory(
        atPath: staleDestination.deletingLastPathComponent().path)) ?? []
    #expect(showFolderContents.isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: otherLibrary.appendingPathComponent("Podcasts").path))
    // No download mapping was persisted.
    #expect(persistence.data == nil)
  }

  @Test
  func testDeleteDownloadLeavesFilesOutsideCurrentLibraryAlone() async throws {
    let feedURL = try writeCustomFeed(
      named: "delete-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "d-1",
      enclosure: try writeSourceMP3(named: "source-delete.mp3"))
    let otherLibrary = try makeOtherLibrary()
    let store = PodcastStore(persistence: InMemoryPersistence())
    var currentLibrary = library
    store.libraryFolderProvider = { currentLibrary }

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    await store.download(episode)
    let downloadedFile = try #require(store.localFileURL(for: episode))

    // The user switches libraries: the old file is no longer reachable and
    // Remove must not delete it.
    currentLibrary = otherLibrary
    #expect(store.localFileURL(for: episode) == nil)
    store.deleteDownload(episode)

    #expect(FileManager.default.fileExists(atPath: downloadedFile.path))
    #expect(store.episodeStates[episode.id] == .notDownloaded)
  }

  @Test
  func testReconcileDropsDownloadedStateFromAnotherLibrary() async throws {
    let feedURL = try writeCustomFeed(
      named: "scope-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "s-1",
      enclosure: try writeSourceMP3(named: "source-scope.mp3"))
    let otherLibrary = try makeOtherLibrary()
    let store = PodcastStore(persistence: InMemoryPersistence())
    var currentLibrary = library
    store.libraryFolderProvider = { currentLibrary }

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    await store.download(episode)
    let downloadedFile = try #require(store.localFileURL(for: episode))

    currentLibrary = otherLibrary
    _ = await store.loadFeed(url: feedURL)

    #expect(store.episodeStates[episode.id] == .notDownloaded)
    #expect(store.localFileURL(for: episode) == nil)
    // The old library's file is untouched.
    #expect(FileManager.default.fileExists(atPath: downloadedFile.path))
  }

  @Test
  func testDownloadMappingsAreKeptPerLibrary() async throws {
    let feedURL = try writeCustomFeed(
      named: "perlib-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "p-1",
      enclosure: try writeSourceMP3(named: "source-perlib.mp3"))
    let otherLibrary = try makeOtherLibrary()
    let store = PodcastStore(persistence: InMemoryPersistence())
    var currentLibrary = library
    store.libraryFolderProvider = { currentLibrary }

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    await store.download(episode)
    let downloadedFile = try #require(store.localFileURL(for: episode))

    // Switching to library B resets states; deleting there must not touch
    // library A's file or forget A's persisted mapping.
    currentLibrary = otherLibrary
    store.libraryFolderDidChange()
    #expect(store.episodeStates[episode.id] == .notDownloaded)
    store.deleteDownload(episode)
    #expect(FileManager.default.fileExists(atPath: downloadedFile.path))

    // Back in library A the mapping still resolves the download.
    currentLibrary = library
    store.libraryFolderDidChange()
    #expect(store.episodeStates[episode.id] == .downloaded(fileURL: downloadedFile))
    #expect(store.localFileURL(for: episode) == downloadedFile)
  }

  @Test
  func testDownloadRecordTravelsWithAMovedLibrary() async throws {
    let feedURL = try writeCustomFeed(
      named: "moved-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "m-1",
      enclosure: try writeSourceMP3(named: "source-moved.mp3"))
    let store = PodcastStore(persistence: InMemoryPersistence())
    var currentLibrary = library
    store.libraryFolderProvider = { currentLibrary }

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    await store.download(episode)
    let originalFile = try #require(store.localFileURL(for: episode))

    // The user moves/renames the whole library folder: the sidecar travels
    // with it, so the download record survives the location change.
    let movedLibrary = scratch.appendingPathComponent("Moved Library", isDirectory: true)
    try FileManager.default.moveItem(at: library, to: movedLibrary)
    currentLibrary = movedLibrary
    store.libraryFolderDidChange()

    let movedFile = movedLibrary.appendingPathComponent(
      originalFile.path.replacingOccurrences(of: library.path + "/", with: ""),
      isDirectory: false)
    #expect(store.episodeStates[episode.id] == .downloaded(fileURL: movedFile))
    #expect(store.localFileURL(for: episode) == movedFile)
  }

  @Test
  func testValidJSONMappingCannotClaimOrDeleteAnUnrelatedSong() async throws {
    let feedURL = try writeCustomFeed(
      named: "unsafe-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "unsafe-1",
      enclosure: try writeSourceMP3(named: "source-unsafe.mp3"))
    let episodeID = PodcastFeedParser.episodeID(
      feedURL: feedURL, itemIdentifier: "unsafe-1")
    let unrelated = library.appendingPathComponent("Music/Favorite.mp3")
    try FileManager.default.createDirectory(
      at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: writeSourceMP3(named: "unrelated-source.mp3"), to: unrelated)
    let sidecar = PodcastDownloadsFile.url(for: library)
    let unsafeRecord = try JSONEncoder().encode([episodeID: "Music/Favorite.mp3"])
    try unsafeRecord.write(to: sidecar)
    let store = store(persistence: InMemoryPersistence())

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    #expect(store.localFileURL(for: episode) == nil)
    #expect(throws: PodcastFeedError.self) {
      try store.ensureDownloadsPersistenceWritable()
    }
    store.deleteDownload(episode)

    #expect(FileManager.default.fileExists(atPath: unrelated.path))
    #expect(try Data(contentsOf: sidecar) == unsafeRecord)
  }

  @Test
  func testDamagedDownloadsSidecarBlocksDownloadsAndIsNeverOverwritten() async throws {
    let feedURL = try writeCustomFeed(
      named: "damaged-feed.xml", showTitle: "Show", author: nil,
      episodeTitle: "Episode", guid: "dmg-1",
      enclosure: try writeSourceMP3(named: "source-damaged.mp3"))
    let store = PodcastStore(persistence: InMemoryPersistence())
    let library = self.library
    store.libraryFolderProvider = { library }

    let sidecar = PodcastDownloadsFile.url(for: library)
    let garbage = Data("not json {".utf8)
    try garbage.write(to: sidecar)

    let episode = try #require(await store.loadFeed(url: feedURL)?.episodes.first)
    await store.download(episode)

    // The download refuses rather than risking a rewrite of the record.
    guard case .failed(let message) = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    #expect(message.contains(sidecar.path))
    #expect(store.lastError == message)
    // The damaged sidecar is byte-identical — nothing overwrote it.
    #expect(try Data(contentsOf: sidecar) == garbage)
  }

  @Test
  func testDownloadRefusesUnsupportedEnclosureFormat() async throws {
    let store = store(persistence: InMemoryPersistence())
    let episode = PodcastEpisode(
      id: "ogg-1", title: "Ogg Episode", showTitle: "Baywatch Berlin",
      enclosureURL: try #require(URL(string: "https://example.com/episode.ogg")))

    await store.download(episode)

    guard case .failed(let message) = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    #expect(message.contains("OGG"))
  }

  @Test
  func testDownloadFailsGracefullyWithoutLibraryFolder() async throws {
    let store = PodcastStore(persistence: InMemoryPersistence())
    let episode = PodcastEpisode(
      id: "e-1", title: "Episode", showTitle: "Show",
      enclosureURL: try #require(URL(string: "https://example.com/e.mp3")))

    await store.download(episode)

    guard case .failed = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    #expect((store.lastError) != (nil))
  }

  @Test
  func testFailedDownloadLeavesNoPartialFiles() async throws {
    let feedURL = try writeFeedFixture(
      episodeURL: scratch.appendingPathComponent("missing.mp3"))
    let store = store(persistence: InMemoryPersistence())
    let feed = try #require(await store.loadFeed(url: feedURL))
    let episode = try #require(feed.episodes.first { $0.id.hasSuffix("#guid-13") })

    await store.download(episode)

    guard case .failed = store.episodeStates[episode.id] else {
      Issue.record("expected a failed state")
      return
    }
    let showFolder = library.appendingPathComponent("Podcasts/Baywatch Berlin")
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: showFolder.path)) ?? []
    #expect(contents.isEmpty)
  }

  @Test
  func testSearchWithEmptyTermReturnsNothingWithoutError() async {
    let store = store(persistence: InMemoryPersistence())
    let results = await store.search(term: "   ")
    #expect(results.isEmpty)
    #expect((store.lastError) == (nil))
  }

  @Test
  func testLoadFeedFailureSetsLastError() async throws {
    let store = store(persistence: InMemoryPersistence())
    let missing = scratch.appendingPathComponent("missing-feed.xml")
    let feed = await store.loadFeed(url: missing)
    #expect((feed) == (nil))
    #expect((store.lastError) != (nil))
  }
}

// MARK: - Online policy podcast consent

@MainActor
struct OnlineServicesPolicyPodcastTests {
  @Test
  func testPodcastConsentDefaultsOnAndRefreshOn() {
    let policy = OnlineServicesPolicy(persistence: InMemoryPersistence())
    #expect(policy.isPodcastsEnabled)
    #expect(policy.podcastAutoRefresh)
    #expect(policy.isPodcastAutoRefreshActive)
    #expect(!policy.isEnabled)  // MusicBrainz still requires opt-in
  }

  @Test
  func testPodcastConsentIsIndependentOfMusicBrainzAndRoundTrips() {
    let persistence = InMemoryPersistence()
    let policy = OnlineServicesPolicy(persistence: persistence)
    policy.setPodcastsConsent(.disabled)
    policy.setPodcastAutoRefresh(false)
    #expect(!policy.isPodcastsEnabled)
    #expect(!policy.isEnabled)  // MusicBrainz consent untouched
    #expect(!policy.isPodcastAutoRefreshActive)

    let reloaded = OnlineServicesPolicy(persistence: persistence)
    #expect(!reloaded.isPodcastsEnabled)
    #expect(!reloaded.podcastAutoRefresh)
    #expect(!reloaded.isEnabled)
  }
}

// MARK: - Subscription automation

@MainActor
final class PodcastAutomationTests {
  private let scratch: URL
  private let library: URL

  init() throws {
    scratch = TestScratch.directory(prefix: "NightdrivePodcastAutomation")
    library = scratch.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
  }

  deinit {
    let scratch = self.scratch
    try? FileManager.default.removeItem(at: scratch)
  }

  private func store(
    persistence: any AppDataPersistence = InMemoryPersistence()
  ) -> PodcastStore {
    let store = PodcastStore(persistence: persistence)
    let library = self.library
    store.libraryFolderProvider = { library }
    return store
  }

  /// Three episodes, newest first, each backed by a real local MP3.
  private func writeAutomationFeed() throws -> URL {
    var items = ""
    for (index, day) in [("3", "21"), ("2", "14"), ("1", "07")] {
      let source = scratch.appendingPathComponent("source-\(index).mp3")
      try MP3Builder.build(
        tags: MP3Builder.Tags(title: "", artist: "", album: "", genre: "", trackNumber: 0, year: 0),
        seconds: 1
      ).write(to: source)
      items += """
        <item>
          <title>Episode \(index)</title>
          <guid>auto-\(index)</guid>
          <pubDate>Fri, \(day) Aug 2026 06:00:00 +0000</pubDate>
          <enclosure url="\(source.absoluteString)" type="audio/mpeg" length="1000"/>
        </item>
        """
    }
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Automation Show</title>\(items)</channel></rss>
      """
    let feedURL = scratch.appendingPathComponent("automation-feed.xml")
    try xml.write(to: feedURL, atomically: true, encoding: .utf8)
    return feedURL
  }

  /// Rewrites one stable feed URL with a single new episode, matching a
  /// publisher that only exposes its latest item.
  private func writeRollingAutomationFeed(guid: String, day: String) throws -> URL {
    let source = scratch.appendingPathComponent("source-\(guid).mp3")
    try MP3Builder.build(
      tags: MP3Builder.Tags(title: "", artist: "", album: "", genre: "", trackNumber: 0, year: 0),
      seconds: 1
    ).write(to: source)
    let xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel><title>Rolling Automation Show</title>
        <item>
          <title>Episode \(guid)</title>
          <guid>\(guid)</guid>
          <pubDate>Fri, \(day) Aug 2026 06:00:00 +0000</pubDate>
          <enclosure url="\(source.absoluteString)" type="audio/mpeg" length="1000"/>
        </item>
      </channel></rss>
      """
    let feedURL = scratch.appendingPathComponent("rolling-automation-feed.xml")
    try xml.write(to: feedURL, atomically: true, encoding: .utf8)
    return feedURL
  }

  @Test
  func testAutomationSettingsPersist() async throws {
    let persistence = InMemoryPersistence()
    let feedURL = try writeAutomationFeed()
    let first = PodcastStore(persistence: persistence)
    await first.subscribe(feedURL: feedURL)
    let subscription = try #require(first.subscriptions.first)
    #expect(subscription.autoDownloadCount == 0)
    #expect(subscription.autoDeleteKeepCount == 0)
    #expect(!subscription.removePlayedEpisodes)

    first.setAutoDownloadCount(3, for: subscription)
    first.setAutoDeleteKeepCount(5, for: subscription)
    first.setRemovePlayedEpisodes(true, for: subscription)

    let reloaded = PodcastStore(persistence: persistence)
    #expect(reloaded.subscriptions.first?.autoDownloadCount == 3)
    #expect(reloaded.subscriptions.first?.autoDeleteKeepCount == 5)
    #expect(reloaded.subscriptions.first?.removePlayedEpisodes == true)
  }

  @Test
  func testOlderSavedSubscriptionDefaultsAutomationSettingsOff() throws {
    let persistence = InMemoryPersistence()
    persistence.data = Data(
      """
      {"subscriptions":[{"addedAt":0,"feedURL":"https://example.com/feed.xml","title":"Legacy Show"}]}
      """.utf8)

    let store = PodcastStore(persistence: persistence)

    let subscription = try #require(store.subscriptions.first)
    #expect(subscription.autoDownloadCount == 0)
    #expect(subscription.autoDeleteKeepCount == 0)
    #expect(!subscription.removePlayedEpisodes)
  }

  @Test
  func testMaintenanceDownloadsNewestEpisodes() async throws {
    let store = store()
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(2, for: subscription)

    await store.performMaintenance()

    let feed = try #require(store.feeds[subscription.feedURL])
    #expect(feed.episodes.map { $0.id.hasSuffix("#auto-3") } == [true, false, false])
    #expect(feed.episodes.map { $0.id.hasSuffix("#auto-1") } == [false, false, true])
    #expect(store.localFileURL(for: feed.episodes[0]) != nil)
    #expect(store.localFileURL(for: feed.episodes[1]) != nil)
    #expect(store.localFileURL(for: feed.episodes[2]) == nil)
  }

  @Test
  func testMaintenanceRemovesPlayedEpisodesAndDoesNotRedownloadThem() async throws {
    let store = store()
    let played = Mutex<Set<String>>([])
    store.episodePlayedProvider = { url in
      played.withLock { $0.contains(url.lastPathComponent) }
    }
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(2, for: subscription)
    store.setRemovePlayedEpisodes(true, for: subscription)

    await store.performMaintenance()
    let feed = try #require(store.feeds[subscription.feedURL])
    let newest = feed.episodes[0]
    let newestFile = try #require(store.localFileURL(for: newest))

    // The newest episode gets listened to (e.g. play counts merged from an
    // iPod sync); the next pass removes it and does not fetch it again.
    _ = played.withLock { $0.insert(newestFile.lastPathComponent) }
    await store.performMaintenance()

    #expect(store.localFileURL(for: newest) == nil)
    #expect(!FileManager.default.fileExists(atPath: newestFile.path))
    #expect(store.localFileURL(for: feed.episodes[1]) != nil)
    #expect(store.episodeStates[newest.id] == .notDownloaded)
  }

  @Test
  func testMaintenanceDeletesAllButConfiguredNewestEpisodes() async throws {
    let store = store()
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(3, for: subscription)
    await store.performMaintenance()

    let feed = try #require(store.feeds[subscription.feedURL])
    let newestFile = try #require(store.localFileURL(for: feed.episodes[0]))
    let middleFile = try #require(store.localFileURL(for: feed.episodes[1]))
    let oldestFile = try #require(store.localFileURL(for: feed.episodes[2]))

    store.setAutoDownloadCount(0, for: subscription)
    store.setAutoDeleteKeepCount(1, for: subscription)
    await store.performMaintenance()

    #expect(store.localFileURL(for: feed.episodes[0]) != nil)
    #expect(store.localFileURL(for: feed.episodes[1]) == nil)
    #expect(store.localFileURL(for: feed.episodes[2]) == nil)
    #expect(FileManager.default.fileExists(atPath: newestFile.path))
    #expect(!FileManager.default.fileExists(atPath: middleFile.path))
    #expect(!FileManager.default.fileExists(atPath: oldestFile.path))
  }

  @Test
  func testRetentionLimitCapsAutomaticDownloads() async throws {
    let store = store()
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(3, for: subscription)
    store.setAutoDeleteKeepCount(2, for: subscription)

    await store.performMaintenance()
    await store.performMaintenance()

    let feed = try #require(store.feeds[subscription.feedURL])
    #expect(store.localFileURL(for: feed.episodes[0]) != nil)
    #expect(store.localFileURL(for: feed.episodes[1]) != nil)
    #expect(store.localFileURL(for: feed.episodes[2]) == nil)
  }

  @Test
  func testRetentionDeletesEpisodeMissingFromRollingFeedAfterRestart() async throws {
    let persistence = InMemoryPersistence()
    let feedURL = try writeRollingAutomationFeed(guid: "rolling-1", day: "07")
    let first = store(persistence: persistence)
    await first.subscribe(feedURL: feedURL)
    let subscription = try #require(first.subscriptions.first)
    first.setAutoDownloadCount(1, for: subscription)
    first.setAutoDeleteKeepCount(1, for: subscription)
    await first.performMaintenance()

    let firstEpisode = try #require(first.feeds[feedURL]?.episodes.first)
    let firstFile = try #require(first.localFileURL(for: firstEpisode))
    _ = try writeRollingAutomationFeed(guid: "rolling-2", day: "14")

    let reloaded = store(persistence: persistence)
    await reloaded.performMaintenance()

    let currentEpisode = try #require(reloaded.feeds[feedURL]?.episodes.first)
    #expect(currentEpisode.id.hasSuffix("#rolling-2"))
    #expect(reloaded.localFileURL(for: currentEpisode) != nil)
    #expect(!FileManager.default.fileExists(atPath: firstFile.path))
    let mapping = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: PodcastDownloadsFile.url(for: library)))
    let owners = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: PodcastDownloadOwnersFile.url(for: library)))
    #expect(mapping[firstEpisode.id] == nil)
    #expect(mapping[currentEpisode.id] != nil)
    #expect(owners[firstEpisode.id] == nil)
    #expect(owners[currentEpisode.id] == feedURL.absoluteString)
  }

  @Test
  func testRetentionDoesNotClaimFragmentFeedDownloadByStringPrefix() async throws {
    let store = store()
    let baseFeedURL = try writeRollingAutomationFeed(guid: "shared-guid", day: "07")
    let fragmentFeedURL = try #require(URL(string: "\(baseFeedURL.absoluteString)#alternate"))
    await store.subscribe(feedURL: baseFeedURL)
    await store.subscribe(feedURL: fragmentFeedURL)

    let baseSubscription = try #require(
      store.subscriptions.first { $0.feedURL == baseFeedURL })
    let fragmentEpisode = try #require(store.feeds[fragmentFeedURL]?.episodes.first)
    await store.download(fragmentEpisode)
    let fragmentFile = try #require(store.localFileURL(for: fragmentEpisode))
    store.setAutoDeleteKeepCount(1, for: baseSubscription)

    await store.performMaintenance()

    #expect(store.localFileURL(for: fragmentEpisode) == fragmentFile)
    #expect(FileManager.default.fileExists(atPath: fragmentFile.path))
  }

  @Test
  func testFailedRollingFeedDeletionRemainsVisibleAfterNewDownload() async throws {
    let persistence = InMemoryPersistence()
    let feedURL = try writeRollingAutomationFeed(guid: "locked-rolling-1", day: "07")
    let first = store(persistence: persistence)
    await first.subscribe(feedURL: feedURL)
    let subscription = try #require(first.subscriptions.first)
    first.setAutoDownloadCount(1, for: subscription)
    first.setAutoDeleteKeepCount(1, for: subscription)
    await first.performMaintenance()

    let firstEpisode = try #require(first.feeds[feedURL]?.episodes.first)
    let firstFile = try #require(first.localFileURL(for: firstEpisode))
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: firstFile.path)
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: firstFile.path)
    }
    _ = try writeRollingAutomationFeed(guid: "locked-rolling-2", day: "14")

    let reloaded = store(persistence: persistence)
    await reloaded.performMaintenance()

    let currentEpisode = try #require(reloaded.feeds[feedURL]?.episodes.first)
    #expect(reloaded.localFileURL(for: currentEpisode) != nil)
    #expect(FileManager.default.fileExists(atPath: firstFile.path))
    #expect(reloaded.lastError != nil)
    let mapping = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: PodcastDownloadsFile.url(for: library)))
    #expect(mapping[firstEpisode.id] != nil)
    #expect(mapping[currentEpisode.id] != nil)
  }

  @Test
  func testRetentionPreservesRecordWhenFileDeletionFails() async throws {
    let store = store()
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(3, for: subscription)
    await store.performMaintenance()

    let feed = try #require(store.feeds[subscription.feedURL])
    let blocked = feed.episodes[1]
    let blockedFile = try #require(store.localFileURL(for: blocked))
    let oldest = feed.episodes[2]
    let oldestFile = try #require(store.localFileURL(for: oldest))
    store.setAutoDownloadCount(0, for: subscription)
    store.setAutoDeleteKeepCount(1, for: subscription)
    try FileManager.default.setAttributes(
      [.immutable: true], ofItemAtPath: blockedFile.path)
    defer {
      try? FileManager.default.setAttributes(
        [.immutable: false], ofItemAtPath: blockedFile.path)
    }

    await store.performMaintenance()

    #expect(store.localFileURL(for: blocked) == blockedFile)
    #expect(FileManager.default.fileExists(atPath: blockedFile.path))
    #expect(store.localFileURL(for: oldest) == nil)
    #expect(!FileManager.default.fileExists(atPath: oldestFile.path))
    #expect(store.lastError != nil)
    let mapping = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: PodcastDownloadsFile.url(for: library)))
    #expect(mapping[blocked.id] != nil)
    #expect(mapping[oldest.id] == nil)
  }

  @Test
  func testPlayedAndOlderDeletionPoliciesCompose() async throws {
    let store = store()
    let played = Mutex<Set<String>>([])
    store.episodePlayedProvider = { url in
      played.withLock { $0.contains(url.lastPathComponent) }
    }
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(3, for: subscription)
    await store.performMaintenance()

    let feed = try #require(store.feeds[subscription.feedURL])
    let newestFile = try #require(store.localFileURL(for: feed.episodes[0]))
    _ = played.withLock { $0.insert(newestFile.lastPathComponent) }
    store.setAutoDeleteKeepCount(2, for: subscription)
    store.setRemovePlayedEpisodes(true, for: subscription)

    await store.performMaintenance()

    #expect(store.localFileURL(for: feed.episodes[0]) == nil)
    #expect(store.localFileURL(for: feed.episodes[1]) != nil)
    #expect(store.localFileURL(for: feed.episodes[2]) == nil)
  }

  @Test
  func testSettingChangesDuringMaintenanceStopDownloadsAndQueueAnotherPass() async throws {
    let store = store()
    await store.subscribe(feedURL: try writeAutomationFeed())
    let subscription = try #require(store.subscriptions.first)
    store.setAutoDownloadCount(3, for: subscription)

    // Mid-run — deterministically, from the played consult maintenance
    // performs right before each episode download — the user turns
    // auto-download off, enables remove-played (the episode about to
    // download finishes playing elsewhere), and pokes maintenance again.
    var playedFiles: Set<String> = []
    var consultedFiles: [String] = []
    var corrected = false
    var correctiveCall: Task<Void, Never>?
    store.episodePlayedProvider = { [weak store] url in
      consultedFiles.append(url.lastPathComponent)
      if !corrected, let store {
        corrected = true
        store.setAutoDownloadCount(0, for: subscription)
        store.setRemovePlayedEpisodes(true, for: subscription)
        playedFiles.insert(url.lastPathComponent)
        correctiveCall = Task { await store.performMaintenance() }
        return false
      }
      return playedFiles.contains(url.lastPathComponent)
    }

    await store.performMaintenance()
    await correctiveCall?.value

    let feed = try #require(store.feeds[subscription.feedURL])
    // The first download was already committed when the count dropped; the
    // remaining two episodes were never fetched, and the queued corrective
    // pass removed the now-played download under the new settings.
    #expect(store.episodeStates[feed.episodes[0].id] == .notDownloaded)
    #expect(store.localFileURL(for: feed.episodes[1]) == nil)
    #expect(store.localFileURL(for: feed.episodes[2]) == nil)
    let showFolder = library.appendingPathComponent(
      "Podcasts/Automation Show", isDirectory: true)
    let contents =
      (try? FileManager.default.contentsOfDirectory(atPath: showFolder.path)) ?? []
    #expect(contents.isEmpty)
    // Exactly two consults: one before the first episode's download, one
    // when the corrective pass removed that episode's played file.
    #expect(consultedFiles.count == 2)
    #expect(Set(consultedFiles).count == 1)
  }
}

// MARK: - Test-only conveniences

extension PodcastFileNaming {
  /// Test convenience over `episodeRelativePath`; production code resolves
  /// paths through the store's per-library download mapping instead.
  static func episodeFileURL(
    libraryFolder: URL, showTitle: String, episodeTitle: String, episodeID: String,
    fileExtension: String
  ) -> URL {
    libraryFolder.appendingPathComponent(
      episodeRelativePath(
        showTitle: showTitle, episodeTitle: episodeTitle, episodeID: episodeID,
        fileExtension: fileExtension),
      isDirectory: false)
  }
}
