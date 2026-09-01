import Foundation
import Synchronization
import Testing

@testable import Nightdrive

final class MusicBrainzTests {
  private var directory: URL!

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMusicBrainzTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  @Test
  func testParsesRecordingSearchResponse() throws {
    let candidates = try MusicBrainzParser.recordingCandidates(
      from: Data(Self.recordingSearchJSON.utf8))

    #expect((candidates.count) == (3))
    let best = candidates[0]
    #expect((best.recordingID) == ("rec-1"))
    #expect((best.score) == (100))
    #expect((best.title) == ("Paranoid Android"))
    #expect((best.artistName) == ("Radiohead"))
    #expect((best.artistID) == ("artist-1"))
    #expect((best.releaseID) == ("release-1"))
    #expect((best.releaseTitle) == ("OK Computer"))
    #expect((best.year) == (1997))
    #expect((best.trackNumber) == (2))
    #expect((best.discNumber) == (1))
    #expect((best.trackCount) == (12))

    #expect((candidates[1].recordingID) == ("rec-1"))
    #expect((candidates[1].releaseID) == ("release-2"))

    #expect((candidates[2].recordingID) == ("rec-2"))
    #expect((candidates[2].score) == (88))
    #expect((candidates[2].releaseID) == (""))
  }

  @Test
  func testParsesReleaseSearchResponse() throws {
    let candidates = try MusicBrainzParser.releaseCandidates(
      from: Data(Self.releaseSearchJSON.utf8))

    #expect((candidates.count) == (2))
    #expect((candidates[0].id) == ("release-1"))
    #expect((candidates[0].score) == (100))
    #expect((candidates[0].title) == ("OK Computer"))
    #expect((candidates[0].artistName) == ("Radiohead"))
    #expect((candidates[0].year) == (1997))
    #expect((candidates[0].country) == ("GB"))
    #expect((candidates[0].trackCount) == (12))
    #expect((candidates[1].trackCount) == (0))
  }

  @Test
  func testParsesReleaseLookupResponse() throws {
    let release = try MusicBrainzParser.release(from: Data(Self.releaseLookupJSON.utf8))

    #expect((release.id) == ("release-1"))
    #expect((release.title) == ("OK Computer"))
    #expect((release.artistName) == ("Radiohead"))
    #expect((release.artistID) == ("artist-1"))
    #expect((release.year) == (1997))
    #expect((release.discCount) == (2))
    #expect((release.tracks.count) == (3))

    #expect((release.tracks[0].recordingID) == ("rec-1"))
    #expect((release.tracks[0].title) == ("Airbag"))
    #expect((release.tracks[0].discNumber) == (1))
    #expect((release.tracks[0].trackNumber) == (1))
    #expect((release.tracks[0].trackCount) == (2))
    #expect((release.tracks[1].artistName) == ("Radiohead feat. Guest"))
    #expect((release.tracks[1].artistID) == ("artist-1"))
    #expect((release.tracks[2].discNumber) == (2))
    #expect((release.tracks[2].trackNumber) == (1))
  }

  @Test
  func testMalformedResponseThrows() {
    #expect(throws: (any Error).self) { try MusicBrainzParser.recordingCandidates(from: Data("not json".utf8)) }
    #expect(throws: (any Error).self) { try MusicBrainzParser.release(from: Data("{}".utf8)) }
  }

  @Test
  func testArtistCreditConcatenatesJoinPhrasesVerbatim() throws {
    let json = """
      {
        "recordings": [
          {
            "id": "rec-9",
            "score": 100,
            "title": "Duet",
            "artist-credit": [
              {"name": "A", "joinphrase": " feat. ", "artist": {"id": "a-1", "name": "A"}},
              {"name": "B", "artist": {"id": "b-1", "name": "B"}}
            ]
          }
        ]
      }
      """
    let candidates = try MusicBrainzParser.recordingCandidates(from: Data(json.utf8))
    #expect((candidates.count) == (1))
    #expect((candidates[0].artistName) == ("A feat. B"))
    #expect((candidates[0].artistID) == ("a-1"))
  }

