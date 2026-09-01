import Foundation
import Testing

@testable import Nightdrive

struct CorruptRecoveryMarkerReadTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture
  private let fs: IpodFileSystem

  init() throws {
    scratchFixture = try ScratchFixture()
    fs = IpodFileSystem(volumeURL: scratchFixture.scratch)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
  }

  private let shuffleMarkerName = ".nightdrive-shuffle-database-transaction.plist"
  private let shuffleQuarantinePrefix =
    ".nightdrive-quarantined-shuffle-database-transaction-"
  private let nanoMarkerName = ".nightdrive-nano-install.plist"
  private let nanoQuarantinePrefix = ".nightdrive-quarantined-nano-install-"

  @Test
  func testMalformedShuffleMarkerDoesNotBlockRepeatedReadsAndQuarantinesEveryIncident()
    throws
  {
    let live = try seedLegacyDatabase(named: "Valid Shuffle Live", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(shuffleMarkerName)
    let first = Data("truncated shuffle marker one".utf8)
    try first.write(to: marker)

    for _ in 1...2 {
      #expect(try fs.readDatabase().masterPlaylistName == "Valid Shuffle Live")
    }
    #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix) == [first])

    let second = Data("truncated shuffle marker two".utf8)
    try second.write(to: marker)
    #expect(try fs.readDatabase().masterPlaylistName == "Valid Shuffle Live")
    #expect(Set(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix)) == Set([first, second]))
    #expect(ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs))
    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: fs.databaseURL) == live)
  }

  @Test
  func testMalformedNanoMarkerDoesNotBlockRepeatedReadsAndQuarantinesEveryIncident() throws {
    let live = try seedNanoDatabase(named: "Valid Nano Live", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let first = Data("truncated nano marker one".utf8)
    try first.write(to: marker)

    for _ in 1...2 {
      #expect(try fs.readDatabase().masterPlaylistName == "Valid Nano Live")
    }
    #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix) == [first])

    let second = Data("truncated nano marker two".utf8)
    try second.write(to: marker)
    #expect(try fs.readDatabase().masterPlaylistName == "Valid Nano Live")
    #expect(Set(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix)) == Set([first, second]))
    #expect(Nano5DatabaseWriter.hasPendingTransaction(fileSystem: fs))
    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: fs.compressedDatabaseURL) == live)
  }

  @Test
  func testMalformedShuffleMarkerRemainsFailClosedForMutationRecovery() throws {
    let live = try seedLegacyDatabase(named: "Valid Shuffle Live", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(shuffleMarkerName)
    let corrupt = Data("truncated shuffle marker".utf8)
    try corrupt.write(to: marker)

    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: fs.databaseURL) == live)
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).isEmpty)
  }

  @Test
  func testMalformedNanoMarkerRemainsFailClosedForMutationRecovery() throws {
    let live = try seedNanoDatabase(named: "Valid Nano Live", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let corrupt = Data("truncated nano marker".utf8)
    try corrupt.write(to: marker)

    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: fs.compressedDatabaseURL) == live)
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).isEmpty)
  }

  @Test
  func testMalformedShuffleMarkerStillRequiresAValidLiveDatabase() throws {
    let invalidLive = Data("not an iTunesDB".utf8)
    try invalidLive.write(to: fs.databaseURL)
    try Data("bad marker".utf8).write(
      to: fs.itunesDir.appendingPathComponent(shuffleMarkerName))

    #expect(throws: (any Error).self) { try fs.readDatabase() }
    #expect(try Data(contentsOf: fs.databaseURL) == invalidLive)
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).count == 1)
  }

  @Test
  func testMalformedNanoMarkerStillRequiresAValidLiveDatabase() throws {
    let invalidLive = Data("not an iTunesCDB".utf8)
    try invalidLive.write(to: fs.compressedDatabaseURL)
    try Data("bad marker".utf8).write(
      to: fs.itunesDir.appendingPathComponent(nanoMarkerName))

    #expect(throws: (any Error).self) { try fs.readDatabase() }
    #expect(try Data(contentsOf: fs.compressedDatabaseURL) == invalidLive)
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).count == 1)
  }

  @Test
  func testReadOnlyShuffleMarkerIsIgnoredWithoutLosingForensics() throws {
    defer { try? makeWritable(fs.itunesDir) }
    _ = try seedLegacyDatabase(named: "Read-Only Shuffle", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(shuffleMarkerName)
    let corrupt = Data("read-only shuffle marker".utf8)
    try corrupt.write(to: marker)
    try makeReadOnly(fs.itunesDir)

    for _ in 1...2 {
      #expect(try fs.readDatabase().masterPlaylistName == "Read-Only Shuffle")
    }
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).isEmpty)

    try makeWritable(fs.itunesDir)
    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: marker) == corrupt)
  }

  @Test
  func testReadOnlyNanoMarkerIsIgnoredWithoutLosingForensicsOrDeadlocking() throws {
    defer { try? makeWritable(fs.itunesDir) }
    _ = try seedNanoDatabase(named: "Read-Only Nano", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let corrupt = Data("read-only nano marker".utf8)
    try corrupt.write(to: marker)
    try makeReadOnly(fs.itunesDir)

    for _ in 1...2 {
      #expect(try fs.readDatabase().masterPlaylistName == "Read-Only Nano")
    }
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).isEmpty)

    try makeWritable(fs.itunesDir)
    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: marker) == corrupt)
  }

  @Test
  func testArbitraryShuffleRecoveryLockErrorStillBlocksTheRead() throws {
    _ = try seedLegacyDatabase(named: "Valid Shuffle", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(shuffleMarkerName)
    let corrupt = Data("shuffle marker awaiting recovery".utf8)
    try corrupt.write(to: marker)
    try FileManager.default.createDirectory(
      at: fs.itunesDir.appendingPathComponent(".nightdrive-shuffle.lock"),
      withIntermediateDirectories: false)

    for _ in 1...2 { #expect(throws: (any Error).self) { try fs.readDatabase() } }
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).isEmpty)
  }

  @Test
  func testArbitraryNanoRecoveryLockErrorStillBlocksTheReadWithoutDeadlocking() throws {
    _ = try seedNanoDatabase(named: "Valid Nano", fileSystem: fs)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let corrupt = Data("nano marker awaiting recovery".utf8)
    try corrupt.write(to: marker)
    try FileManager.default.createDirectory(
      at: fs.itunesDir.appendingPathComponent(".nightdrive-nano.lock"),
      withIntermediateDirectories: false)

    for _ in 1...2 { #expect(throws: (any Error).self) { try fs.readDatabase() } }
    #expect(try Data(contentsOf: marker) == corrupt)
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).isEmpty)
  }

  @Test
  func testShufflePermissionFailureAfterFirstRecoveryMutationStillBlocksTheRead() throws {
    struct Interrupted: Error {}
    let oldDatabase = try seedLegacyDatabase(named: "Old Shuffle", fileSystem: fs)
    var replacement = ITunesDatabase()
    replacement.masterPlaylistName = "Replacement Shuffle"
    #expect(throws: (any Error).self) {
      try ShuffleDatabaseWriter.install(
        databaseData: ITunesDBWriter().write(replacement),
        shuffleData: Data("replacement shuffle generation".utf8), fileSystem: fs,
        after: { if $0 == .databaseInstalled { throw Interrupted() } })
    }

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ShuffleDatabaseWriter.recoverForReadIfNeeded(fileSystem: fs) { checkpoint in
          if checkpoint == .databaseRestored { throw POSIXError(.EACCES) }
        }
      }
      if let caughtError {
        #expect((caughtError as? POSIXError)?.code == .EACCES)
      }
    }
    #expect(try Data(contentsOf: fs.databaseURL) == oldDatabase)
    #expect(
      FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(shuffleMarkerName).path))
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).isEmpty)
  }

  @Test
  func testNanoPermissionFailureAfterFirstRecoveryMutationStillBlocksTheRead() throws {
    struct Interrupted: Error {}
    _ = try seedNanoGeneration(named: "Old Nano", fileSystem: fs)
    let staged = try stagedNanoGeneration(named: "Replacement Nano", fileSystem: fs)
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: staged.directory, stagedCDB: staged.cdb, fileSystem: fs,
        after: { if $0 == .directoryInstalled { throw Interrupted() } })
    }

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.recoverForReadIfNeeded(fileSystem: fs) { checkpoint in
          if checkpoint == .directoryRestored { throw POSIXError(.EACCES) }
        }
      }
      if let caughtError {
        #expect((caughtError as? POSIXError)?.code == .EACCES)
      }
    }
    #expect(
      FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(nanoMarkerName).path))
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).isEmpty)
  }

  @Test
  func testNanoCommittedLivePermissionErrorIsNotReclassifiedAsBadBackupMetadata() throws {
    struct Interrupted: Error {}
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: fs.compressedDatabaseURL.path)
    }
    _ = try seedNanoGeneration(named: "Old Nano", fileSystem: fs)
    let staged = try stagedNanoGeneration(named: "Committed Nano", fileSystem: fs)
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: staged.directory, stagedCDB: staged.cdb, fileSystem: fs,
        after: { if $0 == .committed { throw Interrupted() } })
    }
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let metadata = try #require(
      PropertyListSerialization.propertyList(
        from: Data(contentsOf: marker), options: [], format: nil) as? [String: Any])
    let identifier = try #require(metadata["identifier"] as? String)
    let backupCDB = fs.itunesDir.appendingPathComponent(
      ".nightdrive-nano-\(identifier)-backup.cdb")
    try Data("corrupt but readable backup".utf8).write(to: backupCDB)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: fs.compressedDatabaseURL.path)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.recoverForReadIfNeeded(fileSystem: fs)
      }
      if let caughtError {
        #expect(
          RecoveryMarkerReadSupport.isReadOnlyAccessError(caughtError),
          Comment(rawValue: "unexpected error: \(caughtError)"))
      }
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix).isEmpty)
  }

  @Test
  func testUnsafeShuffleSymlinkMarkerQuarantinesOnlyTheFixedLink() throws {
    _ = try seedLegacyDatabase(named: "Safe Shuffle Live", fileSystem: fs)
    let outside = scratch.appendingPathComponent("outside-sentinel")
    let sentinel = Data("outside forensic target".utf8)
    try sentinel.write(to: outside)
    let marker = fs.itunesDir.appendingPathComponent(shuffleMarkerName)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)

    #expect(try fs.readDatabase().masterPlaylistName == "Safe Shuffle Live")
    #expect(try Data(contentsOf: outside) == sentinel)
    #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    let quarantined = try quarantinedMarkers(in: fs, prefix: shuffleQuarantinePrefix)
    #expect(quarantined.count == 1)
    #expect(try quarantined[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
  }

  @Test
  func testUnsafeNanoSymlinkMarkerQuarantinesOnlyTheFixedLink() throws {
    _ = try seedNanoDatabase(named: "Safe Nano Live", fileSystem: fs)
    let outside = scratch.appendingPathComponent("outside-nano-sentinel")
    let sentinel = Data("outside nano forensic target".utf8)
    try sentinel.write(to: outside)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: outside)

    #expect(try fs.readDatabase().masterPlaylistName == "Safe Nano Live")
    #expect(try Data(contentsOf: outside) == sentinel)
    #expect(!(FileManager.default.fileExists(atPath: marker.path)))
    let quarantined = try quarantinedMarkers(in: fs, prefix: nanoQuarantinePrefix)
    #expect(quarantined.count == 1)
    #expect(try quarantined[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
  }

  @Test
  func testUnsafeNanoMarkerPathsAreNeverUsed() throws {
    _ = try seedNanoDatabase(named: "Safe Nano Live", fileSystem: fs)
    let sentinel = fs.itunesDir.appendingPathComponent("sentinel")
    let sentinelData = Data("must remain".utf8)
    try sentinelData.write(to: sentinel)
    let marker = fs.itunesDir.appendingPathComponent(nanoMarkerName)
    let unsafe = try nanoMarkerData(
      phase: "preparing", directoryName: "../sentinel", cdbName: "iTunesCDB")
    try unsafe.write(to: marker)

    #expect(try fs.readDatabase().masterPlaylistName == "Safe Nano Live")
    #expect(try Data(contentsOf: sentinel) == sentinelData)
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix) == [unsafe])
    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
  }

  @Test
  func testUnclassifiableShuffleRecoveryMetadataFallsBackToValidLiveDatabase() throws {
    struct Interrupted: Error {}
    _ = try seedLegacyDatabase(named: "Old Shuffle", fileSystem: fs)
    var replacement = ITunesDatabase()
    replacement.masterPlaylistName = "Replacement Shuffle"
    #expect(throws: (any Error).self) {
      try ShuffleDatabaseWriter.install(
        databaseData: ITunesDBWriter().write(replacement),
        shuffleData: ITunesSDFile.write([]), fileSystem: fs,
        after: { if $0 == .databaseInstalled { throw Interrupted() } })
    }
    var unrelated = ITunesDatabase()
    unrelated.masterPlaylistName = "Unrelated Valid Shuffle"
    let unrelatedData = ITunesDBWriter().write(unrelated)
    try unrelatedData.write(to: fs.databaseURL)

    #expect(try fs.readDatabase().masterPlaylistName == "Unrelated Valid Shuffle")
    #expect(try Data(contentsOf: fs.databaseURL) == unrelatedData)
    #expect(try quarantineContents(in: fs, prefix: shuffleQuarantinePrefix).count == 1)
    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
  }

  @Test
  func testUnclassifiableNanoRecoveryMetadataFallsBackToValidLiveDatabase() throws {
    _ = try seedNanoDatabase(named: "Unrelated Valid Nano", fileSystem: fs)
    let marker = try nanoMarkerData(
      phase: "committed",
      directoryName: ".nightdrive-itlp-\(UUID().uuidString)",
      cdbName: ".nightdrive-cdb-\(UUID().uuidString)")
    try marker.write(to: fs.itunesDir.appendingPathComponent(nanoMarkerName))

    #expect(try fs.readDatabase().masterPlaylistName == "Unrelated Valid Nano")
    #expect(try quarantineContents(in: fs, prefix: nanoQuarantinePrefix) == [marker])
    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
  }

  private func seedLegacyDatabase(named name: String, fileSystem fs: IpodFileSystem) throws
    -> Data
  {
    var database = ITunesDatabase()
    database.masterPlaylistName = name
    let data = ITunesDBWriter().write(database)
    try data.write(to: fs.databaseURL)
    try ITunesSDFile.write([]).write(to: fs.shuffleDatabaseURL)
    return data
  }

  private func seedNanoDatabase(named name: String, fileSystem fs: IpodFileSystem) throws
    -> Data
  {
    var database = ITunesDatabase()
    database.masterPlaylistName = name
    let data = try ITunesCDB.compress(ITunesDBWriter().write(database))
    try data.write(to: fs.compressedDatabaseURL)
    return data
  }

  private func seedNanoGeneration(named name: String, fileSystem fs: IpodFileSystem) throws
    -> Data
  {
    try FileManager.default.createDirectory(
      at: fs.sqliteLibraryDirectory, withIntermediateDirectories: true)
    for fileName in nanoGenerationFileNames {
      try Data("old \(fileName)".utf8).write(
        to: fs.sqliteLibraryDirectory.appendingPathComponent(fileName))
    }
    return try seedNanoDatabase(named: name, fileSystem: fs)
  }

  private func stagedNanoGeneration(named name: String, fileSystem fs: IpodFileSystem) throws
    -> (directory: URL, cdb: URL)
  {
    let directory = fs.itunesDir.appendingPathComponent(
      ".nightdrive-itlp-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for fileName in nanoGenerationFileNames {
      try Data("new \(fileName)".utf8).write(to: directory.appendingPathComponent(fileName))
    }
    var database = ITunesDatabase()
    database.masterPlaylistName = name
    let cdb = fs.itunesDir.appendingPathComponent(".nightdrive-cdb-\(UUID().uuidString)")
    try ITunesCDB.compress(ITunesDBWriter().write(database)).write(to: cdb)
    return (directory, cdb)
  }

  private var nanoGenerationFileNames: [String] {
    [
      "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
      "Locations.itdb.cbk",
    ]
  }

  private func nanoMarkerData(
    phase: String, directoryName: String, cdbName: String
  ) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "identifier": UUID().uuidString,
        "phase": phase,
        "originalStagedDirectoryName": directoryName,
        "originalStagedCDBName": cdbName,
        "sqliteHashes": [String: Data](),
        "cdbHash": Data(),
      ], format: .binary, options: 0)
  }

  private func quarantinedMarkers(in fs: IpodFileSystem, prefix: String) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: fs.itunesDir, includingPropertiesForKeys: nil
    ).filter {
      $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(".plist")
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func quarantineContents(in fs: IpodFileSystem, prefix: String) throws -> [Data] {
    try quarantinedMarkers(in: fs, prefix: prefix).map { try Data(contentsOf: $0) }
  }

  private func makeReadOnly(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
  }

  private func makeWritable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}
