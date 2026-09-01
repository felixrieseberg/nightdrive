import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Synchronization

struct TranscodeProfile: Hashable, Sendable {
  var bitrateKbps: Int = TranscodeSettings.defaultBitrateKbps

  var identifier: String { "aac-\(bitrateKbps)" }
  var fileExtension: String { "m4a" }
}

struct TranscodeSettings: Hashable, Sendable {
  static let defaultBitrateKbps = 256
  static let defaultCacheCeilingBytes: Int64 = 4 * 1024 * 1024 * 1024

  static let bitrateDefaultsKey = "transcodeBitrateKbps"
  static let cacheCeilingDefaultsKey = "transcodeCacheCeilingBytes"
  var bitrateKbps: Int = TranscodeSettings.defaultBitrateKbps
  var cacheCeilingBytes: Int64 = TranscodeSettings.defaultCacheCeilingBytes

  var aacProfile: TranscodeProfile {
    TranscodeProfile(bitrateKbps: bitrateKbps)
  }

  static func load(defaults: UserDefaults = NightdriveDefaults.current) -> TranscodeSettings {
    var settings = TranscodeSettings()
    if defaults.object(forKey: bitrateDefaultsKey) != nil {
      let stored = defaults.integer(forKey: bitrateDefaultsKey)
      if stored > 0 { settings.bitrateKbps = stored }
    }
    if defaults.object(forKey: cacheCeilingDefaultsKey) != nil {
      let stored = Int64(defaults.integer(forKey: cacheCeilingDefaultsKey))
      if stored > 0 { settings.cacheCeilingBytes = stored }
    }
    return settings
  }
}

enum TranscodeError: Error, LocalizedError {
  case noAudioTrack
  case encodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .noAudioTrack:
      String(localized: "The file contains no decodable audio track.")
    case .encodingFailed(let reason):
      String(localized: "The audio could not be converted: \(reason)")
    }
  }
}

enum TranscodeCacheInspectionOperation: Sendable {
  case enumerateDirectory
  case readMetadata(URL)
}

private enum TranscodeCacheInspectionError: Error, LocalizedError {
  case missingMetadata(URL, String)

  var errorDescription: String? {
    switch self {
    case .missingMetadata(let url, let field):
      String(
        localized:
          "The converted-audio cache could not read \(field) for \(url.lastPathComponent).")
    }
  }
}

protocol TranscodeEncoder: Sendable {
  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws
}

protocol TranscodeCacheMaintenance: Sendable {
  func totalSizeBytes() async throws -> Int64
  func clear() async throws
}

struct AVFoundationAACEncoder: TranscodeEncoder {
  let pumpDidReadSample: (@Sendable () -> Void)?

  init(pumpDidReadSample: (@Sendable () -> Void)? = nil) {
    self.pumpDidReadSample = pumpDidReadSample
  }

