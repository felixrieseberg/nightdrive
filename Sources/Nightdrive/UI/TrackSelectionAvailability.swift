import SwiftUI

struct TrackCommands {
  let selectionCount: Int
  let canEditInfo: Bool
  let editInfo: (() -> Void)?
}

private struct TrackCommandsKey: FocusedValueKey {
  typealias Value = TrackCommands
}

extension FocusedValues {
  var trackCommands: TrackCommands? {
    get { self[TrackCommandsKey.self] }
    set { self[TrackCommandsKey.self] = newValue }
  }
}

private struct TrackCommandsModifier<ID: Hashable>: ViewModifier {
  @Binding var selection: Set<ID>
  let visibleIDs: Set<ID>
  let mutationsDisabled: Bool
  let canEditInfo: ((Set<ID>) -> Bool)?
  let editInfo: ((Set<ID>) -> Void)?

  func body(content: Content) -> some View {
    content.focusedSceneValue(\.trackCommands, commands)
  }

  private var commands: TrackCommands {
    let selectedIDs = selection.intersection(visibleIDs)
    return TrackCommands(
      selectionCount: selectedIDs.count,
      canEditInfo: editInfo != nil && !selectedIDs.isEmpty && !mutationsDisabled
        && (canEditInfo?(selectedIDs) ?? true),
      editInfo: editInfoCommand)
  }

  private var editInfoCommand: (() -> Void)? {
    guard let editInfo else { return nil }
    return { editInfo(selection.intersection(visibleIDs)) }
  }
}

private struct ClearTrackSelectionWhenUnavailable: ViewModifier {
  @Binding var selection: Set<TrackID>
  let unavailable: Bool

  func body(content: Content) -> some View {
    content
      .onAppear { clearIfNeeded() }
      .onChange(of: unavailable) { clearIfNeeded() }
      .onChange(of: selection) { clearIfNeeded() }
  }

  private func clearIfNeeded() {
    guard unavailable, !selection.isEmpty else { return }
    selection.removeAll()
  }
}

extension View {
  func trackCommands<ID: Hashable>(
    selection: Binding<Set<ID>>,
    visibleIDs: Set<ID>,
    mutationsDisabled: Bool = false,
    canEditInfo: ((Set<ID>) -> Bool)? = nil,
    editInfo: ((Set<ID>) -> Void)? = nil
  ) -> some View {
    modifier(
      TrackCommandsModifier(
        selection: selection,
        visibleIDs: visibleIDs,
        mutationsDisabled: mutationsDisabled,
        canEditInfo: canEditInfo,
        editInfo: editInfo))
  }

  func clearsTrackSelection(_ selection: Binding<Set<TrackID>>, when unavailable: Bool)
    -> some View
  {
    modifier(
      ClearTrackSelectionWhenUnavailable(
        selection: selection,
        unavailable: unavailable))
  }
}
