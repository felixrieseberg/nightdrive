import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrackFileInfo {
  var filename: String
  var location: String
  var durationMS: Int
  var sizeBytes: Int
  var bitrate: Int
  var sampleRate: Int

  init(_ track: LibraryTrack) {
    filename = track.url.lastPathComponent
    location = track.url.deletingLastPathComponent().path
    durationMS = track.durationMS
    sizeBytes = track.sizeBytes
    bitrate = track.bitrate
    sampleRate = track.samplerate
  }

  init(_ track: ITDBTrack, fileURL: URL?) {
    filename = fileURL?.lastPathComponent ?? (track.ipodPath as NSString?)?.lastPathComponent ?? ""
    location = fileURL?.deletingLastPathComponent().path ?? track.ipodPath ?? ""
    durationMS = Int(track.lengthMS)
    sizeBytes = Int(track.sizeBytes)
    bitrate = Int(track.bitrate)
    sampleRate = Int(track.samplerate)
  }
}

struct TrackInfoEditor: View {
  @Environment(\.dismiss) private var dismiss

  @State private var metadata: TrackMetadata
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var artwork: NSImage?
  @State private var artworkChange: ArtworkChange = .unchanged
  @State private var isLookupPresented = false

  let originalMetadata: TrackMetadata
  let fileInfo: TrackFileInfo
  let fileURL: URL
  let musicBrainzLookup: MusicBrainzLookupContext?
  let genreSuggestions: [String]
  let onSave: (TrackMetadata, ArtworkChange) async throws -> Void

  init(
    metadata: TrackMetadata,
    fileInfo: TrackFileInfo,
    fileURL: URL,
    musicBrainzLookup: MusicBrainzLookupContext? = nil,
    genreSuggestions: [String] = [],
    onSave: @escaping (TrackMetadata, ArtworkChange) async throws -> Void
  ) {
    _metadata = State(initialValue: metadata)
    originalMetadata = metadata
    self.fileInfo = fileInfo
    self.fileURL = fileURL
    self.musicBrainzLookup = musicBrainzLookup
    self.genreSuggestions = genreSuggestions
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Artwork") {
          HStack(spacing: 16) {
            Group {
              if let artwork {
                Image(nsImage: artwork)
                  .resizable()
                  .scaledToFit()
              } else {
                Image(systemName: "music.note")
                  .font(.system(size: 34))
                  .foregroundStyle(.tertiary)
              }
            }
            .frame(width: 100, height: 100)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 8) {
              Button("Choose Artwork…") { chooseArtwork() }
              Button("Remove Artwork", role: .destructive) {
                artwork = nil
                artworkChange = .remove
              }
              .disabled(artwork == nil)
            }
          }
        }

        Section("Details") {
          TextField("Title", text: $metadata.title)
          TextField("Artist", text: $metadata.artist)
          TextField("Album", text: $metadata.album)
          TextField("Album Artist", text: $metadata.albumArtist)
          TextField("Composer", text: $metadata.composer)
          LabeledContent("Genres") {
            GenreEditor(rawValue: $metadata.genre, suggestions: genreSuggestions)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .labeledContentStyle(LeadingGenreEditorStyle())
          TextField("Grouping", text: $metadata.grouping)
          TextField("Comment", text: $metadata.comment, axis: .vertical)
            .lineLimit(2...4)
        }
        if identityChanged {
          Section {
            Label(
              "Title and artist identify tracks during sync. A differently tagged copy on the other side may sync as a separate track.",
              systemImage: "exclamationmark.triangle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
          }
        }

        Section("Track") {
          LabeledContent("Year") {
            numberField(value: $metadata.year, width: 90)
          }
          LabeledContent("BPM") {
            numberField(value: $metadata.bpm, width: 90)
          }
          LabeledContent("Track") {
            HStack {
              numberField(value: $metadata.trackNumber)
              Text("of").foregroundStyle(.secondary)
              numberField(value: $metadata.trackCount)
            }
          }
          LabeledContent("Disc") {
            HStack {
              numberField(value: $metadata.discNumber)
              Text("of").foregroundStyle(.secondary)
              numberField(value: $metadata.discCount)
            }
          }
          Toggle("Part of a compilation", isOn: $metadata.compilation)
        }

        Section("Lyrics") {
          TextEditor(text: $metadata.lyrics)
            .font(.body)
            .frame(minHeight: 100)
        }

        Section("File") {
          LabeledContent("Name", value: fileInfo.filename)
          LabeledContent("Location") {
            Text(fileInfo.location)
              .lineLimit(1)
              .truncationMode(.middle)
              .textSelection(.enabled)
          }
          LabeledContent("Duration", value: LibraryTrack.formatDuration(ms: fileInfo.durationMS))
          LabeledContent("Size", value: fileInfo.sizeBytes.byteText)
          if fileInfo.bitrate > 0 {
            LabeledContent("Bit Rate", value: "\(fileInfo.bitrate) kbps")
          }
          if fileInfo.sampleRate > 0 {
            LabeledContent(
              "Sample Rate",
              value: String(format: "%.1f kHz", Double(fileInfo.sampleRate) / 1000))
          }
        }
      }
      .formStyle(.grouped)

      ErrorBanner(message: errorMessage)

      Divider()
      HStack {
        if musicBrainzLookup != nil {
          Button("Look Up on MusicBrainz…") { isLookupPresented = true }
            .help("Search MusicBrainz for this song and review the proposed tags")
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .buttonStyle(.lit)
          .keyboardShortcut(.defaultAction)
          .disabled(
            isSaving
              || metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if isSaving {
          ProgressView()
            .controlSize(.small)
        }
      }
      .padding(16)
    }
    .frame(width: 560, height: 650)
    .sheet(isPresented: $isLookupPresented) {
      if let musicBrainzLookup {
        MusicBrainzRecordingLookupSheet(
          context: musicBrainzLookup,
          current: metadata
        ) { proposed in
          metadata = proposed
        }
      }
    }
    .task {
      guard case .unchanged = artworkChange else { return }
      guard let data = await MetadataLoader.loadArtwork(url: fileURL) else { return }
      guard case .unchanged = artworkChange else { return }
      artwork = NSImage(data: data)
    }
  }

  private func numberField(value: Binding<Int>, width: CGFloat = 64) -> some View {
    TextField(String(), value: value, format: .number)
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: width)
  }

  private var identityChanged: Bool {
    func normalized(_ value: String) -> String {
      value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    return normalized(metadata.title) != normalized(originalMetadata.title)
      || normalized(metadata.artist) != normalized(originalMetadata.artist)
  }

  private func save() {
    runSheetSave(isSaving: $isSaving, errorMessage: $errorMessage, dismiss: dismiss) {
      try await onSave(metadata.normalized, artworkChange)
    }
  }

  private func chooseArtwork() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.png, .jpeg]
    panel.prompt = "Choose"
    panel.message = "Choose JPEG or PNG artwork for this track."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      guard let image = NSImage(data: data) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      artwork = image
      artworkChange = .replace(data)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct LeadingGenreEditorStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .top, spacing: 12) {
      configuration.label
        .frame(width: 105, alignment: .leading)
      configuration.content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}
