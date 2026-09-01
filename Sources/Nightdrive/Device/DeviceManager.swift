import AppKit
import Foundation
import Observation

struct IpodDevice: Identifiable, Sendable {
  var id: URL { volumeURL }
  let volumeURL: URL
  var databaseID: UInt64? = nil
  var name: String
  var modelDescription: String
  var modelNumber: String?
  var family: IpodDeviceFamily = .thirdGenerationOrLater
  var totalCapacity: Int64
  var availableCapacity: Int64
  private(set) var tracks: [ITDBTrack] = []
  var playlists: [ITDBPlaylist] = []
  var databaseError: String?
  var writeError: String?
  private(set) var derivedDataRevision: UInt64 = 0
  private(set) var trackDurationMS = 0
  private(set) var usedByAudioBytes: Int64 = 0

  init(
    volumeURL: URL,
    databaseID: UInt64? = nil,
    name: String,
    modelDescription: String,
    totalCapacity: Int64,
    availableCapacity: Int64,
    tracks: [ITDBTrack] = [],
    databaseError: String? = nil,
    writeError: String? = nil
  ) {
    self.volumeURL = volumeURL
    self.databaseID = databaseID
    self.name = name
    self.modelDescription = modelDescription
    self.totalCapacity = totalCapacity
    self.availableCapacity = availableCapacity
    self.databaseError = databaseError
    self.writeError = writeError
    installTracks(tracks)
  }

  mutating func installTracks(_ tracks: [ITDBTrack]) {
    self.tracks = tracks
    let totals = tracks.reduce(into: (durationMS: 0, sizeBytes: Int64(0))) {
      $0.durationMS += Int($1.lengthMS)
      $0.sizeBytes += Int64($1.sizeBytes)
    }
    trackDurationMS = totals.durationMS
    usedByAudioBytes = totals.sizeBytes
  }

  mutating func assignDerivedDataRevision(_ revision: UInt64) {
    derivedDataRevision = revision
  }
}

struct DeviceTrackMetadataEdit: Sendable {
  let dbid: UInt64
  let metadata: TrackMetadata
  let artworkChange: ArtworkChange

  init(
    dbid: UInt64,
    metadata: TrackMetadata,
    artworkChange: ArtworkChange = .unchanged
  ) {
    self.dbid = dbid
    self.metadata = metadata
    self.artworkChange = artworkChange
  }
}

struct DeviceMetadataRollbackFailure {
  let url: URL
  let error: Error
}

enum DeviceMetadataMutationError: LocalizedError {
  case rollbackFailed(operation: Error, failures: [DeviceMetadataRollbackFailure])

  var errorDescription: String? {
    switch self {
    case .rollbackFailed(let operation, let failures):
      let joinedDetails = localizedDetails(failures)
      return String(
        localized:
          "The iPod metadata update failed (\(operation.localizedDescription)), and the original audio could not be fully restored (\(joinedDetails))."
      )
    }
  }

  private func localizedDetails(_ failures: [DeviceMetadataRollbackFailure]) -> String {
    failures.map {
      String(localized: "\($0.url.lastPathComponent): \($0.error.localizedDescription)")
    }.joined(separator: "; ")
  }
}

/// Watches /Volumes for iPods and loads their databases.
@Observable
@MainActor
final class DeviceManager {
  private(set) var devices: [IpodDevice] = []
  private(set) var ejectError: String?

  @ObservationIgnored var onDevicesConnected: (([IpodDevice]) -> Void)?

