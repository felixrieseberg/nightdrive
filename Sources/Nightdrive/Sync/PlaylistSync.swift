import Foundation

enum PlaylistSyncDisplayStatus: Equatable, Sendable {
  case synced
  case notOnDevice
  case tracksUnavailable(Int)
  case syncDisabled

  var label: String {
    switch self {
    case .synced: String(localized: "Synced")
    case .notOnDevice: String(localized: "Not on iPod")
    case .tracksUnavailable(let count):
      count == 1
        ? String(localized: "1 song unavailable")
        : String(localized: "\(count) songs unavailable")
    case .syncDisabled: String(localized: "Sync off")
    }
  }
}

enum PlaylistSyncAction: Equatable, Sendable {
  case createOnDevice(LocalPlaylist)
  case updateOnDevice(localID: UUID, persistentID: UInt64, name: String, memberDbids: [UInt64])
  case deleteOnDevice(persistentID: UInt64, name: String)
  case createInLibrary(name: String, trackIDs: [TrackID], persistentID: UInt64)
  case updateInLibrary(localID: UUID, name: String, trackIDs: [TrackID])
  case deleteInLibrary(localID: UUID, name: String)
  case conflictResolved(name: String, detail: String)
}

struct OnTheGoImport: Equatable, Sendable {
  var name: String
  var trackIDs: [TrackID]
}

struct PlaylistTrackLinks: Sendable {
  var dbidForTrackID: [TrackID: UInt64] = [:]
  var trackIDForDbid: [UInt64: TrackID] = [:]
  var urlForDbid: [UInt64: URL] = [:]

  init() {}

  init(entries: [SyncLedgerEntry], libraryFolder: URL) {
    for entry in entries where !entry.relativePath.isEmpty {
      let url = libraryFolder.appendingPathComponent(entry.relativePath).standardizedFileURL
      let trackID = TrackID(url: url)
      if dbidForTrackID[trackID] == nil { dbidForTrackID[trackID] = entry.dbid }
      if trackIDForDbid[entry.dbid] == nil {
        trackIDForDbid[entry.dbid] = trackID
        urlForDbid[entry.dbid] = url
      }
    }
  }

  func dbids(forTrackIDs trackIDs: [TrackID]) -> (dbids: [UInt64], skipped: Int) {
    var dbids: [UInt64] = []
    var skipped = 0
    for trackID in trackIDs {
      if let dbid = dbidForTrackID[trackID] {
        dbids.append(dbid)
      } else {
        skipped += 1
      }
    }
    return (dbids, skipped)
  }

  func trackIDs(forDbids dbids: [UInt64]) -> (trackIDs: [TrackID], dropped: Int) {
    var trackIDs: [TrackID] = []
    var seen = Set<TrackID>()
    var dropped = 0
    for dbid in dbids {
      guard let trackID = trackIDForDbid[dbid] else {
        dropped += 1
        continue
      }
      if seen.insert(trackID).inserted { trackIDs.append(trackID) }
    }
    return (trackIDs, dropped)
  }
}

struct PlaylistSyncPlan: Sendable {
  var deviceActions: [PlaylistSyncAction] = []
  var libraryActions: [PlaylistSyncAction] = []
  var links: [SyncPlaylistLink] = []
  var pendingLibraryLinks: [SyncPlaylistLink] = []
  var notes: [String] = []

  var allActions: [PlaylistSyncAction] { deviceActions + libraryActions }
  var isEmpty: Bool { deviceActions.isEmpty && libraryActions.isEmpty }
}

