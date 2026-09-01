import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import Nightdrive

// MARK: - Audio fixtures

/// Writes a mono sine-wave audio file for encoder and metadata tests.
func writeAudioFixture(
  to url: URL, formatID: AudioFormatID, seconds: Double = 1.0,
  frequency: Double = 440, amplitude: Float = 0.4
) throws {
  let sampleRate = 44_100.0
  guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
  else {
    throw TranscodeError.encodingFailed("Could not build the fixture's audio format.")
  }
  let file = try AVAudioFile(
    forWriting: url,
    settings: [
      AVFormatIDKey: formatID,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
    ],
    commonFormat: .pcmFormatFloat32,
    interleaved: false)
  let frames = AVAudioFrameCount(sampleRate * seconds)
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
    let samples = buffer.floatChannelData?[0]
  else {
    throw TranscodeError.encodingFailed("Could not allocate the fixture's sample buffer.")
  }
  buffer.frameLength = frames
  for index in 0..<Int(frames) {
    samples[index] =
      sinf(Float(2.0 * Double.pi * frequency * Double(index) / sampleRate)) * amplitude
  }
  try file.write(from: buffer)
}

/// An MP3 carrying the standard "Old ..." tags that editing tests rewrite.
func makeTaggedMP3(in directory: URL, filename: String = "track.mp3") throws -> URL {
  let url = directory.appendingPathComponent(filename)
  let tags = MP3Builder.Tags(
    title: "Old Title", artist: "Old Artist", album: "Old Album",
    genre: "Old Genre", trackNumber: 1, year: 1999)
  try MP3Builder.build(tags: tags, seconds: 1).write(to: url)
  return url
}

// MARK: - Artwork fixtures

/// A solid-color CGImage for artwork fixtures.
func solidImage(
  red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 64, height: Int = 64
) -> CGImage? {
  var pixels = [UInt8](repeating: 255, count: width * height * 4)
  for offset in stride(from: 0, to: pixels.count, by: 4) {
    pixels[offset] = UInt8(red * 255)
    pixels[offset + 1] = UInt8(green * 255)
    pixels[offset + 2] = UInt8(blue * 255)
  }
  let context = CGContext(
    data: &pixels, width: width, height: height, bitsPerComponent: 8,
    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  return context?.makeImage()
}

/// PNG bytes of a solid color for artwork fixtures.
func pngData(
  red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 64, height: Int = 64
) throws -> Data {
  let image = try #require(solidImage(red: red, green: green, blue: blue, width: width, height: height))
  let output = NSMutableData()
  let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  #expect(CGImageDestinationFinalize(destination))
  return output as Data
}

/// PNG bytes of a small NSImage-drawn square for embedded-artwork fixtures.
func pngArtwork(size: Int = 8, color: NSColor = .systemTeal) -> Data {
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    color.setFill()
    rect.fill()
    return true
  }
  guard let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
  else {
    Issue.record("Could not build the artwork fixture")
    return Data()
  }
  return png
}

// MARK: - LibraryTrack fixtures

extension LibraryTrack {
  /// A LibraryTrack with test-friendly physical facts; tag fields keep the
  /// initializer's empty defaults so tests only state what they assert on.
  static func fixture(
    url: URL,
    title: String,
    artist: String = "Artist",
    album: String = "Album",
    genre: String = "",
    trackNumber: Int = 0,
    trackCount: Int = 0,
    discNumber: Int = 0,
    discCount: Int = 0,
    year: Int = 0,
    compilation: Bool = false,
    durationMS: Int = 1_000,
    sizeBytes: Int = 1_000,
    bitrate: Int = 128,
    samplerate: Int = 44_100
  ) -> LibraryTrack {
    LibraryTrack(
      url: url, title: title, artist: artist, album: album, genre: genre,
      trackNumber: trackNumber, trackCount: trackCount, discNumber: discNumber,
      discCount: discCount, year: year, compilation: compilation,
      durationMS: durationMS, sizeBytes: sizeBytes, bitrate: bitrate,
      samplerate: samplerate)
  }
}

// MARK: - ID3 frame construction

