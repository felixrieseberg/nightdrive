import SwiftUI

struct IPodSyncSettingsView: View {
  @Bindable var app: AppState

  private static let bitrateChoices = [128, 192, 256, 320]
  private static let ceilingChoicesGB: [Int64] = [1, 2, 4, 8, 16]

  var body: some View {
    SettingsPaneScroll(spacing: 9) {
      SettingsHeading(String(localized: "Audio Conversion"))

      SettingsCard {
        pickerRow(
          String(localized: "Convert to AAC at"),
          caption: String(
            localized: "Formats the iPod can't play, like FLAC, are converted on sync."),
          selection: $app.transcodeBitrateKbps,
          options: Self.bitrateChoices.map { ($0, String(localized: "\($0) kbps")) })

        SettingsCardDivider()
        pickerRow(
          String(localized: "Keep converted copies up to"),
          caption: String(localized: "Older conversions are removed first once the cache fills."),
          selection: Binding(
            get: { app.transcodeCacheCeilingBytes },
            set: { app.transcodeCacheCeilingBytes = $0 }),
          options: Self.ceilingChoicesGB.map {
            ($0 * 1_073_741_824, String(localized: "\($0) GB"))
          })

        SettingsCardDivider()
        cacheRow
      }

      SettingsFootnote(
        String(
          localized:
            "Converted copies are cached so a track is only encoded once; the originals in the music folder are never modified."
        ))
    }
    .onAppear { app.refreshTranscodeCacheSize() }
  }

  private func pickerRow<Value: Hashable>(
    _ title: String, caption: String, selection: Binding<Value>,
    options: [(Value, String)]
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
      Picker(title, selection: selection) {
        ForEach(options, id: \.0) { value, label in
          Text(label).tag(value)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .frame(width: 120, alignment: .trailing)
      .accessibilityLabel(title)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  private var cacheRow: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text("Converted audio cache")
          .font(.system(size: 13))
        Text(String(localized: "\(Int(app.transcodeCacheSizeBytes).byteText) in use"))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let error = app.transcodeCacheError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(
        app.isClearingTranscodeCache
          ? String(localized: "Clearing…") : String(localized: "Clear Cache")
      ) {
        app.clearTranscodeCache()
      }
      .controlSize(.small)
      .disabled(app.isClearingTranscodeCache)
      .frame(width: 120, alignment: .trailing)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}
