import Darwin
import Foundation

extension SyncEngine {
  private static func stampIndex(
    for tracks: [LibraryTrack]
  ) -> [String: LibraryIndexCacheEntry] {
    var entries: [String: LibraryIndexCacheEntry] = [:]
    entries.reserveCapacity(tracks.count)
    for track in tracks {
      guard let stamp = track.fileGenerationStamp else { continue }
      entries[track.url.standardizedFileURL.path] = LibraryIndexCacheEntry(
        stamp: stamp, track: track)
    }
    return entries
  }

  private enum ArtworkDatabaseCommitOutcome {
    case compatible
    case incompatible
    case unknown
  }

  /// One sync execution. Owns the state the sync's phases share, is created
  /// per `SyncEngine.execute` call, and is driven by a single task; it is
  /// deliberately not Sendable.
  final class SyncRun {
    private let request: SyncExecutionRequest
    private let deviceVolume: URL
    private let libraryFolder: URL
    private let expectedDatabaseID: UInt64?
    private let effects: SyncEngineEffects
    private let transcoding: TranscodeContext
    private let loudness: LoudnessStore
    private let progress: @Sendable (SyncProgress) async -> Void
    private let fs: IpodFileSystem

    private var libraryRootToken: LibraryRootToken!
    private var db = ITunesDatabase()
    private var ledgerEntriesBeforeSync: [SyncLedgerEntry] = []
    private var outboundSnapshotArea: OutboundSnapshotArea?
    private var step = 0
    private var total = 0
    private var transaction: IpodCopyTransaction?
    private var deviceFamily: IpodDeviceFamily!
    private var result = SyncResult()
    private var artworkLinksBeforeSync: [ArtworkDatabaseLink] = []
    private var ledgerEntryBeforeSyncByDbid: [UInt64: SyncLedgerEntry] = [:]
    private var onTheGo: (parsed: [OnTheGoPlaylist.ParsedFile], notes: [String]) = ([], [])
    private var playback = DevicePlaybackCollection()
    private var libraryLock: ScopedAdvisoryLock?
    private var executablePlan = SyncPlan(librarySnapshot: [])
    private var verifiedUpdates: [VerifiedDeviceUpdate] = []

    private struct VerifiedDeviceUpdate {
      let update: SyncDeviceUpdate
    }
    private var reservedDestinations: Set<URL> = []
    private var newEntries: [SyncLedgerEntry] = []
    private var pending: [PendingDeviceCopy] = []
    private var copiedToDevice: [URL] = []
    private var replacedFiles: [(dbid: UInt64, ipodPath: String, title: String)] = []
    private var outboundArtworkSources: [UInt64: ArtworkSourceOverride] = [:]
    private var deleteTransactions: [IpodDeleteTransaction] = []
    private var deviceTracksRemoved = false
    private var devicePlaylistsChanged = false
    private var deviceStatsChanged = false
    private var trackLinks: PlaylistTrackLinks!

    private struct PendingDeviceCopy {
      let track: LibraryTrack
      let staged: URL
      let destination: URL
      let artwork: Data?
      let replacing: ITDBTrack?
      let entrySeed: SyncLedgerEntry?
      let staleEntry: SyncLedgerEntry?
    }

    private static let maximumConcurrentOutboundPreparations = 4

    private struct OutboundIntent: Sendable {
      let local: LibraryTrack
      let delivery: DeviceDelivery
      let operation: SyncFailureOperation
      let replacing: ITDBTrack?
      let staleEntry: SyncLedgerEntry?
      let paceInDevelopment: Bool
    }

    private struct PreparedOutbound: Sendable {
      let intent: OutboundIntent
      let snapshot: OutboundSourceSnapshot
      let transcode: TranscodeHandoff?
      let deviceSource: URL
      let description: OutboundFileDescription
      let transcodeProfile: String?

      func remove() {
        transcode?.remove()
        snapshot.remove()
      }
    }

    private enum OutboundPreparationOutcome: Sendable {
      case prepared(PreparedOutbound)
      case failed(String)
      case cancelled
    }

    init(
      request: SyncExecutionRequest,
      deviceVolume: URL,
      libraryFolder: URL,
      expectedDatabaseID: UInt64?,
      effects: SyncEngineEffects,
      transcoding: TranscodeContext,
      loudness: LoudnessStore,
      progress: @escaping @Sendable (SyncProgress) async -> Void
    ) {
      self.request = request
      self.deviceVolume = deviceVolume
      self.libraryFolder = libraryFolder
      self.expectedDatabaseID = expectedDatabaseID
      self.effects = effects
      self.transcoding = transcoding
      self.loudness = loudness
      self.progress = progress
      self.fs = IpodFileSystem(volumeURL: deviceVolume)
    }

    /// Phase order is the durability contract. Every file operation before the
    /// database write is journaled and reversible; the write is the single
    /// commit. So playlists, On-The-Go imports, and artwork reconcile before
    /// it, transactions finish after it, and an earlier abort is unwound by
    /// the next sync's recovery.
    func run() async throws -> SyncResult {
      let deviceLock = try await prepareDevice()
      defer { deviceLock.unlock() }
      defer { outboundSnapshotArea?.remove() }
      try await buildExecutablePlan()
      verifyPlannedDeviceUpdates()
      defer { libraryLock?.unlock() }

      // Track copies are not the only device-writing phase. Removals stage
      // files transactionally, while playback, playlists, artwork, and the
      // shuffle play-order reconciliation can all require a database write.
      // Validate before any of those phases can change device state.
      try IpodDatabaseSupport(fileSystem: fs).validateForWriting()

      let folderStaging =
        executablePlan.copyToFolder.isEmpty
        ? nil : try SyncStagingArea(libraryFolder: libraryFolder, rootToken: libraryRootToken)
      defer { folderStaging?.remove() }
      total = executablePlan.totalSteps + executablePlan.adoptedPairs.count

      let neededOnDevice = SyncCapacity.plannedOutboundBytes(
        executablePlan, family: deviceFamily, settings: transcoding.settings)
      let available: Int64
      do {
        guard
          let capacity = try deviceVolume.resourceValues(
            forKeys: [.volumeAvailableCapacityKey]
          ).volumeAvailableCapacity
        else {
          throw SyncError.deviceCapacityUnavailable(
            underlying: String(localized: "The volume did not report its available capacity."))
        }
        available = Int64(capacity)
      } catch let error as SyncError {
        throw error
      } catch {
        throw SyncError.deviceCapacityUnavailable(underlying: error.localizedDescription)
      }
      if neededOnDevice + SyncCapacity.reserveBytes > available,
        !executablePlan.copyToDevice.isEmpty || !executablePlan.updateOnDevice.isEmpty
      {
        throw SyncError.notEnoughSpace(needed: neededOnDevice, available: available)
      }

      try await copyInboundFromDevice(staging: folderStaging)
      try await stageOutboundToDevice()
      try publishStagedCopies()
      try await removePlannedDeviceTracks()
      try await linkAdoptedPairs()

      if SyncEngine.mergeDevicePlayback(
        playback: playback, db: &db,
        retainedLinks: &executablePlan.retainedLinks, newEntries: &newEntries,
        result: &result, localRatings: request.localRatings,
        trackLinks: trackLinks, libraryFolder: libraryFolder,
        validateLibraryRoot: validateLibraryRoot)
      {
        deviceStatsChanged = true
      }

      try await reconcilePlaylists()
      importOnTheGoPlaylists()
      let artwork = await reconcileDeviceArtwork()
      try await writeDeviceDatabase(
        artworkChanged: artwork.changedDevice, artworkTransaction: artwork.transaction)
      await persistSyncLedger()
      await report(String(localized: "Done"))
      return result
    }

