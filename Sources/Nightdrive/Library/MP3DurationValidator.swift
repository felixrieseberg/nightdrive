import Foundation

struct MP3DurationFacts: Equatable, Sendable {
  let minimumBitrate: Int
  let declaredFrameCount: UInt32?
  let declaredByteCount: UInt32?
  let physicalFrameCount: Int?
  let physicalDurationSeconds: Double?
}

enum MP3DurationValidator {
  /// Inspect the declarations near the first frame and walk the complete stream only when the
  /// decoder/asset durations or the declarations give us a reason not to trust the cheap answer.
  /// Mapping the file does not page all of its audio bytes in; the common path below touches only
  /// the ID3 header, the first-frame search window, and the first MPEG frame.
  static func inspect(
    url: URL, assetSeconds: Double?, decoderSeconds: Double?,
    isCancelled: () -> Bool = { false }
  ) -> MP3DurationFacts? {
    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    guard let inspection = inspect(data, walkPhysicalFrames: false, isCancelled: isCancelled)
    else { return nil }
    guard
      shouldWalkPhysicalFrames(
        inspection, assetSeconds: assetSeconds, decoderSeconds: decoderSeconds,
        data: data)
    else { return inspection.facts }
    return inspect(data, walkPhysicalFrames: true, isCancelled: isCancelled)?.facts
  }

  static func inspect(_ data: Data) -> MP3DurationFacts? {
    inspect(data, walkPhysicalFrames: true, isCancelled: { false })?.facts
  }

  private struct Inspection {
    let facts: MP3DurationFacts
    let first: LocatedMP3Frame
    let hasXingHeader: Bool
    let declarationsAreWellFormed: Bool
  }

  private static func inspect(
    _ data: Data, walkPhysicalFrames: Bool, isCancelled: () -> Bool
  ) -> Inspection? {
    guard let first = MP3FrameScanner.firstFrame(in: data) else { return nil }
    let header = first.header
    guard let xingOffset = MP3FrameScanner.checkedAdd(first.offset, 4 + header.sideInfoBytes),
      let firstFrameEnd = MP3FrameScanner.checkedAdd(first.offset, header.length),
      let xingHeaderEnd = MP3FrameScanner.checkedAdd(xingOffset, 8),
      xingHeaderEnd <= firstFrameEnd, xingHeaderEnd <= data.count
    else {
      return Inspection(
        facts: MP3DurationFacts(
          minimumBitrate: header.minimumBitrate,
          declaredFrameCount: nil, declaredByteCount: nil,
          physicalFrameCount: nil, physicalDurationSeconds: nil),
        first: first, hasXingHeader: false, declarationsAreWellFormed: true)
    }

    let base = data.startIndex
    let magic = String(
      bytes: data[(base + xingOffset)..<(base + xingOffset + 4)], encoding: .ascii)
    guard magic == "Xing" || magic == "Info" else {
      return Inspection(
        facts: MP3DurationFacts(
          minimumBitrate: header.minimumBitrate,
          declaredFrameCount: nil, declaredByteCount: nil,
          physicalFrameCount: nil, physicalDurationSeconds: nil),
        first: first, hasXingHeader: false, declarationsAreWellFormed: true)
    }

    let declarations = xingDeclarations(
      data, flagsOffset: xingOffset + 4, firstFrameEnd: firstFrameEnd)
    let declaredFrameCount = declarations?.frameCount
    let declaredByteCount = declarations?.byteCount

    let walked =
      walkPhysicalFrames
      ? walkContiguousFrames(data, from: first, isCancelled: isCancelled) : nil
    let walkIsTrustworthy =
      walked.map {
        trailingBytesAreMetadataOrPadding(data, from: $0.endOffset)
          || declaredByteCount.flatMap(Int.init(exactly:)) == $0.audioBytes
      } ?? false
    return Inspection(
      facts: MP3DurationFacts(
        minimumBitrate: header.minimumBitrate,
        declaredFrameCount: declaredFrameCount,
        declaredByteCount: declaredByteCount,
        physicalFrameCount: walkIsTrustworthy ? walked?.frameCount : nil,
        physicalDurationSeconds: walkIsTrustworthy ? walked?.durationSeconds : nil),
      first: first, hasXingHeader: true,
      declarationsAreWellFormed: declarations != nil)
  }

