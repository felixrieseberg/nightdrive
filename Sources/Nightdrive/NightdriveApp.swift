import AppKit
import SwiftUI

@MainActor
final class NightdriveApplicationDelegate: NSObject, NSApplicationDelegate {
  private(set) static weak var current: NightdriveApplicationDelegate?

  var flushPlaybackState: (@MainActor () async -> Void)?
  var togglePlayback: (@MainActor () -> Void)? {
    didSet { installPlaybackShortcutMonitorIfNeeded() }
  }
  var playbackShortcutIsEnabled: (@MainActor () -> Bool)?
  var openAudioFiles: (@MainActor ([URL]) -> Void)? {
    didSet { deliverPendingOpenRequests() }
  }
  var openNightdriveURL: (@MainActor (URL) -> Bool)? {
    didSet { deliverPendingNightdriveURLs() }
  }
  var dockMenuModel: (@MainActor () -> DockPlaybackMenuModel?)?
  var performDockMenuAction: (@MainActor (DockMenuAction) -> Void)?
  private var terminationTask: Task<Void, Never>?
  private var playbackStateWasFlushedForTermination = false
  private var pendingOpenRequests: [[URL]] = []
  private var pendingNightdriveURLs: [URL] = []
  private var playbackShortcutMonitor: Any?
  private var systemSleepWakeController: SystemSleepWakeController?
  private let replyToTerminationRequest: @MainActor (NSApplication, Bool) -> Void

  override convenience init() {
    self.init { application, shouldTerminate in
      application.reply(toApplicationShouldTerminate: shouldTerminate)
    }
  }

  init(
    replyToTerminationRequest: @escaping @MainActor (NSApplication, Bool) -> Void
  ) {
    self.replyToTerminationRequest = replyToTerminationRequest
    super.init()
    Self.current = self
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    systemSleepWakeController?.invalidate()
    if playbackStateWasFlushedForTermination {
      playbackStateWasFlushedForTermination = false
      return .terminateNow
    }
    guard let flushPlaybackState else { return .terminateNow }
    guard terminationTask == nil else { return .terminateLater }

    let replyToTerminationRequest = replyToTerminationRequest
    terminationTask = Task { @MainActor [weak self, weak sender] in
      await flushPlaybackState()
      guard let sender else { return }
      replyToTerminationRequest(sender, true)
      self?.terminationTask = nil
    }
    return .terminateLater
  }

