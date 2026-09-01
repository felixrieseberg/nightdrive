import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct ShuffleSyncTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture(folderName: "FAKESHUFFLE", modelNumber: "MA564")
  }

  private func makePlan() async throws -> SyncPlan {
    try await makePlan(deviceFamily: .shuffle)
  }

  @Test
  func testITunesSDRoundTrip() throws {
    var loud = ITunesSDFile.entry(forIpodPath: ":iPod_Control:Music:F00:SONG.mp3")
    loud.volume = 250
    let entries = [
      loud,
      ITunesSDFile.entry(forIpodPath: ":iPod_Control:Music:F01:BÉLA.m4a"),
      ITunesSDFile.entry(forIpodPath: ":iPod_Control:Music:F02:BOOK.m4b"),
      ITunesSDFile.entry(forIpodPath: ":iPod_Control:Music:F03:TONE.wav"),
    ]

    let data = ITunesSDFile.write(entries)
    #expect((data.count) == (ITunesSDFile.headerLength + entries.count * ITunesSDFile.entryLength))

    let decoded = try ITunesSDFile.read(data)
    var expected = entries
    expected[0].volume = 200
    #expect((decoded) == (expected))

    #expect((decoded.map(\.filetype)) == ([.mp3, .aac, .aac, .wav]))
    #expect((decoded.map(\.bookmarkable)) == ([false, false, true, false]))
    #expect((decoded.map(\.shuffleable)) == ([true, true, false, true]))

    let firstPathBytes = data.subdata(
      in: (ITunesSDFile.headerLength + 33)..<(ITunesSDFile.headerLength + 33 + 46))
    #expect((String(data: firstPathBytes, encoding: .utf16LittleEndian)) == ("/iPod_Control/Music/F00"))
  }

  @Test
  func testITunesSDRejectsCorruptData() {
    #expect(throws: (any Error).self) { try ITunesSDFile.read(Data([1, 2, 3])) }

    var badMagic = ITunesSDFile.write([ITunesSDFile.entry(forIpodPath: ":A.mp3")])
    badMagic[4] = 0x42
    #expect(throws: (any Error).self) { try ITunesSDFile.read(badMagic) }

    let truncated = ITunesSDFile.write([ITunesSDFile.entry(forIpodPath: ":A.mp3")])
      .dropLast(10)
    #expect(throws: (any Error).self) { try ITunesSDFile.read(Data(truncated)) }
  }

  @Test(arguments: ["M9724", "MA133LL", "MA564", "MB228ZP"])
  func testShuffleFamilyIsDetectedFromModelNumber(_ modelNumber: String) {
    #expect(IpodDeviceFamily(modelNumber: modelNumber) == .shuffle)
    #expect(IpodDeviceFamily.shuffle.playsAAC)
    #expect(fs.deviceFamily() == .shuffle)
  }

  @Test
  func testShuffleDeliveryAcceptsMP3AndAACButTranscodesAIFF() {
    func track(_ name: String) -> LibraryTrack {
      LibraryTrack(
        url: URL(fileURLWithPath: "/Music/\(name)"), title: name, artist: "A", album: "L", genre: "G", trackNumber: 1,
        trackCount: 1, discNumber: 1, year: 2026, durationMS: 1_000, sizeBytes: 1_000, bitrate: 256, samplerate: 44_100)
    }
    #expect((track("Song.mp3").deviceDelivery(for: .shuffle)) == (.direct))
    #expect((track("Song.m4a").deviceDelivery(for: .shuffle)) == (.direct))
    #expect((track("Song.wav").deviceDelivery(for: .shuffle)) == (.direct))
    for name in ["Song.aiff", "Song.aif", "Song.flac"] {
      guard case .transcode = track(name).deviceDelivery(for: .shuffle) else {
        Issue.record("\(name) should transcode for a shuffle")
        return
      }
    }
  }

  // MARK: - shuffle sync

  @Test
  func testShuffleRepairReplacesBackupBeforeInstallingNewDatabase() throws {
    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])

    try fs.writeShuffleDatabase(replacement)

    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))
    #expect(fs.shuffleDatabaseMatches(replacement))
  }

  @Test
  func testShuffleRepairStagingRemovalFailurePreservesBothGenerations() throws {
    struct InjectedFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    let staleStaging = Data("abandoned staged backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    try staleStaging.write(to: fs.shuffleDatabaseBackupStagingURL)
    var copied = false

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"]),
          removeStagedBackup: { _ in throw InjectedFailure() },
          copyBackup: { _, _ in copied = true },
          installBackup: ShuffleDatabaseWriter.installStagedFile)
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect(!(copied))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (live))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (staleBackup))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupStagingURL)) == (staleStaging))
  }

  @Test
  func testShuffleRepairRemovesStaleStagingWhenLiveDatabaseIsMissing() throws {
    let staleBackup = Data("stale iTunesSD backup".utf8)
    let staleStaging = Data("abandoned staged backup".utf8)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    try staleStaging.write(to: fs.shuffleDatabaseBackupStagingURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])

    try fs.writeShuffleDatabase(replacement)

    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (staleBackup))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))
  }

  @Test
  func testShuffleRepairPartialBackupCopyFailurePreservesBothGenerations() throws {
    struct InjectedFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    let partial = Data("partial new backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    var installed = false

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"]),
          removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
          copyBackup: { _, staged in
            try partial.write(to: staged)
            throw InjectedFailure()
          },
          installBackup: { _, _ in installed = true })
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect(!(installed))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (live))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (staleBackup))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupStagingURL)) == (partial))
  }

  @Test
  func testShuffleRepairBackupInstallFailurePreservesBothGenerationsAndCanRetry() throws {
    struct InjectedFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          replacement,
          removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
          copyBackup: { try FileManager.default.copyItem(at: $0, to: $1) },
          installBackup: { _, _ in throw InjectedFailure() })
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (live))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (staleBackup))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupStagingURL)) == (live))

    try fs.writeShuffleDatabase(replacement)

    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))
  }

  @Test
  func testShuffleRepairLateBackupInstallFailureLeavesValidGenerationAndCanRetry() throws {
    struct InjectedFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          replacement,
          removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
          copyBackup: { try FileManager.default.copyItem(at: $0, to: $1) },
          installBackup: { staged, backup in
            try ShuffleDatabaseWriter.installStagedFile(staged, backup)
            throw InjectedFailure()
          })
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (live))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))

    try fs.writeShuffleDatabase(replacement)

    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))
  }

  @Test
  func testShuffleRepairDirectorySyncFailureDoesNotPublishLiveAndCanRetry() throws {
    struct InjectedFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    let staleBackup = Data("stale iTunesSD backup".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    try staleBackup.write(to: fs.shuffleDatabaseBackupURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])
    var wroteLive = false

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          replacement,
          removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
          copyBackup: { source, staged in
            try DurableIO.write(Data(contentsOf: source, options: .mappedIfSafe), to: staged)
          },
          installBackup: ShuffleDatabaseWriter.installStagedFile,
          synchronizeDirectory: { _ in throw InjectedFailure() },
          writeLive: { _, _ in wroteLive = true })
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect(!(wroteLive))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (live))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))

    try fs.writeShuffleDatabase(replacement)

    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
    #expect(!(FileManager.default.fileExists(atPath: fs.shuffleDatabaseBackupStagingURL.path)))
  }

  @Test
  func testShuffleRepairReconcilesLiveInstalledBeforeWriterThrows() throws {
    struct InjectedLateWriteFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])
    var synchronizationCount = 0

    try fs.writeShuffleDatabase(
      replacement,
      removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
      copyBackup: { source, staged in
        try DurableIO.write(Data(contentsOf: source, options: .mappedIfSafe), to: staged)
      },
      installBackup: ShuffleDatabaseWriter.installStagedFile,
      writeLive: { data, destination in
        try data.write(to: destination, options: .atomic)
        throw InjectedLateWriteFailure()
      },
      synchronizeLive: { url in
        synchronizationCount += 1
        try DurableIO.synchronizeFileAndParent(at: url)
      })

    #expect((synchronizationCount) == (1))
    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
  }

  @Test
  func testShuffleRepairLateLiveSyncFailureRetriesWithoutRotatingBackup() throws {
    struct InjectedLateWriteFailure: Error {}
    struct InjectedLiveSyncFailure: Error {}

    let live = Data("current iTunesSD".utf8)
    try live.write(to: fs.shuffleDatabaseURL)
    let replacement = shuffleDatabase(paths: [":iPod_Control:Music:F00:NEW.mp3"])

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeShuffleDatabase(
          replacement,
          removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
          copyBackup: { source, staged in
            try DurableIO.write(Data(contentsOf: source, options: .mappedIfSafe), to: staged)
          },
          installBackup: ShuffleDatabaseWriter.installStagedFile,
          writeLive: { data, destination in
            try data.write(to: destination, options: .atomic)
            throw InjectedLateWriteFailure()
          },
          synchronizeLive: { _ in throw InjectedLiveSyncFailure() })
      }
      if let caughtError {
        #expect(caughtError is InjectedLiveSyncFailure)
      }
    }
    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))

    var rotatedBackup = false
    var rewroteLive = false
    try fs.writeShuffleDatabase(
      replacement,
      removeStagedBackup: { try FileManager.default.removeItem(at: $0) },
      copyBackup: { _, _ in rotatedBackup = true },
      installBackup: { _, _ in rotatedBackup = true },
      writeLive: { _, _ in rewroteLive = true },
      synchronizeLive: { try DurableIO.synchronizeFileAndParent(at: $0) })

    #expect(!(rotatedBackup))
    #expect(!(rewroteLive))
    #expect(fs.shuffleDatabaseMatches(replacement))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (live))
  }

  @Test
  func testShuffleDatabaseWriteRestoresOldPairWhenSecondInstallFails() throws {
    struct InjectedFailure: Error {}

    var oldDatabase = ITunesDatabase()
    var first = ITDBTrack()
    first.dbid = 1
    first.ipodPath = ":iPod_Control:Music:F00:ONE.mp3"
    oldDatabase.tracks = [first]
    try fs.writeDatabase(oldDatabase)
    let oldDatabaseData = try Data(contentsOf: fs.databaseURL)
    let oldShuffleData = try Data(contentsOf: fs.shuffleDatabaseURL)

    var newDatabase = oldDatabase
    var second = ITDBTrack()
    second.dbid = 2
    second.ipodPath = ":iPod_Control:Music:F00:TWO.mp3"
    newDatabase.tracks.append(second)

    var installationCount = 0
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try fs.writeDatabase(
          newDatabase,
          shuffleFileInstaller: { staged, live in
            installationCount += 1
            if live.standardizedFileURL == self.fs.shuffleDatabaseURL.standardizedFileURL {
              throw InjectedFailure()
            }
            let data = try Data(contentsOf: staged)
            try data.write(to: live, options: .atomic)
          })
      }
      if let caughtError {
        #expect(caughtError is InjectedFailure)
      }
    }

    #expect((installationCount) == (2))
    #expect((try Data(contentsOf: fs.databaseURL)) == (oldDatabaseData))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (oldShuffleData))
    let recovered = try fs.readDatabase()
    #expect((recovered.tracks.map(\.dbid)) == ([first.dbid]))
    #expect(fs.shuffleDatabaseMatches(recovered))
    #expect(!(ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs)))
  }

  @Test
  func testShuffleDatabaseReadRecoversEveryInterruptedInstallCheckpoint() throws {
    struct SimulatedProcessExit: Error {}

    var oldDatabase = ITunesDatabase()
    var first = ITDBTrack()
    first.dbid = 1
    first.ipodPath = ":iPod_Control:Music:F00:ONE.mp3"
    oldDatabase.tracks = [first]
    var newDatabase = oldDatabase
    var second = ITDBTrack()
    second.dbid = 2
    second.ipodPath = ":iPod_Control:Music:F00:TWO.mp3"
    newDatabase.tracks.append(second)
    let newDatabaseData = ITunesDBWriter().write(newDatabase)
    let newShuffleData = ITunesSDFile.write(
      newDatabase.tracks.compactMap { track in
        track.ipodPath.map(ITunesSDFile.entry(forIpodPath:))
      })

    for interruptedAt in ShuffleDatabaseWriter.InstallCheckpoint.allCases {
      try fs.writeDatabase(oldDatabase)
      let oldDatabaseData = try Data(contentsOf: fs.databaseURL)
      let oldShuffleData = try Data(contentsOf: fs.shuffleDatabaseURL)

      do {
        let caughtError = #expect(throws: (any Error).self) {
          try ShuffleDatabaseWriter.install(
            databaseData: newDatabaseData,
            shuffleData: newShuffleData,
            fileSystem: fs,
            after: { checkpoint in
              if checkpoint == interruptedAt { throw SimulatedProcessExit() }
            })
        }
        if let caughtError {
          #expect(caughtError is SimulatedProcessExit)
        }
      }
      #expect(
        ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs),
        Comment(rawValue: "missing recovery marker after \(interruptedAt)"))

      let recovered = try fs.readDatabase()
      let committed = interruptedAt == .shuffleDatabaseInstalled
      #expect(
        (try Data(contentsOf: fs.databaseURL)) == (committed ? newDatabaseData : oldDatabaseData),
        Comment(rawValue: "wrong iTunesDB generation after \(interruptedAt)"))
      #expect(
        (try Data(contentsOf: fs.shuffleDatabaseURL)) == (committed ? newShuffleData : oldShuffleData),
        Comment(rawValue: "wrong iTunesSD generation after \(interruptedAt)"))
      #expect((recovered.tracks.map(\.dbid)) == (committed ? [1, 2] : [first.dbid]))
      #expect(fs.shuffleDatabaseMatches(recovered))
      #expect(!(ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs)))
    }
  }

  @Test
  func testShuffleDatabaseRecoveryPreservesAnUnrelatedLiveGeneration() throws {
    struct SimulatedProcessExit: Error {}

    var oldDatabase = ITunesDatabase()
    var oldTrack = ITDBTrack()
    oldTrack.dbid = 1
    oldTrack.ipodPath = ":iPod_Control:Music:F00:OLD.mp3"
    oldDatabase.tracks = [oldTrack]
    try fs.writeDatabase(oldDatabase)

    var newDatabase = oldDatabase
    var newTrack = ITDBTrack()
    newTrack.dbid = 2
    newTrack.ipodPath = ":iPod_Control:Music:F00:NEW.mp3"
    newDatabase.tracks.append(newTrack)
    let newDatabaseData = ITunesDBWriter().write(newDatabase)
    let newShuffleData = ITunesSDFile.write(
      newDatabase.tracks.compactMap { track in
        track.ipodPath.map(ITunesSDFile.entry(forIpodPath:))
      })

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ShuffleDatabaseWriter.install(
          databaseData: newDatabaseData,
          shuffleData: newShuffleData,
          fileSystem: fs,
          after: { checkpoint in
            if checkpoint == .databaseInstalled { throw SimulatedProcessExit() }
          })
      }
      if let caughtError {
        #expect(caughtError is SimulatedProcessExit)
      }
    }

    let databaseBeforeRecovery = try Data(contentsOf: fs.databaseURL)
    let unrelatedShuffleData = Data("written by another media manager".utf8)
    try unrelatedShuffleData.write(to: fs.shuffleDatabaseURL, options: .atomic)

    #expect(throws: (any Error).self) { try ShuffleDatabaseWriter.recoverIfNeeded(fileSystem: fs) }
    #expect(
      (try Data(contentsOf: fs.databaseURL)) == (databaseBeforeRecovery),
      Comment(rawValue: "recovery must not roll back one file before validating the whole live pair"))
    #expect(
      (try Data(contentsOf: fs.shuffleDatabaseURL)) == (unrelatedShuffleData),
      Comment(rawValue: "recovery must preserve an unrelated live write"))
    #expect(ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs))
  }

  @Test
  func testShuffleSyncWritesITunesSDAndSkipsScreenPassesIdempotently() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try writeLibraryMP3(filename: "two.mp3", title: "Two")

    let result = try await runSync(try await makePlan())
    #expect((result.copiedToDevice) == (2))
    #expect((result.failures) == ([]))
    #expect(!(result.syncedPlaylists), Comment(rawValue: "playlist reconciliation must skip on a shuffle"))
    #expect((result.artworkImagesWritten) == (0), Comment(rawValue: "artwork must skip on a shuffle"))
    #expect(result.onTheGoImports.isEmpty)
    #expect(
      !(FileManager.default.fileExists(atPath: fs.artworkDBURL.path)),
      Comment(rawValue: "no ArtworkDB may appear on a shuffle"))

    let db = try fs.readDatabase()
    let entries = try ITunesSDFile.read(Data(contentsOf: fs.shuffleDatabaseURL))
    #expect((entries.map(\.ipodPath)) == (db.tracks.map { $0.ipodPath ?? "?" }))
    #expect((entries.count) == (2))

    let dbBefore = try Data(contentsOf: fs.databaseURL)
    let sdBefore = try Data(contentsOf: fs.shuffleDatabaseURL)
    let plan2 = try await makePlan()
    #expect(plan2.isEmpty, Comment(rawValue: "second plan must be empty: \(plan2)"))
    _ = try await runSync(plan2)
    #expect((try Data(contentsOf: fs.databaseURL)) == (dbBefore))
    #expect((try Data(contentsOf: fs.shuffleDatabaseURL)) == (sdBefore))

    try Data("garbage".utf8).write(to: fs.shuffleDatabaseURL)
    try writeLibraryMP3(filename: "three.mp3", title: "Three")
    _ = try await runSync(try await makePlan())
    #expect((try ITunesSDFile.read(Data(contentsOf: fs.shuffleDatabaseURL)).count) == (3))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (Data("garbage".utf8)))
  }

  @Test
  func testANoChangeSyncRestoresTheShufflePlayOrderFile() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try writeLibraryMP3(filename: "two.mp3", title: "Two")
    _ = try await runSync(try await makePlan())

    try FileManager.default.removeItem(at: fs.shuffleDatabaseURL)
    let emptyPlan = try await makePlan()
    #expect(emptyPlan.isEmpty, Comment(rawValue: "nothing to sync: \(emptyPlan)"))
    _ = try await runSync(emptyPlan)
    #expect(
      (try ITunesSDFile.read(Data(contentsOf: fs.shuffleDatabaseURL)).count) == (2),
      Comment(rawValue: "a no-change sync must regenerate a missing iTunesSD"))

    try Data("junk".utf8).write(to: fs.shuffleDatabaseURL)
    _ = try await runSync(try await makePlan())
    #expect((try ITunesSDFile.read(Data(contentsOf: fs.shuffleDatabaseURL)).count) == (2))
    #expect((try Data(contentsOf: fs.shuffleDatabaseBackupURL)) == (Data("junk".utf8)))

    try ITunesSDFile.write([ITunesSDFile.entry(forIpodPath: ":STALE.mp3")])
      .write(to: fs.shuffleDatabaseURL)
    _ = try await runSync(try await makePlan())
    let restored = try ITunesSDFile.read(Data(contentsOf: fs.shuffleDatabaseURL))
    #expect((restored.count) == (2))
    #expect(!(restored.contains { $0.ipodPath == ":STALE.mp3" }))

    let before = try #require(
      FileManager.default.attributesOfItem(
        atPath: fs.shuffleDatabaseURL.path)[.modificationDate] as? Date)
    _ = try await runSync(try await makePlan())
    let after = try #require(
      FileManager.default.attributesOfItem(
        atPath: fs.shuffleDatabaseURL.path)[.modificationDate] as? Date)
    #expect((before) == (after), Comment(rawValue: "a valid iTunesSD must not be rewritten"))
  }

  @Test
  func testSuffixedRegionalModelNumbersSyncAndRepair() async throws {
    try Data("ModelNumStr: xMA564LL/A\n".utf8).write(to: fs.sysInfoURL)
    #expect((fs.modelNumber()) == ("MA564"))
    #expect((fs.deviceFamily()) == (.shuffle))

    try writeLibraryMP3(filename: "one.mp3", title: "One")
    _ = try await runSync(try await makePlan())
    #expect((try fs.readDatabase().tracks.count) == (1))

    try Data(repeating: 0xDE, count: 4_096).write(to: fs.databaseURL)
    try? FileManager.default.removeItem(at: fs.databaseBackupURL)
    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
    #expect((outcome.source) == (.filesOnly))
    #expect((outcome.tracksRecovered) == (1))
  }

  @Test
  func testRepairRebuildsFromFilesWhenDatabaseIsMangled() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try writeLibraryMP3(filename: "two.mp3", title: "Two")
    _ = try await runSync(try await makePlan())

    try Data(repeating: 0xDE, count: 4_096).write(to: fs.databaseURL)
    try? FileManager.default.removeItem(at: fs.databaseBackupURL)

    #expect(throws: (any Error).self) { try fs.readDatabase() }
    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.source) == (.filesOnly))
    #expect((outcome.tracksRecovered) == (2))
    #expect((outcome.tracksKept) == (0))
    #expect((outcome.tracksDropped) == (0))
    let repaired = try fs.readDatabase()
    #expect((Set(repaired.tracks.compactMap(\.title))) == (["One", "Two"]))
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    #expect((try Data(contentsOf: quarantine)) == (Data(repeating: 0xDE, count: 4_096)))
  }

  @Test
  func testRepairLeavesDeviceArtifactsUntouchedWhenMusicRootEnumerationFails() async throws {
    var access = DatabaseRepair.AudioFileAccess.live
    let liveContents = access.contentsOfDirectory
    let musicPath = fs.musicDir.path
    access.contentsOfDirectory = { url in
      if url.path == musicPath { throw InjectedRepairFileAccessFailure() }
      return try liveContents(url)
    }

    try await assertRepairFileAccessFailureIsNonMutating(access)
  }

  @Test
  func testRepairLeavesDeviceArtifactsUntouchedWhenFolderEnumerationFails() async throws {
    var access = DatabaseRepair.AudioFileAccess.live
    let liveContents = access.contentsOfDirectory
    access.contentsOfDirectory = { url in
      if url.lastPathComponent.range(of: #"^F\d\d$"#, options: .regularExpression) != nil {
        throw InjectedRepairFileAccessFailure()
      }
      return try liveContents(url)
    }

    try await assertRepairFileAccessFailureIsNonMutating(access)
  }

  @Test
  func testRepairLeavesDeviceArtifactsUntouchedWhenFolderResourceReadFails() async throws {
    var access = DatabaseRepair.AudioFileAccess.live
    let liveItemInfo = access.itemInfo
    access.itemInfo = { url in
      if url.lastPathComponent.range(of: #"^F\d\d$"#, options: .regularExpression) != nil {
        throw InjectedRepairFileAccessFailure()
      }
      return try liveItemInfo(url)
    }

    try await assertRepairFileAccessFailureIsNonMutating(access)
  }

  @Test
  func testRepairLeavesDeviceArtifactsUntouchedWhenFileResourceReadFails() async throws {
    var access = DatabaseRepair.AudioFileAccess.live
    let liveItemInfo = access.itemInfo
    access.itemInfo = { url in
      if !url.pathExtension.isEmpty { throw InjectedRepairFileAccessFailure() }
      return try liveItemInfo(url)
    }

    try await assertRepairFileAccessFailureIsNonMutating(access)
  }

  @Test
  func testRepairDoesNotCreateAnAbsentMusicTree() async throws {
    try fs.writeDatabase(ITunesDatabase())
    #expect(!(FileManager.default.fileExists(atPath: fs.musicDir.path)))

    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.tracksKept) == (0))
    #expect((outcome.tracksRecovered) == (0))
    #expect(
      !(FileManager.default.fileExists(atPath: fs.musicDir.path)),
      Comment(rawValue: "read-only repair enumeration must not create Music or FNN directories"))
  }

  @Test
  func testRepairPreservesAPartialMusicTreeWithoutCreatingDefaultFolders() async throws {
    let folder = fs.musicDir.appendingPathComponent("F07", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = MP3Builder.build(
      tags: .init(
        title: "Stray", artist: "Artist", album: "Album", genre: "Rock",
        trackNumber: 1, year: 2004),
      seconds: 2)
    let audioURL = folder.appendingPathComponent("ONLY.mp3")
    try audio.write(to: audioURL)
    try fs.writeDatabase(ITunesDatabase())

    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.tracksRecovered) == (1))
    #expect((try Data(contentsOf: audioURL)) == (audio))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.musicDir.path)) == (["F07"]),
      Comment(rawValue: "repair must enumerate the existing layout without creating F00-F19"))
  }

  @Test
  func testRepairIgnoresMusicFoldersWithUnicodeDigits() async throws {
    let folder = fs.musicDir.appendingPathComponent("F٠٠", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let audio = MP3Builder.build(
      tags: .init(
        title: "Stray", artist: "Artist", album: "Album", genre: "Rock",
        trackNumber: 1, year: 2004),
      seconds: 2)
    let audioURL = folder.appendingPathComponent("ONLY.mp3")
    try audio.write(to: audioURL)
    try fs.writeDatabase(ITunesDatabase())

    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.tracksRecovered) == (0))
    #expect((try Data(contentsOf: audioURL)) == (audio))
  }

  @Test
  func testRepairRejectsASymlinkedMusicFolderWithoutChangingArtifacts() async throws {
    let realFolder = scratch.appendingPathComponent("real-F00", isDirectory: true)
    try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: fs.musicDir.appendingPathComponent("F00"), withDestinationURL: realFolder)
    try fs.writeDatabase(ITunesDatabase())
    let before = try deviceArtifactSnapshot()

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected symlinked FNN rejection")
    } catch {
      guard case ITunesDBError.notFound = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try deviceArtifactSnapshot()) == (before))
  }

  @Test
  func testRepairEnumerationFailureDoesNotResolvePendingShuffleRecovery() async throws {
    struct SimulatedProcessExit: Error {}

    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    var oldDatabase = ITunesDatabase()
    oldDatabase.tracks = [try putTrackOnIpod(title: "One", artist: "Artist")]
    try fs.writeDatabase(oldDatabase)
    var newDatabase = oldDatabase
    var added = ITDBTrack()
    added.dbid = 99
    added.ipodPath = ":iPod_Control:Music:F00:MISSING.mp3"
    newDatabase.tracks.append(added)
    let newDatabaseData = ITunesDBWriter().write(newDatabase)
    let newShuffleData = ITunesSDFile.write(
      newDatabase.tracks.compactMap { track in
        track.ipodPath.map(ITunesSDFile.entry(forIpodPath:))
      })
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try ShuffleDatabaseWriter.install(
          databaseData: newDatabaseData, shuffleData: newShuffleData, fileSystem: fs,
          after: { checkpoint in
            if checkpoint == .databaseInstalled { throw SimulatedProcessExit() }
          })
      }
      if let caughtError {
        #expect(caughtError is SimulatedProcessExit)
      }
    }
    #expect(ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs))
    let before = try deviceArtifactSnapshot()

    var access = DatabaseRepair.AudioFileAccess.live
    let liveContents = access.contentsOfDirectory
    let musicPath = fs.musicDir.path
    access.contentsOfDirectory = { url in
      if url.path == musicPath { throw InjectedRepairFileAccessFailure() }
      return try liveContents(url)
    }
    do {
      _ = try await DatabaseRepair.rebuild(
        deviceVolume: ipodDir,
        databaseWriter: { fileSystem, database, format in
          try fileSystem.writeDatabase(database, preflightedFormat: format)
        },
        audioFileAccess: access)
      Issue.record("expected injected file inspection failure")
    } catch {
      #expect(error is InjectedRepairFileAccessFailure, Comment(rawValue: "unexpected error: \(error)"))
    }

    #expect(
      ShuffleDatabaseWriter.hasPendingTransaction(fileSystem: fs),
      Comment(rawValue: "enumeration failure must leave pending recovery untouched"))
    #expect((try deviceArtifactSnapshot()) == (before))
  }

  @Test
  func testRepairPreflightLeavesFilesUntouchedWhenEmptyFormatIsUnknown() async throws {
    try setModelNumber("UNKNOWN")
    let live = Data("unreadable live database".utf8)
    let backup = Data("unreadable backup database".utf8)
    let priorQuarantine = Data("prior forensic copy".utf8)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try priorQuarantine.write(to: quarantine)

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected unsupported device")
    } catch {
      guard case ITunesDBError.unsupportedDevice = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.itunesDir.path)
        .filter { $0.hasPrefix("iTunesDB.corrupt") }) == (["iTunesDB.corrupt"]))
  }

  @Test
  func testRepairPreflightLeavesFilesUntouchedForUnsupportedBackupScheme() async throws {
    let live = Data("unreadable live database".utf8)
    var backup = ITunesDBWriter().write(ITunesDatabase())
    backup[48] = 2
    backup[49] = 0
    let priorQuarantine = Data("prior forensic copy".utf8)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try priorQuarantine.write(to: quarantine)

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected unsupported device")
    } catch {
      guard case ITunesDBError.unsupportedDevice = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.itunesDir.path)
        .filter { $0.hasPrefix("iTunesDB.corrupt") }) == (["iTunesDB.corrupt"]))
  }

  @Test
  func testRepairPreflightLeavesBackupSourceUntouchedForIncompleteNano() async throws {
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
    let live = Data("unreadable live database".utf8)
    let backup = ITunesDBWriter().write(ITunesDatabase())
    let compressed = Data("incomplete nano database".utf8)
    let priorQuarantine = Data("prior forensic copy".utf8)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try compressed.write(to: fs.compressedDatabaseURL)
    try priorQuarantine.write(to: quarantine)

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected incomplete nano rejection")
    } catch {
      guard case ITunesDBError.unsupportedDevice = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: fs.compressedDatabaseURL)) == (compressed))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.itunesDir.path)
        .filter { $0.hasPrefix("iTunesDB.corrupt") }) == (["iTunesDB.corrupt"]))
  }

  @Test
  func testRepairPreflightLeavesBackupSourceUntouchedForMalformedNanoRecovery() async throws {
    try Data("FirewireGuid: 0x000A27001A2B3C4D\n".utf8).write(to: fs.sysInfoURL)
    let live = Data("unreadable live database".utf8)
    let backup = ITunesDBWriter().write(ITunesDatabase())
    let marker = Data("malformed nano transaction".utf8)
    let priorQuarantine = Data("prior forensic copy".utf8)
    let markerURL = fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist")
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try marker.write(to: markerURL)
    try priorQuarantine.write(to: quarantine)

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected malformed nano recovery rejection")
    } catch {
      guard case ITunesDBError.badHeader = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: markerURL)) == (marker))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.itunesDir.path)
        .filter { $0.hasPrefix("iTunesDB.corrupt") }) == (["iTunesDB.corrupt"]))
  }

  @Test
  func testRepairChecksNanoIdentityBeforeRecoveryCanMutate() async throws {
    let live = Data("unreadable live database".utf8)
    let backup = ITunesDBWriter().write(ITunesDatabase())
    let marker = Data("malformed nano transaction".utf8)
    let markerURL = fs.itunesDir.appendingPathComponent(".nightdrive-nano-install.plist")
    let lockURL = fs.itunesDir.appendingPathComponent(".nightdrive-nano.lock")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try marker.write(to: markerURL)

    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)
      Issue.record("expected missing identity rejection")
    } catch {
      guard case ITunesDBError.unsupportedDevice = error else {
        Issue.record("unexpected error: \(error)")
        return
      }
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: markerURL)) == (marker))
    #expect(!(FileManager.default.fileExists(atPath: lockURL.path)))
  }

  @Test
  func testRepairRestoresBackupSourceLiveDatabaseWhenWriteFails() async throws {
    struct InjectedWriteFailure: Error {}

    let live = Data("unreadable live database".utf8)
    let backup = ITunesDBWriter().write(ITunesDatabase())
    let priorQuarantine = Data("prior forensic copy".utf8)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    try priorQuarantine.write(to: quarantine)

    do {
      _ = try await DatabaseRepair.rebuild(
        deviceVolume: ipodDir,
        databaseWriter: { fileSystem, _, _ in
          try Data("partial replacement".utf8).write(to: fileSystem.databaseURL)
          throw InjectedWriteFailure()
        })
      Issue.record("expected injected write failure")
    } catch {
      #expect(error is InjectedWriteFailure, Comment(rawValue: "unexpected error: \(error)"))
    }

    #expect((try Data(contentsOf: fs.databaseURL)) == (live))
    #expect((try Data(contentsOf: fs.databaseBackupURL)) == (backup))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    #expect(
      (try FileManager.default.contentsOfDirectory(atPath: fs.itunesDir.path)
        .filter { $0.hasPrefix("iTunesDB.corrupt") }) == (["iTunesDB.corrupt"]))
  }

  @Test
  func testRepairReportsWriteAndRollbackFailures() async throws {
    struct InjectedWriteFailure: Error {}

    let live = Data("unreadable live database".utf8)
    let backup = ITunesDBWriter().write(ITunesDatabase())
    try live.write(to: fs.databaseURL)
    try backup.write(to: fs.databaseBackupURL)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")

    do {
      _ = try await DatabaseRepair.rebuild(
        deviceVolume: ipodDir,
        databaseWriter: { _, _, _ in
          try FileManager.default.removeItem(at: quarantine)
          throw InjectedWriteFailure()
        })
      Issue.record("expected write and rollback failures")
    } catch {
      guard
        case .rollbackFailed(let operation, let rollback, let rollbackSource) =
          error as? DatabaseRepairError
      else {
        Issue.record("unexpected error: \(error)")
        return
      }
      #expect(operation is InjectedWriteFailure)
      #expect((rollbackSource) == (quarantine))
      #expect(((rollback as NSError).code) == (NSFileNoSuchFileError))
    }
  }

  @Test
  func testSuccessfulRepairPreservesAnExistingQuarantine() async throws {
    let live = Data("new corrupt database".utf8)
    let priorQuarantine = Data("prior forensic copy".utf8)
    let quarantine = fs.itunesDir.appendingPathComponent("iTunesDB.corrupt")
    try live.write(to: fs.databaseURL)
    try? FileManager.default.removeItem(at: fs.databaseBackupURL)
    try priorQuarantine.write(to: quarantine)

    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.source) == (.filesOnly))
    #expect((try Data(contentsOf: quarantine)) == (priorQuarantine))
    let quarantines = try FileManager.default.contentsOfDirectory(
      at: fs.itunesDir, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.hasPrefix("iTunesDB.corrupt-") }
    #expect((quarantines.count) == (1))
    #expect((try Data(contentsOf: #require(quarantines.first))) == (live))
    #expect(throws: Never.self) { try fs.readDatabase() }
  }

  @Test
  func testRepairDropsGhostRowsAndAdoptsStrayFiles() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try writeLibraryMP3(filename: "two.mp3", title: "Two")
    _ = try await runSync(try await makePlan())

    var db = try fs.readDatabase()
    let ghost = try #require(db.tracks.first { $0.title == "One" })
    let ghostURL = try fs.validatedMusicFileURL(forIpodPath: #require(ghost.ipodPath))
    try FileManager.default.removeItem(at: ghostURL)
    let strayData = MP3Builder.build(
      tags: .init(
        title: "Stray", artist: "Nobody", album: "Found",
        genre: "Rock", trackNumber: 1, year: 2004),
      seconds: 2)
    let strayURL = try fs.destinationForNewFile(extension: "mp3")
    try strayData.write(to: strayURL)
    let playlist = ITDBPlaylist(
      name: "Mixed", isMaster: false, memberDbids: db.tracks.map(\.dbid))
    db.playlists = [playlist]
    try fs.writeDatabase(db)

    let outcome = try await DatabaseRepair.rebuild(deviceVolume: ipodDir)

    #expect((outcome.source) == (.database))
    #expect((outcome.tracksKept) == (1))
    #expect((outcome.tracksDropped) == (1))
    #expect((outcome.tracksRecovered) == (1))
    let repaired = try fs.readDatabase()
    #expect((Set(repaired.tracks.compactMap(\.title))) == (["Two", "Stray"]))
    let survivor = try #require(repaired.tracks.first { $0.title == "Two" })
    #expect(
      (repaired.playlists.first { $0.name == "Mixed" }?.memberDbids) == ([survivor.dbid]),
      Comment(rawValue: "playlists must be pruned to surviving rows"))
  }

  @Test
  func testRepairRefusesANonIpodFolder() async throws {
    let plainFolder = scratch.appendingPathComponent("not-an-ipod", isDirectory: true)
    try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
    do {
      _ = try await DatabaseRepair.rebuild(deviceVolume: plainFolder)
      Issue.record("repair must reject a folder with no iPod_Control")
    } catch {}
  }

  private struct DeviceArtifactSnapshot: Equatable {
    var directories: Set<String> = []
    var files: [String: Data] = [:]
    var symbolicLinks: [String: String] = [:]
  }

  private func deviceArtifactSnapshot() throws -> DeviceArtifactSnapshot {
    let fm = FileManager.default
    let root = fs.controlDir.standardizedFileURL
    var snapshot = DeviceArtifactSnapshot()

    func relativePath(_ url: URL) -> String {
      String(url.standardizedFileURL.path.dropFirst(root.path.count))
    }

    func visit(_ url: URL) throws {
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
      ])
      let path = relativePath(url)
      if values.isSymbolicLink == true {
        snapshot.symbolicLinks[path] = try fm.destinationOfSymbolicLink(atPath: url.path)
      } else if values.isDirectory == true {
        snapshot.directories.insert(path)
        for child in try fm.contentsOfDirectory(
          at: url,
          includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
          ]
        )
        .sorted(by: { $0.path < $1.path }) {
          try visit(child)
        }
      } else if values.isRegularFile == true {
        snapshot.files[path] = try Data(contentsOf: url)
      }
    }

    try visit(root)
    return snapshot
  }

  private func assertRepairFileAccessFailureIsNonMutating(
    _ audioFileAccess: DatabaseRepair.AudioFileAccess
  ) async throws {
    try FileManager.default.createDirectory(at: fs.musicDir, withIntermediateDirectories: true)
    var database = ITunesDatabase()
    database.tracks = [try putTrackOnIpod(title: "One", artist: "Artist")]
    try fs.writeDatabase(database)
    let liveDatabase = try Data(contentsOf: fs.databaseURL)
    #expect((try ITunesDBReader().read(liveDatabase).tracks.count) == (1))
    let before = try deviceArtifactSnapshot()

    do {
      _ = try await DatabaseRepair.rebuild(
        deviceVolume: ipodDir,
        databaseWriter: { fileSystem, database, format in
          try fileSystem.writeDatabase(database, preflightedFormat: format)
        },
        audioFileAccess: audioFileAccess)
      Issue.record("expected injected file inspection failure")
    } catch {
      #expect(error is InjectedRepairFileAccessFailure, Comment(rawValue: "unexpected error: \(error)"))
    }

    #expect(
      (try deviceArtifactSnapshot()) == (before),
      Comment(rawValue: "incomplete file inspection must not change database, shuffle, audio, or tree artifacts"))
  }

  /// Two opted-in devices connecting in the same refresh: one sync runs at
  /// a time, so the runner-up used to be silently and permanently skipped.
  /// It must queue and sync as soon as the first device finishes.
  @MainActor
  @Test
  func testSimultaneouslyConnectedAutoSyncDevicesBothSync() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    let secondDir = scratch.appendingPathComponent("FAKECLASSIC", isDirectory: true)
    let fs2 = try makeFakeIpodVolume(at: secondDir)
    try fs.writeDatabase(ITunesDatabase())
    try fs2.writeDatabase(ITunesDatabase())

    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = AppState(
      library: library,
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    func device(_ volume: URL, _ fs: IpodFileSystem) throws -> IpodDevice {
      IpodDevice(
        volumeURL: volume, databaseID: try fs.readDatabase().databaseID,
        name: volume.lastPathComponent, modelDescription: "iPod",
        totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
    }
    let first = try device(ipodDir, fs)
    let second = try device(secondDir, fs2)
    app.updateSyncSettings(for: first) { $0.autoSyncOnConnect = true }
    app.updateSyncSettings(for: second) { $0.autoSyncOnConnect = true }

    app.autoSyncIfRequested([first, second])

    func syncedCount(_ fs: IpodFileSystem) -> Int {
      (try? fs.readDatabase().tracks.count) ?? 0
    }
    await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(100)) {
      syncedCount(fs) >= 1 && syncedCount(fs2) >= 1 && !app.syncState.isSyncing
    }
    #expect((syncedCount(fs)) == (1), Comment(rawValue: "the first connected device must auto-sync"))
    #expect((syncedCount(fs2)) == (1), Comment(rawValue: "the second must queue behind it, not be skipped"))
  }

  @MainActor
  @Test
  func testDeviceConnectingDuringInitialScanAutoSyncsWhenScanCompletes() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())
    let releaseMetadataLoad = TestGate()
    let library = LibraryStore(
      folderURL: libraryDir,
      metadataLoader: { url in
        await releaseMetadataLoad.wait()
        return await MetadataLoader.load(url: url)
      })
    let app = AppState(
      library: library,
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    let device = IpodDevice(
      volumeURL: ipodDir, databaseID: try fs.readDatabase().databaseID,
      name: ipodDir.lastPathComponent, modelDescription: "iPod shuffle",
      totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
    app.updateSyncSettings(for: device) { $0.autoSyncOnConnect = true }

    let scan = Task { await library.rescan() }
    let scanStarted = await waitUntil(timeout: .seconds(30)) {
      library.scanProgress?.phase == .loadingMetadata
    }
    #expect(scanStarted)

    app.autoSyncIfRequested([device])
    #expect(!app.syncState.isSyncing)
    #expect((try fs.readDatabase().tracks.count) == (0))

    await releaseMetadataLoad.signal()
    await scan.value

    let trackCountAtScanReturn = try fs.readDatabase().tracks.count
    let queuedSyncStarted = app.syncState.isSyncing || trackCountAtScanReturn == 1
    #expect(
      queuedSyncStarted,
      Comment(rawValue: "scan completion must resume the queued automatic sync before returning"))
    await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(100)) {
      ((try? fs.readDatabase().tracks.count) ?? 0) >= 1 && !app.syncState.isSyncing
    }
    #expect((try fs.readDatabase().tracks.count) == (1))
  }

  @MainActor
  @Test
  func testDeviceConnectingDuringRepairAutoSyncsWhenRepairCompletes() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())

    let secondDir = scratch.appendingPathComponent("FAKECLASSIC", isDirectory: true)
    let secondFS = try makeFakeIpodVolume(at: secondDir)
    try secondFS.writeDatabase(ITunesDatabase())

    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = AppState(
      library: library,
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    func device(_ volume: URL, _ fileSystem: IpodFileSystem) throws -> IpodDevice {
      IpodDevice(
        volumeURL: volume, databaseID: try fileSystem.readDatabase().databaseID,
        name: volume.lastPathComponent, modelDescription: "iPod",
        totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
    }
    let repairing = try device(ipodDir, fs)
    let waiting = try device(secondDir, secondFS)
    app.updateSyncSettings(for: waiting) { $0.autoSyncOnConnect = true }

    let repairLock = try await ScopedAdvisoryLock.acquire(
      for: ipodDir, namespace: .device)
    defer { repairLock.unlock() }
    let repair = Task { try await app.repairDatabase(repairing) }
    await Task.yield()
    #expect(app.syncState.isSyncing)

    app.autoSyncIfRequested([waiting])
    repairLock.unlock()
    _ = try await repair.value

    let trackCountAtRepairReturn = try secondFS.readDatabase().tracks.count
    let queuedSyncStarted = app.syncState.isSyncing || trackCountAtRepairReturn == 1
    #expect(
      queuedSyncStarted, Comment(rawValue: "repair completion must start its queued automatic sync before returning"))
    await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(100)) {
      ((try? secondFS.readDatabase().tracks.count) ?? 0) >= 1 && !app.syncState.isSyncing
    }
    #expect((try secondFS.readDatabase().tracks.count) == (1))
  }

  @MainActor
  @Test
  func testDeviceConnectingDuringFailedRepairAutoSyncsWhenRepairFails() async throws {
    try writeLibraryMP3(filename: "one.mp3", title: "One")
    try fs.writeDatabase(ITunesDatabase())

    let brokenDir = scratch.appendingPathComponent("UNKNOWN-IPOD", isDirectory: true)
    try FileManager.default.createDirectory(
      at: brokenDir.appendingPathComponent("iPod_Control/iTunes"),
      withIntermediateDirectories: true)
    let brokenDeviceDir = brokenDir.appendingPathComponent("iPod_Control/Device")
    try FileManager.default.createDirectory(
      at: brokenDeviceDir, withIntermediateDirectories: true)
    try Data("ModelNumStr: xUNKNOWN\n".utf8).write(
      to: brokenDeviceDir.appendingPathComponent("SysInfo"))

    let library = LibraryStore(folderURL: libraryDir)
    await library.rescan()
    let app = AppState(
      library: library,
      listeningHistory: ListeningHistoryStore(persistence: MemoryPersistence()))
    let waiting = IpodDevice(
      volumeURL: ipodDir, databaseID: try fs.readDatabase().databaseID,
      name: ipodDir.lastPathComponent, modelDescription: "iPod shuffle",
      totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
    let broken = IpodDevice(
      volumeURL: brokenDir, databaseID: nil,
      name: brokenDir.lastPathComponent, modelDescription: "Unknown iPod",
      totalCapacity: 4_000_000_000, availableCapacity: 1_000_000_000)
    app.updateSyncSettings(for: waiting) { $0.autoSyncOnConnect = true }

    let repairLock = try await ScopedAdvisoryLock.acquire(
      for: brokenDir, namespace: .device)
    defer { repairLock.unlock() }
    let repair = Task { try await app.repairDatabase(broken) }
    await Task.yield()
    #expect(app.syncState.isSyncing)

    app.autoSyncIfRequested([waiting])
    repairLock.unlock()
    var thrownError: Error?
    do {
      _ = try await repair.value
      Issue.record("repair of an unrecognized empty iPod should fail closed")
    } catch {
      thrownError = error
    }

    let databaseError = try #require(thrownError as? ITunesDBError)
    guard case .unsupportedDevice(let message) = databaseError else {
      Issue.record("repair should preserve its unsupported-device error, got \(databaseError)")
      return
    }
    #expect(
      (message)
        == ("Nightdrive could not determine this iPod's database format. Restore it once with "
          + "Apple's iPod software, then reconnect it."))
    #expect((databaseError.localizedDescription) == (message))
    let trackCountAtRepairReturn = try fs.readDatabase().tracks.count
    let queuedSyncStarted = app.syncState.isSyncing || trackCountAtRepairReturn == 1
    #expect(
      queuedSyncStarted, Comment(rawValue: "repair failure must release the sync slot to its queued automatic sync"))

    await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(100)) {
      ((try? fs.readDatabase().tracks.count) ?? 0) >= 1 && !app.syncState.isSyncing
    }
    #expect((try fs.readDatabase().tracks.count) == (1))
  }

  private final class MemoryPersistence: AppDataPersistence {
    private let data = Mutex<Data?>(nil)

    func load() throws -> Data? { data.withLock { $0 } }
    func save(_ data: Data) throws { self.data.withLock { $0 = data } }
  }

  private func shuffleDatabase(paths: [String]) -> ITunesDatabase {
    var database = ITunesDatabase()
    database.tracks = paths.enumerated().map { offset, path in
      var track = ITDBTrack()
      track.dbid = UInt64(offset + 1)
      track.ipodPath = path
      return track
    }
    return database
  }
}

private struct InjectedRepairFileAccessFailure: Error {}
