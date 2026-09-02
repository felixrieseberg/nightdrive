import AppKit
import Darwin
import Foundation

/// Command-line entry points. Only `reset-sidecar` is user-facing and ships in
/// release builds; every other subcommand exists for the development, test, and
/// benchmark harnesses and is compiled only with NIGHTDRIVE_DEVELOPMENT_TOOLS.
enum CLI {
  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    struct SyncSidecarSnapshot: Sendable {
      let playlists: [LocalPlaylist]
      let listeningHistory: ListeningHistoryPayload
    }

    static func loadSyncSidecars(libraryFolder: URL) throws -> SyncSidecarSnapshot {
      try SyncSidecarSnapshot(
        playlists: LocalPlaylistFile.load(libraryFolder: libraryFolder),
        listeningHistory: ListeningHistoryFile.loadPayload(libraryFolder: libraryFolder))
    }
  #endif

  static func runIfRequested() {
    let args = CommandLine.arguments
    guard args.count >= 2 else { return }
    switch args[1] {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      case "benchmark-library":
        do {
          let configuration = try LargeLibraryBenchmark.Configuration.parse(args.dropFirst(2))
          Task { @MainActor in
            do {
              try await LargeLibraryBenchmark.run(configuration: configuration)
              exit(0)
            } catch {
              fail(String(describing: error))
            }
          }
          dispatchMain()
        } catch {
          fail(String(describing: error))
        }
      case "seed-demo":
        var seedArgs = Array(args.dropFirst(2))
        var shuffle = false
        if let index = seedArgs.firstIndex(of: "--shuffle") {
          shuffle = true
          seedArgs.remove(at: index)
        }
        guard seedArgs.count == 2 else {
          fail(String(localized: "usage: seed-demo <libraryDir> <fakeIpodDir> [--shuffle]"))
        }
        let libraryDir = URL(fileURLWithPath: seedArgs[0], isDirectory: true)
        let ipodDir = URL(fileURLWithPath: seedArgs[1], isDirectory: true)
        if let unsafeTarget = unsafeSeedDemoTarget(libraryDir: libraryDir, ipodDir: ipodDir) {
          fail(
            "refusing to seed \(unsafeTarget.path): it is (or is inside) a mounted volume."
              + " seed-demo only writes to plain directories.")
        }
        do {
          try DemoSeeder.seed(libraryDir: libraryDir, ipodDir: ipodDir, shuffle: shuffle)
          print(
            shuffle
              ? String(localized: "Seeded demo library and fake iPod shuffle.")
              : String(localized: "Seeded demo library and fake iPod."))
          exit(0)
        } catch {
          let errorDescription = String(describing: error)
          fail(String(localized: "seed failed: \(errorDescription)"))
        }
      case "sync":
        let usage = String(
          localized:
            "usage: sync <libraryDir> <ipodVolume> [--scope everything|playlists=Name[,Name…]] [--song-sync two-way|ipod-to-library|library-to-ipod] [--trim] [--confirm-removals] [--assume-empty-ledger]"
        )
        guard args.count >= 4 else { fail(usage) }
        let libraryDir = URL(fileURLWithPath: args[2], isDirectory: true)
        let ipodDir = URL(fileURLWithPath: args[3], isDirectory: true)
        var scopeArgument: String?
        var songSyncArgument: String?
        var applyTrim = false
        var confirmRemovals = false
        var assumeEmptyLedger = false
        var argIndex = 4
        while argIndex < args.count {
          switch args[argIndex] {
          case "--scope" where argIndex + 1 < args.count:
            scopeArgument = args[argIndex + 1]
            argIndex += 2
          case "--song-sync" where argIndex + 1 < args.count:
            songSyncArgument = args[argIndex + 1]
            argIndex += 2
          case "--trim":
            applyTrim = true
            argIndex += 1
          case "--confirm-removals":
            confirmRemovals = true
            argIndex += 1
          case "--assume-empty-ledger":
            assumeEmptyLedger = true
            argIndex += 1
          default:
            fail(usage)
          }
        }
        guard IpodFileSystem.isIpodVolume(ipodDir) else {
          fail(String(localized: "\(args[3]) does not look like an iPod (no iPod_Control directory)"))
        }
        let requestedScope = scopeArgument
        let requestedTrackSyncMode = songSyncArgument.map(parseTrackSyncMode)
        let shouldApplyTrim = applyTrim
        let shouldConfirmRemovals = confirmRemovals
        let shouldAssumeEmptyLedger = assumeEmptyLedger
        Task {
          do {
            let localEffects = SyncWorkflow.LocalEffects(
              applyPlaylists: { result, playlists in
                let outcome = PlaylistSyncApplier.apply(result: result, to: playlists)
                if outcome.changedLibrary {
                  _ = try LocalPlaylistFile.load(libraryFolder: libraryDir)
                  try LocalPlaylistFile.save(outcome.playlists, libraryFolder: libraryDir)
                }
                return outcome
              },
              mergePlayback: { report in
                try ListeningHistoryFile.merge(report, libraryFolder: libraryDir)
              })
            let result = try await SyncWorkflow.execute(
              deviceVolume: ipodDir,
              libraryFolder: libraryDir,
              deviceName: String(localized: "the iPod"),
              prepare: {
                if shouldAssumeEmptyLedger {
                  do {
                    _ = try SyncLedgerStore.load(libraryFolder: libraryDir)
                  } catch is SidecarIntegrityError {
                    if let quarantine = try SyncLedgerStore.assumeEmptyAfterIntegrityWarning(
                      libraryFolder: libraryDir)
                    {
                      print(
                        String(
                          localized:
                            "Preserved the unreadable sync ledger at \(quarantine.path); starting with an empty ledger."
                        ))
                    }
                  }
                }
                _ = try SyncLedgerStore.load(libraryFolder: libraryDir)
                let sidecars = try loadSyncSidecars(libraryFolder: libraryDir)
                let libraryURLs = LibraryStore.findAudioFiles(in: libraryDir)
                let libraryTracks = await LibraryStore.loadTracks(at: libraryURLs)
                let fs = IpodFileSystem(volumeURL: ipodDir)
                let db = try fs.readDatabase()
                let deviceFamily = fs.deviceFamily()
                let transcodeSettings = TranscodeSettings.load()
                let links = SyncLedgerStore.resolveLinks(
                  entries: try SyncLedgerStore.checkedEntries(
                    for: db.databaseID, libraryFolder: libraryDir),
                  library: libraryTracks, device: db.tracks, libraryFolder: libraryDir)
                var settings = try SyncLedgerStore.checkedDeviceSettings(
                  for: db.databaseID, libraryFolder: libraryDir)
                if shouldConfirmRemovals,
                  (requestedTrackSyncMode ?? settings.trackSyncMode) != .libraryToIpod
                {
                  fail("--confirm-removals requires Library-to-iPod song sync")
                }
                if shouldConfirmRemovals, libraryTracks.isEmpty, !db.tracks.isEmpty {
                  fail(
                    "--confirm-removals refused: the library scan found no songs, but the iPod has \(db.tracks.count). Check that \(libraryDir.path) is the right folder before removing everything."
                  )
                }

                var localPlaylists = sidecars.playlists
                let listeningPayload = sidecars.listeningHistory
                let listeningFacts = Dictionary(
                  listeningPayload.metadataByID.values.map {
                    ($0.trackID.rawValue, SmartRuleFacts($0))
                  },
                  uniquingKeysWith: { first, _ in first })
                let refreshed = SmartPlaylistEvaluator.refresh(
                  localPlaylists, library: libraryTracks, facts: listeningFacts)
                if refreshed.changed {
                  localPlaylists = refreshed.playlists
                  try LocalPlaylistFile.save(localPlaylists, libraryFolder: libraryDir)
                  print(String(localized: "Refreshed smart playlist membership."))
                }

                if let requestedScope {
                  settings.scope = parseScope(requestedScope, playlists: localPlaylists)
                }
                if let requestedTrackSyncMode {
                  if settings.trackSyncMode != requestedTrackSyncMode {
                    settings.removesSongsNotInLibrary = false
                    settings.removesSongsOutsideSyncScope = false
                  }
                  settings.trackSyncMode = requestedTrackSyncMode
                }
                if requestedScope != nil || requestedTrackSyncMode != nil {
                  try await SyncEngine.writeDeviceSettings(
                    settings, databaseID: db.databaseID, libraryFolder: libraryDir)
                }
                if requestedScope != nil {
                  print(String(localized: "Saved sync scope for this iPod: \(settings.scope.summary)"))
                }
                if requestedTrackSyncMode != nil {
                  print(
                    String(
                      localized: "Saved song sync for this iPod: \(settings.trackSyncMode.summary)"))
                }
                let scopeInput = SyncScopeInput(
                  scope: settings.scope, trackSyncMode: settings.trackSyncMode,
                  removesSongsNotInLibrary: shouldConfirmRemovals,
                  removesSongsOutsideSyncScope: shouldConfirmRemovals,
                  localPlaylists: localPlaylists, listeningFacts: listeningFacts)
                var plan = SyncEngine.makePlan(
                  library: libraryTracks, device: db.tracks, links: links,
                  deviceFamily: deviceFamily, transcodeSettings: transcodeSettings,
                  scope: scopeInput)
                plan.localPlaylists = localPlaylists
                plan.localRatings = listeningPayload.metadataByID.values.reduce(into: [:]) {
                  result, value in
                  if value.rating > 0 { result[value.trackID.rawValue] = value.rating }
                }
                print(
                  String(
                    localized:
                      "Library: \(libraryTracks.count) songs. iPod: \(db.tracks.count) songs."))
                if case .everything = settings.scope {
                } else {
                  print(String(localized: "Sync scope: \(settings.scope.summary)"))
                }
                if settings.trackSyncMode != .twoWay {
                  print(String(localized: "Song sync: \(settings.trackSyncMode.summary)"))
                }
                printPlanCounts(plan, trackSyncMode: settings.trackSyncMode)
                plan.scopeInput.confirmedRemovalDbids = Set(plan.removeFromDevice.map(\.dbid))

                let availableCapacity: Int64
                do {
                  availableCapacity = try cliAvailableCapacity(volume: ipodDir)
                } catch {
                  fail(
                    String(
                      localized:
                        "Could not read the iPod's free space: \(error.localizedDescription)"))
                }
                if let shortfall = SyncCapacity.shortfall(
                  plan: plan, availableCapacity: availableCapacity,
                  family: deviceFamily, settings: transcodeSettings)
                {
                  guard
                    SyncCapacity.trimCanRecover(
                      plan: plan, availableCapacity: availableCapacity,
                      family: deviceFamily, settings: transcodeSettings)
                  else {
                    fail(
                      String(
                        localized:
                          "Not syncing: planned updates are \(shortfall.byteText) over the iPod's free space, and dropping new songs would not help. Free up space or narrow the scope."
                      ))
                  }
                  let trim = SyncCapacity.suggestedTrim(
                    plan: plan, shortfall: shortfall,
                    family: deviceFamily, settings: transcodeSettings)
                  print(
                    String(
                      localized:
                        "Planned copies are \(shortfall.byteText) over the iPod's free space. Suggested trim (lowest-rated, least-recently-played first):"
                    ))
                  for track in trim { print(String(localized: "  - \(track.displayTitle)")) }
                  guard shouldApplyTrim else {
                    fail(
                      String(
                        localized:
                          "Not syncing: over capacity. Re-run with --trim to drop the suggested songs."))
                  }
                  let trimmedKeys = Set(trim.map(\.id.rawValue))
                  plan.scopeInput.excludedURLKeys.formUnion(trimmedKeys)
                  plan.copyToDevice.removeAll { trimmedKeys.contains($0.id.rawValue) }
                  if let stillOver = SyncCapacity.shortfall(
                    plan: plan, availableCapacity: availableCapacity,
                    family: deviceFamily, settings: transcodeSettings)
                  {
                    fail(
                      String(
                        localized:
                          "Not syncing: still \(stillOver.byteText) over capacity after trimming."))
                  }
                  printCount(
                    trim.count,
                    singular: String(localized: "Trimmed 1 song to fit."),
                    plural: String(localized: "Trimmed \(trim.count) songs to fit."))
                }

                let updateCount = plan.updateOnDevice.count + plan.updateInFolder.count
                let localOnlyCount =
                  plan.unsupportedForDevice.count + plan.localOnlyInLibrary.count
                print(
                  String(
                    localized:
                      "To iPod: \(plan.copyToDevice.count), to library: \(plan.copyToFolder.count), updates: \(updateCount), removals: \(plan.removeFromDevice.count), local-only: \(localOnlyCount)"
                  ))
                for track in plan.unsupportedForDevice {
                  let reason: String
                  if case .unsupported(let message) = track.deviceDelivery(
                    for: deviceFamily, transcode: transcodeSettings)
                  {
                    reason = message
                  } else {
                    reason = String(localized: "Unsupported audio format.")
                  }
                  print(String(localized: "  - Not syncing \(track.displayTitle): \(reason)"))
                }
                return SyncWorkflow.PreparedExecution(
                  request: SyncExecutionRequest(plan),
                  expectedDatabaseID: db.databaseID,
                  transcoding: TranscodeContext(settings: transcodeSettings))
              },
              localEffects: localEffects,
              beforePlaybackMerge: {
                let environment = ProcessInfo.processInfo.environment
                if environment["NIGHTDRIVE_SIMULATE_CRASH_BEFORE_PLAYBACK_MERGE"] == "1" {
                  print(String(localized: "Simulated crash before playback merge."))
                  exit(0)
                }
              }
            ) { progress in
              print(
                String(
                  localized:
                    "  [\(progress.step)/\(progress.totalSteps)] \(progress.detail)"))
            }
            if let note = result.devicePlaybackNote { print(String(localized: "\(note).")) }
            print(
              String(
                localized:
                  "Copied \(result.copiedToDevice) to iPod, \(result.copiedToFolder) to library, updated \(result.updatedOnDevice) on iPod, \(result.updatedInFolder) in library, removed \(result.removedFromDevice) from iPod, \(result.failures.count) failures."
              ))
            print(String(localized: "Playlist changes: \(result.totalPlaylistChanges)"))
            if result.artworkImagesWritten > 0 {
              print(
                result.artworkImagesWritten == 1
                  ? String(localized: "Wrote album art for 1 track.")
                  : String(
                    localized:
                      "Wrote album art for \(result.artworkImagesWritten) tracks."))
            }
            for line in result.playlistActionSummaries { print(String(localized: "  ~ \(line)")) }
            for note in result.playlistNotes { print(String(localized: "  ~ \(note)")) }
            for note in result.playbackNotes { print(String(localized: "  ~ \(note)")) }
            for note in result.artworkNotes { print(String(localized: "  ~ \(note)")) }
            for note in result.scopeNotes { print(String(localized: "  ~ \(note)")) }
            for failure in result.failures {
              let description = failure.description
              print(String(localized: "  ! \(description)"))
            }
            exit(result.failures.isEmpty ? 0 : 1)
          } catch let error as SidecarIntegrityError
            where error.path == SyncLedgerStore.url(for: libraryDir).path
            && !shouldAssumeEmptyLedger
          {
            fail(
              String(
                localized:
                  "sync aborted: \(error.localizedDescription) Re-run with --assume-empty-ledger to preserve the current file and sync with empty link history."
              ))
          } catch {
            fail(String(localized: "sync failed: \(error.localizedDescription)"))
          }
        }
        dispatchMain()
      case "__test-clear-transcode-cache":
        guard args.count == 4 else {
          fail(
            String(localized: "usage: __test-clear-transcode-cache <cacheDir> <startedMarker>"))
        }
        do {
          try Data().write(to: URL(fileURLWithPath: args[3]))
        } catch {
          let errorDescription = String(describing: error)
          fail(String(localized: "could not write cache-clear test marker: \(errorDescription)"))
        }
        Task {
          do {
            try await TranscodeCache(directory: URL(fileURLWithPath: args[2])).clear()
            exit(0)
          } catch {
            fail(String(localized: "cache clear failed: \(error.localizedDescription)"))
          }
        }
        dispatchMain()
      case "__test-crash-artwork-media-install":
        guard args.count == 5 else {
          fail(
            String(
              localized:
                "usage: __test-crash-artwork-media-install <ipodVolume> <newCover> <newMedia>"))
        }
        do {
          let fs = IpodFileSystem(
            volumeURL: URL(fileURLWithPath: args[2], isDirectory: true))
          let database = try fs.readDatabase()
          guard database.tracks.count == 1,
            let track = database.tracks.first,
            let path = track.ipodPath,
            let artwork = track.artwork, artwork.hasArtwork,
            case .specs(let specs) = ArtworkFormats.resolve(fileSystem: fs),
            !specs.isEmpty
          else {
            fail(String(localized: "artwork crash fixture is incomplete"))
          }
          let live = try fs.validatedMusicFileURL(forIpodPath: path)
          _ = try ArtworkDBWriter.beginWrite(
            images: [
              ArtworkImage(
                dbid: track.dbid,
                data: try Data(contentsOf: URL(fileURLWithPath: args[3])))
            ],
            specs: specs, fileSystem: fs,
            mediaFileUpdates: [
              ArtworkMediaFileUpdate(
                liveURL: live, ipodPath: path,
                data: try Data(contentsOf: URL(fileURLWithPath: args[4])))
            ],
            imageIDsByDbid: [track.dbid: artwork.mhiiID],
            preinstallPreviousLinks: ArtworkDatabaseLink.links(in: database),
            afterPreviousMoved: { target in
              if target.standardizedFileURL == live.standardizedFileURL {
                Darwin._exit(86)
              }
            })
          fail(String(localized: "artwork crash checkpoint was not reached"))
        } catch {
          fail(String(localized: "artwork crash fixture failed: \(error.localizedDescription)"))
        }
    #endif
    case "reset-sidecar":
      let usage = String(
        localized: "usage: reset-sidecar <libraryDir> <playlists|history> [--confirm]")
      guard args.count >= 4 else { fail(usage) }
      let libraryDir = URL(fileURLWithPath: args[2], isDirectory: true)
      guard let sidecar = SidecarRecovery.Sidecar(rawValue: args[3]) else { fail(usage) }
      var confirmed = false
      for flag in args.dropFirst(4) {
        guard flag == "--confirm" else { fail(usage) }
        confirmed = true
      }
      do {
        if confirmed {
          let quarantine = try SidecarRecovery.reset(sidecar, libraryFolder: libraryDir)
          print(String(localized: "Reset \(sidecar.url(for: libraryDir).path)."))
          print(String(localized: "The damaged file was kept at \(quarantine.path)."))
          print(String(localized: "Nightdrive will start over with \(sidecar.lossDescription) empty."))
          exit(0)
        }
        let quarantine = try SidecarRecovery.preview(sidecar, libraryFolder: libraryDir)
        print(
          String(
            localized:
              "\(sidecar.url(for: libraryDir).path) is damaged and blocks library changes."))
        print(String(localized: "Resetting it permanently discards \(sidecar.lossDescription)."))
        print(
          String(localized: "The damaged file would be kept at \(quarantine.path) for manual repair."))
        print(String(localized: "Re-run with --confirm to reset it."))
        exit(1)
      } catch {
        fail(String(localized: "reset-sidecar refused: \(error.localizedDescription)"))
      }
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      case "dump":
        guard args.count == 3 else { fail(String(localized: "usage: dump <iTunesDB>")) }
        do {
          let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
          let db = try ITunesDBReader().read(data)
          let databaseID = String(db.databaseID, radix: 16)
          print(String(localized: "databaseID: \(databaseID)"))
          print(String(localized: "master playlist: \(db.masterPlaylistName)"))
          print(String(localized: "tracks: \(db.tracks.count)"))
          for t in db.tracks {
            let artist = t.artist ?? "?"
            let title = t.title ?? "?"
            let album = t.album ?? "?"
            let path = t.ipodPath ?? "?"
            print(
              String(
                localized:
                  "  [\(t.id)] \(artist) – \(title) (\(album)) \(t.lengthMS)ms @ \(path)"))
          }
          print(String(localized: "playlists: \(db.playlists.count)"))
          for p in db.playlists {
            print(String(localized: "  \(p.name): \(p.memberDbids.count) tracks"))
          }
          exit(0)
        } catch {
          let errorDescription = String(describing: error)
          fail(String(localized: "dump failed: \(errorDescription)"))
        }
      case "visualizers":
        var folder = VisualizerPluginFolder.default
        var previews: URL?
        var colorways: [VisualizerColorway] = [.default]
        var size = VisualizerSample.defaultPreviewSize
        var index = 2
        while index < args.count {
          switch args[index] {
          case "--dir" where index + 1 < args.count:
            folder = VisualizerPluginFolder(
              url: URL(fileURLWithPath: args[index + 1], isDirectory: true),
              requiresApproval: false)
          case "--render" where index + 1 < args.count:
            previews = URL(fileURLWithPath: args[index + 1], isDirectory: true)
          case "--colorway" where index + 1 < args.count:
            colorways =
              args[index + 1] == "all"
              ? VisualizerColorway.all : [VisualizerColorway.colorway(id: args[index + 1])]
          case "--size" where index + 1 < args.count:
            guard let parsed = parseVisualizerSize(args[index + 1]) else {
              fail(
                String(
                  localized:
                    "--size wants WIDTHxHEIGHT within the preview pixel budget, e.g. 320x44"))
            }
            size = parsed
          default:
            fail(
              String(
                localized:
                  "usage: visualizers [--dir <folder>] [--render <dir>] [--colorway <id|all>] [--size <WxH>]"))
          }
          index += 2
        }
        exit(
          MainActor.assumeIsolated {
            VisualizerReport.run(
              folder: folder, renderTo: previews, colorways: colorways, size: size)
          })
    #endif
    default:
      return  // Ignore Finder's -psn_ argument.
    }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
  }

