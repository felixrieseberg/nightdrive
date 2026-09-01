import Darwin
import Foundation

enum SyncEngine {
  struct ArtworkSourceOverride: Sendable {
    let data: Data?
  }

  static func makePlan(
    library: [LibraryTrack], device: [ITDBTrack], links: [SyncLink] = [],
    deviceFamily: IpodDeviceFamily = .thirdGenerationOrLater,
    transcodeSettings: TranscodeSettings = TranscodeSettings(),
    scope scopeInput: SyncScopeInput = SyncScopeInput()
  ) -> SyncPlan {
    var plan = SyncPlan(librarySnapshot: library)
    plan.scopeInput = scopeInput
    let libraryIsAuthoritative = scopeInput.trackSyncMode == .libraryToIpod
    let ipodIsAuthoritative = scopeInput.trackSyncMode == .ipodToLibrary

    let inScopeKeys = SyncScopeResolver.inScopeKeys(scopeInput, library: library)
    func isInScope(_ track: LibraryTrack) -> Bool {
      if ipodIsAuthoritative { return true }
      guard let inScopeKeys else { return true }
      return inScopeKeys.contains(track.id.rawValue)
    }
    func isTrimmed(_ track: LibraryTrack) -> Bool {
      !scopeInput.excludedURLKeys.isEmpty
        && scopeInput.excludedURLKeys.contains(track.id.rawValue)
    }
    func removalIsConfirmed(_ track: ITDBTrack) -> Bool {
      scopeInput.confirmedRemovalDbids?.contains(track.dbid) ?? true
    }
    func mayRemoveOutsideScope(_ track: ITDBTrack) -> Bool {
      libraryIsAuthoritative && scopeInput.removesSongsOutsideSyncScope
        && removalIsConfirmed(track)
    }
    func mayRemoveNotInLibrary(_ track: ITDBTrack) -> Bool {
      libraryIsAuthoritative && scopeInput.removesSongsNotInLibrary
        && removalIsConfirmed(track)
    }

    func delivery(for track: LibraryTrack) -> DeviceDelivery {
      track.deviceDelivery(for: deviceFamily, transcode: transcodeSettings)
    }

    var linkedLocalURLs: Set<URL> = []
    var linkedDbids: Set<UInt64> = []
    for link in links {
      linkedLocalURLs.insert(link.local.url)
      linkedDbids.insert(link.device.dbid)
      if link.entry.needsMetadataReconstruction && !libraryIsAuthoritative {
        plan.updateInFolder.append(
          SyncFolderUpdate(local: link.local, device: link.device, entry: link.entry))
        if !isInScope(link.local) {
          plan.excludedByScope.append(link.local)
          plan.outOfScopeOnDevice.append(link.device)
        }
        continue
      }
      guard isInScope(link.local) else {
        plan.excludedByScope.append(link.local)
        if mayRemoveOutsideScope(link.device) {
          plan.removeFromDeviceOutsideScope.append(link.device)
        } else {
          plan.outOfScopeOnDevice.append(link.device)
          plan.retainedLinks.append(link.entry)
        }
        continue
      }
      let localChanged = SyncSignature.localLooksChanged(link.local, entry: link.entry)
      let deviceChanged =
        SyncSignature.deviceSignature(for: link.device) != link.entry.deviceSignature
      if ipodIsAuthoritative {
        if localChanged || deviceChanged {
          plan.updateInFolder.append(
            SyncFolderUpdate(local: link.local, device: link.device, entry: link.entry))
        } else if SyncSignature.needsHashReverification(link.local, entry: link.entry) {
          plan.generationStampRevalidations.append(
            SyncGenerationStampRevalidation(local: link.local, entry: link.entry))
        } else {
          plan.retainedLinks.append(link.entry)
        }
        continue
      }
      let localDelivery = delivery(for: link.local)
      let deliverable: Bool
      var profileOutdated = false
      switch localDelivery {
      case .direct:
        deliverable = true
      case .transcode(let profile):
        deliverable = true
        profileOutdated = link.entry.transcodeProfile != profile.identifier
      case .unsupported:
        deliverable = false
      }
      let restoreDeviceMetadata = libraryIsAuthoritative && deviceChanged
      if (localChanged || profileOutdated || restoreDeviceMetadata) && deliverable {
        plan.updateOnDevice.append(
          SyncDeviceUpdate(
            local: link.local, device: link.device, entry: link.entry,
            delivery: localDelivery, requiresDeviceWrite: restoreDeviceMetadata))
      } else if deviceChanged && !libraryIsAuthoritative {
        plan.updateInFolder.append(
          SyncFolderUpdate(local: link.local, device: link.device, entry: link.entry))
      } else {
        if localChanged || restoreDeviceMetadata {
          plan.unsupportedForDevice.append(link.local)
        }
        if SyncSignature.needsHashReverification(link.local, entry: link.entry) {
          plan.generationStampRevalidations.append(
            SyncGenerationStampRevalidation(local: link.local, entry: link.entry))
        } else {
          plan.retainedLinks.append(link.entry)
        }
      }
    }

    let unlinkedLibrary = library.filter { !linkedLocalURLs.contains($0.url) }
    let libraryKeyed = unlinkedLibrary.filter(isInScope)
      .map { (key: TrackMatcher.key(for: $0), track: $0) }
    let outOfScopeKeyed = unlinkedLibrary.filter { !isInScope($0) }
      .map { (key: TrackMatcher.key(for: $0), track: $0) }
    let deviceKeyed = device.filter { !linkedDbids.contains($0.dbid) }
      .map { (key: TrackMatcher.key(for: $0), track: $0) }

    var unmatchedDevice = deviceKeyed.indices.reduce(into: [TrackMatcher.Key: [Int]]()) {
      $0[deviceKeyed[$1].key, default: []].append($1)
    }
    var matchedDeviceIndices: Set<Int> = []
    for entry in libraryKeyed {
      if var candidates = unmatchedDevice[entry.key], !candidates.isEmpty {
        let matched = candidates.removeFirst()
        unmatchedDevice[entry.key] = candidates
        matchedDeviceIndices.insert(matched)
        plan.adoptedPairs.append(
          SyncAdoptedPair(local: entry.track, device: deviceKeyed[matched].track))
      } else if ipodIsAuthoritative {
        plan.localOnlyInLibrary.append(entry.track)
      } else if case .unsupported = delivery(for: entry.track) {
        plan.unsupportedForDevice.append(entry.track)
      } else if isTrimmed(entry.track) {
      } else {
        plan.copyToDevice.append(entry.track)
      }
    }
    for entry in outOfScopeKeyed {
      plan.excludedByScope.append(entry.track)
      if var candidates = unmatchedDevice[entry.key], !candidates.isEmpty {
        let matched = candidates.removeFirst()
        unmatchedDevice[entry.key] = candidates
        matchedDeviceIndices.insert(matched)
        if mayRemoveOutsideScope(deviceKeyed[matched].track) {
          plan.removeFromDeviceOutsideScope.append(deviceKeyed[matched].track)
        } else {
          plan.outOfScopeOnDevice.append(deviceKeyed[matched].track)
        }
      }
    }
    for index in deviceKeyed.indices where !matchedDeviceIndices.contains(index) {
      let track = deviceKeyed[index].track
      if libraryIsAuthoritative {
        if mayRemoveNotInLibrary(track) {
          plan.removeFromDeviceNotInLibrary.append(track)
        } else {
          plan.notInLibraryOnDevice.append(track)
        }
      } else {
        plan.copyToFolder.append(track)
      }
    }
    return plan
  }

