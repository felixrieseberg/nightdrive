import CryptoKit
import Darwin
import Foundation
import SQLite3

enum Nano5DatabaseWriter {
  private static let databaseNames = [
    "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
  ]
  private static let generationFileNames = databaseNames + ["Locations.itdb.cbk"]
  private static let maximumMarkerBytes = 1 * 1_024 * 1_024
  private static let transactionMarkerName = ".nightdrive-nano-install.plist"
  private static let quarantinedMarkerPrefix = ".nightdrive-quarantined-nano-install-"

  static func write(
    _ database: ITunesDatabase, rawDatabase: Data, fileSystem: IpodFileSystem,
    firewireGUID: Data
  ) throws {
    let deviceLock = try IpodDeviceLock.nano(fileSystem: fileSystem)
    try withExtendedLifetime(deviceLock) {
      let recovery = recoveryCoordinator(fileSystem: fileSystem)
      try recovery.rejectQuarantinedMarkers()
      try recovery.runStrictly {
        try recoverIfNeededUnlocked(fileSystem: fileSystem)
      }
      let fm = FileManager.default
      let sourceDirectory = fileSystem.sqliteLibraryDirectory
      for name in databaseNames {
        guard fm.fileExists(atPath: sourceDirectory.appendingPathComponent(name).path) else {
          throw ITunesDBError.unsupportedDevice(
            "This nano 5G is missing \(name). Initialize it once with Apple's iPod software.")
        }
      }
      let existingCDB = try Data(contentsOf: fileSystem.compressedDatabaseURL)
      let material = try Hash72Material.load(from: fileSystem, database: existingCDB)

      let stagingDirectory = fileSystem.itunesDir.appendingPathComponent(
        ".nightdrive-itlp-\(UUID().uuidString)", isDirectory: true)
      let stagedCDB = fileSystem.itunesDir.appendingPathComponent(
        ".nightdrive-cdb-\(UUID().uuidString)")
      defer {
        fm.bestEffortRemoveItem(at: stagingDirectory)
        fm.bestEffortRemoveItem(at: stagedCDB)
      }
      try fm.copyItem(at: sourceDirectory, to: stagingDirectory)
      try updateSQLite(database, in: stagingDirectory)
      try writeLocationsCBK(in: stagingDirectory, material: material)

      var cdbInput = rawDatabase
      cdbInput.patchU32(2, at: 12)
      var cdb = try ITunesCDB.compress(cdbInput)
      cdb = try Hash58.sign(cdb, firewireGUID: firewireGUID)
      try cdb.write(to: stagedCDB, options: .atomic)

      try writeHashInfo(material, firewireGUID: firewireGUID, fileSystem: fileSystem)
      do {
        try installUnlocked(
          stagedDirectory: stagingDirectory, stagedCDB: stagedCDB, fileSystem: fileSystem)
      } catch {
        do {
          try recovery.runStrictly {
            try recoverIfNeededUnlocked(fileSystem: fileSystem)
          }
        } catch let recoveryError {
          NightdriveLog.ipodFS.error(
            "Nano database recovery failed after a failed install: \(recoveryError.localizedDescription, privacy: .public)"
          )
        }
        throw error
      }
    }
  }

  enum InstallCheckpoint: String, CaseIterable {
    case beforeMarkerWritten
    case markerWritten
    case directoryStaged
    case cdbStaged
    case directoryBackupCopied
    case backupsReady
    case directoryReplacementStarted
    case directoryInstalled
    case cdbReplacementStarted
    case cdbInstalled
    case committed
    case backupPointerPromoted
  }

  private enum InstallPhase: String, Codable {
    case preparing
    case backupsReady
    case installingDirectory
    case installingCDB
    case committed
    case rollbackComplete
  }

  private struct InstallTransaction: Codable {
    var identifier: String
    var phase: InstallPhase
    var originalStagedDirectoryName: String
    var originalStagedCDBName: String
    var sqliteHashes: [String: Data]
    var cdbHash: Data
    var previousBackupIdentifier: String?
    var backupFileHashes: [String: Data]?
    var backupCDBHash: Data?
    var rollbackRetainedBackupIdentifier: String?
  }

  enum RecoveryCheckpoint: String, CaseIterable {
    case directoryRestored
    case rollbackMarked
    case directoryBackupDeleted
    case cdbBackupDeleted
  }

  private struct BackupGeneration: Codable {
    var identifier: String
  }

  static func install(
    stagedDirectory: URL, stagedCDB: URL, fileSystem: IpodFileSystem,
    after checkpoint: (InstallCheckpoint) throws -> Void = { _ in }
  ) throws {
    let deviceLock = try IpodDeviceLock.nano(fileSystem: fileSystem)
    try withExtendedLifetime(deviceLock) {
      try recoveryCoordinator(fileSystem: fileSystem).rejectQuarantinedMarkers()
      try installUnlocked(
        stagedDirectory: stagedDirectory, stagedCDB: stagedCDB, fileSystem: fileSystem,
        after: checkpoint)
    }
  }

