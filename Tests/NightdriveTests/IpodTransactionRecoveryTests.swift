import Darwin
import Foundation
import Testing

@testable import Nightdrive

@MainActor
final class IpodTransactionRecoveryTests {
  private var volume: URL!
  private var fileSystem: IpodFileSystem!

  init() throws {
    volume = TestScratch.directory(prefix: "NightdriveTransactionRecoveryTests")
    fileSystem = IpodFileSystem(volumeURL: volume)
    try FileManager.default.createDirectory(
      at: fileSystem.itunesDir, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: volume)
  }

  private func assertCopyRecoveryRejects(_ journal: IpodCopyTransactionJournal) throws {
    let transaction = try IpodCopyTransaction(fileSystem: fileSystem)
    defer { transaction.finish() }
    try JSONEncoder().encode(journal).write(
      to: transaction.directory.appendingPathComponent("journal.json"))

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedSyncCopies(database: ITunesDatabase())
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testCopyRecoveryRejectsOversizedJournal() throws {
    let transaction = try IpodCopyTransaction(fileSystem: fileSystem)
    defer { transaction.finish() }
    try Data(repeating: 0x20, count: IpodCopyTransaction.maximumJournalBytes + 1).write(
      to: transaction.directory.appendingPathComponent("journal.json"))

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedSyncCopies(database: ITunesDatabase())
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testCopyRecoveryRejectsTooManyEntries() throws {
    let journal = IpodCopyTransactionJournal(
      entries: (0...IpodCopyTransaction.maximumEntryCount).map { index in
        IpodCopyTransactionEntry(
          stagedName: String(
            format: "00000000-0000-0000-0000-%012X.mp3", index),
          ipodPath: ":iPod_Control:Music:F00:T\(index).mp3")
      })
    let encoded = try JSONEncoder().encode(journal)
    #expect((encoded.count) <= (IpodCopyTransaction.maximumJournalBytes))
    #expect(
      (Set(journal.entries.map { $0.ipodPath.lowercased() }).count) == (journal.entries.count),
      Comment(rawValue: "the entry-count test must not be rejected by duplicate validation first"))

    try assertCopyRecoveryRejects(journal)
  }

  @Test
  func testCopyRecoveryRejectsOverlongAndUnsafeFields() throws {
    let validName = "00000000-0000-0000-0000-000000000000.mp3"
    let validPath = ":iPod_Control:Music:F00:SAFE.mp3"
    let invalidEntries = [
      IpodCopyTransactionEntry(
        stagedName: validName,
        ipodPath: ":iPod_Control:Music:F00:\(String(repeating: "A", count: 2_000)).mp3"),
      IpodCopyTransactionEntry(
        stagedName: String(repeating: "A", count: IpodCopyTransaction.maximumStagedNameBytes + 1),
        ipodPath: validPath),
      IpodCopyTransactionEntry(stagedName: "../escape.mp3", ipodPath: validPath),
      IpodCopyTransactionEntry(
        stagedName: validName,
        ipodPath: ":iPod_Control:Music:F00:..:escape.mp3"),
    ]

    for entry in invalidEntries {
      try assertCopyRecoveryRejects(IpodCopyTransactionJournal(entries: [entry]))
    }
  }

  @Test
  func testCopyAndDeletionTransactionsRejectUnicodeMusicFolderDigits() throws {
    let ipodPath = ":iPod_Control:Music:F٠٠:TRACK.mp3"

    #expect(fileSystem.transactionMusicFileURL(forIpodPath: ipodPath) == nil)

    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try transaction.stageMusicFileIfPresent(dbid: 123, ipodPath: ipodPath)
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testCopyTransactionRejectsOverlongStagedNameBeforePublishing() throws {
    let source = volume.appendingPathComponent("source.mp3")
    try Data("audio".utf8).write(to: source)
    let destination = fileSystem.musicDir.appendingPathComponent(
      "F00/SAFE.\(String(repeating: "A", count: IpodCopyTransaction.maximumStagedNameBytes))")
    let transaction = try IpodCopyTransaction(fileSystem: fileSystem)
    defer { transaction.finish() }

    #expect(throws: (any Error).self) { try transaction.stage(source: source, destination: destination) }
    #expect(transaction.entries.isEmpty)
  }

  @Test
  func testDeletionRecoveryRemovesJournalLessTransaction() throws {
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)

    try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())

    #expect(!(FileManager.default.fileExists(atPath: transaction.directory.path)))
    #expect(!(FileManager.default.fileExists(atPath: fileSystem.syncTransactionsDirectory.path)))
  }

