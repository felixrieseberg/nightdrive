import Foundation
import Observation

@Observable
@MainActor
final class VisualizerCatalog {
  static let disabledDefaultsKey = "visualizersDisabled"
  static let orderDefaultsKey = "visualizersOrder"

  private let defaults: UserDefaults

  private(set) var disabledIDs: Set<String>
  private(set) var order: [String]

  init(defaults: UserDefaults = NightdriveDefaults.current) {
    self.defaults = defaults
    disabledIDs = Set(defaults.stringArray(forKey: Self.disabledDefaultsKey) ?? [])
    let persistedOrder = defaults.stringArray(forKey: Self.orderDefaultsKey) ?? []
    order = Self.deduplicated(persistedOrder)
    if order != persistedOrder {
      defaults.set(order, forKey: Self.orderDefaultsKey)
    }
  }

  // MARK: - Reading

  func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

  func arranged(_ descriptors: [VisualizerDescriptor]) -> [VisualizerDescriptor] {
    guard !order.isEmpty else { return descriptors }
    let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
    return
      descriptors
      .enumerated()
      .sorted { lhs, rhs in
        let left = rank[lhs.element.id] ?? order.count + lhs.offset
        let right = rank[rhs.element.id] ?? order.count + rhs.offset
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }

  func enabled(_ descriptors: [VisualizerDescriptor]) -> [VisualizerDescriptor] {
    let arranged = arranged(descriptors)
    let on = arranged.filter { isEnabled($0.id) }
    return on.isEmpty ? arranged : on
  }

  func canDisable(_ id: String, in descriptors: [VisualizerDescriptor]) -> Bool {
    guard isEnabled(id) else { return true }
    return descriptors.contains { $0.id != id && isEnabled($0.id) }
  }

  func nextID(
    after id: String, by offset: Int = 1, in descriptors: [VisualizerDescriptor]
  ) -> String {
    let pool = enabled(descriptors)
    guard !pool.isEmpty else { return id }
    if let index = pool.firstIndex(where: { $0.id == id }) {
      return pool[Self.wrap(index + offset, count: pool.count)].id
    }

    let all = arranged(descriptors)
    let step = offset < 0 ? -1 : 1
    guard let start = all.firstIndex(where: { $0.id == id }) else {
      return step > 0 ? pool[0].id : pool[pool.count - 1].id
    }
    var probe = start
    for _ in 0..<all.count {
      probe = Self.wrap(probe + step, count: all.count)
      guard let anchor = pool.firstIndex(where: { $0.id == all[probe].id }) else { continue }
      return pool[Self.wrap(anchor + offset - step, count: pool.count)].id
    }
    return pool[0].id
  }

  private static func wrap(_ index: Int, count: Int) -> Int {
    ((index % count) + count) % count
  }

  private static func deduplicated(_ ids: [String]) -> [String] {
    var seen = Set<String>()
    return ids.filter { seen.insert($0).inserted }
  }

  // MARK: - Writing

  @discardableResult
  func setEnabled(_ enabled: Bool, for id: String, in descriptors: [VisualizerDescriptor]) -> Bool {
    if enabled {
      guard disabledIDs.contains(id) else { return true }
      disabledIDs.remove(id)
    } else {
      guard canDisable(id, in: descriptors) else { return false }
      guard !disabledIDs.contains(id) else { return true }
      disabledIDs.insert(id)
    }
    persistDisabled()
    return true
  }

  func enableAll(_ descriptors: [VisualizerDescriptor]) {
    let ids = Set(descriptors.map(\.id))
    guard disabledIDs.contains(where: ids.contains) else { return }
    disabledIDs.subtract(ids)
    persistDisabled()
  }

  func disableAll(_ descriptors: [VisualizerDescriptor], keeping: String? = nil) {
    let arranged = arranged(descriptors)
    guard let survivor = arranged.first(where: { $0.id == keeping })?.id ?? arranged.first?.id
    else { return }
    disabledIDs.formUnion(arranged.map(\.id))
    disabledIDs.remove(survivor)
    persistDisabled()
  }

  func reorder(to arranged: [VisualizerDescriptor]) {
    let ids = arranged.map(\.id)
    let known = Set(ids)
    order = ids + order.filter { !known.contains($0) }
    defaults.set(order, forKey: Self.orderDefaultsKey)
  }

  func resetOrder() {
    guard !order.isEmpty else { return }
    order = []
    defaults.removeObject(forKey: Self.orderDefaultsKey)
  }

  private func persistDisabled() {
    defaults.set(disabledIDs.sorted(), forKey: Self.disabledDefaultsKey)
  }
}