  func application(_ sender: NSApplication, open urls: [URL]) {
    guard !urls.isEmpty else { return }
    var audioURLs: [URL] = []
    for url in urls {
      if url.scheme?.lowercased() == NightdriveDeepLink.scheme {
        if let openNightdriveURL {
          _ = openNightdriveURL(url)
        } else {
          pendingNightdriveURLs.append(url)
        }
      } else {
        audioURLs.append(url)
      }
    }
    guard !audioURLs.isEmpty else { return }
    if let openAudioFiles {
      openAudioFiles(audioURLs)
    } else {
      pendingOpenRequests.append(audioURLs)
    }
  }

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let model = dockMenuModel?() else { return nil }
    let menu = NSMenu()
    menu.autoenablesItems = false
    let context = NSMenuItem(title: model.contextTitle, action: nil, keyEquivalent: "")
    context.isEnabled = false
    menu.addItem(context)
    menu.addItem(.separator())
    addDockItem(.togglePlayback, model: model, to: menu)
    addDockItem(.previous, model: model, to: menu)
    addDockItem(.next, model: model, to: menu)
    menu.addItem(.separator())
    addDockItem(.showNightdrive, model: model, to: menu)
    addDockItem(.showUpNext, model: model, to: menu)
    return menu
  }

  func applicationWillTerminate(_ notification: Notification) {
    systemSleepWakeController?.invalidate()
    systemSleepWakeController = nil
    if let playbackShortcutMonitor {
      NSEvent.removeMonitor(playbackShortcutMonitor)
      self.playbackShortcutMonitor = nil
    }
  }

  private func installPlaybackShortcutMonitorIfNeeded() {
    guard playbackShortcutMonitor == nil, togglePlayback != nil else { return }
    playbackShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, self.playbackShortcutIsEnabled?() == true else { return event }
      switch PlaybackKeyboardShortcut.disposition(
        keyCode: event.keyCode,
        modifierFlags: event.modifierFlags,
        isARepeat: event.isARepeat,
        firstResponder: event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder)
      {
      case .passThrough:
        return event
      case .perform:
        self.togglePlayback?()
        return nil
      case .consume:
        return nil
      }
    }
  }

  private func addDockItem(
    _ action: DockMenuAction, model: DockPlaybackMenuModel, to menu: NSMenu
  ) {
    let item = NSMenuItem(
      title: model.title(for: action), action: #selector(runDockMenuAction(_:)),
      keyEquivalent: "")
    item.target = self
    item.representedObject = action.rawValue
    item.isEnabled = model.isEnabled(action)
    menu.addItem(item)
  }

  @objc private func runDockMenuAction(_ sender: NSMenuItem) {
    guard let rawValue = sender.representedObject as? String,
      let action = DockMenuAction(rawValue: rawValue),
      let model = dockMenuModel?(), model.isEnabled(action)
    else { return }
    performDockMenuAction?(action)
  }

  func installSystemSleepWakeHandling(
    prepareForSleep: @escaping @MainActor () -> Bool,
    resumeAfterWake: @escaping @MainActor (Bool) -> Void
  ) {
    guard systemSleepWakeController == nil else { return }
    systemSleepWakeController = SystemSleepWakeController(
      operations: SystemSleepWakeOperations(
        prepareForSleep: prepareForSleep,
        flush: { [weak self] in await self?.flushPlaybackState?() },
        resumeAfterWake: resumeAfterWake))
  }

  private func deliverPendingOpenRequests() {
    guard let openAudioFiles, !pendingOpenRequests.isEmpty else { return }
    let requests = pendingOpenRequests
    pendingOpenRequests.removeAll()
    for urls in requests { openAudioFiles(urls) }
  }

  private func deliverPendingNightdriveURLs() {
    guard let openNightdriveURL, !pendingNightdriveURLs.isEmpty else { return }
    let urls = pendingNightdriveURLs
    pendingNightdriveURLs.removeAll()
    for url in urls { _ = openNightdriveURL(url) }
  }

  /// Scripted runs already occupy the main actor. Flush before entering
  /// AppKit's synchronous termination path so its nested event loop does not
  /// have to wait for another main-actor task.
  func terminateAfterFlushing(_ application: NSApplication) async {
    systemSleepWakeController?.invalidate()
    if let flushPlaybackState {
      await flushPlaybackState()
    }
    playbackStateWasFlushedForTermination = true
    application.terminate(nil)
  }
}

@MainActor
func terminateApplicationAfterFlushing() async {
  guard let delegate = NightdriveApplicationDelegate.current else {
    NSApp.terminate(nil)
    return
  }
  await delegate.terminateAfterFlushing(NSApp)
}

@main
enum Main {
  @MainActor
  static func main() {
    CLI.runIfRequested()
    NightdriveLaunchMode.prepare()
    DarkAppearance.install()
    NightdriveApp.main()
  }
}

@MainActor
enum NightdriveLaunchMode {
  static func prepare(environment: [String: String] = ProcessInfo.processInfo.environment) {
    guard activationPolicy(environment: environment) == .accessory else { return }
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  nonisolated static func activationPolicy(environment: [String: String])
    -> NSApplication.ActivationPolicy?
  {
    environment["NIGHTDRIVE_SNAPSHOT_DIR"] == nil ? nil : .accessory
  }
}

struct NightdriveApp: App {
  @NSApplicationDelegateAdaptor(NightdriveApplicationDelegate.self)
  private var applicationDelegate
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @State private var appState: AppState

  @MainActor
  init() {
    _appState = State(initialValue: AppState())
  }