    /// Reconciles local and device playlists, applying planned device
    /// changes and reporting library-side actions in the result.
    ///
    /// After the track passes so new ledger entries resolve members, before
    /// the database write so device playlist changes land in one commit.
    private func reconcilePlaylists() async throws {
      if deviceFamily.supportsDevicePlaylists {
        await report(String(localized: "Reconciling playlists…"))
        let storedLinks = try SyncLedgerStore.checkedPlaylistLinks(
          for: db.databaseID, libraryFolder: libraryFolder)
        let playlistPlan = SyncEngine.makePlaylistPlan(
          local: SyncScopeResolver.playlistsForReconciliation(
            request.localPlaylists, scope: request.scopeInput.scope),
          device: db.playlists,
          links: storedLinks, trackLinks: trackLinks)

        for action in playlistPlan.deviceActions {
          switch action {
          case .createOnDevice(let localPlaylist):
            var created = ITDBPlaylist(name: localPlaylist.name, isMaster: false)
            created.timestamp = Date()
            created.memberDbids = trackLinks.dbids(forTrackIDs: localPlaylist.trackIDs).dbids
            db.playlists.append(created)
            devicePlaylistsChanged = true
            result.playlistsCreatedOnDevice += 1
            result.playlistLinks.append(
              SyncPlaylistLink(
                localID: localPlaylist.id, persistentID: created.persistentID,
                name: created.name, memberDbids: created.memberDbids))
            result.playlistActionSummaries.append(
              created.memberDbids.count == 1
                ? String(localized: "Created playlist \"\(created.name)\" on the iPod (1 song)")
                : String(
                  localized:
                    "Created playlist \"\(created.name)\" on the iPod (\(created.memberDbids.count) songs)"))
          case .updateOnDevice(_, let persistentID, let name, let memberDbids):
            guard let index = db.playlists.firstIndex(where: { $0.persistentID == persistentID })
            else { continue }
            if db.playlists[index].name != name || db.playlists[index].memberDbids != memberDbids {
              db.playlists[index].name = name
              db.playlists[index].memberDbids = memberDbids
              devicePlaylistsChanged = true
            }
            result.playlistsUpdatedOnDevice += 1
            result.playlistActionSummaries.append(
              memberDbids.count == 1
                ? String(localized: "Updated playlist \"\(name)\" on the iPod (1 song)")
                : String(
                  localized:
                    "Updated playlist \"\(name)\" on the iPod (\(memberDbids.count) songs)"))
          case .deleteOnDevice(let persistentID, let name):
            let before = db.playlists.count
            db.playlists.removeAll { $0.persistentID == persistentID }
            if db.playlists.count != before {
              devicePlaylistsChanged = true
              result.playlistsDeletedOnDevice += 1
              result.playlistActionSummaries.append(
                String(localized: "Removed playlist \"\(name)\" from the iPod"))
            }
          case .createInLibrary, .updateInLibrary, .deleteInLibrary, .conflictResolved:
            break
          }
        }

        for action in playlistPlan.libraryActions {
          switch action {
          case .createInLibrary(let name, let trackIDs, _):
            result.playlistsCreatedInLibrary += 1
            result.playlistActionSummaries.append(
              trackIDs.count == 1
                ? String(localized: "Added playlist \"\(name)\" to the library (1 song)")
                : String(
                  localized:
                    "Added playlist \"\(name)\" to the library (\(trackIDs.count) songs)"))
          case .updateInLibrary(_, let name, _):
            result.playlistsUpdatedInLibrary += 1
            result.playlistActionSummaries.append(
              String(localized: "Updated playlist \"\(name)\" in the library"))
          case .deleteInLibrary(_, let name):
            result.playlistsDeletedInLibrary += 1
            result.playlistActionSummaries.append(
              String(localized: "Removed playlist \"\(name)\" from the library"))
          case .conflictResolved(let name, let detail):
            result.playlistActionSummaries.append(
              String(localized: "Merged playlist \"\(name)\": \(detail)"))
          case .createOnDevice, .updateOnDevice, .deleteOnDevice:
            break
          }
        }
        result.libraryPlaylistActions = playlistPlan.libraryActions
        result.playlistLinks += playlistPlan.links
        result.pendingPlaylistLinks = playlistPlan.pendingLibraryLinks
        result.playlistNotes += playlistPlan.notes
        result.syncedPlaylists = true
      }
    }

    /// Turns parsed On-The-Go files into library playlist imports,
    /// deduplicating against existing playlists and naming them.
    private func importOnTheGoPlaylists() {
      result.playlistNotes += onTheGo.notes
      var existingContents = Set(request.localPlaylists.map(\.trackIDs))
      var usedNames = Set(request.localPlaylists.map(\.name))
      for file in onTheGo.parsed {
        let mapped = trackLinks.trackIDs(forDbids: file.trackDbids)
        if mapped.dropped > 0 {
          guard deviceTracksRemoved else {
            result.playlistNotes.append(
              mapped.dropped == 1
                ? String(
                  localized:
                    "\(file.fileURL.lastPathComponent): 1 song could not be matched to a library file; the On-The-Go playlist will be retried next sync."
                )
                : String(
                  localized:
                    "\(file.fileURL.lastPathComponent): \(mapped.dropped) songs could not be matched to library files; the On-The-Go playlist will be retried next sync."
                ))
            continue
          }
          result.playlistNotes.append(
            mapped.dropped == 1
              ? String(
                localized:
                  "\(file.fileURL.lastPathComponent): 1 song could not be matched to a library file and was dropped; this sync changed the iPod's track order, so the On-The-Go playlist could not be kept for a retry."
              )
              : String(
                localized:
                  "\(file.fileURL.lastPathComponent): \(mapped.dropped) songs could not be matched to library files and were dropped; this sync changed the iPod's track order, so the On-The-Go playlist could not be kept for a retry."
              ))
        }
        guard !mapped.trackIDs.isEmpty, !existingContents.contains(mapped.trackIDs)
        else {
          result.onTheGoFilesToDelete.append(file.fileURL)
          continue
        }
        existingContents.insert(mapped.trackIDs)
        var number = 1
        while usedNames.contains("On-The-Go \(number)") { number += 1 }
        let name = "On-The-Go \(number)"
        usedNames.insert(name)
        result.onTheGoImports.append(OnTheGoImport(name: name, trackIDs: mapped.trackIDs))
        result.onTheGoFilesToDelete.append(file.fileURL)
        result.playlistActionSummaries.append(
          mapped.trackIDs.count == 1
            ? String(localized: "Imported On-The-Go playlist as \"\(name)\" (1 song)")
            : String(
              localized:
                "Imported On-The-Go playlist as \"\(name)\" (\(mapped.trackIDs.count) songs)"))
      }
    }

