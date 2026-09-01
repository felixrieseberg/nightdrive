import Foundation

enum ITunesSDFile {
  static let headerLength = 18
  static let entryLength = 558
  static let pathCodeUnits = 261

  enum Filetype: Int, Equatable, Sendable {
    case mp3 = 1
    case aac = 2
    case wav = 4

    init(ipodPath: String) {
      switch (ipodPath as NSString).pathExtension.lowercased() {
      case "m4a", "m4b", "m4p", "aac", "mp4": self = .aac
      case "wav": self = .wav
      default: self = .mp3
      }
    }
  }

  struct Entry: Equatable, Sendable {
    var ipodPath: String
    var filetype: Filetype
    var volume: Int = 100
    var startTime: Int = 0
    var stopTime: Int = 0
    var shuffleable = true
    var bookmarkable = false
  }

  static func entry(forIpodPath ipodPath: String) -> Entry {
    let bookmarkable = ipodPath.lowercased().hasSuffix(".m4b")
    return Entry(
      ipodPath: ipodPath,
      filetype: Filetype(ipodPath: ipodPath),
      shuffleable: !bookmarkable,
      bookmarkable: bookmarkable)
  }

  // MARK: - Writing

  static func write(_ entries: [Entry]) -> Data {
    var data = Data(capacity: headerLength + entries.count * entryLength)
    appendUInt24(&data, entries.count)
    appendUInt24(&data, 0x01_06_00)
    appendUInt24(&data, headerLength)
    data.append(contentsOf: [UInt8](repeating: 0, count: 9))
    for entry in entries {
      appendUInt24(&data, entryLength)
      appendUInt24(&data, 0x5A_A5_01)
      appendUInt24(&data, entry.startTime)
      appendUInt24(&data, 0)
      appendUInt24(&data, 0)
      appendUInt24(&data, entry.stopTime)
      appendUInt24(&data, 0)
      appendUInt24(&data, 0)
      appendUInt24(&data, min(max(entry.volume, 0), 200))
      appendUInt24(&data, entry.filetype.rawValue)
      appendUInt24(&data, 0x00_02_00)
      appendPath(&data, entry.ipodPath)
      data.append(entry.shuffleable ? 1 : 0)
      data.append(entry.bookmarkable ? 1 : 0)
      data.append(0)
    }
    return data
  }

  // MARK: - Reading

  static func read(_ data: Data) throws -> [Entry] {
    let data = Data(data)  // rebase any slice to zero
    guard data.count >= headerLength else {
      throw ITunesDBError.badHeader("iTunesSD is shorter than its header")
    }
    let count = uint24(data, at: 0)
    guard uint24(data, at: 3) == 0x01_06_00, uint24(data, at: 6) == headerLength else {
      throw ITunesDBError.badHeader("iTunesSD header constants are wrong")
    }
    guard data.count == headerLength + count * entryLength else {
      throw ITunesDBError.badHeader(
        "iTunesSD length does not match its \(count)-song header")
    }
    var entries: [Entry] = []
    entries.reserveCapacity(count)
    for index in 0..<count {
      let base = headerLength + index * entryLength
      guard uint24(data, at: base) == entryLength,
        uint24(data, at: base + 3) == 0x5A_A5_01
      else {
        throw ITunesDBError.badHeader("iTunesSD entry \(index) is malformed")
      }
      guard let filetype = Filetype(rawValue: uint24(data, at: base + 27)) else {
        throw ITunesDBError.badHeader("iTunesSD entry \(index) has an unknown filetype")
      }
      guard let path = readPath(data, at: base + 33) else {
        throw ITunesDBError.badHeader("iTunesSD entry \(index) has an unreadable path")
      }
      entries.append(
        Entry(
          ipodPath: IpodPath.colonSeparated(path),
          filetype: filetype,
          volume: uint24(data, at: base + 24),
          startTime: uint24(data, at: base + 6),
          stopTime: uint24(data, at: base + 15),
          shuffleable: data[base + 555] != 0,
          bookmarkable: data[base + 556] != 0))
    }
    return entries
  }

  // MARK: - Field encoding

  private static func appendUInt24(_ data: inout Data, _ value: Int) {
    let clamped = UInt32(min(max(value, 0), 0xFF_FF_FF))
    data.append(UInt8((clamped >> 16) & 0xFF))
    data.append(UInt8((clamped >> 8) & 0xFF))
    data.append(UInt8(clamped & 0xFF))
  }

  private static func uint24(_ data: Data, at offset: Int) -> Int {
    Int(data[offset]) << 16 | Int(data[offset + 1]) << 8 | Int(data[offset + 2])
  }

  private static func appendPath(_ data: inout Data, _ ipodPath: String) {
    let slashed = IpodPath.slashSeparated(ipodPath)
    var units = Array(slashed.utf16.prefix(pathCodeUnits))
    units.append(contentsOf: [UInt16](repeating: 0, count: pathCodeUnits - units.count))
    for unit in units {
      data.append(UInt8(unit & 0xFF))
      data.append(UInt8(unit >> 8))
    }
  }

  private static func readPath(_ data: Data, at offset: Int) -> String? {
    var units: [UInt16] = []
    units.reserveCapacity(pathCodeUnits)
    for index in 0..<pathCodeUnits {
      let unit = UInt16(data[offset + index * 2]) | UInt16(data[offset + index * 2 + 1]) << 8
      if unit == 0 { break }
      units.append(unit)
    }
    guard !units.isEmpty else { return nil }
    return String(decoding: units, as: UTF16.self)
  }
}
