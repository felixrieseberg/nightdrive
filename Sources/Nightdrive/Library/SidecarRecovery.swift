import Foundation

enum SidecarRecovery {
  enum Sidecar: String, CaseIterable, Sendable {
    case playlists
    case history

    var filename: String {
      switch self {
      case .playlists: return LocalPlaylistFile.filename
      case .history: return ListeningHistoryFile.filename
      }
    }

    func url(for libraryFolder: URL) -> URL {
      libraryFolder.appendingPathComponent(filename)
    }

    var lossDescription: String {
      switch self {
      case .playlists:
        return String(localized: "all local playlists")
      case .history:
        return String(
          localized: "listening history, play counts, favorites, and star ratings")
      }
    }

    fileprivate func probe(libraryFolder: URL) -> Probe {
      switch self {
      case .playlists: return Probe(LocalPlaylistFile.loadOutcome(libraryFolder: libraryFolder))
      case .history: return Probe(ListeningHistoryFile.loadOutcome(libraryFolder: libraryFolder))
      }
    }
  }

  fileprivate enum Probe {
    case missing
    case loaded
    case malformed
    case unreadable(AppDataLoadFailure)

    init<Value>(_ outcome: AppDataLoadOutcome<Value>) {
      switch outcome {
      case .missing: self = .missing
      case .loaded: self = .loaded
      case .malformed: self = .malformed
      case .unreadable(let failure): self = .unreadable(failure)
      }
    }
  }

  enum Refusal: LocalizedError, Equatable {
    case missing(path: String)
    case intact(path: String)
    case unreadable(path: String, reason: String)

    var errorDescription: String? {
      switch self {
      case .missing(let path):
        return String(localized: "\(path) does not exist; there is nothing to reset.")
      case .intact(let path):
        return String(localized: "\(path) is readable; refusing to reset an intact sidecar.")
      case .unreadable(let path, let reason):
        return String(
          localized:
            "\(path) could not be read (\(reason)). That is an access problem, not corruption; restore access instead of resetting."
        )
      }
    }
  }

  static func preview(_ sidecar: Sidecar, libraryFolder: URL) throws -> URL {
    let url = sidecar.url(for: libraryFolder)
    switch sidecar.probe(libraryFolder: libraryFolder) {
    case .missing:
      throw Refusal.missing(path: url.path)
    case .loaded:
      throw Refusal.intact(path: url.path)
    case .unreadable(let failure):
      throw Refusal.unreadable(path: url.path, reason: failure.reason)
    case .malformed:
      return quarantineURL(for: url)
    }
  }

  @discardableResult
  static func reset(_ sidecar: Sidecar, libraryFolder: URL) throws -> URL {
    let destination = try preview(sidecar, libraryFolder: libraryFolder)
    try FileManager.default.moveItem(
      at: sidecar.url(for: libraryFolder), to: destination)
    return destination
  }

  static func quarantineURL(for url: URL) -> URL {
    let base = url.path + ".corrupt"
    var candidate = base
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate) {
      candidate = "\(base)-\(counter)"
      counter += 1
    }
    return URL(fileURLWithPath: candidate)
  }
}
