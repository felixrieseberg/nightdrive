import Foundation
import Testing

@testable import Nightdrive

// MARK: - Duplicate detection

struct DuplicateFinderTests {
  @Test
  func testExactContentGroupsRequireMatchingSizeAndHash() {
    let a = makeTrack(path: "/Music/a.mp3", title: "Song", sizeBytes: 100)
    let b = makeTrack(path: "/Music/b.mp3", title: "Song B", sizeBytes: 100)
    let c = makeTrack(path: "/Music/c.mp3", title: "Song C", sizeBytes: 100)
    let d = makeTrack(path: "/Music/d.mp3", title: "Song D", sizeBytes: 42)

    let groups = DuplicateFinder.findGroups(in: [a, b, c, d]) { url in
      url.lastPathComponent == "c.mp3" ? "other" : "same"
    }

    let exact = groups.filter { $0.tier == .exactContent }
    #expect((exact.count) == (1))
    #expect((Set(exact[0].tracks.map(\.id))) == (Set([a.id, b.id])))
  }

  @Test
  func testMetadataTierMatchesWithinDurationTolerance() {
    let a = makeTrack(path: "/Music/a.mp3", title: "Song", durationMS: 180_000, sizeBytes: 1)
    let b = makeTrack(path: "/Music/b.mp3", title: "Song", durationMS: 181_500, sizeBytes: 2)
    let c = makeTrack(path: "/Music/c.mp3", title: "Song", durationMS: 200_000, sizeBytes: 3)

    let groups = DuplicateFinder.findGroups(in: [a, b, c]) { _ in UUID().uuidString }

    let metadata = groups.filter { $0.tier == .matchingMetadata }
    #expect((metadata.count) == (1))
    #expect((Set(metadata[0].tracks.map(\.id))) == (Set([a.id, b.id])))
  }

  @Test
  func testMetadataTierPreselectsDifferentTrackPositionRemoval() {
    let unpositioned = makeTrack(
      path: "/Music/loose.mp3", title: "Song", durationMS: 180_000,
      sizeBytes: 1, trackNumber: 0, discNumber: 0)
    let positioned = makeTrack(
      path: "/Music/Artist/Album/01 Song.mp3", title: "Song",
      durationMS: 180_000, sizeBytes: 2, trackNumber: 1, discNumber: 1)

    let groups = DuplicateFinder.findGroups(in: [unpositioned, positioned]) { _ in
      UUID().uuidString
    }

    #expect((groups.count) == (1))
    #expect((groups[0].tier) == (.differentTrackPosition))
    #expect((Set(groups[0].tracks.map(\.id))) == (Set([unpositioned.id, positioned.id])))
    #expect((groups[0].preselectedRemovals.map(\.id)) == ([unpositioned.id]))
  }

  @Test
  func testUnknownAlbumPlaceholderMatchesMissingAlbumAndPreselectsRemoval() {
    let placeholder = makeTrack(
      path: "/Music/Artist - Song.mp3", title: "Song", album: "Unknown Album",
      sizeBytes: 1)
    let missing = makeTrack(
      path: "/Music/Artist/Unknown Album/Artist - Song.mp3", title: "Song",
      album: "", sizeBytes: 2)

    let groups = DuplicateFinder.findGroups(in: [placeholder, missing]) { _ in
      UUID().uuidString
    }

    #expect((groups.count) == (1))
    #expect((groups[0].tier) == (.matchingMetadata))
    #expect((groups[0].preselectedRemovals.map(\.id)) == ([placeholder.id]))
  }

  @Test
  func testAlternateAlbumTierIsFlaggedButSuggestsNoRemovals() {
    let studio = makeTrack(
      path: "/Music/studio.mp3", title: "Song", album: "Studio", sizeBytes: 1)
    let hits = makeTrack(
      path: "/Music/hits.mp3", title: "Song", album: "Greatest Hits", sizeBytes: 2)

    let groups = DuplicateFinder.findGroups(in: [studio, hits]) { _ in UUID().uuidString }

    #expect((groups.count) == (1))
    #expect((groups[0].tier) == (.alternateAlbum))
  }

  @Test
  func testPossiblePartialCopyMatchesDurationAndTitleVariant() {
    let short = makeTrack(
      path: "/Music/liquid-short.mp3", title: "Liquid", artist: "Nebular B",
      album: "Gatecrasher: Wet", durationMS: 203_000, sizeBytes: 6_000_000, bitrate: 320)
    let full = makeTrack(
      path: "/Music/liquid-full.mp3", title: "Liquid (Trilithon Mix)", artist: "Nebular B",
      album: "Gatecrasher: Wet", durationMS: 315_000, sizeBytes: 5_000_000, bitrate: 192)

    let groups = DuplicateFinder.findGroups(
      in: [short, full], partialContentMatch: { _, _ in true },
      contentHash: { _ in UUID().uuidString })

    #expect((groups.count) == (1))
    #expect((groups[0].tier) == (.possiblePartialCopy))
    #expect((Set(groups[0].tracks.map(\.id))) == (Set([short.id, full.id])))
    #expect((groups[0].suggestedKeeperID) == (full.id))
  }

  @Test
  func testPossiblePartialCopyRequiresSameAlbum() {
    let studio = makeTrack(
      path: "/Music/studio.mp3", title: "Song", album: "Studio", durationMS: 180_000)
    let live = makeTrack(
      path: "/Music/live.mp3", title: "Song (Live)", album: "Live", durationMS: 240_000)

    let groups = DuplicateFinder.findGroups(
      in: [studio, live], partialContentMatch: { _, _ in true },
      contentHash: { _ in UUID().uuidString })

    #expect(groups.isEmpty)
  }

  @Test
  func testDurationMismatchSurfacesWhenAudioOverlapCannotBeConfirmed() {
    let short = makeTrack(
      path: "/Music/song-short.mp3", title: "Song", durationMS: 120_000)
    let full = makeTrack(
      path: "/Music/song-full.mp3", title: "Song", durationMS: 180_000)

    let groups = DuplicateFinder.findGroups(
      in: [short, full], partialContentMatch: { _, _ in false },
      contentHash: { _ in UUID().uuidString })

    #expect((groups.map(\.tier)) == ([.durationMismatch]))
    #expect((groups[0].suggestedKeeperID) == (full.id))
  }

