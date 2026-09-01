import Foundation

final class ITunesDBWriter {
  struct PreservedMemberLookup {
    private var recordsByDbid: [UInt64: [Data]] = [:]
    private var nextRecordByDbid: [UInt64: Int] = [:]
    let opaqueRecords: [Data]

    init(_ members: [ITDBPlaylistMember]) {
      var opaqueRecords: [Data] = []
      for member in members {
        if let dbid = member.dbid {
          recordsByDbid[dbid, default: []].append(member.data)
        } else {
          opaqueRecords.append(member.data)
        }
      }
      self.opaqueRecords = opaqueRecords
    }

    mutating func takeRecord(for dbid: UInt64) -> Data? {
      let nextIndex = nextRecordByDbid[dbid, default: 0]
      guard let records = recordsByDbid[dbid], nextIndex < records.count else {
        return nil
      }
      nextRecordByDbid[dbid] = nextIndex + 1
      return records[nextIndex]
    }
  }

  static let macEpochOffset: UInt64 = 2_082_844_800

  private var timezoneShift: Int = TimeZone.current.secondsFromGMT()

  init() {}

  private enum MhodType {
    static let title: UInt32 = 1
    static let path: UInt32 = 2
    static let album: UInt32 = 3
    static let artist: UInt32 = 4
    static let genre: UInt32 = 5
    static let filetype: UInt32 = 6
    static let comment: UInt32 = 8
    static let composer: UInt32 = 12
    static let albumArtist: UInt32 = 22
    static let sortArtist: UInt32 = 23
    static let sortTitle: UInt32 = 27
    static let sortAlbum: UInt32 = 28
    static let sortAlbumArtist: UInt32 = 29
    static let sortComposer: UInt32 = 30
    static let playlistPosition: UInt32 = 100
    static let albumListAlbum: UInt32 = 200
    static let albumListArtist: UInt32 = 201
    static let artistListArtist: UInt32 = 300
  }

  func macTime(_ date: Date?) -> UInt32 {
    Self.macTime(date, timezoneShift: timezoneShift)
  }

  static func macTime(_ date: Date?, timezoneShift: Int) -> UInt32 {
    guard let date else { return 0 }
    let t = Int64(date.timeIntervalSince1970) + Int64(macEpochOffset) + Int64(timezoneShift)
    return UInt32(clamping: t)
  }