  static func execute(
    plan: SyncPlan,
    deviceVolume: URL,
    libraryFolder: URL,
    expectedDatabaseID: UInt64? = nil,
    transcoding: TranscodeContext = TranscodeContext(),
    loudness: LoudnessStore = LoudnessStore(),
    progress: @escaping @Sendable (SyncProgress) async -> Void
  ) async throws -> SyncResult {
    try await execute(
      request: SyncExecutionRequest(plan), deviceVolume: deviceVolume,
      libraryFolder: libraryFolder, expectedDatabaseID: expectedDatabaseID,
      transcoding: transcoding, loudness: loudness, progress: progress)
  }

  static func execute(
    request: SyncExecutionRequest,
    deviceVolume: URL,
    libraryFolder: URL,
    expectedDatabaseID: UInt64? = nil,
    effects: SyncEngineEffects = SyncEngineEffects(),
    transcoding: TranscodeContext = TranscodeContext(),
    loudness: LoudnessStore = LoudnessStore(),
    progress: @escaping @Sendable (SyncProgress) async -> Void
  ) async throws -> SyncResult {
    try await SyncRun(
      request: request, deviceVolume: deviceVolume, libraryFolder: libraryFolder,
      expectedDatabaseID: expectedDatabaseID, effects: effects,
      transcoding: transcoding, loudness: loudness, progress: progress
    ).run()
  }

