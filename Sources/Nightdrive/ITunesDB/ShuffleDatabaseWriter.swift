import CryptoKit
import Darwin
import Foundation

enum ShuffleDatabaseWriter {
  typealias FileInstaller = (_ staged: URL, _ live: URL) throws -> Void

  enum InstallCheckpoint: CaseIterable, Equatable {
    case markerWritten
    case databaseInstalled
    case shuffleDatabaseInstalled
  }

  enum RecoveryOutcome: Equatable {
    case committed
    case rolledBack
  }

  enum RecoveryCheckpoint: CaseIterable, Equatable {
    case databaseRestored
    case shuffleDatabaseRestored
  }

  private enum LiveGeneration: Equatable {
    case old
    case new
  }

  private struct Transaction: Codable {
    let version: Int
    let hadDatabase: Bool
    let hadShuffleDatabase: Bool
    let newDatabaseHash: Data
    let newShuffleDatabaseHash: Data
    let oldDatabaseHash: Data?
    let oldShuffleDatabaseHash: Data?
  }

  private static let transactionVersion = 1
  private static let maximumMarkerBytes = 16 * 1_024
  private static let markerName = ".nightdrive-shuffle-database-transaction.plist"
  private static let quarantinedMarkerPrefix =
    ".nightdrive-quarantined-shuffle-database-transaction-"
  private static let stagedDatabaseName = ".nightdrive-shuffle-iTunesDB.next"
  private static let stagedShuffleDatabaseName = ".nightdrive-shuffle-iTunesSD.next"
  private static let restoreDatabaseName = ".nightdrive-shuffle-iTunesDB.restore"
  private static let restoreShuffleDatabaseName = ".nightdrive-shuffle-iTunesSD.restore"

  static func install(
    databaseData: Data,
    shuffleData: Data,
    fileSystem: IpodFileSystem,
    fileInstaller: FileInstaller = installStagedFile,
    after checkpoint: (InstallCheckpoint) throws -> Void = { _ in }
  ) throws {
    let deviceLock = try IpodDeviceLock.shuffle(fileSystem: fileSystem)
    try withExtendedLifetime(deviceLock) {
      try installUnlocked(
        databaseData: databaseData, shuffleData: shuffleData,
        fileSystem: fileSystem, fileInstaller: fileInstaller, after: checkpoint)
    }
  }

  private static func installUnlocked(
    databaseData: Data,
    shuffleData: Data,
    fileSystem: IpodFileSystem,
    fileInstaller: FileInstaller,
    after checkpoint: (InstallCheckpoint) throws -> Void
  ) throws {
    let fm = FileManager.default
    let recovery = recoveryCoordinator(fileSystem: fileSystem)
    try recovery.rejectQuarantinedMarkers()
    _ = try recovery.runStrictly {
      try recoverIfNeededUnlocked(fileSystem: fileSystem)
    }
    let artifacts = artifacts(fileSystem)
    try cleanupTransientFiles(fileSystem: fileSystem)

    try DurableIO.write(databaseData, to: artifacts.stagedDatabase)
    try DurableIO.write(shuffleData, to: artifacts.stagedShuffleDatabase)

    let hadDatabase = fm.fileExists(atPath: fileSystem.databaseURL.path)
    let hadShuffleDatabase = fm.fileExists(atPath: fileSystem.shuffleDatabaseURL.path)
    let oldDatabaseHash = try prepareBackup(
      live: fileSystem.databaseURL, backup: fileSystem.databaseBackupURL,
      existed: hadDatabase)
    let oldShuffleDatabaseHash = try prepareBackup(
      live: fileSystem.shuffleDatabaseURL, backup: fileSystem.shuffleDatabaseBackupURL,
      existed: hadShuffleDatabase)
    let transaction = Transaction(
      version: transactionVersion,
      hadDatabase: hadDatabase,
      hadShuffleDatabase: hadShuffleDatabase,
      newDatabaseHash: hash(databaseData),
      newShuffleDatabaseHash: hash(shuffleData),
      oldDatabaseHash: oldDatabaseHash,
      oldShuffleDatabaseHash: oldShuffleDatabaseHash)
    try writeMarker(transaction, fileSystem: fileSystem)
    try checkpoint(.markerWritten)

    try fileInstaller(artifacts.stagedDatabase, fileSystem.databaseURL)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.databaseInstalled)