  func write(_ database: ITunesDatabase) -> Data {
    var db = database
    timezoneShift = db.timezoneShift
    db.podcastPlaylists = Self.normalizedPodcastPlaylists(for: db)

    Self.assignTrackIDs(&db.tracks)
    let idForDbid = Dictionary(
      db.tracks.map { ($0.dbid, $0.id) }, uniquingKeysWith: { first, _ in first })

    var albumIDs: [String: (id: UInt32, sqlID: UInt64, track: ITDBTrack)] = [:]
    var artistIDs: [String: (id: UInt32, sqlID: UInt64, track: ITDBTrack)] = [:]
    var albumIDForTrack: [UInt64: UInt32] = [:]
    var artistIDForTrack: [UInt64: UInt32] = [:]
    let preservedAlbumSection = db.preservedSections.first { $0.type == 4 }
    let preservedArtistSection = db.preservedSections.first { $0.type == 8 }
    let preservedAlbumIDs = preservedAlbumSection.map { albumIndexIDs(in: $0) } ?? [:]
    let preservedArtistIDs = preservedArtistSection.map { artistIndexIDs(in: $0) } ?? [:]
    let firstAlbumID = (preservedAlbumSection.flatMap(maximumIndexID) ?? 0) &+ 1
    let firstArtistID = (preservedArtistSection.flatMap(maximumIndexID) ?? 0) &+ 1
    for track in db.tracks {
      if let album = track.album, !album.isEmpty {
        let key = album + "\u{0}" + (track.albumArtist ?? track.artist ?? "")
        if let id = preservedAlbumIDs[key] {
          albumIDForTrack[track.dbid] = id
        } else if let entry = albumIDs[key] {
          albumIDForTrack[track.dbid] = entry.id
        } else {
          let id = firstAlbumID &+ UInt32(albumIDs.count)
          albumIDs[key] = (id, ITDBTrack.randomDbid(), track)
          albumIDForTrack[track.dbid] = id
        }
      }
      if let artist = track.artist, !artist.isEmpty {
        if let id = preservedArtistIDs[artist] {
          artistIDForTrack[track.dbid] = id
        } else if let entry = artistIDs[artist] {
          artistIDForTrack[track.dbid] = entry.id
        } else {
          let id = firstArtistID &+ UInt32(artistIDs.count)
          artistIDs[artist] = (id, ITDBTrack.randomDbid(), track)
          artistIDForTrack[track.dbid] = id
        }
      }
    }

    var master =
      db.masterPlaylistTemplate
      ?? ITDBPlaylist(name: db.masterPlaylistName, isMaster: true)
    master.name = db.masterPlaylistName
    master.isMaster = true
    master.persistentID = db.masterPlaylistID
    master.memberDbids = db.tracks.map(\.dbid)
    let playlists = [master] + db.playlists.filter { !$0.isMaster }
    let mirroredPlaylists = Self.mirroredPlaylists(
      playlists, preserving: db.podcastPlaylists,
      originalStandardIDs: db.sourcePlaylistIDs)
    // The estimate excludes the type-3 mirror; ByteWriter grows as needed.
    var w = ByteWriter(capacity: Self.estimatedCapacity(for: db, playlists: playlists))

    let mhbdStart = w.count
    if var header = db.preservedMhbdHeader, header.count >= 0x70 {
      patchU32(&header, at: 8, 0)
      patchU32(&header, at: 20, 0)
      patchU64(&header, at: 24, db.databaseID)
      patchU16(&header, at: 32, db.platform)
      patchU64(&header, at: 36, db.id0x24)
      patchU16(&header, at: 48, 0)
      header.replaceSubrange(50..<70, with: repeatElement(UInt8(0), count: 20))
      patchU16(&header, at: 70, db.language)
      patchU64(&header, at: 72, db.libraryPersistentID)
      header.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))
      patchU32(&header, at: 108, UInt32(bitPattern: Int32(timezoneShift)))
      patchU16(&header, at: 112, 0)
      w.bytes(header)
    } else {
      w.tag("mhbd")
      w.u32(244)  // header size
      w.u32(0)  // total size, patched at the end
      w.u32(1)  // 1 for devices without compressed-db support
      w.u32(0x30)  // database version (iTunes 9.2)
      w.u32(0)  // number of child mhsd sections, patched below
      w.u64(db.databaseID)
      w.u16(db.platform)  // 1 = macOS
      w.u16(0)
      w.u64(db.id0x24)
      w.u32(0)
      w.u16(0)  // hashing scheme: none (pre-nano3G devices)
      w.zero16(10)
      w.u16(db.language)
      w.u64(db.libraryPersistentID)
      w.u32(0)
      w.u32(0)
      w.zero32(5)  // hash58 slot, unused
      w.u32(UInt32(bitPattern: Int32(timezoneShift)))
      w.u16(0)  // checksum type: none
      w.u16(0)
      w.zero32(11)
      w.zero16(5)  // audio/subtitle language + unknowns
      w.u8(0)
      w.u8(0)
      w.zero32(14)
      w.zero32(4)
      assert(w.count - mhbdStart == 244)
    }

    writeMhsd(&w, type: 1) { w in
      w.tag("mhlt")
      w.u32(92)
      w.u32(UInt32(db.tracks.count))
      w.zero32(20)
      for track in db.tracks {
        self.writeMhit(
          &w, track,
          albumID: albumIDForTrack[track.dbid] ?? 0,
          artistID: artistIDForTrack[track.dbid] ?? 0,
          id0x24: db.id0x24)
      }
    }

    writeMhsd(&w, type: 3) { w in
      self.writePlaylistList(&w, mirroredPlaylists, idForDbid: idForDbid)
    }

    writeMhsd(&w, type: 2) { w in
      self.writePlaylistList(&w, playlists, idForDbid: idForDbid)
    }

    writeIndexSection(
      &w, type: 4, listTag: "mhla", preserved: preservedAlbumSection,
      entries: albumIDs.values.map { $0 }, entryTag: "mhia", entryHeaderSize: 88,
      entryZeroWords: 14, entryMhods: writeAlbumIndexMhods)

    writeIndexSection(
      &w, type: 8, listTag: "mhli", preserved: preservedArtistSection,
      entries: artistIDs.values.map { $0 }, entryTag: "mhii", entryHeaderSize: 80,
      entryZeroWords: 12, entryMhods: writeArtistIndexMhods)

    for type: UInt32 in [6, 10] {
      if !writePreservedSection(&w, type: type, database: db) {
        writeMhsd(&w, type: type) { w in
          w.tag("mhlt")
          w.u32(92)
          w.u32(0)
          w.zero32(20)
        }
      }
    }

    if !writePreservedSection(&w, type: 5, database: db) {
      writeMhsd(&w, type: 5) { w in
        w.tag("mhlp")
        w.u32(92)
        w.u32(0)
        w.zero32(20)
      }
    }

    let standardTypes: Set<UInt32> = [1, 2, 3, 4, 5, 6, 8, 10]
    let deletedTrack =
      db.sourceTrackDbids.map { !$0.isSubset(of: Set(db.tracks.map(\.dbid))) }
      ?? false
    for section in db.preservedSections
    where !standardTypes.contains(section.type) && !deletedTrack {
      w.bytes(section.data)
    }

    w.patchU32(UInt32(w.count - mhbdStart), at: mhbdStart + 8)
    w.patchU32(
      UInt32(
        8
          + db.preservedSections.filter {
            !standardTypes.contains($0.type) && !deletedTrack
          }.count),
      at: mhbdStart + 20)
    return w.data
  }

  private static func estimatedCapacity(
    for database: ITunesDatabase, playlists: [ITDBPlaylist]
  ) -> Int {
    let trackBytes = database.tracks.count.multipliedReportingOverflow(by: 1_024)
    let memberCount = playlists.reduce(0) { $0 + $1.memberDbids.count }
    let memberBytes = memberCount.multipliedReportingOverflow(by: 120)
    guard !trackBytes.overflow, !memberBytes.overflow else { return 0 }
    let (estimated, overflow) = trackBytes.partialValue.addingReportingOverflow(
      memberBytes.partialValue)
    guard !overflow else { return 0 }
    return max(4_096, estimated)
  }

  private static func mirroredPlaylists(
    _ standard: [ITDBPlaylist], preserving existing: [ITDBPlaylist],
    originalStandardIDs: Set<UInt64>?
  ) -> [ITDBPlaylist] {
    let existingByID = Dictionary(
      existing.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
    let currentIDs = Set(standard.map(\.persistentID))
    var mirrored = standard.map { playlist in
      guard var template = existingByID[playlist.persistentID] else { return playlist }
      template.name = playlist.name
      template.isMaster = playlist.isMaster
      template.timestamp = playlist.timestamp
      template.sortOrder = playlist.sortOrder
      template.memberDbids = playlist.memberDbids
      return template
    }
    let supersededIDs = originalStandardIDs ?? currentIDs
    // A type-3-only entry is indistinguishable from a genuine podcast playlist. Preserve it
    // unless its ID was known to belong to the original type-2 set; externally orphaned mirrors
    // can therefore remain as harmless zombies.
    mirrored.append(
      contentsOf: existing.filter {
        !supersededIDs.contains($0.persistentID) && !currentIDs.contains($0.persistentID)
      })
    return mirrored
  }

  static func assignTrackIDs(_ tracks: inout [ITDBTrack]) {
    var usedIDs = Set<UInt32>()
    for track in tracks where track.preservedMhitHeader != nil && track.id != 0 {
      usedIDs.insert(track.id)
    }

    var assignedIDs = Set<UInt32>()
    var nextID = max(52, (usedIDs.max() ?? 51) &+ 1)
    for index in tracks.indices {
      let importedID = tracks[index].id
      let canKeep =
        tracks[index].preservedMhitHeader != nil && importedID != 0
        && assignedIDs.insert(importedID).inserted
      if canKeep { continue }

      while usedIDs.contains(nextID) { nextID &+= 1 }
      tracks[index].id = nextID
      usedIDs.insert(nextID)
      assignedIDs.insert(nextID)
      nextID &+= 1
    }
  }

  // MARK: - Sections

  private func writeMhsd(_ w: inout ByteWriter, type: UInt32, body: (inout ByteWriter) -> Void) {
    let start = w.count
    w.tag("mhsd")
    w.u32(96)
    w.u32(0)  // total, patched
    w.u32(type)
    w.zero32(20)
    body(&w)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writePreservedSection(
    _ w: inout ByteWriter, type: UInt32, database: ITunesDatabase
  ) -> Bool {
    guard let section = database.preservedSections.first(where: { $0.type == type }) else {
      return false
    }
    w.bytes(section.data)
    return true
  }

  private func maximumIndexID(in section: ITDBPreservedSection) -> UInt32? {
    let data = section.data
    guard let sectionHeader = readU32(data, at: 4), let total = readU32(data, at: 8),
      Int(total) == data.count
    else { return nil }
    let list = Int(sectionHeader)
    guard let listHeader = readU32(data, at: list + 4),
      let count = readU32(data, at: list + 8)
    else { return nil }
    var position = list + Int(listHeader)
    var maximum: UInt32 = 0
    for _ in 0..<count {
      guard let childTotal = readU32(data, at: position + 8), childTotal >= 20,
        let id = readU32(data, at: position + 16),
        position + Int(childTotal) <= data.count
      else { return nil }
      maximum = max(maximum, id)
      position += Int(childTotal)
    }
    return maximum
  }

  private func albumIndexIDs(in section: ITDBPreservedSection) -> [String: UInt32] {
    var result: [String: UInt32] = [:]
    guard let records = indexRecords(in: section) else { return result }
    for record in records {
      guard let album = record.strings[MhodType.albumListAlbum], !album.isEmpty else { continue }
      let key = album + "\u{0}" + (record.strings[MhodType.albumListArtist] ?? "")
      if result[key] == nil { result[key] = record.id }
    }
    return result
  }

  private func artistIndexIDs(in section: ITDBPreservedSection) -> [String: UInt32] {
    var result: [String: UInt32] = [:]
    guard let records = indexRecords(in: section) else { return result }
    for record in records {
      guard let artist = record.strings[MhodType.artistListArtist], !artist.isEmpty else { continue }
      if result[artist] == nil { result[artist] = record.id }
    }
    return result
  }

  private func indexRecords(in section: ITDBPreservedSection) -> [(id: UInt32, strings: [UInt32: String])]? {
    let data = section.data
    guard let sectionHeader = readU32(data, at: 4), let total = readU32(data, at: 8),
      Int(total) == data.count
    else { return nil }
    let list = Int(sectionHeader)
    guard let listHeader = readU32(data, at: list + 4),
      let count = readU32(data, at: list + 8)
    else { return nil }
    var position = list + Int(listHeader)
    guard position <= data.count, Int(count) <= (data.count - position) / 20 else { return nil }
    var records: [(id: UInt32, strings: [UInt32: String])] = []
    for _ in 0..<count {
      guard let header = readU32(data, at: position + 4), header >= 20,
        let total = readU32(data, at: position + 8), total >= header,
        let childCount = readU32(data, at: position + 12),
        let id = readU32(data, at: position + 16),
        position + Int(total) <= data.count
      else { return nil }
      var strings: [UInt32: String] = [:]
      var child = position + Int(header)
      for _ in 0..<childCount {
        guard child + 16 <= position + Int(total),
          Data(data[child..<child + 4]) == Data("mhod".utf8),
          let childTotal = readU32(data, at: child + 8), childTotal >= 16,
          child + Int(childTotal) <= position + Int(total),
          let type = readU32(data, at: child + 12)
        else { return nil }
        if let string = indexString(in: data, at: child, total: Int(childTotal)) {
          strings[type] = string
        }
        child += Int(childTotal)
      }
      records.append((id, strings))
      position += Int(total)
    }
    return records
  }

  private func indexString(in data: Data, at offset: Int, total: Int) -> String? {
    guard total >= 40, let encoding = readU32(data, at: offset + 24),
      let byteLength = readU32(data, at: offset + 28),
      Int(byteLength) <= total - 40
    else { return nil }
    let bytes = Data(data[offset + 40..<offset + 40 + Int(byteLength)])
    return String(data: bytes, encoding: encoding == 1 ? .utf16LittleEndian : .utf8)
  }

  private func writeIndexSection(
    _ w: inout ByteWriter, type: UInt32, listTag: String,
    preserved section: ITDBPreservedSection?,
    entries: [(id: UInt32, sqlID: UInt64, track: ITDBTrack)],
    entryTag: String, entryHeaderSize: UInt32, entryZeroWords: Int,
    entryMhods: (inout ByteWriter, ITDBTrack) -> UInt32
  ) {
    func writeEntries(_ w: inout ByteWriter) {
      for entry in entries.sorted(by: { $0.id < $1.id }) {
        let child = w.count
        w.tag(entryTag)
        w.u32(entryHeaderSize)
        w.u32(0)  // total, patched
        w.u32(0)  // mhod count, patched
        w.u32(entry.id)
        w.u64(entry.sqlID)
        w.u32(2)
        w.zero32(entryZeroWords)
        let mhods = entryMhods(&w, entry.track)
        w.patchU32(UInt32(w.count - child), at: child + 8)
        w.patchU32(mhods, at: child + 12)
      }
    }
    if let section {
      let start = w.count
      w.bytes(section.data)
      guard !entries.isEmpty, let sectionHeader = readU32(section.data, at: 4) else { return }
      let list = start + Int(sectionHeader)
      let oldCount = readU32(section.data, at: Int(sectionHeader) + 8) ?? 0
      writeEntries(&w)
      w.patchU32(oldCount &+ UInt32(entries.count), at: list + 8)
      w.patchU32(UInt32(w.count - start), at: start + 8)
    } else {
      writeMhsd(&w, type: type) { w in
        w.tag(listTag)
        w.u32(92)
        w.u32(UInt32(entries.count))
        w.zero32(20)
        writeEntries(&w)
      }
    }
  }

  private func writeAlbumIndexMhods(_ w: inout ByteWriter, _ track: ITDBTrack) -> UInt32 {
    var mhods: UInt32 = 0
    if let album = track.album, !album.isEmpty {
      writeStringMhod(&w, type: MhodType.albumListAlbum, album)
      mhods += 1
    }
    if let artist = track.albumArtist ?? track.artist, !artist.isEmpty {
      writeStringMhod(&w, type: MhodType.albumListArtist, artist)
      mhods += 1
    }
    return mhods
  }

  private func writeArtistIndexMhods(_ w: inout ByteWriter, _ track: ITDBTrack) -> UInt32 {
    var mhods: UInt32 = 0
    if let artist = track.artist, !artist.isEmpty {
      writeStringMhod(&w, type: MhodType.artistListArtist, artist)
      mhods += 1
    }
    return mhods
  }

  private func writeMhit(
    _ w: inout ByteWriter, _ t: ITDBTrack,
    albumID: UInt32, artistID: UInt32, id0x24: UInt64
  ) {
    if let preservedHeader = t.preservedMhitHeader {
      writePreservedMhit(
        &w, t, header: preservedHeader, albumID: albumID, artistID: artistID)
      return
    }
    let start = w.count
    w.tag("mhit")
    w.u32(0x248)  // header size
    w.u32(0)  // total size, patched
    w.u32(0)  // mhod count, patched
    w.u32(t.id)
    w.u32(1)  // visible
    w.u32(t.filetypeMarker)
    w.u8(t.vbr ? 1 : 0)  // type1: VBR MP3 = 1
    w.u8(t.type2)  // codec: MP3 = 1, AAC = 0
    w.u8(t.compilation ? 1 : 0)
    w.u8(t.rating)
    w.u32(macTime(t.timeModified))
    w.u32(t.sizeBytes)
    w.u32(t.lengthMS)
    w.u32(t.trackNumber)
    w.u32(t.trackCount)
    w.u32(t.year)
    w.u32(t.bitrate)
    w.u32(UInt32(t.samplerate) << 16 | UInt32(t.samplerateLow))
    w.i32(t.volumeAdjustment)
    w.u32(0)  // starttime
    w.u32(0)  // stoptime
    w.u32(t.soundcheck)
    w.u32(t.playCount)
    w.u32(t.playCount2)
    w.u32(macTime(t.timePlayed))
    w.u32(t.discNumber)
    w.u32(t.discCount)
    w.u32(0)  // drm user id
    w.u32(macTime(t.timeAdded))
    w.u32(t.bookmarkMS)
    w.u64(t.dbid)
    w.u8(0)  // checked (0 = checked)
    w.u8(0)  // app rating
    w.u16(0)  // BPM
    w.u16(t.artwork?.hasArtwork == true ? (t.artwork?.count ?? 1) : 0)  // artwork count
    w.u16(0)
    w.u32(t.artwork?.sizeBytes ?? 0)  // artwork size
    w.u32(0)
    w.f32(Float(t.samplerate))
    w.u32(macTime(t.timeReleased))  // time released
    w.u16(0)
    w.u16(0)  // explicit flag
    w.u32(0)
    w.u32(0)
    w.u32(t.skipCount)
    w.u32(macTime(t.lastSkipped))
    w.u8(t.artwork?.hasArtwork == true ? 1 : 2)  // has_artwork: 1 = yes, 2 = no
    w.u8(t.skipWhenShuffling ? 1 : 0)
    w.u8(t.rememberPlaybackPosition ? 1 : 0)
    w.u8(0)
    w.u64(t.dbid)  // dbid2
    w.u8(0)  // lyrics flag
    w.u8(0)  // movie flag
    w.u8(0)  // mark unplayed
    w.u8(0)
    w.u32(0)
    w.u32(t.pregap)
    w.u64(t.sampleCount)
    w.u32(0)
    w.u32(t.postgap)
    w.u32(0)
    w.u32(t.mediaKind)
    w.u32(0)  // season
    w.u32(0)  // episode
    w.u32(0)
    w.zero32(4)
    w.zero32(2)
    w.u32(t.gaplessData)
    w.u32(0)
    w.u16(t.gaplessTrackFlag ? 1 : 0)
    w.u16(t.gaplessAlbumFlag ? 1 : 0)
    w.zero32(7)
    w.u32(albumID)
    w.u64(id0x24)
    w.u32(t.sizeBytes)
    w.u32(0)
    w.u64(0x8080_8080_8080)
    w.u32(0)
    w.zero32(2)
    w.u32(0)  // epub/pdf flags
    w.zero32(5)
    w.u32(t.artwork?.mhiiID ?? 0)  // mhii artwork link
    w.u32(0)
    w.u32(1)
    w.u32(0)
    w.zero32(28)
    w.u32(artistID)
    w.zero32(4)
    w.u32(0)  // composer id
    w.zero32(20)
    assert(w.count - start == 0x248)

    let mhods = writeTrackStringMhods(&w, t)

    w.patchU32(UInt32(w.count - start), at: start + 8)
    w.patchU32(mhods, at: start + 12)
  }

  private func writeTrackStringMhods(_ w: inout ByteWriter, _ t: ITDBTrack) -> UInt32 {
    var mhods: UInt32 = 0
    func str(_ type: UInt32, _ value: String?) {
      guard let value, !value.isEmpty else { return }
      writeStringMhod(&w, type: type, value)
      mhods += 1
    }
    str(MhodType.title, t.title)
    str(MhodType.artist, t.artist)
    str(MhodType.album, t.album)
    str(MhodType.filetype, t.filetypeDescription)
    str(MhodType.comment, t.comment)
    str(MhodType.path, t.ipodPath)
    str(MhodType.genre, t.genre)
    str(MhodType.composer, t.composer)
    str(MhodType.albumArtist, t.albumArtist)
    str(MhodType.sortArtist, t.sortArtist)
    str(MhodType.sortTitle, t.sortTitle)
    str(MhodType.sortAlbum, t.sortAlbum)
    str(MhodType.sortAlbumArtist, t.sortAlbumArtist)
    str(MhodType.sortComposer, t.sortComposer)
    return mhods
  }

  private func writePreservedMhit(
    _ w: inout ByteWriter, _ t: ITDBTrack, header preservedHeader: Data,
    albumID: UInt32, artistID: UInt32
  ) {
    var header = preservedHeader
    patchU32(&header, at: 8, 0)
    patchU32(&header, at: 12, 0)
    patchU32(&header, at: 16, t.id)
    patchU32(&header, at: 24, t.filetypeMarker)
    patchU8(&header, at: 28, t.vbr ? 1 : 0)
    patchU8(&header, at: 29, t.type2)
    patchU8(&header, at: 30, t.compilation ? 1 : 0)
    patchU8(&header, at: 31, t.rating)
    patchU32(&header, at: 32, macTime(t.timeModified))
    patchU32(&header, at: 36, t.sizeBytes)
    patchU32(&header, at: 40, t.lengthMS)
    patchU32(&header, at: 44, t.trackNumber)
    patchU32(&header, at: 48, t.trackCount)
    patchU32(&header, at: 52, t.year)
    patchU32(&header, at: 56, t.bitrate)
    patchU32(
      &header, at: 60,
      UInt32(t.samplerate) << 16 | UInt32(t.samplerateLow))
    patchU32(&header, at: 64, UInt32(bitPattern: t.volumeAdjustment))
    patchU32(&header, at: 76, t.soundcheck)
    patchU32(&header, at: 80, t.playCount)
    patchU32(&header, at: 84, t.playCount2)
    patchU32(&header, at: 88, macTime(t.timePlayed))
    patchU32(&header, at: 92, t.discNumber)
    patchU32(&header, at: 96, t.discCount)
    patchU32(&header, at: 104, macTime(t.timeAdded))
    patchU32(&header, at: 0x6C, t.bookmarkMS)
    patchU64(&header, at: 112, t.dbid)
    patchU32(&header, at: 136, Float(t.samplerate).bitPattern)
    patchU32(&header, at: 0x8C, macTime(t.timeReleased))
    patchU8(&header, at: 0xA5, t.skipWhenShuffling ? 1 : 0)
    patchU8(&header, at: 0xA6, t.rememberPlaybackPosition ? 1 : 0)
    patchU32(&header, at: 0x9C, t.skipCount)
    patchU32(&header, at: 0xA0, macTime(t.lastSkipped))
    patchU64(&header, at: 168, t.dbid)
    patchU32(&header, at: 0xB8, t.pregap)
    patchU64(&header, at: 0xBC, t.sampleCount)
    patchU32(&header, at: 0xC8, t.postgap)
    patchU32(&header, at: 0xD0, t.mediaKind)
    patchU32(&header, at: 0xF8, t.gaplessData)
    patchU16(&header, at: 0x100, t.gaplessTrackFlag ? 1 : 0)
    patchU16(&header, at: 0x102, t.gaplessAlbumFlag ? 1 : 0)
    patchU32(&header, at: 288, albumID)
    patchU32(&header, at: 300, t.sizeBytes)
    patchU32(&header, at: 480, artistID)
    if let artwork = t.artwork {
      patchU16(&header, at: 0x7C, artwork.hasArtwork ? artwork.count : 0)
      patchU32(&header, at: 0x80, artwork.sizeBytes)
      patchU8(&header, at: 0xA4, artwork.hasArtwork ? 1 : 2)
      patchU32(&header, at: 0x160, artwork.mhiiID)
    }

    let start = w.count
    w.bytes(header)
    var mhods = writeTrackStringMhods(&w, t)
    for child in t.preservedMhods {
      w.bytes(child)
      mhods += 1
    }
    w.patchU32(UInt32(w.count - start), at: start + 8)
    w.patchU32(mhods, at: start + 12)
  }

  private func patchU8(_ data: inout Data, at offset: Int, _ value: UInt8) {
    guard offset < data.count else { return }
    data[offset] = value
  }

  private func patchU32(_ data: inout Data, at offset: Int, _ value: UInt32) {
    guard offset >= 0, offset + 4 <= data.count else { return }
    data.patchU32(value, at: offset)
  }

  private func patchU16(_ data: inout Data, at offset: Int, _ value: UInt16) {
    guard offset >= 0, offset + 2 <= data.count else { return }
    data.replaceSubrange(
      offset..<offset + 2, with: [UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  private func patchU64(_ data: inout Data, at offset: Int, _ value: UInt64) {
    patchU32(&data, at: offset, UInt32(value & 0xFFFF_FFFF))
    patchU32(&data, at: offset + 4, UInt32(value >> 32))
  }

  private func readU32(_ data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= data.count else { return nil }
    return LEBytes.u32(data, at: offset)
  }

  private func patchPlaylistPosition(_ data: inout Data, _ position: UInt32) {
    guard let headerLen = readU32(data, at: 4), let childCount = readU32(data, at: 12) else {
      return
    }
    var offset = Int(headerLen)
    for _ in 0..<childCount {
      guard let total = readU32(data, at: offset + 8), total >= 16,
        offset + Int(total) <= data.count
      else { return }
      if readU32(data, at: offset + 12) == MhodType.playlistPosition, total >= 28 {
        patchU32(&data, at: offset + 24, position)
      }
      offset += Int(total)
    }
    while offset + 16 <= data.count,
      Array(data[offset..<offset + 4]) == Array("mhod".utf8)
    {
      guard let total = readU32(data, at: offset + 8), total >= 16,
        offset + Int(total) <= data.count
      else { return }
      if readU32(data, at: offset + 12) == MhodType.playlistPosition, total >= 28 {
        patchU32(&data, at: offset + 24, position)
      }
      offset += Int(total)
    }
  }

  private func writePlaylistList(
    _ w: inout ByteWriter, _ playlists: [ITDBPlaylist], idForDbid: [UInt64: UInt32]
  ) {
    w.tag("mhlp")
    w.u32(92)
    w.u32(UInt32(playlists.count))
    w.zero32(20)
    for playlist in playlists {
      writeMhyp(&w, playlist, idForDbid: idForDbid)
    }
  }

  private func writeMhyp(
    _ w: inout ByteWriter, _ playlist: ITDBPlaylist, idForDbid: [UInt64: UInt32]
  ) {
    if playlist.isPodcast, playlist.preservedMhypHeader == nil {
      writePodcastMhyp(&w, playlist, idForDbid: idForDbid)
      return
    }
    if let preservedHeader = playlist.preservedMhypHeader {
      writePreservedMhyp(
        &w, playlist, header: preservedHeader, idForDbid: idForDbid)
      return
    }
    let start = w.count
    let members = playlist.memberDbids.compactMap { idForDbid[$0] }
    w.tag("mhyp")
    w.u32(108)
    w.u32(0)  // total, patched
    w.u32(2)  // mhods: title + display preferences
    w.u32(UInt32(members.count))
    w.u8(playlist.isMaster ? 1 : 0)
    w.u8(0)
    w.u8(0)
    w.u8(0)
    w.u32(macTime(playlist.timestamp))
    w.u64(playlist.persistentID)
    w.u32(0)
    w.u16(1)  // string mhod count
    w.u16(0)  // podcast flag
    w.u32(playlist.sortOrder)
    w.zero32(15)
    assert(w.count - start == 108)

    writeStringMhod(&w, type: MhodType.title, playlist.name)
    writePlaylistPrefsMhod(&w)

    for (position, trackID) in members.enumerated() {
      writeMhip(&w, trackID: trackID, position: UInt32(position))
    }

    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writePreservedMhyp(
    _ w: inout ByteWriter, _ playlist: ITDBPlaylist, header preservedHeader: Data,
    idForDbid: [UInt64: UInt32]
  ) {
    var header = preservedHeader
    patchU32(&header, at: 8, 0)
    patchU32(&header, at: 12, UInt32(1 + playlist.preservedMhods.count))
    patchU32(&header, at: 16, 0)
    patchU8(&header, at: 20, playlist.isMaster ? 1 : 0)
    patchU32(&header, at: 24, macTime(playlist.timestamp))
    patchU64(&header, at: 28, playlist.persistentID)
    patchU32(&header, at: 44, playlist.sortOrder)

    let start = w.count
    w.bytes(header)
    writeStringMhod(&w, type: MhodType.title, playlist.name)
    for mhod in playlist.preservedMhods { w.bytes(mhod) }

    var memberCount: UInt32 = 0
    if playlist.isPodcast {
      // A podcast playlist interleaves group headings with their episodes;
      // keep the original record order so shows stay above their episodes.
      for member in playlist.preservedMembers {
        if let dbid = member.dbid {
          guard let trackID = idForDbid[dbid] else { continue }
          var record = member.data
          patchU32(&record, at: 24, trackID)
          patchPlaylistPosition(&record, memberCount)
          w.bytes(record)
        } else {
          w.bytes(member.data)
        }
        memberCount += 1
      }
      w.patchU32(memberCount, at: start + 16)
      w.patchU32(UInt32(w.count - start), at: start + 8)
      return
    }
    var preservedMembers = PreservedMemberLookup(playlist.preservedMembers)
    for dbid in playlist.memberDbids {
      guard let trackID = idForDbid[dbid] else { continue }
      if var record = preservedMembers.takeRecord(for: dbid) {
        patchU32(&record, at: 24, trackID)
        patchPlaylistPosition(&record, memberCount)
        w.bytes(record)
      } else {
        writeMhip(&w, trackID: trackID, position: memberCount)
      }
      memberCount += 1
    }
    for record in preservedMembers.opaqueRecords {
      w.bytes(record)
      memberCount += 1
    }
    w.patchU32(memberCount, at: start + 16)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writeMhip(_ w: inout ByteWriter, trackID: UInt32, position: UInt32) {
    let start = w.count
    w.tag("mhip")
    w.u32(76)
    w.u32(0)
    w.u32(1)
    w.u32(0)
    w.u32(0)
    w.u32(trackID)
    w.u32(0)
    w.u32(0)
    w.zero32(10)
    w.tag("mhod")
    w.u32(24)
    w.u32(44)
    w.u32(MhodType.playlistPosition)
    w.zero32(2)
    w.u32(position)
    w.zero32(4)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  // MARK: - Podcast playlists

  private func writePodcastMhyp(
    _ w: inout ByteWriter, _ playlist: ITDBPlaylist, idForDbid: [UInt64: UInt32]
  ) {
    let start = w.count
    w.tag("mhyp")
    w.u32(108)
    w.u32(0)  // total, patched
    w.u32(2)  // mhods: title + display preferences
    w.u32(0)  // member count, patched
    w.u8(playlist.isMaster ? 1 : 0)
    w.u8(0)
    w.u8(0)
    w.u8(0)
    w.u32(macTime(playlist.timestamp))
    w.u64(playlist.persistentID)
    w.u32(0)
    w.u16(1)  // string mhod count
    w.u16(1)  // podcast flag
    w.u32(playlist.sortOrder)
    w.zero32(15)
    assert(w.count - start == 108)

    writeStringMhod(&w, type: MhodType.title, playlist.name)
    writePlaylistPrefsMhod(&w)

    var memberCount: UInt32 = 0
    var nextEntryID: UInt32 = 1
    for group in playlist.podcastGroups {
      let episodeIDs = group.episodeDbids.compactMap { idForDbid[$0] }
      guard !episodeIDs.isEmpty else { continue }
      let groupID = nextEntryID
      nextEntryID += 1
      writePodcastGroupMhip(&w, groupID: groupID, title: group.title)
      memberCount += 1
      for trackID in episodeIDs {
        writePodcastEpisodeMhip(
          &w, entryID: nextEntryID, trackID: trackID, groupRef: groupID,
          position: memberCount)
        nextEntryID += 1
        memberCount += 1
      }
    }
    w.patchU32(memberCount, at: start + 16)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writePodcastGroupMhip(_ w: inout ByteWriter, groupID: UInt32, title: String) {
    let start = w.count
    w.tag("mhip")
    w.u32(76)
    w.u32(0)  // total, patched
    w.u32(1)  // mhods: show title
    w.u32(256)  // podcast group flag
    w.u32(groupID)
    w.u32(0)  // track id: a group heading names no track
    w.u32(0)  // timestamp
    w.u32(0)  // podcast group ref
    w.zero32(10)
    writeStringMhod(&w, type: MhodType.title, title)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writePodcastEpisodeMhip(
    _ w: inout ByteWriter, entryID: UInt32, trackID: UInt32, groupRef: UInt32,
    position: UInt32
  ) {
    let start = w.count
    w.tag("mhip")
    w.u32(76)
    w.u32(0)  // total, patched
    w.u32(1)  // mhods: position
    w.u32(0)  // podcast group flag: episode
    w.u32(entryID)
    w.u32(trackID)
    w.u32(0)  // timestamp
    w.u32(groupRef)
    w.zero32(10)
    w.tag("mhod")
    w.u32(24)
    w.u32(44)
    w.u32(MhodType.playlistPosition)
    w.zero32(2)
    w.u32(position)
    w.zero32(4)
    w.patchU32(UInt32(w.count - start), at: start + 8)
  }

  private func writeStringMhod(_ w: inout ByteWriter, type: UInt32, _ s: String) {
    let utf16 = LEBytes.utf16(s)
    w.tag("mhod")
    w.u32(24)
    w.u32(UInt32(40 + utf16.count))
    w.u32(type)
    w.zero32(2)
    w.u32(1)  // string encoding: UTF-16LE
    w.u32(UInt32(utf16.count))
    w.u32(1)
    w.u32(0)
    w.bytes(Data(utf16))
  }

  private func writePlaylistPrefsMhod(_ w: inout ByteWriter) {
    let columns: [(descriptor: UInt32, isVisible: Bool)] = [
      (0x0012_0001, false),
      (0x00C8_0002, false),
      (0x003C_000D, false),
      (0x007D_0004, false),
      (0x007D_0003, false),
      (0x0064_0008, false),
      (0x0064_0017, true),
      (0x0050_0014, true),
      (0x007D_0015, true),
    ]
    let start = w.count
    let total: UInt32 = 0x288
    w.tag("mhod")
    w.u32(0x18)
    w.u32(total)
    w.u32(MhodType.playlistPosition)
    w.zero32(6)
    w.u32(0x010084)
    w.u32(0x05)
    w.u32(UInt32(columns.count))
    w.u32(UInt32(columns.filter { $0.isVisible }.count))
    for column in columns {
      w.u32(column.descriptor)
      w.u32(column.isVisible ? 1 : 0)
      w.zero32(2)
    }
    let remaining = Int(total) - (w.count - start)
    precondition(remaining >= 0 && remaining % 4 == 0)
    w.zero32(remaining / 4)
  }
}

// MARK: - Podcast playlist synthesis

extension ITunesDBWriter {
  static let podcastPlaylistName = "Podcasts"

  /// A deterministic persistent ID for the podcast playlist Nightdrive
  /// synthesizes, so a rewrite replaces the previous synthesized playlist
  /// while genuinely foreign podcast playlists keep their own IDs.
  static func synthesizedPodcastPlaylistID(for database: ITunesDatabase) -> UInt64 {
    let seed: UInt64 = 0x4E44_506F_6443_7374  // "NDPodCst"
    let id = database.libraryPersistentID ^ seed
    return id == 0 ? seed : id
  }

  /// Builds the special podcast playlist for the iPod's Podcasts menu:
  /// one group per show (album, falling back to artist), groups sorted
  /// alphabetically, episodes newest-first within each group. Returns nil
  /// when the database has no podcast tracks.
  static func synthesizedPodcastPlaylist(for database: ITunesDatabase) -> ITDBPlaylist? {
    let episodes = database.tracks.filter {
      $0.mediaKind == ITDBMediaKind.podcast.rawValue
    }
    guard !episodes.isEmpty else { return nil }

    func showName(_ track: ITDBTrack) -> String {
      if let album = track.album, !album.isEmpty { return album }
      if let artist = track.artist, !artist.isEmpty { return artist }
      return podcastPlaylistName
    }
    // Compare dates at the second granularity the mhit stores so ordering
    // is identical before and after a write/read round trip.
    func seconds(_ date: Date?) -> Int64 {
      date.map { Int64($0.timeIntervalSince1970) } ?? 0
    }
    func newestFirst(_ a: ITDBTrack, _ b: ITDBTrack) -> Bool {
      if seconds(a.timeReleased) != seconds(b.timeReleased) {
        return seconds(a.timeReleased) > seconds(b.timeReleased)
      }
      if a.year != b.year { return a.year > b.year }
      if seconds(a.timeAdded) != seconds(b.timeAdded) {
        return seconds(a.timeAdded) > seconds(b.timeAdded)
      }
      let aTitle = a.title ?? ""
      let bTitle = b.title ?? ""
      if aTitle != bTitle { return aTitle < bTitle }
      return a.dbid < b.dbid
    }

    var episodesByShow: [String: [ITDBTrack]] = [:]
    for episode in episodes {
      episodesByShow[showName(episode), default: []].append(episode)
    }
    var playlist = ITDBPlaylist(name: podcastPlaylistName, isMaster: false)
    playlist.persistentID = synthesizedPodcastPlaylistID(for: database)
    playlist.isPodcast = true
    playlist.timestamp = nil
    let shows = episodesByShow.keys.sorted { a, b in
      let order = a.caseInsensitiveCompare(b)
      return order == .orderedSame ? a < b : order == .orderedAscending
    }
    for show in shows {
      let sorted = episodesByShow[show, default: []].sorted(by: newestFirst)
      playlist.podcastGroups.append(
        ITDBPodcastGroup(title: show, episodeDbids: sorted.map(\.dbid)))
    }
    playlist.memberDbids = playlist.podcastGroups.flatMap(\.episodeDbids)
    return playlist
  }

  /// The podcast playlists a database should carry: foreign podcast
  /// playlists are preserved as-is, while the playlist Nightdrive
  /// synthesizes is rebuilt from the current podcast tracks (or dropped
  /// when none remain).
  static func normalizedPodcastPlaylists(for database: ITunesDatabase) -> [ITDBPlaylist] {
    let synthesizedID = synthesizedPodcastPlaylistID(for: database)
    var playlists = database.podcastPlaylists.filter { $0.persistentID != synthesizedID }
    if let synthesized = synthesizedPodcastPlaylist(for: database) {
      playlists.append(synthesized)
    }
    return playlists
  }
}
