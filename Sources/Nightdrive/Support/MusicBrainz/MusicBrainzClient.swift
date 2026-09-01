import Foundation

enum MusicBrainzError: Error, LocalizedError, Equatable {
  case consentNotGranted
  case emptyQuery
  case requestFailed(statusCode: Int)
  case malformedResponse(String)

  var errorDescription: String? {
    switch self {
    case .consentNotGranted:
      return String(
        localized:
          "Online metadata lookups are turned off. Enable them in Settings → Online first.")
    case .emptyQuery:
      return String(
        localized:
          "There isn't enough tagged metadata to search with. Add an artist or title first.")
    case .requestFailed(let statusCode):
      return String(
        localized: "MusicBrainz answered with HTTP \(statusCode). Try again in a moment.")
    case .malformedResponse(let details):
      return details
    }
  }
}

protocol MusicBrainzService: Sendable {
  func searchRecordings(
    title: String, artist: String, album: String
  ) async throws -> [MusicBrainzRecordingCandidate]

  func searchReleases(
    artist: String, releaseTitle: String
  ) async throws -> [MusicBrainzReleaseCandidate]

  func release(withID id: String) async throws -> MusicBrainzRelease

  /// The canonical genre names MusicBrainz separates from unrestricted
  /// folksonomy tags. The text endpoint returns the complete list in one
  /// rate-limited request.
  func genreNames() async throws -> Set<String>
}

protocol MusicBrainzTransport: Sendable {
  func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: MusicBrainzTransport {}

/// The clock the client paces requests with. Injectable so tests can drive
/// the rate limiter deterministically instead of racing wall-clock sleeps.
protocol MusicBrainzClock: Sendable {
  var now: ContinuousClock.Instant { get }
  func sleep(until instant: ContinuousClock.Instant) async throws
}

extension ContinuousClock: MusicBrainzClock {
  func sleep(until instant: Instant) async throws {
    try await sleep(until: instant, tolerance: nil)
  }
}

actor MusicBrainzClient: MusicBrainzService {
  static let defaultMinimumInterval: Duration = .seconds(1)
  static let defaultRequestTimeout: TimeInterval = 30
  static let defaultServiceUnavailableRetryCount = 2
  static let maximumRetryAfterDelay: TimeInterval = 60

  private let transport: any MusicBrainzTransport
  private let consent: @Sendable () async -> OnlineServicesConsent
  private let minimumInterval: Duration
  private let requestTimeout: TimeInterval
  private let serviceUnavailableRetryCount: Int
  private let clock: any MusicBrainzClock
  private var nextRequestSlot: ContinuousClock.Instant?
  private var requestEmbargoUntil: ContinuousClock.Instant?
  private var cachedGenreNames: Set<String>?

  static let userAgent: String = {
    let info = Bundle.main.infoDictionary
    let version = (info?["CFBundleShortVersionString"] as? String) ?? "0.0"
    return "Nightdrive/\(version) (\(AppLinks.repository.absoluteString))"
  }()

  init(
    consent: @escaping @Sendable () async -> OnlineServicesConsent,
    transport: any MusicBrainzTransport = URLSession.shared,
    minimumInterval: Duration = MusicBrainzClient.defaultMinimumInterval,
    requestTimeout: TimeInterval = MusicBrainzClient.defaultRequestTimeout,
    serviceUnavailableRetryCount: Int = MusicBrainzClient.defaultServiceUnavailableRetryCount,
    clock: any MusicBrainzClock = ContinuousClock()
  ) {
    precondition(requestTimeout.isFinite && requestTimeout > 0)
    precondition(serviceUnavailableRetryCount >= 0)
    self.consent = consent
    self.transport = transport
    self.minimumInterval = minimumInterval
    self.requestTimeout = requestTimeout
    self.serviceUnavailableRetryCount = serviceUnavailableRetryCount
    self.clock = clock
  }

  func searchRecordings(
    title: String, artist: String, album: String
  ) async throws -> [MusicBrainzRecordingCandidate] {
    let data = try await search(
      path: "recording",
      terms: [term("recording", title), term("artist", artist), term("release", album)])
    return try MusicBrainzParser.recordingCandidates(from: data)
  }

  func searchReleases(
    artist: String, releaseTitle: String
  ) async throws -> [MusicBrainzReleaseCandidate] {
    let data = try await search(
      path: "release",
      terms: [term("release", releaseTitle), term("artist", artist)])
    return try MusicBrainzParser.releaseCandidates(from: data)
  }

  func release(withID id: String) async throws -> MusicBrainzRelease {
    guard Self.isValidMBID(id) else {
      throw MusicBrainzError.malformedResponse(
        "MusicBrainz returned a release ID that isn't a valid MBID: '\(id)'.")
    }
    let data = try await get(
      path: "release/\(id)",
      queryItems: [URLQueryItem(name: "inc", value: "recordings+artist-credits")])
    return try MusicBrainzParser.release(from: data)
  }

  func genreNames() async throws -> Set<String> {
    if let cachedGenreNames { return cachedGenreNames }
    let data = try await get(path: "genre/all", queryItems: [], format: "txt")
    guard let body = String(data: data, encoding: .utf8) else {
      throw MusicBrainzError.malformedResponse("MusicBrainz returned an unreadable genre list.")
    }
    let names = Set(
      body.split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty })
    guard !names.isEmpty else {
      throw MusicBrainzError.malformedResponse("MusicBrainz returned an empty genre list.")
    }
    cachedGenreNames = names
    return names
  }

