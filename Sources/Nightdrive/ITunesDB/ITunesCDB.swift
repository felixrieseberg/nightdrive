import CommonCrypto
import Compression
import CryptoKit
import Foundation

enum ITunesCDB {
  static let maximumExpandedBodySize = 512 * 1_024 * 1_024

  static func compress(_ database: Data) throws -> Data {
    let database = Data(database)
    guard database.count >= 0xa9 else {
      throw ITunesDBError.badHeader("iTunesCDB header is too small")
    }
    let headerLength = Int(LEBytes.u32(database, at: 4))
    guard headerLength >= 0xa9, headerLength <= database.count else {
      throw ITunesDBError.badHeader("invalid iTunesCDB header length")
    }
    let body = database[headerLength...]
    let compressed = try (Data(body) as NSData).compressed(using: .zlib) as Data
    var output = Data(database.prefix(headerLength))
    output[0xa8] = 1
    output.append(compressed)
    output.patchU32(UInt32(output.count), at: 8)
    return output
  }

  static func decompress(
    _ database: Data,
    maximumExpandedBodySize: Int = Self.maximumExpandedBodySize
  ) throws -> Data {
    let database = Data(database)
    guard database.count >= 0xa9 else {
      throw ITunesDBError.badHeader("iTunesCDB header is too small")
    }
    let headerLength = Int(LEBytes.u32(database, at: 4))
    let totalLength = Int(LEBytes.u32(database, at: 8))
    guard headerLength >= 0xa9, headerLength <= totalLength, totalLength <= database.count else {
      throw ITunesDBError.badHeader("invalid iTunesCDB lengths")
    }
    guard database[0xa8] == 1 else {
      if database[0xa8] == 0 { return database }
      throw ITunesDBError.badHeader("unknown iTunesCDB compression flag")
    }
    let body = database[headerLength..<totalLength]
    let expanded = try decompressZlib(
      Data(body), maximumOutputSize: maximumExpandedBodySize)
    var output = Data(database.prefix(headerLength))
    output[0xa8] = 0
    output.append(expanded)
    output.patchU32(UInt32(output.count), at: 8)
    return output
  }

  private static func decompressZlib(_ input: Data, maximumOutputSize: Int) throws -> Data {
    guard maximumOutputSize >= 0 else {
      throw ITunesDBError.badHeader("invalid iTunesCDB expansion limit")
    }
    return try input.withUnsafeBytes { sourceBytes in
      let emptyDestination = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
      let emptySource = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
      defer {
        emptyDestination.deallocate()
        emptySource.deallocate()
      }
      var stream = compression_stream(
        dst_ptr: emptyDestination, dst_size: 0, src_ptr: UnsafePointer(emptySource), src_size: 0,
        state: nil)
      guard
        compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
          != COMPRESSION_STATUS_ERROR
      else {
        throw ITunesDBError.badHeader("could not initialize iTunesCDB decompression")
      }
      defer { compression_stream_destroy(&stream) }

      stream.src_ptr =
        sourceBytes.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(emptySource)
      stream.src_size = sourceBytes.count
      var expanded = Data()
      expanded.reserveCapacity(min(maximumOutputSize, max(input.count * 4, 64 * 1_024)))
      var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
      let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)

      while true {
        let status = buffer.withUnsafeMutableBytes { destinationBytes in
          stream.dst_ptr =
            destinationBytes.bindMemory(to: UInt8.self).baseAddress ?? emptyDestination
          stream.dst_size = destinationBytes.count
          return compression_stream_process(&stream, flags)
        }
        let produced = buffer.count - stream.dst_size
        guard produced <= maximumOutputSize - expanded.count else {
          throw ITunesDBError.badHeader(
            "iTunesCDB expands beyond the \(maximumOutputSize)-byte safety limit")
        }
        expanded.append(contentsOf: buffer.prefix(produced))

        if status == COMPRESSION_STATUS_END { return expanded }
        guard status == COMPRESSION_STATUS_OK, produced > 0 || stream.src_size > 0 else {
          throw ITunesDBError.badHeader("invalid iTunesCDB compressed data")
        }
      }
    }
  }

}

