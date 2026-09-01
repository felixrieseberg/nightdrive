import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import OSLog
import Synchronization

extension IpodFileSystem {
  var artworkDir: URL { controlDir.appendingPathComponent("Artwork", isDirectory: true) }
  var artworkDBURL: URL { artworkDir.appendingPathComponent("ArtworkDB") }
  var artworkDBBackupURL: URL { artworkDir.appendingPathComponent("ArtworkDB.nightdrive.bak") }

  func ithmbURL(for spec: ArtworkImageSpec) -> URL {
    artworkDir.appendingPathComponent(spec.ithmbName)
  }
}

struct ArtworkImage: Sendable {
  var dbid: UInt64
  var data: Data
}

struct ArtworkAssignment: Equatable, Sendable {
  var mhiiID: UInt32
  var sourceImageSize: UInt32
}

struct ArtworkDatabaseLink: Codable, Equatable, Sendable {
  var dbid: UInt64
  var mhiiID: UInt32
  var sizeBytes: UInt32
  var count: UInt16

  static func links(in database: ITunesDatabase) -> [ArtworkDatabaseLink] {
    database.tracks.compactMap { track in
      guard let artwork = track.artwork, artwork.hasArtwork else { return nil }
      return ArtworkDatabaseLink(
        dbid: track.dbid, mhiiID: artwork.mhiiID,
        sizeBytes: artwork.sizeBytes, count: artwork.count)
    }.sorted { lhs, rhs in
      lhs.dbid == rhs.dbid ? lhs.mhiiID < rhs.mhiiID : lhs.dbid < rhs.dbid
    }
  }
}

struct ArtworkDatabaseTrackState: Codable, Equatable, Sendable {
  var dbid: UInt64
  var metadata: TrackMetadata
  var sizeBytes: UInt32
  var modificationMarker: UInt32
  var artwork: ArtworkDatabaseLink?

  static func states(in database: ITunesDatabase, dbids: Set<UInt64>)
    -> [ArtworkDatabaseTrackState]
  {
    database.tracks.compactMap { track in
      guard dbids.contains(track.dbid) else { return nil }
      let artwork = track.artwork.flatMap { value -> ArtworkDatabaseLink? in
        guard value.hasArtwork else { return nil }
        return ArtworkDatabaseLink(
          dbid: track.dbid, mhiiID: value.mhiiID,
          sizeBytes: value.sizeBytes, count: value.count)
      }
      return ArtworkDatabaseTrackState(
        dbid: track.dbid, metadata: TrackMetadata(track).normalized,
        sizeBytes: track.sizeBytes,
        modificationMarker: ITunesDBWriter.macTime(
          track.timeModified, timezoneShift: database.timezoneShift),
        artwork: artwork)
    }.sorted { $0.dbid < $1.dbid }
  }
}

/// An audio file installed by the same receipt as ArtworkDB and its ithmb
/// files. `liveURL` is validated against the marker-persisted `ipodPath`
/// before staging.
struct ArtworkMediaFileUpdate: Sendable {
  var liveURL: URL
  var ipodPath: String
  var data: Data
}

/// An installed artwork generation whose previous files stay available until
/// the matching iTunesDB write commits. The device mutation lock keeps each
/// receipt single-owner, so `@unchecked Sendable` carries it across the async
/// sync pass. The recovery marker is armed before installation and upgraded
/// after, so a partial install rolls back and an indeterminate database result
/// resolves against a complete generation.
final class ArtworkDBTransaction: @unchecked Sendable {
  typealias InstallationCheckpoint = (URL) throws -> Void
  typealias RecoveryMarkerWriter = @Sendable (Data, URL) throws -> Void
  typealias BackupReader = @Sendable (URL) throws -> Data
  typealias BackupWriter = @Sendable (Data, URL) throws -> Void

  private static let directoryPrefix = ".nightdrive-artwork-"
  private static let quarantinePrefix = ".nightdrive-quarantined-artwork-"
  private static let recoveryMarkerName = "recovery.plist"
  private static let ownerLockName = "owner.lock"
  private static let recoveryLockName = ".nightdrive-artwork.lock"
  private static let recoveryVersion = 1
  private static let maximumRecoveryMarkerBytes = 8 * 1_024 * 1_024
  private static let maximumRecoveryTargets = 128
  private static let maximumRecoveryLinks = 100_000
  private static let recoveryLogger = Logger(
    subsystem: "dev.nightdrive.Nightdrive", category: "ArtworkRecovery")
  private static let activeDirectories = Mutex<Set<String>>([])

  private enum State: Equatable {
    case prepared
    case installed
    case deferred
    case committed
    case rolledBack
  }

  private struct RecoveryTarget: Codable {
    let name: String
    let ipodPath: String?
    let hadPrevious: Bool
    let previousHash: Data?
    let installedHash: Data
  }

  private enum RecoveryPhase: String, Codable {
    case installing
    case databasePending
  }

  private struct RecoveryManifest: Codable {
    let version: Int
    let phase: RecoveryPhase
    let previousLinks: [ArtworkDatabaseLink]
    let intendedLinks: [ArtworkDatabaseLink]
    let previousTrackStates: [ArtworkDatabaseTrackState]?
    let intendedTrackStates: [ArtworkDatabaseTrackState]?
    let targets: [RecoveryTarget]
  }

  private struct Target {
    let name: String
    let ipodPath: String?
    let key: String
    let live: URL
    let staged: URL
    let previous: URL
    let displaced: URL
    let hadPrevious: Bool
  }

  private let fileSystem: IpodFileSystem
  private let directory: URL
  var recoveryDirectory: URL { directory }
  private let stagedDirectory: URL
  private let previousDirectory: URL
  private let displacedDirectory: URL
  private let targets: [Target]
  private var state = State.prepared
  private var oldFilesMoved: Set<String> = []
  private var newFilesInstalled: Set<String> = []
  private var ownerDescriptor: Int32 = -1
  private var ownsDirectory = false
  private var recoveryPrepared = false

  init(
    fileSystem: IpodFileSystem, liveURLs: [URL],
    mediaFileUpdates: [ArtworkMediaFileUpdate] = []
  ) throws {
    self.fileSystem = fileSystem
    let fm = FileManager.default
    try fileSystem.validateArtworkDirectory()
    directory = fileSystem.artworkDir.appendingPathComponent(
      Self.directoryPrefix + UUID().uuidString, isDirectory: true)
    stagedDirectory = directory.appendingPathComponent("new", isDirectory: true)
    previousDirectory = directory.appendingPathComponent("previous", isDirectory: true)
    displacedDirectory = directory.appendingPathComponent("displaced", isDirectory: true)

    var seen: Set<String> = []
    var preparedTargets: [Target] = []
    let artworkRoot = fileSystem.artworkDir.standardizedFileURL
    for live in liveURLs {
      guard live.deletingLastPathComponent().standardizedFileURL == artworkRoot,
        Self.isSafeTargetName(live.lastPathComponent)
      else {
        throw ITunesDBError.badHeader("Artwork target left iPod_Control/Artwork")
      }
      let key = live.standardizedFileURL.path
      guard seen.insert(key).inserted else {
        throw ITunesDBError.badHeader("Duplicate artwork file target")
      }
      let name = live.lastPathComponent
      preparedTargets.append(
        Target(
          name: name, ipodPath: nil, key: key, live: live,
          staged: stagedDirectory.appendingPathComponent(name),
          previous: previousDirectory.appendingPathComponent(name),
          displaced: displacedDirectory.appendingPathComponent(name),
          hadPrevious: fm.fileExists(atPath: live.path)))
    }
    for (index, update) in mediaFileUpdates.enumerated() {
      let live = try fileSystem.validatedMusicFileURL(forIpodPath: update.ipodPath)
      guard live.standardizedFileURL == update.liveURL.standardizedFileURL else {
        throw ITunesDBError.badHeader("Artwork media target does not match its iPod path")
      }
      let key = live.standardizedFileURL.path
      guard seen.insert(key).inserted else {
        throw ITunesDBError.badHeader("Duplicate artwork file target")
      }
      let name = "media-\(index)"
      preparedTargets.append(
        Target(
          name: name, ipodPath: update.ipodPath, key: key, live: live,
          staged: stagedDirectory.appendingPathComponent(name),
          previous: previousDirectory.appendingPathComponent(name),
          displaced: displacedDirectory.appendingPathComponent(name),
          hadPrevious: true))
    }
    targets = preparedTargets

    do {
      try fm.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
      try fm.createDirectory(at: previousDirectory, withIntermediateDirectories: true)
      try fm.createDirectory(at: displacedDirectory, withIntermediateDirectories: true)
      try acquireDirectoryOwnership()
      try DurableIO.synchronize(at: directory)
      try DurableIO.synchronize(at: fileSystem.artworkDir)
    } catch {
      fm.bestEffortRemoveItem(at: directory)
      throw error
    }
  }