  /// Prints the singular or plural message for a nonzero count. The messages are
  /// autoclosures so `String(localized:)` literals stay at the call site for key extraction.
  private static func printCount(
    _ count: Int, singular: @autoclosure () -> String, plural: @autoclosure () -> String
  ) {
    guard count > 0 else { return }
    print(count == 1 ? singular() : plural())
  }

  private static func printPlanCounts(_ plan: SyncPlan, trackSyncMode: TrackSyncMode) {
    printCount(
      plan.excludedByScope.count,
      singular: String(localized: "Scope excludes 1 library song from this iPod."),
      plural: String(
        localized: "Scope excludes \(plan.excludedByScope.count) library songs from this iPod."))
    printCount(
      plan.notInLibraryOnDevice.count,
      singular: String(
        localized:
          "1 song on the iPod is not in the library (kept; pass --confirm-removals to delete it)."),
      plural: String(
        localized:
          "\(plan.notInLibraryOnDevice.count) songs on the iPod are not in the library (kept; pass --confirm-removals to delete them)."
      ))
    if trackSyncMode == .libraryToIpod {
      printCount(
        plan.outOfScopeOnDevice.count,
        singular: String(
          localized:
            "1 song on the iPod is not in this sync (kept; pass --confirm-removals to delete it)."),
        plural: String(
          localized:
            "\(plan.outOfScopeOnDevice.count) songs on the iPod are not in this sync (kept; pass --confirm-removals to delete them)."
        ))
    } else {
      printCount(
        plan.outOfScopeOnDevice.count,
        singular: String(
          localized:
            "1 song on the iPod is not in this sync (kept; two-way sync never removes iPod songs)."),
        plural: String(
          localized:
            "\(plan.outOfScopeOnDevice.count) songs on the iPod are not in this sync (kept; two-way sync never removes iPod songs)."
        ))
    }
    printCount(
      plan.removeFromDeviceNotInLibrary.count,
      singular: String(localized: "Removing 1 song not in the library from the iPod."),
      plural: String(
        localized:
          "Removing \(plan.removeFromDeviceNotInLibrary.count) songs not in the library from the iPod."
      ))
    printCount(
      plan.removeFromDeviceOutsideScope.count,
      singular: String(localized: "Removing 1 song not in this sync from the iPod."),
      plural: String(
        localized:
          "Removing \(plan.removeFromDeviceOutsideScope.count) songs not in this sync from the iPod."
      ))
    printCount(
      plan.localOnlyInLibrary.count,
      singular: String(localized: "1 library-only song kept locally."),
      plural: String(
        localized: "\(plan.localOnlyInLibrary.count) library-only songs kept locally."))
  }

