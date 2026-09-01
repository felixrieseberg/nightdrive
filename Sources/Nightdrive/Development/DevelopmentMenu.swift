#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import SwiftUI

  struct DevelopmentCommands: View {
    let app: AppState

    private var fakeTargetDevice: IpodDevice? {
      DevelopmentSafety.fakeTargetDevice(
        selected: app.selectedDevice,
        devices: app.deviceManager.devices,
        developmentScanRoots: app.deviceManager.developmentScanRootURLs)
    }

    var body: some View {
      if let suffix = AppIdentity.developmentTitleSuffix {
        Text("Build: \(suffix)")
        Divider()
      }

      Menu("Devices") {
        Section("Mount a Fake iPod") {
          ForEach(DevelopmentDeviceModel.allCases) { model in
            Button(model.title) {
              Task { await DevelopmentDevices.mount(model, app: app) }
            }
          }
        }
        Divider()
        Button("Unmount Fakes and Clear Faked State") {
          Task { await DevelopmentDevices.unmountAll(app: app) }
        }
        .disabled(!app.deviceManager.hasDevelopmentState)
        Button("Delete All Fake iPods…") {
          Task { await DevelopmentDevices.deleteAll(app: app) }
        }
        Button("Reveal Fake iPods in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([DevelopmentDevices.root])
        }
        Divider()
        deviceStateItems
      }

      Menu("Sync") {
        Button("Reset Sync Ledger for This iPod…") {
          guard let device = fakeTargetDevice else { return }
          DevelopmentSyncTools.resetLedger(for: device, app: app)
        }
        .disabled(fakeTargetDevice == nil)
        Button("Corrupt Sync Ledger…") {
          guard let device = fakeTargetDevice else { return }
          Task { await DevelopmentSyncTools.corruptLedger(for: device, app: app) }
        }
        .disabled(fakeTargetDevice == nil || app.isDeviceOperationActive)
        Button("Show Sync Ledger…") {
          DevelopmentSyncTools.showLedger(app: app)
        }
        Divider()
        Toggle(
          isOn: Binding(
            get: { DevelopmentSyncPacing.isSlowed },
            set: { DevelopmentSyncPacing.isSlowed = $0 })
        ) {
          Text(verbatim: "Slow Sync (\(DevelopmentSyncPacing.stepDelay) per file)")
        }
        Divider()
        Button("Clear Transcode Cache") { app.clearTranscodeCache() }
      }

      Menu("Library") {
        Button("Seed and Use Demo Library…") {
          Task { await DevelopmentLibraryTools.seedDemoLibrary(app: app) }
        }
        Button("Seed and Use Messy Library…") {
          Task { await DevelopmentLibraryTools.seedMessyLibrary(app: app) }
        }
        Button("Drop Index Cache and Rescan") {
          Task { await DevelopmentLibraryTools.dropIndexCache(app: app) }
        }
        .disabled(app.library.folderURL == nil)
        Divider()
        Button("Reset Listening History…") {
          DevelopmentLibraryTools.resetListeningHistory(app: app)
        }
        Divider()
        Button("Reset Online Services Consent") {
          DevelopmentLibraryTools.resetOnlineConsent(app: app)
        }
        Button("Inject Sample MusicBrainz Suggestions") {
          DevelopmentLibraryTools.injectSampleSuggestions(app: app)
        }
      }

      Menu("Deck") {
        Button("Replay Opening Ceremony") {
          Task { await DevelopmentDeckTools.replayCeremony(app: app) }
        }
        Button("Reset Greeting for Next Open") {
          DevelopmentDeckTools.resetGreeting(app: app)
        }
        Section("Pin the Mechanism") {
          ForEach(DevelopmentDeckTools.poses, id: \.name) { pose in
            Button(pose.name) {
              DevelopmentDeckTools.pin(
                to: pose.progress, seated: pose.name == "Seated", app: app)
            }
          }
        }
      }

      Menu("Visualizers") {
        Button("Render Previews to Folder…") {
          DevelopmentCapture.renderVisualizerPreviews()
        }
        Divider()
        Button("Load Broken Plugin…") {
          Task { await DevelopmentDeckTools.loadBrokenPlugin(app: app) }
        }
        Button("Remove Broken Plugin") {
          Task { await DevelopmentDeckTools.removeBrokenPlugin(app: app) }
        }
        Divider()
        Button("Forget Plugin Approvals…") {
          DevelopmentDeckTools.resetApprovals(app: app)
        }
      }

      Menu("Capture") {
        Button("Resize Window for Screenshots (16:10)") {
          DevelopmentCapture.resizeMainWindowForScreenshots()
        }
        Button("Save Window Capture…") {
          DevelopmentCapture.saveScreenshot()
        }
        Divider()
        Button("Run Snapshot Tour…") {
          Task { await DevelopmentCapture.runSnapshotTour(app: app) }
        }
      }

      Menu("Demo") {
        DemoMenuItems(app: app)
      }
    }

    @ViewBuilder
    private var deviceStateItems: some View {
      if let device = fakeTargetDevice {
        Section("Fake State on \(app.displayName(for: device))") {
          Button("Fill to 95% Full") {
            Task { await DevelopmentDevices.fillToNearlyFull(device, app: app) }
          }
          Button("Fill Completely") {
            Task { await DevelopmentDevices.fillCompletely(device, app: app) }
          }
          Button("Restore Real Free Space") {
            Task { await DevelopmentDevices.restoreRealCapacity(device, app: app) }
          }
          Divider()
          Button("Simulate Write Failure") {
            Task { await DevelopmentDevices.simulateWriteFailure(device, app: app) }
          }
          Button("Clear Simulated Write Failure") {
            Task { await DevelopmentDevices.clearWriteFailure(device, app: app) }
          }
          Divider()
          Button("Corrupt Database…") {
            Task { await DevelopmentDevices.corruptDatabase(device, app: app) }
          }
        }
      } else {
        Button("Mount a Fake iPod to Fake Its State") {}
          .disabled(true)
      }
    }
  }
#endif
