import AppKit
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

struct QuickSearchMatcherTests {
  @Test
  func testMatchesSubsequenceAndRejectsNonSubsequence() {
    #expect(QuickSearchMatcher.score("mdna", in: "Madonna") != nil)
    #expect(QuickSearchMatcher.score("xyz", in: "Madonna") == nil)
    #expect(QuickSearchMatcher.score("madonnaa", in: "Madonna") == nil)
    #expect(QuickSearchMatcher.score("", in: "Madonna") == nil)
  }

  @Test
  func testMatchingIgnoresCaseAndDiacritics() {
    #expect(QuickSearchMatcher.score("beyonce", in: "Beyoncé") != nil)
    #expect(QuickSearchMatcher.score("MADONNA", in: "madonna") != nil)
  }

  @Test
  func testPrefixOutranksWordInitialsAndScattered() {
    let prefix = QuickSearchMatcher.score("mad", in: "Madonna")!
    let initials = QuickSearchMatcher.score("mad", in: "My Adorable Dog")!
    let scattered = QuickSearchMatcher.score("mad", in: "Diamond Sandstorm")!
    #expect(prefix > initials)
    #expect(initials > scattered)
  }

  @Test
  func testShorterCandidateWinsTies() {
    let exact = QuickSearchMatcher.score("madonna", in: "Madonna")!
    let longer = QuickSearchMatcher.score("madonna", in: "Madonna and Friends")!
    #expect(exact > longer)
  }
}

struct QuickSearchTests {
  @Test
  func testEmptyQueryShowsNavigationPlayerAndToolCommands() {
    let commands = QuickSearch.commands(matching: "   ")

    #expect(commands.count == QuickSearch.commands.count)
    #expect(commands.contains { $0.kind == .navigation })
    #expect(commands.contains { $0.kind == .player })
    #expect(commands.contains { $0.kind == .tool })
    #expect(Set(commands.prefix(7).map(\.kind)) == [.navigation, .player, .tool])
  }

  @Test
  func testCommandsMatchTitlesAndDiscoveryKeywords() {
    let navigation = QuickSearch.commands(matching: "genres")
    let player = QuickSearch.commands(matching: "skip")
    let tool = QuickSearch.commands(matching: "duplicate detection")
    let settings = QuickSearch.commands(matching: "online")
    let operation = QuickSearch.commands(matching: "refresh")

    #expect(navigation.first?.action == .navigate(.genres))
    #expect(player.first?.action == .nextTrack)
    #expect(tool.first?.action == .findDuplicates)
    #expect(settings.first?.action == .openSettings(.online))
    #expect(operation.first?.action == .rescanLibrary)
  }

  @Test
  func testSidebarCommandShortcutsDeriveFromMenuOrder() {
    #expect(
      SidebarItem.commandOrder.map(\.commandShortcutLabel)
        == ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5", "⌘6", "⌘7", "⌘8", "⌘9"])
    #expect(SidebarItem.audiobooks.commandShortcutLabel == "⌘5")
    #expect(SidebarItem.device(URL(fileURLWithPath: "/iPod")).commandShortcutLabel == nil)
    // Every navigation command in the palette shows the same shortcut the
    // View menu derives for its sidebar item.
    for command in QuickSearch.commands {
      if case .navigate(let item) = command.action {
        #expect(command.shortcut == item.commandShortcutLabel)
      }
    }
  }

  @Test
  func testContextualDeviceAndPlaylistCommandsParticipateInCommandSearch() {
    let playlistID = UUID()
    let contextual = [
      QuickSearchCommand(
        id: "view:device:test", kind: .navigation, title: "Felix’s iPod",
        subtitle: "Open iPod classic", systemImage: "ipod",
        keywords: ["device", "ipod"], action: .navigate(.device(URL(fileURLWithPath: "/iPod"))),
        shortcut: "⌘9"),
      QuickSearchCommand(
        id: "view:playlist:test", kind: .navigation, title: "Road Trip",
        subtitle: "Open playlist · 12 songs", systemImage: "music.note.list",
        keywords: ["playlist"], action: .navigatePlaylist(playlistID), shortcut: nil),
    ]

    let device = QuickSearch.commands(matching: "Felix ipod", additionalCommands: contextual)
    let playlist = QuickSearch.commands(matching: "road trip", additionalCommands: contextual)

    #expect(device.first?.action == .navigate(.device(URL(fileURLWithPath: "/iPod"))))
    #expect(device.first?.shortcut == "⌘9")
    #expect(playlist.first?.action == .navigatePlaylist(playlistID))
  }