struct Hash72Material: Equatable, Sendable {
  let initializationVector: Data
  let randomBytes: Data

  static func load(from fileSystem: IpodFileSystem, database: Data) throws -> Self {
    let database = Data(database)
    let extracted = extract(from: database)
    let hashInfoURL = fileSystem.controlDir.appendingPathComponent("Device/HashInfo")
    if let info = try? Data(contentsOf: hashInfoURL),
      info.count == 54,
      info.prefix(6) == Data("HASHv0".utf8),
      let guid = IpodDatabaseSupport(fileSystem: fileSystem).firewireGUID(),
      info[6..<26] == deviceIdentifier(for: guid)
    {
      let stored = Self(
        initializationVector: info[38..<54],
        randomBytes: info[26..<38])
      if let extracted { return extracted }
      return stored
    }
    guard let extracted else {
      throw ITunesDBError.unsupportedDevice(
        "This nano 5G needs signing information. Sync at least one song with Apple's "
          + "iPod software once, then reconnect it.")
    }
    return extracted
  }

  static func deviceIdentifier(for firewireGUID: Data) -> Data {
    var identifier = Data(firewireGUID.prefix(20))
    identifier.append(Data(count: max(0, 20 - identifier.count)))
    return identifier
  }

  static func extract(from database: Data) -> Self? {
    let database = Data(database)
    guard database.count >= 160 else { return nil }
    let signature = Data(database[114..<160])
    guard signature[0] == 1, signature[1] == 0 else { return nil }
    let random = Data(signature[2..<14])
    let ciphertext = Data(signature[14..<46])

    var hashInput = database
    hashInput.replaceSubrange(24..<32, with: repeatElement(UInt8(0), count: 8))
    hashInput.replaceSubrange(88..<108, with: repeatElement(UInt8(0), count: 20))
    hashInput.replaceSubrange(114..<160, with: repeatElement(UInt8(0), count: 46))
    let digest = Data(Insecure.SHA1.hash(data: hashInput))

    guard
      let firstBlock = aesCrypt(
        Data(ciphertext.prefix(16)), operation: CCOperation(kCCDecrypt), options: kCCOptionECBMode,
        initializationVector: nil)
    else { return nil }
    let iv = Data(zip(firstBlock, digest.prefix(16)).map(^))
    let material = Self(initializationVector: iv, randomBytes: random)
    return material.signature(forSHA1: digest) == signature ? material : nil
  }

  func signature(forSHA1 sha1: Data) -> Data {
    precondition(sha1.count == 20 && initializationVector.count == 16 && randomBytes.count == 12)
    let plaintext = sha1 + randomBytes
    guard
      let ciphertext = Self.aesCrypt(
        plaintext, operation: CCOperation(kCCEncrypt), options: 0,
        initializationVector: initializationVector)
    else {
      preconditionFailure("CommonCrypto AES encryption failed")
    }
    return Data([1, 0]) + randomBytes + ciphertext
  }

  private static func aesCrypt(
    _ input: Data, operation: CCOperation, options: Int,
    initializationVector: Data?
  ) -> Data? {
    let key = Data([
      0x61, 0x8c, 0xa1, 0x0d, 0xc7, 0xf5, 0x7f, 0xd3,
      0xb4, 0x72, 0x3e, 0x08, 0x15, 0x74, 0x63, 0xd7,
    ])
    var output = Data(count: input.count)
    let outputCount = output.count
    var written = 0
    let status = output.withUnsafeMutableBytes { outputBytes in
      input.withUnsafeBytes { inputBytes in
        key.withUnsafeBytes { keyBytes in
          if let initializationVector {
            return initializationVector.withUnsafeBytes { ivBytes in
              CCCrypt(
                operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                inputBytes.baseAddress, input.count,
                outputBytes.baseAddress, outputCount, &written)
            }
          }
          return CCCrypt(
            operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(options),
            keyBytes.baseAddress, key.count, nil,
            inputBytes.baseAddress, input.count,
            outputBytes.baseAddress, outputCount, &written)
        }
      }
    }
    guard status == kCCSuccess, written == input.count else { return nil }
    return output
  }
}
