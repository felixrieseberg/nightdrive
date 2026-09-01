import Foundation

enum DatabaseRepair {
  typealias DatabaseWriter =
    @Sendable (
      _ fileSystem: IpodFileSystem, _ database: ITunesDatabase, _ format: IpodDatabaseFormat
    ) throws -> Void

  /// Narrow filesystem seam for proving repair fails closed when it cannot
  /// establish the complete set of audio files on the device.
  struct AudioFileAccess: Sendable {
    struct ItemInfo: Sendable {
      let isDirectory: Bool
      let isRegularFile: Bool
      let isSymbolicLink: Bool
    }

    var contentsOfDirectory: @Sendable (URL) throws -> [URL]
    var itemInfo: @Sendable (URL) throws -> ItemInfo?

    static let live = AudioFileAccess(
      contentsOfDirectory: {
        try FileManager.default.contentsOfDirectory(
          at: $0, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      },
      itemInfo: {
        do {
          let values = try $0.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ])
          return ItemInfo(
            isDirectory: values.isDirectory == true,
            isRegularFile: values.isRegularFile == true,
            isSymbolicLink: values.isSymbolicLink == true)
        } catch CocoaError.fileNoSuchFile {
          return nil
        } catch CocoaError.fileReadNoSuchFile {
          return nil
        }
      })
  }

  struct Outcome: Equatable, Sendable {
    var tracksKept = 0
    var tracksRecovered = 0
    var tracksDropped = 0
    var source: Source = .database

    enum Source: Equatable, Sendable {
      case database
      case backup
      case filesOnly
    }

    var summary: String {
      var parts = [
        tracksKept == 1
          ? String(localized: "Kept 1 track") : String(localized: "Kept \(tracksKept) tracks")
      ]
      if tracksRecovered > 0 {
        parts.append(String(localized: "recovered \(tracksRecovered) from the device's files"))
      }
      if tracksDropped > 0 {
        parts.append(String(localized: "dropped \(tracksDropped) whose files are gone"))
      }
      switch source {
      case .database: break
      case .backup: parts.append(String(localized: "started from Nightdrive's database backup"))
      case .filesOnly: parts.append(String(localized: "rebuilt entirely from the files"))
      }
      let joined = parts.joined(separator: ", ")
      return String(localized: "\(joined).")
    }
  }

  static func rebuild(deviceVolume: URL) async throws -> Outcome {
    try await rebuild(
      deviceVolume: deviceVolume,
      databaseWriter: { fileSystem, database, format in
        try fileSystem.writeDatabase(database, preflightedFormat: format)
      })
  }

  /// Test seams for filesystem inspection and failures after a corrupt live
  /// database has been quarantined but before the repaired generation is
  /// committed.
  static func rebuild(
    deviceVolume: URL, databaseWriter: DatabaseWriter,
    audioFileAccess: AudioFileAccess = .live
  ) async throws -> Outcome {
    guard IpodFileSystem.isIpodVolume(deviceVolume) else {
      throw ITunesDBError.notFound("This folder does not look like an iPod")
    }
    let deviceLock = try await ScopedAdvisoryLock.acquire(
      for: deviceVolume, namespace: .device)
    defer { deviceLock.unlock() }

    let fs = IpodFileSystem(volumeURL: deviceVolume)
    try fs.validateITunesDirectory()
    let fm = FileManager.default

    // Complete the read-only device-file inventory before any recovery or
    // repair-owned mutation. In particular, pending nano and shuffle recovery
    // may replace database artifacts, so an incomplete Music traversal must
    // fail before either recovery path runs.
    let files = try audioFiles(fileSystem: fs, access: audioFileAccess)

    // Start from the best surviving database: the live one, else the
    // backup Nightdrive keeps beside it, else nothing.
    var outcome = Outcome()
    var db: ITunesDatabase
    let format: IpodDatabaseFormat
    let databaseSupport = IpodDatabaseSupport(fileSystem: fs)
    let preparedNanoFormat = try databaseSupport.prepareNanoForRepairIfNeeded()
    _ = try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs)
    if let live = try? fs.readDatabaseWithoutRecovery() {
      db = live
      outcome.source = .database
      if let preparedNanoFormat {
        format = preparedNanoFormat
      } else {
        format = try databaseSupport.formatForWriting()
      }
    } else if let data = try? Data(contentsOf: fs.databaseBackupURL),
      let backup = try? ITunesDBReader().read(data)
    {
      db = backup
      outcome.source = .backup
      if let preparedNanoFormat {
        format = preparedNanoFormat
      } else {
        format = try databaseSupport.formatForWriting(candidateDatabaseData: data)
      }
    } else {
      db = ITunesDatabase()
      outcome.source = .filesOnly
      if let preparedNanoFormat {
        format = preparedNanoFormat
      } else {
        format = try databaseSupport.formatForWriting(candidateDatabaseData: nil)
      }
    }

    let presentPaths = Set(files.map { fs.ipodPath(for: $0) })

    var keptRows: [ITDBTrack] = []
    for track in db.tracks {
      if let path = track.ipodPath, presentPaths.contains(path) {
        keptRows.append(track)
      } else {
        outcome.tracksDropped += 1
      }
    }
    outcome.tracksKept = keptRows.count

    let referenced = Set(keptRows.compactMap(\.ipodPath))
    let orphaned = files.filter { !referenced.contains(fs.ipodPath(for: $0)) }
      .sorted { $0.path < $1.path }
    let recovered = await LibraryStore.loadTracks(at: orphaned)
    for track in recovered {
      keptRows.append(SyncEngine.makeDBTrack(from: track, ipodPath: fs.ipodPath(for: track.url)))
      outcome.tracksRecovered += 1
    }

    db.tracks = keptRows
    let survivors = Set(keptRows.map(\.dbid))
    for index in db.playlists.indices {
      db.playlists[index].memberDbids.removeAll { !survivors.contains($0) }
    }

    var quarantine: URL?
    if outcome.source != .database, fm.fileExists(atPath: fs.databaseURL.path) {
      let url = availableQuarantineURL(fileSystem: fs)
      try fm.moveItem(at: fs.databaseURL, to: url)
      quarantine = url
    }
    do {
      try databaseWriter(fs, db, format)
    } catch {
      let repairError = error
      if let quarantine {
        do {
          try restoreQuarantine(quarantine, fileSystem: fs)
        } catch {
          throw DatabaseRepairError.rollbackFailed(
            operation: repairError, rollback: error, quarantine: quarantine)
        }
      }
      throw repairError
    }
    return outcome
  }

  private static func availableQuarantineURL(fileSystem fs: IpodFileSystem) -> URL {
    let preferred = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    guard FileManager.default.fileExists(atPath: preferred.path) else { return preferred }
    return fs.itunesDir.appendingPathComponent("iTunesDB.corrupt-\(UUID().uuidString)")
  }

  private static func restoreQuarantine(_ quarantine: URL, fileSystem fs: IpodFileSystem) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: fs.databaseURL.path) {
      _ = try fm.replaceItemAt(fs.databaseURL, withItemAt: quarantine)
    } else {
      try fm.moveItem(at: quarantine, to: fs.databaseURL)
    }
  }

  /// Every audio file in the existing FNN music folders. Unlike sync's folder
  /// helper this is strictly read-only and propagates every relevant listing
  /// and metadata error before repair is allowed to mutate database artifacts.
  private static func audioFiles(
    fileSystem fs: IpodFileSystem, access: AudioFileAccess
  ) throws -> [URL] {
    let extensions: Set<String> = ["mp3", "m4a", "m4b", "m4p", "aac", "wav", "aif", "aiff"]
    guard let musicInfo = try access.itemInfo(fs.musicDir) else { return [] }
    guard musicInfo.isDirectory, !musicInfo.isSymbolicLink else {
      throw ITunesDBError.notFound("iPod_Control/Music must be a regular directory")
    }
    let volumeRoot = fs.volumeURL.resolvingSymlinksInPath().standardizedFileURL
    let musicRoot = fs.musicDir.resolvingSymlinksInPath().standardizedFileURL
    guard musicRoot.isContained(in: volumeRoot, allowRoot: false) else {
      throw ITunesDBError.notFound("iPod_Control/Music is outside the iPod volume")
    }

    var folders: [URL] = []
    for candidate in try access.contentsOfDirectory(fs.musicDir) {
      guard isIpodMusicFolderName(candidate.lastPathComponent) else { continue }
      guard let info = try access.itemInfo(candidate), info.isDirectory,
        !info.isSymbolicLink
      else {
        throw ITunesDBError.notFound(
          "Invalid music directory \(candidate.lastPathComponent)")
      }
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.isContained(in: musicRoot, allowRoot: false) else {
        throw ITunesDBError.notFound(
          "Music directory \(candidate.lastPathComponent) is outside iPod_Control/Music")
      }
      folders.append(candidate)
    }

    var files: [URL] = []
    for folder in folders.sorted(by: { $0.path < $1.path }) {
      let entries = try access.contentsOfDirectory(folder)
      for url in entries where extensions.contains(url.pathExtension.lowercased()) {
        guard let info = try access.itemInfo(url), info.isRegularFile,
          !info.isSymbolicLink
        else {
          throw ITunesDBError.notFound(
            "Invalid audio file \(url.lastPathComponent) in \(folder.lastPathComponent)")
        }
        files.append(url)
      }
    }
    return files.sorted { $0.path < $1.path }
  }
}

enum DatabaseRepairError: LocalizedError {
  case rollbackFailed(operation: Error, rollback: Error, quarantine: URL)

  var errorDescription: String? {
    switch self {
    case .rollbackFailed(let operation, let rollback, let quarantine):
      return String(
        localized:
          "The iPod database could not be repaired (\(operation.localizedDescription)), and the original database could not be restored from \(quarantine.path) (\(rollback.localizedDescription))."
      )
    }
  }
}
