import Foundation

struct MusicBrainzTrackIDs: Equatable, Sendable {
  var recordingID = ""
  var releaseID = ""
  var artistID = ""

  var isEmpty: Bool { recordingID.isEmpty && releaseID.isEmpty && artistID.isEmpty }
}

enum MusicBrainzID3 {
  static let ufidOwner = "http://musicbrainz.org"
  static let releaseDescription = "MusicBrainz Album Id"
  static let artistDescription = "MusicBrainz Artist Id"

  static func read(fromMP3At url: URL) -> MusicBrainzTrackIDs {
    guard url.pathExtension.lowercased() == "mp3",
      let data = try? Data(contentsOf: url, options: .mappedIfSafe)
    else { return MusicBrainzTrackIDs() }
    return read(fromTagIn: data)
  }

  static func read(fromTagIn data: Data) -> MusicBrainzTrackIDs {
    var ids = MusicBrainzTrackIDs()
    guard let frames = try? MP3MetadataWriter.frames(in: data) else { return ids }
    for frame in frames {
      switch frame.id {
      case "UFID", "UFI":
        guard let (owner, identifier) = uniqueFileID(frame.payload),
          owner == ufidOwner, ids.recordingID.isEmpty
        else { continue }
        ids.recordingID = identifier
      case "TXXX", "TXX":
        guard let (description, value) = userText(frame.payload) else { continue }
        switch description {
        case releaseDescription where ids.releaseID.isEmpty:
          ids.releaseID = value
        case artistDescription where ids.artistID.isEmpty:
          ids.artistID = value
        default:
          break
        }
      default:
        break
      }
    }
    return ids
  }

  static func isManagedFrame(_ frame: MP3MetadataWriter.Frame) -> Bool {
    switch frame.id {
    case "UFID", "UFI":
      return uniqueFileID(frame.payload)?.owner == ufidOwner
    case "TXXX", "TXX":
      guard let (description, _) = userText(frame.payload) else { return false }
      return description == releaseDescription || description == artistDescription
    default:
      return false
    }
  }

  static func frames(for metadata: TrackMetadata, version: Int) -> [MP3MetadataWriter.Frame] {
    var frames: [MP3MetadataWriter.Frame] = []
    if !metadata.musicBrainzRecordingID.isEmpty {
      var payload = Data(ufidOwner.utf8)
      payload.append(0)
      payload.append(Data(metadata.musicBrainzRecordingID.utf8))
      frames.append(
        MP3MetadataWriter.Frame(id: version == 2 ? "UFI" : "UFID", payload: payload))
    }
    func userText(_ description: String, _ value: String) {
      guard !value.isEmpty else { return }
      var payload = Data()
      if version == 4 {
        payload.append(0x03)  // UTF-8
        payload.append(Data(description.utf8))
        payload.append(0)
        payload.append(Data(value.utf8))
      } else {
        payload.append(0x01)  // UTF-16 with byte-order marks
        payload.append(contentsOf: [0xFF, 0xFE])
        payload.append(utf16LE(description))
        payload.append(contentsOf: [0, 0])
        payload.append(contentsOf: [0xFF, 0xFE])
        payload.append(utf16LE(value))
      }
      frames.append(
        MP3MetadataWriter.Frame(id: version == 2 ? "TXX" : "TXXX", payload: payload))
    }
    userText(releaseDescription, metadata.musicBrainzReleaseID)
    userText(artistDescription, metadata.musicBrainzArtistID)
    return frames
  }

  private static func utf16LE(_ value: String) -> Data {
    var data = Data()
    for unit in value.utf16 {
      data.append(UInt8(unit & 0xFF))
      data.append(UInt8(unit >> 8))
    }
    return data
  }

  private static func uniqueFileID(_ payload: Data) -> (owner: String, identifier: String)? {
    let bytes = [UInt8](payload)
    guard let terminator = bytes.firstIndex(of: 0) else { return nil }
    guard let owner = String(bytes: bytes[..<terminator], encoding: .isoLatin1),
      let identifier = String(bytes: bytes[(terminator + 1)...], encoding: .utf8)
    else { return nil }
    return (owner, identifier)
  }

  private static func userText(_ payload: Data) -> (description: String, value: String)? {
    let bytes = [UInt8](payload)
    guard bytes.count >= 2 else { return nil }
    let encoding = bytes[0]
    let text = Array(bytes[1...])
    switch encoding {
    case 0, 3:  // Latin-1 or UTF-8: single-byte NUL terminator.
      guard let terminator = text.firstIndex(of: 0) else { return nil }
      let stringEncoding: String.Encoding = encoding == 0 ? .isoLatin1 : .utf8
      guard let description = String(bytes: text[..<terminator], encoding: stringEncoding),
        let value = String(bytes: text[(terminator + 1)...], encoding: stringEncoding)
      else { return nil }
      return (description, value)
    case 1, 2:  // UTF-16 (with byte-order mark) or UTF-16BE: two-byte terminator.
      var index = 0
      while index + 1 < text.count, !(text[index] == 0 && text[index + 1] == 0) {
        index += 2
      }
      guard index + 1 < text.count else { return nil }
      let stringEncoding: String.Encoding = encoding == 1 ? .utf16 : .utf16BigEndian
      guard let description = String(bytes: text[..<index], encoding: stringEncoding),
        let value = String(bytes: text[(index + 2)...], encoding: stringEncoding)
      else { return nil }
      return (description, value)
    default:
      return nil
    }
  }
}
