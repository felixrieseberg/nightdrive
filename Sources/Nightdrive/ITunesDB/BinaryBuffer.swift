import Foundation

struct ByteWriter {
  private(set) var data: Data

  init(capacity: Int = 0) {
    data = Data(capacity: capacity)
  }

  var count: Int { data.count }

  mutating func tag(_ s: String) {
    data.append(contentsOf: Array(s.utf8))
  }

  mutating func u8(_ v: UInt8) { data.append(v) }

  mutating func u16(_ v: UInt16) {
    withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func u32(_ v: UInt32) {
    withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

  mutating func u64(_ v: UInt64) {
    withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
  }

  mutating func f32(_ v: Float) { u32(v.bitPattern) }

  mutating func zero32(_ n: Int) { data.append(Data(count: n * 4)) }
  mutating func zero16(_ n: Int) { data.append(Data(count: n * 2)) }

  mutating func bytes(_ d: Data) { data.append(d) }

  mutating func patchU32(_ v: UInt32, at offset: Int) {
    precondition(offset + 4 <= data.count)
    withUnsafeBytes(of: v.littleEndian) { src in
      data.replaceSubrange(offset..<offset + 4, with: src)
    }
  }
}

extension Data {
  mutating func patchU32(_ value: UInt32, at offset: Int) {
    precondition(offset >= 0 && offset + 4 <= count, "patchU32 offset \(offset) out of bounds")
    let start = index(startIndex, offsetBy: offset)
    replaceSubrange(
      start..<index(start, offsetBy: 4),
      with: [
        UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
      ])
  }
}

enum ITunesDBError: Error, LocalizedError {
  case truncated(String)
  case badHeader(String)
  case notFound(String)
  case unsupportedDevice(String)

  var errorDescription: String? {
    switch self {
    case .truncated(let s): return String(localized: "iTunesDB is truncated or corrupt (\(s))")
    case .badHeader(let s): return String(localized: "Unexpected data in iTunesDB (\(s))")
    case .notFound(let s): return s
    case .unsupportedDevice(let s): return s
    }
  }
}

struct ByteReader {
  let data: Data

  init(_ data: Data) { self.data = data }

  var count: Int { data.count }

  private func contains(_ offset: Int, length: Int) -> Bool {
    offset >= 0 && length >= 0 && offset <= data.count - length
  }

  func u8(_ at: Int) throws -> UInt8 {
    guard contains(at, length: 1) else { throw ITunesDBError.truncated("u8 @\(at)") }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in bytes[at] }
  }

  func u16(_ at: Int) throws -> UInt16 {
    guard contains(at, length: 2) else { throw ITunesDBError.truncated("u16 @\(at)") }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
  }

  func u32(_ at: Int) throws -> UInt32 {
    guard contains(at, length: 4) else { throw ITunesDBError.truncated("u32 @\(at)") }
    return LEBytes.u32(data, at: at)
  }

  func u64(_ at: Int) throws -> UInt64 {
    let lo = try u32(at), hi = try u32(at + 4)
    return UInt64(lo) | UInt64(hi) << 32
  }

  func tag(_ at: Int) throws -> String {
    guard contains(at, length: 4) else { throw ITunesDBError.truncated("tag @\(at)") }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      String(bytes: bytes[at..<at + 4], encoding: .ascii) ?? ""
    }
  }

  func slice(_ at: Int, _ len: Int) throws -> Data {
    guard contains(at, length: len) else {
      throw ITunesDBError.truncated("slice @\(at) len \(len)")
    }
    return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
      Data(bytes[at..<at + len])
    }
  }
}

enum LEBytes {
  static func tag(_ data: Data, at offset: Int) -> String {
    let start = data.startIndex + offset
    return String(bytes: data[start..<start + 4], encoding: .ascii) ?? ""
  }

  static func u32(_ data: Data, at offset: Int) -> UInt32 {
    let start = data.startIndex + offset
    return UInt32(data[start]) | UInt32(data[start + 1]) << 8
      | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
  }

  static func utf16(_ s: String) -> [UInt8] {
    s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
  }

  static func utf16String(_ data: Data) -> String? {
    String(data: data, encoding: .utf16LittleEndian)
  }
}

enum IpodPath {
  static func slashSeparated(_ path: String) -> String {
    path.replacingOccurrences(of: ":", with: "/")
  }

  static func colonSeparated(_ path: String) -> String {
    path.replacingOccurrences(of: "/", with: ":")
  }
}
