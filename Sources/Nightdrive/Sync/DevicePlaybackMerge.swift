import Foundation

extension SyncEngine {
  /// Merges playback state pulled from the device — play counts, skip
  /// counts, bookmarks, timestamps, and ratings — into the device
  /// database, the sync ledger entries, and the sync result. Returns
  /// whether any device track rows changed.
  static func mergeDevicePlayback(
    playback: DevicePlaybackCollection,
    db: inout ITunesDatabase,
    retainedLinks: inout [SyncLedgerEntry],
    newEntries: inout [SyncLedgerEntry],
    result: inout SyncResult,
    localRatings: [String: Int],
    trackLinks: PlaylistTrackLinks,
    libraryFolder: URL,
    validateLibraryRoot: () throws -> Void
  ) -> Bool {
    var statsChanged = false
    result.playbackNotes += playback.notes
    var trackIndexByDbid: [UInt64: Int] = [:]
    for (index, track) in db.tracks.enumerated() where trackIndexByDbid[track.dbid] == nil {
      trackIndexByDbid[track.dbid] = index
    }
    if let pending = playback.pending {
      result.playbackReport = pending
      result.playCountsFilesToDelete = playback.filesToDelete
    } else {
      var pulledRatings: [UInt64: Int] = [:]
      var reportEntries: [DevicePlaybackReport.Entry] = []
      var reportIndexByDbid: [UInt64: Int] = [:]
      for (dbid, entry) in playback.parsed {
        if let raw = entry.rating, let stars = PlayCountsFile.starRating(fromDeviceRating: raw) {
          pulledRatings[dbid] = stars
        }
        let deviceTrack = trackIndexByDbid[dbid].map { db.tracks[$0] }
        let bookmarkIsMeaningful =
          entry.bookmarkMS.map {
            $0 > 0 || $0 != (deviceTrack?.bookmarkMS ?? 0)
          } ?? false
        guard
          entry.playCount > 0 || entry.skipCount > 0 || bookmarkIsMeaningful
            || entry.lastSkipped != nil
        else { continue }
        reportIndexByDbid[dbid] = reportEntries.count
        reportEntries.append(
          DevicePlaybackReport.Entry(
            dbid: dbid, localURL: trackLinks.urlForDbid[dbid],
            playCountDelta: Int(entry.playCount), skipCountDelta: Int(entry.skipCount),
            lastPlayed: entry.lastPlayed,
            bookmarkMS: entry.bookmarkMS.map(Int.init), lastSkipped: entry.lastSkipped))
      }

      func ratingDecision(for entry: SyncLedgerEntry) -> (resolved: Int, pullForReport: Int?)? {
        guard let index = trackIndexByDbid[entry.dbid] else { return nil }
        let mhitStars = SyncSignature.starRating(for: db.tracks[index])
        let deviceStars = pulledRatings[entry.dbid] ?? mhitStars
        let base = entry.lastSyncedRating ?? mhitStars
        let localKey = TrackID(
          url: libraryFolder.appendingPathComponent(entry.relativePath)
        ).rawValue
        let localStars = localRatings[localKey] ?? 0
        if deviceStars > 0, deviceStars != base {
          return (deviceStars, deviceStars == localStars ? nil : deviceStars)
        }
        if localStars > 0, localStars != base {
          return (localStars, nil)
        }
        return (base, nil)
      }
      for entry in retainedLinks + newEntries {
        guard let decision = ratingDecision(for: entry), let pulled = decision.pullForReport
        else { continue }
        if let existing = reportIndexByDbid[entry.dbid] {
          reportEntries[existing].deviceRating = pulled
        } else {
          reportIndexByDbid[entry.dbid] = reportEntries.count
          reportEntries.append(
            DevicePlaybackReport.Entry(
              dbid: entry.dbid, localURL: trackLinks.urlForDbid[entry.dbid],
              deviceRating: pulled))
        }
      }

      var playbackCommitted = true
      if reportEntries.isEmpty {
        result.playCountsFilesToDelete = playback.filesToDelete
      } else {
        let report = DevicePlaybackReport(databaseID: db.databaseID, entries: reportEntries)
        do {
          // Durable before the caller's database write: a crash after it would
          // lose the plays along with the consumed Play Counts file.
          try validateLibraryRoot()
          try PendingPlaybackReportStore.save(report, libraryFolder: libraryFolder)
          result.playbackReport = report
          result.playCountsFilesToDelete = playback.filesToDelete
        } catch {
          playbackCommitted = false
          result.fail(
            .mergePlayCounts, PendingPlaybackReportStore.url(for: libraryFolder).path,
            "Play counts were left on the iPod for the next sync (\(error.localizedDescription)).")
        }
      }
      if playbackCommitted {
        for (dbid, entry) in playback.parsed {
          guard let index = trackIndexByDbid[dbid] else { continue }
          if entry.playCount > 0 {
            db.tracks[index].playCount = UInt32(
              clamping: UInt64(db.tracks[index].playCount) + UInt64(entry.playCount))
            statsChanged = true
          }
          if entry.skipCount > 0 {
            db.tracks[index].skipCount = UInt32(
              clamping: UInt64(db.tracks[index].skipCount) + UInt64(entry.skipCount))
            statsChanged = true
          }
          if let bookmarkMS = entry.bookmarkMS,
            bookmarkMS != db.tracks[index].bookmarkMS
          {
            db.tracks[index].bookmarkMS = bookmarkMS
            statsChanged = true
          }
          if let played = entry.lastPlayed,
            played > (db.tracks[index].timePlayed ?? .distantPast)
          {
            db.tracks[index].timePlayed = played
            statsChanged = true
          }
          if let skipped = entry.lastSkipped,
            skipped > (db.tracks[index].lastSkipped ?? .distantPast)
          {
            db.tracks[index].lastSkipped = skipped
            statsChanged = true
          }
        }
      } else {
        pulledRatings = [:]
      }
      func applyRatingDecision(to entry: inout SyncLedgerEntry) {
        guard let decision = ratingDecision(for: entry),
          let index = trackIndexByDbid[entry.dbid]
        else { return }
        let binary = UInt8(clamping: decision.resolved * 20)
        if db.tracks[index].rating != binary {
          db.tracks[index].rating = binary
          statsChanged = true
        }
        entry.lastSyncedRating = decision.resolved
      }
      for index in retainedLinks.indices {
        applyRatingDecision(to: &retainedLinks[index])
      }
      for index in newEntries.indices {
        applyRatingDecision(to: &newEntries[index])
      }
    }
    return statsChanged
  }
}
