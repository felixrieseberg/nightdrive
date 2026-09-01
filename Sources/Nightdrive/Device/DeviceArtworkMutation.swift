import Foundation

enum DeviceArtworkMutationError: LocalizedError {
  case unsupportedDevice
  case incompleteExistingStore
  case unreconstructibleExistingArtwork(Int)
  case untouchedArtworkMismatch
  case unreadableReplacement

  var errorDescription: String? {
    switch self {
    case .unsupportedDevice:
      return String(
        localized: "Nightdrive does not know how to update album artwork on this iPod model.")
    case .incompleteExistingStore:
      return String(localized: "The iPod's existing album artwork cannot be updated safely.")
    case .unreconstructibleExistingArtwork(let count):
      if count == 1 {
        return String(
          localized:
            "Album artwork was not changed because 1 existing cover could not be reconstructed from the iPod's files.")
      }
      return String(
        localized:
          "Album artwork was not changed because \(count) existing covers could not be reconstructed from the iPod's files."
      )
    case .untouchedArtworkMismatch:
      return String(
        localized:
          "Album artwork was not changed because an untouched embedded cover does not match the pixels currently stored by the iPod."
      )
    case .unreadableReplacement:
      return String(localized: "The replacement album artwork could not be decoded.")
    }
  }
}

enum DeviceArtworkMutation {
  typealias DatabaseWriter = @Sendable (IpodFileSystem, ITunesDatabase) throws -> Void
  typealias DatabaseReader = @Sendable (IpodFileSystem) throws -> ITunesDatabase

  private struct ResolvedEdit {
    let dbid: UInt64
    let ipodPath: String
    let fileURL: URL
    let updatedData: Data
    let artworkChange: ArtworkChange
  }

  private enum DatabaseOutcome {
    case intended
    case previous
    case unknown
  }

  private struct ExistingStore {
    let images: [ArtworkDatabaseImage]
    let tilesByFormatID: [UInt32: Data]
  }