  deinit {
    switch state {
    case .prepared:
      logRollbackFailureInDeinit { try rollback() }
    case .installed:
      if recoveryPrepared {
        state = .deferred
      } else {
        logRollbackFailureInDeinit { try rollback() }
      }
    case .deferred, .committed, .rolledBack:
      break
    }
    releaseDirectoryOwnership()
  }

  private func logRollbackFailureInDeinit(_ rollback: () throws -> Void) {
    do {
      try rollback()
    } catch {
      Self.recoveryLogger.error(
        "Artwork transaction rollback failed during teardown; recovery marker resolution will finish it: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  func stage(_ data: Data, for liveURL: URL) throws {
    guard state == .prepared,
      let target = targets.first(where: { $0.key == liveURL.standardizedFileURL.path })
    else {
      throw ITunesDBError.badHeader("Invalid artwork transaction state")
    }
    try fileSystem.validateArtworkDirectory()
    try data.write(to: target.staged, options: .atomic)
  }

  func install(
    checkpoint: InstallationCheckpoint? = nil,
    afterPreviousMoved: InstallationCheckpoint? = nil
  ) throws {
    guard state == .prepared else {
      throw ITunesDBError.badHeader("Invalid artwork transaction state")
    }
    try fileSystem.validateArtworkDirectory()
    let fm = FileManager.default
    guard targets.allSatisfy({ fm.fileExists(atPath: $0.staged.path) }) else {
      throw ITunesDBError.notFound("Artwork transaction is missing a staged file")
    }
    state = .installed
    do {
      for target in targets {
        try checkpoint?(target.live)
        if target.hadPrevious {
          try Self.moveRecognizingLateSuccess(from: target.live, to: target.previous)
          oldFilesMoved.insert(target.key)
          try DurableIO.synchronize(at: target.live.deletingLastPathComponent())
          try DurableIO.synchronize(at: previousDirectory)
          try afterPreviousMoved?(target.live)
        } else if fm.fileExists(atPath: target.live.path) {
          throw CocoaError(.fileWriteFileExists)
        }
        try Self.moveRecognizingLateSuccess(from: target.staged, to: target.live)
        newFilesInstalled.insert(target.key)
        try DurableIO.synchronize(at: stagedDirectory)
        try DurableIO.synchronize(at: target.live.deletingLastPathComponent())
      }
    } catch {
      let installationError = error
      do {
        try rollback()
      } catch {
        throw ArtworkDBTransactionError.rollbackFailed(
          operation: installationError, rollback: error, directory: directory)
      }
      throw installationError
    }
  }

  func prepareInstallationRecovery(previousLinks: [ArtworkDatabaseLink]) throws {
    guard state == .prepared else {
      throw ITunesDBError.badHeader("Invalid artwork transaction state")
    }
    try fileSystem.validateArtworkDirectory()
    let fm = FileManager.default
    guard targets.allSatisfy({ fm.fileExists(atPath: $0.staged.path) }) else {
      throw ITunesDBError.notFound("Artwork transaction is missing a staged file")
    }
    for target in targets {
      try DurableIO.synchronize(at: target.staged)
    }
    try DurableIO.synchronize(at: stagedDirectory)
    let recoveryTargets = try targets.map { target in
      let previousHash = target.hadPrevious ? try DurableIO.sha256(of: target.live) : nil
      return RecoveryTarget(
        name: target.name, ipodPath: target.ipodPath, hadPrevious: target.hadPrevious,
        previousHash: previousHash, installedHash: try DurableIO.sha256(of: target.staged))
    }
    try writeManifest(
      RecoveryManifest(
        version: Self.recoveryVersion, phase: .installing,
        previousLinks: previousLinks, intendedLinks: previousLinks,
        previousTrackStates: nil, intendedTrackStates: nil,
        targets: recoveryTargets))
    recoveryPrepared = true
  }

  /// Keeps the installed generation and turns the previous ArtworkDB into the
  /// user's one-generation backup. Old ithmb files are no longer needed once
  /// the iTunesDB links have committed. A backup failure leaves the receipt
  /// uncommitted so the caller can retain or retry it.
  func commit(
    backupReader: BackupReader = { try Data(contentsOf: $0) },
    backupWriter: BackupWriter = { try DurableIO.write($0, to: $1) }
  ) throws {
    guard state == .installed || state == .deferred else { return }
    try fileSystem.validateArtworkDirectory()
    if let databaseTarget = targets.first(where: { $0.live == fileSystem.artworkDBURL }),
      oldFilesMoved.contains(databaseTarget.key)
    {
      let data = try backupReader(databaseTarget.previous)
      try backupWriter(data, fileSystem.artworkDBBackupURL)
    }
    state = .committed
    FileManager.default.bestEffortRemoveItem(at: directory)
  }

  func rollback() throws {
    guard state == .prepared || state == .installed || state == .deferred else { return }
    try fileSystem.validateArtworkDirectory()
    let fm = FileManager.default
    var failures: [String] = []
    for target in targets {
      guard oldFilesMoved.contains(target.key) || newFilesInstalled.contains(target.key) else {
        continue
      }
      do {
        if oldFilesMoved.contains(target.key) {
          if newFilesInstalled.contains(target.key), fm.fileExists(atPath: target.live.path) {
            if fm.fileExists(atPath: target.displaced.path) {
              try fm.removeItem(at: target.displaced)
            }
            try Self.moveRecognizingLateSuccess(from: target.live, to: target.displaced)
            try DurableIO.synchronize(at: target.live.deletingLastPathComponent())
            try DurableIO.synchronize(at: displacedDirectory)
          }
          guard fm.fileExists(atPath: target.previous.path) else {
            throw ITunesDBError.notFound(
              "Artwork rollback is missing \(target.live.lastPathComponent)")
          }
          do {
            try Self.moveRecognizingLateSuccess(from: target.previous, to: target.live)
          } catch {
            if !fm.fileExists(atPath: target.live.path),
              fm.fileExists(atPath: target.displaced.path)
            {
              do {
                try Self.moveRecognizingLateSuccess(from: target.displaced, to: target.live)
              } catch let restoreError {
                Self.recoveryLogger.error(
                  "Restoring displaced artwork \(target.live.lastPathComponent, privacy: .public) failed during rollback: \(restoreError.localizedDescription, privacy: .public)"
                )
              }
            }
            throw error
          }
          try DurableIO.synchronize(at: previousDirectory)
          try DurableIO.synchronize(at: target.live.deletingLastPathComponent())
          fm.bestEffortRemoveItem(at: target.displaced)
          do {
            try DurableIO.synchronize(at: displacedDirectory)
          } catch {
            Self.recoveryLogger.debug(
              "Best-effort synchronize of the displaced-artwork directory failed: \(error.localizedDescription, privacy: .public)"
            )
          }
        } else if newFilesInstalled.contains(target.key),
          fm.fileExists(atPath: target.live.path)
        {
          do {
            try fm.removeItem(at: target.live)
          } catch {
            if fm.fileExists(atPath: target.live.path) { throw error }
          }
          try DurableIO.synchronize(at: target.live.deletingLastPathComponent())
        }
        oldFilesMoved.remove(target.key)
        newFilesInstalled.remove(target.key)
      } catch {
        failures.append("\(target.live.lastPathComponent): \(error.localizedDescription)")
      }
    }
    guard failures.isEmpty else {
      throw ITunesDBError.notFound(
        "Artwork rollback could not restore the previous generation (\(failures.joined(separator: "; "))). "
          + "Recovery files remain at \(directory.path)")
    }
    state = .rolledBack
    fm.bestEffortRemoveItem(at: directory)
  }

  func prepareRecovery(
    previousLinks: [ArtworkDatabaseLink], intendedLinks: [ArtworkDatabaseLink],
    previousTrackStates: [ArtworkDatabaseTrackState]? = nil,
    intendedTrackStates: [ArtworkDatabaseTrackState]? = nil,
    markerWriter: RecoveryMarkerWriter = { data, url in
      try ArtworkDBTransaction.writeRecoveryMarker(data, to: url)
    }
  ) throws {
    guard state == .installed else {
      throw ITunesDBError.badHeader("Invalid artwork transaction state")
    }
    try fileSystem.validateArtworkDirectory()
    let recoveryTargets = try targets.map { target in
      let previousHash = target.hadPrevious ? try DurableIO.sha256(of: target.previous) : nil
      return RecoveryTarget(
        name: target.name, ipodPath: target.ipodPath, hadPrevious: target.hadPrevious,
        previousHash: previousHash, installedHash: try DurableIO.sha256(of: target.live))
    }
    let manifest = RecoveryManifest(
      version: Self.recoveryVersion, phase: .databasePending,
      previousLinks: previousLinks,
      intendedLinks: intendedLinks, previousTrackStates: previousTrackStates,
      intendedTrackStates: intendedTrackStates, targets: recoveryTargets)
    try writeManifest(manifest, markerWriter: markerWriter)
    recoveryPrepared = true
  }

  private func writeManifest(
    _ manifest: RecoveryManifest,
    markerWriter: RecoveryMarkerWriter = { data, url in
      try ArtworkDBTransaction.writeRecoveryMarker(data, to: url)
    }
  ) throws {
    try Self.validate(manifest)
    let data = try PropertyListEncoder().encode(manifest)
    guard data.count <= Self.maximumRecoveryMarkerBytes else {
      throw ITunesDBError.badHeader("Artwork recovery marker exceeds its safety limit")
    }
    try markerWriter(data, directory.appendingPathComponent(Self.recoveryMarkerName))
  }

  func deferResolution() throws {
    if state == .deferred { return }
    guard state == .installed, recoveryPrepared else {
      throw ITunesDBError.badHeader("Artwork recovery was not prepared before the database write")
    }
    state = .deferred
  }

  func deferPreparedResolutionAfterCommitFailure() {
    guard state == .installed, recoveryPrepared else { return }
    state = .deferred
  }

  static func recoverDeferredTransactions(
    fileSystem: IpodFileSystem, initialDatabase: ITunesDatabase,
    rawDatabaseReader: () throws -> ITunesDatabase,
    afterDeferredTransactionsObserved: () throws -> Void = {}
  ) throws -> ITunesDatabase {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileSystem.artworkDir.path) else { return initialDatabase }
    do {
      try fileSystem.validateArtworkDirectory()
    } catch {
      reportRecoveryWarning("Artwork recovery directory is unavailable: \(error)")
      return initialDatabase
    }
    let observedDirectories: [URL]
    do {
      observedDirectories = try transactionDirectories(fileSystem: fileSystem)
    } catch {
      reportRecoveryWarning("Could not inspect artwork recovery transactions: \(error)")
      return initialDatabase
    }
    guard !observedDirectories.isEmpty else { return initialDatabase }
    try afterDeferredTransactionsObserved()

    let recoveryLock: RecoveryLock
    do {
      recoveryLock = try RecoveryLock(fileSystem: fileSystem)
    } catch {
      reportRecoveryWarning("Could not lock artwork recovery transactions: \(error)")
      return initialDatabase
    }
    return withExtendedLifetime(recoveryLock) {
      var returnedDatabase: ITunesDatabase
      do {
        returnedDatabase = try rawDatabaseReader()
      } catch {
        reportRecoveryWarning("Could not refresh iTunesDB during artwork recovery: \(error)")
        returnedDatabase = initialDatabase
      }
      let directories: [URL]
      do {
        directories = try transactionDirectories(fileSystem: fileSystem)
      } catch {
        reportRecoveryWarning("Could not rescan artwork recovery transactions: \(error)")
        return returnedDatabase
      }
      for transactionDirectory in directories {
        let transactionClaim: TransactionClaim?
        do {
          transactionClaim = try TransactionClaim(directory: transactionDirectory)
        } catch {
          reportRecoveryWarning(
            "Could not claim artwork transaction \(transactionDirectory.lastPathComponent): \(error)")
          continue
        }
        guard let transactionClaim else {
          continue
        }
        if let currentDatabase = withExtendedLifetime(
          transactionClaim,
          {
            resolveClaimedTransaction(
              transactionDirectory, fileSystem: fileSystem,
              rawDatabaseReader: rawDatabaseReader)
          })
        {
          returnedDatabase = currentDatabase
        }
      }
      return returnedDatabase
    }
  }

  private static func transactionDirectories(fileSystem: IpodFileSystem) throws -> [URL] {
    let fm = FileManager.default
    let root = fileSystem.artworkDir.standardizedFileURL
    let contents = try fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
    )
    var directories: [URL] = []
    for candidate in contents {
      let name = candidate.lastPathComponent
      guard name.hasPrefix(directoryPrefix),
        UUID(uuidString: String(name.dropFirst(directoryPrefix.count))) != nil,
        !isActiveDirectory(candidate)
      else { continue }
      do {
        let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
          candidate.deletingLastPathComponent().standardizedFileURL == root
        else {
          reportRecoveryWarning("Ignoring an unsafe artwork recovery directory: \(name)")
          continue
        }
        directories.append(candidate)
      } catch {
        reportRecoveryWarning("Could not inspect artwork recovery directory \(name): \(error)")
      }
    }
    return directories.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private static func resolveClaimedTransaction(
    _ directory: URL, fileSystem: IpodFileSystem,
    rawDatabaseReader: () throws -> ITunesDatabase
  ) -> ITunesDatabase? {
    let fm = FileManager.default
    let marker = directory.appendingPathComponent(recoveryMarkerName)
    guard fm.fileExists(atPath: marker.path) else {
      do {
        try fm.removeItem(at: directory)
        try DurableIO.synchronize(at: fileSystem.artworkDir)
        reportRecoveryWarning(
          "Removed abandoned marker-less artwork transaction \(directory.lastPathComponent)")
      } catch {
        reportRecoveryWarning(
          "Could not remove abandoned artwork transaction \(directory.lastPathComponent): \(error)")
      }
      return nil
    }

    let manifest: RecoveryManifest
    do {
      manifest = try readManifest(at: marker)
      try validate(manifest)
    } catch {
      quarantine(directory, fileSystem: fileSystem, reason: "invalid recovery marker: \(error)")
      return nil
    }

    let currentDatabase: ITunesDatabase
    do {
      currentDatabase = try rawDatabaseReader()
    } catch {
      reportRecoveryWarning(
        "Could not refresh iTunesDB for artwork transaction \(directory.lastPathComponent): \(error)")
      return nil
    }
    let generation: RecoveredGenerationValidation
    switch manifest.phase {
    case .installing:
      guard database(currentDatabase, matches: manifest.previousLinks, trackStates: nil) else {
        quarantine(
          directory, fileSystem: fileSystem,
          reason: "iTunesDB changed during an incomplete artwork installation")
        return currentDatabase
      }
      generation = .installingRollback
    case .databasePending:
      if database(
        currentDatabase, matches: manifest.intendedLinks,
        trackStates: manifest.intendedTrackStates)
      {
        generation = .installed
      } else if database(
        currentDatabase, matches: manifest.previousLinks,
        trackStates: manifest.previousTrackStates)
      {
        generation = .rollback
      } else {
        quarantine(
          directory, fileSystem: fileSystem,
          reason: "iTunesDB no longer matches either recorded artwork generation")
        return currentDatabase
      }
    }

    let paths: [RecoveryPaths]
    do {
      paths = try recoveryPaths(
        manifest, directory: directory, fileSystem: fileSystem,
        validateLiveGeneration: generation)
    } catch {
      quarantine(
        directory, fileSystem: fileSystem,
        reason: "artwork files no longer match a recoverable generation: \(error)")
      return currentDatabase
    }

    do {
      switch generation {
      case .installed:
        try commitRecovered(paths, directory: directory, fileSystem: fileSystem)
      case .rollback, .installingRollback:
        try rollbackRecovered(paths, directory: directory, fileSystem: fileSystem)
      }
    } catch {
      reportRecoveryWarning(
        "Artwork recovery for \(directory.lastPathComponent) will retry: \(error)")
    }
    return currentDatabase
  }

  private static func quarantine(
    _ directory: URL, fileSystem: IpodFileSystem, reason: String
  ) {
    let destination = fileSystem.artworkDir.appendingPathComponent(
      quarantinePrefix + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.moveItem(at: directory, to: destination)
      try DurableIO.synchronize(at: fileSystem.artworkDir)
      reportRecoveryWarning(
        "Quarantined artwork transaction \(directory.lastPathComponent) as "
          + "\(destination.lastPathComponent): \(reason)")
    } catch {
      reportRecoveryWarning(
        "Could not quarantine artwork transaction \(directory.lastPathComponent): \(error); "
          + "database access will continue")
    }
  }

  private static func reportRecoveryWarning(_ message: String) {
    recoveryLogger.warning("\(message, privacy: .public)")
  }

  private static func readManifest(at url: URL) throws -> RecoveryManifest {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ITunesDBError.badHeader("Invalid artwork recovery marker")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= maximumRecoveryMarkerBytes {
      let remaining = maximumRecoveryMarkerBytes + 1 - data.count
      let chunk = try handle.read(upToCount: min(4_096, remaining)) ?? Data()
      if chunk.isEmpty {
        return try PropertyListDecoder().decode(RecoveryManifest.self, from: data)
      }
      data.append(chunk)
    }
    throw ITunesDBError.badHeader("Artwork recovery marker exceeds its safety limit")
  }

  private static func validate(_ manifest: RecoveryManifest) throws {
    guard manifest.version == recoveryVersion,
      !manifest.targets.isEmpty, manifest.targets.count <= maximumRecoveryTargets,
      manifest.previousLinks.count <= maximumRecoveryLinks,
      manifest.intendedLinks.count <= maximumRecoveryLinks,
      manifest.previousTrackStates?.count ?? 0 <= maximumRecoveryLinks,
      manifest.intendedTrackStates?.count ?? 0 <= maximumRecoveryLinks,
      (manifest.previousTrackStates == nil) == (manifest.intendedTrackStates == nil)
    else {
      throw ITunesDBError.badHeader("Invalid artwork recovery marker")
    }
    switch manifest.phase {
    case .installing:
      guard manifest.previousLinks == manifest.intendedLinks,
        manifest.previousTrackStates == nil, manifest.intendedTrackStates == nil
      else {
        throw ITunesDBError.badHeader("Invalid installing artwork recovery marker")
      }
    case .databasePending:
      break
    }
    var names: Set<String> = []
    var mediaPaths: Set<String> = []
    for target in manifest.targets {
      let locationIsSafe: Bool
      if let ipodPath = target.ipodPath {
        locationIsSafe =
          isSafeMediaTargetName(target.name)
          && mediaPaths.insert(ipodPath.lowercased()).inserted
      } else {
        locationIsSafe = isSafeTargetName(target.name)
      }
      guard locationIsSafe, names.insert(target.name.lowercased()).inserted,
        target.installedHash.count == SHA256.Digest.byteCount,
        target.hadPrevious == (target.previousHash != nil),
        target.previousHash?.count == nil
          || target.previousHash?.count == SHA256.Digest.byteCount
      else {
        throw ITunesDBError.badHeader("Invalid artwork recovery target")
      }
    }
    if let previous = manifest.previousTrackStates,
      let intended = manifest.intendedTrackStates
    {
      guard Set(previous.map(\.dbid)).count == previous.count,
        Set(intended.map(\.dbid)).count == intended.count,
        Set(previous.map(\.dbid)) == Set(intended.map(\.dbid))
      else {
        throw ITunesDBError.badHeader("Invalid artwork recovery track state")
      }
    }
  }

  private static func database(
    _ database: ITunesDatabase, matches links: [ArtworkDatabaseLink],
    trackStates: [ArtworkDatabaseTrackState]?
  ) -> Bool {
    guard ArtworkDatabaseLink.links(in: database) == links else { return false }
    guard let trackStates else { return true }
    return ArtworkDatabaseTrackState.states(
      in: database, dbids: Set(trackStates.map(\.dbid))) == trackStates
  }

  private static func commitRecovered(
    _ paths: [RecoveryPaths], directory: URL, fileSystem: IpodFileSystem
  ) throws {
    try fileSystem.validateArtworkDirectory()
    if let database = paths.first(where: { $0.target.name == "ArtworkDB" }),
      database.target.hadPrevious
    {
      let data = try Data(contentsOf: database.previous, options: .mappedIfSafe)
      try DurableIO.write(data, to: fileSystem.artworkDBBackupURL)
    }
    try FileManager.default.removeItem(at: directory)
    try DurableIO.synchronize(at: fileSystem.artworkDir)
  }

  private static func rollbackRecovered(
    _ paths: [RecoveryPaths], directory: URL, fileSystem: IpodFileSystem
  ) throws {
    try fileSystem.validateArtworkDirectory()
    let fm = FileManager.default
    for path in paths {
      if path.target.hadPrevious {
        if fm.fileExists(atPath: path.previous.path) {
          if fm.fileExists(atPath: path.live.path) {
            guard !fm.fileExists(atPath: path.displaced.path) else {
              throw ITunesDBError.badHeader("Ambiguous artwork rollback state")
            }
            try moveRecognizingLateSuccess(from: path.live, to: path.displaced)
            try DurableIO.synchronize(at: path.live.deletingLastPathComponent())
            try DurableIO.synchronize(at: path.displaced.deletingLastPathComponent())
          }
          try moveRecognizingLateSuccess(from: path.previous, to: path.live)
          try DurableIO.synchronize(at: path.previous.deletingLastPathComponent())
          try DurableIO.synchronize(at: path.live.deletingLastPathComponent())
        }
        if fm.fileExists(atPath: path.displaced.path) {
          try fm.removeItem(at: path.displaced)
          try DurableIO.synchronize(at: path.displaced.deletingLastPathComponent())
        }
      } else if fm.fileExists(atPath: path.live.path) {
        try fm.removeItem(at: path.live)
        try DurableIO.synchronize(at: path.live.deletingLastPathComponent())
      }
    }
    try DurableIO.synchronize(at: fileSystem.artworkDir)
    try FileManager.default.removeItem(at: directory)
    try DurableIO.synchronize(at: fileSystem.artworkDir)
  }

  private enum RecoveredGenerationValidation {
    case installed
    case rollback
    case installingRollback
  }

  private struct RecoveryPaths {
    let target: RecoveryTarget
    let live: URL
    let staged: URL
    let previous: URL
    let displaced: URL
  }

  private static func recoveryPaths(
    _ manifest: RecoveryManifest, directory: URL, fileSystem: IpodFileSystem,
    validateLiveGeneration generation: RecoveredGenerationValidation
  ) throws -> [RecoveryPaths] {
    let previousDirectory = directory.appendingPathComponent("previous", isDirectory: true)
    let displacedDirectory = directory.appendingPathComponent("displaced", isDirectory: true)
    let stagedDirectory = directory.appendingPathComponent("new", isDirectory: true)
    try validateRecoveryChildDirectory(previousDirectory, parent: directory)
    try validateRecoveryChildDirectory(displacedDirectory, parent: directory)
    try validateRecoveryChildDirectory(stagedDirectory, parent: directory)
    return try manifest.targets.map { target in
      let live: URL
      if let ipodPath = target.ipodPath {
        guard isSafeMediaTargetName(target.name),
          let resolved = fileSystem.transactionMusicFileURL(forIpodPath: ipodPath)
        else {
          throw ITunesDBError.badHeader("Invalid artwork recovery media target")
        }
        live = resolved
      } else {
        guard isSafeTargetName(target.name) else {
          throw ITunesDBError.badHeader("Invalid artwork recovery target")
        }
        live = fileSystem.artworkDir.appendingPathComponent(target.name)
      }
      let paths = RecoveryPaths(
        target: target, live: live,
        staged: stagedDirectory.appendingPathComponent(target.name),
        previous: previousDirectory.appendingPathComponent(target.name),
        displaced: displacedDirectory.appendingPathComponent(target.name))
      let liveHash = try existingHash(paths.live)
      let stagedHash = try existingHash(paths.staged)
      let previousHash = try existingHash(paths.previous)
      let displacedHash = try existingHash(paths.displaced)
      switch generation {
      case .installed:
        guard liveHash == target.installedHash,
          stagedHash == nil, previousHash == target.previousHash, displacedHash == nil
        else {
          throw ITunesDBError.badHeader("Installed artwork generation failed recovery validation")
        }
      case .rollback:
        if target.hadPrevious {
          let notStarted =
            liveHash == target.installedHash && stagedHash == nil
            && previousHash == target.previousHash
            && displacedHash == nil
          let oldDisplaced =
            liveHash == nil && stagedHash == nil && previousHash == target.previousHash
            && displacedHash == target.installedHash
          let oldRestored =
            liveHash == target.previousHash && stagedHash == nil && previousHash == nil
            && (displacedHash == nil || displacedHash == target.installedHash)
          guard notStarted || oldDisplaced || oldRestored else {
            throw ITunesDBError.badHeader("Artwork rollback target is not a known transaction state")
          }
        } else {
          guard stagedHash == nil, previousHash == nil, displacedHash == nil,
            liveHash == nil || liveHash == target.installedHash
          else {
            throw ITunesDBError.badHeader("Artwork rollback target is not a known transaction state")
          }
        }
      case .installingRollback:
        if target.hadPrevious {
          let untouched =
            liveHash == target.previousHash && stagedHash == target.installedHash
            && previousHash == nil && displacedHash == nil
          let previousMoved =
            liveHash == nil && stagedHash == target.installedHash
            && previousHash == target.previousHash && displacedHash == nil
          let installed =
            liveHash == target.installedHash && stagedHash == nil
            && previousHash == target.previousHash && displacedHash == nil
          let oldDisplaced =
            liveHash == nil && stagedHash == nil
            && previousHash == target.previousHash && displacedHash == target.installedHash
          let oldRestored =
            liveHash == target.previousHash && previousHash == nil
            && (stagedHash == nil || stagedHash == target.installedHash)
            && (displacedHash == nil || displacedHash == target.installedHash)
          guard untouched || previousMoved || installed || oldDisplaced || oldRestored else {
            throw ITunesDBError.badHeader(
              "Partial artwork installation is not a known transaction state")
          }
        } else {
          let untouched =
            liveHash == nil && stagedHash == target.installedHash
            && previousHash == nil && displacedHash == nil
          let installed =
            liveHash == target.installedHash && stagedHash == nil
            && previousHash == nil && displacedHash == nil
          let rolledBack =
            liveHash == nil && stagedHash == nil
            && previousHash == nil && displacedHash == nil
          guard untouched || installed || rolledBack else {
            throw ITunesDBError.badHeader(
              "Partial artwork installation is not a known transaction state")
          }
        }
      }
      return paths
    }
  }

  private static func validateRecoveryChildDirectory(_ url: URL, parent: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true,
      url.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL
    else {
      throw ITunesDBError.badHeader("Invalid artwork recovery child directory")
    }
  }

  private static func existingHash(_ url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw ITunesDBError.badHeader("Artwork recovery target is not a regular file")
    }
    return try DurableIO.sha256(of: url)
  }

