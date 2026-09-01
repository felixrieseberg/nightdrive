import Foundation

/// First-party web destinations owned by Nightdrive.
///
/// Keep product links here so moving the repository or the release layout
/// never requires hunting through views and packaging scripts.
enum AppLinks {
  /// The public repository: where the About pane sends people, and where
  /// published releases live.
  static let repository = URL(string: "https://github.com/felixrieseberg/nightdrive")!

  static let releases = repository.appending(path: "releases")

  /// Third-party projects credited in the app's acknowledgments window.
  static let sparkle = URL(string: "https://sparkle-project.org")!
  static let musicBrainz = URL(string: "https://musicbrainz.org")!

  /// Sparkle update feed for the direct-download channel. GitHub keeps this
  /// URL pointing at the newest published release's `appcast.xml` asset, so
  /// `make publish` is the whole update rollout — there is nothing else to
  /// deploy. `scripts/generate-appcast.sh` writes the file it serves.
  static let appcast = releases.appending(path: "latest/download/appcast.xml")
}
