import Foundation

enum OnTheGoPlaylist {
  static let filenamePrefix = "OTGPlaylistInfo"

  enum ParseError: Error, Equatable {
    case truncated
    case badMagic
    case badHeader
  }

  struct ParsedFile: Equatable, Sendable {
    var fileURL: URL
    var trackDbids: [UInt64]
    var droppedIndexCount: Int
  }

  static func playlistFileURLs(in fileSystem: IpodFileSystem) -> [URL] {
    let contents =
      (try? FileManager.default.contentsOfDirectory(
        at: fileSystem.itunesDir, includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])) ?? []
    return contents.filter { isPlaylistFileName($0.lastPathComponent) }
      .sorted { suffixNumber($0.lastPathComponent) < suffixNumber($1.lastPathComponent) }
  }

  static func isPlaylistFileName(_ name: String) -> Bool {
    guard name.hasPrefix(filenamePrefix) else { return false }
    let suffix = name.dropFirst(filenamePrefix.count)
    if suffix.isEmpty { return true }
    guard suffix.hasPrefix("_") else { return false }
    let digits = suffix.dropFirst()
    return !digits.isEmpty && digits.allSatisfy(\.isNumber)
  }

  private static func suffixNumber(_ name: String) -> Int {
    let suffix = name.dropFirst(filenamePrefix.count)
    guard suffix.hasPrefix("_"), let number = Int(suffix.dropFirst()) else { return 0 }
    return number
  }

  static func parseIndices(_ data: Data) throws -> [UInt32] {
    guard data.count >= 20 else { throw ParseError.truncated }
    guard LEBytes.tag(data, at: 0) == "mhpo" else { throw ParseError.badMagic }
    let headerLength = Int(LEBytes.u32(data, at: 4))
    let entryLength = Int(LEBytes.u32(data, at: 8))
    let entryCount = Int(LEBytes.u32(data, at: 12))
    guard headerLength >= 20, entryLength == 4, entryCount >= 0 else {
      throw ParseError.badHeader
    }
    guard headerLength <= data.count,
      entryCount <= (data.count - headerLength) / entryLength
    else { throw ParseError.truncated }
    return (0..<entryCount).map { LEBytes.u32(data, at: headerLength + $0 * entryLength) }
  }

  static func resolve(indices: [UInt32], tracks: [ITDBTrack]) -> (
    dbids: [UInt64], droppedIndexCount: Int
  ) {
    var dbids: [UInt64] = []
    var dropped = 0
    for index in indices {
      if let position = Int(exactly: index), position < tracks.count {
        dbids.append(tracks[position].dbid)
      } else {
        dropped += 1
      }
    }
    return (dbids, dropped)
  }

  static func collect(fileSystem: IpodFileSystem, tracks: [ITDBTrack]) -> (
    parsed: [ParsedFile], notes: [String]
  ) {
    var parsed: [ParsedFile] = []
    var notes: [String] = []
    for fileURL in playlistFileURLs(in: fileSystem) {
      let name = fileURL.lastPathComponent
      guard let data = try? Data(contentsOf: fileURL) else {
        notes.append(String(localized: "Ignored unreadable On-The-Go playlist file \(name)."))
        continue
      }
      let indices: [UInt32]
      do {
        indices = try parseIndices(data)
      } catch {
        notes.append(String(localized: "Ignored malformed On-The-Go playlist file \(name)."))
        continue
      }
      let resolved = resolve(indices: indices, tracks: tracks)
      if resolved.droppedIndexCount > 0 {
        notes.append(
          resolved.droppedIndexCount == 1
            ? String(
              localized:
                "\(name): 1 entry pointed at tracks that no longer exist and were dropped.")
            : String(
              localized:
                "\(name): \(resolved.droppedIndexCount) entries pointed at tracks that no longer exist and were dropped."
            ))
      }
      parsed.append(
        ParsedFile(
          fileURL: fileURL, trackDbids: resolved.dbids,
          droppedIndexCount: resolved.droppedIndexCount))
    }
    return (parsed, notes)
  }
}
