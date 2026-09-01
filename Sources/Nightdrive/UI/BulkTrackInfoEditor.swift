import SwiftUI

struct BulkTrackInfoEditor: View {
  private enum GenreEditMode: String, CaseIterable, Identifiable {
    case replace = "Replace"
    case add = "Add"
    case remove = "Remove"
    case makePrimary = "Make Primary"

    var id: Self { self }
  }

  @Environment(\.dismiss) private var dismiss

  @State private var draft: TrackMetadata
  @State private var included: Set<MetadataField> = []
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var genreEditMode = GenreEditMode.replace
  @State private var genreOperand = ""
  @State private var genreReplacementTouched = false

  let trackCount: Int
  let mixedFields: Set<MetadataField>
  let genreSuggestions: [String]
  let onSave: (TrackMetadataChanges) async throws -> Void

  init(
    metadata: [TrackMetadata],
    genreSuggestions: [String] = [],
    onSave: @escaping (TrackMetadataChanges) async throws -> Void
  ) {
    precondition(!metadata.isEmpty)
    let values = Self.commonValues(in: metadata)
    _draft = State(initialValue: values.metadata)
    trackCount = metadata.count
    mixedFields = values.mixed
    self.genreSuggestions = genreSuggestions
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          Text(
            "Select the checkbox beside each field you want to change. Unselected fields stay exactly as they are."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
        }

        Section("Details") {
          textField("Title", .title, text: $draft.title)
          textField("Artist", .artist, text: $draft.artist)
          textField("Album", .album, text: $draft.album)
          textField("Album Artist", .albumArtist, text: $draft.albumArtist)
          textField("Composer", .composer, text: $draft.composer)
          fieldRow("Genres", .genre, alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
              Picker("Genre change", selection: $genreEditMode) {
                ForEach(GenreEditMode.allCases) { mode in
                  Text(mode.rawValue).tag(mode)
                }
              }
              .labelsHidden()
              .pickerStyle(.segmented)

              if genreEditMode == .replace {
                if mixedFields.contains(.genre), !genreReplacementTouched {
                  HStack {
                    Text("Multiple Values")
                      .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose Replacement…") {
                      genreReplacementTouched = true
                    }
                  }
                } else {
                  GenreEditor(
                    rawValue: genreReplacementBinding, suggestions: genreSuggestions)
                }
              } else {
                GenreAutocompleteField(
                  "Genre", text: $genreOperand, candidates: genreSuggestions
                )
                .labelsHidden()
              }
            }
            .disabled(!included.contains(.genre))
          }
          textField("Grouping", .grouping, text: $draft.grouping)
          textField("Comment", .comment, text: $draft.comment)
        }

        Section("Track") {
          numberField("Year", .year, value: $draft.year)
          numberField("BPM", .bpm, value: $draft.bpm)
          numberField("Track Number", .trackNumber, value: $draft.trackNumber)
          numberField("Track Count", .trackCount, value: $draft.trackCount)
          numberField("Disc Number", .discNumber, value: $draft.discNumber)
          numberField("Disc Count", .discCount, value: $draft.discCount)
          fieldRow("Compilation", .compilation) {
            Picker("Compilation", selection: $draft.compilation) {
              Text("No").tag(false)
              Text("Yes").tag(true)
            }
            .labelsHidden()
            .frame(width: 100)
          }
        }

        Section("Lyrics") {
          fieldRow("Lyrics", .lyrics, alignment: .top) {
            TextEditor(text: $draft.lyrics)
              .frame(minHeight: 80)
          }
        }
      }
      .formStyle(.grouped)

      ErrorBanner(message: errorMessage)

      Divider()
      HStack {
        Text(
          trackCount == 1
            ? String(localized: "1 song selected")
            : String(localized: "\(trackCount) songs selected")
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save Changes") { save() }
          .buttonStyle(.lit)
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || changes.isEmpty)
        if isSaving {
          ProgressView().controlSize(.small)
        }
      }
      .padding(16)
    }
    .frame(width: 600, height: 680)
  }

  private func textField(
    _ label: String, _ field: MetadataField, text: Binding<String>
  ) -> some View {
    fieldRow(label, field) {
      TextField(label, text: text, prompt: mixedFields.contains(field) ? Text("Multiple Values") : nil)
        .labelsHidden()
    }
  }

  private func numberField(
    _ label: String, _ field: MetadataField, value: Binding<Int>
  ) -> some View {
    fieldRow(label, field) {
      TextField(
        label,
        value: value,
        format: .number,
        prompt: mixedFields.contains(field) ? Text("Multiple Values") : nil
      )
      .labelsHidden()
      .multilineTextAlignment(.trailing)
      .frame(width: 110)
    }
  }

  private func fieldRow<Control: View>(
    _ label: String,
    _ field: MetadataField,
    alignment: VerticalAlignment = .center,
    @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(alignment: alignment) {
      Toggle("Change \(label)", isOn: $included.contains(field))
        .labelsHidden()
        .toggleStyle(.checkbox)
        .help("Include \(label) in this bulk edit")
      Text(label)
        .frame(width: 105, alignment: .leading)
      control()
        .disabled(!included.contains(field))
    }
  }

  private func save() {
    let changes = changes
    runSheetSave(isSaving: $isSaving, errorMessage: $errorMessage, dismiss: dismiss) {
      try await onSave(changes)
    }
  }

  private var changes: TrackMetadataChanges {
    var changes = TrackMetadataChanges()
    func collect<Value>(_ fields: [MetadataField.Descriptor<Value>]) {
      for field in fields where included.contains(field.field) && field.field != .genre {
        changes[keyPath: field.change] = draft[keyPath: field.value]
      }
    }
    collect(MetadataField.stringFields)
    collect(MetadataField.numberFields)
    collect(MetadataField.boolFields)
    if included.contains(.genre) {
      let operand = genreOperand.trimmingCharacters(in: .whitespacesAndNewlines)
      switch genreEditMode {
      case .replace:
        if !mixedFields.contains(.genre) || genreReplacementTouched {
          changes.genre = draft.genre
        }
      case .add where !operand.isEmpty:
        changes.genreOperation = .add(operand)
      case .remove where !operand.isEmpty:
        changes.genreOperation = .remove(operand)
      case .makePrimary where !operand.isEmpty:
        changes.genreOperation = .makePrimary(operand)
      default:
        break
      }
    }
    return changes
  }

  private var genreReplacementBinding: Binding<String> {
    Binding(
      get: { draft.genre },
      set: {
        genreReplacementTouched = true
        draft.genre = $0
      })
  }

  private static func commonValues(in metadata: [TrackMetadata]) -> (
    metadata: TrackMetadata, mixed: Set<MetadataField>
  ) {
    var common = metadata[0]
    var mixed: Set<MetadataField> = []
    func resolve<Value: Equatable>(
      _ fields: [MetadataField.Descriptor<Value>], clearedValue: Value
    ) {
      for field in fields {
        let first = metadata[0][keyPath: field.value]
        if metadata.dropFirst().contains(where: { $0[keyPath: field.value] != first }) {
          mixed.insert(field.field)
          common[keyPath: field.value] = clearedValue
        }
      }
    }
    resolve(MetadataField.stringFields, clearedValue: "")
    resolve(MetadataField.numberFields, clearedValue: 0)
    resolve(MetadataField.boolFields, clearedValue: false)
    return (common, mixed)
  }
}