  @Test
  func testPlayerCommandsResolveToCurrentState() {
    let play = try! #require(QuickSearch.commands.first { $0.action == .togglePlayPause })
    let shuffle = try! #require(QuickSearch.commands.first { $0.action == .toggleShuffle })
    let repeatCommand = try! #require(QuickSearch.commands.first { $0.action == .cycleRepeatMode })
    let mute = try! #require(QuickSearch.commands.first { $0.action == .toggleMute })

    #expect(
      play.resolvingPlayerState(
        isPlaying: true, isShuffleEnabled: false, repeatMode: .off, isMuted: false
      ).title == "Pause")
    #expect(
      shuffle.resolvingPlayerState(
        isPlaying: false, isShuffleEnabled: true, repeatMode: .off, isMuted: false
      ).title == "Turn Shuffle Off")
    let repeatAll = repeatCommand.resolvingPlayerState(
      isPlaying: false, isShuffleEnabled: false, repeatMode: .all, isMuted: false)
    #expect(repeatAll.title == "Repeat All")
    #expect(repeatAll.subtitle == "Next: Repeat One")
    let stateCommands = QuickSearch.commands.map {
      $0.resolvingPlayerState(
        isPlaying: false, isShuffleEnabled: false, repeatMode: .all, isMuted: false)
    }
    #expect(
      QuickSearch.commands(matching: "repeat all", baseCommands: stateCommands).first?.action
        == .cycleRepeatMode)
    #expect(
      QuickSearch.commands(matching: "cycle", baseCommands: stateCommands).first?.action
        == .cycleRepeatMode)
    #expect(
      QuickSearch.commands(matching: "toggle", baseCommands: stateCommands).first?.action
        == .toggleShuffle)
    #expect(
      mute.resolvingPlayerState(
        isPlaying: false, isShuffleEnabled: false, repeatMode: .off, isMuted: true
      ).title == "Unmute")
  }

  @Test
  func testCommandIdentifiersAreUnique() {
    let ids = QuickSearch.commands.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test
  func testEmptyQueryReturnsNothing() {
    let fixture = makeFixture()
    let results = QuickSearch.results(
      matching: "   ", artists: fixture.artists, albums: fixture.albums, tracks: fixture.tracks)
    #expect(results.isEmpty)
  }

  @Test
  func testArtistOutranksSameNamedSongAndCarriesAllTracks() {
    let fixture = makeFixture()
    let results = QuickSearch.results(
      matching: "madonna", artists: fixture.artists, albums: fixture.albums,
      tracks: fixture.tracks)

    let top = try! #require(results.first)
    #expect(top.collectionID == fixture.artists.first?.id)
    #expect(top.title == "Madonna")
    #expect(top.tracks.map(\.title) == ["Vogue", "Frozen", "Madonna"])
    #expect(top.start == top.tracks.first)
    #expect(top.collectionID == fixture.artists.first?.id)
  }

  @Test
  func testSongResultStartsAtTheSongInsideItsAlbum() {
    let fixture = makeFixture()
    let results = QuickSearch.results(
      matching: "frozen", artists: fixture.artists, albums: fixture.albums,
      tracks: fixture.tracks)

    let song = try! #require(results.first { $0.collectionID == nil })
    #expect(song.title == "Frozen")
    #expect(song.start.title == "Frozen")
    #expect(song.tracks.map(\.title) == ["Frozen", "Madonna"])
  }

  @Test
  func testGenreAndAudiobookResultsCarryTheirCollections() {
    let vogue = makeTrack("Vogue", artist: "Madonna", album: "Celebration")
    let book = makeTrack("Becoming", artist: "Michelle Obama", album: "Becoming")
    let pop = collection(kind: .genre, "Pop", subtitle: "1 song", tracks: [vogue])
    let becoming = collection(kind: .audiobook, "Becoming", subtitle: "1 part", tracks: [book])

    let genre = QuickSearch.results(
      matching: "pop", artists: [], albums: [], genres: [pop], audiobooks: [], tracks: [])
    let audiobook = QuickSearch.results(
      matching: "becoming", artists: [], albums: [], genres: [], audiobooks: [becoming],
      tracks: [])

    let genreHit = try! #require(genre.first)
    #expect(genreHit.collectionID == pop.id)
    #expect(genreHit.tracks == [vogue])
    let audiobookHit = try! #require(audiobook.first)
    #expect(audiobookHit.collectionID == becoming.id)
  }

  @Test
  func testSongMatchesThroughArtistPlusTitle() {
    let fixture = makeFixture()
    let results = QuickSearch.results(
      matching: "madonna vogue", artists: fixture.artists, albums: fixture.albums,
      tracks: fixture.tracks)

    let song = try! #require(results.first { $0.collectionID == nil })
    #expect(song.title == "Vogue")
  }

  @Test
  func testAlbumResultPlaysTheAlbum() {
    let fixture = makeFixture()
    let results = QuickSearch.results(
      matching: "ray of light", artists: fixture.artists, albums: fixture.albums,
      tracks: fixture.tracks)

    let album = try! #require(results.first)
    #expect(album.collectionID == fixture.albums[1].id)
    #expect(album.tracks.map(\.title) == ["Frozen", "Madonna"])
    #expect(album.start == album.tracks.first)
  }

  @Test
  func testResultCountIsCapped() {
    let tracks = (0..<40).map { index in
      LibraryTrack.fixture(
        url: URL(fileURLWithPath: "/tmp/nightdrive-quicksearch-cap-\(index).mp3"),
        title: "Song \(index)")
    }
    let results = QuickSearch.results(matching: "song", artists: [], albums: [], tracks: tracks)
    #expect(results.count == QuickSearch.maxResults)
  }

  @Test
  func testCappedResultsStillSurfaceTheBestLateMatch() {
    // The exact-title hit arrives after the top-K set is already full, so it
    // must displace a weaker filler instead of being dropped.
    var tracks = (0..<40).map { index in
      LibraryTrack.fixture(
        url: URL(fileURLWithPath: "/tmp/nightdrive-quicksearch-late-\(index).mp3"),
        title: "Song Number \(index)")
    }
    tracks.append(
      LibraryTrack.fixture(
        url: URL(fileURLWithPath: "/tmp/nightdrive-quicksearch-late-exact.mp3"), title: "Song"))
    let results = QuickSearch.results(matching: "song", artists: [], albums: [], tracks: tracks)
    #expect(results.count == QuickSearch.maxResults)
    #expect(results.first?.title == "Song")
  }

  @Test
  func testPrebuiltIndexMatchesDirectResults() throws {
    let fixture = makeFixture()
    let index = QuickSearchIndex(
      artists: fixture.artists, albums: fixture.albums, genres: [], audiobooks: [],
      tracks: fixture.tracks)
    for query in ["madonna", "frozen", "ray of light", "madonna vogue", "mdna", "beyonce"] {
      let direct = QuickSearch.results(
        matching: query, artists: fixture.artists, albums: fixture.albums,
        tracks: fixture.tracks)
      #expect(try QuickSearch.results(matching: query, in: index) == direct, "query: \(query)")
    }
  }

  private func makeFixture() -> (
    artists: [LibraryCollection], albums: [LibraryCollection], tracks: [LibraryTrack]
  ) {
    let vogue = makeTrack("Vogue", artist: "Madonna", album: "Celebration")
    let frozen = makeTrack("Frozen", artist: "Madonna", album: "Ray of Light")
    // A song literally titled "Madonna" so the artist has to win the tie.
    let madonnaSong = makeTrack("Madonna", artist: "Madonna", album: "Ray of Light")
    let other = makeTrack("Toxic", artist: "Britney Spears", album: "In the Zone")

    let artists = [
      collection(kind: .artist, "Madonna", subtitle: "3 songs", tracks: [vogue, frozen, madonnaSong]),
      collection(kind: .artist, "Britney Spears", subtitle: "1 song", tracks: [other]),
    ]
    let albums = [
      collection(kind: .album, "Celebration", subtitle: "Madonna · 1 song", tracks: [vogue]),
      collection(
        kind: .album, "Ray of Light", subtitle: "Madonna · 2 songs", tracks: [frozen, madonnaSong]),
      collection(kind: .album, "In the Zone", subtitle: "Britney Spears · 1 song", tracks: [other]),
    ]
    return (artists, albums, [vogue, frozen, madonnaSong, other])
  }

  private func makeTrack(_ title: String, artist: String, album: String) -> LibraryTrack {
    .fixture(
      url: URL(fileURLWithPath: "/tmp/nightdrive-quicksearch-\(title).mp3"),
      title: title, artist: artist, album: album)
  }

  private func collection(
    kind: LibraryBrowseKind, _ title: String, subtitle: String, tracks: [LibraryTrack]
  ) -> LibraryCollection {
    LibraryCollection(
      id: LibraryCollectionID(kind: kind, primary: title.lowercased(), secondary: ""),
      title: title, subtitle: subtitle, tracks: tracks)
  }
}

