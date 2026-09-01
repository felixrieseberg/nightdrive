import AppKit
import SwiftUI

/// Edits the ordered genre list while preserving the semicolon-compatible
/// representation used by older tag formats. The first chip is the genre a
/// classic iPod receives.
struct GenreEditor: View {
  @Binding var rawValue: String
  private let suggestions: [String]
  private let primaryGenre: Binding<String>?
  @State private var pendingGenre = ""
  @State private var isAddingGenre = false

  private var genres: [String] { GenreMetadata.values(from: rawValue) }

  init(
    rawValue: Binding<String>, suggestions: [String] = [],
    primaryGenre: Binding<String>? = nil
  ) {
    _rawValue = rawValue
    self.suggestions = suggestions
    self.primaryGenre = primaryGenre
  }

  var body: some View {
    FlowLayout(spacing: 6, fillsProposedWidth: true) {
      ForEach(Array(genres.enumerated()), id: \.element) { index, genre in
        genreChip(genre, isPrimary: isPrimary(genre, index: index))
      }
      pendingGenreChip
    }
    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
    .background {
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture { isAddingGenre = true }
        .help("Click to add a genre")
    }
  }

  private var pendingGenreChip: some View {
    GenreDraftTokenField(
      text: $pendingGenre,
      candidates: suggestions,
      excluding: genres,
      isFocused: $isAddingGenre,
      onSubmit: addPendingGenre
    )
    .frame(
      width: Self.draftFieldWidth(for: pendingGenre, font: pendingGenreFont),
      height: pendingGenreLineHeight,
      alignment: .center
    )
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background {
      if showsPendingGenreChip {
        Capsule().fill(VFD.accent.opacity(0.14))
      }
    }
    .overlay {
      if showsPendingGenreChip {
        Capsule().strokeBorder(VFD.accent.opacity(0.32))
      }
    }
    .help("Type a genre and press Return")
    .accessibilityHint("Press Return to confirm this genre")
  }

  private var pendingGenreLineHeight: CGFloat {
    ceil(pendingGenreFont.boundingRectForFont.height)
  }

  private var pendingGenreFont: NSFont {
    NSFont.preferredFont(forTextStyle: .callout)
  }

  private var showsPendingGenreChip: Bool {
    Self.showsDraftChip(draft: pendingGenre, isFocused: isAddingGenre)
  }

  private func genreChip(_ genre: String, isPrimary: Bool) -> some View {
    HStack(spacing: 4) {
      Button {
        makePrimary(genre)
      } label: {
        HStack(spacing: 4) {
          if isPrimary {
            Image(systemName: "star.fill")
              .font(.caption2)
          }
          Text(genre)
            .lineLimit(1)
        }
      }
      .buttonStyle(.plain)
      .help(
        isPrimary
          ? String(localized: "Primary genre sent to iPod")
          : String(localized: "Make primary genre"))
      Button {
        remove(genre)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .help("Remove \(genre)")
    }
    .font(.callout)
    .padding(.leading, 8)
    .padding(.trailing, 6)
    .padding(.vertical, 4)
    .foregroundStyle(isPrimary ? VFD.accent : .primary)
    .background(
      Capsule().fill(isPrimary ? VFD.accent.opacity(0.14) : Color.primary.opacity(0.08))
    )
    .overlay(
      Capsule().strokeBorder(
        isPrimary ? VFD.accent.opacity(0.32) : Color.primary.opacity(0.12)))
  }

  private func addPendingGenre() {
    let shouldBecomePrimary = primaryGenre?.wrappedValue.isEmpty == true
    guard
      let updatedGenres = Self.confirmedGenres(
        draft: pendingGenre, existing: genres, makePrimary: shouldBecomePrimary)
    else { return }
    rawValue = GenreMetadata.joined(updatedGenres)
    if shouldBecomePrimary { primaryGenre?.wrappedValue = updatedGenres.first ?? "" }
    pendingGenre = ""
  }

  nonisolated static func confirmedGenres(
    draft: String, existing: [String], makePrimary: Bool
  ) -> [String]? {
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    return GenreMetadata.canonicalValues(
      makePrimary ? [value] + existing : existing + [value])
  }

  nonisolated static func showsDraftChip(draft: String, isFocused: Bool) -> Bool {
    isFocused || !draft.isEmpty
  }

  nonisolated static func draftFieldWidth(for draft: String, font: NSFont) -> CGFloat {
    let glyphWidth = ceil((draft as NSString).size(withAttributes: [.font: font]).width)
    return min(240, max(28, glyphWidth + 4))
  }

  private func makePrimary(_ genre: String) {
    rawValue = GenreMetadata.joined([genre] + genres.filter { $0 != genre })
    primaryGenre?.wrappedValue = genre
  }

  private func remove(_ genre: String) {
    let remaining = genres.filter { $0 != genre }
    rawValue = GenreMetadata.joined(remaining)
    if primaryGenre?.wrappedValue == genre {
      primaryGenre?.wrappedValue = remaining.first ?? ""
    }
  }

  private func isPrimary(_ genre: String, index: Int) -> Bool {
    if let primaryGenre { return primaryGenre.wrappedValue == genre }
    return index == 0
  }
}

struct GenreAutocompleteField: View {
  private let title: String
  @Binding private var text: String
  private let candidates: [String]
  private let excluding: [String]
  private let showsPrompt: Bool
  private let onSubmit: () -> Void