  private let extraVolumes: [URL]
  @ObservationIgnored private var refreshTask: Task<[IpodDevice], Never>?
  @ObservationIgnored private var refreshGeneration = 0
  @ObservationIgnored private var reloadGenerations: [URL: UInt64] = [:]
  @ObservationIgnored private var ejectInvocations: [URL: UUID] = [:]
  @ObservationIgnored private var ejectFailures: [URL: String] = [:]
  @ObservationIgnored private var ejectFailureOrder: [URL] = []
  @ObservationIgnored private var nextDerivedDataRevision: UInt64 = 0
  @ObservationIgnored private let metadataModificationDate: @Sendable () -> Date
  @ObservationIgnored private let metadataDatabaseWriter: @Sendable (IpodFileSystem, ITunesDatabase) throws -> Void
  @ObservationIgnored private let metadataDatabaseVerificationReader:
    @Sendable (IpodFileSystem) throws -> ITunesDatabase
  @ObservationIgnored private let metadataRollbackWriter: @Sendable (Data, URL) throws -> Void
  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    @ObservationIgnored private var developmentScanRoots: [URL] = []
    @ObservationIgnored private var developmentCapacityOverrides: [URL: Int64?] = [:]
    @ObservationIgnored private var developmentWriteErrors: [URL: String?] = [:]
  #endif

  convenience init(
    metadataDatabaseWriter: @escaping @Sendable (IpodFileSystem, ITunesDatabase) throws -> Void = {
      try $0.writeDatabase($1)
    },
    metadataDatabaseVerificationReader:
      @escaping @Sendable (IpodFileSystem) throws -> ITunesDatabase = {
        try $0.readDatabase()
      }
  ) {
    self.init(
      metadataModificationDate: { Date() }, metadataDatabaseWriter: metadataDatabaseWriter,
      metadataDatabaseVerificationReader: metadataDatabaseVerificationReader)
  }