  var body: some Scene {
    Window(AppIdentity.appTitle, id: "main") {
      WindowActivity {
        ContentView(app: appState)
          .focusedSceneValue(appState)
          .task {
            applicationDelegate.flushPlaybackState = { [weak appState] in
              await appState?.flushPlaybackState()
            }
            applicationDelegate.installSystemSleepWakeHandling(
              prepareForSleep: { [weak appState] in
                appState?.player.prepareForSystemSleep() ?? false
              },
              resumeAfterWake: { [weak appState] playbackWasActive in
                appState?.player.resumeAfterSystemWake(if: playbackWasActive)
              })
            applicationDelegate.playbackShortcutIsEnabled = { [weak appState] in
              guard let appState else { return false }
              return !appState.searchFieldFocused && !appState.isQuickSearchPresented
            }
            applicationDelegate.togglePlayback = { [weak appState] in
              appState?.player.togglePlayPause()
            }
            applicationDelegate.dockMenuModel = { [weak appState] in
              appState.map { DockPlaybackMenuModel(player: $0.player) }
            }
            applicationDelegate.performDockMenuAction = { [weak appState] action in
              guard let appState else { return }
              switch action {
              case .togglePlayback: appState.player.togglePlayPause()
              case .previous: appState.player.previous()
              case .next: appState.player.next()
              case .showNightdrive: appState.showMainWindow()
              case .showUpNext: appState.openSidebarItem(.upNext)
              }
            }
            appState.openMainWindow = { openWindow(id: "main") }
            applicationDelegate.openNightdriveURL = { appState.openNightdriveURL($0) }
            applicationDelegate.openAudioFiles = { urls in
              Task { await appState.openAudioFiles(urls) }
            }
            Task { @MainActor [weak appState] in
              do {
                try await Task.sleep(for: .seconds(2))
              } catch {
                return
              }
              await appState?.preloadPodcastEpisodes()
            }
            DebugSnapshot.armIfRequested(app: appState)
            var scriptOwnsScreen = DebugSnapshot.isDrivingTour
            #if NIGHTDRIVE_DEVELOPMENT_TOOLS
              DemoAutoRun.armIfRequested(app: appState)
              scriptOwnsScreen = scriptOwnsScreen || DemoAutoRun.isArmed
            #endif
            if appState.deck.opensOnLaunch && !scriptOwnsScreen {
              appState.deck.open()
              await appState.deck.waitToSettle()
            }
            if appState.library.folderURL != nil {
              await appState.library.rescan()
            }
            appState.updateSearchIntegrations()
            appState.startPlaybackIntegrations()
            if !scriptOwnsScreen {
              appState.defaultAudioApp.offerAtLaunchIfNeeded()
            }
            #if NIGHTDRIVE_PERFORMANCE_BENCHMARK
              PerformanceBenchmark.startIfRequested(app: appState)
            #endif
          }
          .onChange(of: appState.library.tracks) {
            appState.libraryContentsDidChange()
            appState.updateSearchIntegrations()
          }
          .onChange(of: appState.playlists.revision) {
            appState.updateSearchIntegrations()
          }
          .onChange(of: scenePhase) {
            if scenePhase == .active {
              appState.defaultAudioApp.refresh()
              appState.recentAudioDocuments.refresh()
            } else {
              Task { await appState.flushPlaybackState() }
            }
          }
      }
    }
    .defaultSize(width: 1150, height: 720)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .appInfo) {
        Button("About \(AppIdentity.appTitle)") {
          AboutWindowPresenter.show()
        }
      }
      CommandGroup(after: .appInfo) {
        CheckForUpdatesButton(updater: appState.updater)
      }
      CommandGroup(after: .help) {
        Button("Controls") {
          ControlsWindowPresenter.show()
        }
        Button("Nightdrive on GitHub") {
          NSWorkspace.shared.open(AppLinks.repository)
        }
      }
      CommandGroup(replacing: .newItem) {
        Button("Open Audio Files…") { appState.chooseAudioFilesToOpen() }
          .keyboardShortcut(AppShortcuts.openAudioFiles)
        Menu("Open Recent") {
          if appState.recentAudioDocuments.urls.isEmpty {
            Button("No Recent Audio") {}
              .disabled(true)
          } else {
            ForEach(appState.recentAudioDocuments.urls, id: \.self) { url in
              Button(url.lastPathComponent) {
                guard let url = appState.recentAudioDocuments.urlForOpening(url) else { return }
                Task { await appState.openAudioFiles([url]) }
              }
              .help(url.path)
            }
          }
          Divider()
          Button("Clear Menu") { appState.recentAudioDocuments.clear() }
            .disabled(!appState.recentAudioDocuments.canClear)
        }
        Button("Choose Library Folder…") { appState.chooseLibraryFolder() }
          .keyboardShortcut(AppShortcuts.chooseLibraryFolder)
          .disabled(appState.isDeviceOperationActive)
        Button("Rescan Library") {
          Task { await appState.library.rescan() }
        }
        .keyboardShortcut(AppShortcuts.rescanLibrary)
        .disabled(appState.library.folderURL == nil)
        Divider()
        Button("Find Duplicates…") {
          appState.openMainWindow?()
          appState.isFindDuplicatesPresented = true
        }
        .disabled(!appState.library.isSettled || appState.libraryMutationsDisabled)
        Button("Clean Up Genres…") {
          appState.openMainWindow?()
          appState.isCleanUpGenresPresented = true
        }
        .disabled(!appState.library.isSettled || appState.libraryMutationsDisabled)
        Button("Find Metadata Problems…") {
          appState.openMainWindow?()
          appState.isFindMetadataProblemsPresented = true
        }
        .disabled(!appState.library.isSettled || appState.libraryMutationsDisabled)
        Button("Organize Library Files…") {
          appState.openMainWindow?()
          appState.isOrganizeLibraryPresented = true
        }
        .disabled(!appState.library.isSettled || appState.libraryMutationsDisabled)
      }
      CommandGroup(after: .pasteboard) {
        Button("Find") { appState.searchFocusRequest += 1 }
          .keyboardShortcut(AppShortcuts.find)
        Button("Command Palette…") {
          appState.openMainWindow?()
          appState.toggleQuickSearch()
        }
        .keyboardShortcut(AppShortcuts.commandPalette)
        EditInfoCommand(app: appState)
      }
      CommandGroup(after: .sidebar) {
        SidebarCommands(app: appState)
      }
      CommandMenu("Controls") {
        Button(
          appState.player.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        ) {
          appState.player.togglePlayPause()
        }
        .keyboardShortcut(AppShortcuts.playPause)
        .disabled(appState.searchFieldFocused || appState.isQuickSearchPresented)
        Button("Next") { appState.player.next() }
          .keyboardShortcut(AppShortcuts.nextTrack)
        Button("Previous") { appState.player.previous() }
          .keyboardShortcut(AppShortcuts.previousTrack)
        Divider()
        Picker(
          "Playback Speed",
          selection: Binding(
            get: { appState.player.playbackRate },
            set: { appState.player.setPlaybackRate($0) })
        ) {
          ForEach(PlayerController.supportedPlaybackRates, id: \.self) { rate in
            Text(
              verbatim: rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
            )
            .tag(rate)
          }
        }
        .disabled(appState.player.currentTrack == nil)
        Divider()
        Button(appState.player.isMuted ? String(localized: "Unmute") : String(localized: "Mute")) {
          appState.player.toggleMute()
        }
        .keyboardShortcut(AppShortcuts.toggleMute)
        Menu("Equalizer") {
          ForEach(EqualizerPreset.allCases) { preset in
            Button {
              appState.player.equalizerPreset = preset
            } label: {
              if appState.player.equalizerPreset == preset {
                Label(preset.label, systemImage: "checkmark")
              } else {
                Text(preset.label)
              }
            }
          }
          Divider()
          Button("Next Equalizer Preset") {
            appState.player.cycleEqualizerPreset()
          }
          .keyboardShortcut(AppShortcuts.nextEqualizerPreset)
        }
        Divider()
        Button(
          appState.deck.isExpanded
            ? String(localized: "Close Deck Display") : String(localized: "Open Deck Display")
        ) {
          appState.deck.toggle()
        }
        .keyboardShortcut(AppShortcuts.toggleDeck)
        Button(
          appState.deck.isDetached
            ? String(localized: "Reattach Faceplate") : String(localized: "Detach Faceplate")
        ) {
          appState.deck.isDetached ? appState.deck.attach() : appState.deck.detach()
        }
        .keyboardShortcut(AppShortcuts.toggleFaceplate)
        Menu("Visualizer") {
          VisualizerMenuItems(app: appState, includeShortcuts: true)
        }
        Divider()
        Button(
          appState.player.isShuffleEnabled
            ? String(localized: "Turn Shuffle Off") : String(localized: "Turn Shuffle On")
        ) {
          appState.player.toggleShuffle()
        }
        Button(appState.player.repeatMode.label) {
          appState.player.cycleRepeatMode()
        }
        Button("Show Up Next") {
          appState.selection = .upNext
        }
        Divider()
        Button("Sync iPod") {
          if let device = appState.selectedDevice ?? appState.deviceManager.devices.first {
            appState.sync(device)
          }
        }
        .keyboardShortcut(AppShortcuts.syncIpod)
        .disabled(appState.deviceManager.devices.isEmpty || appState.isDeviceOperationActive)
      }
      #if NIGHTDRIVE_DEVELOPMENT_TOOLS
        if AppIdentity.isDevelopmentBuild {
          CommandMenu(Text(verbatim: "Develop")) {
            DevelopmentCommands(app: appState)
          }
        }
      #endif
    }