  static func validatedLibraryFile(_ source: URL, in libraryFolder: URL) throws -> URL {
    let root = libraryFolder.resolvingSymlinksInPath().standardizedFileURL
    let resolved = source.resolvingSymlinksInPath().standardizedFileURL
    guard resolved.isContained(in: root, allowRoot: false) else {
      throw ITunesDBError.notFound("Track is outside the library folder")
    }
    let values = try resolved.resourceValues(forKeys: [.isRegularFileKey])
    guard values.isRegularFile == true else {
      throw ITunesDBError.notFound("Track file is missing")
    }
    return resolved
  }

  struct ArtworkReconciliation: Sendable {
    var changedDevice = false
    var notes: [String] = []
    var imagesWritten = 0
    var transaction: ArtworkDBTransaction?
  }

  static func reconcileArtwork(
    fileSystem fs: IpodFileSystem,
    database db: inout ITunesDatabase,
    retainedLinks: inout [SyncLedgerEntry],
    newEntries: inout [SyncLedgerEntry],
    libraryFolder: URL,
    sourceOverrides: [UInt64: ArtworkSourceOverride] = [:],
    existingLinks: [ArtworkDatabaseLink],
    previousEntriesByDbid: [UInt64: SyncLedgerEntry]
  ) async throws -> ArtworkReconciliation {
    var outcome = ArtworkReconciliation()
    guard case .specs(let specs) = ArtworkFormats.resolve(fileSystem: fs) else {
      outcome.notes.append(
        "Album art was not written: Nightdrive does not know this iPod model's artwork format.")
      return outcome
    }
    guard !specs.isEmpty else { return outcome }
    let fm = FileManager.default
    if fm.fileExists(atPath: fs.compressedDatabaseURL.path) {
      outcome.notes.append(
        "Album art was not written: this iPod keeps artwork in a database "
          + "format Nightdrive does not write.")
      return outcome
    }

    var existingImages: [ArtworkDatabaseImage]?
    if let data = try? Data(contentsOf: fs.artworkDBURL) {
      existingImages = try? ArtworkDBReader.read(data)
    }
    let currentDbids = Set((existingImages ?? []).map(\.trackDbid))
    let tilesPresent = specs.allSatisfy { fm.fileExists(atPath: fs.ithmbURL(for: $0).path) }
    var imagesByDbid: [UInt64: [UInt32: ArtworkDatabaseImage]] = [:]
    for image in existingImages ?? [] {
      imagesByDbid[image.trackDbid, default: [:]][image.mhiiID] = image
    }
    let deviceDbids = Set(db.tracks.map(\.dbid))
    let validExistingDbids = Set(
      existingLinks.compactMap { link -> UInt64? in
        guard deviceDbids.contains(link.dbid), tilesPresent,
          imagesByDbid[link.dbid]?[link.mhiiID] != nil
        else { return nil }
        return link.dbid
      })

    func embeddedArtwork(for entry: SyncLedgerEntry) async -> (hash: String, data: Data?)? {
      if let override = sourceOverrides[entry.dbid] {
        guard let data = override.data, !data.isEmpty else { return ("", nil) }
        return (ArtworkPixels.sha256Hex(data), data)
      }
      guard
        let source = try? validatedLibraryFile(
          libraryFolder.appendingPathComponent(entry.relativePath), in: libraryFolder)
      else { return nil }
      guard let data = await MetadataLoader.loadArtwork(url: source), !data.isEmpty else {
        return ("", nil)
      }
      return (ArtworkPixels.sha256Hex(data), data)
    }
    var imageData: [UInt64: Data] = [:]
    var previousHashes: [UInt64: String] = [:]
    var desiredHashes: [UInt64: String] = [:]
    var computedHashes: [UInt64: String] = [:]
    var unknownExistingDbids: Set<UInt64> = []
    let linkedEntries = retainedLinks + newEntries
    let linkedDbids = Set(linkedEntries.map(\.dbid))
    unknownExistingDbids.formUnion(validExistingDbids.subtracting(linkedDbids))
    for entry in linkedEntries {
      guard deviceDbids.contains(entry.dbid) else { continue }
      let previousHash =
        previousEntriesByDbid[entry.dbid]?.artworkSHA256
        ?? entry.artworkSHA256
      if let previousHash { previousHashes[entry.dbid] = previousHash }
      let explicitLocalRemoval = previousHash != nil && sourceOverrides[entry.dbid] != nil
      if let stored = entry.artworkSHA256 {
        desiredHashes[entry.dbid] = stored
      } else if let computed = await embeddedArtwork(for: entry) {
        if computed.hash.isEmpty, !explicitLocalRemoval,
          validExistingDbids.contains(entry.dbid)
        {
          unknownExistingDbids.insert(entry.dbid)
          continue
        }
        computedHashes[entry.dbid] = computed.hash
        desiredHashes[entry.dbid] = computed.hash
        if let data = computed.data { imageData[entry.dbid] = data }
      } else if !explicitLocalRemoval, validExistingDbids.contains(entry.dbid) {
        unknownExistingDbids.insert(entry.dbid)
      }
    }
    var desired = desiredHashes.filter { !$0.value.isEmpty }
    let previous = previousHashes.filter { !$0.value.isEmpty }

    var needsRebuild = desired != previous
    if !desired.isEmpty,
      existingImages == nil || !tilesPresent || !Set(desired.keys).isSubset(of: currentDbids)
    {
      needsRebuild = true
    }
    let examinedWithoutArt = Set(desiredHashes.filter { $0.value.isEmpty }.keys)
    if !examinedWithoutArt.isDisjoint(with: currentDbids) {
      needsRebuild = true
    }

    if needsRebuild {
      for entry in linkedEntries {
        guard desired[entry.dbid] != nil, imageData[entry.dbid] == nil,
          let computed = await embeddedArtwork(for: entry), let data = computed.data
        else { continue }
        imageData[entry.dbid] = data
      }
      let unreconstructibleKnownDbids = validExistingDbids.filter {
        desired[$0] != nil && imageData[$0] == nil
      }
      let blockedDbids = unknownExistingDbids.union(unreconstructibleKnownDbids)
      if !blockedDbids.isEmpty {
        outcome.notes.append(
          blockedDbids.count == 1
            ? String(
              localized:
                "Album art changes were deferred because 1 existing cover could not be reconstructed safely.")
            : String(
              localized:
                "Album art changes were deferred because \(blockedDbids.count) existing covers could not be reconstructed safely."
            ))
        if let existingImages {
          relinkArtworkImages(existingImages, preserving: existingLinks, in: &db)
        }
        keepDeferredArtworkChangesPending(
          newEntries: &newEntries, computedHashes: computedHashes,
          previousEntriesByDbid: previousEntriesByDbid)
        return outcome
      }
      let images = desired.keys.sorted().compactMap { dbid in
        imageData[dbid].map { ArtworkImage(dbid: dbid, data: $0) }
      }
      let write = try ArtworkDBWriter.beginWrite(
        images: images, specs: specs, fileSystem: fs,
        preinstallPreviousLinks: existingLinks)
      let assignments = write.assignments
      let failedExistingDbids = validExistingDbids.intersection(desired.keys)
        .subtracting(assignments.keys)
      if !failedExistingDbids.isEmpty {
        try write.transaction.rollback()
        if let existingImages {
          relinkArtworkImages(existingImages, preserving: existingLinks, in: &db)
        }
        outcome.notes.append(
          failedExistingDbids.count == 1
            ? String(
              localized:
                "Album art changes were deferred because 1 existing cover could not be reconstructed safely.")
            : String(
              localized:
                "Album art changes were deferred because \(failedExistingDbids.count) existing covers could not be reconstructed safely."
            ))
        keepDeferredArtworkChangesPending(
          newEntries: &newEntries, computedHashes: computedHashes,
          previousEntriesByDbid: previousEntriesByDbid)
        return outcome
      }
      outcome.transaction = write.transaction
      for index in db.tracks.indices {
        if let assignment = assignments[db.tracks[index].dbid] {
          db.tracks[index].artwork = ITDBTrackArtwork(
            mhiiID: assignment.mhiiID, sizeBytes: assignment.sourceImageSize)
        } else {
          db.tracks[index].artwork = .cleared
        }
      }
      let unwritten = Set(desired.keys).subtracting(assignments.keys)
      if !unwritten.isEmpty {
        for index in retainedLinks.indices where unwritten.contains(retainedLinks[index].dbid) {
          retainedLinks[index].artworkSHA256 = ""
        }
        for index in newEntries.indices where unwritten.contains(newEntries[index].dbid) {
          newEntries[index].artworkSHA256 = ""
        }
        for dbid in unwritten {
          computedHashes[dbid] = ""
          desired[dbid] = nil
        }
        outcome.notes.append(
          unwritten.count == 1
            ? String(localized: "Album art for 1 track could not be read and was skipped.")
            : String(
              localized:
                "Album art for \(unwritten.count) tracks could not be read and was skipped."))
      }
      outcome.changedDevice = true
      outcome.imagesWritten = assignments.count
    } else if let existingImages {
      relinkArtworkImages(existingImages, preserving: existingLinks, in: &db)
    }

    for index in retainedLinks.indices where retainedLinks[index].artworkSHA256 == nil {
      retainedLinks[index].artworkSHA256 = computedHashes[retainedLinks[index].dbid]
    }
    for index in newEntries.indices where newEntries[index].artworkSHA256 == nil {
      newEntries[index].artworkSHA256 = computedHashes[newEntries[index].dbid]
    }
    return outcome
  }