  static func apply(
    edits: [DeviceTrackMetadataEdit], changes: TrackMetadataChanges,
    initialDatabase: ITunesDatabase, specs: [ArtworkImageSpec],
    fileSystem fs: IpodFileSystem, databaseWriter: DatabaseWriter,
    databaseVerificationReader: DatabaseReader,
    modificationDate: @Sendable () -> Date
  ) async throws {
    let editDbids = Set(edits.map(\.dbid))
    guard editDbids.count == edits.count else {
      throw ITunesDBError.badHeader("Duplicate device metadata edit")
    }

    var intendedDatabase = initialDatabase
    var resolvedEdits: [ResolvedEdit] = []
    for edit in edits {
      guard let index = intendedDatabase.tracks.firstIndex(where: { $0.dbid == edit.dbid }) else {
        throw ITunesDBError.notFound("A selected track is no longer on the iPod")
      }
      guard let path = intendedDatabase.tracks[index].ipodPath else {
        throw ITunesDBError.notFound("A selected track has no file path")
      }
      let previousModificationTime = intendedDatabase.tracks[index].timeModified
      let fileURL = try fs.validatedMusicFileURL(forIpodPath: path)
      let fileTrack = await MetadataLoader.load(url: fileURL)
      let metadata = changes.applying(
        to: TrackMetadata(fileTrack: fileTrack, databaseTrack: intendedDatabase.tracks[index]))
      let original = try Data(contentsOf: fileURL, options: .mappedIfSafe)
      let updated = try rewrittenFileData(
        original: original, liveURL: fileURL, metadata: metadata,
        artworkChange: edit.artworkChange)
      resolvedEdits.append(
        ResolvedEdit(
          dbid: edit.dbid, ipodPath: path, fileURL: fileURL,
          updatedData: updated, artworkChange: edit.artworkChange))
      metadata.applying(to: &intendedDatabase.tracks[index])
      intendedDatabase.tracks[index].timeModified = modificationDate()
      DeviceManager.advanceMetadataCommitMarker(
        on: &intendedDatabase.tracks[index], after: previousModificationTime,
        timezoneShift: intendedDatabase.timezoneShift)
      intendedDatabase.tracks[index].sizeBytes = UInt32(clamping: updated.count)
    }

    let previousLinks = ArtworkDatabaseLink.links(in: initialDatabase)
    let existingStore = try readAndValidateExistingStore(
      previousLinks: previousLinks, specs: specs, fileSystem: fs)
    let existingImagesByDbid = Dictionary(
      uniqueKeysWithValues: existingStore.images.map { ($0.trackDbid, $0) })
    let previousLinkDbids = Set(previousLinks.map(\.dbid))
    let changesByDbid = Dictionary(
      uniqueKeysWithValues: resolvedEdits.map {
        ($0.dbid, $0.artworkChange)
      })
    let replacements = Dictionary(
      uniqueKeysWithValues: resolvedEdits.compactMap { edit in
        if case .replace(let data) = edit.artworkChange { return (edit.dbid, data) }
        return nil
      })
    let removals = Set(
      resolvedEdits.compactMap { edit -> UInt64? in
        if case .remove = edit.artworkChange { return edit.dbid }
        return nil
      })
    let desiredDbids = previousLinkDbids.subtracting(removals).union(replacements.keys)
    var desiredData: [UInt64: Data] = [:]
    var unreconstructible = 0
    for track in initialDatabase.tracks where desiredDbids.contains(track.dbid) {
      if let replacement = replacements[track.dbid] {
        desiredData[track.dbid] = replacement
        continue
      }
      guard let path = track.ipodPath,
        let fileURL = try? fs.validatedMusicFileURL(forIpodPath: path),
        let artwork = await MetadataLoader.loadArtwork(url: fileURL), !artwork.isEmpty
      else {
        unreconstructible += 1
        continue
      }
      if previousLinkDbids.contains(track.dbid), replacements[track.dbid] == nil {
        guard let existingImage = existingImagesByDbid[track.dbid] else {
          throw DeviceArtworkMutationError.incompleteExistingStore
        }
        try validateUntouchedArtwork(
          artwork, existingImage: existingImage, specs: specs,
          tilesByFormatID: existingStore.tilesByFormatID)
      }
      desiredData[track.dbid] = artwork
    }
    guard unreconstructible == 0, desiredData.count == desiredDbids.count else {
      throw DeviceArtworkMutationError.unreconstructibleExistingArtwork(
        max(unreconstructible, desiredDbids.count - desiredData.count))
    }

    let mediaUpdates = resolvedEdits.map {
      ArtworkMediaFileUpdate(liveURL: $0.fileURL, ipodPath: $0.ipodPath, data: $0.updatedData)
    }
    let imageIDs = try imageIDs(
      previousLinks: previousLinks, desiredDbids: desiredDbids,
      replacementDbids: Set(replacements.keys))
    let artworkWrite = try ArtworkDBWriter.beginWrite(
      images: desiredData.map { ArtworkImage(dbid: $0.key, data: $0.value) },
      specs: specs, fileSystem: fs, mediaFileUpdates: mediaUpdates,
      imageIDsByDbid: imageIDs, preinstallPreviousLinks: previousLinks)
    let transaction = artworkWrite.transaction
    var databaseWriteAttempted = false
    do {
      guard Set(artworkWrite.assignments.keys) == desiredDbids else {
        throw DeviceArtworkMutationError.unreadableReplacement
      }
      for index in intendedDatabase.tracks.indices {
        let dbid = intendedDatabase.tracks[index].dbid
        if let assignment = artworkWrite.assignments[dbid] {
          intendedDatabase.tracks[index].artwork = ITDBTrackArtwork(
            mhiiID: assignment.mhiiID, sizeBytes: assignment.sourceImageSize)
        } else if previousLinkDbids.contains(dbid) || changesByDbid[dbid] != nil {
          intendedDatabase.tracks[index].artwork = .cleared
        }
      }

      let previousStates = ArtworkDatabaseTrackState.states(
        in: initialDatabase, dbids: editDbids)
      let intendedStates = ArtworkDatabaseTrackState.states(
        in: intendedDatabase, dbids: editDbids)
      try transaction.prepareRecovery(
        previousLinks: previousLinks,
        intendedLinks: ArtworkDatabaseLink.links(in: intendedDatabase),
        previousTrackStates: previousStates, intendedTrackStates: intendedStates)
      databaseWriteAttempted = true
      try databaseWriter(fs, intendedDatabase)
    } catch {
      let operationError = error
      if databaseWriteAttempted {
        let currentDatabase = try? databaseVerificationReader(fs)
        let outcome = classify(
          currentDatabase: currentDatabase, previous: initialDatabase,
          intended: intendedDatabase, editDbids: editDbids)
        do {
          switch outcome {
          case .intended:
            try transaction.commit()
          case .previous:
            try transaction.rollback()
          case .unknown:
            try transaction.deferResolution()
          }
        } catch {
          transaction.deferPreparedResolutionAfterCommitFailure()
          throw ArtworkDBTransactionError.resolutionFailed(
            operation: operationError, resolution: error,
            directory: transaction.recoveryDirectory)
        }
      } else {
        do {
          try transaction.rollback()
        } catch {
          throw ArtworkDBTransactionError.rollbackFailed(
            operation: operationError, rollback: error,
            directory: transaction.recoveryDirectory)
        }
      }
      throw operationError
    }

    do {
      try transaction.commit()
    } catch {
      transaction.deferPreparedResolutionAfterCommitFailure()
      throw error
    }
  }

