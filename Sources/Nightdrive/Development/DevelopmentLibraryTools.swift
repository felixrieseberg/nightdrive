#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation

  @MainActor
  enum DevelopmentLibraryTools {
    static func seedDemoLibrary(app: AppState) async {
      let folder = DevelopmentDevices.root
        .deletingLastPathComponent()
        .appendingPathComponent("DevelopmentLibrary", isDirectory: true)
      guard
        DevelopmentAlert.confirm(
          title: "Use the demo library?",
          message: """
            Songs are written to \(folder.path) and the app switches to that \
            folder. Your own library folder is not touched.
            """,
          proceedTitle: "Seed and Switch")
      else { return }
      do {
        try DemoSeeder.seedLibrary(at: folder)
      } catch {
        DevelopmentAlert.report(error, doing: "seed the demo library")
        return
      }
      app.setLibraryFolder(folder)
    }

    static func seedMessyLibrary(app: AppState) async {
      let folder = DevelopmentDevices.root
        .deletingLastPathComponent()
        .appendingPathComponent("DevelopmentMessyLibrary", isDirectory: true)
      guard
        DevelopmentAlert.confirm(
          title: "Use a messy demo library?",
          message: """
            A library full of duplicates and badly filed songs is written to \
            \(folder.path) and the app switches to that folder — made for \
            trying Find Duplicates and Organize Library Files. Your own \
            library folder is not touched.
            """,
          proceedTitle: "Seed and Switch")
      else { return }
      do {
        if FileManager.default.fileExists(atPath: folder.path),
          DevelopmentSafety.isFakeVolume(folder)
        {
          try FileManager.default.removeItem(at: folder)
        }
        try DemoSeeder.seedMessyLibrary(at: folder)
      } catch {
        DevelopmentAlert.report(error, doing: "seed the messy demo library")
        return
      }
      app.setLibraryFolder(folder)
    }

    static func dropIndexCache(app: AppState) async {
      guard let folder = app.library.folderURL else {
        DevelopmentAlert.show(
          title: "No library folder",
          message: "There is no index cache until a library folder is chosen.")
        return
      }
      LibraryIndexCache().saveEntries([:], for: folder)
      await app.library.rescan()
    }

    static func resetListeningHistory(app: AppState) {
      guard
        DevelopmentAlert.confirm(
          title: "Reset all listening history?",
          message: """
            Play counts, ratings, favorites, history entries, and the record \
            of which device play-count reports were applied all go away.
            """,
          proceedTitle: "Reset")
      else { return }
      do {
        try app.listeningHistory.removeAllForDevelopment()
      } catch {
        DevelopmentAlert.report(error, doing: "reset listening history")
        return
      }
      app.refreshSmartPlaylists()
    }

    static func resetOnlineConsent(app: AppState) {
      app.onlineServices.setConsent(.unset)
    }

    static func injectSampleSuggestions(app: AppState) {
      let tracks = Array(app.library.tracks.prefix(3))
      guard !tracks.isEmpty else {
        DevelopmentAlert.show(
          title: "No songs to suggest edits for",
          message: "Scan a library first, or seed the demo library.")
        return
      }
      let proposals = tracks.map { track -> MusicBrainzTrackSuggestion in
        var proposed = TrackMetadata(track)
        proposed.genre = proposed.genre.isEmpty ? "Indie Rock" : "\(proposed.genre) (revised)"
        proposed.year = proposed.year == 0 ? 2004 : proposed.year
        proposed.musicBrainzReleaseID = "00000000-0000-4000-8000-develop000001"
        return MusicBrainzTrackSuggestion(
          trackKey: track.id.rawValue,
          displayTitle: track.displayTitle,
          current: TrackMetadata(track),
          proposed: proposed)
      }
      let first = tracks[0]
      app.musicBrainzSuggestions.add(
        MusicBrainzAlbumSuggestion(
          id: "develop-sample-\(first.album)",
          albumTitle: first.album.isEmpty ? "Sample Album" : first.album,
          artistName: first.artist.isEmpty ? "Sample Artist" : first.artist,
          releaseID: "00000000-0000-4000-8000-develop000001",
          releaseTitle: first.album.isEmpty ? "Sample Album" : first.album,
          releaseYear: 2004,
          tracks: proposals))
      app.openSuggestionsInbox()
    }
  }
#endif