func synchsafeSize(_ bytes: Data) -> Int {
  bytes.reduce(0) { ($0 << 7) | Int($1 & 0x7F) }
}

func synchsafeBytes(_ value: Int) -> [UInt8] {
  [
    UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F),
    UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F),
  ]
}

/// Appends raw ID3v2.3 frames to an existing tagged MP3.
func addingFrames(_ frames: [MP3MetadataWriter.Frame], to mp3: Data) -> Data {
  let oldSize = synchsafeSize(mp3[6..<10])
  var body = Data(mp3[10..<(10 + oldSize)])
  for frame in frames {
    body.append(Data(frame.id.utf8))
    var size = UInt32(frame.payload.count).bigEndian
    withUnsafeBytes(of: &size) { body.append(contentsOf: $0) }
    body.append(contentsOf: [0, 0])
    body.append(frame.payload)
  }
  var output = Data("ID3".utf8)
  output.append(contentsOf: [3, 0, 0])
  output.append(contentsOf: synchsafeBytes(body.count))
  output.append(body)
  output.append(mp3[(10 + oldSize)...])
  return output
}

// MARK: - On-The-Go playlist bytes

/// A raw OTGPlaylistInfo file; `entryCount` may lie for truncation tests.
func otgData(indices: [UInt32], entryCount: Int? = nil) -> Data {
  var data = Data("mhpo".utf8)
  for value in [UInt32(20), 4, UInt32(entryCount ?? indices.count), 0] {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }
  for index in indices {
    withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
  }
  return data
}

// MARK: - Filesystem facts

func modificationDate(of url: URL) throws -> Date {
  try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

// MARK: - Deferred artwork transactions

struct DeferredArtworkTransaction {
  let previous: ITunesDatabase
  let intended: ITunesDatabase
  let recoveryDirectory: URL
}

extension FakeIpodFixtureProviding {
  /// Leaves a prepared-but-unresolved artwork transaction on the fake iPod:
  /// a committed "Previous" database plus a deferred write that intended to
  /// update track 1 and add track 2.
  @discardableResult
  func leaveDeferredArtworkTransaction(
    fileSystem fs: IpodFileSystem? = nil
  ) throws -> DeferredArtworkTransaction {
    let fs = fs ?? self.fs
    let specs = try requireArtworkSpecs(modelNumber: modelNumber)
    let previousAssignments = try ArtworkDBWriter.write(
      images: [ArtworkImage(dbid: 1, data: pngData(red: 1, green: 0, blue: 0))],
      specs: specs, fileSystem: fs)
    var previousTrack = ITDBTrack()
    previousTrack.dbid = 1
    previousTrack.title = "Previous"
    let previousAssignment = try #require(previousAssignments[1])
    previousTrack.artwork = ITDBTrackArtwork(
      mhiiID: previousAssignment.mhiiID,
      sizeBytes: previousAssignment.sourceImageSize)
    var previous = ITunesDatabase()
    previous.tracks = [previousTrack]
    try fs.writeDatabase(previous)

    let write = try ArtworkDBWriter.beginWrite(
      images: [
        ArtworkImage(dbid: 1, data: pngData(red: 0, green: 1, blue: 0)),
        ArtworkImage(dbid: 2, data: pngData(red: 0, green: 0, blue: 1)),
      ], specs: specs, fileSystem: fs)
    var intended = previous
    intended.tracks = try [1, 2].map { dbid in
      let assignment = try #require(write.assignments[UInt64(dbid)])
      var track = ITDBTrack()
      track.dbid = UInt64(dbid)
      track.title = dbid == 1 ? "Updated" : "Added"
      track.artwork = ITDBTrackArtwork(
        mhiiID: assignment.mhiiID, sizeBytes: assignment.sourceImageSize)
      return track
    }
    try write.transaction.prepareRecovery(
      previousLinks: ArtworkDatabaseLink.links(in: previous),
      intendedLinks: ArtworkDatabaseLink.links(in: intended))
    let directory = write.transaction.recoveryDirectory
    try write.transaction.deferResolution()
    return DeferredArtworkTransaction(
      previous: previous, intended: intended, recoveryDirectory: directory)
  }
}