@MainActor
struct QuickSearchCommandActionTests {
  @Test
  func testCommandsDrivePlaylistPlayerAndMaintenanceState() {
    _ = NSApplication.shared
    let app = AppState(
      playlists: PlaylistStore(persistence: QuickSearchMemoryPersistence()),
      listeningHistory: ListeningHistoryStore(persistence: QuickSearchMemoryPersistence()),
      playbackPersistence: PlaybackPersistenceStore(persistence: QuickSearchMemoryPersistence()),
      onlineServices: OnlineServicesPolicy(persistence: QuickSearchMemoryPersistence()),
      musicBrainzSuggestions: MusicBrainzSuggestionStore(
        persistence: QuickSearchMemoryPersistence()))
    let playlistID = UUID()

    app.performQuickSearchCommand(.navigatePlaylist(playlistID))
    #expect(app.selection == .playlists)
    #expect(app.selectedPlaylistID == playlistID)

    let feedURL = URL(string: "https://example.com/feed.xml")!
    app.performQuickSearchCommand(.navigatePodcast(feedURL))
    #expect(app.selection == .podcasts)
    #expect(app.pendingPodcastReveal == feedURL)

    app.performQuickSearchCommand(.toggleShuffle)
    app.performQuickSearchCommand(.cycleRepeatMode)
    app.performQuickSearchCommand(.toggleMute)
    #expect(app.player.isShuffleEnabled)
    #expect(app.player.repeatMode == .all)
    #expect(app.player.isMuted)

    app.performQuickSearchCommand(.findDuplicates)
    app.performQuickSearchCommand(.cleanUpGenres)
    app.performQuickSearchCommand(.findMetadataProblems)
    app.performQuickSearchCommand(.organizeLibrary)
    #expect(app.isFindDuplicatesPresented)
    #expect(app.isCleanUpGenresPresented)
    #expect(app.isFindMetadataProblemsPresented)
    #expect(app.isOrganizeLibraryPresented)

    var openedMainWindow = false
    app.openMainWindow = { openedMainWindow = true }
    let previousEditInfoRequest = app.editInfoRequest
    app.requestEditInfo()
    #expect(openedMainWindow)
    #expect(app.editInfoRequest == previousEditInfoRequest + 1)
  }