  private static func installUnlocked(
    stagedDirectory: URL, stagedCDB: URL, fileSystem: IpodFileSystem,
    after checkpoint: (InstallCheckpoint) throws -> Void = { _ in }
  ) throws {
    let fm = FileManager.default
    guard
      stagedDirectory.deletingLastPathComponent().standardizedFileURL
        == fileSystem.itunesDir.standardizedFileURL,
      stagedCDB.deletingLastPathComponent().standardizedFileURL
        == fileSystem.itunesDir.standardizedFileURL
    else {
      throw ITunesDBError.badHeader("nano database staging must stay inside iPod_Control/iTunes")
    }
    let identifier = UUID().uuidString
    let artifacts = installArtifacts(identifier: identifier, fileSystem: fileSystem)
    try synchronizeTree(at: stagedDirectory)
    try DurableIO.synchronizeWithBarrier(at: stagedCDB)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    let sqliteHashes = try generationHashes(in: stagedDirectory, requireCBK: true)
    var transaction = InstallTransaction(
      identifier: identifier, phase: .preparing,
      originalStagedDirectoryName: stagedDirectory.lastPathComponent,
      originalStagedCDBName: stagedCDB.lastPathComponent,
      sqliteHashes: sqliteHashes, cdbHash: try DurableIO.sha256(of: stagedCDB),
      previousBackupIdentifier: currentBackupIdentifier(fileSystem: fileSystem),
      backupFileHashes: nil, backupCDBHash: nil, rollbackRetainedBackupIdentifier: nil)
    try checkpoint(.beforeMarkerWritten)
    try writeTransaction(transaction, fileSystem: fileSystem)
    try checkpoint(.markerWritten)
    try fm.moveItem(at: stagedDirectory, to: artifacts.stagedDirectory)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.directoryStaged)
    try fm.moveItem(at: stagedCDB, to: artifacts.stagedCDB)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.cdbStaged)

    try fm.copyItem(at: fileSystem.sqliteLibraryDirectory, to: artifacts.directoryBackup)
    try checkpoint(.directoryBackupCopied)
    try fm.copyItem(at: fileSystem.compressedDatabaseURL, to: artifacts.cdbBackup)
    try synchronizeTree(at: artifacts.directoryBackup)
    try DurableIO.synchronizeWithBarrier(at: artifacts.cdbBackup)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    transaction.backupFileHashes = try generationHashes(
      in: artifacts.directoryBackup, requireCBK: false)
    transaction.backupCDBHash = try DurableIO.sha256(of: artifacts.cdbBackup)
    transaction.phase = .backupsReady
    try writeTransaction(transaction, fileSystem: fileSystem)
    try checkpoint(.backupsReady)

    transaction.phase = .installingDirectory
    try writeTransaction(transaction, fileSystem: fileSystem)
    try checkpoint(.directoryReplacementStarted)
    _ = try fm.replaceItemAt(
      fileSystem.sqliteLibraryDirectory, withItemAt: artifacts.stagedDirectory)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.directoryInstalled)

    transaction.phase = .installingCDB
    try writeTransaction(transaction, fileSystem: fileSystem)
    try checkpoint(.cdbReplacementStarted)
    _ = try fm.replaceItemAt(
      fileSystem.compressedDatabaseURL, withItemAt: artifacts.stagedCDB)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
    try checkpoint(.cdbInstalled)

    transaction.phase = .committed
    try writeTransaction(transaction, fileSystem: fileSystem)
    try checkpoint(.committed)
    try cleanup(transaction: transaction, fileSystem: fileSystem, after: checkpoint)
  }

  static func recoverIfNeeded(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws {
    try recoveryCoordinator(fileSystem: fileSystem).recoverStrictly(
      acquiringLock: { try IpodDeviceLock.nano(fileSystem: fileSystem) },
      recovery: { try recoverIfNeededUnlocked(fileSystem: fileSystem, after: checkpoint) })
  }

  static func recoverForReadIfNeeded(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws {
    try recoveryCoordinator(fileSystem: fileSystem).recoverForRead(
      acquiringLock: { try IpodDeviceLock.nano(fileSystem: fileSystem) },
      recovery: { try recoverIfNeededUnlocked(fileSystem: fileSystem, after: checkpoint) })
  }

  static func hasPendingTransaction(fileSystem: IpodFileSystem) -> Bool {
    recoveryCoordinator(fileSystem: fileSystem).hasPendingTransaction
  }

  private static func recoveryCoordinator(fileSystem: IpodFileSystem)
    -> RecoveryMarkerCoordinator
  {
    RecoveryMarkerCoordinator(
      marker: transactionURL(fileSystem: fileSystem),
      quarantinedMarkerPrefix: quarantinedMarkerPrefix, recoveryName: "nano")
  }

  private static func recoverIfNeededUnlocked(
    fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void = { _ in }
  ) throws {
    let marker = transactionURL(fileSystem: fileSystem)
    guard FileManager.default.fileExists(atPath: marker.path) else {
      try cleanupOrphanStaging(fileSystem: fileSystem)
      try cleanupObsoleteBackups(fileSystem: fileSystem)
      return
    }
    let transaction = try readTransactionMetadata(at: marker)
    let artifacts = installArtifacts(
      identifier: transaction.identifier, fileSystem: fileSystem)
    switch transaction.phase {
    case .preparing:
      try markRollbackComplete(
        transaction: transaction, retainedBackupIdentifier: transaction.previousBackupIdentifier,
        fileSystem: fileSystem, after: checkpoint)
      return
    case .backupsReady:
      try validateRecoveryMetadata {
        try validateBackupGeneration(transaction: transaction, artifacts: artifacts)
      }
      try markRollbackComplete(
        transaction: transaction, retainedBackupIdentifier: transaction.previousBackupIdentifier,
        fileSystem: fileSystem, after: checkpoint)
      return
    case .installingDirectory, .installingCDB:
      try validateRecoveryMetadata {
        try validateBackupGeneration(transaction: transaction, artifacts: artifacts)
      }
      try restore(
        backup: artifacts.directoryBackup, live: fileSystem.sqliteLibraryDirectory,
        temporary: artifacts.directoryRestore)
      try checkpoint(.directoryRestored)
      try restore(
        backup: artifacts.cdbBackup, live: fileSystem.compressedDatabaseURL,
        temporary: artifacts.cdbRestore)
      try validateRestoredGeneration(transaction: transaction, fileSystem: fileSystem)
      try markRollbackComplete(
        transaction: transaction, retainedBackupIdentifier: transaction.previousBackupIdentifier,
        fileSystem: fileSystem, after: checkpoint)
      return
    case .committed:
      do {
        try validateCommitted(transaction: transaction, fileSystem: fileSystem)
      } catch is ITunesDBError {
        try validateRecoveryMetadata {
          try validateBackupGeneration(transaction: transaction, artifacts: artifacts)
        }
        try restore(
          backup: artifacts.directoryBackup, live: fileSystem.sqliteLibraryDirectory,
          temporary: artifacts.directoryRestore)
        try checkpoint(.directoryRestored)
        try restore(
          backup: artifacts.cdbBackup, live: fileSystem.compressedDatabaseURL,
          temporary: artifacts.cdbRestore)
        try validateRestoredGeneration(transaction: transaction, fileSystem: fileSystem)
        try finishCommittedRollback(
          transaction: transaction, fileSystem: fileSystem, after: checkpoint)
        return
      }
    case .rollbackComplete:
      try finishRollbackCleanup(
        transaction: transaction, fileSystem: fileSystem, after: checkpoint)
      return
    }
    try cleanup(transaction: transaction, fileSystem: fileSystem)
  }

  private static func validateCommitted(
    transaction: InstallTransaction, fileSystem: IpodFileSystem
  ) throws {
    guard transaction.sqliteHashes.count == generationFileNames.count else {
      throw ITunesDBError.badHeader("nano transaction is missing SQLite generation hashes")
    }
    for name in generationFileNames {
      let url = fileSystem.sqliteLibraryDirectory.appendingPathComponent(name)
      guard let expected = transaction.sqliteHashes[name],
        try DurableIO.sha256(of: url) == expected
      else {
        throw ITunesDBError.badHeader("committed nano SQLite generation does not match")
      }
    }
    let cdb = try Data(contentsOf: fileSystem.compressedDatabaseURL)
    guard Data(SHA256.hash(data: cdb)) == transaction.cdbHash else {
      throw ITunesDBError.badHeader("committed nano CDB generation does not match")
    }
    _ = try ITunesDBReader().read(try ITunesCDB.decompress(cdb))
  }

  private static func validateRecoveryMetadata(_ validation: () throws -> Void) throws {
    do {
      try validation()
    } catch let error as ITunesDBError {
      throw RecoveryMarkerMetadataError(error)
    }
  }

  private static func validateBackupGeneration(
    transaction: InstallTransaction,
    artifacts: (
      directoryBackup: URL, cdbBackup: URL, directoryRestore: URL, cdbRestore: URL,
      stagedDirectory: URL, stagedCDB: URL
    )
  ) throws {
    guard let hashes = transaction.backupFileHashes,
      let cdbHash = transaction.backupCDBHash
    else {
      throw ITunesDBError.badHeader("nano recovery marker is missing old-generation hashes")
    }
    try validateGenerationHashes(
      hashes, in: artifacts.directoryBackup,
      failure: "nano recovery backup failed its generation hash")
    let cdb = try Data(contentsOf: artifacts.cdbBackup)
    guard Data(SHA256.hash(data: cdb)) == cdbHash else {
      throw ITunesDBError.badHeader("nano recovery CDB backup failed its generation hash")
    }
    _ = try ITunesDBReader().read(try ITunesCDB.decompress(cdb))
  }

  private static func validateRestoredGeneration(
    transaction: InstallTransaction, fileSystem: IpodFileSystem
  ) throws {
    guard let hashes = transaction.backupFileHashes,
      let cdbHash = transaction.backupCDBHash
    else {
      throw ITunesDBError.badHeader("nano recovery marker is missing old-generation hashes")
    }
    try validateGenerationHashes(
      hashes, in: fileSystem.sqliteLibraryDirectory,
      failure: "restored nano generation failed its persisted hash")
    let cdb = try Data(contentsOf: fileSystem.compressedDatabaseURL)
    guard Data(SHA256.hash(data: cdb)) == cdbHash else {
      throw ITunesDBError.badHeader("restored nano CDB failed its persisted hash")
    }
    _ = try ITunesDBReader().read(try ITunesCDB.decompress(cdb))
  }

  private static func generationHashes(in directory: URL, requireCBK: Bool) throws
    -> [String: Data]
  {
    var hashes: [String: Data] = [:]
    for name in generationFileNames {
      let url = directory.appendingPathComponent(name)
      if name == "Locations.itdb.cbk", !FileManager.default.fileExists(atPath: url.path) {
        if requireCBK {
          throw ITunesDBError.badHeader("nano generation is missing Locations.itdb.cbk")
        }
        continue
      }
      hashes[name] = try DurableIO.sha256(of: url)
    }
    return hashes
  }

  private static func validateGenerationHashes(
    _ hashes: [String: Data], in directory: URL, failure: String
  ) throws {
    guard databaseNames.allSatisfy({ hashes[$0] != nil }),
      hashes.keys.allSatisfy({ generationFileNames.contains($0) })
    else {
      throw ITunesDBError.badHeader("nano recovery marker is missing old-generation hashes")
    }
    for (name, expected) in hashes {
      guard try DurableIO.sha256(of: directory.appendingPathComponent(name)) == expected else {
        throw ITunesDBError.badHeader(failure)
      }
    }
  }

  private static func restore(backup: URL, live: URL, temporary: URL) throws {
    let fm = FileManager.default
    fm.bestEffortRemoveItem(at: temporary)
    try fm.copyItem(at: backup, to: temporary)
    try synchronizeTree(at: temporary)
    if fm.fileExists(atPath: live.path) {
      _ = try fm.replaceItemAt(live, withItemAt: temporary)
    } else {
      try fm.moveItem(at: temporary, to: live)
    }
    try DurableIO.synchronize(at: live.deletingLastPathComponent())
  }

  private static func writeTransaction(
    _ transaction: InstallTransaction, fileSystem: IpodFileSystem
  ) throws {
    let data = try PropertyListEncoder().encode(transaction)
    try DurableIO.write(data, to: transactionURL(fileSystem: fileSystem), barrier: true)
  }

  private static func readTransactionMetadata(at marker: URL) throws -> InstallTransaction {
    let data = try RecoveryMarkerReadSupport.readFixedMarker(
      marker, maximumBytes: maximumMarkerBytes,
      invalidFailure: "Nightdrive found an unsafe nano database recovery marker.",
      oversizedFailure: "Nightdrive found an oversized nano database recovery marker.")
    let transaction: InstallTransaction
    do {
      transaction = try PropertyListDecoder().decode(InstallTransaction.self, from: data)
    } catch {
      throw RecoveryMarkerMetadataError(
        .badHeader("Nightdrive found an unreadable nano database recovery marker."))
    }
    guard UUID(uuidString: transaction.identifier) != nil else {
      throw RecoveryMarkerMetadataError(
        .badHeader("Nightdrive found an invalid nano database recovery marker."))
    }
    guard
      isSafeStagingName(
        transaction.originalStagedDirectoryName, prefix: ".nightdrive-itlp-"),
      isSafeStagingName(transaction.originalStagedCDBName, prefix: ".nightdrive-cdb-")
    else {
      throw RecoveryMarkerMetadataError(
        .badHeader("Nightdrive found unsafe paths in a nano database recovery marker."))
    }
    return transaction
  }

  private static func cleanup(
    transaction: InstallTransaction, fileSystem: IpodFileSystem,
    after checkpoint: (InstallCheckpoint) throws -> Void = { _ in }
  ) throws {
    let fm = FileManager.default
    let artifacts = installArtifacts(
      identifier: transaction.identifier, fileSystem: fileSystem)
    if transaction.phase == .committed {
      try promoteBackup(
        identifier: transaction.identifier, fileSystem: fileSystem, after: checkpoint)
    } else {
      fm.bestEffortRemoveItem(at: artifacts.directoryBackup)
      fm.bestEffortRemoveItem(at: artifacts.cdbBackup)
    }
    for url in [
      artifacts.directoryRestore, artifacts.cdbRestore, artifacts.stagedDirectory,
      artifacts.stagedCDB,
      fileSystem.itunesDir.appendingPathComponent(transaction.originalStagedDirectoryName),
      fileSystem.itunesDir.appendingPathComponent(transaction.originalStagedCDBName),
    ] {
      fm.bestEffortRemoveItem(at: url)
    }
    try fm.removeItem(at: transactionURL(fileSystem: fileSystem))
    try DurableIO.synchronize(at: fileSystem.itunesDir)
  }

  private static func promoteBackup(
    identifier: String, fileSystem: IpodFileSystem,
    after checkpoint: (InstallCheckpoint) throws -> Void
  ) throws {
    let url = backupGenerationURL(fileSystem: fileSystem)
    let data = try PropertyListEncoder().encode(BackupGeneration(identifier: identifier))
    try DurableIO.write(data, to: url, barrier: true)
    try checkpoint(.backupPointerPromoted)
    try cleanupObsoleteBackups(fileSystem: fileSystem)
    try DurableIO.synchronize(at: fileSystem.itunesDir)
  }

  private static func finishCommittedRollback(
    transaction: InstallTransaction, fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void
  ) throws {
    let fm = FileManager.default
    let previousIdentifier: String? = transaction.previousBackupIdentifier.flatMap { identifier in
      guard UUID(uuidString: identifier) != nil else { return nil }
      let previous = installArtifacts(identifier: identifier, fileSystem: fileSystem)
      guard
        fm.fileExists(atPath: previous.directoryBackup.path),
        fm.fileExists(atPath: previous.cdbBackup.path)
      else { return nil }
      return identifier
    }
    let retainedIdentifier = previousIdentifier ?? transaction.identifier
    let pointer = try PropertyListEncoder().encode(
      BackupGeneration(identifier: retainedIdentifier))
    try DurableIO.write(pointer, to: backupGenerationURL(fileSystem: fileSystem), barrier: true)
    try markRollbackComplete(
      transaction: transaction, retainedBackupIdentifier: retainedIdentifier,
      fileSystem: fileSystem, after: checkpoint)
  }

  private static func markRollbackComplete(
    transaction: InstallTransaction, retainedBackupIdentifier: String?,
    fileSystem: IpodFileSystem, after checkpoint: (RecoveryCheckpoint) throws -> Void
  ) throws {
    var rollback = transaction
    rollback.phase = .rollbackComplete
    rollback.rollbackRetainedBackupIdentifier = retainedBackupIdentifier
    try writeTransaction(rollback, fileSystem: fileSystem)
    try checkpoint(.rollbackMarked)
    try finishRollbackCleanup(
      transaction: rollback, fileSystem: fileSystem, after: checkpoint)
  }

  private static func finishRollbackCleanup(
    transaction: InstallTransaction, fileSystem: IpodFileSystem,
    after checkpoint: (RecoveryCheckpoint) throws -> Void
  ) throws {
    let fm = FileManager.default
    let current = installArtifacts(identifier: transaction.identifier, fileSystem: fileSystem)
    if let retained = transaction.rollbackRetainedBackupIdentifier {
      let pointer = try PropertyListEncoder().encode(BackupGeneration(identifier: retained))
      try DurableIO.write(pointer, to: backupGenerationURL(fileSystem: fileSystem), barrier: true)
    }
    if transaction.rollbackRetainedBackupIdentifier != transaction.identifier {
      fm.bestEffortRemoveItem(at: current.directoryBackup)
      try DurableIO.synchronize(at: fileSystem.itunesDir)
      try checkpoint(.directoryBackupDeleted)
      fm.bestEffortRemoveItem(at: current.cdbBackup)
      try DurableIO.synchronize(at: fileSystem.itunesDir)
      try checkpoint(.cdbBackupDeleted)
    }
    try cleanupObsoleteBackups(fileSystem: fileSystem)
    for url in [
      current.directoryRestore, current.cdbRestore, current.stagedDirectory, current.stagedCDB,
      fileSystem.itunesDir.appendingPathComponent(transaction.originalStagedDirectoryName),
      fileSystem.itunesDir.appendingPathComponent(transaction.originalStagedCDBName),
    ] {
      fm.bestEffortRemoveItem(at: url)
    }
    try fm.removeItem(at: transactionURL(fileSystem: fileSystem))
    try DurableIO.synchronize(at: fileSystem.itunesDir)
  }

  private static func currentBackupIdentifier(fileSystem: IpodFileSystem) -> String? {
    let url = backupGenerationURL(fileSystem: fileSystem)
    guard
      let generation = try? PropertyListDecoder().decode(
        BackupGeneration.self, from: Data(contentsOf: url)),
      UUID(uuidString: generation.identifier) != nil
    else { return nil }
    return generation.identifier
  }

  private static func cleanupObsoleteBackups(fileSystem: IpodFileSystem) throws {
    let pointerURL = backupGenerationURL(fileSystem: fileSystem)
    guard
      let generation = try? PropertyListDecoder().decode(
        BackupGeneration.self, from: Data(contentsOf: pointerURL)),
      UUID(uuidString: generation.identifier) != nil
    else { return }
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(
      at: fileSystem.itunesDir, includingPropertiesForKeys: nil)
    let prefix = ".nightdrive-nano-"
    for url in entries {
      let name = url.lastPathComponent
      guard name.hasPrefix(prefix) else { continue }
      let suffix: String
      if name.hasSuffix("-backup.itlp") {
        suffix = "-backup.itlp"
      } else if name.hasSuffix("-backup.cdb") {
        suffix = "-backup.cdb"
      } else {
        continue
      }
      let start = name.index(name.startIndex, offsetBy: prefix.count)
      let end = name.index(name.endIndex, offsetBy: -suffix.count)
      guard start <= end else { continue }
      let identifier = String(name[start..<end])
      guard UUID(uuidString: identifier) != nil, identifier != generation.identifier else {
        continue
      }
      fm.bestEffortRemoveItem(at: url)
    }
  }

  private static func cleanupOrphanStaging(fileSystem: IpodFileSystem) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: fileSystem.itunesDir.path) else { return }
    let entries = try fm.contentsOfDirectory(
      at: fileSystem.itunesDir, includingPropertiesForKeys: nil)
    var removed = false
    for url in entries {
      let name = url.lastPathComponent
      if name.hasPrefix(".nightdrive-itlp-") || name.hasPrefix(".nightdrive-cdb-") {
        fm.bestEffortRemoveItem(at: url)
        removed = true
      }
    }
    if removed { try DurableIO.synchronize(at: fileSystem.itunesDir) }
  }

  private static func isSafeStagingName(_ name: String, prefix: String) -> Bool {
    guard name.hasPrefix(prefix) else { return false }
    let identifier = String(name.dropFirst(prefix.count))
    return UUID(uuidString: identifier) != nil && name == prefix + identifier
  }

  private static func synchronizeTree(at root: URL) throws {
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return }
    guard isDirectory.boolValue else {
      try DurableIO.synchronizeWithBarrier(at: root)
      return
    }
    var directories = [root]
    if let enumerator = fm.enumerator(
      at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
    {
      for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
          directories.append(url)
        } else if values.isRegularFile == true {
          try DurableIO.synchronizeWithBarrier(at: url)
        }
      }
    }
    for directory in directories.reversed() {
      try DurableIO.synchronize(at: directory)
    }
  }

  private static func transactionURL(fileSystem: IpodFileSystem) -> URL {
    fileSystem.itunesDir.appendingPathComponent(transactionMarkerName)
  }

  private static func backupGenerationURL(fileSystem: IpodFileSystem) -> URL {
    fileSystem.itunesDir.appendingPathComponent(".nightdrive-nano-backup.plist")
  }

  private static func installArtifacts(
    identifier: String, fileSystem: IpodFileSystem
  ) -> (
    directoryBackup: URL, cdbBackup: URL, directoryRestore: URL, cdbRestore: URL,
    stagedDirectory: URL, stagedCDB: URL
  ) {
    let base = ".nightdrive-nano-\(identifier)"
    return (
      fileSystem.itunesDir.appendingPathComponent("\(base)-backup.itlp", isDirectory: true),
      fileSystem.itunesDir.appendingPathComponent("\(base)-backup.cdb"),
      fileSystem.itunesDir.appendingPathComponent("\(base)-restore.itlp", isDirectory: true),
      fileSystem.itunesDir.appendingPathComponent("\(base)-restore.cdb"),
      fileSystem.itunesDir.appendingPathComponent("\(base)-staging.itlp", isDirectory: true),
      fileSystem.itunesDir.appendingPathComponent("\(base)-staged.cdb")
    )
  }

  private enum SQLiteWritePolicy {
    case reconcile
    case replaceAll
  }

  private static func updateSQLite(_ database: ITunesDatabase, in directory: URL) throws {
    try projectSQLite(
      database, in: directory,
      policy: database.sourceTrackDbids != nil ? .reconcile : .replaceAll)
  }

  private static func projectSQLite(
    _ database: ITunesDatabase, in directory: URL, policy: SQLiteWritePolicy
  ) throws {
    let reconciling = policy == .reconcile
    let library = try SQLiteStore(url: directory.appendingPathComponent("Library.itdb"))
    let dynamic = try SQLiteStore(url: directory.appendingPathComponent("Dynamic.itdb"))
    let locations = try SQLiteStore(url: directory.appendingPathComponent("Locations.itdb"))
    let currentTrackIDs = Set(database.tracks.map { sql($0.dbid) })
    // Only genuinely podcast-flagged playlists are projected; the type-3
    // section also carries plain mirrors of the standard playlists.
    let podcastPlaylists = database.podcastPlaylists.filter(\.isPodcast)
    let synthesizedPodcastPID = sql(ITunesDBWriter.synthesizedPodcastPlaylistID(for: database))
    let stalePodcastPlaylistIDs: Set<Int64> =
      podcastPlaylists.contains { sql($0.persistentID) == synthesizedPodcastPID }
      ? [] : [synthesizedPodcastPID]
    let removedTrackIDs: Set<Int64>
    let removedPlaylistIDs: Set<Int64>
    if policy == .reconcile {
      let currentPlaylistIDs = Set(
        ([database.masterPlaylistID] + database.playlists.map(\.persistentID)).map(sql))
      removedTrackIDs = Set((database.sourceTrackDbids ?? []).map(sql))
        .subtracting(currentTrackIDs)
      removedPlaylistIDs = Set((database.sourcePlaylistIDs ?? []).map(sql))
        .subtracting(currentPlaylistIDs)
        .union(stalePodcastPlaylistIDs)
    } else {
      removedTrackIDs = []
      removedPlaylistIDs = []
    }

    var master =
      database.masterPlaylistTemplate
      ?? ITDBPlaylist(name: database.masterPlaylistName, isMaster: true)
    master.name = database.masterPlaylistName
    master.isMaster = true
    master.persistentID = database.masterPlaylistID
    master.memberDbids = database.tracks.map(\.dbid)
    let playlists = [master] + database.playlists.filter { !$0.isMaster }
    let projectedPlaylists = playlists + podcastPlaylists

    func write(
      _ store: SQLiteStore, into table: String, keyValues: [String: SQLiteValue],
      values: [String: SQLiteValue], preservingOnUpdate: Set<String> = []
    ) throws {
      if reconciling {
        try store.upsert(
          into: table, keyValues: keyValues, values: values,
          preservingOnUpdate: preservingOnUpdate)
      } else {
        try store.insert(into: table, values: values)
      }
    }

    try library.transaction {
      switch policy {
      case .reconcile:
        for table in [
          "item_to_container", "item_to_album", "item_to_artist", "item_to_composer",
          "avformat_info", "video_info", "video_characteristics", "store_info", "podcast_info",
        ] {
          try library.delete(from: table, where: "item_pid", in: removedTrackIDs)
        }
        try library.delete(from: "item", where: "pid", in: removedTrackIDs)
        try library.delete(
          from: "item_to_container", where: "container_pid", in: removedPlaylistIDs)
        try library.delete(from: "container_seed", where: "container_pid", in: removedPlaylistIDs)
        try library.delete(from: "container", where: "pid", in: removedPlaylistIDs)
      case .replaceAll:
        for table in [
          "item_to_container", "container_seed", "item_to_album", "item_to_artist",
          "item_to_composer", "avformat_info", "video_info", "video_characteristics",
          "store_info", "podcast_info", "item", "container", "album", "artist",
          "composer", "genre_map", "category_map", "location_kind_map", "db_info",
        ] {
          try library.deleteAll(from: table)
        }
      }

      try library.updateAll(
        table: "db_info",
        values: [
          "pid": .integer(sql(database.libraryPersistentID)),
          "primary_container_pid": .integer(sql(database.masterPlaylistID)),
        ],
        insertValues: [
          "pid": .integer(sql(database.libraryPersistentID)),
          "primary_container_pid": .integer(sql(database.masterPlaylistID)),
          "audio_language": .integer(0), "subtitle_language": .integer(0),
        ])

      var genreIDs: [String: Int64] = [:]
      var artistIDs: [String: Int64] = [:]
      var composerIDs: [String: Int64] = [:]
      var albumIDs: [String: Int64] = [:]
      var issuedPIDs: [String: Set<Int64>] = [:]
      var maximumGenreID: Int64 = 0

      func unusedPID(table: String, namespace: String, value: String) throws -> Int64 {
        var candidate = stableID(namespace: namespace, value: value)
        while try issuedPIDs[table, default: []].contains(candidate)
          || (reconciling
            && library.integer(
              in: table, column: "pid", matching: ["pid": .integer(candidate)]) != nil)
        {
          candidate &+= 1
          if candidate == 0 { candidate = 1 }
        }
        issuedPIDs[table, default: []].insert(candidate)
        return candidate
      }

      func genreID(for value: String?) throws -> Int64 {
        guard let value = nonempty(value) else { return 0 }
        if let cached = genreIDs[value] { return cached }
        if reconciling,
          let existing = try library.integer(
            in: "genre_map", column: "id", matching: ["genre": .text(value)])
        {
          genreIDs[value] = existing
          maximumGenreID = max(maximumGenreID, existing)
          return existing
        }
        if reconciling {
          maximumGenreID = max(
            maximumGenreID, try library.maximumInteger(in: "genre_map", column: "id") ?? 0)
        }
        guard maximumGenreID < Int64.max else {
          throw ITunesDBError.badHeader("nano genre identifiers are exhausted")
        }
        let identifier = max(maximumGenreID + 1, 1)
        maximumGenreID = identifier
        try library.insert(
          into: "genre_map",
          values: [
            "id": .integer(identifier), "genre": .text(value), "genre_order": .integer(0),
          ])
        genreIDs[value] = identifier
        return identifier
      }

      func artistID(for value: String?) throws -> Int64 {
        guard let value = nonempty(value) else { return 0 }
        if let cached = artistIDs[value] { return cached }
        if reconciling,
          let existing = try library.integer(
            in: "artist", column: "pid", matching: ["name": .text(value)])
        {
          artistIDs[value] = existing
          return existing
        }
        let identifier = try unusedPID(table: "artist", namespace: "artist", value: value)
        try library.insert(
          into: "artist",
          values: [
            "pid": .integer(identifier), "kind": .integer(2), "artwork_status": .integer(0),
            "artwork_album_pid": .integer(0), "name": .text(value), "name_order": .integer(0),
            "sort_name": .text(value),
          ])
        artistIDs[value] = identifier
        return identifier
      }

      func composerID(for value: String?) throws -> Int64 {
        guard let value = nonempty(value) else { return 0 }
        if let cached = composerIDs[value] { return cached }
        if reconciling,
          let existing = try library.integer(
            in: "composer", column: "pid", matching: ["name": .text(value)])
        {
          composerIDs[value] = existing
          return existing
        }
        let identifier = try unusedPID(table: "composer", namespace: "composer", value: value)
        try library.insert(
          into: "composer",
          values: [
            "pid": .integer(identifier), "name": .text(value), "name_order": .integer(0),
            "sort_name": .text(value),
          ])
        composerIDs[value] = identifier
        return identifier
      }

      func albumID(
        for value: String?, artistID: Int64, artworkTrackID: Int64, compilation: Bool
      ) throws -> Int64 {
        guard let value = nonempty(value) else { return 0 }
        let key = value + "\u{0}" + String(artistID)
        if let cached = albumIDs[key] { return cached }
        if reconciling,
          let existing = try library.integer(
            in: "album", column: "pid",
            matching: ["name": .text(value), "artist_pid": .integer(artistID)])
        {
          albumIDs[key] = existing
          return existing
        }
        let identifier = try unusedPID(table: "album", namespace: "album", value: key)
        try library.insert(
          into: "album",
          values: [
            "pid": .integer(identifier), "kind": .integer(2), "artwork_status": .integer(0),
            "artwork_item_pid": .integer(artworkTrackID), "artist_pid": .integer(artistID),
            "user_rating": .integer(0), "name": .text(value), "name_order": .integer(0),
            "all_compilations": .integer(compilation ? 1 : 0), "season_number": .integer(0),
          ])
        albumIDs[key] = identifier
        return identifier
      }

      func reconcileMapping(
        table: String, relationColumn: String, itemID: Int64, previousRelationID: Int64?,
        relationID: Int64
      ) throws {
        if let previousRelationID {
          try library.delete(
            from: table,
            matching: [
              "item_pid": .integer(itemID), relationColumn: .integer(previousRelationID),
            ])
        }
        guard relationID != 0 else { return }
        let values = [
          "item_pid": SQLiteValue.integer(itemID), relationColumn: .integer(relationID),
        ]
        try write(library, into: table, keyValues: values, values: values)
      }

      for track in database.tracks {
        let trackID = sql(track.dbid)
        let previousAlbumID =
          try reconciling
          ? library.integer(in: "item", column: "album_pid", matching: ["pid": .integer(trackID)])
          : nil
        let previousArtistID =
          try reconciling
          ? library.integer(in: "item", column: "artist_pid", matching: ["pid": .integer(trackID)])
          : nil
        let previousComposerID =
          try reconciling
          ? library.integer(
            in: "item", column: "composer_pid", matching: ["pid": .integer(trackID)])
          : nil
        let trackArtistID = try artistID(for: track.artist)
        let albumArtistID = try artistID(
          for: nonempty(track.albumArtist) ?? nonempty(track.artist))
        let trackAlbumID = try albumID(
          for: track.album, artistID: albumArtistID, artworkTrackID: trackID,
          compilation: track.compilation)
        let trackComposerID = try composerID(for: track.composer)
        let trackGenreID = try genreID(for: track.genre)
        try write(
          library, into: "item", keyValues: ["pid": .integer(trackID)],
          values: [
            "pid": .integer(trackID), "media_kind": .integer(Int64(track.mediaKind)),
            "date_modified": .integer(sqlTime(track.timeModified, timezone: database.timezoneShift)),
            "date_released": .integer(
              sqlTime(track.timeReleased, timezone: database.timezoneShift)),
            "year": .integer(Int64(track.year)),
            "is_compilation": .integer(track.compilation ? 1 : 0),
            "remember_bookmark": .integer(track.rememberPlaybackPosition ? 1 : 0),
            "exclude_from_shuffle": .integer(track.skipWhenShuffling ? 1 : 0),
            "artwork_status": .integer(2), "artwork_cache_id": .integer(0),
            "start_time_ms": .double(0), "stop_time_ms": .double(0),
            "total_time_ms": .double(Double(track.lengthMS)),
            "track_number": .integer(Int64(track.trackNumber)),
            "track_count": .integer(Int64(track.trackCount)),
            "disc_number": .integer(Int64(track.discNumber)),
            "disc_count": .integer(Int64(track.discCount)),
            "relative_volume": .integer(Int64(track.volumeAdjustment)),
            "genre_id": .integer(trackGenreID), "album_pid": .integer(trackAlbumID),
            "artist_pid": .integer(trackArtistID), "composer_pid": .integer(trackComposerID),
            "title": text(track.title), "artist": text(track.artist),
            "album": text(track.album), "album_artist": text(track.albumArtist),
            "composer": text(track.composer),
            "sort_title": text(track.sortTitle ?? track.title),
            "sort_artist": text(track.sortArtist ?? track.artist),
            "sort_album": text(track.sortAlbum ?? track.album),
            "sort_album_artist": text(track.sortAlbumArtist ?? track.albumArtist),
            "sort_composer": text(track.sortComposer ?? track.composer),
            "comment": text(track.comment),
          ],
          preservingOnUpdate: [
            "artwork_status", "artwork_cache_id",
          ])
        try reconcileMapping(
          table: "item_to_album", relationColumn: "album_pid", itemID: trackID,
          previousRelationID: previousAlbumID, relationID: trackAlbumID)
        try reconcileMapping(
          table: "item_to_artist", relationColumn: "artist_pid", itemID: trackID,
          previousRelationID: previousArtistID, relationID: trackArtistID)
        try reconcileMapping(
          table: "item_to_composer", relationColumn: "composer_pid", itemID: trackID,
          previousRelationID: previousComposerID, relationID: trackComposerID)
        try write(
          library, into: "avformat_info",
          keyValues: ["item_pid": .integer(trackID), "sub_id": .integer(0)],
          values: [
            "item_pid": .integer(trackID), "sub_id": .integer(0),
            "audio_format": .integer(track.audioCodec.nanoAudioFormat),
            "bit_rate": .integer(Int64(track.bitrate)),
            "sample_rate": .double(Double(track.samplerate)), "duration": .integer(0),
            "gapless_heuristic_info": .integer(0),
            "gapless_encoding_delay": .integer(Int64(track.pregap)),
            "gapless_encoding_drain": .integer(Int64(track.postgap)),
            "gapless_last_frame_resynch": .integer(0),
            "analysis_inhibit_flags": .integer(0), "audio_fingerprint": .integer(0),
            "volume_normalization_energy": .integer(Int64(track.soundcheck)),
          ],
          preservingOnUpdate: [
            "sub_id", "duration", "gapless_heuristic_info",
            "gapless_last_frame_resynch", "analysis_inhibit_flags",
            "audio_fingerprint",
          ])
        try library.insert(
          into: "location_kind_map", orIgnore: true,
          values: [
            "id": .integer(1), "kind": .text(track.filetypeDescription ?? "MPEG audio file"),
          ])
        if track.mediaKind == ITDBMediaKind.podcast.rawValue {
          try write(
            library, into: "podcast_info", keyValues: ["item_pid": .integer(trackID)],
            values: ["item_pid": .integer(trackID)])
        } else if reconciling {
          try library.delete(from: "podcast_info", matching: ["item_pid": .integer(trackID)])
        }
      }

      for (order, playlist) in projectedPlaylists.enumerated() {
        let playlistID = sql(playlist.persistentID)
        try write(
          library, into: "container", keyValues: ["pid": .integer(playlistID)],
          values: [
            "pid": .integer(playlistID), "distinguished_kind": .integer(0),
            "date_created": .integer(sqlTime(playlist.timestamp, timezone: database.timezoneShift)),
            "date_modified": .integer(sqlTime(playlist.timestamp, timezone: database.timezoneShift)),
            "name": .text(playlist.name), "name_order": .integer(Int64(order)),
            "parent_pid": .integer(0),
            "media_kinds": .integer(playlist.isPodcast ? 4 : 1),
            "workout_template_id": .integer(0), "is_hidden": .integer(playlist.isMaster ? 1 : 0),
            "smart_is_folder": .integer(0),
          ],
          preservingOnUpdate: [
            "distinguished_kind", "date_created", "parent_pid", "media_kinds",
            "workout_template_id", "smart_is_folder",
          ])
        if reconciling {
          try library.delete(from: "item_to_container", where: "container_pid", in: [playlistID])
        }
        for (trackOrder, dbid) in playlist.memberDbids.enumerated() {
          try library.insert(
            into: "item_to_container",
            values: [
              "item_pid": .integer(sql(dbid)), "container_pid": .integer(playlistID),
              "physical_order": .integer(Int64(trackOrder)),
            ])
        }
      }
    }

    try dynamic.transaction {
      switch policy {
      case .reconcile:
        try dynamic.delete(from: "item_stats", where: "item_pid", in: removedTrackIDs)
        try dynamic.delete(from: "rental_info", where: "item_pid", in: removedTrackIDs)
        try dynamic.delete(from: "container_ui", where: "container_pid", in: removedPlaylistIDs)
      case .replaceAll:
        try dynamic.deleteAll(from: "item_stats")
        try dynamic.deleteAll(from: "container_ui")
        try dynamic.deleteAll(from: "rental_info")
      }
      for track in database.tracks {
        let trackID = sql(track.dbid)
        try write(
          dynamic, into: "item_stats", keyValues: ["item_pid": .integer(trackID)],
          values: [
            "item_pid": .integer(trackID),
            "has_been_played": .integer(track.playCount > 0 ? 1 : 0),
            "date_played": .integer(sqlTime(track.timePlayed, timezone: database.timezoneShift)),
            "play_count_user": .integer(Int64(track.playCount)),
            "play_count_recent": .integer(Int64(track.playCount2)),
            "bookmark_time_ms": .double(0), "bookmark_time_ms_common": .double(0),
            "user_rating": .integer(Int64(track.rating)),
            "user_rating_common": .integer(Int64(track.rating)),
          ], preservingOnUpdate: ["bookmark_time_ms", "bookmark_time_ms_common"])
      }
      for playlist in projectedPlaylists {
        let values = [
          "container_pid": SQLiteValue.integer(sql(playlist.persistentID)),
          "play_order": .integer(7), "is_reversed": .integer(0),
          "album_field_order": .integer(1), "repeat_mode": .integer(0),
          "shuffle_items": .integer(0), "has_been_shuffled": .integer(0),
        ]
        try write(
          dynamic, into: "container_ui",
          keyValues: ["container_pid": .integer(sql(playlist.persistentID))],
          values: values,
          preservingOnUpdate: Set(values.keys).subtracting(["container_pid"]))
      }
    }

    try locations.transaction {
      switch policy {
      case .reconcile:
        try locations.delete(from: "location", where: "item_pid", in: removedTrackIDs)
      case .replaceAll:
        try locations.deleteAll(from: "location")
        try locations.deleteAll(from: "base_location")
      }
      try write(
        locations, into: "base_location", keyValues: ["id": .integer(1)],
        values: ["id": .integer(1), "path": .text("iPod_Control/Music")],
        preservingOnUpdate: ["path"])
      for track in database.tracks {
        guard let path = track.ipodPath else { continue }
        let components = path.split(separator: ":")
        let relative =
          components.count >= 3
          ? components.dropFirst(2).joined(separator: "/")
          : components.joined(separator: "/")
        let trackID = sql(track.dbid)
        try write(
          locations, into: "location",
          keyValues: ["item_pid": .integer(trackID), "sub_id": .integer(0)],
          values: [
            "item_pid": .integer(trackID), "sub_id": .integer(0),
            "base_location_id": .integer(1), "location_type": .integer(0x4649_4c45),
            "location": .text(relative), "extension": .integer(Int64(track.filetypeMarker)),
            "kind_id": .integer(1),
            "date_created": .integer(sqlTime(track.timeModified, timezone: database.timezoneShift)),
            "file_size": .integer(Int64(track.sizeBytes)),
          ], preservingOnUpdate: ["sub_id", "base_location_id", "location_type", "kind_id"])
      }
    }

    if policy == .reconcile {
      let extras = try SQLiteStore(url: directory.appendingPathComponent("Extras.itdb"))
      try extras.transaction {
        try extras.delete(from: "chapter", where: "item_pid", in: removedTrackIDs)
      }
    }
  }

  private static func writeLocationsCBK(in directory: URL, material: Hash72Material) throws {
    let data = try Data(contentsOf: directory.appendingPathComponent("Locations.itdb"))
    var blockHashes = Data()
    var offset = 0
    while offset + 1024 <= data.count {
      blockHashes.append(Data(Insecure.SHA1.hash(data: data[offset..<offset + 1024])))
      offset += 1024
    }
    guard !blockHashes.isEmpty else {
      throw ITunesDBError.badHeader("Locations.itdb is unexpectedly small")
    }
    let finalHash = Data(Insecure.SHA1.hash(data: blockHashes))
    let cbk = material.signature(forSHA1: finalHash) + finalHash + blockHashes
    try cbk.write(to: directory.appendingPathComponent("Locations.itdb.cbk"), options: .atomic)
  }

  private static func writeHashInfo(
    _ material: Hash72Material, firewireGUID: Data, fileSystem: IpodFileSystem
  ) throws {
    let data =
      Data("HASHv0".utf8) + Hash72Material.deviceIdentifier(for: firewireGUID)
      + material.randomBytes + material.initializationVector
    let url = fileSystem.controlDir.appendingPathComponent("Device/HashInfo")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }

  private static func sql(_ value: UInt64) -> Int64 { Int64(bitPattern: value) }

  static func sqlTime(_ date: Date?, timezone: Int) -> Int64 {
    guard let date else { return 0 }
    return Int64(date.timeIntervalSince1970) - 978_307_200 - Int64(timezone)
  }

  private static func stableID(namespace: String, value: String) -> Int64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in (namespace + "\u{0}" + value).utf8 {
      hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    if hash == 0 { hash = 1 }
    return Int64(bitPattern: hash)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  private static func text(_ value: String?) -> SQLiteValue {
    value.map(SQLiteValue.text) ?? .null
  }
}

