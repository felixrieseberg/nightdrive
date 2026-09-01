import AppKit
import Foundation
import Observation

@MainActor
struct RecentDocumentOperations {
  let recentURLs: () -> [URL]
  let note: (URL) -> Void
  let clear: () -> Void

  static var appKit: Self {
    Self(
      recentURLs: { NSDocumentController.shared.recentDocumentURLs },
      note: { NSDocumentController.shared.noteNewRecentDocumentURL($0) },
      clear: { NSDocumentController.shared.clearRecentDocuments(nil) })
  }
}

@Observable
@MainActor
final class RecentAudioDocuments {
  private(set) var urls: [URL] = []
  private(set) var canClear = false
  @ObservationIgnored private let operations: RecentDocumentOperations

  init(operations: RecentDocumentOperations = .appKit) {
    self.operations = operations
    refresh()
  }

  func record(_ urls: [URL]) {
    let urls = Self.availableURLs(urls)
    for url in urls.reversed() { operations.note(url) }
    refresh()
  }

  func refresh() {
    let recentURLs = operations.recentURLs()
    urls = Self.availableURLs(recentURLs)
    canClear = !recentURLs.isEmpty
  }

  func clear() {
    operations.clear()
    refresh()
  }

  func urlForOpening(_ url: URL) -> URL? {
    guard let available = Self.availableURL(url) else {
      refresh()
      return nil
    }
    return available
  }

  nonisolated private static func availableURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<URL>()
    return urls.compactMap { url in
      guard let url = availableURL(url), seen.insert(url).inserted else { return nil }
      return url
    }
  }

  nonisolated private static func availableURL(_ url: URL) -> URL? {
    guard url.isFileURL else { return nil }
    let url = url.standardizedFileURL
    guard LibraryAudioFormat(url: url) != nil,
      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else { return nil }
    return url
  }
}