  @Test
  func testRevealsRouteToTheMatchingView() {
    _ = NSApplication.shared
    let app = AppState(
      playlists: PlaylistStore(persistence: QuickSearchMemoryPersistence()),
      listeningHistory: ListeningHistoryStore(persistence: QuickSearchMemoryPersistence()),
      playbackPersistence: PlaybackPersistenceStore(persistence: QuickSearchMemoryPersistence()),
      onlineServices: OnlineServicesPolicy(persistence: QuickSearchMemoryPersistence()),
      musicBrainzSuggestions: MusicBrainzSuggestionStore(
        persistence: QuickSearchMemoryPersistence()))
    let track = LibraryTrack.fixture(
      url: URL(fileURLWithPath: "/tmp/nightdrive-quicksearch-reveal.mp3"), title: "drivers license")

    let artist = LibraryCollectionID(kind: .artist, primary: "olivia rodrigo", secondary: "")
    app.selectedTrackIDs = [track.id]
    app.revealCollection(artist)
    #expect(app.selection == .artists)
    #expect(app.pendingCollectionReveal == artist)
    #expect(app.selectedTrackIDs.isEmpty)

    let genre = LibraryCollectionID(kind: .genre, primary: "pop", secondary: "")
    app.revealCollection(genre)
    #expect(app.selection == .genres)
    #expect(app.pendingCollectionReveal == genre)

    app.searchText = "stale filter"
    app.revealLibraryTrack(track)
    #expect(app.selection == .library)
    #expect(app.selectedTrackIDs == [track.id])
    #expect(app.searchText.isEmpty)
  }
}

private final class QuickSearchMemoryPersistence: RemovableAppDataPersistence, Sendable {
  private let stored = Mutex<Data?>(nil)

  func load() throws -> Data? { stored.withLock { $0 } }
  func save(_ data: Data) throws { stored.withLock { $0 = data } }
  func remove() throws { stored.withLock { $0 = nil } }
}