  @Test
  func testDurationMismatchRejectsContradictoryCompilationFilenames() {
    let communication = makeTrack(
      path: "/Music/Various Artists/Gatecrasher- Wet/Armin - Communication.mp3",
      title: "Communication", artist: "Armin", album: "Gatecrasher: Wet",
      durationMS: 359_000)
    let saltwaterWithBadTags = makeTrack(
      path: "/Music/Various Artists/Gatecrasher- Wet/13 - Saltwater (Tomski vs Disco Citizens Remix).mp3",
      title: "Communication", artist: "Armin", album: "Gatecrasher: Wet",
      durationMS: 154_000)

    let groups = DuplicateFinder.findGroups(
      in: [communication, saltwaterWithBadTags], depth: .shallow,
      partialContentMatch: { _, _ in
        Issue.record("Shallow search must not compare audio"); return false
      },
      progress: { _ in }, contentHash: { _ in UUID().uuidString })

    #expect(groups.isEmpty)
  }

  @Test
  func testDeepAudioMatchCanOverrideContradictoryFilename() {
    let titled = makeTrack(
      path: "/Music/Artist - Song.mp3", title: "Song", durationMS: 120_000)
    let badlyNamed = makeTrack(
      path: "/Music/Completely Wrong Name.mp3", title: "Song", durationMS: 180_000)

    let groups = DuplicateFinder.findGroups(
      in: [titled, badlyNamed], depth: .deep,
      partialContentMatch: { _, _ in true }, progress: { _ in },
      contentHash: { _ in UUID().uuidString })

    #expect((groups.map(\.tier)) == ([.possiblePartialCopy]))
  }

  @Test
  func testShallowSearchSkipsAudioAndReportsMonotonicProgress() {
    let short = makeTrack(
      path: "/Music/song-short.mp3", title: "Song", durationMS: 120_000)
    let full = makeTrack(
      path: "/Music/song-full.mp3", title: "Song", durationMS: 180_000)
    var audioComparisonCount = 0
    var updates: [DuplicateScanProgress] = []

    let groups = DuplicateFinder.findGroups(
      in: [short, full], depth: .shallow,
      partialContentMatch: { _, _ in
        audioComparisonCount += 1
        return true
      },
      progress: { updates.append($0) },
      contentHash: { _ in UUID().uuidString })

    #expect((groups.map(\.tier)) == ([.durationMismatch]))
    #expect((audioComparisonCount) == (0))
    #expect((updates.first?.fraction) == (0))
    #expect((updates.last?.fraction) == (1))
    #expect(zip(updates, updates.dropFirst()).allSatisfy { $0.fraction <= $1.fraction })
  }

  @Test
  func testCancellationStopsScanBeforeRemainingFilesAreHashed() {
    let tracks = (0..<20).map { index in
      makeTrack(
        path: "/Music/song-\(index).mp3", title: "Song \(index)",
        sizeBytes: 100)
    }
    var cancelled = false
    var hashCount = 0
    var updates: [DuplicateScanProgress] = []

    let groups = DuplicateFinder.findGroups(
      in: tracks, depth: .deep,
      partialContentMatch: { _, _ in
        Issue.record("A cancelled scan must not compare audio"); return false
      },
      progress: { updates.append($0) },
      isCancelled: { cancelled },
      contentHash: { _ in
        hashCount += 1
        cancelled = true
        return UUID().uuidString
      })

    #expect(groups.isEmpty)
    #expect((hashCount) == (1))
    #expect((updates.last?.phase) != (.complete))
  }

  @Test
  func testLargeMetadataScanThrottlesProgressUpdates() {
    let tracks = (0..<199).map { index in
      makeTrack(
        path: "/Music/song-\(index).mp3", title: "Song \(index)",
        sizeBytes: index)
    }
    var metadataUpdates = 0

    _ = DuplicateFinder.findGroups(
      in: tracks, depth: .shallow,
      partialContentMatch: { _, _ in false },
      progress: { update in
        if case .comparingSongInformation = update.phase {
          metadataUpdates += 1
        }
      }, contentHash: { _ in UUID().uuidString })

    #expect((metadataUpdates) <= (102))
  }

  @Test
  func testContentHashCancellationStopsBeforeOpeningFile() {
    do {
      let caughtError = #expect(throws: (any Error).self) {
        try SyncSignature.fileSHA256(
          url: URL(fileURLWithPath: "/does-not-need-to-exist.mp3"),
          isCancelled: { true })
      }
      if let caughtError {
        #expect(caughtError is CancellationError)
      }
    }
  }

  @Test
  func testSuggestedKeeperPrefersBitrateThenSizeThenShallowPath() {
    let low = makeTrack(path: "/Music/low.mp3", title: "Song", bitrate: 128)
    let high = makeTrack(path: "/Music/deep/nested/high.mp3", title: "Song", bitrate: 320)
    #expect((DuplicateFinder.suggestedKeeper(among: [low, high])?.id) == (high.id))

    let small = makeTrack(path: "/Music/small.mp3", title: "Song", sizeBytes: 10)
    let large = makeTrack(path: "/Music/large.mp3", title: "Song", sizeBytes: 20)
    #expect((DuplicateFinder.suggestedKeeper(among: [small, large])?.id) == (large.id))

    let shallow = makeTrack(path: "/Music/song.mp3", title: "Song")
    let deep = makeTrack(path: "/Music/a/b/song.mp3", title: "Song")
    #expect((DuplicateFinder.suggestedKeeper(among: [deep, shallow])?.id) == (shallow.id))
  }

  @Test
  func testTracksConsumedByStrongerTierDoNotReappear() {
    let a = makeTrack(path: "/Music/a.mp3", title: "Song", sizeBytes: 100)
    let b = makeTrack(path: "/Music/b.mp3", title: "Song", sizeBytes: 100)

    let groups = DuplicateFinder.findGroups(in: [a, b]) { _ in "same" }

    #expect((groups.count) == (1))
    #expect((groups[0].tier) == (.exactContent))
  }

  @Test
  func testUntaggedFilesNeverMatchByFilenameStem() {
    // Two unrelated rips both named 01.mp3 with blank tags and similar
    // durations must not become an auto-selected "Matching tags" group.
    let a = makeTrack(path: "/Music/Album A/01.mp3", title: "", artist: "", album: "")
    let b = makeTrack(path: "/Music/Album B/01.mp3", title: "", artist: "", album: "")

    let groups = DuplicateFinder.findGroups(in: [a, b]) { _ in UUID().uuidString }

    #expect(groups.isEmpty)
  }

  @Test
  func testUntaggedIdenticalFilesStillMatchByContent() {
    let a = makeTrack(path: "/Music/x/01.mp3", title: "", artist: "", album: "", sizeBytes: 100)
    let b = makeTrack(path: "/Music/y/01.mp3", title: "", artist: "", album: "", sizeBytes: 100)

    let groups = DuplicateFinder.findGroups(in: [a, b]) { _ in "same" }

    #expect((groups.map(\.tier)) == ([.exactContent]))
  }

  private func makeTrack(
    path: String, title: String, artist: String = "Artist", album: String = "Album",
    durationMS: Int = 180_000, sizeBytes: Int = 1_000, bitrate: Int = 256,
    trackNumber: Int = 1, discNumber: Int = 1
  ) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: path), title: title, artist: artist, album: album,
      genre: "Rock", trackNumber: trackNumber, trackCount: 1,
      discNumber: discNumber, year: 2020,
      durationMS: durationMS, sizeBytes: sizeBytes, bitrate: bitrate)
  }
}