  @MainActor
  @Test
  func testCanLookUpRequiresOneResolvedAlbumIdentity() {
    func track(_ name: String, artist: String, albumArtist: String) -> LibraryTrack {
      var track = makeTrack(name: name, title: name, track: 1, disc: 1)
      track.album = "Greatest Hits"
      track.artist = artist
      track.albumArtist = albumArtist
      return track
    }
    let queen = track("one.mp3", artist: "Queen", albumArtist: "Queen")
    let queenToo = track("two.mp3", artist: "Queen", albumArtist: "Queen")
    let abba = track("three.mp3", artist: "ABBA", albumArtist: "ABBA")

    #expect(AlbumLookupRequest.canLookUp([queen, queenToo]))
    #expect(
      !(AlbumLookupRequest.canLookUp([queen, abba])),
      Comment(rawValue: "Same-titled albums by different artists are two records, not one lookup"))
  }

  @Test
  func testClientRefusesWithoutConsent() async throws {
    for consent in [OnlineServicesConsent.unset, .disabled] {
      let transport = RecordingTransport(body: "{}")
      let client = MusicBrainzClient(consent: { consent }, transport: transport)
      do {
        _ = try await client.searchRecordings(title: "Song", artist: "Artist", album: "")
        Issue.record("Expected consentNotGranted for \(consent)")
      } catch let error as MusicBrainzError {
        #expect((error) == (.consentNotGranted))
      }
      let requestCount = await transport.requests.count
      #expect((requestCount) == (0), Comment(rawValue: "No request may leave without consent"))
    }
  }

  @Test
  func testClientRejectsEmptyQueries() async {
    let transport = RecordingTransport(body: "{}")
    let client = MusicBrainzClient(consent: { .enabled }, transport: transport)
    do {
      _ = try await client.searchRecordings(title: " ", artist: "", album: "")
      Issue.record("Expected emptyQuery")
    } catch {
      #expect((error as? MusicBrainzError) == (.emptyQuery))
    }
  }

  @Test
  func testConsentRevokedWhileWaitingForSlotAbortsRequest() async throws {
    let transport = RecordingTransport(body: #"{"recordings": []}"#)
    let consent = ConsentSequence([.enabled, .enabled, .enabled, .disabled])
    let client = MusicBrainzClient(
      consent: { await consent.next() }, transport: transport,
      minimumInterval: .milliseconds(200))

    _ = try await client.searchRecordings(title: "One", artist: "A", album: "")
    do {
      _ = try await client.searchRecordings(title: "Two", artist: "A", album: "")
      Issue.record("Expected consentNotGranted after mid-wait revocation")
    } catch {
      #expect((error as? MusicBrainzError) == (.consentNotGranted))
    }
    let requests = await transport.requests
    #expect((requests.count) == (1), Comment(rawValue: "The revoked request must never reach the transport"))
  }

  @Test
  func testClientSendsUserAgentAndJSONFormat() async throws {
    let transport = RecordingTransport(body: #"{"recordings": []}"#)
    let requestTimeout: TimeInterval = 12
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero,
      requestTimeout: requestTimeout)

    _ = try await client.searchRecordings(
      title: "Paranoid \"Android\"", artist: "Radiohead", album: "OK Computer")

    let requests = await transport.requests
    #expect((requests.count) == (1))
    let request = requests[0]
    #expect((request.timeoutInterval) == (requestTimeout))
    let userAgent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
    #expect(userAgent.hasPrefix("Nightdrive/"))
    #expect(userAgent.contains(AppLinks.repository.absoluteString))

    let url = try #require(request.url)
    #expect((url.host) == ("musicbrainz.org"))
    #expect(url.path.hasPrefix("/ws/2/recording"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = components.queryItems ?? []
    #expect(items.contains(URLQueryItem(name: "fmt", value: "json")))
    let query = try #require(items.first { $0.name == "query" }?.value)
    #expect(query.contains(#"recording:"Paranoid \"Android\"""#))
    #expect(query.contains(#"artist:"Radiohead""#))
    #expect(query.contains(#"release:"OK Computer""#))
  }

  @Test
  func testClientFetchesAndCachesCanonicalGenreNamesAsText() async throws {
    let transport = RecordingTransport(body: "alternative rock\nindie folk\n")
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero)

    let expected = Set(["alternative rock", "indie folk"])
    let first = try await client.genreNames()
    let second = try await client.genreNames()
    #expect((first) == (expected))
    #expect((second) == (expected))

    let requests = await transport.requests
    #expect((requests.count) == (1))
    #expect((requests[0].value(forHTTPHeaderField: "Accept")) == ("text/plain"))
    let url = try #require(requests[0].url)
    #expect((url.path) == ("/ws/2/genre/all"))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect((components.queryItems ?? []).contains(URLQueryItem(name: "fmt", value: "txt")))
  }

  @Test
  func testClientSurfacesHTTPFailures() async {
    let transport = RecordingTransport(body: "{}", statusCode: 503)
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero)
    do {
      _ = try await client.release(withID: "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29")
      Issue.record("Expected requestFailed")
    } catch {
      #expect((error as? MusicBrainzError) == (.requestFailed(statusCode: 503)))
    }
    let requestCount = await transport.requests.count
    #expect((requestCount) == (MusicBrainzClient.defaultServiceUnavailableRetryCount + 1))
  }

  @Test
  func testClientRetriesServiceUnavailableAfterRetryAfter() async throws {
    let transport = SequencedTransport(
      responses: [
        .init(body: "{}", statusCode: 503, headers: ["Retry-After": "0"]),
        .init(body: #"{"recordings": []}"#, statusCode: 200),
      ])
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero)

    let candidates = try await client.searchRecordings(title: "Song", artist: "Artist", album: "")

    #expect(candidates.isEmpty)
    let requests = await transport.requests
    #expect((requests.count) == (2))
  }

  @Test
  func testRetryAfterAcceptsSecondsAndHTTPDate() throws {
    let url = try #require(URL(string: "https://musicbrainz.org/ws/2/recording"))
    let secondsResponse = try #require(
      HTTPURLResponse(
        url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "17"]))
    #expect((MusicBrainzClient.retryDelay(from: secondsResponse)) == (.seconds(17)))

    let calendar = Calendar(identifier: .gregorian)
    let now = try #require(
      calendar.date(
        from: DateComponents(
          timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 8, day: 26, hour: 12)))
    let dateResponse = try #require(
      HTTPURLResponse(
        url: url, statusCode: 503, httpVersion: nil,
        headerFields: ["Retry-After": "Wed, 26 Aug 2026 12:02:00 GMT"]))
    #expect((MusicBrainzClient.retryDelay(from: dateResponse, now: now)) == nil)

    let boundedDateResponse = try #require(
      HTTPURLResponse(
        url: url, statusCode: 503, httpVersion: nil,
        headerFields: ["Retry-After": "Wed, 26 Aug 2026 12:01:00 GMT"]))
    #expect((MusicBrainzClient.retryDelay(from: boundedDateResponse, now: now)) == (.seconds(60)))

    let oversizedResponse = try #require(
      HTTPURLResponse(
        url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "1e20"]))
    #expect(MusicBrainzClient.retryDelay(from: oversizedResponse) == nil)

    let malformedResponse = try #require(
      HTTPURLResponse(
        url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "1e1"]))
    #expect(MusicBrainzClient.retryDelay(from: malformedResponse) == nil)
  }

  @Test
  func testClientDoesNotRetryAnUnsafeRetryAfterValue() async {
    let transport = SequencedTransport(
      responses: [
        .init(body: "{}", statusCode: 503, headers: ["Retry-After": "1e20"])
      ])
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero)

    do {
      _ = try await client.searchRecordings(title: "Song", artist: "Artist", album: "")
      Issue.record("Expected requestFailed")
    } catch {
      #expect((error as? MusicBrainzError) == (.requestFailed(statusCode: 503)))
    }
    let requestCount = await transport.requests.count
    #expect((requestCount) == (1))
  }

  @Test
  func testRetryAfterPostponesAlreadyQueuedRequests() async throws {
    let transport = EmbargoTransport()
    let clock = ManualMusicBrainzClock()
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .milliseconds(500),
      clock: clock)

    // First request fires at t=0 and blocks inside the transport.
    let first = Task {
      try await client.searchRecordings(title: "First", artist: "Artist", album: "")
    }
    #expect(await waitUntil { await transport.isFirstResponseBlocked })

    // Second request reserves the t=500ms slot and sleeps on it.
    let second = Task {
      try await client.searchRecordings(title: "Second", artist: "Artist", album: "")
    }
    #expect(await waitUntil { clock.waiterCount == 1 })

    // The 503 (Retry-After: 1) lands while the second request's slot is
    // already reserved; the embargo runs until t=1s. The first request's
    // retry queues behind it.
    await transport.releaseFirstResponse()
    #expect(await waitUntil { clock.waiterCount == 2 })

    // Advancing to the pre-reserved slot must not release the second
    // request: it re-queues behind the embargo instead of firing.
    clock.advance(to: .milliseconds(500))
    #expect(
      await waitUntil { clock.waiterCount == 2 },
      Comment(rawValue: "The pre-embargo slot holder must re-queue, not fire"))
    let requestsDuringEmbargo = await transport.requests.count
    #expect(
      (requestsDuringEmbargo) == (1),
      Comment(rawValue: "A request with a pre-reserved slot must honor a later embargo"))

    // Embargo lifts at t=1s: the retry goes out first, then the queued
    // second request one minimum interval later.
    clock.advance(to: .seconds(1))
    _ = try await first.value
    clock.advance(to: .milliseconds(1500))
    _ = try await second.value
    let instants = await transport.instants
    #expect((instants.count) == (3))
  }

  @Test
  func testClientRejectsNonMBIDReleaseIDsBeforeAnyRequest() async {
    let transport = RecordingTransport(body: "{}")
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: .zero)
    for id in ["", "release-1", "../artist/abc", "0b6b4ba0 d36f 47bd b4ea 6a5b91842d29"] {
      do {
        _ = try await client.release(withID: id)
        Issue.record("Expected malformedResponse for '\(id)'")
      } catch let error as MusicBrainzError {
        guard case .malformedResponse = error else {
          Issue.record("Expected malformedResponse for '\(id)', got \(error)")
          continue
        }
      } catch {
        Issue.record("Expected MusicBrainzError for '\(id)', got \(error)")
      }
    }
    let requestCount = await transport.requests.count
    #expect((requestCount) == (0), Comment(rawValue: "Invalid MBIDs must be rejected before any request leaves"))
  }

  @Test
  func testClientSpacesRequestsByMinimumInterval() async throws {
    let interval: Duration = .milliseconds(250)
    let transport = RecordingTransport(body: #"{"recordings": []}"#)
    let client = MusicBrainzClient(
      consent: { .enabled }, transport: transport, minimumInterval: interval)

    let start = ContinuousClock().now
    _ = try await client.searchRecordings(title: "One", artist: "A", album: "")
    _ = try await client.searchRecordings(title: "Two", artist: "A", album: "")
    _ = try await client.searchRecordings(title: "Three", artist: "A", album: "")

    let instants = await transport.instants
    #expect((instants.count) == (3))
    #expect((instants[1] - start) >= (interval))
    #expect((instants[2] - start) >= (interval * 2))
  }

  @Test
  func testMBIDsRoundTripThroughID3() async throws {
    let url = try makeMP3()
    var metadata = makeMetadata(title: "Airbag", artist: "Radiohead", album: "OK Computer")
    metadata.musicBrainzRecordingID = "b106e8a9-2e59-4dc2-a103-a1b7f4a3a406"
    metadata.musicBrainzReleaseID = "0b6b4ba0-d36f-47bd-b4ea-6a5b91842d29"
    metadata.musicBrainzArtistID = "a74b1b7f-71a5-4011-9441-d0b5e4122711"

    try MP3MetadataWriter.write(metadata, to: url)

    let ids = MusicBrainzID3.read(fromMP3At: url)
    #expect((ids.recordingID) == (metadata.musicBrainzRecordingID))
    #expect((ids.releaseID) == (metadata.musicBrainzReleaseID))
    #expect((ids.artistID) == (metadata.musicBrainzArtistID))

    let track = await MetadataLoader.load(url: url)
    #expect((track.musicBrainzRecordingID) == (metadata.musicBrainzRecordingID))
    #expect((track.musicBrainzReleaseID) == (metadata.musicBrainzReleaseID))
    #expect((track.musicBrainzArtistID) == (metadata.musicBrainzArtistID))
    let roundTripped = TrackMetadata(track)
    #expect((roundTripped.musicBrainzRecordingID) == (metadata.musicBrainzRecordingID))

    metadata.musicBrainzReleaseID = "11111111-2222-3333-4444-555555555555"
    try MP3MetadataWriter.write(metadata, to: url)
    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
    #expect((frames.filter { $0.id == "UFID" }.count) == (1))
    #expect((MusicBrainzID3.read(fromMP3At: url).releaseID) == ("11111111-2222-3333-4444-555555555555"))

    metadata.musicBrainzRecordingID = ""
    metadata.musicBrainzReleaseID = ""
    metadata.musicBrainzArtistID = ""
    try MP3MetadataWriter.write(metadata, to: url)
    #expect(MusicBrainzID3.read(fromMP3At: url).isEmpty)
    let cleared = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
    #expect(!(cleared.contains { $0.id == "UFID" }))
  }

  @Test
  func testUserTextFramesDeclareTheirActualEncoding() throws {
    var metadata = makeMetadata(title: "Title", artist: "Artist", album: "Album")
    metadata.musicBrainzReleaseID = "édition-東京"
    metadata.musicBrainzArtistID = "artïst-音楽"

    func utf16LE(_ value: String) -> Data {
      value.utf16.reduce(into: Data()) { data, unit in
        data.append(UInt8(unit & 0xFF))
        data.append(UInt8(unit >> 8))
      }
    }
    func utf16Payload(_ description: String, _ value: String) -> Data {
      Data([0x01, 0xFF, 0xFE]) + utf16LE(description) + Data([0, 0, 0xFF, 0xFE])
        + utf16LE(value)
    }
    func utf8Payload(_ description: String, _ value: String) -> Data {
      Data([0x03]) + Data(description.utf8) + Data([0]) + Data(value.utf8)
    }

    let expectedUTF16 = [
      utf16Payload(MusicBrainzID3.releaseDescription, metadata.musicBrainzReleaseID),
      utf16Payload(MusicBrainzID3.artistDescription, metadata.musicBrainzArtistID),
    ]

    for version in [2, 3] {
      let frames = MusicBrainzID3.frames(for: metadata, version: version)
        .filter { $0.id == (version == 2 ? "TXX" : "TXXX") }
      #expect((frames.map(\.payload)) == (expectedUTF16))
    }

    let frames = MusicBrainzID3.frames(for: metadata, version: 4)
      .filter { $0.id == "TXXX" }
    let expectedUTF8 = [
      utf8Payload(MusicBrainzID3.releaseDescription, metadata.musicBrainzReleaseID),
      utf8Payload(MusicBrainzID3.artistDescription, metadata.musicBrainzArtistID),
    ]
    #expect((frames.map(\.payload)) == (expectedUTF8))
  }

  @Test
  func testForeignUFIDAndUserTextSurviveManagedWrites() async throws {
    let url = try makeMP3()

    var foreignUFID = Data("http://example.com/ids".utf8)
    foreignUFID.append(0)
    foreignUFID.append(Data("foreign-id".utf8))
    var foreignTXXX = Data([0x00])
    foreignTXXX.append(Data("ReplayGain".utf8))
    foreignTXXX.append(0)
    foreignTXXX.append(Data("-6.5 dB".utf8))
    let original = try Data(contentsOf: url)
    try addingFrames(
      [
        MP3MetadataWriter.Frame(id: "UFID", payload: foreignUFID),
        MP3MetadataWriter.Frame(id: "TXXX", payload: foreignTXXX),
      ], to: original
    ).write(to: url)

    var metadata = makeMetadata(title: "New Title", artist: "Artist", album: "Album")
    metadata.musicBrainzRecordingID = "b106e8a9-2e59-4dc2-a103-a1b7f4a3a406"
    try MP3MetadataWriter.write(metadata, to: url)

    let frames = try MP3MetadataWriter.frames(in: Data(contentsOf: url))
    let ufids = frames.filter { $0.id == "UFID" }
    #expect((ufids.count) == (2), Comment(rawValue: "The foreign UFID and the MusicBrainz UFID coexist"))
    #expect(ufids.contains { $0.payload == foreignUFID })
    #expect(frames.contains { $0.id == "TXXX" && $0.payload == foreignTXXX })
    #expect((MusicBrainzID3.read(fromMP3At: url).recordingID) == ("b106e8a9-2e59-4dc2-a103-a1b7f4a3a406"))
  }

  @Test
  func testMatchesTracksByDiscAndTrackPosition() {
    let release = Self.sampleRelease
    let tracks = [
      makeTrack(name: "one.mp3", title: "Completely Different", track: 1, disc: 1),
      makeTrack(name: "two.mp3", title: "Also Different", track: 1, disc: 2),
    ]

    let proposals = MusicBrainzReleaseMatcher.proposals(for: tracks, release: release)

    #expect((proposals.count) == (2))
    #expect((proposals[0].proposed.title) == ("Airbag"))
    #expect((proposals[0].proposed.album) == ("OK Computer"))
    #expect((proposals[0].proposed.musicBrainzRecordingID) == ("rec-1"))
    #expect((proposals[0].proposed.musicBrainzReleaseID) == ("release-1"))
    #expect((proposals[0].proposed.year) == (1997))
    #expect((proposals[1].proposed.title) == ("Bonus"))
    #expect((proposals[1].proposed.musicBrainzRecordingID) == ("rec-3"))
    #expect(proposals[0].hasChanges)
  }

  @Test
  func testUntaggedDiscNumberFallsBackToDiscOne() {
    let tracks = [makeTrack(name: "one.mp3", title: "Whatever", track: 2, disc: 0)]
    let proposals = MusicBrainzReleaseMatcher.proposals(for: tracks, release: Self.sampleRelease)
    #expect((proposals[0].proposed.title) == ("Paranoid Android"))
    #expect((proposals[0].proposed.discNumber) == (1))
  }

  @Test
  func testFallsBackToTitleMatchingWithoutPositions() {
    let tracks = [
      makeTrack(name: "a.mp3", title: "paranoid android!", track: 0, disc: 0),
      makeTrack(name: "b.mp3", title: "Aírbag", track: 0, disc: 0),
      makeTrack(name: "c.mp3", title: "Not On This Album", track: 0, disc: 0),
    ]

    let proposals = MusicBrainzReleaseMatcher.proposals(for: tracks, release: Self.sampleRelease)

    #expect((proposals[0].proposed.musicBrainzRecordingID) == ("rec-2"))
    #expect((proposals[1].proposed.musicBrainzRecordingID) == ("rec-1"))
    #expect(!(proposals[2].hasChanges))
    #expect((proposals[2].proposed) == (proposals[2].current))
  }

  @Test
  func testEachReleaseTrackIsClaimedAtMostOnce() {
    let tracks = [
      makeTrack(name: "a.mp3", title: "Airbag", track: 1, disc: 1),
      makeTrack(name: "b.mp3", title: "Airbag", track: 0, disc: 0),
    ]

    let proposals = MusicBrainzReleaseMatcher.proposals(for: tracks, release: Self.sampleRelease)

    #expect((proposals[0].proposed.musicBrainzRecordingID) == ("rec-1"))
    #expect(!(proposals[1].hasChanges))
  }

  @MainActor
  @Test
  func testConsentPolicyPersistsAndReloads() throws {
    let persistence = MemoryPersistence()
    let policy = OnlineServicesPolicy(persistence: persistence)
    #expect((policy.consent) == (.unset))
    #expect(!(policy.isEnabled))

    policy.setConsent(.enabled)
    #expect(policy.isEnabled)
    #expect((persistence.saveCount) == (1))

    let reloaded = OnlineServicesPolicy(persistence: persistence)
    #expect((reloaded.consent) == (.enabled))

    reloaded.setConsent(.disabled)
    let disabled = OnlineServicesPolicy(persistence: persistence)
    #expect((disabled.consent) == (.disabled))
    #expect(disabled.persistenceError == nil)
  }

  private func makeMP3() throws -> URL {
    try makeTaggedMP3(in: directory, filename: "track-\(UUID().uuidString).mp3")
  }

  private func makeMetadata(title: String, artist: String, album: String) -> TrackMetadata {
    TrackMetadata(
      title: title, artist: artist, album: album, albumArtist: "", composer: "",
      genre: "", grouping: "", year: 0, bpm: 0, trackNumber: 0, trackCount: 0,
      discNumber: 0, discCount: 0, comment: "", lyrics: "", compilation: false)
  }

  private func makeTrack(name: String, title: String, track: Int, disc: Int) -> LibraryTrack {
    .fixture(
      url: directory.appendingPathComponent(name), title: title, artist: "Old Artist",
      album: "Old Album", trackNumber: track, discNumber: disc, sizeBytes: 4096,
      bitrate: 128_000)
  }

  private static let sampleRelease = MusicBrainzRelease(
    id: "release-1",
    title: "OK Computer",
    artistName: "Radiohead",
    artistID: "artist-1",
    date: "1997-05-21",
    discCount: 2,
    tracks: [
      MusicBrainzReleaseTrack(
        recordingID: "rec-1", title: "Airbag", artistName: "Radiohead",
        artistID: "artist-1", discNumber: 1, trackNumber: 1, trackCount: 2),
      MusicBrainzReleaseTrack(
        recordingID: "rec-2", title: "Paranoid Android", artistName: "Radiohead",
        artistID: "artist-1", discNumber: 1, trackNumber: 2, trackCount: 2),
      MusicBrainzReleaseTrack(
        recordingID: "rec-3", title: "Bonus", artistName: "Radiohead",
        artistID: "artist-1", discNumber: 2, trackNumber: 1, trackCount: 1),
    ])

  private static let recordingSearchJSON = """
    {
      "created": "2024-01-01T00:00:00.000Z",
      "count": 2,
      "offset": 0,
      "recordings": [
        {
          "id": "rec-1",
          "score": 100,
          "title": "Paranoid Android",
          "length": 383000,
          "artist-credit": [
            {"name": "Radiohead", "artist": {"id": "artist-1", "name": "Radiohead"}}
          ],
          "releases": [
            {
              "id": "release-1",
              "title": "OK Computer",
              "date": "1997-05-21",
              "track-count": 12,
              "media": [
                {
                  "position": 1,
                  "format": "CD",
                  "track": [{"id": "t-1", "number": "2", "title": "Paranoid Android"}],
                  "track-count": 12,
                  "track-offset": 1
                }
              ]
            },
            {
              "id": "release-2",
              "title": "OK Computer OKNOTOK 1997 2017",
              "date": "2017-06-23",
              "track-count": 23,
              "media": [
                {
                  "position": 1,
                  "track": [{"number": "2"}],
                  "track-count": 23
                }
              ]
            }
          ]
        },
        {
          "id": "rec-2",
          "score": 88,
          "title": "Paranoid Android (live)",
          "artist-credit": [
            {"name": "Radiohead", "artist": {"id": "artist-1", "name": "Radiohead"}}
          ]
        }
      ]
    }
    """

  private static let releaseSearchJSON = """
    {
      "created": "2024-01-01T00:00:00.000Z",
      "count": 2,
      "offset": 0,
      "releases": [
        {
          "id": "release-1",
          "score": 100,
          "title": "OK Computer",
          "status": "Official",
          "date": "1997-05-21",
          "country": "GB",
          "track-count": 12,
          "artist-credit": [
            {"name": "Radiohead", "artist": {"id": "artist-1", "name": "Radiohead"}}
          ]
        },
        {
          "id": "release-2",
          "score": 92,
          "title": "OK Computer",
          "artist-credit": [
            {"name": "Radiohead", "artist": {"id": "artist-1", "name": "Radiohead"}}
          ]
        }
      ]
    }
    """

  private static let releaseLookupJSON = """
    {
      "id": "release-1",
      "title": "OK Computer",
      "status": "Official",
      "date": "1997-05-21",
      "country": "GB",
      "artist-credit": [
        {"name": "Radiohead", "artist": {"id": "artist-1", "name": "Radiohead"}}
      ],
      "media": [
        {
          "position": 1,
          "format": "CD",
          "track-count": 2,
          "tracks": [
            {
              "id": "t-1",
              "position": 1,
              "number": "1",
              "title": "Airbag",
              "recording": {"id": "rec-1", "title": "Airbag"}
            },
            {
              "id": "t-2",
              "position": 2,
              "number": "2",
              "title": "Paranoid Android",
              "artist-credit": [
                {
                  "name": "Radiohead",
                  "joinphrase": " feat. ",
                  "artist": {"id": "artist-1", "name": "Radiohead"}
                },
                {"name": "Guest", "artist": {"id": "artist-9", "name": "Guest"}}
              ],
              "recording": {"id": "rec-2", "title": "Paranoid Android"}
            }
          ]
        },
        {
          "position": 2,
          "track-count": 1,
          "tracks": [
            {
              "id": "t-3",
              "position": 1,
              "number": "1",
              "title": "Bonus",
              "recording": {"id": "rec-3", "title": "Bonus"}
            }
          ]
        }
      ]
    }
    """
}

