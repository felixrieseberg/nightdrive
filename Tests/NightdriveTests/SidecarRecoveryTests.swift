import Foundation
import Testing

@testable import Nightdrive

struct SidecarRecoveryTests: ScratchFixtureProviding {
  let scratchFixture: ScratchFixture

  init() throws {
    scratchFixture = try ScratchFixture()
  }
  @Test
  func testResetRefusesMissingAndIntactSidecars() throws {
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try SidecarRecovery.reset(.playlists, libraryFolder: scratch)
      }
      if let caughtError {
        guard case SidecarRecovery.Refusal.missing = caughtError else {
          Issue.record("expected a missing refusal, got \(caughtError)")
          return
        }
      }
    }

    try LocalPlaylistFile.save([LocalPlaylist(name: "Keep me")], libraryFolder: scratch)
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try SidecarRecovery.reset(.playlists, libraryFolder: scratch)
      }
      if let caughtError {
        guard case SidecarRecovery.Refusal.intact = caughtError else {
          Issue.record("expected an intact refusal, got \(caughtError)")
          return
        }
      }
    }
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).map(\.name)) == (["Keep me"]))
  }

  @Test
  func testResetRefusesUnreadableSidecars() throws {
    let url = LocalPlaylistFile.url(for: scratch)
    try LocalPlaylistFile.save([LocalPlaylist(name: "Inaccessible")], libraryFolder: scratch)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    do {
      let caughtError = #expect(throws: (any Error).self) {
        try SidecarRecovery.reset(.playlists, libraryFolder: scratch)
      }
      if let caughtError {
        guard case SidecarRecovery.Refusal.unreadable = caughtError else {
          Issue.record("expected an unreadable refusal, got \(caughtError)")
          return
        }
      }
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).map(\.name)) == (["Inaccessible"]))
  }

  @MainActor
  @Test
  func testResetQuarantinesCorruptSidecarAndUnblocksTheStore() async throws {
    let corrupt = Data("not json".utf8)
    let url = LocalPlaylistFile.url(for: scratch)
    try corrupt.write(to: url)

    let blocked = PlaylistStore(libraryFolder: scratch)
    #expect(throws: (any Error).self) { try blocked.create(name: "Blocked") }

    let quarantine = try SidecarRecovery.reset(.playlists, libraryFolder: scratch)
    #expect(!(FileManager.default.fileExists(atPath: url.path)))
    #expect((quarantine.path) == (url.path + ".corrupt"))
    #expect((try Data(contentsOf: quarantine)) == (corrupt), Comment(rawValue: "the damaged bytes are kept"))

    try blocked.reloadFromPersistence()
    let id = try blocked.create(name: "Fresh start")
    try await blocked.flushPersistence()
    #expect((try LocalPlaylistFile.load(libraryFolder: scratch).map(\.id)) == ([id]))
  }

  @Test
  func testResetQuarantineAvoidsCollisions() throws {
    let url = ListeningHistoryFile.url(for: scratch)
    try Data("old quarantine".utf8).write(to: URL(fileURLWithPath: url.path + ".corrupt"))
    try Data("not json".utf8).write(to: url)

    let quarantine = try SidecarRecovery.reset(.history, libraryFolder: scratch)
    #expect((quarantine.path) == (url.path + ".corrupt-2"))
    #expect((try Data(contentsOf: quarantine)) == (Data("not json".utf8)))
    #expect((try Data(contentsOf: URL(fileURLWithPath: url.path + ".corrupt"))) == (Data("old quarantine".utf8)))
  }
}