  #if NIGHTDRIVE_DEVELOPMENT_TOOLS
    static func unsafeSeedDemoTarget(libraryDir: URL, ipodDir: URL) -> URL? {
      [libraryDir, ipodDir].first { !DevelopmentSafety.isFakeSeedTarget($0) }
    }

    private static func parseScope(
      _ argument: String, playlists: [LocalPlaylist]
    ) -> SyncScope {
      if argument == "everything" { return .everything }
      guard argument.hasPrefix("playlists=") else {
        fail(
          String(
            localized:
              "--scope wants 'everything' or 'playlists=Name[,Name…]', got '\(argument)'"))
      }
      let names = argument.dropFirst("playlists=".count)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
      guard !names.isEmpty else {
        fail(String(localized: "--scope playlists= needs at least one playlist name"))
      }
      var ids: [UUID] = []
      for name in names {
        guard
          let playlist = playlists.first(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
          })
        else {
          let known = playlists.map(\.name).joined(separator: ", ")
          let knownDescription = known.isEmpty ? String(localized: "none") : known
          fail(String(localized: "no playlist named '\(name)' (have: \(knownDescription))"))
        }
        ids.append(playlist.id)
      }
      return .playlists(ids)
    }

    private static func parseTrackSyncMode(_ argument: String) -> TrackSyncMode {
      switch argument {
      case "two-way": .twoWay
      case "ipod-to-library": .ipodToLibrary
      case "library-to-ipod": .libraryToIpod
      default:
        fail(
          "--song-sync wants 'two-way', 'ipod-to-library', or 'library-to-ipod', got '\(argument)'")
      }
    }

    private static func cliAvailableCapacity(volume: URL) throws -> Int64 {
      if let fake = ProcessInfo.processInfo.environment["NIGHTDRIVE_FAKE_AVAILABLE_CAPACITY"],
        let bytes = Int64(fake)
      {
        return bytes
      }
      let values = try volume.resourceValues(forKeys: [.volumeAvailableCapacityKey])
      guard let capacity = values.volumeAvailableCapacity else {
        throw SyncError.deviceCapacityUnavailable(
          underlying: String(localized: "The volume did not report its available capacity."))
      }
      return Int64(capacity)
    }

    static func parseVisualizerSize(_ argument: String) -> CGSize? {
      let separators = argument.indices.filter { index in
        argument[index] == "x" || argument[index] == "X"
      }
      guard separators.count == 1, let separator = separators.first else { return nil }
      let widthText = argument[..<separator]
      let heightText = argument[argument.index(after: separator)...]
      guard !widthText.isEmpty, !heightText.isEmpty,
        let width = Double(widthText), let height = Double(heightText)
      else { return nil }
      let size = CGSize(width: width, height: height)
      return VisualizerReport.isSafePreviewSize(size) ? size : nil
    }
  #endif
}

