import Foundation
import Observation
import SwiftUI

/// The deck's visualizer and colorway selection model: which visualizer is
/// showing, which are enabled, and the persisted preferences behind both.
@Observable
@MainActor
final class VisualizerSelection {
  @ObservationIgnored private let registry: VisualizerRegistry
  @ObservationIgnored private let defaults: UserDefaults
  let catalog: VisualizerCatalog

  static let defaultVisualizerID = "nightdrive"
  private static let visualizerKey = "visualizerMode"

  var visualizerID: String {
    didSet { defaults.set(visualizerID, forKey: Self.visualizerKey) }
  }

  init(
    registry: VisualizerRegistry = .shared,
    defaults: UserDefaults = NightdriveDefaults.current
  ) {
    self.registry = registry
    self.defaults = defaults
    visualizerID = defaults.string(forKey: Self.visualizerKey) ?? Self.defaultVisualizerID
    catalog = VisualizerCatalog(defaults: defaults)
  }

  var currentVisualizer: any Visualizer {
    registry.visualizer(id: visualizerID)
      ?? registry.visualizer(id: enabledVisualizers.first?.id ?? "")
      ?? registry.visualizers.first
      ?? SpectrumVisualizer()
  }

  var allVisualizers: [VisualizerDescriptor] {
    catalog.arranged(registry.descriptors)
  }

  var enabledVisualizers: [VisualizerDescriptor] {
    catalog.enabled(registry.descriptors)
  }

  func selectVisualizer(_ id: String) {
    guard id != visualizerID else { return }
    currentVisualizer.reset()
    visualizerID = id
  }

  func cycleVisualizer(by offset: Int = 1) {
    selectVisualizer(
      catalog.nextID(after: visualizerID, by: offset, in: registry.descriptors))
  }

  @discardableResult
  func setVisualizerEnabled(_ enabled: Bool, for id: String) -> Bool {
    let descriptors = registry.descriptors
    guard catalog.setEnabled(enabled, for: id, in: descriptors) else { return false }
    if !enabled, id == visualizerID {
      selectVisualizer(catalog.nextID(after: id, in: descriptors))
    }
    return true
  }

  var colorwayID: String { VFDTheme.shared.colorway.id }

  func selectColorway(_ id: String) {
    VFDTheme.shared.select(id: id)
    VisualizerColorway.store(VFDTheme.shared.colorway.id, in: NightdriveDefaults.current)
  }

  func openVisualizersFolder() {
    registry.folder.createIfNeeded()
    NSWorkspace.shared.open(registry.folder.url)
  }

  func revealVisualizerPlugin(_ id: String) {
    guard let url = registry.pluginURL(for: id) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }
}