  func encode(
    source: URL, destination: URL, profile: TranscodeProfile,
    metadata: TrackMetadata, artwork: Data?
  ) async throws {
    var completed = false
    defer {
      if !completed { FileManager.default.bestEffortRemoveItem(at: destination) }
    }
    try Task.checkCancellation()
    let asset = AVURLAsset(url: source)
    guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
      throw TranscodeError.noAudioTrack
    }
    try Task.checkCancellation()
    var channels = 2
    var sampleRate = 44_100.0
    if let format = try await audioTrack.load(.formatDescriptions).first,
      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
    {
      if description.mChannelsPerFrame > 0 {
        channels = min(Int(description.mChannelsPerFrame), 2)
      }
      if description.mSampleRate > 0 {
        sampleRate = min(description.mSampleRate, 48_000)
      }
    }

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(
      track: audioTrack,
      outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
    guard reader.canAdd(readerOutput) else {
      throw TranscodeError.encodingFailed("The source audio cannot be decoded.")
    }
    reader.add(readerOutput)

    let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
    let input = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: channels,
        AVSampleRateKey: sampleRate,
        AVEncoderBitRateKey: profile.bitrateKbps * 1000,
      ])
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else {
      throw TranscodeError.encodingFailed("The AAC writer rejected the audio settings.")
    }
    writer.add(input)
    writer.metadata = Self.metadataItems(metadata, artwork: artwork)

    let pump = AACEncodingPump(
      reader: reader, output: readerOutput, writer: writer, input: input,
      didReadSample: pumpDidReadSample)
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await pump.run()
        try Task.checkCancellation()
      } onCancel: {
        pump.cancel()
      }
    } catch {
      pump.cancel()
      throw error
    }
    completed = true
  }

  static func metadataItems(_ metadata: TrackMetadata, artwork: Data?) -> [AVMetadataItem] {
    var items: [AVMetadataItem] = []
    func add(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?) {
      guard let value else { return }
      let item = AVMutableMetadataItem()
      item.identifier = identifier
      item.value = value
      items.append(item)
    }
    func text(_ string: String) -> NSString? {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed as NSString
    }
    func numberPair(_ index: Int, _ total: Int) -> NSData? {
      guard index > 0 || total > 0 else { return nil }
      var bytes: [UInt8] = [0, 0]
      bytes.append(contentsOf: [UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)])
      bytes.append(contentsOf: [UInt8((total >> 8) & 0xFF), UInt8(total & 0xFF)])
      bytes.append(contentsOf: [0, 0])
      return Data(bytes) as NSData
    }
    add(.iTunesMetadataSongName, text(metadata.title))
    add(.iTunesMetadataArtist, text(metadata.artist))
    add(.iTunesMetadataAlbum, text(metadata.album))
    add(.iTunesMetadataAlbumArtist, text(metadata.albumArtist))
    add(.iTunesMetadataUserGenre, text(metadata.genre))
    add(.iTunesMetadataComposer, text(metadata.composer))
    if let groupingID = AVMetadataItem.identifier(
      forKey: AVMetadataKey(rawValue: "\u{00A9}grp"), keySpace: .iTunes)
    {
      add(groupingID, text(metadata.grouping))
    }
    add(.iTunesMetadataUserComment, text(metadata.comment))
    add(.iTunesMetadataLyrics, text(metadata.lyrics))
    if metadata.year > 0 {
      add(.iTunesMetadataReleaseDate, String(metadata.year) as NSString)
    }
    if metadata.bpm > 0 {
      add(.iTunesMetadataBeatsPerMin, NSNumber(value: metadata.bpm))
    }
    if metadata.compilation {
      add(.iTunesMetadataDiscCompilation, NSNumber(value: 1))
    }
    add(.iTunesMetadataTrackNumber, numberPair(metadata.trackNumber, metadata.trackCount))
    add(.iTunesMetadataDiscNumber, numberPair(metadata.discNumber, metadata.discCount))
    if let artwork, !artwork.isEmpty {
      add(.iTunesMetadataCoverArt, artwork as NSData)
    }
    return items
  }
}

/// Owns the media pump and every AVFoundation call after setup, all on one
/// serial queue. Cancellation only flips a mutex-guarded flag before
/// enqueueing, so it never touches reader or writer while a sample operation
/// is in flight. `@unchecked Sendable` because the AVFoundation objects and
/// pump state are confined to that queue rather than protected by a lock.
private final class AACEncodingPump: @unchecked Sendable {
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let didReadSample: (@Sendable () -> Void)?
  private let queue = DispatchQueue(label: "nightdrive.transcode.pump")
  private let cancellationRequested = Mutex(false)
  private var continuation: CheckedContinuation<Void, any Error>?
  private var completed = false
  private var readerStarted = false
  private var writerStarted = false
  private var didInvokeReadHook = false

  init(
    reader: AVAssetReader, output: AVAssetReaderTrackOutput,
    writer: AVAssetWriter, input: AVAssetWriterInput,
    didReadSample: (@Sendable () -> Void)?
  ) {
    self.reader = reader
    self.output = output
    self.writer = writer
    self.input = input
    self.didReadSample = didReadSample
  }

