import AVFoundation
import Foundation

struct GaplessInfo: Hashable, Sendable, Codable {
  var pregap: UInt32
  var postgap: UInt32
  var sampleCount: UInt64
  var gaplessData: UInt32
}

enum GaplessScanner {
  static func scan(url: URL) async -> GaplessInfo? {
    switch url.pathExtension.lowercased() {
    case "mp3":
      guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
      return scanMP3(data)
    case "m4a", "m4b", "m4r", "mp4":
      return await scanMPEG4(url: url)
    default:
      return nil
    }
  }

  // MARK: - MPEG-4 (iTunSMPB)

  static func scanMPEG4(url: URL) async -> GaplessInfo? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.metadata) else { return nil }
    for item in metadata {
      let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
      guard key.contains("iTunSMPB") else { continue }
      var text = await item.loadedStringValue
      if text == nil, let data = await item.loadedDataValue {
        text = String(data: data, encoding: .utf8)
      }
      if let text, let info = parseITunSMPB(text) { return info }
    }
    return nil
  }

  static func parseITunSMPB(_ value: String) -> GaplessInfo? {
    let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
    guard fields.count >= 4,
      let priming = UInt32(fields[1], radix: 16),
      let padding = UInt32(fields[2], radix: 16),
      let samples = UInt64(fields[3], radix: 16),
      priming > 0, priming < 16384, samples > 0
    else { return nil }
    return GaplessInfo(
      pregap: priming, postgap: padding, sampleCount: samples, gaplessData: 0)
  }

  // MARK: - MP3 (Xing/Info + LAME tag)

  static func scanMP3(_ data: Data) -> GaplessInfo? {
    guard let located = MP3FrameScanner.firstFrame(in: data) else { return nil }
    let firstOffset = located.offset
    let first = located.header

    guard
      let xingOffset = MP3FrameScanner.checkedAdd(
        firstOffset, 4 + first.sideInfoBytes),
      let xingHeaderEnd = MP3FrameScanner.checkedAdd(xingOffset, 8),
      let firstFrameEnd = MP3FrameScanner.checkedAdd(firstOffset, first.length),
      xingHeaderEnd <= firstFrameEnd, xingHeaderEnd <= data.count
    else { return nil }
    let base = data.startIndex
    let magic = String(bytes: data[(base + xingOffset)..<(base + xingOffset + 4)], encoding: .ascii)
    guard magic == "Xing" || magic == "Info" else { return nil }
    let isCBR = magic == "Info"
    let flags =
      UInt32(data[base + xingOffset + 4]) << 24 | UInt32(data[base + xingOffset + 5]) << 16
      | UInt32(data[base + xingOffset + 6]) << 8 | UInt32(data[base + xingOffset + 7])
    var lameOffset = xingHeaderEnd
    if flags & 0x1 != 0 {  // frame count
      guard let next = MP3FrameScanner.checkedAdd(lameOffset, 4) else { return nil }
      lameOffset = next
    }
    if flags & 0x2 != 0 {  // byte count
      guard let next = MP3FrameScanner.checkedAdd(lameOffset, 4) else { return nil }
      lameOffset = next
    }
    if flags & 0x4 != 0 {  // TOC
      guard let next = MP3FrameScanner.checkedAdd(lameOffset, 100) else { return nil }
      lameOffset = next
    }
    if flags & 0x8 != 0 {  // VBR scale
      guard let next = MP3FrameScanner.checkedAdd(lameOffset, 4) else { return nil }
      lameOffset = next
    }
    let lameTagSize = 0x24
    guard let lameEnd = MP3FrameScanner.checkedAdd(lameOffset, lameTagSize),
      lameEnd <= firstFrameEnd, lameEnd <= data.count,
      String(bytes: data[(base + lameOffset)..<(base + lameOffset + 4)], encoding: .ascii)
        == "LAME"
    else { return nil }
    let delay =
      UInt32(data[base + lameOffset + 0x15]) << 4 | UInt32(data[base + lameOffset + 0x16]) >> 4
    let padding =
      UInt32(data[base + lameOffset + 0x16] & 0xF) << 8 | UInt32(data[base + lameOffset + 0x17])

    var totalDataSize = Int64(first.length)
    var musicFrames = 0
    var lastEight = [Int](repeating: 0, count: 8)
    guard var pos = MP3FrameScanner.checkedAdd(firstOffset, first.length) else { return nil }
    while let f = MP3FrameScanner.frame(data, at: pos),
      let next = MP3FrameScanner.checkedAdd(pos, f.length), next <= data.count
    {
      lastEight[musicFrames % 8] = f.length
      let byteResult = totalDataSize.addingReportingOverflow(Int64(f.length))
      let frameResult = musicFrames.addingReportingOverflow(1)
      guard !byteResult.overflow, !frameResult.overflow else { return nil }
      totalDataSize = byteResult.partialValue
      musicFrames = frameResult.partialValue
      pos = next
    }
    guard musicFrames > 0 else { return nil }
    let finalEight = lastEight.prefix(min(8, musicFrames)).reduce(Int64(0)) {
      $0 + Int64($1)
    }

    let frameResult = musicFrames.addingReportingOverflow(isCBR ? 1 : 0)
    guard !frameResult.overflow else { return nil }
    let sampleResult = Int64(frameResult.partialValue).multipliedReportingOverflow(
      by: Int64(first.samplesPerFrame))
    guard !sampleResult.overflow else { return nil }
    let afterDelay = sampleResult.partialValue.subtractingReportingOverflow(Int64(delay))
    guard !afterDelay.overflow else { return nil }
    let afterPadding = afterDelay.partialValue.subtractingReportingOverflow(Int64(padding))
    guard !afterPadding.overflow else { return nil }
    return makeMP3Info(
      delay: delay, padding: padding, sampleCount: afterPadding.partialValue,
      gaplessData: totalDataSize - finalEight)
  }

  static func makeMP3Info(
    delay: UInt32, padding: UInt32, sampleCount: Int64, gaplessData: Int64
  ) -> GaplessInfo? {
    guard delay > 0, padding > 0, sampleCount > 0,
      gaplessData > 0, gaplessData <= Int64(UInt32.max)
    else { return nil }
    return GaplessInfo(
      pregap: delay, postgap: padding,
      sampleCount: UInt64(sampleCount), gaplessData: UInt32(gaplessData))
  }
}