    Settings {
      WindowActivity {
        SettingsView(app: appState)
      }
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(after: .pasteboard) {
        EditInfoCommand(app: appState)
      }
    }
  }
}

private struct EditInfoCommand: View {
  @Bindable var app: AppState
  @FocusedValue(\.trackCommands) private var trackCommands

  private var selectedTracks: [LibraryTrack] {
    app.library.catalog.tracksInLibraryOrder(for: app.selectedTrackIDs)
  }

  private var canEditSelectedTracks: Bool {
    !app.libraryMutationsDisabled
      && !selectedTracks.isEmpty
      && selectedTracks.count == app.selectedTrackIDs.count
      && selectedTracks.allSatisfy(\.supportsMetadataEditing)
  }

  private var canRunCommand: Bool {
    guard trackCommands?.editInfo != nil else { return canEditSelectedTracks }
    return trackCommands?.canEditInfo == true
  }

  private var title: String {
    let count =
      trackCommands?.editInfo == nil
      ? selectedTracks.count : trackCommands?.selectionCount ?? 0
    return editInfoTitle(for: count)
  }

  var body: some View {
    Button(title) {
      if let editInfo = trackCommands?.editInfo {
        editInfo()
      } else {
        app.requestEditInfo()
      }
    }
    .keyboardShortcut(AppShortcuts.editInfo)
    .disabled(!canRunCommand)
  }
}

