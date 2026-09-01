import Darwin
import Foundation

/// Runs a best-effort durability sync whose failure must not abort the caller
/// (FAT-formatted iPod volumes commonly reject directory fsyncs), recording
/// the failure for diagnosis.
private func bestEffortSynchronize(_ context: String, _ operation: () throws -> Void) {
  do {
    try operation()
  } catch {
    NightdriveLog.ipodFS.info(
      "Best-effort synchronize failed (\(context, privacy: .public)): \(error.localizedDescription, privacy: .public)"
    )
  }
}

func isIpodMusicFolderName(_ name: String) -> Bool {
  let bytes = name.utf8
  return bytes.count == 3
    && bytes.first == UInt8(ascii: "F")
    && bytes.dropFirst().allSatisfy { UInt8(ascii: "0")...UInt8(ascii: "9") ~= $0 }
}

struct IpodFileSystem {
  let volumeURL: URL

  var controlDir: URL { volumeURL.appendingPathComponent("iPod_Control", isDirectory: true) }
  var musicDir: URL { controlDir.appendingPathComponent("Music", isDirectory: true) }
  var itunesDir: URL { controlDir.appendingPathComponent("iTunes", isDirectory: true) }
  var databaseURL: URL { itunesDir.appendingPathComponent("iTunesDB") }
  var databaseBackupURL: URL { itunesDir.appendingPathComponent("iTunesDB.nightdrive.bak") }
  var shuffleDatabaseURL: URL { itunesDir.appendingPathComponent("iTunesSD") }
  var shuffleDatabaseBackupURL: URL {
    itunesDir.appendingPathComponent("iTunesSD.nightdrive.bak")
  }
  var shuffleDatabaseBackupStagingURL: URL {
    itunesDir.appendingPathComponent(".nightdrive-iTunesSD-backup.next")
  }
  var compressedDatabaseURL: URL { itunesDir.appendingPathComponent("iTunesCDB") }
  var sqliteLibraryDirectory: URL {
    itunesDir.appendingPathComponent("iTunes Library.itlp", isDirectory: true)
  }
  var sysInfoURL: URL { controlDir.appendingPathComponent("Device/SysInfo") }
  var sysInfoExtendedURL: URL { controlDir.appendingPathComponent("Device/SysInfoExtended") }
  var syncTransactionsDirectory: URL {
    itunesDir.appendingPathComponent(".nightdrive-transactions", isDirectory: true)
  }

