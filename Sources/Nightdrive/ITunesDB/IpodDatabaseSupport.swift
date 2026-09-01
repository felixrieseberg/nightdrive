import CryptoKit
import Foundation

enum IpodDatabaseFormat: Equatable, Sendable {
  case legacy
  case hash58(firewireGUID: Data)
  case nano5(firewireGUID: Data)
}

struct IpodDatabaseSupport {
  let fileSystem: IpodFileSystem

  func formatForWriting() throws -> IpodDatabaseFormat {
    if hasNanoDatabase {
      let guid = try requiredFirewireGUID()
      try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fileSystem)
      return .nano5(firewireGUID: guid)
    }

    let databaseData =
      FileManager.default.fileExists(atPath: fileSystem.databaseURL.path)
      ? try Data(contentsOf: fileSystem.databaseURL, options: .mappedIfSafe)
      : nil
    return try formatForWriting(candidateDatabaseData: databaseData)
  }

  func formatForWriting(candidateDatabaseData: Data?) throws -> IpodDatabaseFormat {
    if hasNanoDatabase {
      return .nano5(firewireGUID: try requiredFirewireGUID())
    }

    if let header = candidateDatabaseData {
      guard header.count >= 108,
        String(bytes: header.prefix(4), encoding: .ascii) == "mhbd"
      else {
        throw ITunesDBError.badHeader("existing database has no valid mhbd header")
      }
      let scheme = u16(header, at: 48)
      let carriesHash58 = header[88..<108].contains { $0 != 0 }
      if scheme == 1 {
        return .hash58(firewireGUID: try requiredFirewireGUID())
      }
      if scheme == 0 {
        if carriesHash58 {
          return .hash58(firewireGUID: try requiredFirewireGUID())
        }
        return .legacy
      }
      throw ITunesDBError.unsupportedDevice(
        "This iPod uses database checksum scheme \(scheme), which Nightdrive cannot safely write.")
    }

    if fileSystem.deviceFamily().isShuffle {
      return .legacy
    }
    if let model = fileSystem.modelNumber(), Self.knownLegacyModels.contains(model) {
      return .legacy
    }
    throw ITunesDBError.unsupportedDevice(
      "Nightdrive could not determine this iPod's database format. Restore it once with "
        + "Apple's iPod software, then reconnect it.")
  }

  func prepareNanoForRepairIfNeeded() throws -> IpodDatabaseFormat? {
    guard hasNanoDatabase else { return nil }
    let guid = try requiredFirewireGUID()
    try Nano5DatabaseWriter.recoverIfNeeded(fileSystem: fileSystem)
    try validateNanoPrerequisites()
    return .nano5(firewireGUID: guid)
  }

  private var hasNanoDatabase: Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: fileSystem.compressedDatabaseURL.path)
      || fm.fileExists(atPath: fileSystem.sqliteLibraryDirectory.path)
      || Nano5DatabaseWriter.hasPendingTransaction(fileSystem: fileSystem)
  }

  func validateForWriting() throws {
    let format = try formatForWriting()
    guard case .nano5 = format else { return }
    try validateNanoPrerequisites()
  }

  private func validateNanoPrerequisites() throws {
    for name in [
      "Dynamic.itdb", "Extras.itdb", "Genius.itdb", "Library.itdb", "Locations.itdb",
    ] {
      let url = fileSystem.sqliteLibraryDirectory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw ITunesDBError.unsupportedDevice(
          "This nano 5G is missing \(name). Initialize it once with Apple's iPod software.")
      }
    }
    let database = try Data(contentsOf: fileSystem.compressedDatabaseURL)
    _ = try Hash72Material.load(from: fileSystem, database: database)
  }

  func firewireGUID() -> Data? {
    for url in [fileSystem.sysInfoURL, fileSystem.sysInfoExtendedURL] {
      guard let data = try? Data(contentsOf: url) else { continue }
      if let guid = guid(in: data) { return guid }
    }
    return nil
  }

  private func requiredFirewireGUID() throws -> Data {
    guard let guid = firewireGUID() else {
      throw ITunesDBError.unsupportedDevice(
        "This iPod requires database signing, but its FirewireGuid is missing from "
          + "iPod_Control/Device/SysInfo and SysInfoExtended.")
    }
    return guid
  }

  private func guid(in data: Data) -> Data? {
    let data = Data(data)
    if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = object as? [String: Any]
    {
      for key in ["FireWireGUID", "FirewireGuid", "SerialNumber"] {
        if let value = dictionary[key] as? String, let parsed = Self.parseGUID(value) {
          return parsed
        }
      }
    }
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    for line in text.split(whereSeparator: \.isNewline) {
      let pair = line.split(separator: ":", maxSplits: 1)
      guard pair.count == 2 else { continue }
      let key = pair[0].trimmingCharacters(in: .whitespaces)
      if ["FireWireGUID", "FirewireGuid", "SerialNumber"].contains(key),
        let parsed = Self.parseGUID(String(pair[1]))
      {
        return parsed
      }
    }
    return nil
  }

  static func parseGUID(_ value: String) -> Data? {
    var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.lowercased().hasPrefix("0x") { hex.removeFirst(2) }
    hex = String(hex.prefix(16))
    guard hex.count == 16, hex.allSatisfy(\.isHexDigit) else { return nil }
    var bytes = Data()
    var index = hex.startIndex
    for _ in 0..<8 {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes
  }

  private func u16(_ data: Data, at offset: Int) -> UInt16 {
    UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
  }

  private static let knownLegacyModels: Set<String> = [
    "M9160", "M9245", "M9268", "M9282", "M9585", "M9586", "MA079", "MA127",
    "M9724", "M9725", "MA133", "MA564", "MA947",
    "MB225", "MB227", "MB228", "MB229", "MB233",
    "MB518", "MB520", "MB522", "MB524", "MB526",
  ]
}