  private static func isSafeTargetName(_ name: String) -> Bool {
    name == "ArtworkDB"
      || name.range(of: #"^F[0-9]+_1[.]ithmb$"#, options: .regularExpression) != nil
  }

  private static func isSafeMediaTargetName(_ name: String) -> Bool {
    name.range(of: #"^media-[0-9]+$"#, options: .regularExpression) != nil
  }

  static func writeRecoveryMarker(_ data: Data, to url: URL) throws {
    try DurableIO.write(data, to: url)
  }

  private static func moveRecognizingLateSuccess(from source: URL, to destination: URL) throws {
    do {
      try FileManager.default.moveItem(at: source, to: destination)
    } catch {
      guard !FileManager.default.fileExists(atPath: source.path),
        FileManager.default.fileExists(atPath: destination.path)
      else { throw error }
    }
  }

  private func acquireDirectoryOwnership() throws {
    let lockURL = directory.appendingPathComponent(Self.ownerLockName)
    let pendingDescriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
    guard pendingDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    do {
      var status = stat()
      guard Darwin.fstat(pendingDescriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG
      else {
        throw ITunesDBError.badHeader("Invalid artwork transaction owner lock")
      }
      guard Darwin.lockf(pendingDescriptor, F_TLOCK, 0) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } catch {
      Darwin.close(pendingDescriptor)
      throw error
    }
    ownerDescriptor = pendingDescriptor
    ownsDirectory = true
    Self.activeDirectories.withLock {
      _ = $0.insert(directory.standardizedFileURL.path)
    }
  }

  private func releaseDirectoryOwnership() {
    guard ownsDirectory else { return }
    if ownerDescriptor >= 0 {
      Darwin.lockf(ownerDescriptor, F_ULOCK, 0)
      Darwin.close(ownerDescriptor)
      ownerDescriptor = -1
    }
    Self.activeDirectories.withLock {
      _ = $0.remove(directory.standardizedFileURL.path)
    }
    ownsDirectory = false
  }

  private static func isActiveDirectory(_ directory: URL) -> Bool {
    activeDirectories.withLock {
      $0.contains(directory.standardizedFileURL.path)
    }
  }

  private final class TransactionClaim {
    private var descriptor: Int32 = -1

    init?(directory: URL) throws {
      let lockURL = directory.appendingPathComponent(ownerLockName)
      descriptor = Darwin.open(lockURL.path, O_RDWR | O_NOFOLLOW)
      if descriptor < 0, errno == ENOENT { return nil }
      guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      var status = stat()
      guard Darwin.fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG
      else {
        Darwin.close(descriptor)
        descriptor = -1
        throw ITunesDBError.badHeader("Invalid artwork transaction owner lock")
      }
      guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
        let lockError = errno
        Darwin.close(descriptor)
        descriptor = -1
        if lockError == EACCES || lockError == EAGAIN { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
      }
    }

    deinit {
      if descriptor >= 0 {
        Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
      }
    }
  }

  /// Serializes two synchronous readers without retaking the async device
  /// lock: in-process by Artwork directory, POSIX across Nightdrive processes.
  /// The per-directory `NSLock` is held from `init` to `deinit`, which
  /// `Mutex.withLock` cannot express; only the registry uses `Mutex`.
  private final class RecoveryLock {
    private static let processLocks = Mutex<[String: NSLock]>([:])

    private let processLock: NSLock
    private var descriptor: Int32 = -1

    init(fileSystem: IpodFileSystem) throws {
      let key = fileSystem.artworkDir.standardizedFileURL.path
      processLock = Self.processLocks.withLock { locks in
        if let existing = locks[key] { return existing }
        let created = NSLock()
        locks[key] = created
        return created
      }
      processLock.lock()
      do {
        try fileSystem.validateArtworkDirectory()
        let lockURL = fileSystem.artworkDir.appendingPathComponent(recoveryLockName)
        descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG
        else {
          throw ITunesDBError.badHeader("Invalid artwork recovery lock file")
        }
        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      } catch {
        if descriptor >= 0 { Darwin.close(descriptor) }
        descriptor = -1
        processLock.unlock()
        throw error
      }
    }

    deinit {
      if descriptor >= 0 {
        Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
      }
      processLock.unlock()
    }
  }
}

enum ArtworkDBTransactionError: LocalizedError {
  case rollbackFailed(operation: Error, rollback: Error, directory: URL)
  case resolutionFailed(operation: Error, resolution: Error, directory: URL)

  var errorDescription: String? {
    switch self {
    case .rollbackFailed(let operation, let rollback, let directory):
      return String(
        localized:
          "Album artwork could not be installed (\(operation.localizedDescription)), and the previous artwork generation could not be fully restored (\(rollback.localizedDescription)). Recovery files remain at \(directory.path)"
      )
    case .resolutionFailed(let operation, let resolution, let directory):
      return String(
        localized:
          "The iPod database write reported an error (\(operation.localizedDescription)), and the matching artwork generation could not be resolved safely (\(resolution.localizedDescription)). Recovery files remain at \(directory.path)"
      )
    }
  }
}

struct ArtworkDBWrite: Sendable {
  var assignments: [UInt64: ArtworkAssignment]
  var transaction: ArtworkDBTransaction
}

enum ArtworkDBWriter {
  static let firstImageID: UInt32 = 0x40

  static func write(
    images: [ArtworkImage], specs: [ArtworkImageSpec], fileSystem: IpodFileSystem
  ) throws -> [UInt64: ArtworkAssignment] {
    let write = try beginWrite(images: images, specs: specs, fileSystem: fileSystem)
    try write.transaction.commit()
    return write.assignments
  }

  static func beginWrite(
    images: [ArtworkImage], specs: [ArtworkImageSpec], fileSystem: IpodFileSystem,
    mediaFileUpdates: [ArtworkMediaFileUpdate] = [],
    imageIDsByDbid: [UInt64: UInt32] = [:],
    preinstallPreviousLinks: [ArtworkDatabaseLink]? = nil,
    installationCheckpoint: ArtworkDBTransaction.InstallationCheckpoint? = nil,
    afterPreviousMoved: ArtworkDBTransaction.InstallationCheckpoint? = nil
  ) throws -> ArtworkDBWrite {
    precondition(!specs.isEmpty, "artwork specs are required to write artwork")
    let fm = FileManager.default
    try fileSystem.validateControlDirectory()
    try fileSystem.validateArtworkDirectory()
    try fm.createDirectory(at: fileSystem.artworkDir, withIntermediateDirectories: true)
    try fileSystem.validateArtworkDirectory()

    struct UniqueImage {
      let data: Data
      let cgImage: CGImage
    }
    var tileIndexByDigest: [Data: Int] = [:]
    var uniqueImages: [UniqueImage] = []
    struct Record {
      let dbid: UInt64
      let mhiiID: UInt32
      let sourceSize: UInt32
      let tileIndex: Int
    }
    let imageDbids = Set(images.map(\.dbid))
    let imageCounts = images.reduce(into: [UInt64: Int]()) { counts, image in
      counts[image.dbid, default: 0] += 1
    }
    guard Set(imageIDsByDbid.keys).isSubset(of: imageDbids),
      imageIDsByDbid.keys.allSatisfy({ imageCounts[$0] == 1 }),
      Set(imageIDsByDbid.values).count == imageIDsByDbid.count,
      imageIDsByDbid.values.allSatisfy({ $0 > 0 && $0 < UInt32.max })
    else {
      throw ITunesDBError.badHeader("Invalid artwork image identifiers")
    }
    var usedImageIDs = Set(imageIDsByDbid.values)
    var nextGeneratedImageID = firstImageID
    func imageID(for dbid: UInt64) throws -> UInt32 {
      if let preferred = imageIDsByDbid[dbid] { return preferred }
      while usedImageIDs.contains(nextGeneratedImageID) {
        guard nextGeneratedImageID < UInt32.max else {
          throw ITunesDBError.badHeader("Artwork image identifiers are exhausted")
        }
        nextGeneratedImageID += 1
      }
      guard nextGeneratedImageID < UInt32.max else {
        throw ITunesDBError.badHeader("Artwork image identifiers are exhausted")
      }
      let generated = nextGeneratedImageID
      usedImageIDs.insert(generated)
      return generated
    }
    var records: [Record] = []
    for image in images.sorted(by: { $0.dbid < $1.dbid }) {
      let mhiiID = try imageID(for: image.dbid)
      let digest = ArtworkPixels.sha256(image.data)
      if let index = tileIndexByDigest[digest] {
        records.append(
          Record(
            dbid: image.dbid, mhiiID: mhiiID,
            sourceSize: UInt32(clamping: image.data.count), tileIndex: index))
        continue
      }
      guard let cgImage = decode(image.data) else { continue }
      let index = uniqueImages.count
      uniqueImages.append(UniqueImage(data: image.data, cgImage: cgImage))
      tileIndexByDigest[digest] = index
      records.append(
        Record(
          dbid: image.dbid, mhiiID: mhiiID,
          sourceSize: UInt32(clamping: image.data.count), tileIndex: index))
    }

    let transaction = try ArtworkDBTransaction(
      fileSystem: fileSystem,
      liveURLs: specs.map { fileSystem.ithmbURL(for: $0) } + [fileSystem.artworkDBURL],
      mediaFileUpdates: mediaFileUpdates)

    for spec in specs {
      var ithmb = Data(capacity: uniqueImages.count * spec.bytesPerTile)
      for unique in uniqueImages {
        ithmb.append(ArtworkPixels.tileData(image: unique.cgImage, spec: spec))
      }
      try transaction.stage(ithmb, for: fileSystem.ithmbURL(for: spec))
    }

    var writer = ByteWriter(
      capacity: estimatedCapacity(recordCount: records.count, specCount: specs.count))
    let mhfdStart = writer.count
    writer.tag("mhfd")
    writer.u32(132)
    writer.u32(0)  // total length, patched
    writer.u32(0)
    writer.u32(2)
    writer.u32(3)  // children: image list, album list, file list
    writer.u32(0)
    let highestImageID = records.map(\.mhiiID).max()
    writer.u32(highestImageID.map { $0 + 1 } ?? firstImageID)  // next image id
    writer.u64(0)
    writer.u64(0)
    writer.u32(2)
    writer.zero32(3)
    writer.u32(2)
    writer.zero32(16)
    assert(writer.count - mhfdStart == 132)

    let imageListStart = writer.count
    writeMhsdHeader(&writer, type: 1)
    writer.tag("mhli")
    writer.u32(92)
    writer.u32(UInt32(records.count))
    writer.zero32(20)
    for record in records {
      writeMhii(
        &writer, id: record.mhiiID, dbid: record.dbid,
        sourceSize: record.sourceSize, tileIndex: record.tileIndex, specs: specs)
    }
    writer.patchU32(UInt32(writer.count - imageListStart), at: imageListStart + 8)

    let albumListStart = writer.count
    writeMhsdHeader(&writer, type: 2)
    writer.tag("mhla")
    writer.u32(92)
    writer.u32(0)
    writer.zero32(20)
    writer.patchU32(UInt32(writer.count - albumListStart), at: albumListStart + 8)

    let fileListStart = writer.count
    writeMhsdHeader(&writer, type: 3)
    writer.tag("mhlf")
    writer.u32(92)
    writer.u32(UInt32(specs.count))
    writer.zero32(20)
    for spec in specs {
      writer.tag("mhif")
      writer.u32(124)
      writer.u32(124)
      writer.u32(0)
      writer.u32(spec.formatID)
      writer.u32(UInt32(spec.bytesPerTile))
      writer.zero32(25)
    }
    writer.patchU32(UInt32(writer.count - fileListStart), at: fileListStart + 8)

    writer.patchU32(UInt32(writer.count - mhfdStart), at: mhfdStart + 8)

    var assignments: [UInt64: ArtworkAssignment] = [:]
    for record in records {
      assignments[record.dbid] = ArtworkAssignment(
        mhiiID: record.mhiiID, sourceImageSize: record.sourceSize)
    }
    try transaction.stage(writer.data, for: fileSystem.artworkDBURL)
    for update in mediaFileUpdates {
      try transaction.stage(update.data, for: update.liveURL)
    }
    if let preinstallPreviousLinks {
      try transaction.prepareInstallationRecovery(previousLinks: preinstallPreviousLinks)
    }
    try transaction.install(
      checkpoint: installationCheckpoint, afterPreviousMoved: afterPreviousMoved)
    return ArtworkDBWrite(assignments: assignments, transaction: transaction)
  }

  static func estimatedCapacity(recordCount: Int, specCount: Int) -> Int {
    guard recordCount >= 0, specCount >= 0 else { return 0 }
    let specBytes = specCount.multipliedReportingOverflow(by: 192)
    guard !specBytes.overflow else { return 0 }
    let bytesPerRecord = specBytes.partialValue.addingReportingOverflow(256)
    guard !bytesPerRecord.overflow else { return 0 }
    let recordBytes = recordCount.multipliedReportingOverflow(by: bytesPerRecord.partialValue)
    guard !recordBytes.overflow else { return 0 }
    let estimated = recordBytes.partialValue.addingReportingOverflow(1_024)
    return estimated.overflow ? 0 : estimated.partialValue
  }

  private static func writeMhsdHeader(_ writer: inout ByteWriter, type: UInt32) {
    writer.tag("mhsd")
    writer.u32(96)
    writer.u32(0)  // total length, patched by the caller
    writer.u32(type)
    writer.zero32(20)
  }

  private static func writeMhii(
    _ writer: inout ByteWriter, id: UInt32, dbid: UInt64, sourceSize: UInt32,
    tileIndex: Int, specs: [ArtworkImageSpec]
  ) {
    let start = writer.count
    writer.tag("mhii")
    writer.u32(152)
    writer.u32(0)  // total length, patched
    writer.u32(UInt32(specs.count))  // child mhods
    writer.u32(id)
    writer.u64(dbid)
    writer.u32(0)
    writer.u32(0)  // rating
    writer.u32(0)
    writer.u32(0)  // original date
    writer.u32(0)  // digitized date
    writer.u32(sourceSize)
    writer.zero32(25)
    assert(writer.count - start == 152)
    for spec in specs {
      writeThumbnailMhod(&writer, spec: spec, tileIndex: tileIndex)
    }
    writer.patchU32(UInt32(writer.count - start), at: start + 8)
  }

  private static func writeThumbnailMhod(
    _ writer: inout ByteWriter, spec: ArtworkImageSpec, tileIndex: Int
  ) {
    let containerStart = writer.count
    writeArtworkMhodHeader(&writer, type: 2)

    let mhniStart = writer.count
    writer.tag("mhni")
    writer.u32(76)
    writer.u32(0)  // total length, patched
    writer.u32(1)  // one child: the file-name mhod
    writer.u32(spec.formatID)
    writer.u32(UInt32(tileIndex * spec.bytesPerTile))
    writer.u32(UInt32(spec.bytesPerTile))
    writer.u16(0)  // vertical padding (tiles are letterboxed, not padded)
    writer.u16(0)  // horizontal padding
    writer.u16(UInt16(spec.height))
    writer.u16(UInt16(spec.width))
    writer.zero32(10)
    assert(writer.count - mhniStart == 76)

    let nameStart = writer.count
    writeArtworkMhodHeader(&writer, type: 3)
    let name = ":" + spec.ithmbName
    let utf16 = LEBytes.utf16(name)
    writer.u32(UInt32(utf16.count))
    writer.u32(2)  // encoding: UTF-16LE
    writer.u32(0)
    writer.bytes(Data(utf16))
    writer.patchU32(UInt32(writer.count - nameStart), at: nameStart + 8)

    writer.patchU32(UInt32(writer.count - mhniStart), at: mhniStart + 8)
    writer.patchU32(UInt32(writer.count - containerStart), at: containerStart + 8)
  }

  private static func writeArtworkMhodHeader(_ writer: inout ByteWriter, type: UInt16) {
    writer.tag("mhod")
    writer.u32(24)
    writer.u32(0)  // total length, patched by the caller
    writer.u16(type)
    writer.u16(0)
    writer.u32(0)
    writer.u32(0)
  }

  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}

enum ArtworkPixels {
  static func rgb565(r: UInt8, g: UInt8, b: UInt8) -> UInt16 {
    (UInt16(r) >> 3) << 11 | (UInt16(g) >> 2) << 5 | UInt16(b) >> 3
  }

  static func aspectFitRect(imageSize: CGSize, in canvas: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0, canvas.width > 0, canvas.height > 0 else {
      return CGRect(origin: .zero, size: canvas)
    }
    let scale = min(canvas.width / imageSize.width, canvas.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
      x: (canvas.width - size.width) / 2,
      y: (canvas.height - size.height) / 2,
      width: size.width, height: size.height)
  }

  static func tileData(image: CGImage, spec: ArtworkImageSpec) -> Data {
    let width = spec.width
    let height = spec.height
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: &rgba, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return Data(count: spec.bytesPerTile)
    }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.interpolationQuality = .high
    context.draw(
      image,
      in: aspectFitRect(
        imageSize: CGSize(width: image.width, height: image.height),
        in: CGSize(width: CGFloat(width), height: CGFloat(height))))

    var tile = Data(capacity: spec.bytesPerTile)
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      let pixel = rgb565(r: rgba[offset], g: rgba[offset + 1], b: rgba[offset + 2])
      if spec.bigEndian {
        tile.append(UInt8(pixel >> 8))
        tile.append(UInt8(pixel & 0xFF))
      } else {
        tile.append(UInt8(pixel & 0xFF))
        tile.append(UInt8(pixel >> 8))
      }
    }
    return tile
  }

  static func sha256(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).hexString
  }
}

