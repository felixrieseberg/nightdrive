import SwiftUI

struct SmartRuleDraft: Equatable {
  var artist = ""
  var album = ""
  var genre = ""
  var yearMinimum = ""
  var yearMaximum = ""
  var minimumRating = 0
  var minimumPlays = ""
  var addedWithinDays = ""
  var favoritesOnly = false
  var format: LibraryAudioFormat?

  init() {}

  init(rule: SmartPlaylistRule) {
    for predicate in rule.predicates {
      switch predicate {
      case .artistContains(let text): artist = text
      case .albumContains(let text): album = text
      case .genreContains(let text): genre = text
      case .yearBetween(let minimum, let maximum):
        yearMinimum = minimum.map(String.init) ?? ""
        yearMaximum = maximum.map(String.init) ?? ""
      case .ratingAtLeast(let stars): minimumRating = stars
      case .playCountAtLeast(let plays): minimumPlays = String(plays)
      case .addedWithinDays(let days): addedWithinDays = String(days)
      case .favorite: favoritesOnly = true
      case .format(let value): format = value
      }
    }
  }

  var rule: SmartPlaylistRule {
    var predicates: [SmartPlaylistPredicate] = []
    let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    if !artist.isEmpty { predicates.append(.artistContains(artist)) }
    let album = album.trimmingCharacters(in: .whitespacesAndNewlines)
    if !album.isEmpty { predicates.append(.albumContains(album)) }
    let genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
    if !genre.isEmpty { predicates.append(.genreContains(genre)) }
    let low = Int(yearMinimum.trimmingCharacters(in: .whitespaces))
    let high = Int(yearMaximum.trimmingCharacters(in: .whitespaces))
    if low != nil || high != nil {
      predicates.append(.yearBetween(minimum: low, maximum: high))
    }
    if minimumRating > 0 { predicates.append(.ratingAtLeast(minimumRating)) }
    if let plays = Int(minimumPlays.trimmingCharacters(in: .whitespaces)), plays > 0 {
      predicates.append(.playCountAtLeast(plays))
    }
    if let days = Int(addedWithinDays.trimmingCharacters(in: .whitespaces)), days > 0 {
      predicates.append(.addedWithinDays(days))
    }
    if favoritesOnly { predicates.append(.favorite) }
    if let format { predicates.append(.format(format)) }
    return SmartPlaylistRule(predicates: predicates)
  }
}

struct SmartRuleEditorView: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let confirmLabel: String
  let showsName: Bool
  let onSave: (String, SmartPlaylistRule) -> Void
  @State private var name: String
  @State private var draft: SmartRuleDraft

  init(
    title: String,
    confirmLabel: String = "Save",
    name: String = "",
    showsName: Bool = false,
    rule: SmartPlaylistRule = SmartPlaylistRule(),
    onSave: @escaping (String, SmartPlaylistRule) -> Void
  ) {
    self.title = title
    self.confirmLabel = confirmLabel
    self.showsName = showsName
    self.onSave = onSave
    _name = State(initialValue: name)
    _draft = State(initialValue: SmartRuleDraft(rule: rule))
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        if showsName {
          Section {
            TextField("Name", text: $name)
          }
        }
        Section("Match all of these (leave a row empty to skip it)") {
          TextField("Artist contains", text: $draft.artist)
          TextField("Album contains", text: $draft.album)
          TextField("Genre contains", text: $draft.genre)
          HStack {
            TextField("Year from", text: $draft.yearMinimum)
            TextField("to", text: $draft.yearMaximum)
          }
          Picker("Rating at least", selection: $draft.minimumRating) {
            Text("Any").tag(0)
            ForEach(1...5, id: \.self) { stars in
              Text(String(repeating: "★", count: stars)).tag(stars)
            }
          }
          TextField("Played at least (times)", text: $draft.minimumPlays)
          TextField("Added in the last (days)", text: $draft.addedWithinDays)
          Toggle("Favorites only", isOn: $draft.favoritesOnly)
          Picker("Format", selection: $draft.format) {
            Text("Any").tag(LibraryAudioFormat?.none)
            ForEach(LibraryAudioFormat.allCases, id: \.self) { format in
              Text(format.rawValue.uppercased()).tag(Optional(format))
            }
          }
        }
      }
      .formStyle(.grouped)
      Divider()
      HStack {
        Text(draft.rule.summary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
        Spacer()
        Button("Cancel") { dismiss() }
        Button(confirmLabel) {
          onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), draft.rule)
          dismiss()
        }
        .buttonStyle(.lit)
        .disabled(showsName && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding()
    }
    .navigationTitle(title)
    .frame(minWidth: 460, minHeight: 440)
  }
}