    /// Reconciles album artwork on the device and returns whether the
    /// device changed along with the pending artwork transaction.
    ///
    /// After the track passes so ledger entries carry final dbids, before the
    /// database write so mhit artwork links land in one commit. A screenless
    /// shuffle skips it.
    private func reconcileDeviceArtwork() async -> (changedDevice: Bool, transaction: ArtworkDBTransaction?) {
      var changedDevice = false
      var transaction: ArtworkDBTransaction?
      if !deviceFamily.isShuffle {
        await report(String(localized: "Syncing album art…"))
        do {
          let artwork = try await SyncEngine.reconcileArtwork(
            fileSystem: fs, database: &db,
            retainedLinks: &executablePlan.retainedLinks, newEntries: &newEntries,
            libraryFolder: libraryFolder, sourceOverrides: outboundArtworkSources,
            existingLinks: artworkLinksBeforeSync,
            previousEntriesByDbid: ledgerEntryBeforeSyncByDbid)
          changedDevice = artwork.changedDevice
          transaction = artwork.transaction
          result.artworkImagesWritten = artwork.imagesWritten
          result.artworkNotes += artwork.notes
        } catch {
          result.fail(.writeArtwork, fs.artworkDBURL.path, error.localizedDescription)
        }
      }
      return (changedDevice, transaction)
    }

    /// Writes the device database when anything changed, committing or
    /// resolving the artwork transaction and finishing copy and delete
    /// transactions; recovers published copies if the write fails.
    private func writeDeviceDatabase(artworkChanged: Bool, artworkTransaction: ArtworkDBTransaction?) async throws {
      if result.copiedToDevice > 0 || result.updatedOnDevice > 0 || devicePlaylistsChanged
        || deviceStatsChanged || artworkChanged || deviceTracksRemoved
      {
        await report(String(localized: "Updating iPod database…"))
        do {
          try artworkTransaction?.prepareRecovery(
            previousLinks: artworkLinksBeforeSync,
            intendedLinks: ArtworkDatabaseLink.links(in: db),
            markerWriter: effects.artworkRecoveryMarkerWriter)
          try effects.databaseWriter(fs, db)
          if let artworkTransaction {
            do {
              try effects.artworkCommitter(artworkTransaction)
            } catch {
              artworkTransaction.deferPreparedResolutionAfterCommitFailure()
              throw error
            }
          }
          transaction?.finish()
          for deleteTransaction in deleteTransactions { deleteTransaction.finish() }
        } catch {
          let databaseWriteError = error
          var cleanupSucceeded = false
          let currentDatabase: ITunesDatabase?
          do {
            currentDatabase = try effects.databaseVerificationReader(fs)
          } catch {
            currentDatabase = nil
            NightdriveLog.sync.error(
              "Could not re-read the device database after a failed write; skipping cleanup: \(error.localizedDescription, privacy: .public)"
            )
          }
          let artworkOutcome: ArtworkDatabaseCommitOutcome
          if let currentDatabase {
            let currentLinks = ArtworkDatabaseLink.links(in: currentDatabase)
            let intendedLinks = ArtworkDatabaseLink.links(in: db)
            if currentLinks == intendedLinks {
              artworkOutcome = .compatible
            } else if currentLinks == artworkLinksBeforeSync {
              artworkOutcome = .incompatible
            } else {
              artworkOutcome = .unknown
            }
          } else {
            artworkOutcome = .unknown
          }
          if let currentDatabase {
            do {
              try fs.recoverInterruptedDeletions(database: currentDatabase)
            } catch {
              NightdriveLog.sync.error(
                "Recovering interrupted deletions failed after a failed database write: \(error.localizedDescription, privacy: .public)"
              )
            }
            let referenced = Set(currentDatabase.tracks.compactMap(\.ipodPath))
            cleanupSucceeded = true
            for url in copiedToDevice where !referenced.contains(fs.ipodPath(for: url)) {
              do {
                try FileManager.default.removeItem(at: url)
              } catch {
                if FileManager.default.fileExists(atPath: url.path) {
                  cleanupSucceeded = false
                }
              }
            }
          }
          if cleanupSucceeded { transaction?.finish() }
          if let artworkTransaction {
            do {
              switch artworkOutcome {
              case .compatible:
                do {
                  try effects.artworkCommitter(artworkTransaction)
                } catch {
                  artworkTransaction.deferPreparedResolutionAfterCommitFailure()
                  throw error
                }
              case .incompatible:
                try artworkTransaction.rollback()
              case .unknown:
                try artworkTransaction.deferResolution()
              }
            } catch {
              throw ArtworkDBTransactionError.resolutionFailed(
                operation: databaseWriteError, resolution: error,
                directory: artworkTransaction.recoveryDirectory)
            }
          }
          throw databaseWriteError
        }
      } else {
        if deviceFamily.isShuffle {
          if !fs.shuffleDatabaseMatches(db) {
            await report(String(localized: "Restoring shuffle play-order file…"))
          }
          // Even matching bytes may be the result of an atomic publication
          // whose late durability sync failed. The writer reconciles that case
          // without rewriting live data or rotating the previous backup.
          try fs.writeShuffleDatabase(db)
        }
        transaction?.finish()
      }
    }

    /// Persists the merged ledger entries for this device database when
    /// a database exists on disk.
    private func persistSyncLedger() async {
      let databaseOnDisk =
        FileManager.default.fileExists(atPath: fs.databaseURL.path)
        || FileManager.default.fileExists(atPath: fs.compressedDatabaseURL.path)
      result.databaseID = databaseOnDisk ? db.databaseID : nil
      if databaseOnDisk {
        var entries = executablePlan.retainedLinks + newEntries
        entries.sort { $0.relativePath < $1.relativePath }
        do {
          let ledgerLock = try await ScopedAdvisoryLock.acquire(
            for: libraryFolder, namespace: .library)
          defer { ledgerLock.unlock() }
          try validateLibraryRoot()
          try SyncLedgerStore.replaceEntries(
            entries, for: db.databaseID, libraryFolder: libraryFolder)
        } catch {
          result.fail(.saveLedger, SyncLedgerStore.url(for: libraryFolder).path, error.localizedDescription)
        }
      }
    }

