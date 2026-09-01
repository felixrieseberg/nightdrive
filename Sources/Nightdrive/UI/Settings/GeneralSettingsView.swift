import SwiftUI

struct GeneralSettingsView: View {
  @Bindable var app: AppState
  @State private var defaultAudioAppFailure: DefaultAudioAppChangeFailure?

  private var hasFolder: Bool { app.library.folderURL != nil }

  var body: some View {
    SettingsPaneScroll {
      librarySection
      audioOutputSection
      fileAssociationsSection
      deckSection
      if app.updater.isAvailable {
        updatesSection
      }
    }
    .alert(item: $defaultAudioAppFailure) { failure in
      Alert(
        title: Text(failure.title),
        message: Text(failure.message),
        dismissButton: .default(Text("OK")))
    }
  }

  // MARK: - Audio output

  private var audioOutputSection: some View {
    let output = app.player.audioOutput
    return VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "Audio Output"))

      SettingsCard {
        HStack(spacing: 12) {
          Image(systemName: "speaker.wave.2.fill")
            .font(.system(size: 15))
            .foregroundStyle(output.isRouteAvailable ? Color.accentColor : Color.red)
            .frame(width: 20)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 1) {
            Text("Output device")
              .font(.system(size: 13, weight: .medium))
            Text(output.issue ?? String(localized: "Choose where Nightdrive sends audio."))
              .font(.caption)
              .foregroundStyle(output.issue == nil ? Color.secondary : Color.red)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Picker(
            "Output device",
            selection: Binding(
              get: { output.selectionID },
              set: { app.player.selectAudioOutput($0) })
          ) {
            Text(systemDefaultLabel)
              .tag(AudioOutputController.systemDefaultSelectionID)
            ForEach(output.devices) { device in
              Text(device.displayName).tag(device.uid)
            }
            if output.selectedDeviceIsMissing, let uid = output.selectedDeviceUID {
              Text("Previously selected device (unavailable)").tag(uid)
            }
          }
          .labelsHidden()
          .frame(width: 260)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
      }

      SettingsFootnote(
        String(
          localized:
            "Connected Bluetooth and AirPlay outputs appear here when macOS exposes them to Core Audio. Playback pauses if the active output disconnects."
        ))
    }
  }

  private var systemDefaultLabel: String {
    if let name = app.player.audioOutput.defaultDeviceName {
      return String(localized: "System Default — \(name)")
    }
    return String(localized: "System Default")
  }

  // MARK: - File associations

  private var fileAssociationsSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "File Associations"))

      SettingsCard {
        HStack(spacing: 12) {
          Image(systemName: defaultAppSymbol)
            .font(.system(size: 15))
            .foregroundStyle(defaultAppSymbolIsActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 20)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 1) {
            Text(defaultAppTitle)
              .font(.system(size: 13, weight: .medium))
            Text(defaultAppCaption)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if app.defaultAudioApp.isRequesting {
            ProgressView()
              .controlSize(.small)
          } else if app.defaultAudioApp.status != .all {
            Button("Make Default") {
              Task { defaultAudioAppFailure = await app.defaultAudioApp.makeDefault() }
            }
            .controlSize(.small)
            .disabled(app.defaultAudioApp.status == .unavailable)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
      }

      SettingsFootnote(
        String(localized: "macOS may ask you to confirm each audio format."))
    }
    .onAppear { app.defaultAudioApp.refresh() }
  }

  private var defaultAppTitle: String {
    switch app.defaultAudioApp.status {
    case .unavailable: String(localized: "Default app controls are unavailable")
    case .none: String(localized: "Nightdrive isn’t the default music player")
    case .some: String(localized: "Nightdrive opens some audio formats by default")
    case .all: String(localized: "Nightdrive is the default music player")
    }
  }

  private var defaultAppCaption: String {
    switch app.defaultAudioApp.status {
    case .unavailable:
      String(localized: "Install the Nightdrive app to manage file associations.")
    case .none:
      String(localized: "Use Nightdrive when you double-click supported audio files.")
    case .some:
      String(localized: "Make Nightdrive the default for every supported audio format.")
    case .all:
      String(localized: "Supported audio files open here when you double-click them.")
    }
  }

  private var defaultAppSymbol: String {
    app.defaultAudioApp.status == .all ? "checkmark.circle.fill" : "music.note"
  }

  private var defaultAppSymbolIsActive: Bool {
    app.defaultAudioApp.status == .all
  }

  // MARK: - Music library

  private var librarySection: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "Music Library"))

      SettingsCard {
        if hasFolder {
          folderRow
          SettingsCardDivider()
          statsRow
        } else {
          noFolderRow
        }
      }

      SettingsFootnote(
        String(
          localized:
            "Nightdrive scans this folder for common audio formats. Syncing copies compatible songs in both directions."
        ))
    }
  }

  private var folderRow: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: "folder.fill")
        .font(.system(size: 15))
        .foregroundStyle(.tint)
        .frame(width: 20)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 1) {
        Text(folderName)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(folderPath)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Music folder, \(folderName)")
      .accessibilityValue(folderPath)

      Button("Choose…") { app.chooseLibraryFolder() }
        .disabled(app.isDeviceOperationActive)
      Button("Show in Finder") { app.revealLibraryFolder() }
    }
    .controlSize(.small)
    .help(folderPath)
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var noFolderRow: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder.badge.questionmark")
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .frame(width: 20)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 1) {
        Text("No folder chosen yet")
          .font(.system(size: 13, weight: .medium))
        Text("Pick the folder your music lives in to get started.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button("Choose Folder…") { app.chooseLibraryFolder() }
        .controlSize(.small)
        .disabled(app.isDeviceOperationActive)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }

  private var statsRow: some View {
    HStack(alignment: .center, spacing: 0) {
      if let progress = app.library.scanProgress {
        HStack(spacing: 8) {
          if let fraction = progress.fractionCompleted {
            ProgressView(value: fraction)
              .progressViewStyle(.linear)
              .frame(width: 72)
          } else {
            ProgressView().controlSize(.small)
          }
          Text(progress.statusText)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else if app.library.scanState == .cancelled {
        Text("Scan canceled. Rescan before syncing or editing the library.")
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        let stats = app.library.totalStats
        stat(
          String(stats.count),
          label: stats.count == 1 ? String(localized: "song") : String(localized: "songs"))
        stat(durationText(stats.durationMS), label: String(localized: "playing time"))
        stat(sizeText(stats.sizeBytes), label: String(localized: "on disk"))
        Spacer(minLength: 8)
      }
      if app.library.isScanning {
        Button("Cancel") { app.library.cancelScan() }
          .controlSize(.small)
      } else {
        Button("Rescan") { Task { await app.library.rescan() } }
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private func stat(_ value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value)
        .font(.system(size: 13, weight: .medium))
        .monospacedDigit()
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(width: 108, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(verbatim: "\(value) \(label)"))
  }

  // MARK: - Deck

  private var deckSection: some View {
    @Bindable var deck = app.deck
    return VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "The Deck"))

      SettingsCard {
        SettingsSwitchRow(
          String(localized: "Open the deck at launch"),
          subtitle: String(
            localized: "Motors the fold-down display open as soon as Nightdrive starts."),
          isOn: $deck.opensOnLaunch)

        SettingsCardDivider()
        ceremonyField(
          String(localized: "Greeting"), text: $deck.greeting, prompt: DeckCeremony.defaultGreeting,
          caption: String(localized: "Played on the glass the first time the deck opens."))
      }

      SettingsFootnote(
        String(
          localized:
            "The deck folds down under the head unit and shows whichever mode is on the glass. Head units of the era greeted their owner at power-on; the glass writes the greeting in capitals, up to \(DeckCeremony.maxLength) characters, once per launch."
        ))
    }
  }

  // MARK: - Updates

  /// Only distribution builds can update themselves, so this whole section is
  /// absent from builds made from source.
  private var updatesSection: some View {
    VStack(alignment: .leading, spacing: 9) {
      SettingsHeading(String(localized: "Updates"))

      SettingsCard {
        SettingsSwitchRow(
          String(localized: "Check for updates automatically"),
          subtitle: String(
            localized: "Looks once a day and tells you when a new version is ready."),
          isOn: Binding(
            get: { app.updater.automaticallyChecksForUpdates },
            set: { app.updater.setAutomaticallyChecksForUpdates($0) }))

        SettingsCardDivider()

        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Check now")
              .font(.system(size: 13))
            Text("Looks for a new version right away, whatever the setting above says.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Button("Check Now") { app.updater.checkForUpdates() }
            .controlSize(.small)
            .disabled(!app.updater.canCheckForUpdates)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
      }

      SettingsFootnote(
        String(
          localized:
            "Updates are downloaded from the Nightdrive releases on GitHub and verified before they are installed."
        ))
    }
  }

  private func ceremonyField(
    _ title: String, text: Binding<String>, prompt: String, caption: String
  ) -> some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13))
        Text(caption)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      TextField(title, text: text, prompt: Text(prompt))
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .font(.system(size: 12, design: .monospaced))
        .multilineTextAlignment(.trailing)
        .frame(width: 170)
        .labelsHidden()
        .accessibilityLabel(String(localized: "Deck \(title.lowercased())"))
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  // MARK: - Text

  private var folderPath: String {
    app.library.folderURL?.path(percentEncoded: false) ?? String(localized: "No folder selected")
  }

  private var folderName: String {
    guard let url = app.library.folderURL else { return String(localized: "No folder selected") }
    return url.lastPathComponent.isEmpty ? folderPath : url.lastPathComponent
  }

  private func durationText(_ milliseconds: Int) -> String {
    let seconds = milliseconds / 1000
    if seconds >= 86400 {
      let days = (Double(seconds) / 86400).formatted(.number.precision(.fractionLength(1)))
      return String(localized: "\(days) days")
    }
    if seconds >= 3600 {
      let hours = (Double(seconds) / 3600).formatted(.number.precision(.fractionLength(1)))
      return String(localized: "\(hours) hours")
    }
    let minutes = (Double(seconds) / 60).formatted(.number.precision(.fractionLength(1)))
    return String(localized: "\(minutes) minutes")
  }

  private func sizeText(_ bytes: Int) -> String { bytes.byteText }
}