  func run() async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        start(continuation)
      }
    }
  }

  func cancel() {
    cancellationRequested.withLock { $0 = true }
    // Only the transcode queue touches AVFoundation objects.
    queue.async { [self] in
      cancelOnQueue()
    }
  }

  private func start(_ continuation: CheckedContinuation<Void, any Error>) {
    precondition(self.continuation == nil && !completed)
    self.continuation = continuation
    if isCancellationRequested {
      cancelOnQueue()
      return
    }

    guard reader.startReading() else {
      fail(reader.error ?? TranscodeError.encodingFailed("The source could not be read."))
      return
    }
    readerStarted = true
    if isCancellationRequested {
      cancelOnQueue()
      return
    }

    guard writer.startWriting() else {
      fail(writer.error ?? TranscodeError.encodingFailed("The destination could not be written."))
      return
    }
    writerStarted = true
    if isCancellationRequested {
      cancelOnQueue()
      return
    }

    writer.startSession(atSourceTime: .zero)
    if isCancellationRequested {
      cancelOnQueue()
      return
    }
    input.requestMediaDataWhenReady(on: queue) { [self] in
      pumpAvailableMedia()
    }
  }

  private func pumpAvailableMedia() {
    guard !completed else { return }
    while input.isReadyForMoreMediaData {
      if isCancellationRequested {
        cancelOnQueue()
        return
      }
      guard let buffer = output.copyNextSampleBuffer() else {
        finishReading()
        return
      }
      if !didInvokeReadHook {
        didInvokeReadHook = true
        didReadSample?()
      }
      if isCancellationRequested {
        cancelOnQueue()
        return
      }
      guard input.append(buffer) else {
        fail(writer.error ?? TranscodeError.encodingFailed("Encoding stopped unexpectedly."))
        return
      }
      if isCancellationRequested {
        cancelOnQueue()
        return
      }
    }
  }

  private func finishReading() {
    if isCancellationRequested {
      cancelOnQueue()
      return
    }
    if reader.status == .failed {
      fail(reader.error ?? TranscodeError.encodingFailed("Decoding stopped unexpectedly."))
      return
    }
    input.markAsFinished()
    if isCancellationRequested {
      cancelOnQueue()
      return
    }
    writer.finishWriting { [self] in
      queue.async { [self] in
        finishWritingDidComplete()
      }
    }
  }

  private func finishWritingDidComplete() {
    guard !completed else { return }
    if isCancellationRequested {
      cancelOnQueue()
      return
    }
    guard writer.status == .completed else {
      fail(writer.error ?? TranscodeError.encodingFailed("Encoding did not complete."))
      return
    }
    complete(with: .success(()))
  }

  private func cancelOnQueue() {
    guard !completed, continuation != nil else { return }
    if readerStarted { reader.cancelReading() }
    if writerStarted { writer.cancelWriting() }
    complete(with: .failure(CancellationError()))
  }

  private func fail(_ error: any Error) {
    if readerStarted { reader.cancelReading() }
    if writerStarted { writer.cancelWriting() }
    complete(with: .failure(error))
  }

  private func complete(with result: Result<Void, any Error>) {
    guard !completed, let continuation else { return }
    completed = true
    self.continuation = nil
    continuation.resume(with: result)
  }

  private var isCancellationRequested: Bool {
    cancellationRequested.withLock { $0 }
  }
}

struct TranscodeCache: Sendable {
  static let directoryEnvironmentKey = "NIGHTDRIVE_TRANSCODE_CACHE"
  /// Where private transcodes are staged while a caller reads them. Every
  /// process on the machine shares one root by default, which is what makes a
  /// handoff left by a crash recoverable at all — but it also means any
  /// process may reclaim a *dead* one. Automated runs that assert on that
  /// reclamation, and worktrees verifying side by side, point this at a
  /// directory of their own so they cannot sweep each other's handoffs.
  static let handoffRootEnvironmentKey = "NIGHTDRIVE_TRANSCODE_HANDOFF_ROOT"

  let directory: URL
  let encoder: (any TranscodeEncoder)?
  let inspectionHook: (@Sendable (TranscodeCacheInspectionOperation) throws -> Void)?
  let handoffRoot: URL?

  init(
    directory: URL? = nil,
    encoder: (any TranscodeEncoder)? = nil,
    inspectionHook: (@Sendable (TranscodeCacheInspectionOperation) throws -> Void)? = nil,
    handoffRoot: URL? = nil
  ) {
    self.directory =
      directory
      ?? Self.defaultDirectory(environment: ProcessInfo.processInfo.environment)
    self.encoder = encoder
    self.inspectionHook = inspectionHook
    self.handoffRoot = handoffRoot
  }

  static func defaultDirectory(environment: [String: String]) -> URL {
    CacheDirectory.resolve(
      environment: environment, overrideKey: directoryEnvironmentKey,
      subdirectory: "Nightdrive/TranscodeCache")
  }