struct ArtworkDatabaseImage: Equatable, Sendable {
  struct Thumbnail: Equatable, Sendable {
    var formatID: UInt32
    var fileName: String
    var ithmbOffset: UInt32
    var imageSize: UInt32
    var width: Int
    var height: Int
    var childCount: Int
    var fileNameChildCount: Int
  }

  var mhiiID: UInt32
  var trackDbid: UInt64
  var sourceImageSize: UInt32
  var childCount: Int
  var thumbnails: [Thumbnail]
}

enum ArtworkDBReader {
  static func read(_ data: Data) throws -> [ArtworkDatabaseImage] {
    let r = ByteReader(data)
    guard try r.tag(0) == "mhfd" else {
      throw ITunesDBError.badHeader("expected mhfd")
    }
    let headerLen = Int(try r.u32(4))
    let totalLen = Int(try r.u32(8))
    guard headerLen >= 40, totalLen >= headerLen, totalLen <= r.count else {
      throw ITunesDBError.truncated("mhfd lengths")
    }
    var images: [ArtworkDatabaseImage] = []
    var pos = headerLen
    while pos + 16 <= totalLen {
      guard try r.tag(pos) == "mhsd" else {
        throw ITunesDBError.badHeader("expected mhsd at \(pos)")
      }
      let sectionHeaderLen = Int(try r.u32(pos + 4))
      let sectionTotal = Int(try r.u32(pos + 8))
      let sectionType = try r.u32(pos + 12)
      guard sectionHeaderLen >= 16, sectionTotal >= sectionHeaderLen,
        pos + sectionTotal <= totalLen
      else {
        throw ITunesDBError.truncated("mhsd lengths at \(pos)")
      }
      if sectionType == 1 {
        images = try readImageList(
          r, at: pos + sectionHeaderLen, end: pos + sectionTotal)
      }
      pos += sectionTotal
    }
    return images
  }

