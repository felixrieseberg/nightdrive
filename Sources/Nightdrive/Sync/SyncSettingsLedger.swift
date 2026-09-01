import Foundation
import Observation

typealias AppSyncSettingsWriter =
  @Sendable (
    SyncDeviceSettings, UInt64, URL
  ) async throws -> Void

/// The debounced write-through cache for per-device sync settings: reads go
/// through an in-memory cache keyed by library folder and device database ID,
/// writes chain serially onto disk with generation-based error suppression so
/// only the newest write can surface or clear an error.
@Observable
@MainActor
final class SyncSettingsLedger {
  @ObservationIgnored private let library: LibraryStore
  @ObservationIgnored private let writer: AppSyncSettingsWriter
  private(set) var revision: UInt64 = 0
  private(set) var error: String?
  @ObservationIgnored private var cache: [String: SyncDeviceSettings] = [:]
  @ObservationIgnored private var writeTask: Task<Void, Never>?
  @ObservationIgnored private var writeGeneration: UInt64 = 0

  init(
    library: LibraryStore,
    writer: @escaping AppSyncSettingsWriter = { settings, databaseID, folder in
      try await SyncEngine.writeDeviceSettings(
        settings, databaseID: databaseID, libraryFolder: folder)
    }
  ) {
    self.library = library
    self.writer = writer
  }

  func settings(for device: IpodDevice) -> SyncDeviceSettings {
    _ = revision
    guard let folder = library.folderURL, let databaseID = device.databaseID else {
      return SyncDeviceSettings()
    }
    if let cached = cache[key(folder: folder, databaseID: databaseID)] {
      return cached
    }
    guard (try? library.validateAvailableRoot()) != nil else {
      return SyncDeviceSettings()
    }
    let settings = SyncLedgerStore.deviceSettings(for: databaseID, libraryFolder: folder)
    cache[key(folder: folder, databaseID: databaseID)] = settings
    return settings
  }

  func update(for device: IpodDevice, _ mutate: (inout SyncDeviceSettings) -> Void) {
    var settings = settings(for: device)
    mutate(&settings)
    set(settings, for: device)
  }

  func setDisplayName(_ name: String, for device: IpodDevice) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    update(for: device) {
      $0.displayName = (trimmed.isEmpty || trimmed == device.name) ? nil : trimmed
    }
  }

  func displayName(for device: IpodDevice) -> String {
    if let name = settings(for: device).displayName?
      .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
    {
      return name
    }
    return device.name
  }

  private func key(folder: URL, databaseID: UInt64) -> String {
    folder.standardizedFileURL.path + "|" + String(databaseID)
  }

  func invalidateCache(for folder: URL?) {
    guard let folder else { return }
    let prefix = folder.standardizedFileURL.path + "|"
    cache = cache.filter { !$0.key.hasPrefix(prefix) }
    writeGeneration &+= 1
    revision &+= 1
  }

  /// Abandons in-flight write error reporting after the library folder moved.
  func libraryFolderDidChange() {
    writeGeneration &+= 1
    error = nil
  }

  private func set(_ settings: SyncDeviceSettings, for device: IpodDevice) {
    guard let folder = library.folderURL, let databaseID = device.databaseID else { return }
    do {
      _ = try library.validateAvailableRoot()
    } catch {
      // This rejected mutation is newer than every queued write. Prevent an
      // older completion from clearing or replacing the error it produced.
      writeGeneration &+= 1
      self.error = error.localizedDescription
      return
    }
    cache[key(folder: folder, databaseID: databaseID)] = settings
    revision &+= 1
    error = nil
    writeGeneration &+= 1
    let generation = writeGeneration
    let previous = writeTask
    writeTask = Task {
      await previous?.value
      do {
        _ = try library.validateAvailableRoot()
        guard library.folderURL?.standardizedFileURL == folder.standardizedFileURL else {
          throw LibraryStoreError.libraryChanged
        }
        try await writer(settings, databaseID, folder)
        if writeGeneration == generation { error = nil }
      } catch {
        if writeGeneration == generation {
          self.error = error.localizedDescription
        }
      }
    }
  }

  func dismissError() {
    error = nil
  }

  func flushWrites() async {
    await writeTask?.value
  }
}
