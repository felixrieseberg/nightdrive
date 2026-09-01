import AudioToolbox
import CoreAudio
import Foundation
import Observation

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  let transportType: UInt32

  var id: String { uid }

  var transportLabel: String? {
    switch transportType {
    case kAudioDeviceTransportTypeAirPlay: String(localized: "AirPlay")
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
      String(localized: "Bluetooth")
    case kAudioDeviceTransportTypeUSB: String(localized: "USB")
    case kAudioDeviceTransportTypeHDMI: String(localized: "HDMI")
    case kAudioDeviceTransportTypeDisplayPort: String(localized: "DisplayPort")
    default: nil
    }
  }

  var displayName: String {
    transportLabel.map { "\(name) · \($0)" } ?? name
  }
}

struct AudioOutputSnapshot: Equatable, Sendable {
  var devices: [AudioOutputDevice]
  var defaultDeviceID: AudioDeviceID?
}

@MainActor
protocol AudioOutputProviding: AnyObject {
  func snapshot() throws -> AudioOutputSnapshot
  func route(to deviceID: AudioDeviceID) throws
  func startMonitoring(_ handler: @escaping @MainActor () -> Void)
  func stopMonitoring()
}

enum AudioOutputError: LocalizedError {
  case unavailable
  case coreAudio(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      String(localized: "The selected audio output is unavailable.")
    case .coreAudio(let status):
      String(localized: "macOS could not configure the audio output (error \(status)).")
    }
  }
}

@Observable
@MainActor
final class AudioOutputController {
  static let systemDefaultSelectionID = "__nightdrive.system-default__"
  static let selectedUIDDefaultsKey = "audioOutput.selectedDeviceUID"

  private(set) var devices: [AudioOutputDevice] = []
  private(set) var defaultDeviceID: AudioDeviceID?
  private(set) var selectedDeviceUID: String?
  private(set) var issue: String?
  private(set) var activeDeviceID: AudioDeviceID?
  private(set) var activeDeviceUID: String?

  @ObservationIgnored var onRouteWillChange: ((_ outputWasLost: Bool) -> Void)?
  @ObservationIgnored var onRouteChanged: (() -> Void)?

  @ObservationIgnored private let provider: any AudioOutputProviding
  @ObservationIgnored private let defaults: UserDefaults

  var selectionID: String { selectedDeviceUID ?? Self.systemDefaultSelectionID }
  var selectedDeviceIsMissing: Bool {
    selectedDeviceUID.map { uid in !devices.contains { $0.uid == uid } } ?? false
  }
  var isRouteAvailable: Bool { activeDeviceID != nil && activeDeviceUID != nil && issue == nil }
  var defaultDeviceName: String? {
    devices.first { $0.deviceID == defaultDeviceID }?.name
  }

  init(
    provider: any AudioOutputProviding,
    defaults: UserDefaults = NightdriveDefaults.current
  ) {
    self.provider = provider
    self.defaults = defaults
    selectedDeviceUID = defaults.string(forKey: Self.selectedUIDDefaultsKey)
    refresh(notify: false)
    provider.startMonitoring { [weak self] in self?.refresh() }
  }

  isolated deinit {
    provider.stopMonitoring()
  }

  func select(_ selectionID: String) {
    let uid = selectionID == Self.systemDefaultSelectionID ? nil : selectionID
    guard uid != selectedDeviceUID else { return }
    selectedDeviceUID = uid
    if let uid {
      defaults.set(uid, forKey: Self.selectedUIDDefaultsKey)
    } else {
      defaults.removeObject(forKey: Self.selectedUIDDefaultsKey)
    }
    refresh(forceRoute: true)
  }

  @discardableResult
  func refresh() -> Bool {
    refresh(forceRoute: false, notify: true)
  }

  /// Re-reads and re-applies the selected Core Audio route after macOS wakes.
  func reconcileAfterSystemWake() {
    refresh(forceRoute: true, notify: false)
  }

  func requireAvailableRoute() throws {
    guard isRouteAvailable else { throw AudioOutputError.unavailable }
  }