enum DemoSeeder {
  struct Song {
    let title: String, artist: String, album: String, genre: String
    let track: Int, year: Int, seconds: Double
  }

  static let librarySongs: [Song] = [
    .init(
      title: "The District Sleeps Alone Tonight", artist: "The Postal Service",
      album: "Give Up", genre: "Electronic", track: 1, year: 2003, seconds: 32),
    .init(
      title: "Such Great Heights", artist: "The Postal Service",
      album: "Give Up", genre: "Electronic", track: 2, year: 2003, seconds: 30),
    .init(
      title: "Obstacle 1", artist: "Interpol",
      album: "Turn On the Bright Lights", genre: "Post-Punk", track: 3, year: 2002, seconds: 28),
    .init(
      title: "Float On", artist: "Modest Mouse",
      album: "Good News for People Who Love Bad News", genre: "Indie Rock",
      track: 3, year: 2004, seconds: 31),
    .init(
      title: "Take Me Out", artist: "Franz Ferdinand",
      album: "Franz Ferdinand", genre: "Indie Rock", track: 3, year: 2004, seconds: 29),
    .init(
      title: "Caring Is Creepy", artist: "The Shins",
      album: "Oh, Inverted World", genre: "Indie Pop", track: 1, year: 2001, seconds: 27),
    .init(
      title: "New Slang", artist: "The Shins",
      album: "Oh, Inverted World", genre: "Indie Pop", track: 4, year: 2001, seconds: 30),
    .init(
      title: "Naked as We Came", artist: "Iron & Wine",
      album: "Our Endless Numbered Days", genre: "Folk", track: 4, year: 2004, seconds: 26),
    .init(
      title: "The Sound of Settling", artist: "Death Cab for Cutie",
      album: "Transatlanticism", genre: "Indie Rock", track: 8, year: 2003, seconds: 25),
    .init(
      title: "Transatlanticism", artist: "Death Cab for Cutie",
      album: "Transatlanticism", genre: "Indie Rock", track: 11, year: 2003, seconds: 34),
    .init(
      title: "Banquet", artist: "Bloc Party",
      album: "Silent Alarm", genre: "Indie Rock", track: 2, year: 2005, seconds: 28),
    .init(
      title: "Rebellion (Lies)", artist: "Arcade Fire",
      album: "Funeral", genre: "Indie Rock", track: 9, year: 2004, seconds: 33),
    .init(
      title: "Wake Up", artist: "Arcade Fire",
      album: "Funeral", genre: "Indie Rock", track: 7, year: 2004, seconds: 31),
    .init(
      title: "Reptilia", artist: "The Strokes",
      album: "Room on Fire", genre: "Garage Rock", track: 2, year: 2003, seconds: 27),
    .init(
      title: "Maps", artist: "Yeah Yeah Yeahs",
      album: "Fever to Tell", genre: "Indie Rock", track: 9, year: 2003, seconds: 26),
    .init(
      title: "Chapter 1: Letter I", artist: "Mary Shelley",
      album: "Frankenstein", genre: "Audiobook", track: 1, year: 1818, seconds: 33),
    .init(
      title: "Chapter 2: Letter II", artist: "Mary Shelley",
      album: "Frankenstein", genre: "Audiobook", track: 2, year: 1818, seconds: 29),
    .init(
      title: "Chapter 3: Letter III", artist: "Mary Shelley",
      album: "Frankenstein", genre: "Audiobook", track: 3, year: 1818, seconds: 27),
  ]