  func cachedFileURL(sourceHash: String, profile: TranscodeProfile) -> URL {
    directory.appendingPathComponent(
      "\(sourceHash)-\(profile.identifier).\(profile.fileExtension)")
  }

  func withTranscodedFile<Result>(
    source: URL,
    sourceHash: String,
    profile: TranscodeProfile,
    metadata: TrackMetadata,
    artwork: Data?,
    settings: TranscodeSettings = TranscodeSettings(),
    consume: (URL) async throws -> Result
  ) async throws -> Result {
    let privateFile = try await preparePrivateTranscodedFile(
      source: source, sourceHash: sourceHash, profile: profile,
      metadata: metadata, artwork: artwork)
    defer { privateFile.remove() }

    let result: Result
    do {
      result = try await consume(privateFile.url)
    } catch let consumeError {
      await evictLoggingFailure(ceilingBytes: settings.cacheCeilingBytes)
      throw consumeError
    }
    await evictLoggingFailure(ceilingBytes: settings.cacheCeilingBytes)
    return result
  }

  /// Produces a caller-owned immutable transcode that remains valid until the
  /// returned handoff is released. Sync uses this to prepare files ahead of
  /// the single serialized device writer.
  func prepareTranscodedFile(
    source: URL,
    sourceHash: String,
    profile: TranscodeProfile,
    metadata: TrackMetadata,
    artwork: Data?,
    settings: TranscodeSettings = TranscodeSettings()
  ) async throws -> TranscodeHandoff {
    let privateFile = try await preparePrivateTranscodedFile(
      source: source, sourceHash: sourceHash, profile: profile,
      metadata: metadata, artwork: artwork)
    await evictLoggingFailure(ceilingBytes: settings.cacheCeilingBytes)
    return privateFile
  }