// MARK: - Metadata problem detection

struct MetadataProblemFinderTests {
  @Test
  func testFindsCopiedNeighborTagsAndProposesOnlySupportedFields() throws {
    let wrong = makeTrack(
      path: "/Music/Compilation/14 - 4G.mp3",
      title: "Heaven (Lange remix)", artist: "Agenda", trackNumber: 16,
      durationMS: 280_000)
    let correctlyNamedPeer = makeTrack(
      path: "/Music/Compilation/16 - Heaven (Lange Remix).mp3",
      title: "Heaven (Lange remix)", artist: "Agenda", trackNumber: 16,
      durationMS: 241_000)

    let findings = MetadataProblemFinder.findProblems(
      in: [wrong, correctlyNamedPeer], audioContentHash: { _ in nil })

    let finding = try #require(findings.first)
    #expect((findings.count) == (1))
    #expect((finding.track.id) == (wrong.id))
    #expect((finding.reason) == (.copiedTags))
    #expect((finding.confidence) == (.high))
    #expect((finding.proposedCorrection?.title) == ("4G"))
    #expect((finding.proposedCorrection?.trackNumber) == (14))
    #expect(finding.proposedCorrection?.artist == nil)
    #expect(finding.proposedCorrection?.album == nil)
  }

  @Test
  func testBareFilenameDisagreementIsNotEnoughForAFinding() {
    let track = makeTrack(
      path: "/Music/Mystery download.mp3", title: "Actual Song", artist: "Artist",
      trackNumber: 0)

    let findings = MetadataProblemFinder.findProblems(
      in: [track], audioContentHash: { _ in nil })

    #expect(findings.isEmpty)
  }

  @Test
  func testCommonCopyAndArtistTitleFilenamesDoNotProduceFindings() {
    let tracks = [
      makeTrack(
        path: "/Music/Downloads/Artist - Actual Song.mp3", title: "Actual Song",
        artist: "Artist", trackNumber: 0),
      makeTrack(
        path: "/Music/Downloads/Copy of Artist - Actual Song.mp3", title: "Actual Song",
        artist: "Artist", trackNumber: 0),
      makeTrack(
        path: "/Music/Downloads/Artist - Actual Song (1).mp3", title: "Actual Song",
        artist: "Artist", trackNumber: 0),
    ]

    let findings = MetadataProblemFinder.findProblems(
      in: tracks, audioContentHash: { _ in nil })

    #expect(findings.isEmpty)
  }

  @Test
  func testSimilarDurationCopiesStayInDuplicateFinder() {
    let tracks = [
      makeTrack(
        path: "/Music/Album/01 - Actual Song.mp3", title: "Actual Song",
        trackNumber: 1, durationMS: 180_000),
      makeTrack(
        path: "/Music/Downloads/Radio recording.mp3", title: "Actual Song",
        trackNumber: 1, durationMS: 181_000),
    ]

    let findings = MetadataProblemFinder.findProblems(
      in: tracks, audioContentHash: { _ in nil })

    #expect(findings.isEmpty)
  }

  @Test
  func testTitleAndTrackConflictAreReportedWithoutAnUnsafeProposal() throws {
    let track = makeTrack(
      path: "/Music/03 - Filename Title.mp3", title: "Embedded Title",
      artist: "Artist", trackNumber: 7)

    let finding = try #require(
      MetadataProblemFinder.findProblems(
        in: [track], audioContentHash: { _ in nil }
      ).first)

    #expect((finding.confidence) == (.medium))
    #expect((finding.reason) == (.trackNumberConflict))
    #expect(finding.proposedCorrection == nil)
  }

  @Test
  func testFolderConventionCorroboratesTitleAndTrackCorrection() throws {
    let tracks = [
      makeTrack(path: "/Music/Album/01 - Alpha.mp3", title: "Alpha", trackNumber: 1),
      makeTrack(path: "/Music/Album/02 - Beta.mp3", title: "Beta", trackNumber: 2),
      makeTrack(path: "/Music/Album/03 - Gamma.mp3", title: "Gamma", trackNumber: 3),
      makeTrack(path: "/Music/Album/04 - Delta.mp3", title: "Echo", trackNumber: 5),
    ]

    let findings = MetadataProblemFinder.findProblems(
      in: tracks, audioContentHash: { _ in nil })

    let finding = try #require(findings.first)
    #expect((findings.count) == (1))
    #expect((finding.track.url.lastPathComponent) == ("04 - Delta.mp3"))
    #expect((finding.confidence) == (.high))
    #expect((finding.proposedCorrection?.title) == ("Delta"))
    #expect((finding.proposedCorrection?.trackNumber) == (4))
  }

  @Test
  func testCapitalizationPunctuationAndDiscPrefixAreEquivalent() {
    let track = makeTrack(
      path: "/Music/Album/CD 1-02 - HEAVEN (lange remix).mp3",
      title: "Heaven (Lange Remix)", discNumber: 1, trackNumber: 2)

    let findings = MetadataProblemFinder.findProblems(
      in: [track], audioContentHash: { _ in nil })

    #expect(findings.isEmpty)
  }

  @Test
  func testMatchingAudioCanSupportATitleButDoesNotInventAnArtist() throws {
    let wrong = makeTrack(
      path: "/Music/01 - Right Song.mp3", title: "Wrong Song",
      artist: "Wrong Artist", trackNumber: 1)
    let reference = makeTrack(
      path: "/Music/Elsewhere/Right Artist - Right Song.mp3", title: "Right Song",
      artist: "Right Artist", trackNumber: 8)

    let findings = MetadataProblemFinder.findProblems(
      in: [wrong, reference],
      audioContentHash: { _ in "same-encoded-audio" })

    let finding = try #require(findings.first { $0.track.id == wrong.id })
    #expect((finding.reason) == (.matchingAudio))
    #expect((finding.confidence) == (.high))
    #expect((finding.proposedCorrection?.title) == ("Right Song"))
    #expect(finding.proposedCorrection?.artist == nil)
  }

  @Test
  func testEncodedAudioHashIgnoresID3Tags() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "NightdriveMetadataHashTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("first.mp3")
    let second = folder.appendingPathComponent("second.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "First", artist: "Artist A", album: "Album", genre: "Rock",
        trackNumber: 1, year: 2000),
      seconds: 1
    ).write(to: first)
    try MP3Builder.build(
      tags: .init(
        title: "A much longer second title", artist: "Artist B", album: "Album",
        genre: "Rock", trackNumber: 2, year: 2000),
      seconds: 1
    ).write(to: second)

    #expect(
      (try MetadataProblemFinder.encodedAudioSHA256(first)) == (try MetadataProblemFinder.encodedAudioSHA256(second)))
    #expect((try SyncSignature.fileSHA256(url: first)) != (try SyncSignature.fileSHA256(url: second)))
  }

  private func makeTrack(
    path: String, title: String, artist: String = "Artist", album: String = "Album",
    discNumber: Int = 1, trackNumber: Int,
    durationMS: Int = 180_000
  ) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: path), title: title, artist: artist, album: album,
      genre: "Electronic", trackNumber: trackNumber, trackCount: 20,
      discNumber: discNumber, discCount: 1, year: 2000,
      durationMS: durationMS, bitrate: 256)
  }
}