    try fileInstaller(artifacts.stagedShuffleDatabase, fileSystem.shuffleDatabaseURL)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.shuffleDatabaseInstalled)

    try validateLiveNewGeneration(transaction, fileSystem: fileSystem)
    try cleanupTransaction(fileSystem: fileSystem)
  }

  static func recoverIfNeeded(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws -> RecoveryOutcome? {
    try recoveryCoordinator(fileSystem: fileSystem).recoverStrictly(
      acquiringLock: { try IpodDeviceLock.shuffle(fileSystem: fileSystem) },
      recovery: { try recoverIfNeededUnlocked(fileSystem: fileSystem, after: checkpoint) })
  }

  private static func recoverIfNeededUnlocked(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws -> RecoveryOutcome? {
    let artifacts = artifacts(fileSystem)
    guard FileManager.default.fileExists(atPath: artifacts.marker.path) else { return nil }
    let transaction = try readMarker(at: artifacts.marker)
    try validateMarker(transaction)

    let liveDatabaseGeneration = try classifyLiveGeneration(
      fileSystem.databaseURL, existedBefore: transaction.hadDatabase,
      oldHash: transaction.oldDatabaseHash, newHash: transaction.newDatabaseHash)
    let liveShuffleDatabaseGeneration = try classifyLiveGeneration(
      fileSystem.shuffleDatabaseURL, existedBefore: transaction.hadShuffleDatabase,
      oldHash: transaction.oldShuffleDatabaseHash,
      newHash: transaction.newShuffleDatabaseHash)
    if liveDatabaseGeneration == .new, liveShuffleDatabaseGeneration == .new {
      try cleanupTransaction(fileSystem: fileSystem)
      return .committed
    }

    try validateBackup(
      fileSystem.databaseBackupURL, existed: transaction.hadDatabase,
      expectedHash: transaction.oldDatabaseHash)
    try validateBackup(
      fileSystem.shuffleDatabaseBackupURL, existed: transaction.hadShuffleDatabase,
      expectedHash: transaction.oldShuffleDatabaseHash)

    try restore(
      backup: fileSystem.databaseBackupURL, live: fileSystem.databaseURL,
      temporary: artifacts.restoreDatabase, existed: transaction.hadDatabase)
    try checkpoint(.databaseRestored)
    try restore(
      backup: fileSystem.shuffleDatabaseBackupURL, live: fileSystem.shuffleDatabaseURL,
      temporary: artifacts.restoreShuffleDatabase, existed: transaction.hadShuffleDatabase)
    try checkpoint(.shuffleDatabaseRestored)

    try validateLiveOldGeneration(transaction, fileSystem: fileSystem)
    try cleanupTransaction(fileSystem: fileSystem)
    return .rolledBack
  }

  static func recoverForReadIfNeeded(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws {
    try recoveryCoordinator(fileSystem: fileSystem).recoverForRead(
      acquiringLock: { try IpodDeviceLock.shuffle(fileSystem: fileSystem) },
      recovery: {
        _ = try recoverIfNeededUnlocked(fileSystem: fileSystem, after: checkpoint)
      })
  }

  static func hasPendingTransaction(fileSystem: IpodFileSystem) -> Bool {
    recoveryCoordinator(fileSystem: fileSystem).hasPendingTransaction
  }

  private static func recoveryCoordinator(fileSystem: IpodFileSystem)
    -> RecoveryMarkerCoordinator
  {
    RecoveryMarkerCoordinator(
      marker: artifacts(fileSystem).marker,
      quarantinedMarkerPrefix: quarantinedMarkerPrefix, recoveryName: "shuffle")
  }

  static func installStagedFile(_ staged: URL, _ live: URL) throws {
    guard
      staged.deletingLastPathComponent().standardizedFileURL
        == live.deletingLastPathComponent().standardizedFileURL
    else {
      throw ITunesDBError.badHeader("shuffle database staging left iPod_Control/iTunes")
    }
    guard Darwin.rename(staged.path, live.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private static func prepareBackup(live: URL, backup: URL, existed: Bool) throws -> Data? {
    guard existed else { return nil }
    let data = try Data(contentsOf: live, options: .mappedIfSafe)
    try DurableIO.write(data, to: backup)
    return hash(data)
  }

  private static func validateBackup(_ backup: URL, existed: Bool, expectedHash: Data?) throws {
    if !existed {
      guard expectedHash == nil else {
        throw RecoveryMarkerMetadataError(
          .badHeader("shuffle recovery marker has an unexpected backup hash"))
      }
      return
    }
    guard let expectedHash, try liveMatches(backup, hash: expectedHash) else {
      throw RecoveryMarkerMetadataError(
        .badHeader("shuffle database recovery backup failed its hash"))
    }
  }

  private static func restore(
    backup: URL, live: URL, temporary: URL, existed: Bool
  ) throws {
    let fm = FileManager.default
    fm.bestEffortRemoveItem(at: temporary)
    guard existed else {
      if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
      try DurableIO.synchronize(at: live.deletingLastPathComponent())
      return
    }
    try fm.copyItem(at: backup, to: temporary)
    try DurableIO.synchronize(at: temporary)
    guard Darwin.rename(temporary.path, live.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try DurableIO.synchronize(at: live.deletingLastPathComponent())
  }

  private static func validateMarker(_ transaction: Transaction) throws {
    guard transaction.version == transactionVersion,
      transaction.newDatabaseHash.count == SHA256.Digest.byteCount,
      transaction.newShuffleDatabaseHash.count == SHA256.Digest.byteCount,
      transaction.hadDatabase == (transaction.oldDatabaseHash != nil),
      transaction.hadShuffleDatabase == (transaction.oldShuffleDatabaseHash != nil),
      transaction.oldDatabaseHash?.count == nil
        || transaction.oldDatabaseHash?.count == SHA256.Digest.byteCount,
      transaction.oldShuffleDatabaseHash?.count == nil
        || transaction.oldShuffleDatabaseHash?.count == SHA256.Digest.byteCount
    else {
      throw RecoveryMarkerMetadataError(
        .badHeader("invalid shuffle database recovery marker"))
    }
  }

  private static func validateLiveNewGeneration(
    _ transaction: Transaction, fileSystem: IpodFileSystem
  ) throws {
    let databaseMatches = try liveMatches(
      fileSystem.databaseURL, hash: transaction.newDatabaseHash)
    let shuffleDatabaseMatches = try liveMatches(
      fileSystem.shuffleDatabaseURL, hash: transaction.newShuffleDatabaseHash)
    guard databaseMatches, shuffleDatabaseMatches else {
      throw ITunesDBError.badHeader("installed shuffle database generation failed its hash")
    }
  }

  private static func validateLiveOldGeneration(
    _ transaction: Transaction, fileSystem: IpodFileSystem
  ) throws {
    let databaseMatches = try liveMatchesOld(
      fileSystem.databaseURL, existed: transaction.hadDatabase,
      hash: transaction.oldDatabaseHash)
    let shuffleDatabaseMatches = try liveMatchesOld(
      fileSystem.shuffleDatabaseURL, existed: transaction.hadShuffleDatabase,
      hash: transaction.oldShuffleDatabaseHash)
    guard databaseMatches, shuffleDatabaseMatches else {
      throw ITunesDBError.badHeader("restored shuffle database generation failed its hash")
    }
  }

  private static func liveMatchesOld(_ url: URL, existed: Bool, hash: Data?) throws -> Bool {
    if !existed { return !FileManager.default.fileExists(atPath: url.path) }
    guard let hash else { return false }
    return try liveMatches(url, hash: hash)
  }

  private static func classifyLiveGeneration(
    _ url: URL, existedBefore: Bool, oldHash: Data?, newHash: Data
  ) throws -> LiveGeneration {
    guard FileManager.default.fileExists(atPath: url.path) else {
      guard !existedBefore else {
        throw RecoveryMarkerMetadataError(
          .badHeader("shuffle database live file is not a known transaction generation"))
      }
      return .old
    }

    let liveHash = hash(try Data(contentsOf: url, options: .mappedIfSafe))
    if liveHash == newHash { return .new }
    if existedBefore, let oldHash, liveHash == oldHash { return .old }
    throw RecoveryMarkerMetadataError(
      .badHeader("shuffle database live file is not a known transaction generation"))
  }

  private static func liveMatches(_ url: URL, hash expected: Data) throws -> Bool {
    guard FileManager.default.fileExists(atPath: url.path) else { return false }
    return hash(try Data(contentsOf: url, options: .mappedIfSafe)) == expected
  }

  private static func hash(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private static func writeMarker(_ transaction: Transaction, fileSystem: IpodFileSystem) throws {
    let data = try PropertyListEncoder().encode(transaction)
    guard data.count <= maximumMarkerBytes else {
      throw ITunesDBError.badHeader("shuffle database recovery marker exceeds safety limit")
    }
    try DurableIO.write(data, to: artifacts(fileSystem).marker)
  }

  private static func readMarker(at url: URL) throws -> Transaction {
    let data = try RecoveryMarkerReadSupport.readFixedMarker(
      url, maximumBytes: maximumMarkerBytes,
      invalidFailure: "invalid shuffle database recovery marker",
      oversizedFailure: "shuffle database recovery marker exceeds safety limit")
    do {
      return try PropertyListDecoder().decode(Transaction.self, from: data)
    } catch {
      throw RecoveryMarkerMetadataError(
        .badHeader("unreadable shuffle database recovery marker"))
    }
  }

  private static func cleanupTransientFiles(fileSystem: IpodFileSystem) throws {
    let fm = FileManager.default
    let value = artifacts(fileSystem)
    for url in [
      value.stagedDatabase, value.stagedShuffleDatabase,
      value.restoreDatabase, value.restoreShuffleDatabase,
    ] where fm.fileExists(atPath: url.path) {
      try fm.removeItem(at: url)
    }
  }

  private static func cleanupTransaction(fileSystem: IpodFileSystem) throws {
    let marker = artifacts(fileSystem).marker
    try cleanupTransientFiles(fileSystem: fileSystem)
    if FileManager.default.fileExists(atPath: marker.path) {
      try FileManager.default.removeItem(at: marker)
    }
    try DurableIO.synchronize(at: fileSystem.itunesDir)
  }

  private static func artifacts(_ fileSystem: IpodFileSystem) -> (
    marker: URL, stagedDatabase: URL, stagedShuffleDatabase: URL,
    restoreDatabase: URL, restoreShuffleDatabase: URL
  ) {
    (
      fileSystem.itunesDir.appendingPathComponent(markerName),
      fileSystem.itunesDir.appendingPathComponent(stagedDatabaseName),
      fileSystem.itunesDir.appendingPathComponent(stagedShuffleDatabaseName),
      fileSystem.itunesDir.appendingPathComponent(restoreDatabaseName),
      fileSystem.itunesDir.appendingPathComponent(restoreShuffleDatabaseName)
    )
  }

}