  private static func keepDeferredArtworkChangesPending(
    newEntries: inout [SyncLedgerEntry], computedHashes: [UInt64: String],
    previousEntriesByDbid: [UInt64: SyncLedgerEntry]
  ) {
    for index in newEntries.indices {
      let dbid = newEntries[index].dbid
      guard let computed = computedHashes[dbid],
        let previous = previousEntriesByDbid[dbid],
        previous.artworkSHA256 != computed
      else { continue }
      newEntries[index].fileSize = previous.fileSize
      newEntries[index].fileModifiedAt = previous.fileModifiedAt
      newEntries[index].fileGenerationStamp = previous.fileGenerationStamp
      newEntries[index].contentSHA256 = previous.contentSHA256
      newEntries[index].artworkSHA256 = previous.artworkSHA256
      newEntries[index].transcodeProfile = previous.transcodeProfile
    }
  }

  private static func relinkArtworkImages(
    _ images: [ArtworkDatabaseImage], preserving links: [ArtworkDatabaseLink],
    in database: inout ITunesDatabase
  ) {
    var imagesByDbid: [UInt64: [ArtworkDatabaseImage]] = [:]
    var imageByDbidAndMhiiID: [UInt64: [UInt32: ArtworkDatabaseImage]] = [:]
    for image in images {
      imagesByDbid[image.trackDbid, default: []].append(image)
      imageByDbidAndMhiiID[image.trackDbid, default: [:]][image.mhiiID] = image
    }
    var linkByDbid: [UInt64: ArtworkDatabaseLink] = [:]
    for link in links where imageByDbidAndMhiiID[link.dbid]?[link.mhiiID] != nil {
      linkByDbid[link.dbid] = link
    }
    for index in database.tracks.indices {
      let dbid = database.tracks[index].dbid
      let artwork: ITDBTrackArtwork
      if let link = linkByDbid[dbid] {
        artwork = ITDBTrackArtwork(
          mhiiID: link.mhiiID, sizeBytes: link.sizeBytes, count: link.count)
      } else if let candidates = imagesByDbid[dbid], candidates.count == 1,
        let image = candidates.first
      {
        artwork = ITDBTrackArtwork(mhiiID: image.mhiiID, sizeBytes: image.sourceImageSize)
      } else {
        continue
      }
      guard database.tracks[index].artwork != artwork else { continue }
      database.tracks[index].artwork = artwork
    }
  }