@MainActor
struct MetadataProblemCorrectionTests {
  @Test
  func testCorrectionRejectsAStaleReviewAndPreservesUnproposedFields() async throws {
    let folder = TestScratch.directory(prefix: "NightdriveMetadataProblemCorrection")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("02 - Correct Title.mp3")
    try MP3Builder.build(
      tags: .init(
        title: "Wrong Title", artist: "Original Artist", album: "Original Album",
        genre: "Electronic", trackNumber: 7, year: 2004),
      seconds: 1
    ).write(to: url)

    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first)
    let originalData = try Data(contentsOf: url)
    let correction = MetadataProblem.Correction(title: "Correct Title", trackNumber: 2)
    let edit = TrackMetadataEdit(
      track: track, metadata: correction.applying(to: track.metadata))
    let app = AppState(library: store)

    do {
      try await app.applyMetadataProblemCorrections(
        [edit], expectedLibraryIdentity: store.identityRevision &+ 1)
      Issue.record("Expected a stale review to be rejected")
    } catch LibraryStoreError.libraryChanged {
    }
    #expect((try Data(contentsOf: url)) == (originalData))

    try await app.applyMetadataProblemCorrections(
      [edit], expectedLibraryIdentity: store.identityRevision)
    let updated = try #require(store.tracks.first)
    #expect((updated.title) == ("Correct Title"))
    #expect((updated.trackNumber) == (2))
    #expect((updated.artist) == ("Original Artist"))
    #expect((updated.album) == ("Original Album"))
    #expect((updated.genre) == ("Electronic"))
    #expect((updated.year) == (2004))
  }
}

// MARK: - Organize planning

struct LibraryOrganizerTests {
  private let root = URL(fileURLWithPath: "/Library", isDirectory: true)

  @Test
  func testArtistAlbumPatternBuildsExpectedPath() {
    let track = makeTrack(path: "/Library/loose.mp3", artist: "Daft Punk", album: "Discovery")
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Daft Punk/Discovery/loose.mp3"]))
  }

  @Test
  func testYearPatternAndRenamingUseMetadata() {
    let track = makeTrack(
      path: "/Library/x.mp3", title: "One More Time", artist: "Daft Punk",
      album: "Discovery", year: 2001, trackNumber: 1)
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .albumArtistYearAlbum, renameFiles: true,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Daft Punk/2001 – Discovery/01 One More Time.mp3"]))
  }