  static func resolveDurationSeconds(
    assetSeconds: Double?, decoderSeconds: Double?, fileSizeBytes: Int,
    facts: MP3DurationFacts?
  ) -> Double? {
    let minimumBitrate = facts?.minimumBitrate ?? 8_000
    let plausibilityBytes =
      facts?.declaredByteCount.flatMap(Int.init(exactly:)).flatMap {
        $0 > 0 && $0 <= fileSizeBytes ? $0 : nil
      } ?? fileSizeBytes
    let candidates = [assetSeconds, decoderSeconds].compactMap { seconds -> Double? in
      guard let seconds, checkedMilliseconds(seconds: seconds) != nil,
        isPlausible(
          seconds: seconds, fileSizeBytes: plausibilityBytes,
          minimumBitrate: minimumBitrate)
      else { return nil }
      return seconds
    }

    guard let physical = facts?.physicalDurationSeconds,
      checkedMilliseconds(seconds: physical) != nil
    else {
      return candidates.first
    }
    if let agreeing = candidates.first(where: { durationsAgree($0, physical) }) {
      return agreeing
    }
    return physical
  }

  static func checkedMilliseconds(seconds: Double) -> Int? {
    guard seconds.isFinite, seconds > 0 else { return nil }
    let milliseconds = seconds * 1_000
    guard milliseconds.isFinite, milliseconds >= 1,
      milliseconds < Double(Int.max)
    else { return nil }
    return Int(milliseconds)
  }

  static func checkedBitrateKbps(sizeBytes: Int, durationMS: Int) -> Int? {
    guard sizeBytes >= 0, durationMS > 0 else { return nil }
    let bitrate = Double(sizeBytes) * 8 / Double(durationMS)
    guard bitrate.isFinite, bitrate >= 0, bitrate < Double(Int.max) else { return nil }
    return Int(bitrate)
  }

  private static func isPlausible(
    seconds: Double, fileSizeBytes: Int, minimumBitrate: Int
  ) -> Bool {
    guard fileSizeBytes > 0, minimumBitrate > 0 else { return false }
    let averageBitrate = Double(fileSizeBytes) * 8 / seconds
    guard averageBitrate.isFinite, averageBitrate > 0 else { return false }
    return averageBitrate >= Double(minimumBitrate)
  }

  private static func durationsAgree(_ first: Double, _ second: Double) -> Bool {
    let tolerance = max(0.25, min(5, second * 0.02))
    return abs(first - second) <= tolerance
  }

  private static func shouldWalkPhysicalFrames(
    _ inspection: Inspection, assetSeconds: Double?, decoderSeconds: Double?,
    data: Data
  ) -> Bool {
    guard inspection.hasXingHeader else { return false }
    guard inspection.declarationsAreWellFormed else { return true }

    let facts = inspection.facts
    guard let frameCount = facts.declaredFrameCount, frameCount > 0,
      let byteCount = facts.declaredByteCount, byteCount > 0,
      let bytes = Int(exactly: byteCount),
      let declaredEnd = MP3FrameScanner.checkedAdd(inspection.first.offset, bytes),
      declaredEnd <= data.count,
      trailingBytesAreMetadataOrPadding(data, from: declaredEnd)
    else { return true }

    let candidates = [assetSeconds, decoderSeconds].compactMap { seconds -> Double? in
      guard let seconds, checkedMilliseconds(seconds: seconds) != nil,
        isPlausible(
          seconds: seconds,
          fileSizeBytes: bytes,
          minimumBitrate: facts.minimumBitrate)
      else { return nil }
      return seconds
    }
    // AVFoundation and the decoder are independent enough to make agreement the useful cheap
    // signal. If either source is missing or they disagree, retain the old physical safeguard.
    guard candidates.count == 2, durationsAgree(candidates[0], candidates[1]) else { return true }

    let declaredSeconds =
      Double(frameCount) * Double(inspection.first.header.samplesPerFrame)
      / Double(inspection.first.header.sampleRate)
    guard checkedMilliseconds(seconds: declaredSeconds) != nil,
      candidates.allSatisfy({ durationsAgree($0, declaredSeconds) })
    else { return true }

    let averageBitrate = Double(byteCount) * 8 / declaredSeconds
    guard averageBitrate.isFinite,
      averageBitrate >= Double(facts.minimumBitrate), averageBitrate <= 320_000
    else { return true }
    return false
  }