  static func isIpodVolume(_ url: URL) -> Bool {
    let volumeRoot = url.resolvingSymlinksInPath().standardizedFileURL
    let controlURL = url.appendingPathComponent("iPod_Control", isDirectory: true)
    let resolvedControl = controlURL.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedControl.isContained(in: volumeRoot, allowRoot: false) else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: controlURL.path, isDirectory: &isDir)
      && isDir.boolValue
  }

  func validateControlDirectory() throws {
    let fm = FileManager.default
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    let resolvedControl = controlDir.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedControl.isContained(in: volumeRoot, allowRoot: false) else {
      throw ITunesDBError.notFound("iPod_Control is outside the iPod volume")
    }
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: controlDir.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ITunesDBError.notFound("iPod_Control is missing")
    }
  }

  func validateMusicDirectory() throws {
    try validateControlDirectory()
    try validateDirectory(musicDir, named: "iPod_Control/Music")
  }

  func validateITunesDirectory() throws {
    try validateControlDirectory()
    try validateDirectory(itunesDir, named: "iPod_Control/iTunes")
  }

  func validateArtworkDirectory() throws {
    try validateControlDirectory()
    try validateDirectory(
      artworkDir, named: "iPod_Control/Artwork", containedBy: controlDir,
      rejectSymbolicLink: true)
  }

  func validateDeviceIdentity(_ expectedDatabaseID: UInt64?, database: ITunesDatabase) throws {
    guard let expectedDatabaseID else { return }
    guard database.databaseID == expectedDatabaseID else {
      throw ITunesDBError.notFound(
        "The iPod at this location changed before the operation could begin")
    }
  }

  private func validateDirectory(
    _ url: URL, named name: String, containedBy requiredParent: URL? = nil,
    rejectSymbolicLink: Bool = false
  ) throws {
    let fm = FileManager.default
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.isContained(in: volumeRoot, allowRoot: false) else {
      throw ITunesDBError.notFound("\(name) is outside the iPod volume")
    }
    if let requiredParent {
      let resolvedParent = requiredParent.resolvingSymlinksInPath().standardizedFileURL
      guard resolved.isContained(in: resolvedParent, allowRoot: false) else {
        throw ITunesDBError.notFound("\(name) is outside \(requiredParent.lastPathComponent)")
      }
    }
    var isDirectory: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw ITunesDBError.notFound("\(name) is not a directory")
      }
      if rejectSymbolicLink {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
          throw ITunesDBError.notFound("\(name) must not be a symbolic link")
        }
      }
    }
  }

  func musicSubdirectories() throws -> [URL] {
    let fm = FileManager.default
    try validateMusicDirectory()
    try fm.createDirectory(at: musicDir, withIntermediateDirectories: true)
    try validateMusicDirectory()
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    let musicRoot = musicDir.resolvingSymlinksInPath().standardizedFileURL
    guard musicRoot.isContained(in: volumeRoot) else {
      throw ITunesDBError.notFound("iPod_Control/Music is outside the iPod volume")
    }
    let listed: [URL]
    do {
      listed = try fm.contentsOfDirectory(
        at: musicDir,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: .skipsHiddenFiles)
    } catch {
      NightdriveLog.ipodFS.error(
        "Could not list iPod_Control/Music; falling back to the standard folder set: \(error.localizedDescription, privacy: .public)"
      )
      listed = []
    }
    let existing =
      listed.filter {
        guard
          let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
          values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        return $0.resolvingSymlinksInPath().standardizedFileURL.isContained(in: musicRoot)
      }.filter { isIpodMusicFolderName($0.lastPathComponent) }
    if !existing.isEmpty { return existing.sorted { $0.path < $1.path } }
    var created: [URL] = []
    for i in 0..<20 {
      let dir = musicDir.appendingPathComponent(String(format: "F%02d", i), isDirectory: true)
      try fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true,
        dir.resolvingSymlinksInPath().standardizedFileURL.isContained(in: musicRoot)
      else {
        throw ITunesDBError.notFound("Invalid music directory \(dir.lastPathComponent)")
      }
      created.append(dir)
    }
    return created
  }

  func destinationForNewFile(
    extension ext: String,
    excluding reservedDestinations: Set<URL> = []
  ) throws -> URL {
    guard !ext.isEmpty,
      ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
    else {
      throw ITunesDBError.notFound("Invalid audio file extension")
    }
    let dirs = try musicSubdirectories()
    guard let dir = dirs.randomElement() else {
      throw ITunesDBError.notFound("No music directories on iPod")
    }
    let reserved = Set(reservedDestinations.map(\.standardizedFileURL))
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    for _ in 0..<1000 {
      let name = String((0..<4).map { _ in letters.randomElement()! }) + "." + ext
      let candidate = dir.appendingPathComponent(name)
      if !reserved.contains(candidate.standardizedFileURL),
        !FileManager.default.fileExists(atPath: candidate.path)
      {
        return candidate
      }
    }
    throw ITunesDBError.notFound("Could not find a free filename on the iPod")
  }

  func ipodPath(for fileURL: URL) -> String {
    let volumes = [volumeURL.standardizedFileURL.path, volumeURL.canonicalFileURL.path]
    var path = fileURL.standardizedFileURL.path
    if let volume = volumes.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
      path = String(path.dropFirst(volume.count))
    }
    if !path.hasPrefix("/") { path = "/" + path }
    return IpodPath.colonSeparated(path)
  }

  func fileURL(forIpodPath ipodPath: String) -> URL? {
    let components = ipodPath.split(separator: ":", omittingEmptySubsequences: true)
    guard !components.isEmpty,
      components.allSatisfy({ component in
        component != "." && component != ".." && !component.contains("/")
          && !component.contains("\\") && !component.contains("\0")
      })
    else { return nil }
    let url = components.reduce(volumeURL.standardizedFileURL) {
      $0.appendingPathComponent(String($1))
    }.standardizedFileURL
    guard url.isContained(in: volumeURL.standardizedFileURL) else { return nil }
    return url
  }

  func validatedMusicFileURL(forIpodPath ipodPath: String) throws -> URL {
    let (_, resolved) = try resolvedMusicFileURLs(forIpodPath: ipodPath)
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw ITunesDBError.notFound("Track file is missing")
    }
    return resolved
  }

  /// Resolve a database path for removal. `nil` means the path itself is
  /// structurally safe but no filesystem entry exists there; malformed paths,
  /// any symlink component, and non-files still throw.
  func validatedMusicFileURLIfPresent(forIpodPath ipodPath: String) throws -> URL? {
    guard let unresolved = fileURL(forIpodPath: ipodPath) else {
      throw ITunesDBError.notFound("Invalid track path")
    }
    let root = volumeURL.standardizedFileURL
    let musicRoot = musicDir.standardizedFileURL
    guard unresolved.isContained(in: musicRoot, allowRoot: false) else {
      throw ITunesDBError.notFound("Track path is outside iPod_Control/Music")
    }

    // Walk the recorded spelling itself. Resolving first would turn a leaf
    // symlink A -> B into B's URL and let a removal move B's real file.
    let components = ipodPath.split(separator: ":", omittingEmptySubsequences: true)
    var current = root
    for (offset, component) in components.enumerated() {
      current.appendPathComponent(String(component))
      var status = stat()
      guard Darwin.lstat(current.path, &status) == 0 else {
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      let fileType = status.st_mode & S_IFMT
      guard fileType != S_IFLNK else {
        throw ITunesDBError.notFound("Track path contains a symbolic link")
      }
      if offset == components.count - 1 {
        guard fileType == S_IFREG else {
          throw ITunesDBError.notFound("Track path is not a regular file")
        }
      } else {
        guard fileType == S_IFDIR else {
          throw ITunesDBError.notFound("Track path contains a non-directory component")
        }
      }
    }
    return unresolved
  }

  private func resolvedMusicFileURLs(forIpodPath ipodPath: String) throws -> (
    unresolved: URL, resolved: URL
  ) {
    guard let unresolved = fileURL(forIpodPath: ipodPath) else {
      throw ITunesDBError.notFound("Invalid track path")
    }
    let resolved = unresolved.resolvingSymlinksInPath().standardizedFileURL
    let root = musicDir.resolvingSymlinksInPath().standardizedFileURL
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    guard root.isContained(in: volumeRoot),
      resolved.isContained(in: root, allowRoot: false)
    else {
      throw ITunesDBError.notFound("Track path is outside iPod_Control/Music")
    }
    return (unresolved, resolved)
  }

  /// Removes files published by a process that died before committing the
  /// matching database. A file already named in the database is kept.
  func recoverInterruptedSyncCopies(database: ITunesDatabase) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: syncTransactionsDirectory.path) else { return }
    let root = syncTransactionsDirectory.resolvingSymlinksInPath().standardizedFileURL
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    guard root.isContained(in: volumeRoot),
      (try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
      (try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink
        != true
    else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }

    let referencedPaths = Set(database.tracks.compactMap(\.ipodPath))
    let directories = try fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: .skipsHiddenFiles)
    for directory in directories where IpodCopyTransaction.isTransactionDirectory(directory) {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
      guard IpodCopyTransaction.hasJournal(in: directory) else {
        try fm.removeItem(at: directory)
        continue
      }
      let journal: IpodCopyTransactionJournal
      do {
        journal = try IpodCopyTransaction.readJournal(in: directory)
        try IpodCopyTransaction.validate(journal: journal, fileSystem: self)
      } catch {
        throw ITunesDBError.badHeader(
          "Unreadable Nightdrive recovery journal at \(directory.lastPathComponent)")
      }
      for entry in journal.entries where !referencedPaths.contains(entry.ipodPath) {
        guard let destination = transactionMusicFileURL(forIpodPath: entry.ipodPath) else {
          throw ITunesDBError.badHeader("Invalid path in Nightdrive recovery journal")
        }
        do {
          try fm.removeItem(at: destination)
        } catch {
          if fm.fileExists(atPath: destination.path) { throw error }
        }
      }
      try fm.removeItem(at: directory)
    }
    if (try? fm.contentsOfDirectory(atPath: root.path).isEmpty) == true {
      fm.bestEffortRemoveItem(at: root)
    }
  }

  /// Resolves interrupted deletion journals: restore the file if the database
  /// still lists the track, discard it if the commit landed.
  func recoverInterruptedDeletions(database: ITunesDatabase) throws {
    try IpodDeleteTransaction.recoverAll(fileSystem: self, database: database)
  }

  func recoverInterruptedMutations(database: ITunesDatabase) throws {
    try recoverInterruptedSyncCopies(database: database)
    try recoverInterruptedDeletions(database: database)
  }

  func transactionMusicFileURL(forIpodPath ipodPath: String) -> URL? {
    let components = ipodPath.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    guard components.count == 4, components[0] == "iPod_Control", components[1] == "Music",
      isIpodMusicFolderName(components[2]),
      !components[3].isEmpty, !components[3].contains("/"), !components[3].contains("\\"),
      components[3] != ".", components[3] != ".."
    else { return nil }
    let parent = musicDir.appendingPathComponent(components[2], isDirectory: true)
    let resolvedParent = parent.resolvingSymlinksInPath().standardizedFileURL
    let resolvedRoot = musicDir.resolvingSymlinksInPath().standardizedFileURL
    let volumeRoot = volumeURL.resolvingSymlinksInPath().standardizedFileURL
    guard resolvedRoot.isContained(in: volumeRoot),
      resolvedParent.isContained(in: resolvedRoot, allowRoot: false)
    else { return nil }
    let candidate = parent.appendingPathComponent(components[3]).standardizedFileURL
    var status = stat()
    if Darwin.lstat(candidate.path, &status) == 0 {
      guard status.st_mode & S_IFMT == S_IFREG else { return nil }
    } else if errno != ENOENT {
      return nil
    }
    return candidate
  }

  func readDatabase() throws -> ITunesDatabase {
    try readDatabase(afterInitialRead: { _ in })
  }

  func readDatabase(
    afterInitialRead: (ITunesDatabase) throws -> Void,
    afterDeferredTransactionsObserved: () throws -> Void = {}
  ) throws -> ITunesDatabase {
    let database = try readDatabaseWithoutArtworkRecovery()
    try afterInitialRead(database)
    return try ArtworkDBTransaction.recoverDeferredTransactions(
      fileSystem: self, initialDatabase: database,
      rawDatabaseReader: { try readDatabaseWithoutArtworkRecovery() },
      afterDeferredTransactionsObserved: afterDeferredTransactionsObserved)
  }

  private func readDatabaseWithoutArtworkRecovery() throws -> ITunesDatabase {
    try validateITunesDirectory()
    try ShuffleDatabaseWriter.recoverForReadIfNeeded(fileSystem: self)
    try Nano5DatabaseWriter.recoverForReadIfNeeded(fileSystem: self)
    return try readDatabaseWithoutRecovery()
  }

  func readDatabaseWithoutRecovery() throws -> ITunesDatabase {
    try validateITunesDirectory()
    if FileManager.default.fileExists(atPath: compressedDatabaseURL.path) {
      let compressed = try Data(contentsOf: compressedDatabaseURL)
      return try ITunesDBReader().read(try ITunesCDB.decompress(compressed))
    } else if FileManager.default.fileExists(atPath: databaseURL.path) {
      return try ITunesDBReader().read(Data(contentsOf: databaseURL))
    } else {
      return ITunesDatabase()  // fresh iPod: start empty
    }
  }

  func writeDatabase(
    _ db: ITunesDatabase, preflightedFormat: IpodDatabaseFormat? = nil,
    shuffleFileInstaller: ShuffleDatabaseWriter.FileInstaller =
      ShuffleDatabaseWriter.installStagedFile,
    databaseFileWriter: (Data, URL, Bool) throws -> Void = {
      try DurableIO.write($0, to: $1, barrier: $2)
    }
  ) throws {
    // Normalize podcast playlists once so the CDB writer and the nano 5G
    // SQLite projection consume the same synthesized state.
    var db = db
    db.podcastPlaylists = ITunesDBWriter.normalizedPodcastPlaylists(for: db)
    let fm = FileManager.default
    try validateITunesDirectory()
    try fm.createDirectory(at: itunesDir, withIntermediateDirectories: true)
    try validateITunesDirectory()
    _ = try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: self)
    let format: IpodDatabaseFormat
    if let preflightedFormat {
      format = preflightedFormat
    } else {
      format = try IpodDatabaseSupport(fileSystem: self).formatForWriting()
    }
    var data = ITunesDBWriter().write(db)
    switch format {
    case .legacy:
      break
    case .hash58(let guid):
      data = try Hash58.sign(data, firewireGUID: guid)
    case .nano5(let guid):
      try Nano5DatabaseWriter.write(
        db, rawDatabase: data, fileSystem: self, firewireGUID: guid)
      return
    }
    if deviceFamily().isShuffle {
      let shuffleData = try shuffleDatabaseData(for: db)
      do {
        try ShuffleDatabaseWriter.install(
          databaseData: data, shuffleData: shuffleData, fileSystem: self,
          fileInstaller: shuffleFileInstaller)
      } catch {
        if try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: self) == .committed {
          return
        }
        throw error
      }
      return
    }
    if fm.fileExists(atPath: databaseURL.path) {
      fm.bestEffortRemoveItem(at: databaseBackupURL)
      try databaseFileWriter(
        Data(contentsOf: databaseURL, options: .mappedIfSafe), databaseBackupURL, true)
    }
    try databaseFileWriter(data, databaseURL, true)
  }

  func writeShuffleDatabase(
    _ db: ITunesDatabase,
    removeStagedBackup: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
    copyBackup: (URL, URL) throws -> Void = { source, staged in
      try DurableIO.write(Data(contentsOf: source, options: .mappedIfSafe), to: staged)
    },
    installBackup: (URL, URL) throws -> Void = ShuffleDatabaseWriter.installStagedFile,
    synchronizeDirectory: (URL) throws -> Void = DurableIO.synchronize,
    writeLive: (Data, URL) throws -> Void = { try DurableIO.write($0, to: $1) },
    synchronizeLive: (URL) throws -> Void = {
      try DurableIO.synchronizeFileAndParent(at: $0)
    }
  ) throws {
    let fm = FileManager.default
    let data = try shuffleDatabaseData(for: db)
    func liveContainsDesiredData() -> Bool {
      guard let installed = try? Data(contentsOf: shuffleDatabaseURL, options: .mappedIfSafe)
      else { return false }
      return installed == data
    }

    // A prior atomic write may have published these bytes before a later
    // durability sync failed. Retry only that sync; rotating the installed
    // generation into the backup would discard the actual previous version.
    if liveContainsDesiredData() {
      try synchronizeLive(shuffleDatabaseURL)
      return
    }
    if fm.fileExists(atPath: shuffleDatabaseBackupStagingURL.path) {
      try removeStagedBackup(shuffleDatabaseBackupStagingURL)
    }
    if fm.fileExists(atPath: shuffleDatabaseURL.path) {
      // Build the new backup beside the old one. The same-directory rename
      // replaces the old backup atomically only after the copy completes.
      try copyBackup(shuffleDatabaseURL, shuffleDatabaseBackupStagingURL)
      try installBackup(shuffleDatabaseBackupStagingURL, shuffleDatabaseBackupURL)
      try synchronizeDirectory(itunesDir)
    }
    do {
      try writeLive(data, shuffleDatabaseURL)
    } catch {
      let writeError = error
      guard liveContainsDesiredData() else { throw writeError }
      // `writeLive` may throw after its atomic rename. Repeating the shared
      // durability protocol reconciles that installed outcome in place.
      try synchronizeLive(shuffleDatabaseURL)
    }
  }

  /// Whether the on-disk iTunesSD matches the database. Shuffle firmware plays
  /// only iTunesSD, so even a no-op sync must rewrite a missing, stale, or
  /// truncated one — an intact iTunesDB alone leaves the device unplayable.
  func shuffleDatabaseMatches(_ db: ITunesDatabase) -> Bool {
    guard let data = try? Data(contentsOf: shuffleDatabaseURL) else { return false }
    if deviceFamily() == .modernShuffle {
      return ModernShuffleDatabaseFile.matches(data, database: db)
    }
    guard let existing = try? ITunesSDFile.read(data) else { return false }
    return existing == shuffleEntries(for: db)
  }

  private func shuffleDatabaseData(for db: ITunesDatabase) throws -> Data {
    switch deviceFamily() {
    case .modernShuffle:
      return try ModernShuffleDatabaseFile.write(db)
    case .shuffle:
      return ITunesSDFile.write(shuffleEntries(for: db))
    case .firstOrSecondGeneration, .thirdGenerationOrLater:
      throw ITunesDBError.unsupportedDevice("This iPod does not use a shuffle database.")
    }
  }

  private func shuffleEntries(for db: ITunesDatabase) -> [ITunesSDFile.Entry] {
    db.tracks.compactMap { track in
      track.ipodPath.map { ITunesSDFile.entry(forIpodPath: $0) }
    }
  }

  func modelNumber() -> String? {
    guard let text = try? String(contentsOf: sysInfoURL, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n") {
      if line.hasPrefix("ModelNumStr:") {
        var value = line.dropFirst("ModelNumStr:".count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("x") { value = String(value.dropFirst()) }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(5)).uppercased()
      }
    }
    return nil
  }

  func deviceFamily() -> IpodDeviceFamily {
    let modelFamily = IpodDeviceFamily(modelNumber: modelNumber())
    if modelFamily.isShuffle { return modelFamily }
    // This fallback intentionally loads iTunesSD for models that SysInfo does
    // not identify as a shuffle. Keep callers on device-discovery/sync cold paths.
    guard let data = try? Data(contentsOf: shuffleDatabaseURL) else { return modelFamily }
    if ModernShuffleDatabaseFile.isModernDatabase(data) { return .modernShuffle }
    if (try? ITunesSDFile.read(data)) != nil { return .shuffle }
    return modelFamily
  }

  func modelDescription() -> String {
    let knownModels: [String: String] = [
      "M9282": String(localized: "iPod (4th generation) 20 GB"),
      "M9268": String(localized: "iPod (4th generation) 40 GB"),
      "M9160": String(localized: "iPod (4th generation) 20 GB"),
      "M9245": String(localized: "iPod (4th generation) 40 GB"),
      "MA079": String(localized: "iPod (4th generation) 20 GB"),
      "MA127": String(localized: "iPod (4th generation) 60 GB"),
      "M9585": String(localized: "iPod photo 20 GB"),
      "M9586": String(localized: "iPod photo 60 GB"),
      "M9724": String(localized: "iPod shuffle 512 MB"),
      "M9725": String(localized: "iPod shuffle 1 GB"),
      "MA133": String(localized: "iPod shuffle 512 MB"),
      "MA564": String(localized: "iPod shuffle (2nd generation) 1 GB"),
      "MA947": String(localized: "iPod shuffle (2nd generation) 1 GB"),
    ]
    let model = modelNumber()
    if let model, let description = knownModels[model] { return description }
    if let generation = IpodDeviceFamily.shuffleGeneration(modelNumber: model) {
      return String(localized: "iPod shuffle (\(ordinal(generation)) generation)")
    }
    guard let model else { return String(localized: "iPod") }
    return String(localized: "iPod (\(model))")
  }

  private func ordinal(_ value: Int) -> String {
    switch value {
    case 1: String(localized: "1st")
    case 2: String(localized: "2nd")
    case 3: String(localized: "3rd")
    default: String(localized: "\(value)th")
    }
  }
}