  @Test
  func testPodcastRenamePreservesDownloadFingerprint() {
    var track = makeTrack(
      path: "/Library/Podcasts/Show/Episode [12ab34cd].mp3", title: "Episode",
      artist: "Host", album: "Show", trackNumber: 7)
    track.mediaKind = .podcast
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .artistAlbum, renameFiles: true,
      fileExists: { _ in false })
    #expect(
      plan.moves.map(\.relativeDestination)
        == ["Host/Show/07 Episode [12ab34cd].mp3"])
  }

  @Test
  func testGenrePatternAndUnknownFallbacks() {
    let track = makeTrack(path: "/Library/x.mp3", artist: "", album: "", genre: "")
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .genreArtistAlbum, renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Unknown Genre/Unknown Artist/Unknown Album/x.mp3"]))
  }

  @Test
  func testCompilationUsesVariousArtists() {
    let track = makeTrack(
      path: "/Library/x.mp3", artist: "Someone", album: "Now 45", compilation: true)
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Various Artists/Now 45/x.mp3"]))
  }

  @Test
  func testSanitizationStripsHostileCharacters() {
    #expect((LibraryOrganizer.sanitizeComponent("AC/DC")) == ("AC-DC"))
    #expect((LibraryOrganizer.sanitizeComponent("Song: Remix")) == ("Song- Remix"))
    #expect((LibraryOrganizer.sanitizeComponent("...hidden")) == ("hidden"))
    #expect((LibraryOrganizer.sanitizeComponent("   ")) == ("Unknown"))
    #expect((LibraryOrganizer.sanitizeComponent(String(repeating: "x", count: 300)).count) == (100))
  }

  @Test
  func testPlanningIsIdempotentForOrganizedLibrary() {
    let organized = makeTrack(
      path: "/Library/Daft Punk/Discovery/loose.mp3", artist: "Daft Punk", album: "Discovery")
    let plan = LibraryOrganizer.plan(
      tracks: [organized], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { _ in true })
    #expect(plan.moves.isEmpty)
    #expect((plan.alreadyOrganizedCount) == (1))
  }

  @Test
  func testConflictingDestinationsAreUniquified() {
    let first = makeTrack(
      path: "/Library/a/song.mp3", artist: "Artist", album: "Album")
    let second = makeTrack(
      path: "/Library/b/song.mp3", artist: "Artist", album: "Album")
    let plan = LibraryOrganizer.plan(
      tracks: [first, second], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination).sorted()) == (["Artist/Album/song 2.mp3", "Artist/Album/song.mp3"]))
    #expect((plan.moves.filter { $0.status == .renamedToAvoidConflict }.count) == (1))
  }

  @Test
  func testUnrelatedFileOnDiskForcesRenameUnderEveryConflictPolicy() {
    let track = makeTrack(path: "/Library/x/song.mp3", artist: "Artist", album: "Album")
    let occupied = root.appendingPathComponent("Artist/Album/song.mp3").standardizedFileURL
    for policy in [LibraryOrganizeConflictPolicy.rename, .moveToTrash] {
      let plan = LibraryOrganizer.plan(
        tracks: [track], root: root, pattern: .artistAlbum, renameFiles: false,
        conflictPolicy: policy,
        fileExists: { $0.standardizedFileURL.path == occupied.path })
      #expect((plan.moves.map(\.relativeDestination)) == (["Artist/Album/song 2.mp3"]))
      #expect((plan.moves[0].status) == (.renamedToAvoidConflict))
      #expect(plan.conflictRemovals.isEmpty)
    }
  }

  @Test
  func testCaseOnlyRenameIsNotBlockedByItsOwnFile() {
    // On APFS the destination "exists" case-insensitively as the track's own
    // file; the planner must treat that as a rename, not an obstruction.
    let track = makeTrack(
      path: "/Library/artist/album/song.mp3", artist: "Artist", album: "Album")
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { $0.path.lowercased() == track.url.path.lowercased() })
    #expect((plan.moves.map(\.relativeDestination)) == (["Artist/Album/song.mp3"]))
    #expect((plan.moves[0].status) == (.move))
  }

  @Test
  func testLongTitleTruncationKeepsAudioExtension() {
    var track = makeTrack(
      path: "/Library/x.mp3", title: String(repeating: "y", count: 150),
      artist: "Artist", album: "Album")
    track.trackNumber = 0
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, pattern: .artistAlbum, renameFiles: true,
      fileExists: { _ in false })
    let destination = plan.moves[0].relativeDestination
    #expect(destination.hasSuffix(".mp3"), Comment(rawValue: destination))
    #expect(((destination as NSString).lastPathComponent.count) <= (104))
  }

  @Test
  func testTrackAlreadyInPlaceClaimsItsPathAgainstConflicts() {
    let inPlace = makeTrack(
      path: "/Library/Artist/Album/song.mp3", artist: "Artist", album: "Album")
    let intruder = makeTrack(path: "/Library/other/song.mp3", artist: "Artist", album: "Album")
    let plan = LibraryOrganizer.plan(
      tracks: [intruder, inPlace], root: root, pattern: .artistAlbum, renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.alreadyOrganizedCount) == (1))
    #expect((plan.moves.map(\.relativeDestination)) == (["Artist/Album/song 2.mp3"]))
  }

  @Test
  func testTrashConflictPolicyRemovesOutOfPlaceTrackInsteadOfRenamingIt() throws {
    let inPlace = makeTrack(
      path: "/Library/Artist/Album/song.mp3", artist: "Artist", album: "Album")
    let straggler = makeTrack(
      path: "/Library/other/song.mp3", artist: "Artist", album: "Album")
    let plan = LibraryOrganizer.plan(
      tracks: [straggler, inPlace], root: root, pattern: .artistAlbum,
      renameFiles: false, conflictPolicy: .moveToTrash,
      fileExists: { _ in false })

    #expect(plan.moves.isEmpty)
    let removal = try #require(plan.conflictRemovals.first)
    #expect((removal.track.id) == (straggler.id))
    #expect((removal.conflictKeeper?.id) == (inPlace.id))
    #expect((removal.relativeDestination) == ("Artist/Album/song.mp3"))
  }

  @Test
  func testTrashConflictPolicyKeepsFirstPlannedMoveAndRemovesSecondClaimant() throws {
    let first = makeTrack(
      path: "/Library/a/song.mp3", artist: "Artist", album: "Album")
    let second = makeTrack(
      path: "/Library/b/song.mp3", artist: "Artist", album: "Album")
    let plan = LibraryOrganizer.plan(
      tracks: [second, first], root: root, pattern: .artistAlbum,
      renameFiles: false, conflictPolicy: .moveToTrash,
      fileExists: { _ in false })

    #expect((plan.moves.map(\.track.id)) == ([first.id]))
    let removal = try #require(plan.conflictRemovals.first)
    #expect((removal.track.id) == (second.id))
    #expect((removal.conflictKeeper?.id) == (first.id))
  }

  @Test
  func testCustomBlockStructureBuildsExpectedPath() {
    let track = makeTrack(
      path: "/Library/x.mp3", artist: "Daft Punk", album: "Discovery",
      genre: "Electronic", year: 2001)
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: [.decade, .year, .genre, .trackArtist, .album],
      renameFiles: false, fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["2000s/2001/Electronic/Daft Punk/Discovery/x.mp3"]))
  }

  @Test
  func testEveryBlockProducesAFolderForATaggedTrack() {
    var track = makeTrack(
      path: "/Library/x.mp3", title: "One More Time", artist: "Daft Punk",
      album: "Discovery", genre: "Electronic", year: 2001)
    track.albumArtist = "Daft Punk"
    track.composer = "Bangalter"
    track.grouping = "House"
    track.discNumber = 2
    track.bpm = 123
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: LibraryPathBlock.allCases,
      renameFiles: false, fileExists: { _ in false })
    #expect(
      (plan.moves.map(\.relativeDestination))
        == ([
          "Daft Punk/Daft Punk/Discovery/One More Time/Electronic/Bangalter/House"
            + "/2001/2001 – Discovery/2000s/Disc 2/123 BPM/x.mp3"
        ]))
  }

  @Test
  func testEveryBlockHasAFallbackForABareTrack() throws {
    let track = makeTrack(
      path: "/Library/x.mp3", title: "", artist: "", album: "", genre: "", year: 0)
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: LibraryPathBlock.allCases,
      renameFiles: false, fileExists: { _ in false })
    let destination = try #require(plan.moves.first?.relativeDestination)
    let folders = destination.split(separator: "/").dropLast()
    #expect((folders.count) == (LibraryPathBlock.allCases.count))
    for folder in folders {
      #expect(!(folder.isEmpty))
    }
  }

  @Test
  func testArtistBlockPrefersAlbumArtistWhileTrackArtistDoesNot() {
    var track = makeTrack(path: "/Library/x.mp3", artist: "Guest Singer", album: "Album")
    track.albumArtist = "Band"
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: [.artist, .trackArtist],
      renameFiles: false, fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Band/Guest Singer/x.mp3"]))
  }

  @Test
  func testEmptyBlockListFlattensIntoRoot() {
    let track = makeTrack(path: "/Library/deep/nested/song.mp3")
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: [], renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["song.mp3"]))
  }

  @Test
  func testUnknownYearAndDecadeFallBackToNamedFolders() {
    let track = makeTrack(path: "/Library/x.mp3", year: 0)
    let plan = LibraryOrganizer.plan(
      tracks: [track], root: root, blocks: [.decade, .year], renameFiles: false,
      fileExists: { _ in false })
    #expect((plan.moves.map(\.relativeDestination)) == (["Unknown Decade/Unknown Year/x.mp3"]))
  }

  @Test
  func testBlockListRoundTripsThroughStorageString() {
    let blocks: [LibraryPathBlock] = [.genre, .artist, .yearAlbum]
    #expect((LibraryPathBlock.decodeList(LibraryPathBlock.encodeList(blocks))) == (blocks))
    #expect(LibraryPathBlock.decodeList("artist/nonsense") == nil)
    #expect((LibraryPathBlock.decodeList("")) == ([]))
  }

  private func makeTrack(
    path: String, title: String = "Song", artist: String = "Artist",
    album: String = "Album", genre: String = "Rock", year: Int = 0,
    trackNumber: Int = 0, compilation: Bool = false
  ) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: path), title: title, artist: artist, album: album,
      genre: genre, trackNumber: trackNumber, year: year, compilation: compilation,
      durationMS: 180_000, bitrate: 256)
  }
}