  static func makeDBTrack(from track: LibraryTrack, ipodPath: String) -> ITDBTrack {
    func clean(_ s: String) -> String? {
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    var t = ITDBTrack()
    t.title = track.displayTitle
    t.artist = clean(track.artist)
    t.album = clean(track.album)
    t.albumArtist = clean(track.albumArtist)
    t.genre = clean(track.primaryGenre)
    t.composer = clean(track.composer)
    t.comment = clean(track.comment)
    t.sortTitle = SortNames.sortValue(display: t.title, explicit: clean(track.sortTitle))
    t.sortAlbum = SortNames.sortValue(display: t.album, explicit: clean(track.sortAlbum))
    t.sortArtist = SortNames.sortValue(display: t.artist, explicit: clean(track.sortArtist))
    t.sortAlbumArtist = SortNames.sortValue(
      display: t.albumArtist, explicit: clean(track.sortAlbumArtist))
    t.sortComposer = SortNames.sortValue(
      display: t.composer, explicit: clean(track.sortComposer))
    switch track.mediaKind {
    case .song:
      t.mediaKind = ITDBMediaKind.audio.rawValue
    case .audiobook:
      t.mediaKind = ITDBMediaKind.audiobook.rawValue
      t.rememberPlaybackPosition = true
      t.skipWhenShuffling = true
    case .podcast:
      t.mediaKind = ITDBMediaKind.podcast.rawValue
      t.rememberPlaybackPosition = true
      t.skipWhenShuffling = true
      t.timeReleased = track.releaseDate ?? releaseDate(forYear: track.year)
    }
    if let gapless = track.gapless {
      t.pregap = gapless.pregap
      t.postgap = gapless.postgap
      t.sampleCount = gapless.sampleCount
      t.gaplessData = gapless.gaplessData
      t.gaplessTrackFlag = true
    }
    if let gain = track.gainDB {
      t.soundcheck = LoudnessAnalyzer.soundcheckValue(gainDB: gain)
    }
    t.ipodPath = ipodPath
    t.sizeBytes = UInt32(clamping: track.sizeBytes)
    t.lengthMS = UInt32(clamping: track.durationMS)
    t.trackNumber = UInt32(clamping: track.trackNumber)
    t.trackCount = UInt32(clamping: track.trackCount)
    t.discNumber = UInt32(clamping: track.discNumber)
    t.discCount = UInt32(clamping: track.discCount)
    t.year = UInt32(clamping: track.year)
    t.compilation = track.compilation
    t.bitrate = UInt32(clamping: track.bitrate)
    t.samplerate = UInt16(clamping: track.samplerate)
    t.timeAdded = Date()
    t.timeModified = track.modificationDate ?? Date()
    let ext = track.url.pathExtension.lowercased()
    let codec = ITDBAudioCodec(fileExtension: ext)
    switch ext {
    case "wav":
      t.filetypeDescription = "WAV audio file"
    case "aif", "aiff":
      t.filetypeDescription = "AIFF audio file"
    default:
      t.filetypeDescription = codec.filetypeDescription
    }
    if let type2 = codec.binaryType2 { t.type2 = type2 }
    t.filetypeMarker = filetypeMarker(for: track.url.pathExtension)
    return t
  }

  /// When a library track carries only a release year, the mhit's released
  /// date resolves to midnight UTC on January 1 of that year.
  static func releaseDate(forYear year: Int) -> Date? {
    guard year > 0 else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = 1
    components.day = 1
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar.date(from: components)
  }

  static func filetypeMarker(for ext: String) -> UInt32 {
    var marker: UInt32 = 0
    let chars = Array(ext.uppercased().utf8)
    for i in 0..<4 {
      marker <<= 8
      marker |= UInt32(i < chars.count ? chars[i] : UInt8(ascii: " "))
    }
    return marker
  }

  static func folderDestination(for track: ITDBTrack, source: URL, in folder: URL) -> URL {
    let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension
    var stem: String
    let title = sanitize(track.title ?? "")
    let artist = sanitize(track.artist ?? "")
    if !title.isEmpty && !artist.isEmpty {
      stem = "\(artist) - \(title)"
    } else if !title.isEmpty {
      stem = title
    } else {
      stem = sanitize(source.deletingPathExtension().lastPathComponent)
      if stem.isEmpty { stem = "Track" }
    }
    stem = String(stem.prefix(120))

    var candidate = folder.appendingPathComponent("\(stem).\(ext)")
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent("\(stem) \(counter).\(ext)")
      counter += 1
    }
    return candidate
  }