  private static func readImageList(
    _ r: ByteReader, at start: Int, end: Int
  ) throws -> [ArtworkDatabaseImage] {
    guard try r.tag(start) == "mhli" else {
      throw ITunesDBError.badHeader("expected mhli")
    }
    let headerLen = Int(try r.u32(start + 4))
    let count = Int(try r.u32(start + 8))
    guard headerLen >= 12, headerLen <= end - start, count <= 1_000_000 else {
      throw ITunesDBError.badHeader("implausible mhli")
    }
    let recordsStart = start + headerLen
    guard count <= (end - recordsStart) / 52 else {
      throw ITunesDBError.badHeader("image count \(count) exceeds mhli bounds")
    }
    var images: [ArtworkDatabaseImage] = []
    images.reserveCapacity(count)
    var pos = recordsStart
    for _ in 0..<count {
      guard pos + 16 <= end, try r.tag(pos) == "mhii" else {
        throw ITunesDBError.badHeader("expected mhii at \(pos)")
      }
      let mhiiHeaderLen = Int(try r.u32(pos + 4))
      let mhiiTotal = Int(try r.u32(pos + 8))
      let childCount = Int(try r.u32(pos + 12))
      guard mhiiHeaderLen >= 52, mhiiTotal >= mhiiHeaderLen, pos + mhiiTotal <= end,
        childCount <= 64
      else {
        throw ITunesDBError.truncated("mhii lengths at \(pos)")
      }
      var image = ArtworkDatabaseImage(
        mhiiID: try r.u32(pos + 16),
        trackDbid: try r.u64(pos + 20),
        sourceImageSize: try r.u32(pos + 48),
        childCount: childCount,
        thumbnails: [])
      var childPos = pos + mhiiHeaderLen
      for _ in 0..<childCount {
        let child = try readMhod(r, at: childPos, end: pos + mhiiTotal)
        if let thumbnail = child.thumbnail {
          image.thumbnails.append(thumbnail)
        }
        childPos += child.totalLen
      }
      images.append(image)
      pos += mhiiTotal
    }
    return images
  }