  @discardableResult
  private func refresh(forceRoute: Bool = false, notify: Bool = true) -> Bool {
    let snapshot: AudioOutputSnapshot
    do {
      snapshot = try provider.snapshot()
    } catch {
      let outputWasActive = activeDeviceID != nil
      issue = error.localizedDescription
      activeDeviceID = nil
      activeDeviceUID = nil
      if notify, outputWasActive { onRouteWillChange?(true) }
      return false
    }
    let oldActiveDeviceID = activeDeviceID
    let oldActiveDeviceUID = activeDeviceUID
    devices = snapshot.devices.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    defaultDeviceID = snapshot.defaultDeviceID

    let target =
      selectedDeviceUID.flatMap { uid in
        devices.first { $0.uid == uid }
      } ?? (selectedDeviceUID == nil ? devices.first { $0.deviceID == defaultDeviceID } : nil)
    guard let target else {
      issue =
        selectedDeviceUID == nil
        ? String(localized: "No system audio output is available. Playback is paused.")
        : String(localized: "The selected audio output is no longer connected. Playback is paused.")
      activeDeviceID = nil
      activeDeviceUID = nil
      if notify, oldActiveDeviceID != nil { onRouteWillChange?(true) }
      return false
    }
    guard forceRoute || target.deviceID != oldActiveDeviceID || target.uid != oldActiveDeviceUID else {
      issue = nil
      return false
    }

    let outputWasLost =
      oldActiveDeviceUID.map { old in
        !devices.contains { $0.uid == old }
      } ?? false
    if notify { onRouteWillChange?(outputWasLost) }
    do {
      try provider.route(to: target.deviceID)
      activeDeviceID = target.deviceID
      activeDeviceUID = target.uid
      issue = nil
      if notify { onRouteChanged?() }
      return true
    } catch {
      issue = error.localizedDescription
      activeDeviceID = nil
      activeDeviceUID = nil
      return false
    }
  }
}

@MainActor
final class CoreAudioOutputProvider: AudioOutputProviding {
  private let audioUnit: AudioUnit?
  private var handler: (@MainActor () -> Void)?
  private var listener: AudioObjectPropertyListenerBlock?

  init(audioUnit: AudioUnit?) {
    self.audioUnit = audioUnit
  }

  func snapshot() throws -> AudioOutputSnapshot {
    let system = AudioObjectID(kAudioObjectSystemObject)
    let deviceIDs: [AudioDeviceID] = try propertyArray(
      object: system, selector: kAudioHardwarePropertyDevices)
    let devices = deviceIDs.compactMap { deviceID -> AudioOutputDevice? in
      guard (try? hasOutputStreams(deviceID)) == true,
        let uid = try? stringProperty(deviceID, kAudioDevicePropertyDeviceUID),
        let name = try? stringProperty(deviceID, kAudioObjectPropertyName),
        let transportType = try? scalarProperty(deviceID, kAudioDevicePropertyTransportType)
      else { return nil }
      return AudioOutputDevice(
        deviceID: deviceID,
        uid: uid, name: name, transportType: transportType)
    }
    let defaultID: AudioDeviceID = try scalarProperty(
      system, kAudioHardwarePropertyDefaultOutputDevice)
    return AudioOutputSnapshot(
      devices: devices,
      defaultDeviceID: defaultID == kAudioObjectUnknown ? nil : defaultID)
  }

  func route(to deviceID: AudioDeviceID) throws {
    guard let audioUnit else { throw AudioOutputError.unavailable }
    var deviceID = deviceID
    let status = AudioUnitSetProperty(
      audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
      &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
  }

  func startMonitoring(_ handler: @escaping @MainActor () -> Void) {
    stopMonitoring()
    self.handler = handler
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.handler?() }
    }
    self.listener = listener
    for selector in [
      kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
      var address = Self.address(selector)
      AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
  }

  func stopMonitoring() {
    guard let listener else { return }
    for selector in [
      kAudioHardwarePropertyDevices,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
      var address = Self.address(selector)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    }
    self.listener = nil
    handler = nil
  }

  private func hasOutputStreams(_ deviceID: AudioDeviceID) throws -> Bool {
    var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
    var size: UInt32 = 0
    let status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return size >= UInt32(MemoryLayout<AudioStreamID>.size)
  }

  private func stringProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) throws -> String {
    var address = Self.address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr, let value else { throw AudioOutputError.coreAudio(status) }
    return value.takeRetainedValue() as String
  }

  private func scalarProperty(
    _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) throws -> UInt32 {
    var address = Self.address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return value
  }

  private func propertyArray(
    object: AudioObjectID, selector: AudioObjectPropertySelector
  ) throws -> [AudioDeviceID] {
    var address = Self.address(selector)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    guard size > 0 else { return [] }
    var values = [AudioDeviceID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
    status = values.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
    }
    guard status == noErr else { throw AudioOutputError.coreAudio(status) }
    return values
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
}