    /// Copies planned tracks from the device into the library and writes
    /// device tag edits back to local files, releasing the library lock
    /// once the folder side of the sync is complete.
    private func copyInboundFromDevice(staging: SyncStagingArea?) async throws {
      for track in executablePlan.copyToFolder {
        try Task.checkCancellation()
        step += 1
        let trackTitle = track.title ?? String(localized: "Unknown")
        await report(String(localized: "Copying from iPod: \(trackTitle)"))
        #if NIGHTDRIVE_DEVELOPMENT_TOOLS
          await DevelopmentSyncPacing.pauseIfSlowed()
        #endif
        guard let ipodPath = track.ipodPath else {
          let failurePath = track.title ?? String(localized: "Unknown track")
          result.fail(
            .copyToLibrary, failurePath, String(localized: "Source file is missing on the iPod."))
          continue
        }
        let source: URL
        do {
          source = try fs.validatedMusicFileURL(forIpodPath: ipodPath)
        } catch {
          result.fail(
            .copyToLibrary, ipodPath,
            String(
              localized:
                "Source file could not be read from the iPod (\(error.localizedDescription))."))
          continue
        }
        let destination = SyncEngine.folderDestination(for: track, source: source, in: libraryFolder)
        guard let stagingURL = staging?.url else {
          result.fail(
            .copyToLibrary, destination.path,
            String(localized: "Could not create a staging area."))
          continue
        }
        let stagedDestination = stagingURL.appendingPathComponent(
          "\(UUID().uuidString).\(destination.pathExtension)")
        do {
          try validateLibraryRoot()
          try LibraryRootPreflight.createDirectoryHierarchy(
            at: destination.deletingLastPathComponent(), in: libraryRootToken)
          try FileManager.default.copyItem(at: source, to: stagedDestination)
          guard
            let provisionalEntry = ledgerEntry(
              localURL: destination, dbid: track.dbid,
              deviceSignature: SyncSignature.deviceSignature(for: track),
              needsMetadataReconstruction: true,
              identityURL: stagedDestination)
          else {
            throw SyncError.localCopyIdentityUnavailable
          }
          let intendedMetadata: TrackMetadata?
          if LibraryAudioFormat(url: stagedDestination)?.supportsMetadataEditing == true {
            let copiedTrack = await MetadataLoader.load(url: stagedDestination)
            intendedMetadata = SyncEngine.reconciledMetadataForLocalCopy(copiedTrack, from: track)
          } else {
            intendedMetadata = nil
          }
          var tagFailure: Error?
          do {
            try await effects.tagWriter(stagedDestination, track)
            if let intendedMetadata {
              let verifiedTrack = await MetadataLoader.load(url: stagedDestination)
              guard TrackMetadata(verifiedTrack).normalized == intendedMetadata else {
                throw SyncError.metadataVerificationFailed
              }
            }
          } catch {
            tagFailure = error
          }
          try validateLibraryRoot()
          try FileManager.default.moveItem(at: stagedDestination, to: destination)
          result.copiedToFolder += 1
          let entry =
            ledgerEntry(
              localURL: destination, dbid: track.dbid,
              deviceSignature: SyncSignature.deviceSignature(for: track),
              needsMetadataReconstruction: tagFailure != nil)
            ?? provisionalEntry
          newEntries.append(entry)
          if let tagFailure {
            result.fail(
              .reconstructMetadata, destination.path,
              String(
                localized:
                  "Copied without reconstructed tags (\(tagFailure.localizedDescription))"))
          }
        } catch {
          FileManager.default.bestEffortRemoveItem(at: stagedDestination)
          result.fail(.copyToLibrary, destination.path, error.localizedDescription)
        }
      }
      for update in executablePlan.updateInFolder {
        try Task.checkCancellation()
        step += 1
        await report(String(localized: "Updating in library: \(update.local.displayTitle)"))
        let source: URL
        do {
          source = try SyncEngine.validatedLibraryFile(update.local.url, in: libraryFolder)
        } catch {
          result.fail(.updateInFolder, update.local.url.path, error.localizedDescription)
          newEntries.append(update.entry)
          continue
        }
        guard LibraryAudioFormat(url: source)?.supportsMetadataEditing == true else {
          result.fail(
            .updateInFolder, update.local.url.path,
            String(
              localized:
                "Device tag edits can only be written back to MP3 and MPEG-4 audio files."))
          var entry = update.entry
          entry.deviceSignature = SyncSignature.deviceSignature(for: update.device)
          entry.needsMetadataReconstruction = false
          newEntries.append(entry)
          continue
        }
        do {
          try validateLibraryRoot()
          let fileTrack = await MetadataLoader.load(url: source)
          let reconciled = TrackMetadata(fileTrack: fileTrack, databaseTrack: update.device)
            .normalized
          if TrackMetadata(fileTrack).normalized != reconciled {
            try validateLibraryRoot()
            try effects.metadataWriter(reconciled, source)
          }
          let verifiedTrack = await MetadataLoader.load(url: source)
          guard TrackMetadata(verifiedTrack).normalized == reconciled else {
            throw SyncError.metadataVerificationFailed
          }
          if let entry = ledgerEntry(
            localURL: source, dbid: update.device.dbid,
            deviceSignature: SyncSignature.deviceSignature(for: update.device))
          {
            newEntries.append(entry)
            result.updatedInFolder += 1
          } else {
            var entry = update.entry
            entry.needsMetadataReconstruction = true
            newEntries.append(entry)
            result.fail(
              .updateInFolder, update.local.url.path,
              String(
                localized:
                  "Updated metadata could not be verified because the local file could not be read."))
          }
        } catch {
          result.fail(.updateInFolder, update.local.url.path, error.localizedDescription)
          if let entry = ledgerEntry(
            localURL: source, dbid: update.device.dbid,
            deviceSignature: update.entry.deviceSignature)
          {
            var entry = entry
            entry.needsMetadataReconstruction = true
            newEntries.append(entry)
          } else {
            var entry = update.entry
            entry.needsMetadataReconstruction = true
            newEntries.append(entry)
          }
        }
      }
      staging?.remove()
      libraryLock?.unlock()
      libraryLock = nil
    }

    /// Stages planned copies and verified updates into the on-device
    /// staging area without publishing them.
    private func stageOutboundToDevice() async throws {
      let intents = makeOutboundIntents()
      guard !intents.isEmpty else { return }
      try await stageOutboundIntents(intents, area: outboundArea())
    }

