import Foundation

enum PlayCountsFile {
  static let filename = "Play Counts"

  static func url(in fileSystem: IpodFileSystem) -> URL {
    fileSystem.itunesDir.appendingPathComponent(filename)
  }

  struct Entry: Equatable, Sendable {
    var playCount: UInt32 = 0
    var lastPlayed: Date?
    var bookmarkMS: UInt32?
    var rating: UInt32?
    var skipCount: UInt32 = 0
    var lastSkipped: Date?
  }

  static func parse(_ data: Data, timezoneShift: Int) -> [Entry]? {
    guard data.count >= 16, LEBytes.tag(data, at: 0) == "mhdp" else { return nil }
    let headerLength = Int(LEBytes.u32(data, at: 4))
    let entryLength = Int(LEBytes.u32(data, at: 8))
    let entryCount = Int(LEBytes.u32(data, at: 12))
    guard headerLength >= 16, headerLength <= data.count else { return nil }
    if entryCount == 0 { return [] }
    guard entryLength >= 4, entryCount <= (data.count - headerLength) / entryLength else {
      return nil
    }
    var entries: [Entry] = []
    entries.reserveCapacity(entryCount)
    for index in 0..<entryCount {
      let base = headerLength + index * entryLength
      var entry = Entry()
      entry.playCount = LEBytes.u32(data, at: base)
      if entryLength >= 8 {
        entry.lastPlayed = date(LEBytes.u32(data, at: base + 4), timezoneShift: timezoneShift)
      }
      if entryLength >= 12 { entry.bookmarkMS = LEBytes.u32(data, at: base + 8) }
      if entryLength >= 16 { entry.rating = LEBytes.u32(data, at: base + 12) }
      if entryLength >= 24 { entry.skipCount = LEBytes.u32(data, at: base + 20) }
      if entryLength >= 28 {
        entry.lastSkipped = date(LEBytes.u32(data, at: base + 24), timezoneShift: timezoneShift)
      }
      entries.append(entry)
    }
    return entries
  }

  static func starRating(fromDeviceRating rating: UInt32) -> Int? {
    guard rating > 0 else { return nil }
    return max(1, min(5, Int(rating) / 20))
  }

  private static func date(_ macTime: UInt32, timezoneShift: Int) -> Date? {
    guard macTime != 0 else { return nil }
    let unix = Int64(macTime) - Int64(ITunesDBWriter.macEpochOffset) - Int64(timezoneShift)
    return Date(timeIntervalSince1970: TimeInterval(unix))
  }
}
