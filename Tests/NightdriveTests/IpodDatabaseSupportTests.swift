import CryptoKit
import Foundation
import Testing

@testable import Nightdrive

struct IpodDatabaseSupportTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }

  @Test
  func testFirewireGUIDParsing() {
    #expect(
      IpodDatabaseSupport.parseGUID(" 0x000A27001A2B3C4D ") == Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d]))
    #expect(
      IpodDatabaseSupport.parseGUID("000A27001A2B3C4Dmore-serial-data")
        == Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d]))
    #expect(IpodDatabaseSupport.parseGUID("not-a-guid") == nil)
  }

  @Test
  func testHash58MatchesReferenceVector() throws {
    var database = Data((0..<700).map { UInt8(($0 * 37 + 11) & 0xff) })
    database.replaceSubrange(0..<4, with: Data("mhbd".utf8))
    let guid = try #require(IpodDatabaseSupport.parseGUID("000A27001A2B3C4D"))

    let signed = try Hash58.sign(database, firewireGUID: guid)

    #expect(Array(signed[48..<50]) == [1, 0])
    #expect(
      Data(signed[88..<108]).hex == "1ef94c58fe8c5143339bdedf4521b644a485e8e7")
    #expect(signed[24..<32] == database[24..<32])
    #expect(signed[50..<70] == database[50..<70])
  }

  @Test
  func testCompressedDatabaseRoundTrip() throws {
    var db = ITunesDatabase()
    var track = ITDBTrack()
    track.title = "Compressed"
    track.artist = "Nano"
    track.ipodPath = ":iPod_Control:Music:F00:NANO.mp3"
    db.tracks = [track]
    let raw = ITunesDBWriter().write(db)

    let compressed = try ITunesCDB.compress(raw)

    #expect(compressed[0xa8] == 1)
    #expect(compressed.count < raw.count)
    #expect(try ITunesCDB.decompress(compressed) == raw)
  }

  @Test
  func testCompressedDatabaseExpansionLimitFailsWithControlledError() throws {
    var db = ITunesDatabase()
    var track = ITDBTrack()
    track.title = String(repeating: "Compressible", count: 2_000)
    db.tracks = [track]
    let raw = ITunesDBWriter().write(db)
    let headerLength = Int(DBBytes.u32(raw, at: 4))
    let compressed = try ITunesCDB.compress(raw)

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ITunesCDB.decompress(
          compressed, maximumExpandedBodySize: raw.count - headerLength - 1)
      }
      if let caughtError {
        guard case ITunesDBError.badHeader(let detail) = caughtError else {
          Issue.record("unexpected error: \(caughtError)")
          return
        }
        #expect(detail.contains("safety limit"))
      }
    }
    #expect(
      try ITunesCDB.decompress(
        compressed, maximumExpandedBodySize: raw.count - headerLength) == raw)
  }

  @Test
  func testProtocolOperationsAcceptNonzeroStartIndexData() throws {
    var db = ITunesDatabase()
    var track = ITDBTrack()
    track.title = "Sliced"
    db.tracks = [track]
    let raw = ITunesDBWriter().write(db)
    let rawSlice = (Data(repeating: 0xee, count: 7) + raw)[7...]
    #expect(rawSlice.startIndex == 7)
    #expect((try ITunesCDB.compress(rawSlice)) == (try ITunesCDB.compress(raw)))

    let compressed = try ITunesCDB.compress(raw)
    let compressedSlice = (Data(repeating: 0xdd, count: 5) + compressed)[5...]
    #expect(try ITunesCDB.decompress(compressedSlice) == raw)

    let guid = try #require(IpodDatabaseSupport.parseGUID("000A27001A2B3C4D"))
    #expect((try Hash58.sign(rawSlice, firewireGUID: guid)) == (try Hash58.sign(raw, firewireGUID: guid)))

    let material = Hash72Material(
      initializationVector: Data((0..<16).map(UInt8.init)),
      randomBytes: Data((40..<52).map(UInt8.init)))
    var signed = raw
    var hashInput = signed
    hashInput.replaceSubrange(24..<32, with: repeatElement(UInt8(0), count: 8))
    hashInput.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))
    hashInput.replaceSubrange(114..<160, with: repeatElement(UInt8(0), count: 46))
    signed.replaceSubrange(
      114..<160,
      with: material.signature(forSHA1: Data(Insecure.SHA1.hash(data: hashInput))))
    let signedSlice = (Data(repeating: 0xcc, count: 9) + signed)[9...]
    #expect(Hash72Material.extract(from: signedSlice) == material)
  }

  @Test
  func testNanoInstallRecoversEveryInterruptedCheckpoint() throws {
    struct SimulatedProcessDeath: Error {}

    for interrupted in Nano5DatabaseWriter.InstallCheckpoint.allCases {
      let root = TestScratch.directory()
      defer { try? FileManager.default.removeItem(at: root) }
      let fs = IpodFileSystem(volumeURL: root)
      try FileManager.default.createDirectory(
        at: fs.sqliteLibraryDirectory, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
      try Data("old directory".utf8).write(
        to: fs.sqliteLibraryDirectory.appendingPathComponent("generation"))
      for name in [
        "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
        "Locations.itdb.cbk",
      ] {
        if name == "Locations.itdb.cbk", interrupted == .directoryInstalled {
          continue
        }
        try Data("old \(name)".utf8).write(
          to: fs.sqliteLibraryDirectory.appendingPathComponent(name))
      }
      var oldDatabase = ITunesDatabase()
      oldDatabase.masterPlaylistName = "old"
      let oldCDB = try ITunesCDB.compress(ITunesDBWriter().write(oldDatabase))
      try oldCDB.write(to: fs.compressedDatabaseURL)
      let stagedDirectory = fs.itunesDir.appendingPathComponent(
        ".nightdrive-itlp-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
      try Data("new directory".utf8).write(
        to: stagedDirectory.appendingPathComponent("generation"))
      for name in [
        "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
        "Locations.itdb.cbk",
      ] {
        try Data("new \(name)".utf8).write(to: stagedDirectory.appendingPathComponent(name))
      }
      let stagedCDB = fs.itunesDir.appendingPathComponent(
        ".nightdrive-cdb-\(UUID().uuidString)")
      let newCDB = try ITunesCDB.compress(ITunesDBWriter().write(ITunesDatabase()))
      try newCDB.write(to: stagedCDB)

      #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.install(
          stagedDirectory: stagedDirectory, stagedCDB: stagedCDB, fileSystem: fs
        ) { checkpoint in
          if checkpoint == interrupted { throw SimulatedProcessDeath() }
        }
      }

      #expect(
        try IpodDatabaseSupport(fileSystem: fs).formatForWriting()
          == .nano5(firewireGUID: Data([0x00, 0x0a, 0x27, 0x00, 0x1a, 0x2b, 0x3c, 0x4d])))
      let committed = interrupted == .committed || interrupted == .backupPointerPromoted
      #expect(
        try String(
          contentsOf: fs.sqliteLibraryDirectory.appendingPathComponent("generation"),
          encoding: .utf8) == (committed ? "new directory" : "old directory"), Comment(rawValue: interrupted.rawValue))
      #expect(
        try Data(contentsOf: fs.compressedDatabaseURL) == (committed ? newCDB : oldCDB),
        Comment(rawValue: interrupted.rawValue))
      if interrupted == .directoryInstalled {
        #expect(
          !(FileManager.default.fileExists(
            atPath:
              fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb.cbk").path)),
          Comment(rawValue: "recovery must accept and faithfully restore a preexisting generation without a CBK"))
      }
      #expect(
        !(FileManager.default.fileExists(
          atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist").path)))
      let leftovers = try FileManager.default.contentsOfDirectory(
        at: fs.itunesDir, includingPropertiesForKeys: nil
      ).filter {
        $0.lastPathComponent.hasPrefix(".nightdrive-nano-")
          && $0.lastPathComponent != ".nightdrive-nano-backup.plist"
      }
      #expect(leftovers.count == (committed ? 2 : 0), Comment(rawValue: interrupted.rawValue))
    }
  }

  @Test
  func testNanoRecoveryRemovesObsoleteBackupAfterPointerPromotion() throws {
    struct SimulatedProcessDeath: Error {}
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(
      at: fs.sqliteLibraryDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
    try Data("original".utf8).write(
      to: fs.sqliteLibraryDirectory.appendingPathComponent("generation"))
    for name in [
      "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
      "Locations.itdb.cbk",
    ] {
      try Data("original \(name)".utf8).write(
        to: fs.sqliteLibraryDirectory.appendingPathComponent(name))
    }
    try ITunesCDB.compress(ITunesDBWriter().write(ITunesDatabase())).write(
      to: fs.compressedDatabaseURL)

    func staged(_ generation: String) throws -> (URL, URL) {
      let directory = fs.itunesDir.appendingPathComponent(
        ".nightdrive-itlp-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(generation.utf8).write(
        to: directory.appendingPathComponent("generation"))
      for name in [
        "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
        "Locations.itdb.cbk",
      ] {
        try Data("\(generation) \(name)".utf8).write(
          to: directory.appendingPathComponent(name))
      }
      let cdb = fs.itunesDir.appendingPathComponent(".nightdrive-cdb-\(UUID().uuidString)")
      var database = ITunesDatabase()
      database.masterPlaylistName = generation
      try ITunesCDB.compress(ITunesDBWriter().write(database)).write(to: cdb)
      return (directory, cdb)
    }

    let first = try staged("first")
    try Nano5DatabaseWriter.install(
      stagedDirectory: first.0, stagedCDB: first.1, fileSystem: fs)
    let oldBackups = try nanoBackupFiles(in: fs.itunesDir)
    #expect(oldBackups.count == 2)

    let second = try staged("second")
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: second.0, stagedCDB: second.1, fileSystem: fs
      ) { checkpoint in
        if checkpoint == .backupPointerPromoted { throw SimulatedProcessDeath() }
      }
    }
    _ = try IpodDatabaseSupport(fileSystem: fs).formatForWriting()

    let currentBackups = try nanoBackupFiles(in: fs.itunesDir)
    #expect(currentBackups.count == 2)
    #expect(Set(oldBackups).isDisjoint(with: currentBackups))
    #expect(
      try String(
        contentsOf: fs.sqliteLibraryDirectory.appendingPathComponent("generation"),
        encoding: .utf8) == "second")

    let corrupt = try staged("corrupt")
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: corrupt.0, stagedCDB: corrupt.1, fileSystem: fs
      ) { checkpoint in
        if checkpoint == .backupPointerPromoted { throw SimulatedProcessDeath() }
      }
    }
    try Data("damaged after commit".utf8).write(to: fs.compressedDatabaseURL)
    _ = try IpodDatabaseSupport(fileSystem: fs).formatForWriting()
    #expect(
      try String(
        contentsOf: fs.sqliteLibraryDirectory.appendingPathComponent("generation"),
        encoding: .utf8) == "second",
      Comment(rawValue: "a committed generation failing its persisted hashes must roll back"))
    #expect(
      Set(try nanoBackupFiles(in: fs.itunesDir)) == Set(currentBackups),
      Comment(rawValue: "rollback after pointer promotion must restore the previous retained-backup pointer"))

    let badCBK = try staged("bad-cbk")
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: badCBK.0, stagedCDB: badCBK.1, fileSystem: fs
      ) { checkpoint in
        if checkpoint == .committed { throw SimulatedProcessDeath() }
      }
    }
    try Data("corrupt cbk".utf8).write(
      to: fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb.cbk"))
    _ = try IpodDatabaseSupport(fileSystem: fs).formatForWriting()
    #expect(
      try String(
        contentsOf: fs.sqliteLibraryDirectory.appendingPathComponent("generation"),
        encoding: .utf8) == "second",
      Comment(rawValue: "a corrupt committed CBK must roll back with the rest of its generation"))

    for recoveryCheckpoint in Nano5DatabaseWriter.RecoveryCheckpoint.allCases {
      let ordinary = try staged("ordinary-\(recoveryCheckpoint.rawValue)")
      #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.install(
          stagedDirectory: ordinary.0, stagedCDB: ordinary.1, fileSystem: fs
        ) { checkpoint in
          if checkpoint == .directoryInstalled { throw SimulatedProcessDeath() }
        }
      }
      #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) { checkpoint in
          if checkpoint == recoveryCheckpoint { throw SimulatedProcessDeath() }
        }
      }
      try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs)
      #expect(
        !(FileManager.default.fileExists(
          atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist").path)),
        Comment(rawValue: recoveryCheckpoint.rawValue))
    }

    for recoveryCheckpoint in Nano5DatabaseWriter.RecoveryCheckpoint.allCases {
      let committed = try staged("committed-\(recoveryCheckpoint.rawValue)")
      #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.install(
          stagedDirectory: committed.0, stagedCDB: committed.1, fileSystem: fs
        ) { checkpoint in
          if checkpoint == .backupPointerPromoted { throw SimulatedProcessDeath() }
        }
      }
      try Data("force committed rollback".utf8).write(to: fs.compressedDatabaseURL)
      #expect(throws: (any Error).self) {
        try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) { checkpoint in
          if checkpoint == recoveryCheckpoint { throw SimulatedProcessDeath() }
        }
      }
      try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs)
      #expect(
        !(FileManager.default.fileExists(
          atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist").path)),
        Comment(rawValue: recoveryCheckpoint.rawValue))
    }
  }

  @Test
  func testNanoRecoveryRejectsCorruptOldGenerationBackup() throws {
    struct SimulatedProcessDeath: Error {}
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(
      at: fs.sqliteLibraryDirectory, withIntermediateDirectories: true)
    for name in [
      "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
      "Locations.itdb.cbk",
    ] {
      try Data("old \(name)".utf8).write(
        to: fs.sqliteLibraryDirectory.appendingPathComponent(name))
    }
    try ITunesCDB.compress(ITunesDBWriter().write(ITunesDatabase())).write(
      to: fs.compressedDatabaseURL)
    let stagedDirectory = fs.itunesDir.appendingPathComponent(
      ".nightdrive-itlp-\(UUID().uuidString)")
    try FileManager.default.copyItem(at: fs.sqliteLibraryDirectory, to: stagedDirectory)
    let stagedCDB = fs.itunesDir.appendingPathComponent(
      ".nightdrive-cdb-\(UUID().uuidString)")
    try ITunesCDB.compress(ITunesDBWriter().write(ITunesDatabase())).write(to: stagedCDB)
    #expect(throws: (any Error).self) {
      try Nano5DatabaseWriter.install(
        stagedDirectory: stagedDirectory, stagedCDB: stagedCDB, fileSystem: fs
      ) { checkpoint in
        if checkpoint == .directoryInstalled { throw SimulatedProcessDeath() }
      }
    }

    let markerURL = fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist")
    let marker = try #require(
      try PropertyListSerialization.propertyList(from: Data(contentsOf: markerURL), format: nil)
        as? [String: Any])
    let identifier = try #require(marker["identifier"] as? String)
    let backupLibrary = fs.itunesDir.appendingPathComponent(
      ".nightdrive-nano-\(identifier)-backup.itlp/Library.itdb")
    try Data("corrupted old backup".utf8).write(to: backupLibrary)

    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(FileManager.default.fileExists(atPath: markerURL.path))
  }

  @Test
  func testNanoRecoveryRejectsMarkerNamingLiveDatabasePaths() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(
      at: fs.sqliteLibraryDirectory, withIntermediateDirectories: true)
    let sentinel = fs.sqliteLibraryDirectory.appendingPathComponent("sentinel")
    try Data("live directory".utf8).write(to: sentinel)
    try Data("live cdb".utf8).write(to: fs.compressedDatabaseURL)
    let marker: [String: Any] = [
      "identifier": UUID().uuidString,
      "phase": "preparing",
      "originalStagedDirectoryName": "iTunes Library.itlp",
      "originalStagedCDBName": "iTunesCDB",
      "sqliteHashes": [String: Data](),
      "cdbHash": Data(),
    ]
    let markerData = try PropertyListSerialization.data(
      fromPropertyList: marker, format: .binary, options: 0)
    try markerData.write(
      to: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist"))

    #expect(throws: (any Error).self) { try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(try Data(contentsOf: sentinel) == Data("live directory".utf8))
    #expect(try Data(contentsOf: fs.compressedDatabaseURL) == Data("live cdb".utf8))
  }

  @Test
  func testHash72SignatureMatchesAESReferenceVector() {
    let material = Hash72Material(
      initializationVector: Data((0..<16).map(UInt8.init)),
      randomBytes: Data((40..<52).map(UInt8.init)))
    let signature = material.signature(forSHA1: Data((20..<40).map(UInt8.init)))

    #expect(
      signature.hex == "010028292a2b2c2d2e2f303132336343e16bb2c0c806013f33c8268cc911483b"
        + "9324ff4dece3456b8aa7b09a9740")
  }

  @Test
  func testHash72MaterialCanBeRecoveredFromSignedDatabase() throws {
    let material = Hash72Material(
      initializationVector: Data((0..<16).map(UInt8.init)),
      randomBytes: Data((40..<52).map(UInt8.init)))
    var database = Data((0..<700).map { UInt8(($0 * 19 + 3) & 0xff) })
    database.replaceSubrange(0..<4, with: Data("mhbd".utf8))
    database.replaceSubrange(114..<160, with: repeatElement(UInt8(0), count: 46))
    var hashInput = database
    hashInput.replaceSubrange(24..<32, with: repeatElement(UInt8(0), count: 8))
    hashInput.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))
    let sha1 = Data(Insecure.SHA1.hash(data: hashInput))
    database.replaceSubrange(114..<160, with: material.signature(forSHA1: sha1))

    #expect(Hash72Material.extract(from: database) == material)
  }

  @Test
  func testHashInfoMustMatchDeviceAndCannotOverrideSignedDatabaseMaterial() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let guid = try #require(IpodDatabaseSupport.parseGUID("000A27001A2B3C4D"))
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
    let authenticated = Hash72Material(
      initializationVector: Data((0..<16).map(UInt8.init)),
      randomBytes: Data((40..<52).map(UInt8.init)))
    let stale = Hash72Material(
      initializationVector: Data((80..<96).map(UInt8.init)),
      randomBytes: Data((100..<112).map(UInt8.init)))
    let signedDatabase = hash72SignedDatabase(material: authenticated)
    let hashInfoURL = fs.controlDir.appendingPathComponent("Device/HashInfo")

    let staleInfo =
      Data("HASHv0".utf8) + Hash72Material.deviceIdentifier(for: guid)
      + stale.randomBytes + stale.initializationVector
    try staleInfo.write(to: hashInfoURL)
    #expect(try Hash72Material.load(from: fs, database: signedDatabase) == authenticated)

    let foreignIdentifier = Data(repeating: 0xee, count: 20)
    let foreignInfo =
      Data("HASHv0".utf8) + foreignIdentifier + stale.randomBytes + stale.initializationVector
    try foreignInfo.write(to: hashInfoURL)
    #expect(try Hash72Material.load(from: fs, database: signedDatabase) == authenticated)
    #expect(throws: (any Error).self) {
      try Hash72Material.load(from: fs, database: ITunesDBWriter().write(ITunesDatabase()))
    }
  }

  @Test
  func testUnknownEmptyDeviceFailsClosed() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)

    do {
      let caughtError = #expect(throws: (any Error).self) { try fs.writeDatabase(ITunesDatabase()) }
      if let caughtError {
        guard case ITunesDBError.unsupportedDevice = caughtError else {
          Issue.record("unexpected error: \(caughtError)")
          return
        }
      }
    }
    #expect(!(FileManager.default.fileExists(atPath: fs.databaseURL.path)))
  }

  @Test
  func testUnknownChecksumSchemeFailsClosedEvenWithHashBytes() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
    var database = ITunesDBWriter().write(ITunesDatabase())
    database[48] = 2
    database[49] = 0
    database[88] = 0xA5
    try database.write(to: fs.databaseURL)

    do {
      let caughtError = #expect(throws: (any Error).self) { try IpodDatabaseSupport(fileSystem: fs).formatForWriting() }
      if let caughtError {
        guard case ITunesDBError.unsupportedDevice = caughtError else {
          Issue.record("unexpected error: \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testKnownLegacyModelMayStartFreshButCannotOverwriteMalformedDatabase() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("ModelNumStr: M9282\n".utf8).write(to: fs.sysInfoURL)

    #expect(try IpodDatabaseSupport(fileSystem: fs).formatForWriting() == .legacy)
    try Data("mhbd".utf8).write(to: fs.databaseURL)
    do {
      let caughtError = #expect(throws: (any Error).self) { try IpodDatabaseSupport(fileSystem: fs).formatForWriting() }
      if let caughtError {
        guard case ITunesDBError.badHeader = caughtError else {
          Issue.record("unexpected error: \(caughtError)")
          return
        }
      }
    }
  }

  @Test
  func testReadOnlyLegacyDatabaseReadDoesNotCreateNanoLock() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    var database = ITunesDatabase()
    database.masterPlaylistName = "Read Only"
    try ITunesDBWriter().write(database).write(to: fs.databaseURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fs.itunesDir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fs.itunesDir.path)
    }

    #expect(try fs.readDatabase().masterPlaylistName == "Read Only")
    #expect(
      !(FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano.lock").path)))
  }

  @Test
  func testLegacyWriteFormatDetectionDoesNotCreateNanoLock() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    try ITunesDBWriter().write(ITunesDatabase()).write(to: fs.databaseURL)

    #expect(try IpodDatabaseSupport(fileSystem: fs).formatForWriting() == .legacy)
    #expect(
      !(FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano.lock").path)))
  }

  @Test
  func testStableNanoReadDoesNotCreateLockOrRequireWriteAccess() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    var database = ITunesDatabase()
    database.masterPlaylistName = "Stable Nano"
    try ITunesCDB.compress(ITunesDBWriter().write(database)).write(
      to: fs.compressedDatabaseURL)
    try Data("interrupted transaction".utf8).write(
      to: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: fs.itunesDir.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: fs.itunesDir.path)
    }

    #expect(try fs.readDatabase().masterPlaylistName == "Stable Nano")
    #expect(
      !(FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano.lock").path)))
  }

  @Test
  func testHash58DeviceIsDetectedAndSignedOnWrite() throws {
    let root = scratch
    let fs = IpodFileSystem(volumeURL: root)
    try FileManager.default.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fs.sysInfoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)

    var existing = ITunesDBWriter().write(ITunesDatabase())
    existing[48] = 1
    existing[88] = 1
    try existing.write(to: fs.databaseURL)
    try fs.writeDatabase(ITunesDatabase())

    let written = try Data(contentsOf: fs.databaseURL)
    #expect(Array(written[48..<50]) == [1, 0])
    #expect(written[88..<108].contains { $0 != 0 })
    #expect(throws: Never.self) { try ITunesDBReader().read(written) }
  }

  @Test
  func testNano5WriteUpdatesCompressedAndSQLiteDatabases() throws {
    let root = scratch
    let fixture = try makeNano5FileSystem(at: root)
    let fs = fixture.fs
    let material = fixture.material
    try FileManager.default.removeItem(
      at: fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb.cbk"))

    var database = ITunesDatabase()
    database.masterPlaylistName = "Nano Test"
    let formats: [(String, Int64)] = [
      ("mp3", 301), ("m4a", 502), ("m4b", 502), ("wav", 0), ("aif", 0), ("aiff", 0),
      ("opus", 0),
    ]
    database.tracks = formats.enumerated().map { index, entry in
      var track = ITDBTrack()
      track.title = entry.0
      track.artist = "Nightdrive"
      track.album = "Fifth Generation"
      track.genre = "Test"
      track.ipodPath = ":iPod_Control:Music:F00:NANO\(index).\(entry.0)"
      track.filetypeMarker = SyncEngine.filetypeMarker(for: entry.0)
      if entry.0 == "opus" { track.type2 = 17 }
      track.sizeBytes = 1234
      track.lengthMS = 5000
      return track
    }
    var markerlessMP3 = ITDBTrack()
    markerlessMP3.title = "markerless-mp3"
    markerlessMP3.ipodPath = ":iPod_Control:Music:F00:IMPORTED.mp3"
    markerlessMP3.filetypeMarker = 0
    markerlessMP3.type2 = 0
    var markerlessAAC = ITDBTrack()
    markerlessAAC.title = "markerless-aac"
    markerlessAAC.ipodPath = ":iPod_Control:Music:F00:IMPORTED.bin"
    markerlessAAC.filetypeMarker = 0
    markerlessAAC.type2 = 0
    database.tracks += [markerlessMP3, markerlessAAC]
    try fs.writeDatabase(database)

    #expect(
      Set(try fs.readDatabase().tracks.compactMap(\.title))
        == Set(formats.map(\.0) + ["markerless-mp3", "markerless-aac"]))
    let cdb = try Data(contentsOf: fs.compressedDatabaseURL)
    #expect(cdb[0xa8] == 1)
    #expect(Array(cdb[48..<50]) == [1, 0])
    #expect(
      try sqliteCount(
        at: fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb"),
        table: "item") == formats.count + 2)
    #expect(
      try sqliteCount(
        at: fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb"),
        table: "location") == formats.count + 2)
    for (extensionName, expected) in formats {
      #expect(
        try sqliteInt(
          at: fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb"),
          query:
            "SELECT a.audio_format FROM avformat_info a JOIN item i ON i.pid = a.item_pid "
            + "WHERE i.title = '\(extensionName)'") == expected, Comment(rawValue: extensionName))
    }
    #expect(
      try sqliteInt(
        at: fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb"),
        query:
          "SELECT a.audio_format FROM avformat_info a JOIN item i ON i.pid = a.item_pid "
          + "WHERE i.title = 'markerless-mp3'") == 301)
    #expect(
      try sqliteInt(
        at: fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb"),
        query:
          "SELECT a.audio_format FROM avformat_info a JOIN item i ON i.pid = a.item_pid "
          + "WHERE i.title = 'markerless-aac'") == 502)
    let cbk = try Data(
      contentsOf: fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb.cbk"))
    #expect(cbk.count > 66)
    #expect(cbk.prefix(46) == material.signature(forSHA1: Data(cbk[46..<66])))
    #expect(
      !(FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist").path)))
    #expect(
      FileManager.default.fileExists(
        atPath: fs.itunesDir.appendingPathComponent(".nightdrive-nano-backup.plist").path))
    let firstBackupFiles = try nanoBackupFiles(in: fs.itunesDir)
    #expect(firstBackupFiles.count == 2)

    let preservedID = Int64(bitPattern: try #require(database.tracks.first).dbid)
    let libraryURL = fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb")
    let dynamicURL = fs.sqliteLibraryDirectory.appendingPathComponent("Dynamic.itdb")
    let locationsURL = fs.sqliteLibraryDirectory.appendingPathComponent("Locations.itdb")
    let previousAlbumID = try sqliteInt(
      at: libraryURL, query: "SELECT album_pid FROM item WHERE pid = \(preservedID)")
    let previousArtistID = try sqliteInt(
      at: libraryURL, query: "SELECT artist_pid FROM item WHERE pid = \(preservedID)")
    let previousComposerID = try sqliteInt(
      at: libraryURL, query: "SELECT composer_pid FROM item WHERE pid = \(preservedID)")
    let foreignAlbumID: Int64 = -9_000_001
    let foreignArtistID: Int64 = -9_000_002
    let foreignComposerID: Int64 = -9_000_003
    try executeSQLite(
      at: libraryURL,
      sql: """
        UPDATE item SET media_kind = 4, remember_bookmark = 1,
          artwork_status = 1, artwork_cache_id = 7788 WHERE pid = \(preservedID);
        UPDATE avformat_info SET gapless_heuristic_info = 91,
          gapless_encoding_delay = 92, gapless_encoding_drain = 93
          WHERE item_pid = \(preservedID);
        INSERT INTO video_info (item_pid) VALUES (\(preservedID));
        INSERT INTO podcast_info (item_pid) VALUES (\(preservedID));
        INSERT INTO avformat_info (
          item_pid, sub_id, audio_format, bit_rate, sample_rate, duration,
          gapless_heuristic_info, gapless_encoding_delay, gapless_encoding_drain,
          gapless_last_frame_resynch, analysis_inhibit_flags, audio_fingerprint,
          volume_normalization_energy
        ) VALUES (\(preservedID), 1, 999, 998, 997, 996, 995, 994, 993, 992, 991, 990, 989);
        INSERT INTO item_to_album (item_pid, album_pid)
          VALUES (\(preservedID), \(foreignAlbumID));
        INSERT INTO item_to_artist (item_pid, artist_pid)
          VALUES (\(preservedID), \(foreignArtistID));
        INSERT INTO item_to_composer (item_pid, composer_pid)
          VALUES (\(preservedID), \(foreignComposerID));
        """)
    try executeSQLite(
      at: locationsURL,
      sql: """
        INSERT INTO location (
          item_pid, sub_id, base_location_id, location_type, location, extension,
          kind_id, date_created, file_size
        ) VALUES (\(preservedID), 1, 9, 8, 'alternate/resource', 7, 6, 5, 4321);
        """)
    try executeSQLite(
      at: dynamicURL,
      sql: """
        UPDATE item_stats SET bookmark_time_ms = 12345,
          bookmark_time_ms_common = 12346 WHERE item_pid = \(preservedID);
        """)

    var mutated = try fs.readDatabase()
    mutated.tracks[0].title = "Edited on nano"
    mutated.tracks[0].artist = "Edited Artist"
    mutated.tracks[0].albumArtist = "Edited Album Artist"
    mutated.tracks[0].album = "Edited Album"
    mutated.tracks[0].genre = "Edited Genre"
    mutated.tracks[0].composer = "Edited Composer"
    mutated.tracks[0].mediaKind = ITDBMediaKind.podcast.rawValue
    mutated.tracks[0].rememberPlaybackPosition = true
    mutated.tracks[0].pregap = 92
    mutated.tracks[0].postgap = 93
    let removedID = Int64(bitPattern: mutated.tracks.remove(at: 1).dbid)
    var added = ITDBTrack()
    added.title = "Added during reconcile"
    added.artist = "New Artist"
    added.album = "New Album"
    added.genre = "New Genre"
    added.composer = "New Composer"
    added.ipodPath = ":iPod_Control:Music:F00:ADDED.mp3"
    added.filetypeMarker = SyncEngine.filetypeMarker(for: "mp3")
    let addedID = Int64(bitPattern: added.dbid)
    mutated.tracks.append(added)
    try fs.writeDatabase(mutated)
    #expect(try sqliteInt(at: libraryURL, query: "SELECT media_kind FROM item WHERE pid = \(preservedID)") == 4)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT remember_bookmark FROM item WHERE pid = \(preservedID)") == 1)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT artwork_cache_id FROM item WHERE pid = \(preservedID)") == 7788)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query:
          "SELECT gapless_encoding_delay FROM avformat_info WHERE item_pid = \(preservedID) "
          + "AND sub_id = 0") == 92)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query:
          "SELECT audio_format FROM avformat_info WHERE item_pid = \(preservedID) "
          + "AND sub_id = 1") == 999)
    #expect(
      try sqliteInt(
        at: locationsURL,
        query:
          "SELECT file_size FROM location WHERE item_pid = \(preservedID) AND sub_id = 1") == 4_321)
    #expect(
      try sqliteInt(
        at: dynamicURL,
        query: "SELECT bookmark_time_ms FROM item_stats WHERE item_pid = \(preservedID)") == 12_345)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM video_info WHERE item_pid = \(preservedID)") == 1)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM podcast_info WHERE item_pid = \(preservedID)") == 1)
    #expect(try sqliteInt(at: libraryURL, query: "SELECT COUNT(*) FROM item WHERE pid = \(removedID)") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT COUNT(*) FROM item i
          JOIN artist ar ON ar.pid = i.artist_pid
          JOIN album al ON al.pid = i.album_pid
          JOIN composer co ON co.pid = i.composer_pid
          JOIN genre_map ge ON ge.id = i.genre_id
          JOIN item_to_album ial ON ial.item_pid = i.pid AND ial.album_pid = i.album_pid
          JOIN item_to_artist iar ON iar.item_pid = i.pid AND iar.artist_pid = i.artist_pid
          JOIN item_to_composer ico ON ico.item_pid = i.pid AND ico.composer_pid = i.composer_pid
          WHERE i.pid = \(preservedID) AND ar.name = 'Edited Artist'
            AND al.name = 'Edited Album' AND al.artist_pid != i.artist_pid
            AND co.name = 'Edited Composer' AND ge.genre = 'Edited Genre'
          """) == 1)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT COUNT(*) FROM item i
          JOIN artist ar ON ar.pid = i.artist_pid
          JOIN album al ON al.pid = i.album_pid
          JOIN composer co ON co.pid = i.composer_pid
          JOIN genre_map ge ON ge.id = i.genre_id
          JOIN item_to_album ial ON ial.item_pid = i.pid AND ial.album_pid = i.album_pid
          JOIN item_to_artist iar ON iar.item_pid = i.pid AND iar.artist_pid = i.artist_pid
          JOIN item_to_composer ico ON ico.item_pid = i.pid AND ico.composer_pid = i.composer_pid
          WHERE i.pid = \(addedID) AND ar.name = 'New Artist'
            AND al.name = 'New Album' AND co.name = 'New Composer' AND ge.genre = 'New Genre'
          """) == 1)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT COUNT(*) FROM item_to_album
          WHERE item_pid = \(preservedID) AND album_pid = \(previousAlbumID)
          """) == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT COUNT(*) FROM item_to_artist
          WHERE item_pid = \(preservedID) AND artist_pid = \(previousArtistID)
          """) == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT COUNT(*) FROM item_to_composer
          WHERE item_pid = \(preservedID) AND composer_pid = \(previousComposerID)
          """) == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: """
          SELECT
            (SELECT COUNT(*) FROM item_to_album
              WHERE item_pid = \(preservedID) AND album_pid = \(foreignAlbumID))
            + (SELECT COUNT(*) FROM item_to_artist
              WHERE item_pid = \(preservedID) AND artist_pid = \(foreignArtistID))
            + (SELECT COUNT(*) FROM item_to_composer
              WHERE item_pid = \(preservedID) AND composer_pid = \(foreignComposerID))
          """) == 3)
    let secondBackupFiles = try nanoBackupFiles(in: fs.itunesDir)
    #expect(secondBackupFiles.count == 2)
    #expect(Set(firstBackupFiles).isDisjoint(with: secondBackupFiles))
  }

  @Test
  func testNano5WriteReconcilesPlaylistContainersAndUIState() throws {
    let root = scratch
    let fs = try makeNano5FileSystem(at: root).fs

    var database = ITunesDatabase()
    var track = ITDBTrack()
    track.title = "Song"
    track.ipodPath = ":iPod_Control:Music:F00:SONG.mp3"
    track.filetypeMarker = SyncEngine.filetypeMarker(for: "mp3")
    database.tracks = [track]
    var playlist = ITDBPlaylist(name: "Doomed", isMaster: false)
    playlist.memberDbids = [track.dbid]
    database.playlists = [playlist]
    try fs.writeDatabase(database)

    let libraryURL = fs.sqliteLibraryDirectory.appendingPathComponent("Library.itdb")
    let dynamicURL = fs.sqliteLibraryDirectory.appendingPathComponent("Dynamic.itdb")
    let playlistPID = Int64(bitPattern: playlist.persistentID)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(playlistPID)") == 1)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM item_to_container WHERE container_pid = \(playlistPID)") == 1)
    #expect(
      try sqliteInt(
        at: dynamicURL,
        query: "SELECT COUNT(*) FROM container_ui WHERE container_pid = \(playlistPID)") == 1)

    var mutated = try fs.readDatabase()
    #expect(mutated.playlists.count == 1)
    mutated.playlists.removeAll { $0.persistentID == playlist.persistentID }
    var created = ITDBPlaylist(name: "Created during reconcile", isMaster: false)
    created.memberDbids = [track.dbid]
    mutated.playlists.append(created)
    try fs.writeDatabase(mutated)
    let createdPID = Int64(bitPattern: created.persistentID)

    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(playlistPID)") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM item_to_container WHERE container_pid = \(playlistPID)") == 0)
    #expect(
      try sqliteInt(
        at: dynamicURL,
        query: "SELECT COUNT(*) FROM container_ui WHERE container_pid = \(playlistPID)") == 0)
    #expect(
      try sqliteInt(
        at: libraryURL, query: "SELECT COUNT(*) FROM container WHERE pid = \(createdPID)") == 1)
    #expect(
      try sqliteInt(
        at: dynamicURL,
        query: "SELECT COUNT(*) FROM container_ui WHERE container_pid = \(createdPID)") == 1)
    #expect(
      try sqliteInt(
        at: libraryURL,
        query: "SELECT COUNT(*) FROM item WHERE pid = \(Int64(bitPattern: track.dbid))") == 1)
  }

  private func hash72SignedDatabase(material: Hash72Material) -> Data {
    var database = ITunesDBWriter().write(ITunesDatabase())
    var hashInput = database
    hashInput.replaceSubrange(24..<32, with: repeatElement(UInt8(0), count: 8))
    hashInput.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))
    hashInput.replaceSubrange(114..<160, with: repeatElement(UInt8(0), count: 46))
    let digest = Data(Insecure.SHA1.hash(data: hashInput))
    database.replaceSubrange(114..<160, with: material.signature(forSHA1: digest))
    return database
  }

  private func nanoBackupFiles(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).filter {
      $0.hasPrefix(".nightdrive-nano-") && $0.contains("-backup.")
        && $0 != ".nightdrive-nano-backup.plist"
    }
  }
}

extension Data {
  fileprivate var hex: String {
    map { String(format: "%02x", $0) }.joined()
  }
}