  private static func classify(
    currentDatabase: ITunesDatabase?, previous: ITunesDatabase,
    intended: ITunesDatabase, editDbids: Set<UInt64>
  ) -> DatabaseOutcome {
    guard let currentDatabase else { return .unknown }
    if database(currentDatabase, matches: intended, editDbids: editDbids) {
      return .intended
    }
    if database(currentDatabase, matches: previous, editDbids: editDbids) {
      return .previous
    }
    return .unknown
  }

  private static func imageIDs(
    previousLinks: [ArtworkDatabaseLink], desiredDbids: Set<UInt64>,
    replacementDbids: Set<UInt64>
  ) throws -> [UInt64: UInt32] {
    guard Set(previousLinks.map(\.mhiiID)).count == previousLinks.count else {
      throw DeviceArtworkMutationError.incompleteExistingStore
    }
    var result = Dictionary(
      uniqueKeysWithValues: previousLinks.compactMap { link in
        desiredDbids.contains(link.dbid) && !replacementDbids.contains(link.dbid)
          ? (link.dbid, link.mhiiID) : nil
      })
    var reserved = Set(previousLinks.map(\.mhiiID))
    var candidate = ArtworkDBWriter.firstImageID
    for dbid in replacementDbids.sorted() {
      while reserved.contains(candidate) {
        guard candidate < UInt32.max else {
          throw ITunesDBError.badHeader("Artwork image identifiers are exhausted")
        }
        candidate += 1
      }
      result[dbid] = candidate
      reserved.insert(candidate)
    }
    return result
  }

  private static func database(
    _ current: ITunesDatabase, matches expected: ITunesDatabase,
    editDbids: Set<UInt64>
  ) -> Bool {
    ArtworkDatabaseLink.links(in: current) == ArtworkDatabaseLink.links(in: expected)
      && ArtworkDatabaseTrackState.states(in: current, dbids: editDbids)
        == ArtworkDatabaseTrackState.states(in: expected, dbids: editDbids)
  }