extension SyncEngine {
  static func makePlaylistPlan(
    local: [LocalPlaylist],
    device: [ITDBPlaylist],
    links: [SyncPlaylistLink],
    trackLinks: PlaylistTrackLinks
  ) -> PlaylistSyncPlan {
    var plan = PlaylistSyncPlan()

    var localByID: [UUID: LocalPlaylist] = [:]
    for playlist in local where localByID[playlist.id] == nil {
      localByID[playlist.id] = playlist
    }
    var deviceByPID: [UInt64: ITDBPlaylist] = [:]
    for playlist in device where deviceByPID[playlist.persistentID] == nil {
      deviceByPID[playlist.persistentID] = playlist
    }

    var claimedLocal = Set<UUID>()
    var claimedDevice = Set<UInt64>()

    for link in links {
      let localPlaylist = claimedLocal.contains(link.localID) ? nil : localByID[link.localID]
      let devicePlaylist =
        claimedDevice.contains(link.persistentID) ? nil : deviceByPID[link.persistentID]
      if let localPlaylist { claimedLocal.insert(localPlaylist.id) }
      if let devicePlaylist { claimedDevice.insert(devicePlaylist.persistentID) }

      if let localPlaylist, !localPlaylist.syncEnabled {
        plan.links.append(link)
        continue
      }

      switch (localPlaylist, devicePlaylist) {
      case (nil, nil):
        continue

      case (let localPlaylist?, let devicePlaylist?):
        merge(
          local: localPlaylist, device: devicePlaylist,
          baseName: link.name, baseMembers: link.memberDbids,
          trackLinks: trackLinks, into: &plan)

      case (let localPlaylist?, nil):
        let resolved = trackLinks.dbids(forTrackIDs: localPlaylist.trackIDs)
        let localChanged =
          localPlaylist.name != link.name || resolved.dbids != link.memberDbids
        if localChanged {
          plan.deviceActions.append(.createOnDevice(localPlaylist))
          noteSkipped(resolved.skipped, playlist: localPlaylist.name, into: &plan)
          plan.libraryActions.append(
            .conflictResolved(
              name: localPlaylist.name,
              detail: String(
                localized:
                  "deleted on the iPod but changed locally; recreated on the iPod")))
        } else {
          plan.libraryActions.append(
            .deleteInLibrary(localID: localPlaylist.id, name: localPlaylist.name))
        }

      case (nil, let devicePlaylist?):
        let deviceChanged =
          devicePlaylist.name != link.name || devicePlaylist.memberDbids != link.memberDbids
        if deviceChanged {
          appendCreateInLibrary(devicePlaylist, trackLinks: trackLinks, into: &plan)
          plan.libraryActions.append(
            .conflictResolved(
              name: devicePlaylist.name,
              detail: String(localized: "deleted locally but changed on the iPod; re-imported")))
        } else {
          plan.deviceActions.append(
            .deleteOnDevice(persistentID: devicePlaylist.persistentID, name: devicePlaylist.name))
        }
      }
    }

    for localPlaylist in local where !claimedLocal.contains(localPlaylist.id) {
      guard
        let devicePlaylist = device.first(where: {
          !claimedDevice.contains($0.persistentID) && $0.name == localPlaylist.name
        })
      else { continue }
      claimedLocal.insert(localPlaylist.id)
      claimedDevice.insert(devicePlaylist.persistentID)
      guard localPlaylist.syncEnabled else { continue }
      merge(
        local: localPlaylist, device: devicePlaylist,
        baseName: localPlaylist.name, baseMembers: [],
        trackLinks: trackLinks, into: &plan)
    }

    for localPlaylist in local
    where !claimedLocal.contains(localPlaylist.id) && localPlaylist.syncEnabled {
      plan.deviceActions.append(.createOnDevice(localPlaylist))
      let resolved = trackLinks.dbids(forTrackIDs: localPlaylist.trackIDs)
      noteSkipped(resolved.skipped, playlist: localPlaylist.name, into: &plan)
    }

    for devicePlaylist in device where !claimedDevice.contains(devicePlaylist.persistentID) {
      appendCreateInLibrary(devicePlaylist, trackLinks: trackLinks, into: &plan)
    }

    return plan
  }