private enum SQLiteValue {
  case integer(Int64)
  case double(Double)
  case text(String)
  case null
}

private final class SQLiteStore {
  private var database: OpaquePointer?
  private var columnCache: [String: Set<String>] = [:]

  init(url: URL) throws {
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      if let database { sqlite3_close(database) }
      throw ITunesDBError.badHeader("cannot open \(url.lastPathComponent): \(message)")
    }
  }

  deinit {
    if let database { sqlite3_close(database) }
  }

  func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try body()
      try execute("COMMIT")
    } catch {
      do {
        try execute("ROLLBACK")
      } catch let rollbackError {
        NightdriveLog.ipodFS.error(
          "SQLite ROLLBACK failed after a failed transaction: \(rollbackError.localizedDescription, privacy: .public)"
        )
      }
      throw error
    }
  }

  func deleteAll(from table: String) throws {
    try execute("DELETE FROM \(quoted(table))")
  }

  func delete(from table: String, where column: String, in values: Set<Int64>) throws {
    guard !values.isEmpty else { return }
    let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
    let command =
      "DELETE FROM \(quoted(table)) WHERE \(quoted(column)) IN (\(placeholders))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare delete from \(table)") }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.sorted().enumerated() {
      sqlite3_bind_int64(statement, Int32(offset + 1), value)
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error("delete from \(table)") }
  }

  func delete(from table: String, matching keyValues: [String: SQLiteValue]) throws {
    guard !keyValues.isEmpty else {
      throw ITunesDBError.badHeader("delete from \(table) has no key columns")
    }
    let available = try columns(in: table)
    let keys = keyValues.filter { available.contains($0.key) }.sorted { $0.key < $1.key }
    guard keys.count == keyValues.count else {
      throw ITunesDBError.badHeader("table \(table) is missing a delete key column")
    }
    let predicate = keys.map { "\(quoted($0.key)) = ?" }.joined(separator: " AND ")
    let command = "DELETE FROM \(quoted(table)) WHERE \(predicate)"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare delete from \(table)") }
    defer { sqlite3_finalize(statement) }
    for (offset, entry) in keys.enumerated() {
      bind(entry.value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error("delete from \(table)") }
  }

  func upsert(
    into table: String, keyValues: [String: SQLiteValue],
    values: [String: SQLiteValue], preservingOnUpdate: Set<String> = []
  ) throws {
    guard !keyValues.isEmpty else {
      throw ITunesDBError.badHeader("upsert into \(table) has no key columns")
    }
    let available = try columns(in: table)
    let keys = keyValues.filter { available.contains($0.key) }.sorted { $0.key < $1.key }
    guard keys.count == keyValues.count else {
      throw ITunesDBError.badHeader("table \(table) is missing an upsert key column")
    }
    let rowExists = try contains(table: table, matching: keys)
    guard rowExists else {
      try insert(into: table, values: values)
      return
    }
    let keyColumns = Set(keys.map(\.key))
    let updates = values.filter {
      available.contains($0.key) && !keyColumns.contains($0.key)
        && !preservingOnUpdate.contains($0.key)
    }.sorted { $0.key < $1.key }
    if !updates.isEmpty {
      let assignments = updates.map { "\(quoted($0.key)) = ?" }.joined(separator: ",")
      let predicate = keys.map { "\(quoted($0.key)) = ?" }.joined(separator: " AND ")
      let command =
        "UPDATE \(quoted(table)) SET \(assignments) WHERE \(predicate)"
      var statement: OpaquePointer?
      guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
        let statement
      else { throw error("prepare update \(table)") }
      defer { sqlite3_finalize(statement) }
      for (offset, entry) in updates.enumerated() {
        bind(entry.value, to: statement, at: Int32(offset + 1))
      }
      for (offset, entry) in keys.enumerated() {
        bind(entry.value, to: statement, at: Int32(updates.count + offset + 1))
      }
      guard sqlite3_step(statement) == SQLITE_DONE else { throw error("update \(table)") }
    }
  }

  func updateAll(
    table: String, values: [String: SQLiteValue], insertValues: [String: SQLiteValue]
  ) throws {
    guard try hasRows(table: table) else {
      try insert(into: table, values: insertValues)
      return
    }
    let available = try columns(in: table)
    let updates = values.filter { available.contains($0.key) }.sorted { $0.key < $1.key }
    guard !updates.isEmpty else { throw ITunesDBError.badHeader("no columns to update in \(table)") }
    let command =
      "UPDATE \(quoted(table)) SET "
      + updates.map { "\(quoted($0.key)) = ?" }.joined(separator: ",")
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare update \(table)") }
    defer { sqlite3_finalize(statement) }
    for (offset, entry) in updates.enumerated() {
      bind(entry.value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else { throw error("update \(table)") }
  }

  func insert(into table: String, orIgnore: Bool = false, values: [String: SQLiteValue]) throws {
    let available = try columns(in: table)
    let filtered = values.filter { available.contains($0.key) }.sorted { $0.key < $1.key }
    guard !filtered.isEmpty else {
      throw ITunesDBError.badHeader("table \(table) has no expected columns")
    }
    let columnSQL = filtered.map { quoted($0.key) }.joined(separator: ",")
    let placeholders = Array(repeating: "?", count: filtered.count).joined(separator: ",")
    let command =
      "INSERT \(orIgnore ? "OR IGNORE " : "")INTO \(quoted(table)) "
      + "(\(columnSQL)) VALUES (\(placeholders))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw error("prepare insert into \(table)")
    }
    defer { sqlite3_finalize(statement) }
    for (offset, entry) in filtered.enumerated() {
      bind(entry.value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw error("insert into \(table)")
    }
  }

  private func columns(in table: String) throws -> Set<String> {
    if let cached = columnCache[table] { return cached }
    var statement: OpaquePointer?
    let command = "PRAGMA table_info(\(quoted(table)))"
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw error("inspect table \(table)")
    }
    defer { sqlite3_finalize(statement) }
    var result = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1) {
        result.insert(String(cString: name))
      }
    }
    guard !result.isEmpty else {
      throw ITunesDBError.badHeader("missing SQLite table \(table)")
    }
    columnCache[table] = result
    return result
  }

  func integer(
    in table: String, column: String, matching keyValues: [String: SQLiteValue]
  ) throws -> Int64? {
    let available = try columns(in: table)
    guard available.contains(column), keyValues.keys.allSatisfy(available.contains) else {
      throw ITunesDBError.badHeader("table \(table) is missing an expected lookup column")
    }
    let keys = keyValues.sorted { $0.key < $1.key }
    let predicate = keys.map { "\(quoted($0.key)) = ?" }.joined(separator: " AND ")
    let command =
      "SELECT \(quoted(column)) FROM \(quoted(table)) WHERE \(predicate) LIMIT 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare lookup in \(table)") }
    defer { sqlite3_finalize(statement) }
    for (offset, entry) in keys.enumerated() {
      bind(entry.value, to: statement, at: Int32(offset + 1))
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  func maximumInteger(in table: String, column: String) throws -> Int64? {
    let available = try columns(in: table)
    guard available.contains(column) else {
      throw ITunesDBError.badHeader("table \(table) is missing an expected lookup column")
    }
    let command = "SELECT MAX(\(quoted(column))) FROM \(quoted(table))"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare maximum lookup in \(table)") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL
    else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private func contains(
    table: String, matching keyValues: [(key: String, value: SQLiteValue)]
  ) throws -> Bool {
    let predicate = keyValues.map { "\(quoted($0.key)) = ?" }.joined(separator: " AND ")
    let command = "SELECT 1 FROM \(quoted(table)) WHERE \(predicate) LIMIT 1"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare lookup in \(table)") }
    defer { sqlite3_finalize(statement) }
    for (offset, entry) in keyValues.enumerated() {
      bind(entry.value, to: statement, at: Int32(offset + 1))
    }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func hasRows(table: String) throws -> Bool {
    var statement: OpaquePointer?
    let command = "SELECT 1 FROM \(quoted(table)) LIMIT 1"
    guard sqlite3_prepare_v2(database, command, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw error("prepare row lookup in \(table)") }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    switch value {
    case .integer(let value): sqlite3_bind_int64(statement, index, value)
    case .double(let value): sqlite3_bind_double(statement, index, value)
    case .text(let value): sqlite3_bind_text(statement, index, value, -1, transient)
    case .null: sqlite3_bind_null(statement, index)
    }
  }

  private func execute(_ command: String) throws {
    var message: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, command, nil, nil, &message) == SQLITE_OK else {
      let detail = message.map { String(cString: $0) } ?? "unknown SQLite error"
      sqlite3_free(message)
      throw ITunesDBError.badHeader(detail)
    }
  }

  private func error(_ operation: String) -> ITunesDBError {
    let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    return .badHeader("\(operation): \(detail)")
  }

  private func quoted(_ identifier: String) -> String {
    "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}