private actor RecordingTransport: MusicBrainzTransport {
  private(set) var requests: [URLRequest] = []
  private(set) var instants: [ContinuousClock.Instant] = []
  private let body: String
  private let statusCode: Int
  private let clock = ContinuousClock()

  init(body: String, statusCode: Int = 200) {
    self.body = body
    self.statusCode = statusCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    instants.append(clock.now)
    let response = HTTPURLResponse(
      url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), response)
  }
}

private actor SequencedTransport: MusicBrainzTransport {
  struct Response: Sendable {
    let body: String
    let statusCode: Int
    let headers: [String: String]

    init(body: String, statusCode: Int, headers: [String: String] = [:]) {
      self.body = body
      self.statusCode = statusCode
      self.headers = headers
    }
  }

  private(set) var requests: [URLRequest] = []
  private var responses: [Response]

  init(responses: [Response]) {
    precondition(!responses.isEmpty)
    self.responses = responses
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    let response = responses.count > 1 ? responses.removeFirst() : responses[0]
    let http = HTTPURLResponse(
      url: request.url!, statusCode: response.statusCode, httpVersion: nil,
      headerFields: response.headers)!
    return (Data(response.body.utf8), http)
  }
}

/// A hand-cranked MusicBrainzClock: time only moves when the test advances
/// it, so rate-limiter tests cannot race wall-clock sleeps under suite load.
private final class ManualMusicBrainzClock: MusicBrainzClock, @unchecked Sendable {
  private struct Waiter {
    let deadline: ContinuousClock.Instant
    let continuation: CheckedContinuation<Void, Never>
  }

