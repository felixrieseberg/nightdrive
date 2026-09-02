import Foundation
import Observation

enum OnlineServicesConsent: String, Codable, Sendable {
  case unset
  case enabled
  case disabled
}

@Observable
@MainActor
final class OnlineServicesPolicy {
  private(set) var consent: OnlineServicesConsent = .unset
  private(set) var autoLookup = true
  /// Podcasts default to on: search and feeds are user-initiated browsing,
  /// unlike metadata lookup which inspects the user's own files.
  private(set) var podcastsConsent: OnlineServicesConsent = .enabled
  private(set) var podcastAutoRefresh = true
  private(set) var persistenceError: String?

  @ObservationIgnored private let persistence: any AppDataPersistence
  nonisolated static let defaultsKey = "onlineServicesPolicy"

  private struct PersistedState: Codable {
    var consent: OnlineServicesConsent
    var autoLookup: Bool
    var podcastsConsent: OnlineServicesConsent
    var podcastAutoRefresh: Bool
  }

  init(
    persistence: any AppDataPersistence = UserDefaultsDataPersistence(
      key: OnlineServicesPolicy.defaultsKey)
  ) {
    self.persistence = persistence
    load()
  }

  var isEnabled: Bool { consent == .enabled }

  var isAutoLookupActive: Bool { isEnabled && autoLookup }

  var isPodcastsEnabled: Bool { podcastsConsent == .enabled }

  var isPodcastAutoRefreshActive: Bool { isPodcastsEnabled && podcastAutoRefresh }

  func setConsent(_ consent: OnlineServicesConsent) {
    guard consent != self.consent else { return }
    self.consent = consent
    save()
  }

  func setPodcastsConsent(_ consent: OnlineServicesConsent) {
    guard consent != podcastsConsent else { return }
    podcastsConsent = consent
    save()
  }

  func setPodcastAutoRefresh(_ enabled: Bool) {
    guard enabled != podcastAutoRefresh else { return }
    podcastAutoRefresh = enabled
    save()
  }

  func setAutoLookup(_ enabled: Bool) {
    guard enabled != autoLookup else { return }
    autoLookup = enabled
    save()
  }

  private func load() {
    do {
      guard let state = try persistence.load(PersistedState.self) else { return }
      consent = state.consent
      autoLookup = state.autoLookup
      podcastsConsent = state.podcastsConsent
      podcastAutoRefresh = state.podcastAutoRefresh
    } catch {
      // Unreadable saved state fails closed: the user may have withdrawn a
      // consent this build can no longer read, and subscribed feeds refresh
      // without a user action once podcasts are on. Only save failures
      // surface to the UI.
      consent = .unset
      autoLookup = true
      podcastsConsent = .disabled
      podcastAutoRefresh = false
      NightdriveLog.app.error(
        "Saved online-services policy could not be decoded; using defaults: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  private func save() {
    do {
      try persistence.save(
        PersistedState(
          consent: consent, autoLookup: autoLookup,
          podcastsConsent: podcastsConsent, podcastAutoRefresh: podcastAutoRefresh))
      persistenceError = nil
    } catch {
      persistenceError = error.localizedDescription
    }
  }
}