  /// Cache eviction is best-effort housekeeping: a failure must not fail the
  /// transcode that triggered it, but it leaves the cache over its ceiling.
  private func evictLoggingFailure(ceilingBytes: Int64) async {
    do {
      try await evict(ceilingBytes: ceilingBytes)
    } catch {
      NightdriveLog.transcode.error(
        "Transcode cache eviction failed; the cache may exceed its ceiling: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private enum CacheLookup {
    case hit
    case miss(generation: String)
  }

  private func preparePrivateTranscodedFile(
    source: URL,
    sourceHash: String,
    profile: TranscodeProfile,
    metadata: TrackMetadata,
    artwork: Data?
  ) async throws -> TranscodeHandoff {
    let fm = FileManager.default
    let cached = cachedFileURL(sourceHash: sourceHash, profile: profile)
    let keyLock = try await ScopedAdvisoryLock.acquire(for: cached, namespace: .transcodeKey)
    var handoff: TranscodeHandoff?
    do {
      let privateFile = try TranscodeHandoff.create(
        fileExtension: profile.fileExtension, rootDirectory: handoffRoot)
      handoff = privateFile
      let temporary = privateFile.directory
      let snapshot = privateFile.url
      let lookup = try await withCacheLock {
        let generation = try cacheGeneration(fileManager: fm)
        if fm.fileExists(atPath: cached.path) {
          do {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: cached.path)
          } catch {
            NightdriveLog.transcode.debug(
              "Could not refresh cache-entry recency: \(error.localizedDescription, privacy: .public)"
            )
          }
          try cloneOrCopyItem(at: cached, to: snapshot, fileManager: fm)
          return CacheLookup.hit
        }
        return CacheLookup.miss(generation: generation)
      }

      guard case .miss(let initialGeneration) = lookup else {
        keyLock.unlock()
        return privateFile
      }

      let encoded = temporary.appendingPathComponent(
        "encoded.\(profile.fileExtension)")
      try await (encoder ?? AVFoundationAACEncoder()).encode(
        source: source, destination: encoded, profile: profile,
        metadata: metadata, artwork: artwork)
      guard fm.fileExists(atPath: encoded.path) else {
        throw TranscodeError.encodingFailed("The encoder produced no output file.")
      }

      try await withCacheLock {
        if try cacheGeneration(fileManager: fm) == initialGeneration {
          try publish(encoded, as: cached, fileManager: fm)
          try cloneOrCopyItem(at: cached, to: snapshot, fileManager: fm)
        } else {
          try fm.moveItem(at: encoded, to: snapshot)
        }
      }
      keyLock.unlock()
      return privateFile
    } catch {
      keyLock.unlock()
      handoff?.remove()
      throw error
    }
  }

  private func publish(_ encoded: URL, as cached: URL, fileManager fm: FileManager) throws {
    if fm.fileExists(atPath: cached.path) { return }
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let working = directory.appendingPathComponent(
      "encoding-\(UUID().uuidString).\(cached.pathExtension)")
    do {
      try cloneOrCopyItem(at: encoded, to: working, fileManager: fm)
      try fm.moveItem(at: working, to: cached)
    } catch {
      fm.bestEffortRemoveItem(at: working)
      throw error
    }
  }

  private func cloneOrCopyItem(at source: URL, to destination: URL, fileManager fm: FileManager)
    throws
  {
    if Darwin.clonefile(source.path, destination.path, 0) == 0 { return }
    if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
    try fm.copyItem(at: source, to: destination)
  }

  private var generationURL: URL {
    directory.appendingPathComponent(".generation")
  }

  private func cacheGeneration(fileManager fm: FileManager) throws -> String {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    if fm.fileExists(atPath: generationURL.path),
      let generation = String(data: try Data(contentsOf: generationURL), encoding: .utf8),
      !generation.isEmpty
    {
      return generation
    }
    return try advanceCacheGeneration(fileManager: fm)
  }

  @discardableResult
  private func advanceCacheGeneration(fileManager fm: FileManager) throws -> String {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    let generation = UUID().uuidString
    try Data(generation.utf8).write(to: generationURL, options: .atomic)
    return generation
  }

  private func withCacheLock<Result>(_ body: () throws -> Result) async throws -> Result {
    let lock = try await ScopedAdvisoryLock.acquire(
      for: directory, namespace: .transcodeCache)
    do {
      let result = try body()
      lock.unlock()
      return result
    } catch {
      lock.unlock()
      throw error
    }
  }

  func totalSizeBytes() async throws -> Int64 {
    try await withCacheLock {
      try entries().reduce(0) { $0 + $1.size }
    }
  }

  func clear() async throws {
    try await withCacheLock {
      let fm = FileManager.default
      if fm.fileExists(atPath: directory.path) {
        for url in try cacheFileURLs(includeWorkingFiles: true) {
          try fm.removeItem(at: url)
        }
      }
      try advanceCacheGeneration(fileManager: fm)
    }
  }

  private struct Entry {
    let url: URL
    let size: Int64
    let modified: Date
  }

  private func entries() throws -> [Entry] {
    try cacheFileURLs(includeWorkingFiles: false).map { url in
      try inspectionHook?(.readMetadata(url))
      let values = try url.resourceValues(forKeys: [
        .fileSizeKey, .contentModificationDateKey, .isRegularFileKey,
      ])
      guard values.isRegularFile == true else {
        throw TranscodeCacheInspectionError.missingMetadata(url, "its file type")
      }
      guard let size = values.fileSize else {
        throw TranscodeCacheInspectionError.missingMetadata(url, "its size")
      }
      guard let modified = values.contentModificationDate else {
        throw TranscodeCacheInspectionError.missingMetadata(url, "its modification date")
      }
      return Entry(url: url, size: Int64(size), modified: modified)
    }
  }

  private func cacheFileURLs(includeWorkingFiles: Bool) throws -> [URL] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return [] }
    try inspectionHook?(.enumerateDirectory)
    let contents = try fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    var files: [URL] = []
    for url in contents {
      let recognized =
        Self.isPublishedCacheName(url.lastPathComponent)
        || includeWorkingFiles && Self.isWorkingName(url.lastPathComponent)
      guard recognized else { continue }
      try inspectionHook?(.readMetadata(url))
      let values = try url.resourceValues(forKeys: [.isRegularFileKey])
      guard let isRegularFile = values.isRegularFile else {
        throw TranscodeCacheInspectionError.missingMetadata(url, "its file type")
      }
      if isRegularFile { files.append(url) }
    }
    return files
  }

  private static func isPublishedCacheName(_ name: String) -> Bool {
    name.range(
      of: #"^[0-9A-Fa-f]{64}-aac-[0-9]+\.m4a$"#,
      options: .regularExpression) != nil
  }

  private static func isWorkingName(_ name: String) -> Bool {
    let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, parts[1] == "m4a",
      parts[0].hasPrefix("encoding-")
    else { return false }
    return UUID(uuidString: String(parts[0].dropFirst("encoding-".count))) != nil
  }

  private func evict(ceilingBytes: Int64) async throws {
    try await withCacheLock {
      var all = try entries().sorted { $0.modified < $1.modified }
      var total = all.reduce(Int64(0)) { $0 + $1.size }
      while total > ceilingBytes, !all.isEmpty {
        let oldest = all.removeFirst()
        try FileManager.default.removeItem(at: oldest.url)
        total -= oldest.size
      }
    }
  }
}

