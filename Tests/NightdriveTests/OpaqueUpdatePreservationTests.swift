import Foundation
import Testing

@testable import Nightdrive

@Suite(.tags(.fakeIpod))
struct OpaqueUpdatePreservationTests: FakeIpodFixtureProviding {
  let fakeIpodFixture: FakeIpodFixture

  init() throws {
    fakeIpodFixture = try FakeIpodFixture()
  }
  private let opaqueDRM: UInt32 = 0xA1B2_C3D4
  private let opaqueFuture: UInt32 = 0x1122_3344
  private let importedBookmarkMS: UInt32 = 0x5566_7788
  private let importedSkipCount: UInt32 = 42
  private let importedLastSkipped = Date(timeIntervalSince1970: 1_300_000_321)

  @Test
  func testDeviceReplacementPreservesImportedOpaqueFieldsAndRefreshesModeledFields()
    async throws
  {
    var deviceTrack = try putTrackOnIpod(
      title: "Imported Song", artist: "Imported Artist", trackNumber: 1)
    deviceTrack.album = "Device Album"
    deviceTrack.bookmarkMS = importedBookmarkMS
    deviceTrack.skipCount = importedSkipCount
    deviceTrack.lastSkipped = importedLastSkipped
    let (raw, unknownMhod) = try rawImportedDatabase(track: deviceTrack)
    try raw.write(to: fs.databaseURL)

    let imported = try fs.readDatabase()
    let old = try #require(imported.tracks.first)
    #expect((DBBytes.u32(try #require(old.preservedMhitHeader), at: 100)) == (opaqueDRM))
    #expect((DBBytes.u32(try #require(old.preservedMhitHeader), at: 0x220)) == (opaqueFuture))
    #expect((old.bookmarkMS) == (importedBookmarkMS))
    #expect((old.skipCount) == (importedSkipCount))
    #expect((old.lastSkipped) == (importedLastSkipped))
    #expect((old.preservedMhods) == ([unknownMhod]))

    let localURL = try writeLibraryMP3(
      filename: "song.mp3", title: "Imported Song", artist: "Imported Artist",
      album: "Device Album", trackNumber: 1, seconds: 2)
    let adoption = try await makePlan()
    #expect((adoption.adoptedPairs.count) == (1))
    let firstSync = try await sync()
    #expect((firstSync.failures) == ([]))

    try writeLibraryMP3(
      filename: "song.mp3", title: "Updated Song", artist: "Updated Artist",
      album: "Updated Album", trackNumber: 1, seconds: 5)
    let replacementPlan = try await makePlan()
    let update = try #require(replacementPlan.updateOnDevice.first)
    #expect((replacementPlan.updateOnDevice.count) == (1))

    let result = try await sync()
    #expect((result.updatedOnDevice) == (1))
    #expect((result.failures) == ([]))

    let afterRaw = try Data(contentsOf: fs.databaseURL)
    let after = try fs.readDatabase()
    let row = try #require(after.tracks.first)
    #expect((row.dbid) == (old.dbid))
    #expect((DBBytes.u32(try #require(row.preservedMhitHeader), at: 100)) == (opaqueDRM))
    #expect((DBBytes.u32(try #require(row.preservedMhitHeader), at: 0x220)) == (opaqueFuture))
    #expect((row.bookmarkMS) == (importedBookmarkMS))
    #expect((row.skipCount) == (importedSkipCount))
    #expect((row.lastSkipped) == (importedLastSkipped))
    #expect((row.preservedMhods) == ([unknownMhod]))
    #expect(afterRaw.range(of: unknownMhod) != nil)

    #expect((row.title) == ("Updated Song"))
    #expect((row.artist) == ("Updated Artist"))
    #expect((row.album) == ("Updated Album"))
    #expect((row.sizeBytes) == (UInt32(clamping: update.local.sizeBytes)))
    #expect((row.lengthMS) == (UInt32(clamping: update.local.durationMS)))
    #expect((row.ipodPath) != (old.ipodPath))
    #expect(
      (try Data(contentsOf: localURL))
        == (try Data(
          contentsOf: fs.validatedMusicFileURL(
            forIpodPath: try #require(row.ipodPath)))))
  }

  private func unknownMhod() -> Data {
    var data = Data("mhod".utf8) + Data(count: 20)
    DBBytes.patchU32(&data, at: 4, 16)
    DBBytes.patchU32(&data, at: 8, UInt32(data.count))
    DBBytes.patchU32(&data, at: 12, 0xF00D)
    data.replaceSubrange(
      16..<24, with: Data([0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4]))
    return data
  }

  private func rawImportedDatabase(track: ITDBTrack) throws -> (Data, Data) {
    var database = ITunesDatabase()
    database.tracks = [track]
    var raw = ITunesDBWriter().write(database)
    let mhit = try #require(DBBytes.mhitOffsets(in: raw).first)
    let headerLength = Int(DBBytes.u32(raw, at: mhit + 4))
    #expect((headerLength) > (0x224))
    DBBytes.patchU32(&raw, at: mhit + 100, opaqueDRM)
    DBBytes.patchU32(&raw, at: mhit + 0x220, opaqueFuture)

    let child = unknownMhod()
    let insertion = mhit + Int(DBBytes.u32(raw, at: mhit + 8))
    let trackSection = try #require(DBBytes.mhsdSections(in: raw).first(where: { $0.type == 1 }))
    #expect((insertion) == (trackSection.range.upperBound))
    DBBytes.patchU32(
      &raw, at: mhit + 8, DBBytes.u32(raw, at: mhit + 8) + UInt32(child.count))
    DBBytes.patchU32(&raw, at: mhit + 12, DBBytes.u32(raw, at: mhit + 12) + 1)
    DBBytes.patchU32(
      &raw, at: trackSection.range.lowerBound + 8,
      DBBytes.u32(raw, at: trackSection.range.lowerBound + 8) + UInt32(child.count))
    DBBytes.patchU32(&raw, at: 8, DBBytes.u32(raw, at: 8) + UInt32(child.count))
    raw.insert(contentsOf: child, at: insertion)
    return (raw, child)
  }

  private func sync() async throws -> SyncResult {
    try await runSync(try await makePlan())
  }
}