struct IpodCopyTransactionEntry: Codable, Sendable {
  let stagedName: String
  let ipodPath: String
}

struct IpodCopyTransactionJournal: Codable, Sendable {
  var entries: [IpodCopyTransactionEntry]
}

/// Persistent staging on the iPod. The journal is written before any file is
/// renamed into FNN, so recovery removes only uncommitted destinations.
final class IpodCopyTransaction {
  private static let prefix = "sync-"
  private static let journalName = "journal.json"
  static let maximumJournalBytes = 8 * 1_024 * 1_024
  static let maximumEntryCount = 50_000
  static let maximumIpodPathBytes = 1_024
  static let maximumStagedNameBytes = 128

  private let fileSystem: IpodFileSystem
  let directory: URL
  private(set) var entries: [IpodCopyTransactionEntry] = []
  private var stagedDestinationKeys: Set<String> = []

  init(fileSystem: IpodFileSystem) throws {
    self.fileSystem = fileSystem
    let fm = FileManager.default
    try fileSystem.validateITunesDirectory()
    let unresolvedRoot = fileSystem.syncTransactionsDirectory
    let prospectiveRoot = unresolvedRoot.resolvingSymlinksInPath().standardizedFileURL
    let volumeRoot = fileSystem.volumeURL.resolvingSymlinksInPath().standardizedFileURL
    guard prospectiveRoot.isContained(in: volumeRoot, allowRoot: false) else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    try fm.createDirectory(
      at: unresolvedRoot, withIntermediateDirectories: true)
    let root = fileSystem.syncTransactionsDirectory.resolvingSymlinksInPath().standardizedFileURL
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      root.isContained(in: volumeRoot)
    else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    directory = root.appendingPathComponent(
      Self.prefix + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: directory, withIntermediateDirectories: false)
  }