  private static func merge(
    local: LocalPlaylist, device: ITDBPlaylist,
    baseName: String, baseMembers: [UInt64],
    trackLinks: PlaylistTrackLinks, into plan: inout PlaylistSyncPlan
  ) {
    let resolved = trackLinks.dbids(forTrackIDs: local.trackIDs)
    noteSkipped(resolved.skipped, playlist: local.name, into: &plan)
    let localMembers = resolved.dbids
    let deviceMembers = device.memberDbids

    let localNameChanged = local.name != baseName
    let deviceNameChanged = device.name != baseName
    var conflictDetails: [String] = []

    let resolvedName: String
    if localNameChanged && deviceNameChanged && local.name != device.name {
      resolvedName = local.name
      conflictDetails.append(
        String(
          localized:
            "renamed on both sides (\"\(local.name)\" here, \"\(device.name)\" on the iPod); kept the local name"))
    } else if localNameChanged {
      resolvedName = local.name
    } else {
      resolvedName = device.name
    }

    let resolvedMembers: [UInt64]
    if localMembers != baseMembers && deviceMembers != baseMembers
      && localMembers != deviceMembers
    {
      var known = Set(baseMembers)
      known.formUnion(localMembers)
      var appended: [UInt64] = []
      for dbid in deviceMembers where !known.contains(dbid) {
        known.insert(dbid)
        appended.append(dbid)
      }
      resolvedMembers = localMembers + appended
      if appended.isEmpty {
        conflictDetails.append(String(localized: "edited on both sides; kept the local version"))
      } else if appended.count == 1 {
        conflictDetails.append(
          String(
            localized:
              "edited on both sides; kept the local order and appended 1 song added on the iPod"))
      } else {
        conflictDetails.append(
          String(
            localized:
              "edited on both sides; kept the local order and appended \(appended.count) songs added on the iPod"))
      }
    } else if localMembers != baseMembers {
      resolvedMembers = localMembers
    } else {
      resolvedMembers = deviceMembers
    }

    if !conflictDetails.isEmpty {
      plan.libraryActions.append(
        .conflictResolved(name: resolvedName, detail: conflictDetails.joined(separator: "; ")))
    }

    if resolvedName != device.name || resolvedMembers != device.memberDbids {
      plan.deviceActions.append(
        .updateOnDevice(
          localID: local.id, persistentID: device.persistentID,
          name: resolvedName, memberDbids: resolvedMembers))
    }

    let mapped = trackLinks.trackIDs(forDbids: resolvedMembers)
    if mapped.dropped > 0 {
      if mapped.dropped == 1 {
        plan.notes.append(
          String(
            localized:
              "\(resolvedName): 1 song on the iPod could not be matched to a library file and was left out locally."))
      } else {
        plan.notes.append(
          String(
            localized:
              "\(resolvedName): \(mapped.dropped) songs on the iPod could not be matched to library files and were left out locally."
          ))
      }
    }
    var newTrackIDs = mapped.trackIDs
    var seen = Set(newTrackIDs)
    for trackID in local.trackIDs where trackLinks.dbidForTrackID[trackID] == nil {
      if seen.insert(trackID).inserted { newTrackIDs.append(trackID) }
    }
    if resolvedName != local.name || newTrackIDs != local.trackIDs {
      plan.libraryActions.append(
        .updateInLibrary(localID: local.id, name: resolvedName, trackIDs: newTrackIDs))
    }

    plan.links.append(
      SyncPlaylistLink(
        localID: local.id, persistentID: device.persistentID,
        name: resolvedName, memberDbids: resolvedMembers))
  }

  private static func appendCreateInLibrary(
    _ devicePlaylist: ITDBPlaylist, trackLinks: PlaylistTrackLinks,
    into plan: inout PlaylistSyncPlan
  ) {
    let mapped = trackLinks.trackIDs(forDbids: devicePlaylist.memberDbids)
    if mapped.dropped > 0 {
      if mapped.dropped == 1 {
        plan.notes.append(
          String(
            localized:
              "\(devicePlaylist.name): 1 song on the iPod could not be matched to a library file and was left out locally."
          ))
      } else {
        plan.notes.append(
          String(
            localized:
              "\(devicePlaylist.name): \(mapped.dropped) songs on the iPod could not be matched to library files and were left out locally."
          ))
      }
    }
    plan.libraryActions.append(
      .createInLibrary(
        name: devicePlaylist.name, trackIDs: mapped.trackIDs,
        persistentID: devicePlaylist.persistentID))
    plan.pendingLibraryLinks.append(
      SyncPlaylistLink(
        localID: UUID(), persistentID: devicePlaylist.persistentID,
        name: devicePlaylist.name, memberDbids: devicePlaylist.memberDbids))
  }

