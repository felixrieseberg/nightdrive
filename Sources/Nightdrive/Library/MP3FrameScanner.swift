import Foundation

struct MP3FrameHeader: Equatable, Sendable {
  let length: Int
  let samplesPerFrame: Int
  let sampleRate: Int
  let bitrate: Int
  let minimumBitrate: Int
  let sideInfoBytes: Int
}

struct LocatedMP3Frame: Equatable, Sendable {
  let offset: Int
  let header: MP3FrameHeader
}

enum MP3FrameScanner {
  private static let bitratesMPEG1 = [
    0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
  ]
  private static let bitratesMPEG2 = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160,
  ]
  private static let sampleRates = [44_100, 48_000, 32_000]

  static func frame(_ data: Data, at offset: Int) -> MP3FrameHeader? {
    guard offset >= 0, offset <= data.count, data.count - offset >= 4 else { return nil }
    let base = data.startIndex + offset
    let bits =
      UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
      | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    guard (bits >> 21) & 0x7FF == 0x7FF else { return nil }
    let versionBits = (bits >> 19) & 3  // 0 = MPEG2.5, 2 = MPEG2, 3 = MPEG1
    let layerBits = (bits >> 17) & 3  // 1 = Layer III
    let bitrateIndex = Int((bits >> 12) & 0xF)
    let sampleRateIndex = Int((bits >> 10) & 3)
    let paddingBit = Int((bits >> 9) & 1)
    let channelMode = (bits >> 6) & 3  // 3 = mono
    guard versionBits != 1, layerBits == 1,
      (1...14).contains(bitrateIndex), sampleRateIndex != 3
    else { return nil }

    let isMPEG1 = versionBits == 3
    let bitrates = isMPEG1 ? bitratesMPEG1 : bitratesMPEG2
    let bitrate = bitrates[bitrateIndex] * 1_000
    var sampleRate = sampleRates[sampleRateIndex]
    if versionBits == 2 { sampleRate /= 2 }
    if versionBits == 0 { sampleRate /= 4 }
    guard bitrate > 0, sampleRate > 0 else { return nil }
    let length = (isMPEG1 ? 144 : 72) * bitrate / sampleRate + paddingBit
    guard length > 4 else { return nil }
    let mono = channelMode == 3
    return MP3FrameHeader(
      length: length,
      samplesPerFrame: isMPEG1 ? 1_152 : 576,
      sampleRate: sampleRate,
      bitrate: bitrate,
      minimumBitrate: (isMPEG1 ? bitratesMPEG1 : bitratesMPEG2)[1] * 1_000,
      sideInfoBytes: isMPEG1 ? (mono ? 17 : 32) : (mono ? 9 : 17))
  }

  static func firstFrame(in data: Data) -> LocatedMP3Frame? {
    var offset = id3v2Length(data)
    guard offset >= 0, offset <= data.count else { return nil }
    let remaining = data.count - offset
    guard remaining >= 4 else { return nil }
    let searchDistance = min(remaining - 4, 65_536)
    guard let searchEnd = checkedAdd(offset, searchDistance) else { return nil }
    while offset <= searchEnd {
      if let header = frame(data, at: offset) {
        return LocatedMP3Frame(offset: offset, header: header)
      }
      guard offset < searchEnd, let next = checkedAdd(offset, 1) else { break }
      offset = next
    }
    return nil
  }

  static func id3v2Length(_ data: Data) -> Int {
    let base = data.startIndex
    guard data.count >= 10,
      data[base] == 0x49, data[base + 1] == 0x44, data[base + 2] == 0x33
    else { return 0 }
    let flags = data[base + 5]
    let size =
      Int(data[base + 6] & 0x7F) << 21 | Int(data[base + 7] & 0x7F) << 14
      | Int(data[base + 8] & 0x7F) << 7 | Int(data[base + 9] & 0x7F)
    guard let headerAndPayload = checkedAdd(10, size) else { return data.count }
    return checkedAdd(headerAndPayload, flags & 0x10 != 0 ? 10 : 0) ?? data.count
  }

  static func checkedAdd(_ lhs: Int, _ rhs: Int) -> Int? {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? nil : result.partialValue
  }
}