  private static func walkContiguousFrames(
    _ data: Data, from first: LocatedMP3Frame, isCancelled: () -> Bool
  ) -> (frameCount: Int, durationSeconds: Double, audioBytes: Int, endOffset: Int)? {
    var offset = first.offset
    var frameCount = 0
    var durationSeconds = 0.0
    var audioBytes = 0
    while let frame = MP3FrameScanner.frame(data, at: offset),
      let next = MP3FrameScanner.checkedAdd(offset, frame.length), next <= data.count
    {
      if frameCount.isMultiple(of: 1_024), isCancelled() { return nil }
      let countResult = frameCount.addingReportingOverflow(1)
      let byteResult = audioBytes.addingReportingOverflow(frame.length)
      guard !countResult.overflow, !byteResult.overflow else { return nil }
      frameCount = countResult.partialValue
      audioBytes = byteResult.partialValue
      durationSeconds += Double(frame.samplesPerFrame) / Double(frame.sampleRate)
      guard durationSeconds.isFinite else { return nil }
      offset = next
    }
    guard frameCount >= 2 else { return nil }
    return (frameCount, durationSeconds, audioBytes, offset)
  }

  private static func trailingBytesAreMetadataOrPadding(_ data: Data, from offset: Int) -> Bool {
    guard offset >= 0, offset <= data.count else { return false }
    if offset == data.count { return true }
    let trailing = data[(data.startIndex + offset)..<data.endIndex]
    if trailing.count == 128, trailing.starts(with: Data("TAG".utf8)) { return true }
    return trailing.count <= 4_096 && trailing.allSatisfy { $0 == 0 }
  }

  private static func xingDeclarations(
    _ data: Data, flagsOffset: Int, firstFrameEnd: Int
  ) -> (frameCount: UInt32?, byteCount: UInt32?)? {
    guard let flagsField = u32(data, at: flagsOffset, endingAt: firstFrameEnd) else {
      return nil
    }
    let flags = flagsField.value
    var cursor = flagsField.end
    var frameCount: UInt32?
    var byteCount: UInt32?

    if flags & 0x1 != 0 {
      guard let field = u32(data, at: cursor, endingAt: firstFrameEnd) else { return nil }
      frameCount = field.value
      cursor = field.end
    }
    if flags & 0x2 != 0 {
      guard let field = u32(data, at: cursor, endingAt: firstFrameEnd) else { return nil }
      byteCount = field.value
      cursor = field.end
    }
    if flags & 0x4 != 0 {
      guard
        let end = boundedEnd(
          in: data, at: cursor, count: 100, endingAt: firstFrameEnd)
      else { return nil }
      cursor = end
    }
    if flags & 0x8 != 0 {
      guard u32(data, at: cursor, endingAt: firstFrameEnd) != nil else { return nil }
    }
    return (frameCount, byteCount)
  }

  private static func u32(
    _ data: Data, at offset: Int, endingAt logicalEnd: Int
  ) -> (value: UInt32, end: Int)? {
    guard let end = boundedEnd(in: data, at: offset, count: 4, endingAt: logicalEnd)
    else { return nil }
    let base = data.startIndex + offset
    let value =
      UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
      | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    return (value, end)
  }

  private static func boundedEnd(
    in data: Data, at offset: Int, count: Int, endingAt logicalEnd: Int
  ) -> Int? {
    guard offset >= 0, count >= 0,
      let end = MP3FrameScanner.checkedAdd(offset, count),
      end <= logicalEnd, end <= data.count
    else { return nil }
    return end
  }
}