  private static func noteSkipped(
    _ skipped: Int, playlist name: String, into plan: inout PlaylistSyncPlan
  ) {
    guard skipped > 0 else { return }
    if skipped == 1 {
      plan.notes.append(String(localized: "\(name): 1 song not on the iPod was skipped."))
    } else {
      plan.notes.append(String(localized: "\(name): \(skipped) songs not on the iPod were skipped."))
    }
  }

  static func writePlaylistLinks(
    _ links: [SyncPlaylistLink], databaseID: UInt64, libraryFolder: URL
  ) async throws {
    let ledgerLock = try await ScopedAdvisoryLock.acquire(
      for: libraryFolder, namespace: .library)
    defer { ledgerLock.unlock() }
    try SyncLedgerStore.replacePlaylistLinks(links, for: databaseID, libraryFolder: libraryFolder)
  }

  static func writeDeviceSettings(
    _ settings: SyncDeviceSettings, databaseID: UInt64, libraryFolder: URL
  ) async throws {
    let ledgerLock = try await ScopedAdvisoryLock.acquire(
      for: libraryFolder, namespace: .library)
    defer { ledgerLock.unlock() }
    try SyncLedgerStore.replaceDeviceSettings(
      settings, for: databaseID, libraryFolder: libraryFolder)
  }

  static func removeOnTheGoFiles(_ files: [URL], deviceVolume: URL) async {
    guard !files.isEmpty else { return }
    guard
      let lock = try? await ScopedAdvisoryLock.acquire(for: deviceVolume, namespace: .device)
    else { return }
    defer { lock.unlock() }
    let itunesDir = IpodFileSystem(volumeURL: deviceVolume).itunesDir.standardizedFileURL
    for file in files {
      let standardized = file.standardizedFileURL
      guard
        standardized.deletingLastPathComponent().standardizedFileURL.path == itunesDir.path,
        OnTheGoPlaylist.isPlaylistFileName(standardized.lastPathComponent)
      else { continue }
      FileManager.default.bestEffortRemoveItem(at: standardized)
    }
  }
}

enum PlaylistSyncApplier {
  struct Outcome: Sendable {
    var playlists: [LocalPlaylist]
    var links: [SyncPlaylistLink]
    var changedLibrary: Bool
  }

  static func apply(result: SyncResult, to playlists: [LocalPlaylist]) -> Outcome {
    var playlists = playlists
    var pending = result.pendingPlaylistLinks
    var patched = Set<Int>()
    var changed = false

    for action in result.libraryPlaylistActions {
      switch action {
      case .createInLibrary(let name, let trackIDs, let persistentID):
        let created = LocalPlaylist(name: name, trackIDs: trackIDs)
        playlists.append(created)
        changed = true
        for index in pending.indices
        where pending[index].persistentID == persistentID && !patched.contains(index) {
          pending[index].localID = created.id
          patched.insert(index)
          break
        }
      case .updateInLibrary(let localID, let name, let trackIDs):
        guard let index = playlists.firstIndex(where: { $0.id == localID }) else { continue }
        let updated = LocalPlaylist(
          id: localID, name: name, trackIDs: trackIDs,
          syncEnabled: playlists[index].syncEnabled,
          smartRule: playlists[index].smartRule)
        if playlists[index] != updated {
          playlists[index] = updated
          changed = true
        }
      case .deleteInLibrary(let localID, _):
        let before = playlists.count
        playlists.removeAll { $0.id == localID }
        if playlists.count != before { changed = true }
      case .createOnDevice, .updateOnDevice, .deleteOnDevice, .conflictResolved:
        break
      }
    }

    for imported in result.onTheGoImports {
      playlists.append(LocalPlaylist(name: imported.name, trackIDs: imported.trackIDs))
      changed = true
    }

    let finalizedPending = pending.indices.filter(patched.contains).map { pending[$0] }
    return Outcome(
      playlists: playlists,
      links: result.playlistLinks + finalizedPending,
      changedLibrary: changed)
  }
}