  static func isValidMBID(_ id: String) -> Bool {
    UUID(uuidString: id) != nil
  }

  private func term(_ field: String, _ value: String) -> String? {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return "\(field):\(luceneQuoted(value))"
  }

  private func search(path: String, terms: [String?]) async throws -> Data {
    let terms = terms.compactMap { $0 }
    guard !terms.isEmpty else { throw MusicBrainzError.emptyQuery }
    return try await get(
      path: path,
      queryItems: [
        URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
        URLQueryItem(name: "limit", value: "25"),
      ])
  }

  // MARK: - Request plumbing

  private func get(
    path: String, queryItems: [URLQueryItem], format: String = "json"
  ) async throws -> Data {
    guard await consent() == .enabled else { throw MusicBrainzError.consentNotGranted }

    guard var components = URLComponents(string: "https://musicbrainz.org/ws/2/\(path)") else {
      throw MusicBrainzError.malformedResponse(
        "Could not form a MusicBrainz request URL for '\(path)'.")
    }
    components.queryItems = queryItems + [URLQueryItem(name: "fmt", value: format)]
    guard let url = components.url else {
      throw MusicBrainzError.malformedResponse(
        "Could not form a MusicBrainz request URL for '\(path)'.")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = requestTimeout
    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue(
      format == "txt" ? "text/plain" : "application/json",
      forHTTPHeaderField: "Accept")

    var unavailableRetries = 0
    while true {
      try await waitForPermittedRequestSlot()
      let (data, response) = try await transport.data(for: request)
      guard let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      else {
        return data
      }

      guard http.statusCode == 503, unavailableRetries < serviceUnavailableRetryCount else {
        throw MusicBrainzError.requestFailed(statusCode: http.statusCode)
      }
      unavailableRetries += 1
      let retryDelay: Duration
      if http.value(forHTTPHeaderField: "Retry-After") != nil {
        guard let parsedDelay = Self.retryDelay(from: http) else {
          throw MusicBrainzError.requestFailed(statusCode: http.statusCode)
        }
        retryDelay = parsedDelay
      } else {
        retryDelay = minimumInterval
      }
      postponeRequests(by: retryDelay)
    }
  }

  static func retryDelay(from response: HTTPURLResponse, now: Date = Date()) -> Duration? {
    guard
      let value = response.value(forHTTPHeaderField: "Retry-After")?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else { return nil }

    if value.utf8.allSatisfy({ (48...57).contains($0) }),
      let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0,
      seconds <= maximumRetryAfterDelay
    {
      return .seconds(seconds)
    }

    for format in [
      "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
      "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
      "EEE MMM d HH':'mm':'ss yyyy",
    ] {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        let seconds = max(0, date.timeIntervalSince(now))
        guard seconds <= maximumRetryAfterDelay else { return nil }
        return .seconds(seconds)
      }
    }
    return nil
  }

  private func waitForPermittedRequestSlot() async throws {
    while true {
      let now = clock.now
      let slot: ContinuousClock.Instant
      if let next = nextRequestSlot, next > now {
        slot = next
      } else {
        slot = now
      }
      nextRequestSlot = slot.advanced(by: minimumInterval)
      try await clock.sleep(until: slot)

      guard await consent() == .enabled else { throw MusicBrainzError.consentNotGranted }
      guard let requestEmbargoUntil, requestEmbargoUntil > clock.now else { return }
    }
  }

  private func postponeRequests(by delay: Duration) {
    let retrySlot = clock.now.advanced(by: delay)
    requestEmbargoUntil = max(requestEmbargoUntil ?? retrySlot, retrySlot)
    if let nextRequestSlot, nextRequestSlot >= retrySlot {
      return
    } else {
      nextRequestSlot = retrySlot
    }
  }

  private func luceneQuoted(_ value: String) -> String {
    let escaped =
      value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }
}