    private func makeOutboundIntents() -> [OutboundIntent] {
      var intents: [OutboundIntent] = []
      intents.reserveCapacity(executablePlan.copyToDevice.count + verifiedUpdates.count)
      for track in executablePlan.copyToDevice {
        intents.append(
          OutboundIntent(
            local: track,
            delivery: track.deviceDelivery(for: deviceFamily, transcode: transcoding.settings),
            operation: .copyToDevice, replacing: nil, staleEntry: nil,
            paceInDevelopment: true))
      }
      for verified in verifiedUpdates {
        let update = verified.update
        intents.append(
          OutboundIntent(
            local: update.local, delivery: update.delivery,
            operation: .updateOnDevice, replacing: update.device, staleEntry: update.entry,
            paceInDevelopment: false))
      }
      return intents
    }

    private func stageOutboundIntents(
      _ intents: [OutboundIntent], area: OutboundSnapshotArea
    ) async throws {
      let libraryFolder = libraryFolder
      let effects = effects
      let transcoding = transcoding
      let loudness = loudness

      let width = min(Self.maximumConcurrentOutboundPreparations, intents.count)
      var preparationTasks: [Task<OutboundPreparationOutcome, Never>?] = []
      preparationTasks.reserveCapacity(width)
      for index in 0..<width {
        preparationTasks.append(
          Self.outboundPreparationTask(
            intents[index], libraryFolder: libraryFolder, area: area,
            effects: effects, transcoding: transcoding, loudness: loudness))
      }
      do {
        for index in intents.indices {
          let intent = intents[index]
          let slot = index % width
          guard let awaitedTask = preparationTasks[slot] else {
            preconditionFailure("outbound preparation slot was unexpectedly empty")
          }
          let outcome = await withTaskCancellationHandler {
            await awaitedTask.value
          } onCancel: {
            awaitedTask.cancel()
          }
          preparationTasks[slot] = nil
          let nextIndex = index + width
          if nextIndex < intents.count {
            preparationTasks[slot] = Self.outboundPreparationTask(
              intents[nextIndex], libraryFolder: libraryFolder, area: area,
              effects: effects, transcoding: transcoding, loudness: loudness)
          }
          do {
            try await beginOutboundStep(intent)
            try acceptPreparedOutbound(outcome, for: intent)
          } catch {
            Self.removePreparedResources(in: outcome)
            throw error
          }
        }
      } catch {
        let remainingTasks = preparationTasks.compactMap { $0 }
        remainingTasks.forEach { $0.cancel() }
        for task in remainingTasks {
          Self.removePreparedResources(in: await task.value)
        }
        throw error
      }
    }

    private func beginOutboundStep(_ intent: OutboundIntent) async throws {
      try checkCancellationBeforePublish()
      step += 1
      #if NIGHTDRIVE_DEVELOPMENT_TOOLS
        if intent.paceInDevelopment {
          await DevelopmentSyncPacing.pauseIfSlowed()
        }
      #endif
      if intent.operation == .updateOnDevice {
        await report(String(localized: "Updating on iPod: \(intent.local.displayTitle)"))
      } else {
        await report(String(localized: "Copying to iPod: \(intent.local.displayTitle)"))
      }
    }

    private func acceptPreparedOutbound(
      _ outcome: OutboundPreparationOutcome, for intent: OutboundIntent
    ) throws {
      switch outcome {
      case .prepared(let prepared):
        do {
          try stagePreparedOutbound(prepared)
        } catch {
          result.fail(intent.operation, intent.local.url.path, error.localizedDescription)
          if let staleEntry = intent.staleEntry { newEntries.append(staleEntry) }
        }
      case .failed(let reason):
        result.fail(intent.operation, intent.local.url.path, reason)
        if let staleEntry = intent.staleEntry { newEntries.append(staleEntry) }
      case .cancelled:
        transaction?.finish()
        throw CancellationError()
      }
    }

    private static func removePreparedResources(in outcome: OutboundPreparationOutcome) {
      guard case .prepared(let prepared) = outcome else { return }
      prepared.remove()
    }

    private static func outboundPreparationTask(
      _ intent: OutboundIntent,
      libraryFolder: URL,
      area: OutboundSnapshotArea,
      effects: SyncEngineEffects,
      transcoding: TranscodeContext,
      loudness: LoudnessStore
    ) -> Task<OutboundPreparationOutcome, Never> {
      Task {
        await prepareOutbound(
          intent, libraryFolder: libraryFolder, area: area,
          effects: effects, transcoding: transcoding, loudness: loudness)
      }
    }

    /// Performs CPU-heavy inspection and transcoding against immutable local
    /// files. Several of these may run ahead of the single device writer.
    private static func prepareOutbound(
      _ intent: OutboundIntent,
      libraryFolder: URL,
      area: OutboundSnapshotArea,
      effects: SyncEngineEffects,
      transcoding: TranscodeContext,
      loudness: LoudnessStore
    ) async -> OutboundPreparationOutcome {
      do {
        try Task.checkCancellation()
        if case .unsupported(let reason) = intent.delivery { return .failed(reason) }

        let source = try SyncEngine.validatedLibraryFile(intent.local.url, in: libraryFolder)
        let snapshot = try OutboundSourceSnapshot.create(
          from: source, in: libraryFolder, area: area)
        do {
          switch intent.delivery {
          case .direct:
            let description = await effects.outboundFileDescriber(
              snapshot.url, snapshot, loudness)
            return .prepared(
              PreparedOutbound(
                intent: intent, snapshot: snapshot, transcode: nil,
                deviceSource: snapshot.url, description: description,
                transcodeProfile: nil))
          case .transcode(let profile):
            var sourceTrack = await MetadataLoader.load(url: snapshot.url)
            if sourceTrack.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              sourceTrack.title = snapshot.originalURL.deletingPathExtension().lastPathComponent
            }
            let artwork = await MetadataLoader.loadArtwork(url: snapshot.url)
            let transcode = try await transcoding.cache.prepareTranscodedFile(
              source: snapshot.url, sourceHash: snapshot.contentSHA256, profile: profile,
              metadata: TrackMetadata(sourceTrack), artwork: artwork,
              settings: transcoding.settings)
            let description = await effects.outboundFileDescriber(
              transcode.url, snapshot, loudness)
            return .prepared(
              PreparedOutbound(
                intent: intent, snapshot: snapshot, transcode: transcode,
                deviceSource: transcode.url, description: description,
                transcodeProfile: profile.identifier))
          case .unsupported(let reason):
            snapshot.remove()
            return .failed(reason)
          }
        } catch {
          snapshot.remove()
          throw error
        }
      } catch let error as CancellationError {
        return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
      } catch {
        return .failed(error.localizedDescription)
      }
    }