enum Hash58 {
  static func sign(_ database: Data, firewireGUID: Data) throws -> Data {
    let database = Data(database)
    guard database.count >= 108,
      String(bytes: database.prefix(4), encoding: .ascii) == "mhbd",
      firewireGUID.count == 8
    else {
      throw ITunesDBError.badHeader("cannot apply hash58")
    }

    var output = database
    output[48] = 1
    output[49] = 0

    var input = output
    input.replaceSubrange(24..<32, with: repeatElement(UInt8(0), count: 8))
    input.replaceSubrange(50..<70, with: repeatElement(UInt8(0), count: 20))
    input.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))

    let key = SymmetricKey(data: derivedKey(firewireGUID))
    let authentication = HMAC<Insecure.SHA1>.authenticationCode(for: input, using: key)
    output.replaceSubrange(88..<108, with: Data(authentication))
    return output
  }

  private static func derivedKey(_ guid: Data) -> Data {
    let bytes = [UInt8](guid)
    var transformed = Data()
    for index in stride(from: 0, to: 8, by: 2) {
      let multiple = leastCommonMultiple(Int(bytes[index]), Int(bytes[index + 1]))
      let high = UInt8((multiple >> 8) & 0xff)
      let low = UInt8(multiple & 0xff)
      transformed.append(aesSBox(high))
      transformed.append(aesInverseSBox(high))
      transformed.append(aesSBox(low))
      transformed.append(aesInverseSBox(low))
    }
    let fixed: [UInt8] = [
      0x67, 0x23, 0xfe, 0x30, 0x45, 0x33, 0xf8, 0x90, 0x99,
      0x21, 0x07, 0xc1, 0xd0, 0x12, 0xb2, 0xa1, 0x07, 0x81,
    ]
    return Data(Insecure.SHA1.hash(data: Data(fixed) + transformed))
  }

  private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
    var a = lhs
    var b = rhs
    while b != 0 {
      (a, b) = (b, a % b)
    }
    return a
  }

  private static func leastCommonMultiple(_ lhs: Int, _ rhs: Int) -> Int {
    guard lhs != 0, rhs != 0 else { return 1 }
    return lhs * rhs / greatestCommonDivisor(lhs, rhs)
  }

  private static func aesSBox(_ value: UInt8) -> UInt8 {
    let inverse = value == 0 ? UInt8(0) : gfPower(value, 254)
    return inverse ^ rotateLeft(inverse, 1) ^ rotateLeft(inverse, 2)
      ^ rotateLeft(inverse, 3) ^ rotateLeft(inverse, 4) ^ 0x63
  }

  private static func aesInverseSBox(_ value: UInt8) -> UInt8 {
    for candidate in UInt16(0)...UInt16(255)
    where aesSBox(UInt8(candidate)) == value {
      return UInt8(candidate)
    }
    preconditionFailure("AES S-box must be bijective")
  }

  private static func rotateLeft(_ value: UInt8, _ count: UInt8) -> UInt8 {
    (value << count) | (value >> (8 - count))
  }

  private static func gfPower(_ value: UInt8, _ exponent: Int) -> UInt8 {
    var result: UInt8 = 1
    var base = value
    var power = exponent
    while power > 0 {
      if power & 1 == 1 { result = gfMultiply(result, base) }
      base = gfMultiply(base, base)
      power >>= 1
    }
    return result
  }

  private static func gfMultiply(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
    var a = lhs
    var b = rhs
    var result: UInt8 = 0
    for _ in 0..<8 {
      if b & 1 != 0 { result ^= a }
      let highBit = a & 0x80
      a <<= 1
      if highBit != 0 { a ^= 0x1b }
      b >>= 1
    }
    return result
  }
}
