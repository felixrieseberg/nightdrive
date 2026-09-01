#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import Foundation

  enum DevelopmentDeviceModel: String, CaseIterable, Identifiable {
    case photo
    case fourthGeneration
    case shuffle
    case modernShuffle
    case empty

    var id: String { rawValue }

    var title: String {
      switch self {
      case .photo: "iPod photo (color, with songs)"
      case .fourthGeneration: "iPod 4th Generation (greyscale, with songs)"
      case .shuffle: "iPod shuffle (2nd generation)"
      case .modernShuffle: "iPod shuffle (4th generation, with playlists)"
      case .empty: "Empty iPod (no songs)"
      }
    }

    var folderName: String {
      switch self {
      case .photo: "FakePhoto"
      case .fourthGeneration: "Fake4G"
      case .shuffle: "FakeShuffle"
      case .modernShuffle: "FakeModernShuffle"
      case .empty: "FakeEmpty"
      }
    }

    var modelNumber: String {
      switch self {
      case .photo, .empty: "M9585"
      case .fourthGeneration: "M9282"
      case .shuffle: "MA564"
      case .modernShuffle: "MC584"
      }
    }

    var songs: [DemoSeeder.Song] {
      self == .empty ? [] : DemoSeeder.ipodOnlySongs
    }

    var carriesPlaylists: Bool { self != .shuffle }
  }

  @MainActor
  enum DevelopmentDevices {
    static var root: URL {
      NightdriveAppData.defaultDirectoryURL
        .appendingPathComponent("DevelopmentDevices", isDirectory: true)
    }

    static func volumeURL(for model: DevelopmentDeviceModel) -> URL {
      root.appendingPathComponent(model.folderName, isDirectory: true)
    }

    static func mount(_ model: DevelopmentDeviceModel, app: AppState) async {
      let url = volumeURL(for: model)
      if !IpodFileSystem.isIpodVolume(url) {
        do {
          try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
          try DemoSeeder.seedIpod(
            at: url, model: model.modelNumber, name: model.folderName,
            songs: model.songs, playlists: model.carriesPlaylists)
        } catch {
          DevelopmentAlert.report(error, doing: "create the fake iPod at \(url.path)")
          return
        }
      }
      await app.deviceManager.addDevelopmentScanRoot(url)
      if let device = app.deviceManager.devices.first(where: { $0.volumeURL == url }) {
        app.selection = .device(device.volumeURL)
      }
    }

    static func unmountAll(app: AppState) async {
      if case .device(let url) = app.selection,
        app.deviceManager.developmentScanRootURLs.contains(url)
      {
        app.selection = .library
      }
      await app.deviceManager.removeAllDevelopmentScanRoots()
    }

    static func deleteAll(app: AppState) async {
      guard
        DevelopmentAlert.confirm(
          title: "Delete every fake iPod?",
          message: """
            This removes \(root.path) and everything in it. Real devices and \
            your library are untouched.
            """,
          proceedTitle: "Delete")
      else { return }
      await unmountAll(app: app)
      do {
        try DevelopmentFileRemoval.removeItemIfPresent(at: root)
      } catch {
        DevelopmentAlert.report(error, doing: "delete the fake iPods at \(root.path)")
        return
      }
    }

    // MARK: - Faked device states

    static func fillToNearlyFull(_ device: IpodDevice, app: AppState) async {
      guard
        DevelopmentSafety.requireFakeVolume(device.volumeURL, action: "fake free space")
      else { return }
      let remaining = max(device.totalCapacity / 20, 1 * 1024 * 1024)
      await app.deviceManager.setDevelopmentAvailableCapacity(
        remaining, for: device.volumeURL)
    }

    static func fillCompletely(_ device: IpodDevice, app: AppState) async {
      guard
        DevelopmentSafety.requireFakeVolume(device.volumeURL, action: "fake free space")
      else { return }
      await app.deviceManager.setDevelopmentAvailableCapacity(0, for: device.volumeURL)
    }

    static func restoreRealCapacity(_ device: IpodDevice, app: AppState) async {
      await app.deviceManager.setDevelopmentAvailableCapacity(nil, for: device.volumeURL)
    }

    static func simulateWriteFailure(_ device: IpodDevice, app: AppState) async {
      guard
        DevelopmentSafety.requireFakeVolume(device.volumeURL, action: "fake a write failure")
      else { return }
      await app.deviceManager.setDevelopmentWriteError(
        "Simulated from Develop ▸ Devices. This iPod's database is not really "
          + "read-only.", for: device.volumeURL)
    }

    static func clearWriteFailure(_ device: IpodDevice, app: AppState) async {
      await app.deviceManager.setDevelopmentWriteError(nil, for: device.volumeURL)
    }

    static func corruptDatabase(_ device: IpodDevice, app: AppState) async {
      guard
        DevelopmentSafety.confirmDestructiveAction(
          on: device.volumeURL,
          title: "Corrupt this fake iPod's database?",
          message: """
            The iTunesDB on \(device.volumeURL.lastPathComponent) will be \
            overwritten with garbage so the repair flow has something to fix. \
            The audio files stay where they are.
            """)
      else { return }
      let fs = IpodFileSystem(volumeURL: device.volumeURL)
      let target =
        FileManager.default.fileExists(atPath: fs.databaseURL.path)
        ? fs.databaseURL : fs.compressedDatabaseURL
      do {
        try Data("not an iTunesDB".utf8).write(to: target)
      } catch {
        DevelopmentAlert.report(error, doing: "corrupt \(target.lastPathComponent)")
        return
      }
      await app.deviceManager.reload(device)
    }
  }
#endif