extension TranscodeCache: TranscodeCacheMaintenance {}

/// A caller-private transcode directory that lives only as long as its owner.
/// PID-prefixed UUID names isolate concurrent app and CLI processes and let a
/// later process reclaim only directories whose owner is gone.
final class TranscodeHandoff: Sendable {
  private static let rootComponents = ["Nightdrive", "TranscodeHandoffs"]

  /// Overridable so concurrent test processes cannot scavenge each other's
  /// handoff directories.
  static func rootDirectory(fileManager fm: FileManager = .default) -> URL {
    // `getenv` rather than `ProcessInfo`, which snapshots the environment and
    // would not see a test's `setenv`.
    if let raw = Darwin.getenv(TranscodeCache.handoffRootEnvironmentKey),
      case let override = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines),
      !override.isEmpty
    {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return rootComponents.reduce(fm.temporaryDirectory) {
      $0.appendingPathComponent($1, isDirectory: true)
    }
  }

  let url: URL
  let directory: URL

  private let removed = Mutex(false)

  static func create(
    fileExtension: String, rootDirectory: URL? = nil
  ) throws -> TranscodeHandoff {
    let fm = FileManager.default
    let root = try prepareRoot(rootDirectory: rootDirectory, fileManager: fm)
    try scavenge(in: root, fileManager: fm)
    let directory = root.appendingPathComponent(
      "\(Darwin.getpid())-\(UUID().uuidString)", isDirectory: true)
    do {
      try fm.createDirectory(at: directory, withIntermediateDirectories: false)
      try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      try Task.checkCancellation()
      return TranscodeHandoff(
        directory: directory,
        url: directory.appendingPathComponent("transcoded.\(fileExtension)"))
    } catch {
      fm.bestEffortRemoveItem(at: directory)
      throw error
    }
  }

  private init(directory: URL, url: URL) {
    self.directory = directory
    self.url = url
  }

  func remove() {
    removed.withLock { removed in
      guard !removed else { return }
      removed = true
      FileManager.default.bestEffortRemoveItem(at: directory)
    }
  }

  deinit { remove() }

  private static func prepareRoot(
    rootDirectory: URL?, fileManager fm: FileManager
  ) throws -> URL {
    let root = rootDirectory ?? self.rootDirectory(fileManager: fm)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let descriptor = Darwin.open(
      root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw posixError() }
    defer { Darwin.close(descriptor) }

    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_uid == Darwin.geteuid(),
      Darwin.fchmod(descriptor, 0o700) == 0
    else {
      throw TranscodeError.encodingFailed("The private transcode directory is invalid.")
    }
    return root
  }

  private static func scavenge(in root: URL, fileManager fm: FileManager) throws {
    let candidates = try fm.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    for candidate in candidates {
      let parts = candidate.lastPathComponent.split(
        separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2, let owner = pid_t(parts[0]), owner > 0,
        let identifier = UUID(uuidString: String(parts[1])),
        identifier.uuidString == String(parts[1]), owner != Darwin.getpid(),
        let values = try? candidate.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]),
        values.isDirectory == true, values.isSymbolicLink != true
      else { continue }

      errno = 0
      if Darwin.kill(owner, 0) == 0 || errno == EPERM { continue }
      guard errno == ESRCH else { continue }
      fm.bestEffortRemoveItem(at: candidate)
    }
  }
}

struct TranscodeContext: Sendable {
  var settings = TranscodeSettings()
  var cache = TranscodeCache()
}