  func stage(source: URL, destination: URL) throws -> URL {
    let ipodPath = fileSystem.ipodPath(for: destination)
    let destinationKey = ipodPath.lowercased()
    guard entries.count < Self.maximumEntryCount else {
      throw ITunesDBError.badHeader("Nightdrive copy journal has too many entries")
    }
    guard !stagedDestinationKeys.contains(destinationKey) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let extensionSuffix = destination.pathExtension.isEmpty ? "" : ".\(destination.pathExtension)"
    let stagedName = UUID().uuidString + extensionSuffix
    let entry = IpodCopyTransactionEntry(stagedName: stagedName, ipodPath: ipodPath)
    guard Self.isValid(entry: entry, fileSystem: fileSystem) else {
      throw ITunesDBError.notFound("Invalid Nightdrive copy transaction entry")
    }
    let stagedURL = directory.appendingPathComponent(stagedName)
    try FileManager.default.copyItem(at: source, to: stagedURL)
    stagedDestinationKeys.insert(destinationKey)
    entries.append(entry)
    return stagedURL
  }

  func publishJournal() throws {
    // Flush after every staged copy has been issued so removable disks can
    // coalesce their writes. The journal remains the publication boundary:
    // before it exists, recovery may discard this entire private directory.
    for entry in entries {
      try DurableIO.synchronize(at: directory.appendingPathComponent(entry.stagedName))
    }
    let journal = IpodCopyTransactionJournal(entries: entries)
    try Self.validate(journal: journal, fileSystem: fileSystem)
    let data = try JSONEncoder().encode(journal)
    guard data.count <= Self.maximumJournalBytes else {
      throw ITunesDBError.badHeader("Nightdrive copy journal exceeds safety limit")
    }
    let journalURL = directory.appendingPathComponent(Self.journalName)
    try data.write(to: journalURL, options: .atomic)
    try DurableIO.synchronize(at: journalURL)
    bestEffortSynchronize("copy transaction directory") {
      try DurableIO.synchronize(at: directory)
    }
  }

  /// Make every published rename durable before the database can refer to it.
  func synchronizePublishedFiles(_ urls: [URL]) throws {
    for url in urls { try DurableIO.synchronize(at: url) }
    for directory in Set(urls.map { $0.deletingLastPathComponent() }) {
      bestEffortSynchronize("published file parent directory") {
        try DurableIO.synchronize(at: directory)
      }
    }
  }

  func finish() {
    FileManager.default.bestEffortRemoveItem(at: directory)
    let root = fileSystem.syncTransactionsDirectory
    if (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true {
      FileManager.default.bestEffortRemoveItem(at: root)
    }
  }

  static func isTransactionDirectory(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard name.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }

  static func readJournal(in directory: URL) throws -> IpodCopyTransactionJournal {
    let data = try RecoveryMarkerReadSupport.readBoundedJournal(
      at: directory.appendingPathComponent(journalName), maximumBytes: maximumJournalBytes,
      oversizedFailure: "Nightdrive copy journal exceeds safety limit")
    return try JSONDecoder().decode(IpodCopyTransactionJournal.self, from: data)
  }

  static func hasJournal(in directory: URL) -> Bool {
    FileManager.default.fileExists(
      atPath: directory.appendingPathComponent(journalName).path)
  }

  static func validate(
    journal: IpodCopyTransactionJournal, fileSystem: IpodFileSystem
  ) throws {
    guard journal.entries.count <= maximumEntryCount else {
      throw ITunesDBError.badHeader("Nightdrive copy journal has too many entries")
    }
    var destinationKeys: Set<String> = []
    var stagedNames: Set<String> = []
    destinationKeys.reserveCapacity(journal.entries.count)
    stagedNames.reserveCapacity(journal.entries.count)
    for entry in journal.entries {
      guard isValid(entry: entry, fileSystem: fileSystem),
        destinationKeys.insert(entry.ipodPath.lowercased()).inserted,
        stagedNames.insert(entry.stagedName.lowercased()).inserted
      else {
        throw ITunesDBError.badHeader("Invalid entry in Nightdrive copy journal")
      }
    }
  }

  private static func isValid(
    entry: IpodCopyTransactionEntry, fileSystem: IpodFileSystem
  ) -> Bool {
    guard entry.ipodPath.utf8.count <= maximumIpodPathBytes,
      entry.stagedName.utf8.count <= maximumStagedNameBytes,
      let destination = fileSystem.transactionMusicFileURL(forIpodPath: entry.ipodPath),
      fileSystem.ipodPath(for: destination) == entry.ipodPath,
      entry.ipodPath.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
    else { return false }
    let parts = entry.stagedName.split(
      separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first, UUID(uuidString: String(first)) != nil else { return false }
    if parts.count == 1 { return true }
    let fileExtension = parts[1]
    return !fileExtension.isEmpty
      && fileExtension.unicodeScalars.allSatisfy {
        $0.isASCII && CharacterSet.alphanumerics.contains($0)
      }
  }
}

struct IpodDeleteTransactionJournal: Codable, Sendable {
  let dbid: UInt64
  let ipodPath: String
  let stagedName: String
}

enum IpodDeleteTransactionSyncPoint: Equatable, Sendable {
  case journalDirectory
  case sourceDirectoryAfterRename
  case transactionDirectoryAfterRename
}

/// A durable delete intent. Audio moves in only after its journal reaches
/// disk, so recovery can restore or discard it from the committed database.
final class IpodDeleteTransaction {
  private static let prefix = "delete-"
  private static let journalName = "journal.json"
  private static let maximumJournalBytes = 16 * 1_024
  private static let maximumIpodPathBytes = 1_024
  private static let maximumStagedNameBytes = 128

  private let fileSystem: IpodFileSystem
  private let volumeDirectoryDescriptor: Int32
  private let controlDirectoryDescriptor: Int32
  private let itunesDirectoryDescriptor: Int32
  private let rootDirectoryDescriptor: Int32
  private let directoryDescriptor: Int32
  private let rootName: String
  private let directoryName: String
  private let controlIdentity: FileIdentity
  private let itunesIdentity: FileIdentity
  private let rootIdentity: FileIdentity
  private let directoryIdentity: FileIdentity
  private var stagedEntry: (name: String, identity: FileIdentity)?
  private var retainsITunesChain = true
  private var retainsTransactionDescriptors = true
  let directory: URL

  init(
    fileSystem: IpodFileSystem,
    afterOpeningControlDirectory: () throws -> Void = {}
  ) throws {
    self.fileSystem = fileSystem
    let itunesChain = try Self.openITunesDirectory(
      fileSystem: fileSystem,
      afterOpeningControlDirectory: afterOpeningControlDirectory)
    var ownsITunesChain = true
    defer {
      if ownsITunesChain { Self.close(itunesChain) }
    }
    guard Self.itunesDirectoryIsLinked(itunesChain) else {
      throw ITunesDBError.notFound("iPod_Control/iTunes changed")
    }

    let rootName = fileSystem.syncTransactionsDirectory.lastPathComponent
    let rootCreationResult = Darwin.mkdirat(
      itunesChain.itunesDescriptor, rootName, S_IRWXU)
    guard rootCreationResult == 0 || errno == EEXIST else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if rootCreationResult == 0 {
      try DurableIO.synchronize(descriptor: itunesChain.itunesDescriptor)
    }
    let rootDescriptor = Darwin.openat(
      itunesChain.itunesDescriptor, rootName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    var ownsRootDescriptor = true
    defer {
      if ownsRootDescriptor { Darwin.close(rootDescriptor) }
    }
    let rootIdentity = try Self.identity(of: rootDescriptor)
    guard rootIdentity.fileType == S_IFDIR else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }

    let directoryName = Self.prefix + UUID().uuidString
    guard Darwin.mkdirat(rootDescriptor, directoryName, S_IRWXU) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let directoryDescriptor = Darwin.openat(
      rootDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      _ = Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR)
      throw error
    }
    var ownsDirectoryDescriptor = true
    defer {
      if ownsDirectoryDescriptor { Darwin.close(directoryDescriptor) }
    }
    let directoryIdentity = try Self.identity(of: directoryDescriptor)
    guard directoryIdentity.fileType == S_IFDIR else {
      _ = Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR)
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    do {
      try DurableIO.synchronize(descriptor: rootDescriptor)
    } catch {
      _ = Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR)
      throw error
    }

    self.volumeDirectoryDescriptor = itunesChain.volumeDescriptor
    self.controlDirectoryDescriptor = itunesChain.controlDescriptor
    self.itunesDirectoryDescriptor = itunesChain.itunesDescriptor
    self.rootDirectoryDescriptor = rootDescriptor
    self.directoryDescriptor = directoryDescriptor
    self.rootName = rootName
    self.directoryName = directoryName
    self.controlIdentity = itunesChain.controlIdentity
    self.itunesIdentity = itunesChain.itunesIdentity
    self.rootIdentity = rootIdentity
    self.directoryIdentity = directoryIdentity
    self.directory = fileSystem.syncTransactionsDirectory.appendingPathComponent(
      directoryName, isDirectory: true)
    ownsDirectoryDescriptor = false
    ownsITunesChain = false
    ownsRootDescriptor = false
  }

