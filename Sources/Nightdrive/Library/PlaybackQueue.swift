import Foundation

enum PlaybackRepeatMode: String, CaseIterable, Codable, Sendable {
  case off
  case all
  case one

  var label: String {
    switch self {
    case .off: String(localized: "Repeat Off")
    case .all: String(localized: "Repeat All")
    case .one: String(localized: "Repeat One")
    }
  }

  var systemImage: String {
    switch self {
    case .off, .all: "repeat"
    case .one: "repeat.1"
    }
  }

  mutating func cycle() {
    switch self {
    case .off: self = .all
    case .all: self = .one
    case .one: self = .off
    }
  }
}

struct PlaybackQueue: Sendable {
  struct HistoryEntry: Sendable {
    var track: LibraryTrack
    var queueIndex: Int?
  }

  static let maxHistory = 200

  private(set) var tracks: [LibraryTrack] = []
  var currentIndex: Int?
  var isShuffleEnabled = false
  var repeatMode: PlaybackRepeatMode = .off
  private(set) var history: [HistoryEntry] = []

  var upNext: [LibraryTrack] {
    guard let currentIndex else { return tracks }
    return Array(tracks.dropFirst(currentIndex + 1))
  }

  var currentTrackNumber: Int? {
    currentIndex.map { $0 + 1 }
  }

  // MARK: - Building and clearing

  mutating func activate(_ track: LibraryTrack, in source: [LibraryTrack]) {
    history = []
    let contents = source.contains(where: { $0.id == track.id }) ? source : [track] + source
    if isShuffleEnabled {
      tracks = [track] + contents.filter { $0.id != track.id }.shuffled()
      currentIndex = 0
    } else {
      tracks = contents
      currentIndex = contents.firstIndex(where: { $0.id == track.id })
    }
  }

  mutating func load(_ savedTracks: [LibraryTrack], currentID: TrackID?) {
    tracks = savedTracks
    currentIndex = currentID.flatMap { id in savedTracks.firstIndex(where: { $0.id == id }) }
  }

  mutating func clear() {
    tracks = []
    currentIndex = nil
    history = []
  }

  // MARK: - Membership edits

  mutating func removeTrack(id trackID: TrackID) {
    let removedBeforeCurrent =
      tracks.prefix(currentIndex ?? 0).filter { $0.id == trackID }.count
    tracks.removeAll { $0.id == trackID }
    if let currentIndex {
      self.currentIndex = max(0, currentIndex - removedBeforeCurrent)
    }
  }

  mutating func replaceTrack(_ track: LibraryTrack) {
    for index in tracks.indices where tracks[index].id == track.id {
      tracks[index] = track
    }
    for index in history.indices where history[index].track.id == track.id {
      history[index].track = track
    }
  }

  /// Retargets queue and history entries whose files moved to new IDs. Each
  /// remapped entry takes the destination's refreshed catalog track so the
  /// queue never holds a stale URL.
  mutating func remapTracks(_ mapping: [TrackID: TrackID], catalog: LibraryCatalog) {
    func remapped(_ track: LibraryTrack) -> LibraryTrack {
      guard let destination = mapping[track.id], let updated = catalog[destination] else {
        return track
      }
      return updated
    }
    for index in tracks.indices {
      tracks[index] = remapped(tracks[index])
    }
    for index in history.indices {
      history[index].track = remapped(history[index].track)
    }
  }

  mutating func insertNext(_ track: LibraryTrack) {
    tracks.insert(track, at: min((currentIndex ?? -1) + 1, tracks.count))
  }

  mutating func append(_ track: LibraryTrack) {
    tracks.append(track)
  }

  mutating func removeUpNext(at offsets: IndexSet) {
    let base = (currentIndex ?? -1) + 1
    for offset in offsets.sorted(by: >) {
      let index = base + offset
      guard tracks.indices.contains(index) else { continue }
      tracks.remove(at: index)
    }
  }

  mutating func moveUpNext(from offsets: IndexSet, to destination: Int) {
    var upcoming = upNext
    let selected = offsets.sorted().compactMap { upcoming.indices.contains($0) ? upcoming[$0] : nil }
    for offset in offsets.sorted(by: >) where upcoming.indices.contains(offset) {
      upcoming.remove(at: offset)
    }
    let removedBeforeDestination = offsets.filter { $0 < destination }.count
    let insertion = min(max(0, destination - removedBeforeDestination), upcoming.count)
    upcoming.insert(contentsOf: selected, at: insertion)
    replaceUpNext(with: upcoming)
  }

  mutating func replaceUpNext(with newTracks: [LibraryTrack]) {
    let prefixCount = (currentIndex.map { $0 + 1 }) ?? 0
    tracks = Array(tracks.prefix(prefixCount)) + newTracks
  }