  static let ipodOnlySongs: [Song] = [
    .init(
      title: "Heartbeats", artist: "The Knife",
      album: "Deep Cuts", genre: "Electronic", track: 2, year: 2003, seconds: 29),
    .init(
      title: "Slow Hands", artist: "Interpol",
      album: "Antics", genre: "Post-Punk", track: 3, year: 2004, seconds: 27),
    .init(
      title: "Portions for Foxes", artist: "Rilo Kiley",
      album: "More Adventurous", genre: "Indie Rock", track: 4, year: 2004, seconds: 28),
  ]

  /// Deterministic filler for the demo reel's fake iPod: ten synthetic
  /// albums of ten tracks each, so the device's track table is long enough
  /// that scrolling it on camera actually moves.
  static let demoIpodFillerSongs: [Song] = {
    let shows: [(artist: String, album: String, genre: String, year: Int)] = [
      ("Neon Meridian", "Glass Highways", "Electronic", 2001),
      ("The Sodium Lights", "Overpass Serenades", "Indie Rock", 2002),
      ("Casette Motel", "Vacancy in Stereo", "Indie Pop", 2003),
      ("Delco Wires", "Signal Fade", "Post-Punk", 2003),
      ("Marina & The Substations", "Voltage Coast", "Electronic", 2004),
      ("Fern Antenna", "Rooftop Reception", "Indie Folk", 2004),
      ("The Odometers", "Mile After Mile", "Indie Rock", 2005),
      ("Polaroid Weather", "Develop in Darkness", "Indie Pop", 2005),
      ("Static Bouquet", "Pressed Flowers", "Shoegaze", 2006),
      ("Late Exit", "Last Ramp Before Dawn", "Electronic", 2007),
    ]
    let first = [
      "Midnight", "Chrome", "Static", "Velvet", "Analog",
      "Electric", "Silver", "Fading", "Coastal", "Winter",
    ]
    let second = [
      "Signal", "Horizon", "Reverie", "Mileage", "Cassette",
      "Skyline", "Current", "Frequency", "Interlude", "Bloom",
    ]
    var songs: [Song] = []
    for (albumIndex, show) in shows.enumerated() {
      for trackIndex in 0..<10 {
        songs.append(
          Song(
            title: "\(first[trackIndex]) \(second[(albumIndex + trackIndex) % second.count])",
            artist: show.artist, album: show.album, genre: show.genre,
            track: trackIndex + 1, year: show.year,
            seconds: 22 + Double((albumIndex * 10 + trackIndex * 7) % 14)))
      }
    }
    return songs
  }()