  private static func readAndValidateExistingStore(
    previousLinks: [ArtworkDatabaseLink], specs: [ArtworkImageSpec],
    fileSystem fs: IpodFileSystem
  ) throws -> ExistingStore {
    let fm = FileManager.default
    let images: [ArtworkDatabaseImage]
    if fm.fileExists(atPath: fs.artworkDBURL.path) {
      do {
        images = try ArtworkDBReader.read(Data(contentsOf: fs.artworkDBURL))
      } catch {
        throw DeviceArtworkMutationError.incompleteExistingStore
      }
    } else {
      images = []
    }
    var storeLinks: [ArtworkDatabaseLink] = []
    for image in images {
      storeLinks.append(
        ArtworkDatabaseLink(
          dbid: image.trackDbid, mhiiID: image.mhiiID,
          sizeBytes: image.sourceImageSize, count: 1))
    }
    storeLinks.sort { lhs, rhs in
      lhs.dbid == rhs.dbid ? lhs.mhiiID < rhs.mhiiID : lhs.dbid < rhs.dbid
    }
    guard Set(specs.map(\.formatID)).count == specs.count,
      Set(previousLinks.map(\.dbid)).count == previousLinks.count,
      Set(images.map(\.trackDbid)).count == images.count,
      storeLinks == previousLinks,
      images.isEmpty || specs.allSatisfy({ fm.fileExists(atPath: fs.ithmbURL(for: $0).path) })
    else {
      throw DeviceArtworkMutationError.incompleteExistingStore
    }
    let tilesByFormatID: [UInt32: Data]
    do {
      tilesByFormatID =
        images.isEmpty
        ? [:]
        : try Dictionary(
          uniqueKeysWithValues: specs.map {
            ($0.formatID, try Data(contentsOf: fs.ithmbURL(for: $0), options: .mappedIfSafe))
          })
    } catch {
      throw DeviceArtworkMutationError.incompleteExistingStore
    }
    return ExistingStore(images: images, tilesByFormatID: tilesByFormatID)
  }

  private static func rewrittenFileData(
    original: Data, liveURL: URL, metadata: TrackMetadata,
    artworkChange: ArtworkChange
  ) throws -> Data {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveDeviceArtwork-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { FileManager.default.bestEffortRemoveItem(at: directory) }
    let staged = directory.appendingPathComponent(
      "track.\(liveURL.pathExtension.lowercased())")
    try original.write(to: staged)
    try TrackFileMetadataWriter.write(metadata, artworkChange: artworkChange, to: staged)
    return try Data(contentsOf: staged, options: .mappedIfSafe)
  }

  private static func validateUntouchedArtwork(
    _ embeddedData: Data, existingImage: ArtworkDatabaseImage,
    specs: [ArtworkImageSpec], tilesByFormatID: [UInt32: Data]
  ) throws {
    guard let image = ArtworkDBWriter.decode(embeddedData),
      existingImage.childCount == existingImage.thumbnails.count,
      existingImage.thumbnails.count == specs.count,
      Set(existingImage.thumbnails.map(\.formatID)).count == specs.count
    else {
      throw DeviceArtworkMutationError.untouchedArtworkMismatch
    }
    for spec in specs {
      guard
        let thumbnail = existingImage.thumbnails.first(where: { $0.formatID == spec.formatID }),
        thumbnail.fileName == ":" + spec.ithmbName,
        thumbnail.imageSize == UInt32(spec.bytesPerTile),
        thumbnail.width == spec.width, thumbnail.height == spec.height,
        thumbnail.childCount == 1, thumbnail.fileNameChildCount == 1,
        let ithmb = tilesByFormatID[spec.formatID]
      else {
        throw DeviceArtworkMutationError.untouchedArtworkMismatch
      }
      let stored: Data
      let offset = Int(thumbnail.ithmbOffset)
      let (end, overflow) = offset.addingReportingOverflow(spec.bytesPerTile)
      guard !overflow, offset >= 0, end <= ithmb.count else {
        throw DeviceArtworkMutationError.untouchedArtworkMismatch
      }
      stored = ithmb.subdata(in: offset..<end)
      guard stored == ArtworkPixels.tileData(image: image, spec: spec) else {
        throw DeviceArtworkMutationError.untouchedArtworkMismatch
      }
    }
  }
}
