import SwiftUI

/// Red warning label pinned above a sheet's footer while an operation error
/// is showing. Renders nothing when there is no message.
struct ErrorBanner: View {
  let message: String?

  var body: some View {
    if let message {
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.callout)
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
  }
}

/// Empty state shown when a maintenance scan finds nothing left to fix.
struct AllClearView: View {
  let message: LocalizedStringKey
  var spacing: CGFloat = 8

  var body: some View {
    VStack(spacing: spacing) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 36))
        .foregroundStyle(.secondary)
      Text(message)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// Shared footer for the library maintenance sheets: a secondary summary, a
/// Cancel button, the primary action, and a busy spinner.
struct SheetFooter: View {
  @Environment(\.dismiss) private var dismiss

  let summary: String
  var cancelTitle: LocalizedStringKey = "Cancel"
  var cancelAction: (() -> Void)? = nil
  let primaryTitle: String
  let primaryDisabled: Bool
  let isBusy: Bool
  let primaryAction: () -> Void

  var body: some View {
    HStack {
      Text(summary)
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
      Button(cancelTitle, role: .cancel) { (cancelAction ?? dismiss.callAsFunction)() }
        .keyboardShortcut(.cancelAction)
      Button(primaryTitle) { primaryAction() }
        .buttonStyle(.lit)
        .keyboardShortcut(.defaultAction)
        .disabled(primaryDisabled)
      if isBusy { ProgressView().controlSize(.small) }
    }
    .padding(16)
  }
}

/// Runs a sheet's async save/apply action: marks the sheet busy, clears any
/// previous error, then dismisses on success or records the failure and
/// re-enables the sheet.
@MainActor
func runSheetSave(
  isSaving: Binding<Bool>,
  errorMessage: Binding<String?>,
  dismiss: DismissAction,
  action: @escaping () async throws -> Void
) {
  guard !isSaving.wrappedValue else { return }
  isSaving.wrappedValue = true
  errorMessage.wrappedValue = nil
  Task {
    do {
      try await action()
      dismiss()
    } catch {
      errorMessage.wrappedValue = error.localizedDescription
      isSaving.wrappedValue = false
    }
  }
}

/// Runs a throwing operation, reporting a failure's localized description.
@MainActor
func attempt(_ operation: () throws -> Void, failure: (String) -> Void) {
  do {
    try operation()
  } catch {
    failure(error.localizedDescription)
  }
}

extension View {
  /// OK-only alert presenting an optional error message; dismissing clears it.
  func errorAlert(_ title: LocalizedStringKey, message: Binding<String?>) -> some View {
    alert(
      title,
      isPresented: Binding(
        get: { message.wrappedValue != nil },
        set: { if !$0 { message.wrappedValue = nil } })
    ) {
      Button("OK") { message.wrappedValue = nil }
    } message: {
      Text(message.wrappedValue ?? "")
    }
  }
}

extension Binding {
  /// A checkbox binding that reflects and toggles `element`'s membership in
  /// this set.
  @MainActor
  func contains<Element: Hashable & Sendable>(_ element: Element) -> Binding<Bool>
  where Value == Set<Element> {
    Binding<Bool>(
      get: { wrappedValue.contains(element) },
      set: { included in
        if included {
          wrappedValue.insert(element)
        } else {
          wrappedValue.remove(element)
        }
      })
  }
}