  @Test
  func testStagedDeletionBatchReleasesAllDescriptorsPerTrack() throws {
    let batchVolume = volume.appendingPathComponent("descriptor-batch", isDirectory: true)
    let batchFileSystem = IpodFileSystem(volumeURL: batchVolume)
    try FileManager.default.createDirectory(
      at: batchFileSystem.itunesDir, withIntermediateDirectories: true)
    let baselineDescriptorCount = try openFileDescriptorCount()
    let transactionCount = 50
    var transactions: [IpodDeleteTransaction] = []

    for index in 0..<transactionCount {
      let filename = String(format: "TRACK-%03d.mp3", index)
      let source = batchFileSystem.musicDir.appendingPathComponent("F00/\(filename)")
      try FileManager.default.createDirectory(
        at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("audio \(index)".utf8).write(to: source)
      let transaction = try IpodDeleteTransaction(fileSystem: batchFileSystem)
      #expect(
        try transaction.stageMusicFileIfPresent(
          dbid: UInt64(index + 1),
          ipodPath: ":iPod_Control:Music:F00:\(filename)"))
      transactions.append(transaction)
    }

    let stagedDescriptorCount = try openFileDescriptorCount()
    #expect((stagedDescriptorCount - baselineDescriptorCount) <= (8))

    let interferenceDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
    #expect((interferenceDescriptor) >= (0))
    defer {
      if interferenceDescriptor >= 0 { Darwin.close(interferenceDescriptor) }
    }
    for transaction in transactions { transaction.finish() }

    let finishedDescriptorCount = try openFileDescriptorCount()
    #expect((finishedDescriptorCount) <= (baselineDescriptorCount + 8))
    #expect(
      !(FileManager.default.fileExists(
        atPath: batchFileSystem.syncTransactionsDirectory.path)))
  }

  @Test
  func testDeletionRecoveryRejectsOversizedJournal() throws {
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    try Data(repeating: 0x20, count: 64 * 1_024).write(
      to: transaction.directory.appendingPathComponent("journal.json"))

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
    #expect(FileManager.default.fileExists(atPath: transaction.directory.path))
  }

  @Test
  func testDeletionRecoveryRejectsOverlongDecodedPath() throws {
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let journal = IpodDeleteTransactionJournal(
      dbid: 123,
      ipodPath: ":iPod_Control:Music:F00:\(String(repeating: "A", count: 2_000)).mp3",
      stagedName: "audio.mp3")
    try JSONEncoder().encode(journal).write(
      to: transaction.directory.appendingPathComponent("journal.json"))

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testDeletionRecoveryRejectsUnknownJournalFields() throws {
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let data = Data(
      #"{"dbid":123,"ipodPath":":iPod_Control:Music:F00:TRACK.mp3","stagedName":"audio.mp3","unexpected":true}"#
        .utf8)
    try data.write(to: transaction.directory.appendingPathComponent("journal.json"))

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())
      }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("Expected badHeader, got \(caughtError)")
          return
        }
      }
    }
    #expect(FileManager.default.fileExists(atPath: transaction.directory.path))
  }

  @Test
  func testDeletionStageRejectsUnsupportedExtensionBeforeJournalOrMove() throws {
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.mp-3")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let journal = transaction.directory.appendingPathComponent("journal.json")

    #expect(throws: (any Error).self) {
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: ":iPod_Control:Music:F00:TRACK.mp-3")
    }

    #expect((try Data(contentsOf: source)) == (original))
    #expect(!(FileManager.default.fileExists(atPath: journal.path)))
    #expect(!(FileManager.default.fileExists(atPath: transaction.directory.path)))
  }

  @Test
  func testDeletionStageRejectsOverlongStagedNameBeforeJournalOrMove() throws {
    let fileExtension = String(repeating: "a", count: 129)
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.\(fileExtension)")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let journal = transaction.directory.appendingPathComponent("journal.json")

    #expect(throws: (any Error).self) {
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: ":iPod_Control:Music:F00:TRACK.\(fileExtension)")
    }

    #expect((try Data(contentsOf: source)) == (original))
    #expect(!(FileManager.default.fileExists(atPath: journal.path)))
    #expect(!(FileManager.default.fileExists(atPath: transaction.directory.path)))
  }

  @Test
  func testDeletionStageRejectsNoncanonicalPathBeforeJournalOrMove() throws {
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.mp3")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let journal = transaction.directory.appendingPathComponent("journal.json")

    #expect(throws: (any Error).self) {
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: "::iPod_Control:Music:F00:TRACK.mp3")
    }

    #expect((try Data(contentsOf: source)) == (original))
    #expect(!(FileManager.default.fileExists(atPath: journal.path)))
    #expect(!(FileManager.default.fileExists(atPath: transaction.directory.path)))
  }

  @Test
  func testDeletionTransactionRejectsIntermediateControlDirectorySwap() throws {
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.mp3")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let parkedControl = volume.appendingPathComponent("parked-iPod_Control", isDirectory: true)
    let outsideControl = volume.appendingPathComponent("outside-control", isDirectory: true)
    let outsideITunes = outsideControl.appendingPathComponent("iTunes", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideITunes, withIntermediateDirectories: true)
    let sentinel = outsideITunes.appendingPathComponent("sentinel")
    let sentinelData = Data("outside must survive".utf8)
    try sentinelData.write(to: sentinel)

    #expect(throws: (any Error).self) {
      try IpodDeleteTransaction(
        fileSystem: fileSystem,
        afterOpeningControlDirectory: {
          try FileManager.default.moveItem(at: self.fileSystem.controlDir, to: parkedControl)
          try FileManager.default.createSymbolicLink(
            at: self.fileSystem.controlDir, withDestinationURL: outsideControl)
        })
    }

    #expect((try Data(contentsOf: sentinel)) == (sentinelData))
    #expect(
      (try Data(
        contentsOf: parkedControl.appendingPathComponent("Music/F00/TRACK.mp3"))) == (original))
    #expect(
      !(FileManager.default.fileExists(
        atPath: outsideITunes.appendingPathComponent(".nightdrive-transactions").path)))
  }

  @Test
  func testDeletionRecoveryRejectsIntermediateControlDirectorySwap() throws {
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.mp3")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    #expect(
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: ":iPod_Control:Music:F00:TRACK.mp3"))
    let transactionName = transaction.directory.lastPathComponent
    let parkedControl = volume.appendingPathComponent("parked-iPod_Control", isDirectory: true)
    let outsideControl = volume.appendingPathComponent("outside-control", isDirectory: true)
    let outsideITunes = outsideControl.appendingPathComponent("iTunes", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideITunes, withIntermediateDirectories: true)
    let sentinel = outsideITunes.appendingPathComponent("sentinel")
    let sentinelData = Data("outside must survive".utf8)
    try sentinelData.write(to: sentinel)

    #expect(throws: (any Error).self) {
      try IpodDeleteTransaction.recoverAll(
        fileSystem: fileSystem,
        database: ITunesDatabase(),
        afterOpeningControlDirectory: {
          try FileManager.default.moveItem(at: self.fileSystem.controlDir, to: parkedControl)
          try FileManager.default.createSymbolicLink(
            at: self.fileSystem.controlDir, withDestinationURL: outsideControl)
        })
    }

    #expect((try Data(contentsOf: sentinel)) == (sentinelData))
    #expect(
      FileManager.default.fileExists(
        atPath: parkedControl.appendingPathComponent(
          "iTunes/.nightdrive-transactions/\(transactionName)/journal.json"
        ).path))
    #expect(
      FileManager.default.fileExists(
        atPath: parkedControl.appendingPathComponent(
          "iTunes/.nightdrive-transactions/\(transactionName)/audio.mp3"
        ).path))
    #expect(
      !(FileManager.default.fileExists(
        atPath: outsideITunes.appendingPathComponent(".nightdrive-transactions").path)))
  }

  @Test
  func testDeletionFinishRejectsTransactionDirectoryReplacementAfterStage() throws {
    let source = fileSystem.musicDir.appendingPathComponent("F00/TRACK.mp3")
    try FileManager.default.createDirectory(
      at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original audio".utf8)
    try original.write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    #expect(
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: ":iPod_Control:Music:F00:TRACK.mp3"))
    let parkedTransaction = volume.appendingPathComponent(
      "parked-delete-transaction", isDirectory: true)
    try FileManager.default.moveItem(at: transaction.directory, to: parkedTransaction)
    try FileManager.default.createDirectory(
      at: transaction.directory, withIntermediateDirectories: false)
    let sentinel = transaction.directory.appendingPathComponent("keep.txt")
    let sentinelData = Data("replacement must survive".utf8)
    try sentinelData.write(to: sentinel)

    transaction.finish()

    #expect((try Data(contentsOf: parkedTransaction.appendingPathComponent("audio.mp3"))) == (original))
    #expect((try Data(contentsOf: sentinel)) == (sentinelData))
  }

  @Test
  func testCommittedDeletionCleansUpWhenOriginalParentVanished() throws {
    let parent = fileSystem.musicDir.appendingPathComponent("F00", isDirectory: true)
    let source = parent.appendingPathComponent("TRACK.mp3")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: source)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    #expect(
      try transaction.stageMusicFileIfPresent(
        dbid: 123, ipodPath: ":iPod_Control:Music:F00:TRACK.mp3"))
    try FileManager.default.removeItem(at: parent)

    try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())

    #expect(!(FileManager.default.fileExists(atPath: transaction.directory.path)))
    #expect(!(FileManager.default.fileExists(atPath: fileSystem.syncTransactionsDirectory.path)))
  }

  @Test
  func testDeletionRecoveryNeverRecursivelyRemovesUnexpectedStagedDirectory() throws {
    try FileManager.default.createDirectory(
      at: fileSystem.musicDir.appendingPathComponent("F00"),
      withIntermediateDirectories: true)
    let transaction = try IpodDeleteTransaction(fileSystem: fileSystem)
    let journal = IpodDeleteTransactionJournal(
      dbid: 123,
      ipodPath: ":iPod_Control:Music:F00:TRACK.mp3",
      stagedName: "audio.mp3")
    try JSONEncoder().encode(journal).write(
      to: transaction.directory.appendingPathComponent("journal.json"))
    let nested = transaction.directory.appendingPathComponent("audio.mp3/tree/keep.txt")
    try FileManager.default.createDirectory(
      at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
    let sentinel = Data("preserve the unexpected tree".utf8)
    try sentinel.write(to: nested)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fileSystem.recoverInterruptedDeletions(database: ITunesDatabase())
      }
      if let caughtError {
        #expect(caughtError.localizedDescription.contains("unexpected non-file"))
      }
    }

    #expect((try Data(contentsOf: nested)) == (sentinel))
    #expect(FileManager.default.fileExists(atPath: transaction.directory.path))
  }

  private func openFileDescriptorCount() throws -> Int {
    guard let directory = opendir("/dev/fd") else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { closedir(directory) }
    var count = 0
    while let entry = readdir(directory) {
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
      }
      if name != "." && name != ".." { count += 1 }
    }
    return count
  }
}
