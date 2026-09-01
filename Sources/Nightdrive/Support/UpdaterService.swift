import Sparkle
import SwiftUI

/// Sparkle-backed update checking for the notarized direct download.
///
/// The updater stays inert unless the bundle carries the Sparkle signing key
/// (`SUPublicEDKey`, stamped by `scripts/package-developer-id.sh`), so builds
/// made from source — including every development and test run — never check
/// for updates and never show the update UI.
@Observable
@MainActor
final class UpdaterService {
  /// True when this bundle is an update-capable, distribution-signed build.
  let isAvailable: Bool

  /// Mirrors Sparkle's own gate so the menu item disables while a check or
  /// install is already in flight.
  private(set) var canCheckForUpdates = false

  /// Sparkle owns persistence for this preference. Packaged builds set its
  /// initial default in Info.plist; later changes belong to the user.
  private(set) var automaticallyChecksForUpdates = false

  @ObservationIgnored private var controller: SPUStandardUpdaterController?
  @ObservationIgnored private let feedDelegate = SparkleFeedDelegate()
  @ObservationIgnored private var observations: [NSKeyValueObservation] = []

  init(bundle: Bundle = .main) {
    isAvailable = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") is String
    guard isAvailable else { return }

    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: feedDelegate,
      userDriverDelegate: nil)
    self.controller = controller

    canCheckForUpdates = controller.updater.canCheckForUpdates
    automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
    observations = [
      observe(controller.updater, \.canCheckForUpdates) { $0.canCheckForUpdates = $1 },
      observe(controller.updater, \.automaticallyChecksForUpdates) {
        $0.automaticallyChecksForUpdates = $1
      },
    ]
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }

  func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    controller?.updater.automaticallyChecksForUpdates = enabled
  }

  /// Sparkle publishes its state through KVO, which can fire off the main
  /// thread. Hop back before touching observable storage.
  private func observe(
    _ updater: SPUUpdater,
    _ keyPath: KeyPath<SPUUpdater, Bool>,
    apply: @escaping @MainActor (UpdaterService, Bool) -> Void
  ) -> NSKeyValueObservation {
    updater.observe(keyPath, options: [.new]) { [weak self] _, change in
      guard let value = change.newValue else { return }
      Task { @MainActor in
        guard let self else { return }
        apply(self, value)
      }
    }
  }
}

/// Supplies the appcast location from Swift so first-party URLs stay in
/// `AppLinks` instead of a packaging script's Info.plist.
private final class SparkleFeedDelegate: NSObject, SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    AppLinks.appcast.absoluteString
  }
}

/// "Check for Updates…" menu item; renders nothing in builds that cannot
/// update themselves.
struct CheckForUpdatesButton: View {
  let updater: UpdaterService

  var body: some View {
    if updater.isAvailable {
      Button("Check for Updates…") {
        updater.checkForUpdates()
      }
      .disabled(!updater.canCheckForUpdates)
    }
  }
}
