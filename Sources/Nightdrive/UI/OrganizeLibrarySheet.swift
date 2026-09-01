import SwiftUI
import UniformTypeIdentifiers

/// Preview-first sheet that reorganizes the library folder around a naming
/// structure the user assembles from tag blocks. Nothing moves until the
/// user applies the previewed plan.
struct OrganizeLibrarySheet: View {
  @Environment(\.dismiss) private var dismiss

  /// Reads the live library so replans after a partial failure see the
  /// files that actually moved, not the pre-apply snapshot.
  let tracks: () -> [LibraryTrack]
  let libraryFolder: URL
  let onApply: (LibraryOrganizeChanges) async -> AppState.LibraryRelocationOutcome?

  @State private var blocks: [LibraryPathBlock] = OrganizeStructureDefaults.load()
  @State private var renameFiles = false
  @State private var conflictPolicy: LibraryOrganizeConflictPolicy = .rename
  @State private var draggedBlock: LibraryPathBlock?
  @State private var plan: LibraryOrganizePlan?
  @State private var planTask: Task<Void, Never>?
  @State private var isApplying = false
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      ErrorBanner(message: errorMessage)
      Divider()
      footer
    }
    .frame(width: 720, height: 560)
    .onAppear { rebuildPlan() }
    .onChange(of: blocks) {
      OrganizeStructureDefaults.store(blocks)
      rebuildPlan()
    }
    .onChange(of: renameFiles) { rebuildPlan() }
    .onChange(of: conflictPolicy) { rebuildPlan() }
    .onDisappear { planTask?.cancel() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Organize Library Files")
          .font(.headline)
        Spacer()
        Menu("Presets") {
          ForEach(LibraryOrganizePattern.allCases) { pattern in
            Button(pattern.label) {
              withAnimation(.snappy(duration: 0.2)) { blocks = pattern.blocks }
            }
          }
        }
        .fixedSize()
        .disabled(isApplying)
      }
      blockBuilder
      Toggle("Rename files to “01 Title.mp3”", isOn: $renameFiles)
        .disabled(isApplying)
      HStack {
        Text("When files conflict:")
        Picker("When files conflict", selection: $conflictPolicy) {
          Text("Rename the out-of-place file").tag(LibraryOrganizeConflictPolicy.rename)
          Text("Move the out-of-place file to Trash")
            .tag(LibraryOrganizeConflictPolicy.moveToTrash)
        }
        .labelsHidden()
        .fixedSize()
        .disabled(isApplying)
      }
      Text("Example: \(examplePath)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
  }

  /// The structure the user is building, one draggable chip per folder
  /// level, with an add menu for the blocks not in use yet. Chips flow onto
  /// further lines once a structure outgrows the sheet.
  private var blockBuilder: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
      if blocks.isEmpty {
        Text("No folders — files move to the top level")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      FlowLayout(spacing: 6) {
        ForEach(blocks) { block in
          blockChip(block)
          if block != blocks.last {
            Text("/")
              .foregroundStyle(.tertiary)
          }
        }
        addBlockMenu
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.05))
        .strokeBorder(Color.primary.opacity(0.1))
    )
    .onDrop(of: [.text], isTargeted: nil) { _ in
      draggedBlock = nil
      return true
    }
    .animation(.snappy(duration: 0.2), value: blocks)
  }

  private func blockChip(_ block: LibraryPathBlock) -> some View {
    HStack(spacing: 4) {
      Image(systemName: "line.3.horizontal")
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.tertiary)
      Text(block.label)
        .font(.callout.weight(.medium))
      Button {
        withAnimation(.snappy(duration: 0.2)) {
          blocks.removeAll { $0 == block }
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Remove \(block.label)")
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Capsule().fill(VFD.accent.opacity(0.14)))
    .overlay(Capsule().strokeBorder(VFD.accent.opacity(0.3)))
    .opacity(draggedBlock == block ? 0.4 : 1)
    .help(block.detail)
    .onDrag {
      draggedBlock = block
      return NSItemProvider(object: block.rawValue as NSString)
    }
    .onDrop(
      of: [.text],
      delegate: BlockReorderDropDelegate(
        target: block, blocks: $blocks, dragged: $draggedBlock)
    )
    .disabled(isApplying)
  }

  private var addBlockMenu: some View {
    Menu {
      ForEach(availableBlocks) { block in
        Button {
          withAnimation(.snappy(duration: 0.2)) { blocks.append(block) }
        } label: {
          Text(block.label)
          Text(block.detail)
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 10, weight: .bold))
        .frame(width: 20, height: 20)
        .background(Circle().fill(Color.primary.opacity(0.08)))
        .contentShape(Circle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(isApplying || availableBlocks.isEmpty)
    .accessibilityLabel("Add a folder level")
  }

  private var availableBlocks: [LibraryPathBlock] {
    LibraryPathBlock.allCases.filter { !blocks.contains($0) }
  }

  private var examplePath: String {
    let folders = blocks.map(\.exampleValue).joined(separator: "/")
    let filename = renameFiles ? "01 One More Time.mp3" : "Daft Punk - One More Time.mp3"
    return folders.isEmpty ? filename : "\(folders)/\(filename)"
  }

  @ViewBuilder
  private var content: some View {
    if let plan {
      if plan.actionItems.isEmpty {
        AllClearView(message: "Every file already matches this structure.")
      } else {
        moveList(plan)
      }
    } else {
      VStack(spacing: 12) {
        ProgressView()
        Text("Planning moves for \(tracks().count) songs…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func moveList(_ plan: LibraryOrganizePlan) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 8) {
        ForEach(plan.actionItems) { item in
          moveRow(item)
        }
      }
      .padding(16)
    }
  }

  private func moveRow(_ item: LibraryOrganizePlanItem) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        Text(sourcePath(for: item.track))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if item.status == .renamedToAvoidConflict {
          Text("Renamed to avoid a conflict")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .foregroundStyle(.secondary)
        } else if item.status == .moveToTrash {
          Text("Will move to Trash")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.red.opacity(0.1)))
            .foregroundStyle(.red)
        }
      }
      Label {
        Text(
          item.status == .moveToTrash
            ? String(localized: "Conflicts with \(item.relativeDestination)")
            : item.relativeDestination
        )
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
      } icon: {
        Image(systemName: item.status == .moveToTrash ? "trash" : "arrow.turn.down.right")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func sourcePath(for track: LibraryTrack) -> String {
    SyncLedgerStore.relativePath(for: track.url, in: libraryFolder) ?? track.url.path
  }

  private var footer: some View {
    SheetFooter(
      summary: footerSummary,
      primaryTitle: applyButtonTitle,
      primaryDisabled: plan?.actionItems.isEmpty != false || isApplying,
      isBusy: isApplying,
      primaryAction: apply)
  }

  private var footerSummary: String {
    guard let plan else { return "" }
    var parts: [String] = []
    switch plan.moves.count {
    case 0: break
    case 1: parts.append(String(localized: "1 file will move."))
    default: parts.append(String(localized: "\(plan.moves.count) files will move."))
    }
    switch plan.conflictRemovals.count {
    case 0: break
    case 1: parts.append(String(localized: "1 conflicting file will move to Trash."))
    default:
      parts.append(
        String(localized: "\(plan.conflictRemovals.count) conflicting files will move to Trash."))
    }
    switch plan.alreadyOrganizedCount {
    case 0: break
    case 1: parts.append(String(localized: "1 file is already in place."))
    default:
      parts.append(String(localized: "\(plan.alreadyOrganizedCount) files are already in place."))
    }
    return parts.joined(separator: " ")
  }

  private var applyButtonTitle: String {
    guard let plan else { return String(localized: "Apply Changes") }
    if plan.moves.isEmpty {
      return plan.conflictRemovals.count == 1
        ? String(localized: "Move 1 File to Trash")
        : String(localized: "Move \(plan.conflictRemovals.count) Files to Trash")
    }
    if plan.conflictRemovals.isEmpty {
      return plan.moves.count == 1
        ? String(localized: "Move 1 File") : String(localized: "Move \(plan.moves.count) Files")
    }
    return String(localized: "Apply Changes")
  }

  private func rebuildPlan() {
    planTask?.cancel()
    plan = nil
    let tracks = tracks()
    let blocks = blocks
    let renameFiles = renameFiles
    let conflictPolicy = conflictPolicy
    let root = libraryFolder
    planTask = Task {
      let built = await Task.detached(priority: .userInitiated) {
        LibraryOrganizer.plan(
          tracks: tracks, root: root, blocks: blocks, renameFiles: renameFiles,
          conflictPolicy: conflictPolicy)
      }.value
      guard !Task.isCancelled else { return }
      plan = built
    }
  }

  private func apply() {
    guard !isApplying, let plan, !plan.actionItems.isEmpty else { return }
    isApplying = true
    errorMessage = nil
    let changes = plan.changes(root: libraryFolder)
    Task {
      let outcome = await onApply(changes)
      guard let outcome else {
        errorMessage = LibraryStoreError.libraryChanged.localizedDescription
        isApplying = false
        return
      }
      if let failure = outcome.failed.first {
        errorMessage =
          outcome.failed.count == 1
          ? "\(failure.track.url.lastPathComponent): \(failure.message)"
          : "\(outcome.failed.count) files couldn’t be changed. \(failure.message)"
        isApplying = false
        rebuildPlan()
        return
      }
      if let warning = outcome.sidecarWarning {
        errorMessage = warning
        isApplying = false
        rebuildPlan()
        return
      }
      dismiss()
    }
  }
}

/// Remembers the structure the user built across sheet presentations.
enum OrganizeStructureDefaults {
  private static let key = "libraryOrganizeStructure"

  static func load(defaults: UserDefaults = NightdriveDefaults.current) -> [LibraryPathBlock] {
    guard let stored = defaults.string(forKey: key),
      let blocks = LibraryPathBlock.decodeList(stored)
    else { return LibraryOrganizePattern.artistAlbum.blocks }
    return blocks
  }

  static func store(
    _ blocks: [LibraryPathBlock], defaults: UserDefaults = NightdriveDefaults.current
  ) {
    defaults.set(LibraryPathBlock.encodeList(blocks), forKey: key)
  }
}

/// Reorders chips as a dragged block passes over its neighbours, the
/// standard in-place reorder pattern for horizontal chip rows.
private struct BlockReorderDropDelegate: DropDelegate {
  let target: LibraryPathBlock
  @Binding var blocks: [LibraryPathBlock]
  @Binding var dragged: LibraryPathBlock?

  func dropEntered(info: DropInfo) {
    guard let dragged, dragged != target,
      let from = blocks.firstIndex(of: dragged),
      let to = blocks.firstIndex(of: target)
    else { return }
    withAnimation(.snappy(duration: 0.2)) {
      blocks.move(
        fromOffsets: IndexSet(integer: from),
        toOffset: to > from ? to + 1 : to)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    dragged = nil
    return true
  }
}
