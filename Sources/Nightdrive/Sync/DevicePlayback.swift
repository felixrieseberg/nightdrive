import Foundation

struct DevicePlaybackReport: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    var dbid: UInt64
    var localURL: URL?
    var playCountDelta: Int
    var skipCountDelta: Int
    var lastPlayed: Date?
    var deviceRating: Int?
    var bookmarkMS: Int?
    var lastSkipped: Date?

    init(
      dbid: UInt64, localURL: URL? = nil, playCountDelta: Int = 0,
      skipCountDelta: Int = 0, lastPlayed: Date? = nil, deviceRating: Int? = nil,
      bookmarkMS: Int? = nil, lastSkipped: Date? = nil
    ) {
      self.dbid = dbid
      self.localURL = localURL
      self.playCountDelta = playCountDelta
      self.skipCountDelta = skipCountDelta
      self.lastPlayed = lastPlayed
      self.deviceRating = deviceRating
      self.bookmarkMS = bookmarkMS
      self.lastSkipped = lastSkipped
    }
  }

  var id: UUID = UUID()
  var databaseID: UInt64? = nil
  var entries: [Entry] = []
}

enum PendingPlaybackReportStore {
  static let filename = ".nightdrive-pending-plays.json"

  static func url(for libraryFolder: URL) -> URL {
    libraryFolder.appendingPathComponent(filename)
  }

  static func loadOutcome(libraryFolder: URL) -> AppDataLoadOutcome<DevicePlaybackReport> {
    SidecarJSONFile.loadOutcome(DevicePlaybackReport.self, at: url(for: libraryFolder))
  }

  static func load(libraryFolder: URL) throws -> DevicePlaybackReport? {
    try loadOutcome(libraryFolder: libraryFolder).unwrapIfPresent(
      url: url(for: libraryFolder),
      malformedRecoveryInstruction:
        "Restore a valid pending-play report before syncing; deleting it may double-count plays.")
  }

  static func save(_ report: DevicePlaybackReport, libraryFolder: URL) throws {
    try SidecarJSONFile.save(report, to: url(for: libraryFolder))
  }

  static func clear(libraryFolder: URL) {
    FileManager.default.bestEffortRemoveItem(at: url(for: libraryFolder))
  }
}

struct DevicePlaybackCollection: Sendable {
  var pending: DevicePlaybackReport?
  var parsed: [(dbid: UInt64, entry: PlayCountsFile.Entry)] = []
  var filesToDelete: [URL] = []
  var notes: [String] = []
}

extension SyncEngine {
  static func collectDevicePlayback(
    fileSystem fs: IpodFileSystem, database db: ITunesDatabase, libraryFolder: URL,
    pending: DevicePlaybackReport?
  ) -> DevicePlaybackCollection {
    var collection = DevicePlaybackCollection()
    let fm = FileManager.default
    let fileURL = PlayCountsFile.url(in: fs)
    if let pending {
      // Replay the durable report instead of double-counting device deltas.
      collection.pending = pending
      if pending.databaseID == db.databaseID, fm.fileExists(atPath: fileURL.path) {
        collection.filesToDelete.append(fileURL)
      }
      return collection
    }
    if fm.fileExists(atPath: fs.compressedDatabaseURL.path)
      || fm.fileExists(atPath: fs.sqliteLibraryDirectory.path)
    {
      return collection
    }
    guard let data = try? Data(contentsOf: fileURL) else { return collection }
    guard let entries = PlayCountsFile.parse(data, timezoneShift: db.timezoneShift) else {
      collection.notes.append(
        "Ignored a malformed Play Counts file on the iPod; it was left in place.")
      return collection
    }
    guard entries.count <= db.tracks.count else {
      collection.notes.append(
        "Ignored a Play Counts file that does not match the iPod's database; "
          + "it was left in place.")
      return collection
    }
    for (index, entry) in entries.enumerated() {
      collection.parsed.append((dbid: db.tracks[index].dbid, entry: entry))
    }
    collection.filesToDelete.append(fileURL)
    return collection
  }

  static func finalizeDevicePlaybackMerge(
    playCountsFiles: [URL], libraryFolder: URL, deviceVolume: URL, databaseID: UInt64?
  ) async {
    let pending: DevicePlaybackReport?
    do {
      pending = try PendingPlaybackReportStore.load(libraryFolder: libraryFolder)
    } catch {
      // A malformed report is the only remaining exactly-once token.
      return
    }
    var allRemoved = true
    if !playCountsFiles.isEmpty {
      guard
        let lock = try? await ScopedAdvisoryLock.acquire(
          for: deviceVolume, namespace: .device)
      else {
        return
      }
      defer { lock.unlock() }
      let itunesDir = IpodFileSystem(volumeURL: deviceVolume).itunesDir.standardizedFileURL
      for file in playCountsFiles {
        let standardized = file.standardizedFileURL
        guard
          standardized.deletingLastPathComponent().standardizedFileURL.path == itunesDir.path,
          standardized.lastPathComponent == PlayCountsFile.filename
        else { continue }
        FileManager.default.bestEffortRemoveItem(at: standardized)
        if FileManager.default.fileExists(atPath: standardized.path) { allRemoved = false }
      }
    }
    guard allRemoved else { return }
    if let pending, let owner = pending.databaseID, owner != databaseID {
      return
    }
    PendingPlaybackReportStore.clear(libraryFolder: libraryFolder)
  }
}