  deinit {
    releaseAllDescriptors()
  }

  func stage(source: URL, dbid: UInt64, ipodPath: String) throws {
    guard let expected = fileSystem.fileURL(forIpodPath: ipodPath),
      expected.canonicalFileURL == source.canonicalFileURL
    else {
      finish()
      throw ITunesDBError.notFound("Track source does not match its iPod path")
    }
    guard try stageMusicFileIfPresent(dbid: dbid, ipodPath: ipodPath) else {
      throw ITunesDBError.notFound("Track file is missing")
    }
  }

  /// Stages the recorded directory entry without following any component.
  /// The parent descriptor remains authoritative through `renameat`, so a
  /// path swapped to a symlink after inspection cannot redirect the move.
  @discardableResult
  func stageMusicFileIfPresent(
    dbid: UInt64,
    ipodPath: String,
    afterSourceStat: () throws -> Void = {},
    synchronizeDirectory:
      (Int32, IpodDeleteTransactionSyncPoint) throws -> Void = { descriptor, _ in
        try DurableIO.synchronize(descriptor: descriptor)
      }
  ) throws -> Bool {
    defer { releaseAllDescriptors() }
    let opened: OpenMusicEntry
    do {
      guard let candidate = try openMusicEntry(forIpodPath: ipodPath) else {
        finish()
        return false
      }
      opened = candidate
    } catch {
      finish()
      throw error
    }
    defer { Darwin.close(opened.parentDescriptor) }

    let ext = opened.sourceURL.pathExtension
    let stagedName = ext.isEmpty ? "audio" : "audio.\(ext)"
    var didRenameSource = false
    do {
      let journal = IpodDeleteTransactionJournal(
        dbid: dbid, ipodPath: ipodPath, stagedName: stagedName)
      let encodedJournal = try JSONEncoder().encode(journal)
      try Self.validate(journal: journal, encodedData: encodedJournal)
      try writeJournal(
        encodedJournal,
        synchronizeDirectory: { descriptor in
          try synchronizeDirectory(descriptor, .journalDirectory)
        })
      try afterSourceStat()
      guard transactionDirectoryIsLinkedAtExpectedName() else {
        throw ITunesDBError.notFound("Nightdrive deletion transaction directory changed")
      }
      guard
        Darwin.renameatx_np(
          opened.parentDescriptor, opened.leafName,
          directoryDescriptor, stagedName, UInt32(RENAME_EXCL)) == 0
      else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      didRenameSource = true

      let stagedIdentity = try Self.identity(
        named: stagedName, in: directoryDescriptor)
      guard stagedIdentity == opened.identity, stagedIdentity.fileType == S_IFREG else {
        let mismatch = ITunesDBError.notFound(
          "Track changed while its deletion was being staged")
        do {
          try restoreStagedEntry(named: stagedName, to: opened)
        } catch {
          throw ITunesDBError.notFound(
            "Track changed while its deletion was being staged and could not be restored (\(error.localizedDescription))"
          )
        }
        cleanupEmptyTransaction()
        throw mismatch
      }
      stagedEntry = (stagedName, stagedIdentity)

      var firstSynchronizationError: Error?
      do {
        try synchronizeDirectory(opened.parentDescriptor, .sourceDirectoryAfterRename)
      } catch {
        firstSynchronizationError = error
      }
      do {
        try synchronizeDirectory(directoryDescriptor, .transactionDirectoryAfterRename)
      } catch {
        if firstSynchronizationError == nil { firstSynchronizationError = error }
      }
      if let firstSynchronizationError { throw firstSynchronizationError }
      return true
    } catch {
      if !didRenameSource {
        cleanupEmptyTransaction()
      }
      throw error
    }
  }

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let fileType: mode_t

