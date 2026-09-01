import Foundation

enum MP3Builder {
  struct Tags {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var trackNumber: Int
    var year: Int
    var discNumber: Int = 0
    var albumArtist: String = ""
    var compilation: Bool = false
    var sortTitle: String = ""
    var sortAlbum: String = ""
    var sortArtist: String = ""
    var sortAlbumArtist: String = ""
    var sortComposer: String = ""
    var artwork: Data? = nil
  }

  struct Gapless {
    var encoderDelay: Int
    var encoderPadding: Int
  }

  static func build(
    tags: Tags, seconds: Double, sampleRate: Int = 44_100, gapless: Gapless? = nil
  ) -> Data {
    precondition(sampleRate == 44_100 || sampleRate == 48_000)
    var data = id3v2Tag(tags)
    let frameCount = max(1, Int(seconds * Double(sampleRate) / 1152.0))
    if let gapless {
      data.append(infoFrame(sampleRate: sampleRate, gapless: gapless))
    }
    let frame = silentFrame(sampleRate: sampleRate)
    for _ in 0..<frameCount { data.append(frame) }
    return data
  }

  private static func infoFrame(sampleRate: Int, gapless: Gapless) -> Data {
    var frame = silentFrame(sampleRate: sampleRate)
    let xing = 4 + 32
    frame.replaceSubrange(xing..<xing + 4, with: Data("Info".utf8))
    func putU32(_ value: UInt32, at offset: Int) {
      frame.replaceSubrange(
        offset..<offset + 4,
        with: [
          UInt8(value >> 24), UInt8((value >> 16) & 0xFF),
          UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
    putU32(0x3, at: xing + 4)  // flags: FRAMES | BYTES
    putU32(0, at: xing + 8)  // frame count (unused by the parser)
    putU32(0, at: xing + 12)  // byte count (unused by the parser)
    let lame = xing + 16
    frame.replaceSubrange(lame..<lame + 9, with: Data("LAME3.100".utf8))
    frame[lame + 0x15] = UInt8((gapless.encoderDelay >> 4) & 0xFF)
    frame[lame + 0x16] =
      UInt8((gapless.encoderDelay & 0xF) << 4) | UInt8((gapless.encoderPadding >> 8) & 0xF)
    frame[lame + 0x17] = UInt8(gapless.encoderPadding & 0xFF)
    return frame
  }

  private static func silentFrame(sampleRate: Int) -> Data {
    let formatByte: UInt8 = sampleRate == 48_000 ? 0x94 : 0x90
    var frame = Data([0xFF, 0xFB, formatByte, 0x00])
    let frameByteCount = 144 * 128_000 / sampleRate
    frame.append(Data(count: frameByteCount - 4))
    return frame
  }

  static func id3v2Tag(_ tags: Tags) -> Data {
    var frames = Data()
    func textFrame(_ id: String, _ value: String) {
      guard !value.isEmpty else { return }
      var text: Data
      if value.unicodeScalars.allSatisfy({ $0.value < 256 }) {
        text = Data([0x00])  // Latin-1
        text.append(contentsOf: value.unicodeScalars.map { UInt8($0.value) })
      } else {
        text = Data([0x01, 0xFF, 0xFE])  // UTF-16 with LE BOM
        for unit in value.utf16 {
          text.append(UInt8(unit & 0xFF))
          text.append(UInt8(unit >> 8))
        }
      }
      frames.append(contentsOf: Array(id.utf8))
      var size = UInt32(text.count).bigEndian
      withUnsafeBytes(of: &size) { frames.append(contentsOf: $0) }
      frames.append(contentsOf: [0x00, 0x00])
      frames.append(text)
    }
    textFrame("TIT2", tags.title)
    textFrame("TPE1", tags.artist)
    textFrame("TALB", tags.album)
    textFrame("TCON", tags.genre)
    if tags.trackNumber > 0 { textFrame("TRCK", String(tags.trackNumber)) }
    if tags.discNumber > 0 { textFrame("TPOS", String(tags.discNumber)) }
    if tags.year > 0 { textFrame("TYER", String(tags.year)) }
    textFrame("TPE2", tags.albumArtist)
    if tags.compilation { textFrame("TCMP", "1") }
    textFrame("TSOT", tags.sortTitle)
    textFrame("TSOA", tags.sortAlbum)
    textFrame("TSOP", tags.sortArtist)
    textFrame("TSO2", tags.sortAlbumArtist)
    textFrame("TSOC", tags.sortComposer)
    if let art = tags.artwork {
      var body = Data([0x00])  // Latin-1 for the MIME/description strings
      body.append(Data("image/png".utf8))
      body.append(0x00)
      body.append(0x03)  // picture type: front cover
      body.append(0x00)  // empty description
      body.append(art)
      frames.append(contentsOf: Array("APIC".utf8))
      var size = UInt32(body.count).bigEndian
      withUnsafeBytes(of: &size) { frames.append(contentsOf: $0) }
      frames.append(contentsOf: [0x00, 0x00])
      frames.append(body)
    }

    var tag = Data("ID3".utf8)
    tag.append(contentsOf: [0x03, 0x00, 0x00])  // v2.3.0, no flags
    let size = UInt32(frames.count)
    tag.append(contentsOf: [
      UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
      UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F),
    ])
    tag.append(frames)
    return tag
  }
}
