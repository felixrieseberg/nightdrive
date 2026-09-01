import AppKit
import Observation
import UniformTypeIdentifiers

enum DefaultAudioAppStatus: Equatable {
  case unavailable
  case none
  case some
  case all
}

struct DefaultAudioAppChangeFailure: Identifiable {
  let id = UUID()
  let changedCount: Int
  let failedCount: Int
  let underlyingDescription: String

  var title: String {
    if changedCount > 0 {
      String(localized: "Some File Associations Couldn’t Be Changed")
    } else {
      String(localized: "File Associations Couldn’t Be Changed")
    }
  }

  var message: String {
    let summary =
      if changedCount > 0 {
        String(localized: "Nightdrive changed some file associations, but not all of them.")
      } else {
        String(localized: "Nightdrive couldn’t change any file associations.")
      }
    return "\(summary) \(underlyingDescription)"
  }
}

struct DefaultAudioAppOperations {
  var applicationURL: URL?
  var defaultApplicationURL: @MainActor (UTType) -> URL?
  var setDefaultApplication: @MainActor (URL, UTType) async throws -> Void

  @MainActor
  static var live: Self {
    let bundleURL = Bundle.main.bundleURL
    return Self(
      applicationURL: bundleURL.pathExtension == "app" ? bundleURL : nil,
      defaultApplicationURL: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
      setDefaultApplication: { applicationURL, contentType in
        try await NSWorkspace.shared.setDefaultApplication(
          at: applicationURL, toOpen: contentType)
      })
  }
}

@Observable
@MainActor
final class DefaultAudioAppController {
  private(set) var status: DefaultAudioAppStatus = .unavailable
  private(set) var isRequesting = false
  var isPromptPresented = false

  @ObservationIgnored private let operations: DefaultAudioAppOperations
  @ObservationIgnored private let defaults: UserDefaults

  private static let offeredDefaultsKey = "offeredDefaultAudioApp"

  init(
    operations: DefaultAudioAppOperations = .live,
    defaults: UserDefaults = NightdriveDefaults.current
  ) {
    self.operations = operations
    self.defaults = defaults
    refresh()
  }

  func refresh() {
    guard let applicationURL = operations.applicationURL,
      !AudioFileOpening.contentTypes.isEmpty
    else {
      status = .unavailable
      return
    }
    let matching = AudioFileOpening.contentTypes.count { contentType in
      guard let defaultURL = operations.defaultApplicationURL(contentType) else { return false }
      return Self.sameApplication(defaultURL, applicationURL)
    }
    switch matching {
    case 0: status = .none
    case AudioFileOpening.contentTypes.count: status = .all
    default: status = .some
    }
  }

  func offerAtLaunchIfNeeded() {
    guard operations.applicationURL != nil,
      !defaults.bool(forKey: Self.offeredDefaultsKey)
    else { return }
    refresh()
    if status == .all {
      recordOfferAnswered()
    } else {
      isPromptPresented = true
    }
  }

  func declinePrompt() {
    isPromptPresented = false
    recordOfferAnswered()
  }

  func makeDefault() async -> DefaultAudioAppChangeFailure? {
    guard !isRequesting, let applicationURL = operations.applicationURL else { return nil }
    isPromptPresented = false
    recordOfferAnswered()
    isRequesting = true
    defer { isRequesting = false }

    var changedCount = 0
    var failures: [Error] = []
    for contentType in AudioFileOpening.contentTypes {
      if let current = operations.defaultApplicationURL(contentType),
        Self.sameApplication(current, applicationURL)
      {
        continue
      }
      do {
        try await operations.setDefaultApplication(applicationURL, contentType)
        changedCount += 1
      } catch {
        failures.append(error)
      }
    }
    refresh()
    guard let firstFailure = failures.first else { return nil }
    return DefaultAudioAppChangeFailure(
      changedCount: changedCount,
      failedCount: failures.count,
      underlyingDescription: firstFailure.localizedDescription)
  }

  private static func sameApplication(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.canonicalFileURL.path.caseInsensitiveCompare(rhs.canonicalFileURL.path) == .orderedSame
  }

  private func recordOfferAnswered() {
    defaults.set(true, forKey: Self.offeredDefaultsKey)
  }
}