    /// Serializes the only expensive operation that touches the iPod while
    /// preserving plan order and the existing recovery journal contract.
    private func stagePreparedOutbound(_ prepared: PreparedOutbound) throws {
      defer { prepared.remove() }
      let destination = try reserveDestination(
        fileExtension: prepared.deviceSource.pathExtension)
      let staged = try existingOrNewTransaction().stage(
        source: prepared.deviceSource, destination: destination)
      pending.append(
        PendingDeviceCopy(
          track: prepared.description.track, staged: staged, destination: destination,
          artwork: prepared.description.artwork, replacing: prepared.intent.replacing,
          entrySeed: entrySeed(
            localURL: prepared.intent.local.url, snapshot: prepared.snapshot,
            transcodeProfile: prepared.transcodeProfile),
          staleEntry: prepared.intent.staleEntry))
    }

    /// Publishes staged files onto the device and updates the database
    /// rows and ledger entries for each landed copy.
    private func publishStagedCopies() throws {
      if !pending.isEmpty {
        do {
          // The last cheap cancellation: once published, an abort is unwound
          // only by the next sync's recovery of the journal.
          try Task.checkCancellation()
          try transaction?.publishJournal()
        } catch {
          transaction?.finish()
          throw error
        }
      }
      for copy in pending {
        do {
          guard !FileManager.default.fileExists(atPath: copy.destination.path) else {
            throw CocoaError(.fileWriteFileExists)
          }
          try FileManager.default.moveItem(at: copy.staged, to: copy.destination)
          copiedToDevice.append(copy.destination)
          var row = SyncEngine.makeDBTrack(from: copy.track, ipodPath: fs.ipodPath(for: copy.destination))
          if let replacing = copy.replacing,
            let index = db.tracks.firstIndex(where: { $0.dbid == replacing.dbid })
          {
            let old = db.tracks[index]
            row.dbid = old.dbid
            row.playCount = old.playCount
            row.playCount2 = old.playCount2
            row.bookmarkMS = old.bookmarkMS
            row.rating = old.rating
            row.skipCount = old.skipCount
            row.timeAdded = old.timeAdded
            row.timePlayed = old.timePlayed
            row.lastSkipped = old.lastSkipped
            row.preservedMhitHeader = old.preservedMhitHeader
            row.preservedMhods = old.preservedMhods
            db.tracks[index] = row
            if let oldPath = old.ipodPath, oldPath != row.ipodPath {
              replacedFiles.append((old.dbid, oldPath, copy.track.displayTitle))
            }
            result.updatedOnDevice += 1
          } else {
            db.tracks.append(row)
            result.copiedToDevice += 1
          }
          if var entry = copy.entrySeed {
            entry.dbid = row.dbid
            entry.deviceSignature = SyncSignature.deviceSignature(for: row)
            newEntries.append(entry)
            outboundArtworkSources[row.dbid] = ArtworkSourceOverride(data: copy.artwork)
          } else if let stale = copy.staleEntry {
            newEntries.append(stale)
          }
        } catch {
          result.fail(
            copy.replacing == nil ? .copyToDevice : .updateOnDevice, copy.destination.path,
            error.localizedDescription)
          if let stale = copy.staleEntry {
            newEntries.append(stale)
          }
        }
      }
      try transaction?.synchronizePublishedFiles(copiedToDevice)
    }

    /// Keeps the pre-sync ledger entry for a track whose removal failed
    /// so the still-present file stays linked for the next sync.
    private func retainFailedRemovalLink(for dbid: UInt64) {
      guard let entry = ledgerEntryBeforeSyncByDbid[dbid],
        !executablePlan.retainedLinks.contains(where: { $0.dbid == dbid }),
        !newEntries.contains(where: { $0.dbid == dbid })
      else { return }
      executablePlan.retainedLinks.append(entry)
    }

    /// Stages deletions for replaced files and removes planned tracks
    /// from the device database and its playlists.
    ///
    /// Superseded files stage out of Music before the commit: the journal
    /// restores them if it never lands, and discards them once the on-disk
    /// database points at the replacements. A cancel here is unwound by the
    /// next sync, leaving the device as if this one never ran.
    private func removePlannedDeviceTracks() async throws {
      for replaced in replacedFiles {
        let oldURL: URL
        do {
          oldURL = try fs.validatedMusicFileURL(forIpodPath: replaced.ipodPath)
        } catch {
          result.fail(
            .updateOnDevice, replaced.ipodPath,
            String(
              localized:
                "Previous copy was not found for removal (\(error.localizedDescription))."))
          continue
        }
        do {
          let deleteTransaction = try IpodDeleteTransaction(fileSystem: fs)
          try deleteTransaction.stage(
            source: oldURL, dbid: replaced.dbid, ipodPath: replaced.ipodPath)
          deleteTransactions.append(deleteTransaction)
        } catch {
          result.fail(
            .updateOnDevice, replaced.ipodPath,
            String(
              localized: "Previous copy was not removed (\(error.localizedDescription))."))
        }
      }

      if executablePlan.scopeInput.trackSyncMode == .libraryToIpod
        && (executablePlan.scopeInput.removesSongsNotInLibrary
          || executablePlan.scopeInput.removesSongsOutsideSyncScope)
      {
        var removedDbids: Set<UInt64> = []
        removedDbids.reserveCapacity(executablePlan.removeFromDevice.count)
        for track in executablePlan.removeFromDevice {
          try Task.checkCancellation()
          step += 1
          let trackTitle = track.title ?? String(localized: "Unknown")
          await report(String(localized: "Removing from iPod: \(trackTitle)"))
          if let ipodPath = track.ipodPath {
            do {
              if let deleteTransaction = try effects.removalStager(fs, track.dbid, ipodPath) {
                deleteTransactions.append(deleteTransaction)
              }
            } catch {
              result.fail(.removeFromDevice, ipodPath, error.localizedDescription)
              retainFailedRemovalLink(for: track.dbid)
              continue
            }
          }
          // A row with no recorded path, or whose safe path has no file, is stale.
          removedDbids.insert(track.dbid)
          result.removedFromDevice += 1
        }
        if !removedDbids.isEmpty {
          db.tracks.removeAll { removedDbids.contains($0.dbid) }
          for index in db.playlists.indices {
            db.playlists[index].memberDbids.removeAll { removedDbids.contains($0) }
          }
          deviceTracksRemoved = true
        }
      }
      if !executablePlan.notInLibraryOnDevice.isEmpty {
        let count = executablePlan.notInLibraryOnDevice.count
        result.scopeNotes.append(
          count == 1
            ? String(localized: "1 track on the iPod is not in the library and was left alone.")
            : String(
              localized:
                "\(count) tracks on the iPod are not in the library and were left alone."))
      }
      if !executablePlan.outOfScopeOnDevice.isEmpty {
        let count = executablePlan.outOfScopeOnDevice.count
        result.scopeNotes.append(
          count == 1
            ? String(localized: "1 track on the iPod was not in this sync and was left alone.")
            : String(
              localized:
                "\(count) tracks on the iPod were not in this sync and were left alone."))
      }
    }