  /// Extra one-song albums seeded only for the demo reel (`--rich`), so the
  /// albums grid overflows its viewport and has room to scroll on camera.
  static func seed(libraryDir: URL, ipodDir: URL, shuffle: Bool = false) throws {
    try seedLibrary(at: libraryDir)
    try seedIpod(
      at: ipodDir, model: shuffle ? "MA564" : "M9585",
      name: shuffle ? "DemoShuffle" : "My iPod",
      songs: ipodOnlySongs, playlists: !shuffle)
  }

  static func seedLibrary(at libraryDir: URL) throws {
    try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
    for song in librarySongs {
      let data = mp3(song)
      let name = SyncEngine.sanitize("\(song.artist) - \(song.title)") + ".mp3"
      try data.write(to: libraryDir.appendingPathComponent(name))
    }
  }

  /// A deliberately untidy library for exercising the duplicate finder and
  /// the organizer: exact byte-for-byte copies, re-rips and partial copies
  /// of the same song, alternate-album versions, and files scattered across
  /// junk folders.
  static func seedMessyLibrary(at libraryDir: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: libraryDir, withIntermediateDirectories: true)

    func write(_ data: Data, to relativePath: String) throws {
      let url = libraryDir.appendingPathComponent(relativePath)
      try fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }

    for (index, song) in librarySongs.enumerated() {
      let messyGenre =
        switch index % 4 {
        case 0:
          "WSUM 91.7 FM Madison;my top songs;rock and roll over;indie folk;Versus Verses"
        case 1: "Alternative; Indie Rock; favorites"
        default: song.genre
        }
      let taggedSong = Song(
        title: song.title, artist: song.artist, album: song.album,
        genre: messyGenre, track: song.track, year: song.year, seconds: song.seconds)
      let data = mp3(taggedSong)
      let name = SyncEngine.sanitize("\(song.artist) - \(song.title)") + ".mp3"
      // Scatter files across the kinds of folders real downloads end up in.
      let folder =
        switch index % 4 {
        case 0: ""
        case 1: "Downloads/"
        case 2: "New Folder/"
        default: "to sort/\(SyncEngine.sanitize(song.artist))/"
        }
      try write(data, to: folder + name)

      // A byte-for-byte copy of every fifth song.
      if index % 5 == 0 {
        try write(data, to: "Downloads/Copy of \(name)")
      }
      // A re-rip: same song, slightly different encode.
      if index % 5 == 2 {
        let rerip = mp3(
          Song(
            title: song.title, artist: song.artist, album: song.album,
            genre: taggedSong.genre, track: song.track, year: song.year,
            seconds: song.seconds + 1))
        try write(rerip, to: "old rips/\(name)")
      }
      // A suspicious shorter recording whose version suffix still shares
      // the original title stem.
      if index % 5 == 3 {
        let partial = mp3(
          Song(
            title: "\(song.title) (Partial)", artist: song.artist, album: song.album,
            genre: song.genre, track: song.track, year: song.year,
            seconds: max(10, song.seconds * 0.55)))
        try write(partial, to: "damaged downloads/\(name)")
      }
      // The same recording appearing again on a compilation.
      if index % 5 == 4 {
        let alternate = mp3(
          Song(
            title: song.title, artist: song.artist, album: "Indie Anthems",
            genre: taggedSong.genre, track: index + 1, year: 2006, seconds: song.seconds))
        try write(alternate, to: "Indie Anthems/\(name)")
      }
    }