  private struct ParsedMhod {
    var totalLen: Int
    var type: UInt16
    var thumbnail: ArtworkDatabaseImage.Thumbnail?
    var string: String?
  }

  private static func readMhod(_ r: ByteReader, at pos: Int, end: Int) throws -> ParsedMhod {
    guard pos + 16 <= end, try r.tag(pos) == "mhod" else {
      throw ITunesDBError.badHeader("expected artwork mhod at \(pos)")
    }
    let headerLen = Int(try r.u32(pos + 4))
    let totalLen = Int(try r.u32(pos + 8))
    let type = try r.u16(pos + 12)
    guard headerLen >= 16, totalLen >= headerLen, pos + totalLen <= end else {
      throw ITunesDBError.truncated("artwork mhod lengths at \(pos)")
    }
    var parsed = ParsedMhod(totalLen: totalLen, type: type)
    switch type {
    case 2:
      parsed.thumbnail = try readMhni(r, at: pos + headerLen, end: pos + totalLen)
    case 1, 3:
      let stringLen = Int(try r.u32(pos + headerLen))
      let stringStart = pos + headerLen + 12
      guard stringLen >= 0, stringStart + stringLen <= pos + totalLen else {
        throw ITunesDBError.truncated("artwork string at \(pos)")
      }
      let bytes = try r.slice(stringStart, stringLen)
      parsed.string = LEBytes.utf16String(bytes)
    default:
      break
    }
    return parsed
  }