    /// Records ledger entries for adopted local/device pairs and builds
    /// the track-link index used by the playlist and playback phases.
    private func linkAdoptedPairs() async throws {
      try Task.checkCancellation()
      for pair in executablePlan.adoptedPairs {
        try Task.checkCancellation()
        step += 1
        await report(String(localized: "Linking \(step)/\(total): \(pair.local.displayTitle)"))
        if let entry = ledgerEntry(
          localURL: pair.local.url, dbid: pair.device.dbid,
          deviceSignature: SyncSignature.deviceSignature(for: pair.device))
        {
          newEntries.append(entry)
        }
      }

      trackLinks = PlaylistTrackLinks(
        entries: executablePlan.retainedLinks + newEntries, libraryFolder: libraryFolder)
    }

    /// Locks the device volume, reads its database, and captures the
    /// pre-sync ledger, artwork, playback, and On-The-Go state that the
    /// later phases build on. The caller owns the returned lock.
    private func prepareDevice() async throws -> ScopedAdvisoryLock {
      libraryRootToken = try LibraryRootPreflight.inspect(libraryFolder).get()
      _ = try PendingPlaybackReportStore.load(libraryFolder: libraryFolder)
      deviceFamily = fs.deviceFamily()
      let dispatchedDatabaseID: UInt64?
      if let expectedDatabaseID {
        dispatchedDatabaseID = expectedDatabaseID
      } else if FileManager.default.fileExists(atPath: fs.databaseURL.path)
        || FileManager.default.fileExists(atPath: fs.compressedDatabaseURL.path)
      {
        dispatchedDatabaseID = try fs.readDatabase().databaseID
      } else {
        dispatchedDatabaseID = nil
      }
      let deviceLock = try await ScopedAdvisoryLock.acquire(
        for: deviceVolume, namespace: .device)
      do {
        try validateLibraryRoot()

        let pendingPlayback = try PendingPlaybackReportStore.load(libraryFolder: libraryFolder)
        db = try fs.readDatabase()
        artworkLinksBeforeSync = ArtworkDatabaseLink.links(in: db)
        ledgerEntriesBeforeSync = try SyncLedgerStore.checkedEntries(
          for: db.databaseID, libraryFolder: libraryFolder)

        for entry in ledgerEntriesBeforeSync {
          ledgerEntryBeforeSyncByDbid[entry.dbid] = entry
        }
        try fs.validateDeviceIdentity(dispatchedDatabaseID, database: db)
        try fs.recoverInterruptedMutations(database: db)

        onTheGo =
          deviceFamily.isShuffle
          ? ([], []) : OnTheGoPlaylist.collect(fileSystem: fs, tracks: db.tracks)

        playback =
          deviceFamily.isShuffle
          ? DevicePlaybackCollection()
          : SyncEngine.collectDevicePlayback(
            fileSystem: fs, database: db, libraryFolder: libraryFolder,
            pending: pendingPlayback)
      } catch {
        deviceLock.unlock()
        throw error
      }
      return deviceLock
    }

    /// Rescans the files the dispatched plan was made from and rebuilds the
    /// plan against the device's current contents. When the plan writes into
    /// the library folder, takes the library lock and replans from a full
    /// rescan so concurrent library edits cannot be overwritten.
    private func buildExecutablePlan() async throws {
      var snapshotURLs: [URL] = []
      snapshotURLs.reserveCapacity(request.librarySnapshot.count)
      for track in request.librarySnapshot {
        do {
          snapshotURLs.append(try SyncEngine.validatedLibraryFile(track.url, in: libraryFolder))
        } catch {
          NightdriveLog.sync.debug(
            "Skipping library snapshot entry that no longer validates: \(track.url.lastPathComponent, privacy: .public) (\(error.localizedDescription, privacy: .public))"
          )
        }
      }
      let refreshedLibrary = await LibraryStore.scanTracks(
        at: snapshotURLs, consulting: SyncEngine.stampIndex(for: request.librarySnapshot)
      ).tracks
      executablePlan = SyncEngine.makePlan(
        library: refreshedLibrary, device: db.tracks,
        links: resolvedLinks(for: refreshedLibrary),
        deviceFamily: deviceFamily, transcodeSettings: transcoding.settings,
        scope: request.scopeInput)

      if !executablePlan.copyToFolder.isEmpty || !executablePlan.updateInFolder.isEmpty {
        libraryLock = try await ScopedAdvisoryLock.acquire(
          for: libraryFolder, namespace: .library)
        try validateLibraryRoot()
        let currentURLs = LibraryStore.findAudioFiles(in: libraryFolder)
        let currentLibrary = await LibraryStore.scanTracks(
          at: currentURLs, consulting: SyncEngine.stampIndex(for: refreshedLibrary)
        ).tracks
        executablePlan = SyncEngine.makePlan(
          library: currentLibrary, device: db.tracks,
          links: resolvedLinks(for: currentLibrary),
          deviceFamily: deviceFamily, transcodeSettings: transcoding.settings,
          scope: request.scopeInput)
      }
    }

    /// Drops planned device updates whose local content is unchanged, keeping
    /// their refreshed ledger entries, and settles generation-stamp revalidations.
    private func verifyPlannedDeviceUpdates() {
      for update in executablePlan.updateOnDevice {
        let signature: OutboundSourceSnapshot.StableSignature
        do {
          let source = try SyncEngine.validatedLibraryFile(update.local.url, in: libraryFolder)
          signature = try OutboundSourceSnapshot.stableSignature(
            of: source, in: libraryFolder)
        } catch {
          result.fail(.updateOnDevice, update.local.url.path, error.localizedDescription)
          executablePlan.retainedLinks.append(update.entry)
          continue
        }
        var profileOutdated = false
        if case .transcode(let profile) = update.delivery {
          profileOutdated = update.entry.transcodeProfile != profile.identifier
        }
        if signature.contentSHA256 == update.entry.contentSHA256 && !profileOutdated
          && !update.requiresDeviceWrite
        {
          var entry = update.entry
          entry.fileSize = signature.fileSize
          entry.fileModifiedAt = signature.modificationDate.timeIntervalSince1970
          entry.fileGenerationStamp = signature.fileGenerationStamp
          executablePlan.retainedLinks.append(entry)
        } else {
          verifiedUpdates.append(VerifiedDeviceUpdate(update: update))
        }
      }
      executablePlan.updateOnDevice = verifiedUpdates.map(\.update)
      for revalidation in executablePlan.generationStampRevalidations {
        do {
          let source = try SyncEngine.validatedLibraryFile(revalidation.local.url, in: libraryFolder)
          let signature = try OutboundSourceSnapshot.stableSignature(
            of: source, in: libraryFolder)
          guard signature.contentSHA256 == revalidation.entry.contentSHA256 else {
            executablePlan.retainedLinks.append(revalidation.entry)
            continue
          }
          var entry = revalidation.entry
          entry.fileSize = signature.fileSize
          entry.fileModifiedAt = signature.modificationDate.timeIntervalSince1970
          entry.fileGenerationStamp = signature.fileGenerationStamp
          executablePlan.retainedLinks.append(entry)
        } catch {
          executablePlan.retainedLinks.append(revalidation.entry)
        }
      }
      executablePlan.generationStampRevalidations = []
    }

