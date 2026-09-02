import Foundation

private final class ResourceBundleFinder {}

extension Bundle {
  /// The SwiftPM-generated resource bundle that ships beside the executable,
  /// or `nil` when it cannot be found.
  ///
  /// SwiftPM's own `Bundle.module` traps instead of returning `nil`. That turns
  /// an app bundle whose `Contents/Resources` is missing or half-copied — an
  /// interrupted Finder copy, an incomplete unarchive — into a `SIGTRAP`
  /// during `AppState.init()`, before any window exists to explain the
  /// failure. Every caller here treats its resources as optional, so resolve
  /// the bundle the same way `Bundle.module` does but let a miss stay a miss.
  static let nightdriveResources: Bundle? = {
    let bundleName = "Nightdrive_Nightdrive.bundle"
    let finderBundle = Bundle(for: ResourceBundleFinder.self)
    let candidates = [
      // The app bundle: Contents/Resources.
      Bundle.main.resourceURL,
      finderBundle.resourceURL,
      // A bare executable, such as the CLI run from the build directory.
      Bundle.main.bundleURL,
      // The test runner: the bundle sits beside the .xctest in the products
      // directory.
      finderBundle.bundleURL.deletingLastPathComponent(),
    ]
    for candidate in candidates {
      guard let url = candidate?.appendingPathComponent(bundleName) else { continue }
      if let bundle = Bundle(url: url) { return bundle }
    }
    NightdriveLog.app.error(
      "Resource bundle \(bundleName, privacy: .public) is missing; shipped resources are unavailable."
    )
    return nil
  }()
}