  private static func readMhni(
    _ r: ByteReader, at pos: Int, end: Int
  ) throws -> ArtworkDatabaseImage.Thumbnail {
    guard pos + 36 <= end, try r.tag(pos) == "mhni" else {
      throw ITunesDBError.badHeader("expected mhni at \(pos)")
    }
    let headerLen = Int(try r.u32(pos + 4))
    let totalLen = Int(try r.u32(pos + 8))
    let childCount = Int(try r.u32(pos + 12))
    guard headerLen >= 36, totalLen >= headerLen, pos + totalLen <= end, childCount <= 8 else {
      throw ITunesDBError.truncated("mhni lengths at \(pos)")
    }
    var thumbnail = ArtworkDatabaseImage.Thumbnail(
      formatID: try r.u32(pos + 16),
      fileName: "",
      ithmbOffset: try r.u32(pos + 20),
      imageSize: try r.u32(pos + 24),
      width: Int(try r.u16(pos + 34)),
      height: Int(try r.u16(pos + 32)),
      childCount: childCount, fileNameChildCount: 0)
    var childPos = pos + headerLen
    for _ in 0..<childCount {
      let child = try readMhod(r, at: childPos, end: pos + totalLen)
      if child.type == 3, let string = child.string {
        thumbnail.fileName = string
        thumbnail.fileNameChildCount += 1
      }
      childPos += child.totalLen
    }
    return thumbnail
  }
}