// MARK: - Sidecar remapping

@MainActor
struct LibraryMaintenanceRemapTests {
  private final class MemoryPersistence: AppDataPersistence, @unchecked Sendable {
    var data: Data?
    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
  }

  @Test
  func testPlaylistRemapPreservesPositionAndDeduplicates() throws {
    let store = PlaylistStore(persistence: MemoryPersistence())
    let a = TrackID(url: URL(fileURLWithPath: "/Music/a.mp3"))
    let b = TrackID(url: URL(fileURLWithPath: "/Music/b.mp3"))
    let c = TrackID(url: URL(fileURLWithPath: "/Music/c.mp3"))
    let moved = TrackID(url: URL(fileURLWithPath: "/Music/Artist/Album/a.mp3"))
    let id = try store.create(name: "Mix", trackIDs: [a, b, c])

    try store.remapTrackIDs([a: moved])
    #expect((store.playlist(withID: id)?.trackIDs) == ([moved, b, c]))

    // Collapsing b onto c keeps c's earlier... b comes first, so b's slot
    // survives and the later duplicate c is dropped.
    try store.remapTrackIDs([b: c])
    #expect((store.playlist(withID: id)?.trackIDs) == ([moved, c]))
  }

  @Test
  func testHistoryRemapMovesMetadataAndHistory() throws {
    let store = ListeningHistoryStore(persistence: MemoryPersistence())
    let old = TrackID(url: URL(fileURLWithPath: "/Music/a.mp3"))
    let new = TrackID(url: URL(fileURLWithPath: "/Music/Artist/a.mp3"))
    try store.setRating(4, for: old)
    try store.recordPlay(of: old)

    try store.remapTrackIDs([old: new])

    #expect((store.rating(for: old)) == (0))
    #expect((store.rating(for: new)) == (4))
    #expect((store.playCount(for: new)) == (1))
    #expect((store.history.map(\.trackID)) == ([new]))
  }

  @Test
  func testHistoryRemapMergesStatisticsIntoExistingKeeper() throws {
    let store = ListeningHistoryStore(persistence: MemoryPersistence())
    let loser = TrackID(url: URL(fileURLWithPath: "/Music/dupe.mp3"))
    let keeper = TrackID(url: URL(fileURLWithPath: "/Music/keeper.mp3"))
    try store.setRating(5, for: loser)
    try store.setFavorite(true, for: [loser])
    try store.recordPlay(of: loser)
    try store.recordPlay(of: loser)
    try store.setRating(3, for: keeper)
    try store.recordPlay(of: keeper)

    try store.remapTrackIDs([loser: keeper])

    #expect((store.rating(for: keeper)) == (5))
    #expect(store.isFavorite(keeper))
    #expect((store.playCount(for: keeper)) == (3))
    #expect((store.metadataByID[loser]) == (nil))
    #expect(store.history.allSatisfy { $0.trackID == keeper })
  }

  @Test
  func testLedgerRemapRewritesPathAndRecapturesStamp() throws {
    let folder = TestScratch.directory(prefix: "NightdriveLedgerRemap")
    defer { try? FileManager.default.removeItem(at: folder) }
    let destinationDir = folder.appendingPathComponent("Artist/Album", isDirectory: true)
    try FileManager.default.createDirectory(
      at: destinationDir, withIntermediateDirectories: true)
    let destination = destinationDir.appendingPathComponent("song.mp3")
    try Data("audio".utf8).write(to: destination)
    let stamp = try #require(FileGenerationStamp(url: destination))

    let entry = SyncLedgerEntry(
      relativePath: "song.mp3", dbid: 7, fileSize: 1, fileModifiedAt: 0,
      fileGenerationStamp: stamp,
      contentSHA256: "abc", deviceSignature: "sig")
    try SyncLedgerStore.replaceEntries([entry], for: 99, libraryFolder: folder)

    try SyncLedgerStore.remapMovedFiles(
      ["song.mp3": "Artist/Album/song.mp3"], libraryFolder: folder)

    let updated = SyncLedgerStore.entries(for: 99, libraryFolder: folder)
    #expect((updated.map(\.relativePath)) == (["Artist/Album/song.mp3"]))
    #expect((updated[0].fileGenerationStamp) == (stamp))
    #expect((updated[0].fileSize) == (stamp.sizeBytes))
    #expect((updated[0].contentSHA256) == ("abc"))
    #expect((updated[0].dbid) == (7))
  }