  init(
    _ title: String,
    text: Binding<String>,
    candidates: [String],
    excluding: [String] = [],
    showsPrompt: Bool = true,
    onSubmit: @escaping () -> Void = {}
  ) {
    self.title = title
    _text = text
    self.candidates = candidates
    self.excluding = excluding
    self.showsPrompt = showsPrompt
    self.onSubmit = onSubmit
  }

  var body: some View {
    TextField(text: $text, prompt: showsPrompt ? Text(title) : nil) {
      EmptyView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .multilineTextAlignment(.leading)
    .accessibilityLabel(Text(title))
    .accessibilityIdentifier("genre-autocomplete-field")
    .textInputSuggestions {
      ForEach(
        GenreMetadata.completions(
          for: text, from: candidates, excluding: excluding),
        id: \.self
      ) { suggestion in
        Text(suggestion)
          .textInputCompletion(suggestion)
      }
    }
    .onSubmit(onSubmit)
  }
}

struct GenreDraftTokenField: NSViewRepresentable {
  @Binding var text: String
  let candidates: [String]
  let excluding: [String]
  @Binding var isFocused: Bool
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> GenreDraftNativeTokenField {
    let field = GenreDraftNativeTokenField()
    field.onFocusChange = { [weak coordinator = context.coordinator] isFocused in
      coordinator?.parent.isFocused = isFocused
    }
    field.delegate = context.coordinator
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.lineBreakMode = .byClipping
    field.alignment = .center
    field.font = NSFont.preferredFont(forTextStyle: .callout)
    field.textColor = NSColor(VFD.accent)
    field.tokenStyle = .none
    field.tokenizingCharacterSet = CharacterSet()
    field.completionDelay = 0.15
    field.setAccessibilityLabel("Add genre")
    field.setAccessibilityIdentifier("genre-autocomplete-field")
    return field
  }

  func updateNSView(_ field: GenreDraftNativeTokenField, context: Context) {
    context.coordinator.parent = self
    field.alignment = .center
    field.textColor = NSColor(VFD.accent)
    if field.currentEditor() == nil, field.stringValue != text {
      field.stringValue = text
    }
    if isFocused, field.currentEditor() == nil {
      DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
        guard coordinator?.parent.isFocused == true else { return }
        field?.window?.makeFirstResponder(field)
      }
    } else if !isFocused, field.currentEditor() != nil {
      DispatchQueue.main.async { [weak field, weak coordinator = context.coordinator] in
        guard coordinator?.parent.isFocused == false else { return }
        field?.window?.makeFirstResponder(nil)
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTokenFieldDelegate {
    var parent: GenreDraftTokenField

    init(parent: GenreDraftTokenField) { self.parent = parent }

    func controlTextDidBeginEditing(_ notification: Notification) {
      parent.isFocused = true
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTokenField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      parent.isFocused = false
    }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      guard commandSelector == #selector(NSResponder.insertNewline(_:)),
        let field = control as? NSTokenField
      else { return false }
      parent.onSubmit()
      field.stringValue = ""
      textView.string = ""
      parent.text = ""
      return true
    }

    func tokenField(
      _ tokenField: NSTokenField,
      completionsForSubstring substring: String,
      indexOfToken tokenIndex: Int,
      indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
      selectedIndex?.pointee = -1
      return GenreMetadata.completions(
        for: substring, from: parent.candidates, excluding: parent.excluding)
    }
  }
}

final class GenreDraftNativeTokenField: NSTokenField {
  var onFocusChange: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let becameFirstResponder = super.becomeFirstResponder()
    if becameFirstResponder { onFocusChange?(true) }
    return becameFirstResponder
  }

  override func resignFirstResponder() -> Bool {
    let resignedFirstResponder = super.resignFirstResponder()
    if resignedFirstResponder { onFocusChange?(false) }
    return resignedFirstResponder
  }
}