    init(_ status: stat) {
      device = status.st_dev
      inode = status.st_ino
      fileType = status.st_mode & S_IFMT
    }
  }

  private struct OpenITunesDirectory {
    let volumeDescriptor: Int32
    let controlDescriptor: Int32
    let itunesDescriptor: Int32
    let controlIdentity: FileIdentity
    let itunesIdentity: FileIdentity
  }

  private struct OpenTransactionDirectory {
    let itunesChain: OpenITunesDirectory
    let rootDescriptor: Int32
    let directoryDescriptor: Int32
  }

  private struct ValidatedMusicPath {
    let components: [String]
    let leafName: String
  }

  private struct OpenMusicParent {
    let descriptor: Int32
    let leafName: String
    let sourceURL: URL
  }

  private struct OpenMusicEntry {
    let parentDescriptor: Int32
    let leafName: String
    let sourceURL: URL
    let identity: FileIdentity
  }

  private func openMusicEntry(forIpodPath ipodPath: String) throws -> OpenMusicEntry? {
    guard let parent = try Self.openMusicParent(fileSystem: fileSystem, ipodPath: ipodPath)
    else { return nil }
    var descriptorIsOwned = true
    defer {
      if descriptorIsOwned { Darwin.close(parent.descriptor) }
    }
    guard
      let identity = try Self.identityIfPresent(
        named: parent.leafName, in: parent.descriptor)
    else { return nil }
    guard identity.fileType != S_IFLNK else {
      throw ITunesDBError.notFound("Track path contains a symbolic link")
    }
    guard identity.fileType == S_IFREG else {
      throw ITunesDBError.notFound("Track path is not a regular file")
    }
    descriptorIsOwned = false
    return OpenMusicEntry(
      parentDescriptor: parent.descriptor,
      leafName: parent.leafName,
      sourceURL: parent.sourceURL,
      identity: identity)
  }

  private static func openMusicParent(
    fileSystem: IpodFileSystem, ipodPath: String
  ) throws -> OpenMusicParent? {
    let path = try validateMusicPath(ipodPath)
    let sourceURL = path.components.reduce(fileSystem.volumeURL.standardizedFileURL) {
      $0.appendingPathComponent($1)
    }

    var parentDescriptor = Darwin.open(
      fileSystem.volumeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parentDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var descriptorIsOwned = true
    defer {
      if descriptorIsOwned { Darwin.close(parentDescriptor) }
    }

    for component in path.components.dropLast() {
      let nextDescriptor = Darwin.openat(
        parentDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard nextDescriptor >= 0 else {
        let openError = errno
        if openError == ENOENT { return nil }
        if Self.entryIsSymbolicLink(named: component, in: parentDescriptor) {
          throw ITunesDBError.notFound("Track path contains a symbolic link")
        }
        if Self.entryExists(named: component, in: parentDescriptor) {
          throw ITunesDBError.notFound("Track path contains a non-directory component")
        }
        throw POSIXError(POSIXErrorCode(rawValue: openError) ?? .EIO)
      }
      Darwin.close(parentDescriptor)
      parentDescriptor = nextDescriptor
    }

    descriptorIsOwned = false
    return OpenMusicParent(
      descriptor: parentDescriptor, leafName: path.leafName, sourceURL: sourceURL)
  }

  private static func validate(
    journal: IpodDeleteTransactionJournal, encodedData: Data
  ) throws {
    guard encodedData.count <= maximumJournalBytes,
      journal.ipodPath.utf8.count <= maximumIpodPathBytes,
      journal.stagedName.utf8.count <= maximumStagedNameBytes
    else {
      throw ITunesDBError.badHeader("Nightdrive deletion journal exceeds safety limit")
    }
    let object = try JSONSerialization.jsonObject(with: encodedData)
    guard let fields = object as? [String: Any],
      Set(fields.keys) == Set(["dbid", "ipodPath", "stagedName"])
    else {
      throw ITunesDBError.badHeader("Invalid Nightdrive deletion journal schema")
    }
    let path = try validateMusicPath(journal.ipodPath)
    let fileExtension = URL(fileURLWithPath: path.leafName).pathExtension
    guard
      fileExtension.unicodeScalars.allSatisfy({ scalar in
        scalar.isASCII
          && ((scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122))
      })
    else {
      throw ITunesDBError.badHeader("Invalid extension in Nightdrive deletion journal")
    }
    let expectedStagedName = fileExtension.isEmpty ? "audio" : "audio.\(fileExtension)"
    guard journal.stagedName == expectedStagedName else {
      throw ITunesDBError.badHeader("Invalid staged name in Nightdrive deletion journal")
    }
  }

  private static func validateMusicPath(_ ipodPath: String) throws -> ValidatedMusicPath {
    guard ipodPath.first == ":" else {
      throw ITunesDBError.badHeader("Invalid path in Nightdrive deletion journal")
    }
    let components = ipodPath.dropFirst().split(
      separator: ":", omittingEmptySubsequences: false
    ).map(String.init)
    guard components.count == 4,
      components.allSatisfy({ !$0.isEmpty }),
      components[0] == "iPod_Control",
      components[1] == "Music",
      isIpodMusicFolderName(components[2]),
      components[3] != ".",
      components[3] != "..",
      !components[3].contains("/"),
      !components[3].contains("\\"),
      components[3].unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }),
      ipodPath == ":" + components.joined(separator: ":")
    else {
      throw ITunesDBError.badHeader("Invalid path in Nightdrive deletion journal")
    }
    return ValidatedMusicPath(components: components, leafName: components[3])
  }

  private static func openITunesDirectory(
    fileSystem: IpodFileSystem,
    afterOpeningControlDirectory: () throws -> Void = {}
  ) throws -> OpenITunesDirectory {
    let volumeDescriptor = Darwin.open(
      fileSystem.volumeURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard volumeDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var controlDescriptor: Int32 = -1
    var itunesDescriptor: Int32 = -1
    var ownsDescriptors = true
    defer {
      if ownsDescriptors {
        if itunesDescriptor >= 0 { Darwin.close(itunesDescriptor) }
        if controlDescriptor >= 0 { Darwin.close(controlDescriptor) }
        Darwin.close(volumeDescriptor)
      }
    }

    controlDescriptor = Darwin.openat(
      volumeDescriptor, "iPod_Control",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard controlDescriptor >= 0 else {
      throw ITunesDBError.notFound("Invalid iPod_Control directory")
    }
    let controlIdentity = try identity(of: controlDescriptor)
    guard controlIdentity.fileType == S_IFDIR else {
      throw ITunesDBError.notFound("Invalid iPod_Control directory")
    }
    try afterOpeningControlDirectory()
    guard
      (try? identity(named: "iPod_Control", in: volumeDescriptor)) == controlIdentity
    else {
      throw ITunesDBError.notFound("iPod_Control changed")
    }

    itunesDescriptor = Darwin.openat(
      controlDescriptor, "iTunes",
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard itunesDescriptor >= 0 else {
      throw ITunesDBError.notFound("Invalid iPod_Control/iTunes directory")
    }
    let itunesIdentity = try identity(of: itunesDescriptor)
    guard itunesIdentity.fileType == S_IFDIR else {
      throw ITunesDBError.notFound("Invalid iPod_Control/iTunes directory")
    }
    let result = OpenITunesDirectory(
      volumeDescriptor: volumeDescriptor,
      controlDescriptor: controlDescriptor,
      itunesDescriptor: itunesDescriptor,
      controlIdentity: controlIdentity,
      itunesIdentity: itunesIdentity)
    guard itunesDirectoryIsLinked(result) else {
      throw ITunesDBError.notFound("iPod_Control/iTunes changed")
    }
    ownsDescriptors = false
    return result
  }

  private static func close(_ directory: OpenITunesDirectory) {
    Darwin.close(directory.itunesDescriptor)
    Darwin.close(directory.controlDescriptor)
    Darwin.close(directory.volumeDescriptor)
  }

  private static func close(_ directory: OpenTransactionDirectory) {
    Darwin.close(directory.directoryDescriptor)
    Darwin.close(directory.rootDescriptor)
    close(directory.itunesChain)
  }

  private func openTransactionDirectory() throws -> OpenTransactionDirectory {
    let itunesChain = try Self.openITunesDirectory(fileSystem: fileSystem)
    var ownsITunesChain = true
    defer {
      if ownsITunesChain { Self.close(itunesChain) }
    }
    guard
      itunesChain.controlIdentity == controlIdentity,
      itunesChain.itunesIdentity == itunesIdentity,
      Self.itunesDirectoryIsLinked(itunesChain),
      (try? Self.identity(named: rootName, in: itunesChain.itunesDescriptor)) == rootIdentity
    else {
      throw ITunesDBError.notFound("Nightdrive deletion transaction path changed")
    }

    let rootDescriptor = Darwin.openat(
      itunesChain.itunesDescriptor, rootName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else {
      throw ITunesDBError.notFound("Nightdrive deletion transaction path changed")
    }
    var ownsRootDescriptor = true
    defer {
      if ownsRootDescriptor { Darwin.close(rootDescriptor) }
    }
    guard
      (try? Self.identity(of: rootDescriptor)) == rootIdentity,
      (try? Self.identity(named: directoryName, in: rootDescriptor)) == directoryIdentity
    else {
      throw ITunesDBError.notFound("Nightdrive deletion transaction path changed")
    }

    let directoryDescriptor = Darwin.openat(
      rootDescriptor, directoryName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryDescriptor >= 0,
      (try? Self.identity(of: directoryDescriptor)) == directoryIdentity
    else {
      if directoryDescriptor >= 0 { Darwin.close(directoryDescriptor) }
      throw ITunesDBError.notFound("Nightdrive deletion transaction path changed")
    }

    ownsITunesChain = false
    ownsRootDescriptor = false
    return OpenTransactionDirectory(
      itunesChain: itunesChain,
      rootDescriptor: rootDescriptor,
      directoryDescriptor: directoryDescriptor)
  }

  private static func itunesDirectoryIsLinked(_ directory: OpenITunesDirectory) -> Bool {
    guard
      (try? identity(named: "iPod_Control", in: directory.volumeDescriptor))
        == directory.controlIdentity,
      directory.controlIdentity.fileType == S_IFDIR,
      (try? identity(named: "iTunes", in: directory.controlDescriptor))
        == directory.itunesIdentity
    else { return false }
    return directory.itunesIdentity.fileType == S_IFDIR
  }

  private func restoreStagedEntry(named stagedName: String, to opened: OpenMusicEntry) throws {
    guard
      Darwin.renameatx_np(
        directoryDescriptor, stagedName,
        opened.parentDescriptor, opened.leafName,
        UInt32(RENAME_EXCL)) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var firstSynchronizationError: Error?
    do {
      try DurableIO.synchronize(descriptor: opened.parentDescriptor)
    } catch {
      firstSynchronizationError = error
    }
    do {
      try DurableIO.synchronize(descriptor: directoryDescriptor)
    } catch {
      if firstSynchronizationError == nil { firstSynchronizationError = error }
    }
    if let firstSynchronizationError { throw firstSynchronizationError }
  }

  private func writeJournal(
    _ data: Data, synchronizeDirectory: (Int32) throws -> Void
  ) throws {
    let temporaryName = ".journal-\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(
      directoryDescriptor, temporaryName,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var renamed = false
    defer {
      Darwin.close(descriptor)
      if !renamed { _ = Darwin.unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    try data.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      var written = 0
      while written < rawBuffer.count {
        let count = Darwin.write(
          descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        written += count
      }
    }
    try DurableIO.synchronize(descriptor: descriptor)
    guard
      Darwin.renameat(
        directoryDescriptor, temporaryName,
        directoryDescriptor, Self.journalName) == 0
    else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    renamed = true
    try synchronizeDirectory(directoryDescriptor)
  }

  private func transactionDirectoryIsLinkedAtExpectedName() -> Bool {
    guard retainsTransactionDescriptors else { return false }
    if retainsITunesChain {
      return transactionDirectoryIsLinkedAtExpectedName(
        OpenITunesDirectory(
          volumeDescriptor: volumeDirectoryDescriptor,
          controlDescriptor: controlDirectoryDescriptor,
          itunesDescriptor: itunesDirectoryDescriptor,
          controlIdentity: controlIdentity,
          itunesIdentity: itunesIdentity),
        rootDescriptor: rootDirectoryDescriptor)
    }
    guard let itunesChain = try? Self.openITunesDirectory(fileSystem: fileSystem) else {
      return false
    }
    defer { Self.close(itunesChain) }
    return transactionDirectoryIsLinkedAtExpectedName(
      itunesChain, rootDescriptor: rootDirectoryDescriptor)
  }

  private func transactionDirectoryIsLinkedAtExpectedName(
    _ itunesChain: OpenITunesDirectory,
    rootDescriptor: Int32
  ) -> Bool {
    guard
      itunesChain.controlIdentity == controlIdentity,
      itunesChain.itunesIdentity == itunesIdentity,
      Self.itunesDirectoryIsLinked(itunesChain),
      let currentRoot = try? Self.identity(
        named: rootName, in: itunesChain.itunesDescriptor),
      currentRoot == rootIdentity,
      let current = try? Self.identity(named: directoryName, in: rootDescriptor)
    else { return false }
    return current == directoryIdentity && current.fileType == S_IFDIR
  }

  private static func identity(of descriptor: Int32) throws -> FileIdentity {
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return FileIdentity(status)
  }

  private static func identity(named name: String, in descriptor: Int32) throws -> FileIdentity {
    guard let identity = try identityIfPresent(named: name, in: descriptor) else {
      throw POSIXError(.ENOENT)
    }
    return identity
  }

  private static func identityIfPresent(
    named name: String, in descriptor: Int32
  ) throws -> FileIdentity? {
    var status = stat()
    guard Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return FileIdentity(status)
  }

  private static func entryExists(named name: String, in descriptor: Int32) -> Bool {
    var status = stat()
    return Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0
  }

  private static func entryIsSymbolicLink(named name: String, in descriptor: Int32) -> Bool {
    var status = stat()
    guard Darwin.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
      return false
    }
    return status.st_mode & S_IFMT == S_IFLNK
  }

  func finish() {
    defer { releaseAllDescriptors() }
    withResolvedTransactionChain { itunesChain, rootDescriptor, directoryDescriptor in
      finish(
        using: itunesChain,
        rootDescriptor: rootDescriptor,
        directoryDescriptor: directoryDescriptor)
    }
  }

  private func finish(
    using itunesChain: OpenITunesDirectory,
    rootDescriptor: Int32,
    directoryDescriptor: Int32
  ) {
    guard
      transactionDirectoryIsLinkedAtExpectedName(
        itunesChain, rootDescriptor: rootDescriptor)
    else { return }
    if let stagedEntry {
      guard
        let current = try? Self.identity(
          named: stagedEntry.name, in: directoryDescriptor),
        current == stagedEntry.identity,
        current.fileType == S_IFREG
      else { return }
      guard Darwin.unlinkat(directoryDescriptor, stagedEntry.name, 0) == 0 else { return }
    }
    cleanupEmptyTransaction(
      using: itunesChain,
      rootDescriptor: rootDescriptor,
      directoryDescriptor: directoryDescriptor)
  }

  private func releaseITunesChainDescriptors() {
    guard retainsITunesChain else { return }
    Darwin.close(itunesDirectoryDescriptor)
    Darwin.close(controlDirectoryDescriptor)
    Darwin.close(volumeDirectoryDescriptor)
    retainsITunesChain = false
  }

  private func releaseAllDescriptors() {
    if retainsTransactionDescriptors {
      Darwin.close(directoryDescriptor)
      Darwin.close(rootDirectoryDescriptor)
      retainsTransactionDescriptors = false
    }
    releaseITunesChainDescriptors()
  }

  /// Resolves the transaction's directory chain — reusing retained
  /// descriptors when available, otherwise reopening and closing it — and
  /// runs `body` with the iTunes chain, root, and transaction descriptors.
  private func withResolvedTransactionChain(
    _ body: (OpenITunesDirectory, Int32, Int32) -> Void
  ) {
    if retainsITunesChain, retainsTransactionDescriptors {
      body(
        OpenITunesDirectory(
          volumeDescriptor: volumeDirectoryDescriptor,
          controlDescriptor: controlDirectoryDescriptor,
          itunesDescriptor: itunesDirectoryDescriptor,
          controlIdentity: controlIdentity,
          itunesIdentity: itunesIdentity),
        rootDirectoryDescriptor,
        directoryDescriptor)
      return
    }
    guard let transactionDirectory = try? openTransactionDirectory() else {
      NightdriveLog.ipodFS.debug(
        "Skipping deletion-transaction cleanup: the transaction directory chain no longer resolves"
      )
      return
    }
    defer { Self.close(transactionDirectory) }
    body(
      transactionDirectory.itunesChain,
      transactionDirectory.rootDescriptor,
      transactionDirectory.directoryDescriptor)
  }

  private func cleanupEmptyTransaction() {
    withResolvedTransactionChain { itunesChain, rootDescriptor, directoryDescriptor in
      cleanupEmptyTransaction(
        using: itunesChain,
        rootDescriptor: rootDescriptor,
        directoryDescriptor: directoryDescriptor)
    }
  }

  private func cleanupEmptyTransaction(
    using itunesChain: OpenITunesDirectory,
    rootDescriptor: Int32,
    directoryDescriptor: Int32
  ) {
    guard
      transactionDirectoryIsLinkedAtExpectedName(
        itunesChain, rootDescriptor: rootDescriptor)
    else { return }
    _ = Darwin.unlinkat(directoryDescriptor, Self.journalName, 0)
    bestEffortSynchronize("deletion transaction directory") {
      try DurableIO.synchronize(descriptor: directoryDescriptor)
    }
    guard Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR) == 0 else {
      return
    }
    bestEffortSynchronize("deletion transaction root") {
      try DurableIO.synchronize(descriptor: rootDescriptor)
    }
    guard
      (try? Self.identity(named: rootName, in: itunesChain.itunesDescriptor)) == rootIdentity
    else { return }
    if Darwin.unlinkat(itunesChain.itunesDescriptor, rootName, AT_REMOVEDIR) == 0 {
      bestEffortSynchronize("iTunes directory after transaction cleanup") {
        try DurableIO.synchronize(descriptor: itunesChain.itunesDescriptor)
      }
    }
  }

  static func recoverAll(
    fileSystem: IpodFileSystem,
    database: ITunesDatabase,
    afterOpeningControlDirectory: () throws -> Void = {}
  ) throws {
    let fm = FileManager.default
    let root = fileSystem.syncTransactionsDirectory
    let itunesChain = try openITunesDirectory(
      fileSystem: fileSystem,
      afterOpeningControlDirectory: afterOpeningControlDirectory)
    defer { close(itunesChain) }
    guard itunesDirectoryIsLinked(itunesChain) else {
      throw ITunesDBError.notFound("iPod_Control/iTunes changed")
    }
    let rootName = root.lastPathComponent
    guard
      let expectedRootIdentity = try identityIfPresent(
        named: rootName, in: itunesChain.itunesDescriptor)
    else { return }
    guard expectedRootIdentity.fileType == S_IFDIR else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    let rootDescriptor = Darwin.openat(
      itunesChain.itunesDescriptor, rootName,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootDescriptor >= 0 else {
      throw ITunesDBError.notFound("Invalid Nightdrive transaction directory")
    }
    defer { Darwin.close(rootDescriptor) }
    let rootIdentity = try identity(of: rootDescriptor)
    guard rootIdentity == expectedRootIdentity else {
      throw ITunesDBError.notFound("Nightdrive transaction directory changed")
    }

    let directories = try fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: .skipsHiddenFiles)
    for directory in directories where isTransactionDirectory(directory) {
      let directoryName = directory.lastPathComponent
      let directoryDescriptor = Darwin.openat(
        rootDescriptor, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard directoryDescriptor >= 0 else { continue }
      defer { Darwin.close(directoryDescriptor) }
      let directoryIdentity = try identity(of: directoryDescriptor)
      guard directoryIdentity.fileType == S_IFDIR else { continue }

      guard entryExists(named: journalName, in: directoryDescriptor) else {
        _ = Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR)
        continue
      }
      let journal: IpodDeleteTransactionJournal
      do {
        let data = try readJournal(in: directoryDescriptor)
        journal = try JSONDecoder().decode(IpodDeleteTransactionJournal.self, from: data)
        try validate(journal: journal, encodedData: data)
      } catch {
        throw ITunesDBError.badHeader(
          "Unreadable Nightdrive deletion journal at \(directory.lastPathComponent)")
      }
      let stagedIdentity = try identityIfPresent(
        named: journal.stagedName, in: directoryDescriptor)
      let isReferenced = database.tracks.contains {
        $0.dbid == journal.dbid && $0.ipodPath == journal.ipodPath
      }
      if !isReferenced {
        if let stagedIdentity {
          guard stagedIdentity.fileType == S_IFREG else {
            throw ITunesDBError.notFound(
              "Interrupted deletion staged an unexpected non-file")
          }
          guard Darwin.unlinkat(directoryDescriptor, journal.stagedName, 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          try DurableIO.synchronize(descriptor: directoryDescriptor)
        }
      } else {
        guard
          let originalParent = try openMusicParent(
            fileSystem: fileSystem, ipodPath: journal.ipodPath)
        else {
          throw ITunesDBError.notFound("Interrupted deletion is missing its track directory")
        }
        defer { Darwin.close(originalParent.descriptor) }
        let originalIdentity = try identityIfPresent(
          named: originalParent.leafName, in: originalParent.descriptor)
        if let originalIdentity {
          guard originalIdentity.fileType == S_IFREG else {
            throw ITunesDBError.notFound(
              "Interrupted deletion found a non-file at the track path")
          }
          if let stagedIdentity {
            guard stagedIdentity.fileType == S_IFREG else {
              throw ITunesDBError.notFound(
                "Interrupted deletion staged an unexpected non-file")
            }
            guard Darwin.unlinkat(directoryDescriptor, journal.stagedName, 0) == 0 else {
              throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try DurableIO.synchronize(descriptor: directoryDescriptor)
          }
        } else if let stagedIdentity {
          guard stagedIdentity.fileType == S_IFREG else {
            // Preserve an unexpected substitute. Restoring its directory entry
            // is safe and leaves the journal behind for operator inspection.
            if Darwin.renameatx_np(
              directoryDescriptor, journal.stagedName,
              originalParent.descriptor, originalParent.leafName,
              UInt32(RENAME_EXCL)) == 0
            {
              try synchronizeDirectories(
                originalParent.descriptor, directoryDescriptor)
            }
            throw ITunesDBError.notFound(
              "Interrupted deletion staged an unexpected non-file")
          }
          guard
            Darwin.renameatx_np(
              directoryDescriptor, journal.stagedName,
              originalParent.descriptor, originalParent.leafName,
              UInt32(RENAME_EXCL)) == 0
          else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          try synchronizeDirectories(originalParent.descriptor, directoryDescriptor)
        } else {
          throw ITunesDBError.notFound("Interrupted deletion is missing its track file")
        }
      }

      guard Darwin.unlinkat(directoryDescriptor, journalName, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try DurableIO.synchronize(descriptor: directoryDescriptor)
      guard
        try identity(named: directoryName, in: rootDescriptor) == directoryIdentity
      else {
        throw ITunesDBError.notFound("Nightdrive deletion transaction directory changed")
      }
      guard Darwin.unlinkat(rootDescriptor, directoryName, AT_REMOVEDIR) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      try DurableIO.synchronize(descriptor: rootDescriptor)
    }

    guard itunesDirectoryIsLinked(itunesChain),
      (try? identity(named: rootName, in: itunesChain.itunesDescriptor)) == rootIdentity
    else {
      return
    }
    if Darwin.unlinkat(itunesChain.itunesDescriptor, rootName, AT_REMOVEDIR) == 0 {
      bestEffortSynchronize("iTunes directory after copy-transaction cleanup") {
        try DurableIO.synchronize(descriptor: itunesChain.itunesDescriptor)
      }
    }
  }

  private static func readJournal(in directoryDescriptor: Int32) throws -> Data {
    let descriptor = Darwin.openat(
      directoryDescriptor, journalName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let journalIdentity = try identity(of: descriptor)
    guard journalIdentity.fileType == S_IFREG else {
      throw ITunesDBError.badHeader("Nightdrive deletion journal is not a regular file")
    }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard status.st_size >= 0, status.st_size <= maximumJournalBytes else {
      throw ITunesDBError.badHeader("Nightdrive deletion journal exceeds safety limit")
    }
    let data = try handle.read(upToCount: maximumJournalBytes + 1) ?? Data()
    guard data.count <= maximumJournalBytes else {
      throw ITunesDBError.badHeader("Nightdrive deletion journal exceeds safety limit")
    }
    return data
  }

  private static func synchronizeDirectories(_ first: Int32, _ second: Int32) throws {
    var firstError: Error?
    do {
      try DurableIO.synchronize(descriptor: first)
    } catch {
      firstError = error
    }
    do {
      try DurableIO.synchronize(descriptor: second)
    } catch {
      if firstError == nil { firstError = error }
    }
    if let firstError { throw firstError }
  }

  private static func isTransactionDirectory(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard name.hasPrefix(prefix) else { return false }
    return UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }
}