  private let origin = ContinuousClock().now
  private let lock = NSLock()
  private var offset: Duration = .zero
  private var waiters: [Waiter] = []

  var now: ContinuousClock.Instant {
    lock.withLock { origin.advanced(by: offset) }
  }

  var waiterCount: Int {
    lock.withLock { waiters.count }
  }

  func advance(to elapsed: Duration) {
    let due: [Waiter] = lock.withLock {
      offset = max(offset, elapsed)
      let current = origin.advanced(by: offset)
      let ready = waiters.filter { $0.deadline <= current }
      waiters.removeAll { $0.deadline <= current }
      return ready
    }
    for waiter in due { waiter.continuation.resume() }
  }

  func sleep(until instant: ContinuousClock.Instant) async throws {
    await withCheckedContinuation { continuation in
      let resumeNow: Bool = lock.withLock {
        if instant <= origin.advanced(by: offset) { return true }
        waiters.append(Waiter(deadline: instant, continuation: continuation))
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }
}

private actor EmbargoTransport: MusicBrainzTransport {
  private(set) var requests: [URLRequest] = []
  private(set) var instants: [ContinuousClock.Instant] = []
  private var firstResponseContinuation: CheckedContinuation<Void, Never>?
  private let clock = ContinuousClock()

  var isFirstResponseBlocked: Bool { firstResponseContinuation != nil }

  func releaseFirstResponse() {
    firstResponseContinuation?.resume()
    firstResponseContinuation = nil
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    instants.append(clock.now)
    if requests.count == 1 {
      await withCheckedContinuation { firstResponseContinuation = $0 }
      let response = HTTPURLResponse(
        url: request.url!, statusCode: 503, httpVersion: nil,
        headerFields: ["Retry-After": "1"])!
      return (Data("{}".utf8), response)
    }

    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (Data(#"{"recordings": []}"#.utf8), response)
  }
}

private actor ConsentSequence {
  private var values: [OnlineServicesConsent]

  init(_ values: [OnlineServicesConsent]) {
    precondition(!values.isEmpty)
    self.values = values
  }

  func next() -> OnlineServicesConsent {
    values.count > 1 ? values.removeFirst() : values[0]
  }
}

private final class MemoryPersistence: AppDataPersistence {
  private struct State {
    var data: Data?
    var error: Error?
    var saveCount = 0
  }

  private let state = Mutex(State())

  var saveCount: Int { state.withLock { $0.saveCount } }

  func load() throws -> Data? {
    try state.withLock { state in
      if let error = state.error { throw error }
      return state.data
    }
  }

  func save(_ data: Data) throws {
    try state.withLock { state in
      if let error = state.error { throw error }
      state.saveCount += 1
      state.data = data
    }
  }
}