  @Test
  func testQueueRemapRetargetsTracks() {
    let oldURL = URL(fileURLWithPath: "/Music/a.mp3")
    let newURL = URL(fileURLWithPath: "/Music/Artist/a.mp3")
    let old = LibraryTrack(
      url: oldURL, title: "Song", durationMS: 1000, sizeBytes: 1, bitrate: 128,
      samplerate: 44_100)
    let new = LibraryTrack(
      url: newURL, title: "Song", durationMS: 1000, sizeBytes: 1, bitrate: 128,
      samplerate: 44_100)
    var queue = PlaybackQueue()
    queue.activate(old, in: [old])

    queue.remapTracks([old.id: new.id], catalog: LibraryCatalog([new]))

    #expect((queue.tracks.map(\.id)) == ([new.id]))
  }
}

// MARK: - File relocation

@MainActor
final class LibraryRelocationTests {
  private var folder: URL!

  init() throws {
    folder = TestScratch.directory(prefix: "NightdriveRelocation")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  private func writeTrack(_ relativePath: String, title: String) throws -> URL {
    let url = folder.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let tags = MP3Builder.Tags(
      title: title, artist: "Artist", album: "Album", genre: "Rock",
      trackNumber: 1, year: 2020)
    try MP3Builder.build(tags: tags, seconds: 1).write(to: url)
    return url
  }

  @Test
  func testOrganizerTrashPolicyRemovesStragglerAndRetargetsReferences() async throws {
    final class Memory: RemovableAppDataPersistence, @unchecked Sendable {
      var data: Data?
      func load() -> Data? { data }
      func save(_ data: Data) { self.data = data }
      func remove() { data = nil }
    }

    let episodeID = "https://example.com/feed#organizer-conflict"
    let filename = "Episode [\(PodcastFileNaming.fingerprint(episodeID))].mp3"
    let keeperURL = try writeTrack("A/\(filename)", title: "Song")
    let stragglerURL = try writeTrack("Loose/\(filename)", title: "Song")
    let destinationPath = "Artist/Album/\(filename)"
    let destinationURL = folder.appendingPathComponent(destinationPath)
    let podcastSidecar = PodcastDownloadsFile.url(for: folder)
    try JSONEncoder().encode([episodeID: "Loose/\(filename)"]).write(to: podcastSidecar)
    let mutations = LibraryFileMutations(
      writeMetadata: { _, _, _, _, _ in },
      moveToTrash: { try FileManager.default.removeItem(at: $0) })
    let store = LibraryStore(folderURL: folder, fileMutations: mutations)
    await store.rescan()
    let keeper = try #require(store.tracks.first { $0.url.path.contains("/A/") })
    let straggler = try #require(store.tracks.first { $0.url.path.contains("/Loose/") })
    let playlists = PlaylistStore(persistence: Memory())
    let history = ListeningHistoryStore(persistence: Memory())
    let app = AppState(
      library: store,
      playlists: playlists,
      listeningHistory: history,
      playbackPersistence: PlaybackPersistenceStore(persistence: Memory()))
    let playlistID = try playlists.create(name: "Conflict", trackIDs: [straggler.id])
    try history.setRating(5, for: [straggler.id])
    let plan = LibraryOrganizer.plan(
      tracks: store.tracks, root: folder, pattern: .artistAlbum,
      renameFiles: false, conflictPolicy: .moveToTrash)

    let result = try #require(
      await app.organizeLibraryTracks(
        plan.changes(root: folder), expectedLibraryIdentity: store.identityRevision))

    #expect(result.failed.isEmpty)
    #expect((result.moved.count) == (1))
    #expect(!FileManager.default.fileExists(atPath: keeperURL.path))
    #expect(!FileManager.default.fileExists(atPath: stragglerURL.path))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Loose").path))
    #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    let organizedID = TrackID(url: destinationURL)
    #expect((store.tracks.map(\.id)) == ([organizedID]))
    #expect((playlists.playlist(withID: playlistID)?.trackIDs) == ([organizedID]))
    #expect((history.rating(for: organizedID)) == (5))
    #expect((history.rating(for: keeper.id)) == (0))
    #expect((history.rating(for: straggler.id)) == (0))
    let podcastMapping = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: podcastSidecar))
    #expect((podcastMapping[episodeID]) == (destinationPath))
  }

  @Test
  func testOrganizerKeepsStragglerWhenKeeperIsReplacedByDirectory() async throws {
    let keeperURL = try writeTrack("Artist/Album/song.mp3", title: "Song")
    let stragglerURL = try writeTrack("Loose/song.mp3", title: "Song")
    let mutations = LibraryFileMutations(
      writeMetadata: { _, _, _, _, _ in },
      moveToTrash: { try FileManager.default.removeItem(at: $0) })
    let store = LibraryStore(folderURL: folder, fileMutations: mutations)
    await store.rescan()
    let plan = LibraryOrganizer.plan(
      tracks: store.tracks, root: folder, pattern: .artistAlbum,
      renameFiles: false, conflictPolicy: .moveToTrash)
    try FileManager.default.removeItem(at: keeperURL)
    try FileManager.default.createDirectory(at: keeperURL, withIntermediateDirectories: true)
    let result = await store.trashOrganizerConflicts(plan.changes(root: folder).conflictRemovals)

    #expect((result.failed.count) == (1))
    #expect(FileManager.default.fileExists(atPath: stragglerURL.path))
  }

  @Test
  func testOrganizerKeepsStragglerWhenPlannedKeeperMoveFails() async throws {
    struct MoveFailure: Error {}

    let keeperURL = try writeTrack("A/song.mp3", title: "Song")
    let stragglerURL = try writeTrack("Loose/song.mp3", title: "Song")
    let mutations = LibraryFileMutations(
      writeMetadata: { _, _, _, _, _ in },
      moveToTrash: { try FileManager.default.removeItem(at: $0) },
      moveItem: { _, _ in throw MoveFailure() })
    let store = LibraryStore(folderURL: folder, fileMutations: mutations)
    await store.rescan()
    let plan = LibraryOrganizer.plan(
      tracks: store.tracks, root: folder, pattern: .artistAlbum,
      renameFiles: false, conflictPolicy: .moveToTrash)
    let app = AppState(library: store)

    let result = try #require(
      await app.organizeLibraryTracks(
        plan.changes(root: folder), expectedLibraryIdentity: store.identityRevision))

    #expect((result.failed.count) == (2))
    #expect(FileManager.default.fileExists(atPath: keeperURL.path))
    #expect(FileManager.default.fileExists(atPath: stragglerURL.path))
  }

  @Test
  func testBlockedSidecarAbortsMaintenanceBeforeAnyFileMoves() async throws {
    final class Garbage: RemovableAppDataPersistence, @unchecked Sendable {
      var data: Data? = Data("not json".utf8)
      func load() -> Data? { data }
      func save(_ data: Data) { self.data = data }
      func remove() { data = nil }
    }
    final class Memory: RemovableAppDataPersistence, @unchecked Sendable {
      var data: Data?
      func load() -> Data? { data }
      func save(_ data: Data) { self.data = data }
      func remove() { data = nil }
    }
    let source = try writeTrack("loose.mp3", title: "Song")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first)
    let app = AppState(
      library: store,
      playlists: PlaylistStore(persistence: Garbage()),
      listeningHistory: ListeningHistoryStore(persistence: Memory()),
      playbackPersistence: PlaybackPersistenceStore(persistence: Memory()))

    let relocation = await app.relocateLibraryTracks(
      [
        LibraryRelocationMove(
          track: track, destination: folder.appendingPathComponent("Artist/Album/loose.mp3"))
      ],
      expectedLibraryIdentity: store.identityRevision)
    let relocationOutcome = try #require(relocation)
    #expect(relocationOutcome.sidecarWarning != nil)
    #expect(relocationOutcome.moved.isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.path))

    let maintenance = await app.resolveDuplicateTracks(
      [AppState.DuplicateResolution(keeper: track, duplicates: [track])],
      expectedLibraryIdentity: store.identityRevision)
    let maintenanceOutcome = try #require(maintenance)
    #expect(maintenanceOutcome.sidecarWarning != nil)
    #expect((maintenanceOutcome.succeededCount) == (0))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test
  func testRelocateMovesFileCreatesDirectoriesAndCleansEmptySource() async throws {
    let source = try writeTrack("Old Folder/song.mp3", title: "Song")
    _ = try writeTrack("keep.mp3", title: "Keep")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first { $0.url.lastPathComponent == "song.mp3" })
    let destination = folder.appendingPathComponent("Artist/Album/song.mp3")

    let result = await store.relocate(
      [LibraryRelocationMove(track: track, destination: destination)])

    #expect((result.failed) == ([]))
    #expect((result.moved.map(\.destination.lastPathComponent)) == (["song.mp3"]))
    #expect(FileManager.default.fileExists(atPath: destination.path))
    #expect(!(FileManager.default.fileExists(atPath: source.path)))
    #expect(
      !(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("Old Folder").path)),
      Comment(rawValue: "Vacated directory should be removed"))
  }

  @Test
  func testAppRelocationRetargetsPodcastDownloadRecord() async throws {
    let episodeID = "https://example.com/feed#episode-1"
    let filename = "Episode [\(PodcastFileNaming.fingerprint(episodeID))].mp3"
    let sourcePath = "Podcasts/Show/\(filename)"
    _ = try writeTrack(sourcePath, title: "Episode")
    let sidecar = PodcastDownloadsFile.url(for: folder)
    try JSONEncoder().encode([episodeID: sourcePath]).write(to: sidecar)
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first)
    let podcasts = PodcastStore(persistence: EmptyDataPersistence())
    let app = AppState(library: store, podcasts: podcasts)
    let destinationPath = "Host/Show/\(filename)"

    let result = try #require(
      await app.relocateLibraryTracks(
        [
          LibraryRelocationMove(
            track: track, destination: folder.appendingPathComponent(destinationPath))
        ],
        expectedLibraryIdentity: store.identityRevision))

    #expect(result.sidecarWarning == nil)
    #expect(result.moved.count == 1)
    let mapping = try JSONDecoder().decode(
      [String: String].self, from: Data(contentsOf: sidecar))
    #expect(mapping[episodeID] == destinationPath)
  }

  @Test
  func testRelocateRefusesDestinationsOutsideTheLibrary() async throws {
    _ = try writeTrack("song.mp3", title: "Song")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first)
    let outside = folder.deletingLastPathComponent().appendingPathComponent("escape.mp3")

    let result = await store.relocate(
      [LibraryRelocationMove(track: track, destination: outside)])

    #expect((result.moved) == ([]))
    #expect((result.failed.count) == (1))
    #expect(FileManager.default.fileExists(atPath: track.url.path))
  }

  @Test
  func testRelocateRefusesToOverwriteExistingFiles() async throws {
    _ = try writeTrack("song.mp3", title: "Song")
    let occupied = try writeTrack("Artist/song.mp3", title: "Other")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(
      store.tracks.first { $0.url.path.hasSuffix("/song.mp3") && !$0.url.path.contains("Artist") })

    let result = await store.relocate(
      [LibraryRelocationMove(track: track, destination: occupied)])

    #expect((result.moved) == ([]))
    #expect((result.failed.count) == (1))
    #expect(FileManager.default.fileExists(atPath: track.url.path))
  }

  @Test
  func testRelocatedFileKeepsLedgerLinkForNoOpSync() async throws {
    let source = try writeTrack("song.mp3", title: "Song")
    let store = LibraryStore(folderURL: folder)
    await store.rescan()
    let track = try #require(store.tracks.first)
    let hash = try SyncSignature.fileSHA256(url: source)
    let entry = SyncLedgerEntry(
      relativePath: "song.mp3", dbid: 1,
      fileSize: track.sizeBytes,
      fileModifiedAt: track.modificationDate?.timeIntervalSince1970 ?? 0,
      fileGenerationStamp: try #require(track.fileGenerationStamp),
      contentSHA256: hash, deviceSignature: "sig")
    try SyncLedgerStore.replaceEntries([entry], for: 42, libraryFolder: folder)

    let destination = folder.appendingPathComponent("Artist/Album/song.mp3")
    let result = await store.relocate(
      [LibraryRelocationMove(track: track, destination: destination)])
    #expect((result.failed) == ([]))
    try SyncLedgerStore.remapMovedFiles(
      ["song.mp3": "Artist/Album/song.mp3"], libraryFolder: folder)
    await store.rescan()

    let moved = try #require(store.tracks.first)
    let updated = try #require(SyncLedgerStore.entries(for: 42, libraryFolder: folder).first)
    #expect((updated.relativePath) == ("Artist/Album/song.mp3"))
    #expect(
      !(SyncSignature.localLooksChanged(moved, entry: updated)),
      Comment(rawValue: "An organized file must not look changed to the next sync"))
  }
}
