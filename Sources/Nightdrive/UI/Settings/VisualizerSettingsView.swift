import SwiftUI

struct VisualizerSettingsView: View {
  @Bindable var app: AppState

  @State private var selectedID: String?
  @State private var hasRevealedInitialSelection = false
  @StateObject private var previews = VisualizerPreviewStore()

  private var catalog: VisualizerCatalog { app.visualizerSelection.catalog }
  private var descriptors: [VisualizerDescriptor] { app.visualizers.descriptors }

  var body: some View {
    VStack(spacing: 0) {
      if !app.visualizers.pendingApproval.isEmpty {
        PluginApprovalBanner(
          pending: app.visualizers.pendingApproval,
          approve: { app.visualizers.approve($0) },
          reveal: app.visualizerSelection.openVisualizersFolder)
        Rectangle().fill(SettingsSurface.hairline).frame(height: 1)
      }

      if !app.visualizers.issues.isEmpty {
        PluginIssueBanner(
          issues: app.visualizers.issues,
          reload: reloadPlugins,
          reveal: app.visualizerSelection.openVisualizersFolder)
        Rectangle().fill(SettingsSurface.hairline).frame(height: 1)
      }

      HStack(spacing: 0) {
        modeColumn
          .frame(width: 268)
          .background(SettingsSurface.list)
          .clipped()
        Rectangle().fill(SettingsSurface.hairline).frame(width: 1)
        detail
          .frame(maxWidth: .infinity)
      }
      .frame(maxHeight: .infinity)

      statusBar
    }
    .background(SettingsSurface.pane)
    .onAppear {
      if selectedID == nil { selectedID = app.visualizerSelection.visualizerID }
    }
    .task {
      await previews.registry.waitUntilReady()
    }
    .onChange(of: app.visualizerSelection.visualizerID) { _, id in selectedID = id }
  }

  // MARK: - list

  private var modeColumn: some View {
    VStack(spacing: 0) {
      VisualizerModeFilterBar(app: app)
      modeList(filteredModes)
    }
  }

  private func modeList(_ modes: FilteredModes) -> some View {
    Group {
      if modes.visible.isEmpty {
        noMatches
      } else {
        list(modes)
      }
    }
  }

