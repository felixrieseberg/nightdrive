import Foundation

struct ITunesDBReader {
  let fallbackTimezoneShift: Int

  init(timezoneShift: Int = TimeZone.current.secondsFromGMT()) {
    self.fallbackTimezoneShift = timezoneShift
  }

  private static let maxChildCount: UInt32 = 1_000_000

  func read(_ data: Data) throws -> ITunesDatabase {
    let r = ByteReader(data)
    guard try r.tag(0) == "mhbd" else {
      throw ITunesDBError.badHeader("file does not start with mhbd")
    }
    let headerLen = Int(try r.u32(4))
    guard headerLen >= 0x68, headerLen <= r.count else {
      throw ITunesDBError.badHeader("mhbd header length \(headerLen)")
    }
    let totalLen = Int(try r.u32(8))
    guard totalLen == r.count else {
      throw ITunesDBError.badHeader("mhbd total length \(totalLen), file length \(r.count)")
    }
    let sectionCount = try r.u32(20)
    guard sectionCount > 0, sectionCount <= Self.maxChildCount else {
      throw ITunesDBError.badHeader("implausible mhsd count \(sectionCount)")
    }

    var db = ITunesDatabase()
    db.preservedMhbdHeader = try r.slice(0, headerLen)
    db.databaseID = try r.u64(24)
    if headerLen >= 0x24 { db.platform = try r.u16(0x20) }
    if headerLen >= 0x30 { db.id0x24 = try r.u64(0x24) }
    if headerLen >= 0x48 { db.language = try r.u16(0x46) }
    if headerLen >= 0x50 { db.libraryPersistentID = try r.u64(0x48) }
    var tz = fallbackTimezoneShift
    if headerLen >= 0x70 {
      let stored = Int32(bitPattern: try r.u32(0x6C))
      if abs(Int(stored)) <= 14 * 3600 { tz = Int(stored) }
    }
    db.timezoneShift = tz

    var pos = headerLen
    var playlistSections: [(type: UInt32, start: Int, end: Int)] = []
    var trackSectionCount = 0
    var standardPlaylistSectionCount = 0
    for _ in 0..<sectionCount {
      guard pos + 16 <= r.count, try r.tag(pos) == "mhsd" else {
        throw ITunesDBError.badHeader("expected mhsd at \(pos)")
      }
      let totalLen = Int(try r.u32(pos + 8))
      let sectionHeaderLen = Int(try r.u32(pos + 4))
      guard totalLen >= sectionHeaderLen, sectionHeaderLen >= 16,
        pos + totalLen <= r.count
      else {
        throw ITunesDBError.badHeader("mhsd lengths at \(pos)")
      }
      let type = try r.u32(pos + 12)
      switch type {
      case 1:
        trackSectionCount += 1
        db.tracks = try readTrackList(
          r, at: pos + sectionHeaderLen, end: pos + totalLen, timezoneShift: tz)
      case 2:
        standardPlaylistSectionCount += 1
        playlistSections.append((type, pos + sectionHeaderLen, pos + totalLen))
      case 3:
        playlistSections.append((type, pos + sectionHeaderLen, pos + totalLen))
      default:
        db.preservedSections.append(
          ITDBPreservedSection(type: type, data: try r.slice(pos, totalLen)))
      }
      pos += totalLen
    }
    guard pos == r.count else {
      throw ITunesDBError.badHeader("mhsd children do not tile the database")
    }
    guard trackSectionCount == 1, standardPlaylistSectionCount == 1 else {
      throw ITunesDBError.badHeader(
        "expected one track and one standard-playlist section")
    }

    var seenDbids = Set<UInt64>(minimumCapacity: db.tracks.count)
    for track in db.tracks where !seenDbids.insert(track.dbid).inserted {
      throw ITunesDBError.badHeader(
        "duplicate track dbid \(String(track.dbid, radix: 16))")
    }

    let trackByID = Dictionary(
      db.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for section in playlistSections {
      let playlists = try readPlaylistList(
        r, at: section.start, end: section.end, timezoneShift: tz)
      for playlist in playlists {
        var pl = ITDBPlaylist(name: playlist.rawName, isMaster: playlist.isMaster)
        pl.persistentID = playlist.persistentID
        pl.sortOrder = playlist.sortOrder
        pl.timestamp = playlist.timestamp
        pl.isPodcast = playlist.podcastFlag != 0
        pl.memberDbids = playlist.members.compactMap { member in
          guard member.podcastGroupFlag == 0 else { return nil }
          return trackByID[member.trackID]?.dbid
        }
        pl.preservedMhypHeader = playlist.preservedHeader
        pl.preservedMhods = playlist.preservedMhods
        pl.preservedMembers = playlist.members.compactMap { member in
          if member.podcastGroupFlag != 0 {
            return ITDBPlaylistMember(dbid: nil, data: member.data)
          }
          guard let dbid = trackByID[member.trackID]?.dbid else { return nil }
          return ITDBPlaylistMember(dbid: dbid, data: member.data)
        }
        if pl.isPodcast {
          pl.podcastGroups = podcastGroups(from: playlist.members, trackByID: trackByID)
        }
        if section.type == 3 {
          db.podcastPlaylists.append(pl)
          continue
        }
        if playlist.isMaster {
          db.masterPlaylistName = playlist.rawName
          db.masterPlaylistID = playlist.persistentID
          db.masterPlaylistTemplate = pl
        } else {
          db.playlists.append(pl)
        }
      }
    }
    db.sourceTrackDbids = Set(db.tracks.map(\.dbid))
    db.sourcePlaylistIDs = Set(
      [db.masterPlaylistID] + db.playlists.map(\.persistentID))
    return db
  }

  // MARK: - Tracks

  private func readTrackList(
    _ r: ByteReader, at start: Int, end: Int, timezoneShift: Int
  ) throws -> [ITDBTrack] {
    guard try r.tag(start) == "mhlt" else {
      throw ITunesDBError.badHeader("expected mhlt")
    }
    let count = try r.u32(start + 8)
    guard count <= Self.maxChildCount else {
      throw ITunesDBError.badHeader("implausible track count \(count)")
    }
    var pos = start + Int(try r.u32(start + 4))
    guard pos >= start + 12, pos <= end else {
      throw ITunesDBError.badHeader("mhlt header length at \(start)")
    }
    guard Int(count) <= (end - pos) / 0x50 else {
      throw ITunesDBError.badHeader("track count \(count) exceeds mhlt bounds")
    }
    var tracks: [ITDBTrack] = []
    tracks.reserveCapacity(Int(count))

    for _ in 0..<count {
      guard pos + 16 <= end, try r.tag(pos) == "mhit" else {
        throw ITunesDBError.badHeader("expected mhit at \(pos)")
      }
      let headerLen = Int(try r.u32(pos + 4))
      let totalLen = Int(try r.u32(pos + 8))
      guard headerLen >= 0x50, totalLen >= headerLen, pos + totalLen <= end else {
        throw ITunesDBError.badHeader("mhit lengths at \(pos)")
      }
      var t = ITDBTrack()
      t.preservedMhitHeader = try r.slice(pos, headerLen)
      t.id = try r.u32(pos + 16)
      t.filetypeMarker = try r.u32(pos + 24)
      t.vbr = (try r.u8(pos + 28)) == 1
      t.type2 = try r.u8(pos + 29)
      t.compilation = (try r.u8(pos + 30)) == 1
      t.rating = try r.u8(pos + 31)
      t.timeModified = date(try r.u32(pos + 32), timezoneShift)
      t.sizeBytes = try r.u32(pos + 36)
      t.lengthMS = try r.u32(pos + 40)
      t.trackNumber = try r.u32(pos + 44)
      t.trackCount = try r.u32(pos + 48)
      t.year = try r.u32(pos + 52)
      t.bitrate = try r.u32(pos + 56)
      let samplerateField = try r.u32(pos + 60)
      t.samplerate = UInt16(samplerateField >> 16)
      t.samplerateLow = UInt16(samplerateField & 0xFFFF)
      t.volumeAdjustment = Int32(bitPattern: try r.u32(pos + 64))
      t.soundcheck = try r.u32(pos + 76)
      if headerLen >= 0x70 {
        t.playCount = try r.u32(pos + 80)
        t.playCount2 = try r.u32(pos + 84)
        t.timePlayed = date(try r.u32(pos + 88), timezoneShift)
        t.discNumber = try r.u32(pos + 92)
        t.discCount = try r.u32(pos + 96)
        t.timeAdded = date(try r.u32(pos + 104), timezoneShift)
        t.bookmarkMS = try r.u32(pos + 0x6C)
      }
      if headerLen >= 0x78 {
        let dbid = try r.u64(pos + 112)
        if dbid != 0 { t.dbid = dbid }
      }
      if headerLen >= 0x90 {
        t.timeReleased = date(try r.u32(pos + 0x8C), timezoneShift)
      }
      if headerLen >= 0xA8 {
        t.skipWhenShuffling = (try r.u8(pos + 0xA5)) == 1
        t.rememberPlaybackPosition = (try r.u8(pos + 0xA6)) == 1
      }
      if headerLen >= 0xA0 {
        t.skipCount = try r.u32(pos + 0x9C)
      }
      if headerLen >= 0xA4 {
        t.lastSkipped = date(try r.u32(pos + 0xA0), timezoneShift)
      }
      if headerLen >= 0xCC {
        t.pregap = try r.u32(pos + 0xB8)
        t.sampleCount = try r.u64(pos + 0xBC)
        t.postgap = try r.u32(pos + 0xC8)
      }
      if headerLen >= 0xD4 {
        t.mediaKind = try r.u32(pos + 0xD0)
      }
      if headerLen >= 0x104 {
        t.gaplessData = try r.u32(pos + 0xF8)
        t.gaplessTrackFlag = (try r.u16(pos + 0x100)) != 0
        t.gaplessAlbumFlag = (try r.u16(pos + 0x102)) != 0
      }
      if headerLen >= 0x164 {
        let artworkCount = try r.u16(pos + 0x7C)
        let artworkSize = try r.u32(pos + 0x80)
        let hasArtwork = try r.u8(pos + 0xA4)
        let mhiiLink = try r.u32(pos + 0x160)
        if hasArtwork == 1, mhiiLink != 0, artworkCount > 0 {
          t.artwork = ITDBTrackArtwork(
            mhiiID: mhiiLink, sizeBytes: artworkSize, count: artworkCount)
        }
      }

      let mhodCount = try r.u32(pos + 12)
      guard mhodCount <= Self.maxChildCount else {
        throw ITunesDBError.badHeader("implausible mhod count \(mhodCount)")
      }
      var mhodPos = pos + headerLen
      for _ in 0..<mhodCount {
        guard let mhod = try readMhod(r, at: mhodPos, end: pos + totalLen) else {
          throw ITunesDBError.badHeader("expected mhod at \(mhodPos)")
        }
        switch mhod.type {
        case 1: t.title = mhod.string
        case 2: t.ipodPath = mhod.string
        case 3: t.album = mhod.string
        case 4: t.artist = mhod.string
        case 5: t.genre = mhod.string
        case 6: t.filetypeDescription = mhod.string
        case 8: t.comment = mhod.string
        case 12: t.composer = mhod.string
        case 22: t.albumArtist = mhod.string
        case 23: t.sortArtist = mhod.string
        case 27: t.sortTitle = mhod.string
        case 28: t.sortAlbum = mhod.string
        case 29: t.sortAlbumArtist = mhod.string
        case 30: t.sortComposer = mhod.string
        default:
          t.preservedMhods.append(try r.slice(mhodPos, mhod.totalLen))
        }
        mhodPos += mhod.totalLen
      }
      guard mhodPos == pos + totalLen else {
        throw ITunesDBError.badHeader("mhit child count/length mismatch at \(pos)")
      }
      tracks.append(t)
      pos += totalLen
    }
    guard pos == end else {
      throw ITunesDBError.badHeader("mhlt child count/length mismatch at \(start)")
    }
    return tracks
  }

  // MARK: - Playlists

  private struct RawPlaylist {
    var rawName: String = ""
    var isMaster = false
    var persistentID: UInt64 = 0
    var timestamp: Date?
    var sortOrder: UInt32 = 1
    var podcastFlag: UInt16 = 0
    var preservedHeader = Data()
    var preservedMhods: [Data] = []
    var members: [RawMember] = []
  }

  private struct RawMember {
    var trackID: UInt32
    var podcastGroupFlag: UInt32
    var groupID: UInt32
    var groupRef: UInt32
    var title: String?
    var data: Data
  }

  private func readPlaylistList(
    _ r: ByteReader, at start: Int, end: Int, timezoneShift: Int
  ) throws -> [RawPlaylist] {
    guard try r.tag(start) == "mhlp" else {
      throw ITunesDBError.badHeader("expected mhlp")
    }
    let count = try r.u32(start + 8)
    guard count <= Self.maxChildCount else {
      throw ITunesDBError.badHeader("implausible playlist count \(count)")
    }
    var pos = start + Int(try r.u32(start + 4))
    guard pos >= start + 12, pos <= end else {
      throw ITunesDBError.badHeader("mhlp header length at \(start)")
    }
    var playlists: [RawPlaylist] = []

    for _ in 0..<count {
      guard pos + 16 <= end, try r.tag(pos) == "mhyp" else {
        throw ITunesDBError.badHeader("expected mhyp at \(pos)")
      }
      let headerLen = Int(try r.u32(pos + 4))
      let totalLen = Int(try r.u32(pos + 8))
      guard headerLen >= 0x30, totalLen >= headerLen, pos + totalLen <= end else {
        throw ITunesDBError.badHeader("mhyp lengths at \(pos)")
      }
      var pl = RawPlaylist()
      pl.preservedHeader = try r.slice(pos, headerLen)
      let mhodCount = try r.u32(pos + 12)
      let mhipCount = try r.u32(pos + 16)
      guard mhodCount <= Self.maxChildCount, mhipCount <= Self.maxChildCount else {
        throw ITunesDBError.badHeader("implausible mhyp child count at \(pos)")
      }
      pl.isMaster = (try r.u8(pos + 20)) == 1
      pl.timestamp = date(try r.u32(pos + 24), timezoneShift)
      pl.persistentID = try r.u64(pos + 28)
      pl.podcastFlag = try r.u16(pos + 42)
      pl.sortOrder = try r.u32(pos + 44)

      var childPos = pos + headerLen
      for _ in 0..<mhodCount {
        guard let mhod = try readMhod(r, at: childPos, end: pos + totalLen) else {
          throw ITunesDBError.badHeader("expected playlist mhod at \(childPos)")
        }
        if mhod.type == 1, let s = mhod.string { pl.rawName = s }
        if mhod.type != 1 {
          pl.preservedMhods.append(try r.slice(childPos, mhod.totalLen))
        }
        childPos += mhod.totalLen
      }
      var parsed: UInt32 = 0
      while parsed < mhipCount {
        guard childPos + 16 <= pos + totalLen else {
          throw ITunesDBError.badHeader("missing mhip at \(childPos)")
        }
        let tag = try r.tag(childPos)
        if tag == "mhod" {
          let skip = Int(try r.u32(childPos + 8))
          guard skip >= 16 else {
            throw ITunesDBError.badHeader("sibling mhod length at \(childPos)")
          }
          let sibling = try r.slice(childPos, skip)
          if pl.members.isEmpty {
            pl.preservedMhods.append(sibling)
          } else {
            pl.members[pl.members.count - 1].data.append(sibling)
          }
          childPos += skip
          continue
        }
        guard tag == "mhip" else {
          throw ITunesDBError.badHeader("expected mhip at \(childPos)")
        }
        let mhipHeader = Int(try r.u32(childPos + 4))
        let mhipTotal = Int(try r.u32(childPos + 8))
        guard mhipHeader >= 28, mhipTotal >= mhipHeader,
          childPos + mhipTotal <= pos + totalLen
        else {
          throw ITunesDBError.badHeader("mhip lengths at \(childPos)")
        }
        let mhipMhodCount = try r.u32(childPos + 12)
        guard mhipMhodCount <= Self.maxChildCount else {
          throw ITunesDBError.badHeader("implausible mhip mhod count at \(childPos)")
        }
        var mhipChild = childPos + mhipHeader
        var memberTitle: String?
        for _ in 0..<mhipMhodCount {
          guard let mhod = try readMhod(r, at: mhipChild, end: childPos + mhipTotal) else {
            throw ITunesDBError.badHeader("expected mhip mhod at \(mhipChild)")
          }
          if mhod.type == 1, let title = mhod.string { memberTitle = title }
          mhipChild += mhod.totalLen
        }
        guard mhipChild == childPos + mhipTotal else {
          throw ITunesDBError.badHeader("mhip child count/length mismatch at \(childPos)")
        }
        let podcastGroupFlag = try r.u32(childPos + 16)
        let trackID = try r.u32(childPos + 24)
        pl.members.append(
          RawMember(
            trackID: trackID, podcastGroupFlag: podcastGroupFlag,
            groupID: try r.u32(childPos + 20),
            groupRef: mhipHeader >= 36 ? try r.u32(childPos + 32) : 0,
            title: memberTitle,
            data: try r.slice(childPos, mhipTotal)))
        childPos += mhipTotal
        parsed += 1
      }
      while childPos + 16 <= pos + totalLen, try r.tag(childPos) == "mhod" {
        let skip = Int(try r.u32(childPos + 8))
        guard skip >= 16, childPos + skip <= pos + totalLen else {
          throw ITunesDBError.badHeader("trailing sibling mhod length at \(childPos)")
        }
        let sibling = try r.slice(childPos, skip)
        if pl.members.isEmpty {
          pl.preservedMhods.append(sibling)
        } else {
          pl.members[pl.members.count - 1].data.append(sibling)
        }
        childPos += skip
      }
      guard parsed == mhipCount, childPos == pos + totalLen else {
        throw ITunesDBError.badHeader("mhyp child count/length mismatch at \(pos)")
      }
      playlists.append(pl)
      pos += totalLen
    }
    guard pos == end else {
      throw ITunesDBError.badHeader("mhlp child count/length mismatch at \(start)")
    }
    return playlists
  }

  // MARK: - Podcast groups

  /// Rebuilds the show/episode structure of a podcast playlist: a group mhip
  /// carries the show title and its own id; episode mhips reference that id
  /// via podcastgroupref, or simply follow their group heading.
  private func podcastGroups(
    from members: [RawMember], trackByID: [UInt32: ITDBTrack]
  ) -> [ITDBPodcastGroup] {
    var groups: [ITDBPodcastGroup] = []
    var groupIndexByID: [UInt32: Int] = [:]
    for member in members {
      if member.podcastGroupFlag != 0 {
        groups.append(ITDBPodcastGroup(title: member.title ?? ""))
        if member.groupID != 0 {
          groupIndexByID[member.groupID] = groups.count - 1
        }
        continue
      }
      guard let dbid = trackByID[member.trackID]?.dbid else { continue }
      if member.groupRef != 0, let index = groupIndexByID[member.groupRef] {
        groups[index].episodeDbids.append(dbid)
      } else if !groups.isEmpty {
        groups[groups.count - 1].episodeDbids.append(dbid)
      }
    }
    return groups
  }

  // MARK: - mhods

  private struct Mhod {
    var type: UInt32
    var totalLen: Int
    var string: String?
  }

  private func readMhod(_ r: ByteReader, at pos: Int, end: Int) throws -> Mhod? {
    guard pos + 16 <= end, try r.tag(pos) == "mhod" else { return nil }
    let totalLen = Int(try r.u32(pos + 8))
    guard totalLen >= 16, pos + totalLen <= end else {
      throw ITunesDBError.badHeader("mhod lengths at \(pos)")
    }
    let type = try r.u32(pos + 12)
    var mhod = Mhod(type: type, totalLen: totalLen)

    let stringTypes: Set<UInt32> = [
      1, 2, 3, 4, 5, 6, 8, 9, 12, 13, 14, 18, 19,
      20, 21, 22, 23, 24, 27, 28, 29, 30, 31,
      200, 201, 202, 300,
    ]
    if stringTypes.contains(type), totalLen >= 40 {
      let encoding = try r.u32(pos + 24)
      let byteLen = Int(try r.u32(pos + 28))
      guard byteLen >= 0, pos + 40 + byteLen <= pos + totalLen else {
        throw ITunesDBError.badHeader("mhod string length at \(pos)")
      }
      let bytes = try r.slice(pos + 40, byteLen)
      if encoding == 1 {
        mhod.string = LEBytes.utf16String(bytes)
      } else {
        mhod.string = String(data: bytes, encoding: .utf8)
      }
    }
    return mhod
  }

  private func date(_ macTime: UInt32, _ timezoneShift: Int) -> Date? {
    guard macTime != 0 else { return nil }
    let unix = Int64(macTime) - Int64(ITunesDBWriter.macEpochOffset) - Int64(timezoneShift)
    return Date(timeIntervalSince1970: TimeInterval(unix))
  }
}
