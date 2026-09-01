import Foundation

// Compiled into every build: the seed-demo CLI relies on it to refuse real iPods.
enum DevelopmentSafety {
  // Destructive tools accept plain directories, never mounted volumes.
  static func isFakeVolume(_ url: URL) -> Bool {
    volumeStatus(url) == false
  }

  // A yet-to-be-created target is safe only when its nearest existing
  // ancestor and every parent below the startup volume are plain directories.
  static func isFakeSeedTarget(
    _ url: URL,
    volumeStatus: (URL) -> Bool? = { DevelopmentSafety.volumeStatus($0) }
  ) -> Bool {
    var probe = url.standardizedFileURL
    while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
      probe = probe.deletingLastPathComponent()
    }
    probe = probe.resolvingSymlinksInPath().standardizedFileURL
    guard probe.pathComponents.count > 1 else { return false }

    while probe.pathComponents.count > 1 {
      guard let isVolume = volumeStatus(probe), !isVolume else { return false }
      probe = probe.deletingLastPathComponent()
    }
    return true
  }

  private static func volumeStatus(_ url: URL) -> Bool? {
    try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume
  }
}

#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit

  extension DevelopmentSafety {
    static func fakeTargetDevice(
      selected: IpodDevice?, devices: [IpodDevice], developmentScanRoots: [URL]
    ) -> IpodDevice? {
      let roots = Set(developmentScanRoots)
      if let selected, roots.contains(selected.volumeURL) {
        return selected
      }
      return devices.first { roots.contains($0.volumeURL) }
    }

    @MainActor
    static func requireFakeVolume(_ url: URL, action: String) -> Bool {
      guard isFakeVolume(url) else {
        DevelopmentAlert.show(
          title: "That is a real volume",
          message: """
            Nightdrive will not \(action) on \(url.path), which is mounted as \
            a volume. Development tools only operate on fake iPods, which are \
            plain directories.
            """)
        return false
      }
      return true
    }

    @MainActor
    static func confirmDestructiveAction(
      on volumeURL: URL, title: String, message: String
    ) -> Bool {
      guard requireFakeVolume(volumeURL, action: "change anything") else { return false }
      return DevelopmentAlert.confirm(title: title, message: message)
    }
  }

  @MainActor
  enum DevelopmentAlert {
    static func show(title: String, message: String) {
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }

    static func confirm(
      title: String, message: String, proceedTitle: String = "Continue"
    ) -> Bool {
      let alert = NSAlert()
      alert.messageText = title
      alert.informativeText = message
      alert.addButton(withTitle: proceedTitle)
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    }

    static func report(_ error: any Error, doing action: String) {
      show(title: "Could not \(action)", message: String(describing: error))
    }
  }

  enum DevelopmentFileRemoval {
    static func removeItemIfPresent(
      at url: URL,
      removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
      do {
        try removeItem(url)
      } catch CocoaError.fileNoSuchFile {
        // Missing is the desired state; every other failure must reach the UI.
      }
    }
  }
#endif