  init(
    metadataModificationDate: @escaping @Sendable () -> Date,
    metadataDatabaseWriter: @escaping @Sendable (IpodFileSystem, ITunesDatabase) throws -> Void,
    metadataDatabaseVerificationReader:
      @escaping @Sendable (IpodFileSystem) throws -> ITunesDatabase = {
        try $0.readDatabase()
      },
    metadataRollbackWriter: @escaping @Sendable (Data, URL) throws -> Void = {
      try $0.write(to: $1, options: .atomic)
    }
  ) {
    self.metadataModificationDate = metadataModificationDate
    self.metadataDatabaseWriter = metadataDatabaseWriter
    self.metadataDatabaseVerificationReader = metadataDatabaseVerificationReader
    self.metadataRollbackWriter = metadataRollbackWriter
    extraVolumes = (ProcessInfo.processInfo.environment["NIGHTDRIVE_EXTRA_VOLUMES"] ?? "")
      .split(separator: ":")
      .map { URL(fileURLWithPath: String($0), isDirectory: true) }

    let center = NSWorkspace.shared.notificationCenter
    for name in [
      NSWorkspace.didMountNotification,
      NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ] {
      center.addObserver(
        forName: name, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.refresh() }
      }
    }
    Task { await refresh() }
  }

  func refresh() async {
    refreshGeneration &+= 1
    let generation = refreshGeneration
    let reloadBaseline = reloadGenerations
    refreshTask?.cancel()
    var extraVolumes = extraVolumes
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      extraVolumes += developmentScanRoots
    #endif
    let scanRoots = extraVolumes
    let task = Task.detached(priority: .utility) {
      var candidates =
        FileManager.default.mountedVolumeURLs(
          includingResourceValuesForKeys: [.volumeNameKey],
          options: [.skipHiddenVolumes]) ?? []
      candidates += scanRoots
      var found: [IpodDevice] = []
      for url in candidates where !Task.isCancelled && IpodFileSystem.isIpodVolume(url) {
        found.append(Self.loadDevice(at: url))
      }
      return found
    }
    refreshTask = task
    let found = await task.value
    guard generation == refreshGeneration, !Task.isCancelled else { return }
    let previousIDs = Set(devices.map(\.id))
    devices = found.map { loaded in
      guard reloadGenerations[loaded.id, default: 0] != reloadBaseline[loaded.id, default: 0],
        let current = devices.first(where: { $0.id == loaded.id })
      else { return installingRevision(on: loaded) }
      return current
    }.sorted { $0.name < $1.name }
    refreshTask = nil
    let connected = devices.filter { !previousIDs.contains($0.id) }
    if !connected.isEmpty { onDevicesConnected?(connected) }
  }

  func reload(_ device: IpodDevice) async {
    let url = device.volumeURL
    reloadGenerations[url, default: 0] &+= 1
    let generation = reloadGenerations[url, default: 0]
    let loaded = await Task.detached(priority: .utility) {
      Self.loadDevice(at: url)
    }.value
    guard reloadGenerations[url] == generation else { return }
    guard device.databaseID == nil || loaded.databaseID == device.databaseID else {
      await refresh()
      return
    }
    if let index = devices.firstIndex(where: { $0.id == device.id }) {
      devices[index] = installingRevision(on: loaded)
    }
  }

  func updateMetadata(
    for track: ITDBTrack,
    on device: IpodDevice,
    from baseline: TrackMetadata,
    to metadata: TrackMetadata,
    artworkChange: ArtworkChange
  ) async throws {
    let changes = TrackMetadataChanges(differenceFrom: baseline, to: metadata)
    if changes.isEmpty, case .unchanged = artworkChange { return }
    try await updateMetadata(
      [
        DeviceTrackMetadataEdit(
          dbid: track.dbid, metadata: baseline, artworkChange: artworkChange)
      ],
      on: device,
      applying: changes)
  }

  func updateMetadata(
    for edits: [DeviceTrackMetadataEdit],
    on device: IpodDevice,
    applying changes: TrackMetadataChanges
  ) async throws {
    guard !edits.isEmpty, !changes.isEmpty else { return }
    try await updateMetadata(edits, on: device, applying: changes)
  }

  private func updateMetadata(
    _ edits: [DeviceTrackMetadataEdit],
    on device: IpodDevice,
    applying changes: TrackMetadataChanges
  ) async throws {
    let volumeURL = device.volumeURL
    let expectedDatabaseID = device.databaseID
    let modificationDate = metadataModificationDate
    let databaseWriter = metadataDatabaseWriter
    let databaseVerificationReader = metadataDatabaseVerificationReader
    let rollbackWriter = metadataRollbackWriter
    try await Task.detached(priority: .userInitiated) {
      let deviceLock = try await ScopedAdvisoryLock.acquire(
        for: volumeURL, namespace: .device)
      defer { deviceLock.unlock() }
      let fs = IpodFileSystem(volumeURL: volumeURL)
      var database = try fs.readDatabase()
      try fs.validateDeviceIdentity(expectedDatabaseID, database: database)
      try fs.recoverInterruptedMutations(database: database)
      let changesArtwork = edits.contains { edit in
        switch edit.artworkChange {
        case .unchanged: false
        case .replace, .remove: true
        }
      }
      if changesArtwork {
        switch ArtworkFormats.resolve(fileSystem: fs) {
        case .unknown:
          throw DeviceArtworkMutationError.unsupportedDevice
        case .specs(let specs) where !specs.isEmpty:
          guard !FileManager.default.fileExists(atPath: fs.compressedDatabaseURL.path) else {
            throw DeviceArtworkMutationError.unsupportedDevice
          }
          try await DeviceArtworkMutation.apply(
            edits: edits, changes: changes, initialDatabase: database,
            specs: specs, fileSystem: fs, databaseWriter: databaseWriter,
            databaseVerificationReader: databaseVerificationReader,
            modificationDate: modificationDate)
          return
        case .specs:
          break
        }
      }
      var originals: [(dbid: UInt64, url: URL, data: Data)] = []
      var databaseWriteAttempted = false
      do {
        for edit in edits {
          guard let index = database.tracks.firstIndex(where: { $0.dbid == edit.dbid }) else {
            throw ITunesDBError.notFound("A selected track is no longer on the iPod")
          }
          guard let path = database.tracks[index].ipodPath else {
            throw ITunesDBError.notFound("A selected track has no file path")
          }
          let previousModificationTime = database.tracks[index].timeModified
          let fileURL = try fs.validatedMusicFileURL(forIpodPath: path)
          originals.append(
            (edit.dbid, fileURL, try Data(contentsOf: fileURL, options: .mappedIfSafe)))
          let fileTrack = await MetadataLoader.load(url: fileURL)
          let currentMetadata = TrackMetadata(
            fileTrack: fileTrack, databaseTrack: database.tracks[index])
          let metadata = changes.applying(to: currentMetadata)
          try TrackFileMetadataWriter.write(
            metadata, artworkChange: edit.artworkChange, to: fileURL)
          metadata.applying(to: &database.tracks[index])
          database.tracks[index].timeModified = modificationDate()
          Self.advanceMetadataCommitMarker(
            on: &database.tracks[index], after: previousModificationTime,
            timezoneShift: database.timezoneShift)
          guard
            let fileSize = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
          else {
            throw CocoaError(.fileReadUnknown)
          }
          database.tracks[index].sizeBytes = UInt32(clamping: fileSize)
        }
        databaseWriteAttempted = true
        try databaseWriter(fs, database)
      } catch {
        let operationError = error
        let originalsToRestore: [(dbid: UInt64, url: URL, data: Data)]
        if !databaseWriteAttempted {
          originalsToRestore = originals
        } else if let currentDatabase = Self.verificationDatabaseAfterFailedWrite(
          fs, reader: databaseVerificationReader)
        {
          originalsToRestore = originals.filter { original in
            guard let intended = database.tracks.first(where: { $0.dbid == original.dbid }),
              !Self.database(currentDatabase, containsMetadataFrom: intended)
            else { return false }
            return true
          }
        } else {
          originalsToRestore = []
        }
        let rollbackFailures = Self.restoreOriginalAudio(
          originalsToRestore, using: rollbackWriter)
        if !rollbackFailures.isEmpty {
          throw DeviceMetadataMutationError.rollbackFailed(
            operation: operationError, failures: rollbackFailures)
        }
        throw operationError
      }
    }.value
    await reload(device)
  }

  func delete(_ track: ITDBTrack, from device: IpodDevice) async throws {
    let volumeURL = device.volumeURL
    let expectedDatabaseID = device.databaseID
    let dbid = track.dbid
    try await Task.detached(priority: .userInitiated) {
      let deviceLock = try await ScopedAdvisoryLock.acquire(
        for: volumeURL, namespace: .device)
      defer { deviceLock.unlock() }
      let fs = IpodFileSystem(volumeURL: volumeURL)
      let originalDatabase = try fs.readDatabase()
      try fs.validateDeviceIdentity(expectedDatabaseID, database: originalDatabase)
      try fs.recoverInterruptedMutations(database: originalDatabase)
      guard let storedTrack = originalDatabase.tracks.first(where: { $0.dbid == dbid }) else {
        throw ITunesDBError.notFound("Track is no longer on the iPod")
      }
      guard let path = storedTrack.ipodPath else {
        throw ITunesDBError.notFound("Track has no file path")
      }
      let fileURL = try fs.validatedMusicFileURL(forIpodPath: path)
      let transaction = try IpodDeleteTransaction(fileSystem: fs)
      do {
        try transaction.stage(source: fileURL, dbid: dbid, ipodPath: path)
      } catch {
        do {
          try fs.recoverInterruptedDeletions(database: originalDatabase)
        } catch let recoveryError {
          NightdriveLog.device.error(
            "Recovering interrupted deletions failed after a failed stage: \(recoveryError.localizedDescription, privacy: .public)"
          )
        }
        throw error
      }

      var updatedDatabase = originalDatabase
      updatedDatabase.tracks.removeAll { $0.dbid == dbid }
      for index in updatedDatabase.playlists.indices {
        updatedDatabase.playlists[index].memberDbids.removeAll { $0 == dbid }
      }
      do {
        try fs.writeDatabase(updatedDatabase)
        transaction.finish()
      } catch {
        Self.recoverInterruptedDeletionsAfterFailedWrite(fs)
        throw error
      }
    }.value
    await reload(device)
  }

  nonisolated private static func verificationDatabaseAfterFailedWrite(
    _ fs: IpodFileSystem,
    reader: (IpodFileSystem) throws -> ITunesDatabase = { try $0.readDatabase() }
  ) -> ITunesDatabase? {
    do {
      return try reader(fs)
    } catch {
      NightdriveLog.device.error(
        "Could not re-read the device database after a failed write: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  nonisolated private static func recoverInterruptedDeletionsAfterFailedWrite(_ fs: IpodFileSystem) {
    guard let currentDatabase = verificationDatabaseAfterFailedWrite(fs) else { return }
    do {
      try fs.recoverInterruptedDeletions(database: currentDatabase)
    } catch {
      NightdriveLog.device.error(
        "Recovering interrupted deletions failed after a failed database write: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  nonisolated static func loadDevice(at url: URL) -> IpodDevice {
    let values: URLResourceValues?
    do {
      values = try url.resourceValues(forKeys: [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .isVolumeKey,
      ])
    } catch {
      values = nil
      NightdriveLog.device.error(
        "Could not read volume metadata for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    let fs = IpodFileSystem(volumeURL: url)
    let isRealVolume = values?.isVolume ?? false
    var device = IpodDevice(
      volumeURL: url,
      name: (isRealVolume ? values?.volumeName : url.lastPathComponent)
        ?? url.lastPathComponent,
      modelDescription: fs.modelDescription(),
      totalCapacity: Int64(values?.volumeTotalCapacity ?? 0),
      availableCapacity: Int64(values?.volumeAvailableCapacity ?? 0))
    device.modelNumber = fs.modelNumber()
    device.family = fs.deviceFamily()

    let loaded: Result<ITunesDatabase, Error> = Result { try fs.readDatabase() }
    switch loaded {
    case .success(let db):
      if FileManager.default.fileExists(atPath: fs.databaseURL.path)
        || FileManager.default.fileExists(atPath: fs.compressedDatabaseURL.path)
      {
        device.databaseID = db.databaseID
      }
      device.installTracks(db.tracks)
      device.playlists = db.playlists
      do {
        try IpodDatabaseSupport(fileSystem: fs).validateForWriting()
      } catch {
        device.writeError = error.localizedDescription
      }
    case .failure(let error):
      device.databaseError = error.localizedDescription
    }
    return device
  }

  private func installingRevision(on device: IpodDevice) -> IpodDevice {
    nextDerivedDataRevision &+= 1
    var revised = device
    revised.assignDerivedDataRevision(nextDerivedDataRevision)
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      revised = applyingDevelopmentOverrides(to: revised)
    #endif
    return revised
  }

  nonisolated private static func database(
    _ database: ITunesDatabase, containsMetadataFrom intended: ITDBTrack
  ) -> Bool {
    guard let current = database.tracks.first(where: { $0.dbid == intended.dbid }) else {
      return false
    }
    return TrackMetadata(current).normalized == TrackMetadata(intended).normalized
      && current.sizeBytes == intended.sizeBytes
      && ITunesDBWriter.macTime(
        current.timeModified, timezoneShift: database.timezoneShift)
        == ITunesDBWriter.macTime(
          intended.timeModified, timezoneShift: database.timezoneShift)
  }

  nonisolated private static func restoreOriginalAudio(
    _ originals: [(dbid: UInt64, url: URL, data: Data)],
    using writer: @Sendable (Data, URL) throws -> Void
  ) -> [DeviceMetadataRollbackFailure] {
    var failures: [DeviceMetadataRollbackFailure] = []
    for original in originals {
      do {
        try writer(original.data, original.url)
      } catch {
        failures.append(DeviceMetadataRollbackFailure(url: original.url, error: error))
      }
    }
    return failures
  }

  /// `timeModified` is the database-backed commit marker for edits whose
  /// grouping, BPM, lyrics, or embedded artwork otherwise change only the
  /// audio file. Generate the nonce in iTunesDB's serialized UInt32 Mac-time
  /// domain so rapid edits and the maximum representable time stay distinct.
  nonisolated static func advanceMetadataCommitMarker(
    on track: inout ITDBTrack, after previous: Date?, timezoneShift: Int
  ) {
    let previousMarker = ITunesDBWriter.macTime(previous, timezoneShift: timezoneShift)
    let intendedMarker = ITunesDBWriter.macTime(
      track.timeModified, timezoneShift: timezoneShift)
    guard intendedMarker <= previousMarker else { return }
    let nextMarker: UInt32 = previousMarker == UInt32.max ? 1 : previousMarker + 1
    let unixTime =
      Int64(nextMarker) - Int64(ITunesDBWriter.macEpochOffset) - Int64(timezoneShift)
    track.timeModified = Date(timeIntervalSince1970: TimeInterval(unixTime))
  }

  func eject(
    _ device: IpodDevice,
    using ejector: @escaping @Sendable (URL) throws -> Void = {
      try NSWorkspace.shared.unmountAndEjectDevice(at: $0)
    }
  ) async {
    let url = device.volumeURL
    let volumeKey = url.standardizedFileURL
    let invocation = UUID()
    ejectInvocations[volumeKey] = invocation
    do {
      try await Task.detached(priority: .userInitiated) {
        try ejector(url)
      }.value
      guard ejectInvocations[volumeKey] == invocation else { return }
      ejectInvocations[volumeKey] = nil
      clearEjectFailure(for: volumeKey)
    } catch {
      guard ejectInvocations[volumeKey] == invocation else { return }
      ejectInvocations[volumeKey] = nil
      recordEjectFailure(
        "\(device.name) could not be ejected: \(error.localizedDescription)",
        for: volumeKey)
    }
  }

  func dismissEjectError() {
    guard let volumeKey = ejectFailureOrder.first else {
      ejectError = nil
      return
    }
    ejectFailures[volumeKey] = nil
    ejectFailureOrder.removeFirst()
    publishNextEjectFailure()
  }

  private func recordEjectFailure(_ message: String, for volumeKey: URL) {
    if ejectFailures[volumeKey] == nil {
      ejectFailureOrder.append(volumeKey)
    }
    ejectFailures[volumeKey] = message
    publishNextEjectFailure()
  }

  private func clearEjectFailure(for volumeKey: URL) {
    guard ejectFailures.removeValue(forKey: volumeKey) != nil else { return }
    ejectFailureOrder.removeAll { $0 == volumeKey }
    publishNextEjectFailure()
  }

  private func publishNextEjectFailure() {
    ejectError = ejectFailureOrder.first.flatMap { ejectFailures[$0] }
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    func addDevelopmentScanRoot(_ url: URL) async {
      guard !developmentScanRoots.contains(url) else { return }
      developmentScanRoots.append(url)
      await refresh()
      var attempts = 0
      while !devices.contains(where: { $0.volumeURL == url }), attempts < 40 {
        attempts += 1
        await Task.pause(for: .milliseconds(50))
      }
    }

    func removeAllDevelopmentScanRoots() async {
      let hadState =
        !developmentScanRoots.isEmpty || !developmentCapacityOverrides.isEmpty
        || !developmentWriteErrors.isEmpty
      guard hadState else { return }
      developmentScanRoots.removeAll()
      developmentCapacityOverrides.removeAll()
      developmentWriteErrors.removeAll()
      await refresh()
    }

    var developmentScanRootURLs: [URL] { developmentScanRoots }

    var hasDevelopmentState: Bool {
      !developmentScanRoots.isEmpty || !developmentCapacityOverrides.isEmpty
        || !developmentWriteErrors.isEmpty
    }

    func setDevelopmentAvailableCapacity(_ bytes: Int64?, for volumeURL: URL) async {
      developmentCapacityOverrides[volumeURL] = bytes
      await reloadIfPresent(volumeURL)
    }

    func setDevelopmentWriteError(_ message: String?, for volumeURL: URL) async {
      developmentWriteErrors[volumeURL] = message
      await reloadIfPresent(volumeURL)
    }

    private func reloadIfPresent(_ volumeURL: URL) async {
      guard let device = devices.first(where: { $0.volumeURL == volumeURL }) else { return }
      await reload(device)
    }

    private func applyingDevelopmentOverrides(to device: IpodDevice) -> IpodDevice {
      var revised = device
      if let capacity = developmentCapacityOverrides[device.volumeURL] ?? nil {
        revised.availableCapacity = capacity
      }
      if let message = developmentWriteErrors[device.volumeURL] ?? nil {
        revised.writeError = message
      }
      return revised
    }
  #endif
}