  static func addTagsIfMissing(to url: URL, from track: ITDBTrack) async throws {
    guard LibraryAudioFormat(url: url)?.supportsMetadataEditing == true else { return }
    let fileTrack = await MetadataLoader.load(url: url)
    guard let reconciled = reconciledMetadataForLocalCopy(fileTrack, from: track) else { return }
    guard TrackMetadata(fileTrack).normalized != reconciled else { return }
    try TrackFileMetadataWriter.write(reconciled, artworkChange: .unchanged, to: url)
  }

  static func reconciledMetadataForLocalCopy(
    _ fileTrack: LibraryTrack, from track: ITDBTrack
  ) -> TrackMetadata? {
    let taggedTitle = track.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let deviceFilename =
      track.ipodPath?.split(separator: ":", omittingEmptySubsequences: true).last
      .map(String.init) ?? ""
    let title =
      taggedTitle.isEmpty ? (deviceFilename as NSString).deletingPathExtension : taggedTitle
    guard !title.isEmpty else { return nil }
    var metadata = TrackMetadata(fileTrack: fileTrack, databaseTrack: track)
    metadata.title = title
    return metadata.normalized
  }

  static func sanitize(_ s: String) -> String {
    var out = s
    for c in ["/", ":", "\\", "\0", "<", ">", "|", "\"", "?", "*"] {
      out = out.replacingOccurrences(of: c, with: "-")
    }
    out = out.components(separatedBy: .controlCharacters).joined()
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    while out.hasPrefix(".") { out = String(out.dropFirst()) }
    while out.hasSuffix(".") || out.hasSuffix(" ") { out = String(out.dropLast()) }
    let stem =
      out.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init) ?? out
    if reservedFATNames.contains(stem.uppercased()) { out = "_" + out }
    return out
  }

  private static let reservedFATNames: Set<String> = {
    var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
    for n in 1...9 {
      names.insert("COM\(n)")
      names.insert("LPT\(n)")
    }
    return names
  }()
}