    private func validateLibraryRoot() throws {
      _ = try LibraryRootPreflight.validate(libraryRootToken).get()
    }

    private func resolvedLinks(for library: [LibraryTrack]) -> [SyncLink] {
      SyncLedgerStore.resolveLinks(
        entries: ledgerEntriesBeforeSync,
        library: library, device: db.tracks, libraryFolder: libraryFolder)
    }

    private func outboundArea() throws -> OutboundSnapshotArea {
      if let existing = outboundSnapshotArea {
        return existing
      }
      let created = try OutboundSnapshotArea.create(libraryFolder: libraryFolder)
      outboundSnapshotArea = created
      return created
    }

    private func report(_ detail: String) async {
      await progress(SyncProgress(step: step, totalSteps: total, detail: detail))
    }

    private func ledgerEntry(
      localURL: URL,
      dbid: UInt64,
      deviceSignature: String,
      needsMetadataReconstruction: Bool = false,
      identityURL: URL? = nil
    ) -> SyncLedgerEntry? {
      let identityURL = identityURL ?? localURL
      let hash: String
      do {
        hash = try SyncSignature.fileSHA256(url: identityURL)
      } catch {
        NightdriveLog.sync.error(
          "Could not hash \(identityURL.lastPathComponent, privacy: .public) for the sync ledger; the link will be rebuilt next sync: \(error.localizedDescription, privacy: .public)"
        )
        return nil
      }
      guard let relativePath = SyncLedgerStore.relativePath(for: localURL, in: libraryFolder),
        let generationStamp = FileGenerationStamp(url: identityURL)
      else { return nil }
      return SyncLedgerEntry(
        relativePath: relativePath, dbid: dbid, fileSize: generationStamp.sizeBytes,
        fileModifiedAt: generationStamp.modificationDate.timeIntervalSince1970,
        fileGenerationStamp: generationStamp,
        contentSHA256: hash, deviceSignature: deviceSignature,
        needsMetadataReconstruction: needsMetadataReconstruction)
    }

    private func entrySeed(
      localURL: URL, snapshot: OutboundSourceSnapshot, transcodeProfile: String? = nil
    ) -> SyncLedgerEntry? {
      guard let relativePath = SyncLedgerStore.relativePath(for: localURL, in: libraryFolder)
      else { return nil }
      return SyncLedgerEntry(
        relativePath: relativePath, dbid: 0, fileSize: snapshot.fileSize,
        fileModifiedAt: snapshot.modificationDate.timeIntervalSince1970,
        fileGenerationStamp: snapshot.fileGenerationStamp,
        contentSHA256: snapshot.contentSHA256, deviceSignature: "",
        transcodeProfile: transcodeProfile)
    }

    private func existingOrNewTransaction() throws -> IpodCopyTransaction {
      if let transaction { return transaction }
      let created = try IpodCopyTransaction(fileSystem: fs)
      transaction = created
      return created
    }

    /// Before the journal is published, cancellation leaves staged copies only
    /// inside the transaction directory, so finishing removes them at once
    /// instead of waiting for the next sync's recovery.
    private func checkCancellationBeforePublish() throws {
      do {
        try Task.checkCancellation()
      } catch {
        transaction?.finish()
        throw error
      }
    }

    private func reserveDestination(fileExtension: String) throws -> URL {
      let destination = try effects.destinationAllocator(
        fs, fileExtension.lowercased(), reservedDestinations)
      guard reservedDestinations.insert(destination.standardizedFileURL).inserted else {
        throw CocoaError(.fileWriteFileExists)
      }
      return destination
    }

  }
}

private final class SyncStagingArea {
  let url: URL
  private var removed = false

  init(libraryFolder: URL, rootToken: LibraryRootToken) throws {
    let fm = FileManager.default
    _ = try LibraryRootPreflight.validate(rootToken).get()
    var libraryStatus = stat()
    guard Darwin.lstat(libraryFolder.path, &libraryStatus) == 0 else {
      throw posixError()
    }
    let scope = ScopedAdvisoryLock.scopeIdentifier(for: libraryFolder, namespace: .library)

    let stagingPrefix = ".nightdrive-sync-\(scope)-staging-"
    let preferredRoot = libraryFolder.deletingLastPathComponent()
    try Self.scavenge(in: preferredRoot, prefix: stagingPrefix)
    try Self.scavenge(in: libraryFolder, prefix: stagingPrefix)

    let preferredURL = preferredRoot.appendingPathComponent(
      "\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
    do {
      try Self.createPrivateDirectory(
        at: preferredURL, expectedDevice: libraryStatus.st_dev, fileManager: fm)
      url = preferredURL
    } catch {
      let fallbackURL = libraryFolder.appendingPathComponent(
        "\(stagingPrefix)\(UUID().uuidString)", isDirectory: true)
      try Self.createPrivateDirectory(
        at: fallbackURL, expectedDevice: libraryStatus.st_dev, fileManager: fm)
      url = fallbackURL
    }
  }

  func remove() {
    guard !removed else { return }
    removed = true
    FileManager.default.bestEffortRemoveItem(at: url)
  }

  deinit {
    remove()
  }

  private static func scavenge(in directory: URL, prefix: String) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return }
    let entries = try fm.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    for candidate in entries
    where isOwnedStagingName(candidate.lastPathComponent, prefix: prefix) {
      guard
        let values = try? candidate.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ]),
        values.isDirectory == true, values.isSymbolicLink != true
      else { continue }
      fm.bestEffortRemoveItem(at: candidate)
    }
  }

  private static func createPrivateDirectory(
    at url: URL, expectedDevice: dev_t, fileManager fm: FileManager
  ) throws {
    try fm.createDirectory(at: url, withIntermediateDirectories: false)
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0,
      status.st_mode & S_IFMT == S_IFDIR,
      status.st_dev == expectedDevice,
      Darwin.chmod(url.path, 0o700) == 0
    else {
      fm.bestEffortRemoveItem(at: url)
      throw posixError()
    }
  }

  private static func isOwnedStagingName(_ name: String, prefix: String) -> Bool {
    guard name.hasPrefix(prefix) else { return false }
    let identifier = String(name.dropFirst(prefix.count))
    return UUID(uuidString: identifier) != nil && name == prefix + identifier
  }
}