    // One copied-tag mistake gives the metadata maintenance snapshot a
    // realistic, deterministic finding to review. Its audio length differs
    // from the neighboring track; only the embedded tags were copied.
    let neighbor = librarySongs[0]
    try write(
      mp3(
        Song(
          title: neighbor.title, artist: neighbor.artist, album: neighbor.album,
          genre: neighbor.genre, track: 16, year: neighbor.year,
          seconds: neighbor.seconds + 8)),
      to: "Compilation/14 - 4G.mp3")
    try write(
      mp3(
        Song(
          title: neighbor.title, artist: neighbor.artist, album: neighbor.album,
          genre: neighbor.genre, track: 16, year: neighbor.year,
          seconds: neighbor.seconds + 12)),
      to: "Compilation/15 - Satellite.mp3")
    try write(
      mp3(
        Song(
          title: neighbor.title, artist: neighbor.artist, album: neighbor.album,
          genre: neighbor.genre, track: 16, year: neighbor.year,
          seconds: neighbor.seconds)),
      to: "Compilation/16 - \(SyncEngine.sanitize(neighbor.title)).mp3")
  }

  static func seedIpod(
    at ipodDir: URL, model: String, name: String, songs: [Song], playlists: Bool
  ) throws {
    let fm = FileManager.default
    let fs = IpodFileSystem(volumeURL: ipodDir)
    try fm.createDirectory(
      at: ipodDir.appendingPathComponent("iPod_Control/Device"),
      withIntermediateDirectories: true)
    try fm.createDirectory(at: fs.itunesDir, withIntermediateDirectories: true)
    try "ModelNumStr: x\(model)\n".write(to: fs.sysInfoURL, atomically: true, encoding: .utf8)

    var db = ITunesDatabase()
    db.masterPlaylistName = name
    for song in songs {
      let data = mp3(song)
      let dest = try fs.destinationForNewFile(extension: "mp3")
      try data.write(to: dest)
      var libTrack = LibraryTrack(
        url: dest, title: song.title, artist: song.artist, album: song.album,
        genre: song.genre, composer: "", trackNumber: song.track, trackCount: 0,
        discNumber: 0, year: song.year, durationMS: Int(song.seconds * 1000),
        sizeBytes: data.count, bitrate: 128, samplerate: 44100,
        modificationDate: Date())
      libTrack.title = song.title
      db.tracks.append(SyncEngine.makeDBTrack(from: libTrack, ipodPath: fs.ipodPath(for: dest)))
    }
    if playlists && !db.tracks.isEmpty {
      var playlist = ITDBPlaylist(name: "On-The-Go 1", isMaster: false)
      playlist.memberDbids = db.tracks.map(\.dbid)
      db.playlists = [playlist]
    }
    try fs.writeDatabase(db)
  }

  private static func mp3(_ song: Song) -> Data {
    MP3Builder.build(
      tags: .init(
        title: song.title, artist: song.artist, album: song.album,
        genre: song.genre, trackNumber: song.track, year: song.year,
        artwork: coverArt(album: song.album)),
      seconds: song.seconds)
  }

  private static func coverArt(album: String) -> Data? {
    let side: CGFloat = 300
    let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
      var hash: UInt32 = 2_166_136_261
      for byte in album.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
      let hue = CGFloat(hash % 360) / 360
      let top = NSColor(hue: hue, saturation: 0.55, brightness: 0.80, alpha: 1)
      let bottom = NSColor(
        hue: (hue + 0.12).truncatingRemainder(dividingBy: 1),
        saturation: 0.70, brightness: 0.30, alpha: 1)
      NSGradient(starting: top, ending: bottom)?.draw(in: rect, angle: -60)
      NSColor.black.withAlphaComponent(0.35).setFill()
      NSBezierPath(
        ovalIn: NSRect(
          x: rect.width * 0.40, y: rect.height * -0.18,
          width: rect.width * 0.75, height: rect.width * 0.75)
      ).fill()
      let initials = album.split(separator: " ").prefix(2)
        .compactMap { $0.first.map(String.init) }.joined()
      NSString(string: initials).draw(
        at: NSPoint(x: 24, y: rect.height - 104),
        withAttributes: [
          .font: NSFont.boldSystemFont(ofSize: 72),
          .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ])
      return true
    }
    guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return png
  }
}