  // MARK: - Navigation

  mutating func advanceIndex(by delta: Int, automatic: Bool) -> Int? {
    guard let index = currentIndex else { return nil }

    var target = index + delta
    if automatic, repeatMode == .one {
      target = index
    }
    if !tracks.indices.contains(target), repeatMode == .all, !tracks.isEmpty {
      if delta > 0, isShuffleEnabled, tracks.count > 1 {
        let previous = tracks[index]
        tracks.shuffle()
        if tracks.first?.id == previous.id {
          tracks.swapAt(0, 1)
        }
      }
      target = delta > 0 ? tracks.startIndex : tracks.index(before: tracks.endIndex)
    }
    guard tracks.indices.contains(target) else { return nil }
    return target
  }

  mutating func promote(at sourceIndex: Int, recording current: LibraryTrack?) -> LibraryTrack? {
    guard tracks.indices.contains(sourceIndex) else { return nil }
    if currentIndex == nil {
      history = []
      let selected = tracks.remove(at: sourceIndex)
      tracks.insert(selected, at: 0)
      currentIndex = 0
      return selected
    }

    guard let currentIndex else { return nil }
    record(current)
    let selected = tracks.remove(at: sourceIndex)
    let target = min(currentIndex + 1, tracks.endIndex)
    tracks.insert(selected, at: target)
    self.currentIndex = target
    return selected
  }

  mutating func shuffleUpcoming() -> Bool {
    guard let currentIndex else {
      tracks.shuffle()
      return false
    }
    let nextIndex = currentIndex + 1
    guard tracks.indices.contains(nextIndex) else { return false }
    tracks.replaceSubrange(
      nextIndex..<tracks.endIndex,
      with: tracks[nextIndex...].shuffled())
    return true
  }

  // MARK: - History

  mutating func record(_ current: LibraryTrack?) {
    guard let current else { return }
    history.append(HistoryEntry(track: current, queueIndex: currentIndex))
    if history.count > Self.maxHistory {
      history.removeFirst(history.count - Self.maxHistory)
    }
  }

  mutating func popHistory() -> HistoryEntry? {
    history.popLast()
  }

  // MARK: - Lookups

  func index(of track: LibraryTrack, preferring storedIndex: Int?) -> Int? {
    if let storedIndex, tracks.indices.contains(storedIndex),
      tracks[storedIndex].id == track.id
    {
      return storedIndex
    }
    let current = currentIndex ?? tracks.endIndex
    return tracks.indices.last {
      $0 < current && tracks[$0].id == track.id
    } ?? tracks.firstIndex(where: { $0.id == track.id })
  }

  func successorIndices(after index: Int) -> [Int] {
    guard !tracks.isEmpty else { return [] }
    if repeatMode == .one { return [index] }

    var result =
      index + 1 < tracks.endIndex
      ? Array((index + 1)..<tracks.endIndex)
      : []
    if repeatMode == .all, !isShuffleEnabled {
      result.append(contentsOf: tracks.startIndex...index)
    }
    return result
  }

  func recoveryIndex(after index: Int, excluding attempted: Set<Int>) -> Int? {
    if index + 1 < tracks.endIndex {
      return ((index + 1)..<tracks.endIndex).first { !attempted.contains($0) }
    }
    guard repeatMode == .all else { return nil }
    return tracks.indices.first { !attempted.contains($0) }
  }

  // MARK: - Reconciliation

  func reconciled(with catalog: LibraryCatalog) -> (queue: PlaybackQueue, oldToNewIndex: [Int: Int]) {
    var oldToNewIndex: [Int: Int] = [:]
    oldToNewIndex.reserveCapacity(tracks.count)
    var reconciledTracks: [LibraryTrack] = []
    reconciledTracks.reserveCapacity(tracks.count)
    for (oldIndex, track) in tracks.enumerated() {
      guard let refreshed = catalog[track.id] else { continue }
      oldToNewIndex[oldIndex] = reconciledTracks.count
      reconciledTracks.append(refreshed)
    }

    var reconciledHistory: [HistoryEntry] = []
    reconciledHistory.reserveCapacity(history.count)
    for entry in history {
      guard let refreshed = catalog[entry.track.id] else { continue }
      reconciledHistory.append(
        HistoryEntry(
          track: refreshed,
          queueIndex: entry.queueIndex.flatMap { oldToNewIndex[$0] }))
    }

    var reconciled = self
    reconciled.tracks = reconciledTracks
    reconciled.history = reconciledHistory
    reconciled.currentIndex = currentIndex.flatMap { oldToNewIndex[$0] }
    return (reconciled, oldToNewIndex)
  }
}