private struct SidebarCommands: View {
  @Bindable var app: AppState
  @FocusedValue(AppState.self) private var focusedApp

  var body: some View {
    ForEach(SidebarItem.commandOrder, id: \.self) { item in
      Button(item.menuTitle) { app.openSidebarItem(item) }
        .keyboardShortcut(shortcut(for: item))
    }

    Divider()
    Button(SidebarItem.playlists.menuTitle) { app.openSidebarItem(.playlists) }
      .keyboardShortcut(shortcut(for: .playlists))

    if !app.deviceManager.devices.isEmpty {
      Divider()
      ForEach(Array(app.deviceManager.devices.enumerated()), id: \.element.id) { index, device in
        Button(app.displayName(for: device)) {
          app.openSidebarItem(.device(device.volumeURL))
        }
        .keyboardShortcut(focusedApp === app ? Self.deviceShortcut(at: index) : nil)
      }
    }
  }

  private func shortcut(for item: SidebarItem) -> KeyboardShortcut? {
    guard focusedApp === app, let digit = item.commandShortcutDigit else { return nil }
    return KeyboardShortcut(KeyEquivalent(digit))
  }

  private static let deviceShortcutKeys = Array("0123456789abcdefghijklmnopqrstuvwxyz")
  private static let deviceShortcutModifierSets: [EventModifiers] = [
    [.command],
    [.command, .shift],
    [.command, .option],
    [.command, .control],
    [.command, .option, .shift],
    [.command, .control, .shift],
    [.command, .control, .option],
  ]

  /// Keep the first device in the remaining Command-number slot, then add
  /// modifiers for the unlikely case where many iPods are connected.
  private static func deviceShortcut(at index: Int) -> KeyboardShortcut {
    if index < 1 {
      return KeyboardShortcut(KeyEquivalent(deviceShortcutKeys[index]))
    }
    let offset = index - 1
    let modifierIndex =
      1 + (offset / deviceShortcutKeys.count) % (deviceShortcutModifierSets.count - 1)
    let modifiers = deviceShortcutModifierSets[modifierIndex]
    return KeyboardShortcut(
      KeyEquivalent(deviceShortcutKeys[offset % deviceShortcutKeys.count]), modifiers: modifiers)
  }
}