  private var noMatches: some View {
    VStack(spacing: 6) {
      Spacer(minLength: 0)
      Image(systemName: "magnifyingglass")
        .font(.system(size: 21))
        .foregroundStyle(.tertiary)
      Text("No modes match")
        .font(.system(size: 12, weight: .medium))
      Text("“\(app.visualizerSearch)” isn't a mode or a group.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button("Clear Search") { app.visualizerSearch = "" }
        .controlSize(.small)
        .padding(.top, 4)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func list(_ modes: FilteredModes) -> some View {
    ScrollViewReader { proxy in
      modeRows(modes)
        .onChange(of: selectedID) { _, id in
          guard let id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
        .onGeometryChange(for: Bool.self) { proxy in
          proxy.size.height > 0
        } action: { hasLayout in
          // Reveal the selection once the list has real geometry; before
          // first layout `scrollTo` has nothing to measure against.
          guard hasLayout, !hasRevealedInitialSelection, let selectedID else { return }
          hasRevealedInitialSelection = true
          proxy.scrollTo(selectedID, anchor: .center)
        }
    }
  }

  private func modeRows(_ modes: FilteredModes) -> some View {
    List(selection: $selectedID) {
      if isReorderable {
        ForEach(modes.groups, id: \.kind) { group in
          Section {
            ForEach(group.modes) { row($0) }
              .onMove { offsets, destination in
                move(group: group, from: offsets, to: destination)
              }
          } header: {
            sectionHeader(group)
              .listRowInsets(EdgeInsets())
              .listRowBackground(SettingsSurface.list)
              .zIndex(1)
          }
        }
      } else {
        ForEach(modes.visible) { row($0) }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 24)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(SettingsSurface.list)
        .frame(height: 10)
        .allowsHitTesting(false)
    }
  }

  private func sectionHeader(_ group: ModeGroup) -> some View {
    HStack(spacing: 5) {
      Text(group.kind.title.uppercased())
        .font(.system(size: 9.5, weight: .semibold))
        .kerning(0.7)
      Text(verbatim: "\(group.modes.count)")
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .monospacedDigit()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 16)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SettingsSurface.list)
  }

  private func row(_ descriptor: VisualizerDescriptor) -> some View {
    let isOn = catalog.isEnabled(descriptor.id)
    let canToggle = catalog.canDisable(descriptor.id, in: descriptors)
    return HStack(spacing: 9) {
      RotationPip(isOn: isOn, isLocked: !canToggle) {
        app.visualizerSelection.setVisualizerEnabled(!isOn, for: descriptor.id)
      }
      .help(
        canToggle
          ? (isOn
            ? String(localized: "\(descriptor.name) is in the deck's rotation")
            : String(localized: "\(descriptor.name) is out of the rotation"))
          : String(localized: "At least one mode has to stay in the rotation")
      )
      .accessibilityLabel(String(localized: "\(descriptor.name), in the deck's rotation"))
      .accessibilityValue(isOn ? String(localized: "on") : String(localized: "off"))

      Text(VisualizerBlurb.displayName(descriptor.name))
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(isOn ? .primary : .secondary)

      Spacer(minLength: 4)

      if descriptor.id == app.visualizerSelection.visualizerID {
        Image(systemName: "play.fill")
          .font(.system(size: 8))
          .foregroundStyle(.tint)
          .help("Showing on the deck now")
          .accessibilityLabel("Showing on the deck now")
      }
      if descriptor.isPlugin {
        Image(systemName: "puzzlepiece.extension.fill")
          .font(.system(size: 9))
          .foregroundStyle(.tertiary)
          .help("Loaded from the visualizers folder")
          .accessibilityLabel("Plugin")
      }
    }
    .padding(.vertical, 2)
    .listRowSeparator(.hidden)
    .contentShape(Rectangle())
    .contextMenu {
      Button(
        isOn ? String(localized: "Take Out of Rotation") : String(localized: "Put in Rotation")
      ) {
        app.visualizerSelection.setVisualizerEnabled(!isOn, for: descriptor.id)
      }
      .disabled(!canToggle)
      Button("Show on the Deck") { showOnDeck(descriptor) }
        .disabled(descriptor.id == app.visualizerSelection.visualizerID)
      if descriptor.isPlugin {
        Divider()
        Button("Show in Finder") { app.visualizerSelection.revealVisualizerPlugin(descriptor.id) }
      }
    }
    .tag(descriptor.id)
  }

  private var statusBar: some View {
    SettingsStatusBar(text: statusText) {
      Menu {
        Button("Put Every Mode in Rotation") { catalog.enableAll(descriptors) }
          .disabled(app.visualizerSelection.enabledVisualizers.count == descriptors.count)
        Button(onlyThisTitle) { onlySelected() }
          .disabled(selected == nil || app.visualizerSelection.enabledVisualizers.count <= 1)
        Button("Reset the Running Order") { catalog.resetOrder() }
          .disabled(catalog.order.isEmpty)
        Divider()
        Button("Reload Plugins") { reloadPlugins() }
        Button("Open Visualizers Folder…") { app.visualizerSelection.openVisualizersFolder() }
      } label: {
        Label("Actions", systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Rotation and plugin actions")
      .accessibilityLabel("Visualizer actions")
    }
  }

  // MARK: - detail

  private var detail: some View {
    GeometryReader { proxy in
      VStack(spacing: 0) {
        ScrollView {
          VStack(spacing: 0) {
            detailStack
            Spacer(minLength: 0)
          }
          .padding(.horizontal, SettingsMetrics.gutter)
          .padding(.top, SettingsMetrics.contentTopInset)
          .padding(.bottom, SettingsMetrics.gutter)
          .frame(minHeight: proxy.size.height, alignment: .top)
          .frame(width: proxy.size.width)
        }
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .bottom) {
          LinearGradient(
            colors: [SettingsSurface.pane.opacity(0), SettingsSurface.pane],
            startPoint: .top, endPoint: .bottom
          )
          .frame(height: 24)
          .allowsHitTesting(false)
        }

        cyclingNote
          .padding(.horizontal, SettingsMetrics.gutter)
          .padding(.top, 12)
          .padding(.bottom, 14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(SettingsSurface.pane)
          .overlay(alignment: .top) {
            Rectangle().fill(SettingsSurface.hairline).frame(height: 1)
          }
      }
    }
  }

  private var detailStack: some View {
    VStack(alignment: .leading, spacing: 18) {
      if let selected {
        VisualizerFaceplate(
          visualizer: previews.registry.visualizer(id: selected.id),
          modeName: selected.name,
          tubeName: VisualizerColorway.colorway(id: app.visualizerSelection.colorwayID).name)

        identity(selected)
        actions(selected)

        Rectangle().fill(SettingsSurface.hairline).frame(height: 1)

        TubePicker(selectedID: app.visualizerSelection.colorwayID) { app.visualizerSelection.selectColorway($0) }
      } else {
        ContentUnavailableView(
          "No Mode Selected", systemImage: "square.dashed",
          description: Text("Pick a mode on the left to see what it looks like.")
        )
        .frame(maxWidth: .infinity, minHeight: 260)
      }
    }
  }

  private func identity(_ descriptor: VisualizerDescriptor) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(VisualizerBlurb.displayName(descriptor.name))
          .font(.system(size: 16, weight: .semibold))
        chip(descriptor.group.title, symbol: descriptor.group.symbol)
          .help(groupHelp(for: descriptor))
        chip(VisualizerBlurb.drive(for: descriptor), symbol: nil)
          .help(driveHelp(for: descriptor))
        Spacer(minLength: 0)
      }
      Text(VisualizerBlurb.text(for: descriptor))
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func chip(_ text: String, symbol: String?) -> some View {
    HStack(spacing: 3) {
      if let symbol {
        Image(systemName: symbol).font(.system(size: 8))
      }
      Text(text).font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(SettingsSurface.card, in: Capsule())
    .overlay(Capsule().strokeBorder(SettingsSurface.hairline, lineWidth: 1))
  }

  private func groupHelp(for descriptor: VisualizerDescriptor) -> String {
    if descriptor.isPlugin {
      return String(localized: "A JavaScript visualizer loaded from your Visualizers folder.")
    }
    return String(localized: "A visualizer built into Nightdrive.")
  }

  private func driveHelp(for descriptor: VisualizerDescriptor) -> String {
    descriptor.wantsContinuousRedraw
      ? String(localized: "Animates continuously, even when no audio is playing.")
      : String(localized: "Redraws from the audio signal and stays still when playback stops.")
  }

  private func actions(_ descriptor: VisualizerDescriptor) -> some View {
    let isOn = catalog.isEnabled(descriptor.id)
    let isShowing = descriptor.id == app.visualizerSelection.visualizerID
    return HStack(alignment: .top, spacing: 16) {
      if isShowing {
        HStack(spacing: 5) {
          Image(systemName: "play.fill").font(.system(size: 9))
          Text("On the deck now").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(VFD.accent)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(VFD.accent.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
      } else {
        Button {
          showOnDeck(descriptor)
        } label: {
          Label("Show on the Deck", systemImage: "play.fill")
        }
        .buttonStyle(.lit)
        .controlSize(.regular)
        .help("Put this mode on the deck's glass and fold the deck open")
      }

      VStack(alignment: .leading, spacing: 1) {
        Toggle("Keep in the rotation", isOn: rotationBinding(descriptor.id))
          .toggleStyle(.checkbox)
          .disabled(!catalog.canDisable(descriptor.id, in: descriptors))
          .accessibilityHint("Whether the deck stops on this mode as it cycles")
        Text(
          isOn
            ? String(localized: "⇧⌘V and clicking the glass will stop here.")
            : String(localized: "The deck will skip past this one.")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
  }

  private var cyclingNote: some View {
    Text("Click the deck's glass or press ⇧⌘V to step through the rotation.")
      .font(.caption)
      .foregroundStyle(.tertiary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }

  // MARK: - Data

  private var selected: VisualizerDescriptor? {
    descriptors.first { $0.id == selectedID } ?? app.visualizerSelection.allVisualizers.first
  }

  private struct FilteredModes {
    var visible: [VisualizerDescriptor] = []
    var groups: [ModeGroup] = []
  }

  private var filteredModes: FilteredModes {
    let query = app.visualizerSearch.trimmingCharacters(in: .whitespaces).lowercased()
    var modes = FilteredModes()
    var groupIndexByKind: [VisualizerGroup: Int] = [:]
    for descriptor in app.visualizerSelection.allVisualizers {
      if let filter = app.visualizerFilter, descriptor.group != filter { continue }
      if !query.isEmpty {
        let matches =
          descriptor.name.lowercased().contains(query)
          || descriptor.id.lowercased().contains(query)
          || descriptor.group.title.lowercased().contains(query)
        if !matches { continue }
      }
      modes.visible.append(descriptor)
      if let index = groupIndexByKind[descriptor.group] {
        modes.groups[index].modes.append(descriptor)
      } else {
        groupIndexByKind[descriptor.group] = modes.groups.count
        modes.groups.append(ModeGroup(kind: descriptor.group, modes: [descriptor]))
      }
    }
    return modes
  }

  private var isReorderable: Bool {
    app.visualizerSearch.isEmpty && app.visualizerFilter == nil
  }

  private struct ModeGroup {
    var kind: VisualizerGroup
    var modes: [VisualizerDescriptor]
  }

  private var statusText: String {
    let total = descriptors.count
    let on = descriptors.filter { catalog.isEnabled($0.id) }.count
    let modes =
      on == total
      ? String(localized: "All \(total) modes in the rotation")
      : String(localized: "\(on) of \(total) modes in the rotation")
    let plugins = descriptors.filter(\.isPlugin).count
    guard plugins > 0 else { return modes }
    let pluginSummary =
      plugins == 1 ? String(localized: "1 plugin") : String(localized: "\(plugins) plugins")
    return "\(modes) · \(pluginSummary)"
  }

  private var onlyThisTitle: String {
    guard let selected else { return String(localized: "Only the Selected Mode") }
    return String(localized: "Only \(VisualizerBlurb.displayName(selected.name))")
  }

  // MARK: - Actions

  private func rotationBinding(_ id: String) -> Binding<Bool> {
    Binding(
      get: { catalog.isEnabled(id) },
      set: { app.visualizerSelection.setVisualizerEnabled($0, for: id) })
  }

  private func showOnDeck(_ descriptor: VisualizerDescriptor) {
    if !catalog.isEnabled(descriptor.id) {
      app.visualizerSelection.setVisualizerEnabled(true, for: descriptor.id)
    }
    app.visualizerSelection.selectVisualizer(descriptor.id)
    app.deck.open()
  }

  private func onlySelected() {
    guard let selected else { return }
    catalog.disableAll(descriptors, keeping: selected.id)
    if !catalog.isEnabled(app.visualizerSelection.visualizerID) {
      app.visualizerSelection.selectVisualizer(selected.id)
    }
  }

  private func move(group: ModeGroup, from offsets: IndexSet, to destination: Int) {
    var moved = group.modes
    moved.move(fromOffsets: offsets, toOffset: destination)

    var replacements = moved.makeIterator()
    let members = Set(group.modes.map(\.id))
    let reordered = app.visualizerSelection.allVisualizers.map { descriptor in
      members.contains(descriptor.id) ? (replacements.next() ?? descriptor) : descriptor
    }
    catalog.reorder(to: reordered)
  }

  private func reloadPlugins() {
    app.visualizers.reloadPlugins()
    previews.registry.reloadPlugins()
    Task {
      await app.visualizers.waitUntilReady()
      await previews.registry.waitUntilReady()
      if !descriptors.contains(where: { $0.id == selectedID }) {
        selectedID = app.visualizerSelection.allVisualizers.first?.id
      }
    }
  }
}

struct VisualizerModeFilterBar: View {
  @Bindable var app: AppState

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("Search modes", text: $app.visualizerSearch)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .accessibilityLabel("Search visualizer modes")

      if !app.visualizerSearch.isEmpty {
        Button {
          app.visualizerSearch = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Clear search")
      }

      Menu {
        Picker("Show", selection: $app.visualizerFilter) {
          Text("All Visualizers").tag(VisualizerGroup?.none)
          Divider()
          ForEach(groupsPresent) { group in
            Label(group.title, systemImage: group.symbol)
              .tag(VisualizerGroup?.some(group))
          }
        }
        .pickerStyle(.inline)
        .labelsHidden()
      } label: {
        Image(
          systemName: app.visualizerFilter == nil
            ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill"
        )
        .font(.system(size: 11, weight: .medium))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Show only built-in modes or plugins")
      .accessibilityLabel("Filter by visualizer group")
    }
    .padding(.horizontal, 8)
    .frame(maxWidth: .infinity)
    .frame(height: 24)
    .background(SettingsSurface.card, in: Capsule())
    .overlay(Capsule().strokeBorder(SettingsSurface.hairline, lineWidth: 1))
    .padding(.horizontal, 10)
    .padding(.top, SettingsMetrics.contentTopInset)
    .padding(.bottom, 8)
    .background(SettingsSurface.list)
    .overlay(alignment: .bottom) {
      Rectangle().fill(SettingsSurface.hairline).frame(height: 1)
    }
  }

  private var groupsPresent: [VisualizerGroup] {
    var seen: [VisualizerGroup] = []
    for descriptor in app.visualizerSelection.allVisualizers where !seen.contains(descriptor.group) {
      seen.append(descriptor.group)
    }
    return seen
  }
}

@MainActor
final class VisualizerPreviewStore: ObservableObject {
  let registry = VisualizerRegistry()
}

struct RotationPip: View {
  let isOn: Bool
  var isLocked = false
  let toggle: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Button(action: toggle) {
      ZStack {
        if isOn {
          Circle()
            .fill(isLocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(VFD.accent))
          Image(systemName: "checkmark")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(isLocked ? Color.white : VFD.accentInk)
        } else {
          Circle()
            .strokeBorder(.tertiary, lineWidth: 1.3)
        }
      }
      .frame(width: 13, height: 13)
      .contentShape(Circle())
      .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isOn)
    }
    .buttonStyle(.plain)
    .disabled(isLocked)
    .accessibilityAddTraits(.isToggle)
  }
}

struct PluginApprovalBanner: View {
  let pending: [VisualizerPluginFolder.PendingScript]
  let approve: (VisualizerPluginFolder.PendingScript) -> Void
  let reveal: () -> Void

  var body: some View {
    SettingsNotice(tone: .news, headline: headline, lines: lines) {
      if pending.count == 1, let script = pending.first {
        Button("Approve \(script.name)") { approve(script) }
      } else {
        Menu("Approve") {
          ForEach(pending) { script in
            Button(script.name) { approve(script) }
          }
        }
        .fixedSize()
      }
      Button("Show in Finder", action: reveal)
    }
  }

  private var headline: String {
    pending.count == 1
      ? String(localized: "A new plugin is waiting for your approval")
      : String(localized: "\(pending.count) new plugins are waiting for your approval")
  }

  private var lines: [String] {
    let names = pending.map(\.name).formatted(.list(type: .and))
    return [
      pending.count == 1
        ? String(
          localized:
            "\(names) runs JavaScript inside Nightdrive, so nothing loads until you approve it.")
        : String(
          localized:
            "\(names) run JavaScript inside Nightdrive, so nothing loads until you approve them.")
    ]
  }
}

struct PluginIssueBanner: View {
  let issues: [VisualizerScriptIssue]
  let reload: () -> Void
  let reveal: () -> Void

  private static let shown = 3

  var body: some View {
    SettingsNotice(tone: .problem, headline: headline, lines: lines) {
      Button("Reload", action: reload)
      Button("Show in Finder", action: reveal)
    }
  }

  private var headline: String {
    issues.count == 1
      ? String(localized: "A plugin didn't load")
      : String(localized: "\(issues.count) plugins didn't load")
  }

  private var lines: [String] {
    var lines = issues.prefix(Self.shown).map { "\($0.source) — \($0.message)" }
    if issues.count > Self.shown {
      lines.append(String(localized: "…and \(issues.count - Self.shown) more."))
    }
    return lines
  }
}
