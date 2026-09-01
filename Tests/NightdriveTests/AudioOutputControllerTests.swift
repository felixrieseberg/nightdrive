import CoreAudio
import Foundation
import Testing

@testable import Nightdrive

@MainActor
@Suite(.serialized)
struct AudioOutputControllerTests {
  @Test
  func selectedDevicePersistsByUIDAndRoutesByCurrentDeviceID() throws {
    let defaults = try isolatedDefaults()
    let provider = TestAudioOutputProvider(
      snapshot: snapshot(devices: [builtIn, headphones], defaultDeviceID: builtIn.deviceID))
    let output = AudioOutputController(provider: provider, defaults: defaults)

    output.select(headphones.uid)

    #expect(output.selectionID == headphones.uid)
    #expect(defaults.string(forKey: AudioOutputController.selectedUIDDefaultsKey) == headphones.uid)
    #expect(provider.routedDeviceIDs == [builtIn.deviceID, headphones.deviceID])
  }

  @Test
  func missingSavedDeviceDoesNotFallBackToSpeakers() throws {
    let defaults = try isolatedDefaults()
    defaults.set(headphones.uid, forKey: AudioOutputController.selectedUIDDefaultsKey)
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn]))
    let output = AudioOutputController(provider: provider, defaults: defaults)

    #expect(output.selectedDeviceIsMissing)
    #expect(!output.isRouteAvailable)
    #expect(provider.routedDeviceIDs.isEmpty)
    #expect(throws: AudioOutputError.self) { try output.requireAvailableRoute() }
  }

  @Test
  func selectedDeviceDisconnectPausesAndNeverRoutesToNewDefault() throws {
    let defaults = try isolatedDefaults()
    defaults.set(headphones.uid, forKey: AudioOutputController.selectedUIDDefaultsKey)
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn, headphones]))
    let output = AudioOutputController(provider: provider, defaults: defaults)
    var lossNotifications = 0
    output.onRouteWillChange = { lost in
      if lost { lossNotifications += 1 }
    }

    provider.publish(snapshot(devices: [builtIn]))

    #expect(lossNotifications == 1)
    #expect(!output.isRouteAvailable)
    #expect(output.selectedDeviceUID == headphones.uid)
    #expect(provider.routedDeviceIDs == [headphones.deviceID])
  }

  @Test
  func followingSystemDefaultPausesBeforeFailingOverAfterDisconnect() throws {
    let defaults = try isolatedDefaults()
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn, headphones]))
    let output = AudioOutputController(provider: provider, defaults: defaults)
    var losses: [Bool] = []
    output.onRouteWillChange = { losses.append($0) }

    provider.publish(snapshot(devices: [builtIn], defaultDeviceID: builtIn.deviceID))

    #expect(losses == [true])
    #expect(output.isRouteAvailable)
    #expect(output.activeDeviceID == builtIn.deviceID)
    #expect(provider.routedDeviceIDs == [headphones.deviceID, builtIn.deviceID])
  }

  @Test
  func changingAnAvailableSystemDefaultIsNotReportedAsDisconnect() throws {
    let defaults = try isolatedDefaults()
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn, headphones]))
    let output = AudioOutputController(provider: provider, defaults: defaults)
    var losses: [Bool] = []
    output.onRouteWillChange = { losses.append($0) }

    provider.publish(snapshot(devices: [builtIn, headphones], defaultDeviceID: builtIn.deviceID))

    #expect(losses == [false])
    #expect(output.activeDeviceID == builtIn.deviceID)
  }

  @Test
  func reusedCoreAudioDeviceIDDoesNotHideAPhysicalOutputLoss() throws {
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [headphones]))
    let output = AudioOutputController(provider: provider, defaults: try isolatedDefaults())
    let replacement = AudioOutputDevice(
      deviceID: headphones.deviceID, uid: "replacement-output", name: "Replacement",
      transportType: kAudioDeviceTransportTypeBuiltIn)
    var losses: [Bool] = []
    output.onRouteWillChange = { losses.append($0) }

    provider.publish(snapshot(devices: [replacement], defaultDeviceID: replacement.deviceID))

    #expect(losses == [true])
    #expect(output.activeDeviceUID == replacement.uid)
    #expect(provider.routedDeviceIDs == [headphones.deviceID, replacement.deviceID])
  }

  @Test
  func losingAccessToTheDeviceListFailsClosed() throws {
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn, headphones]))
    let output = AudioOutputController(provider: provider, defaults: try isolatedDefaults())
    var lossNotifications = 0
    output.onRouteWillChange = { lost in
      if lost { lossNotifications += 1 }
    }

    provider.failSnapshot()

    #expect(lossNotifications == 1)
    #expect(!output.isRouteAvailable)
  }

  @Test
  func monitoringStopsWhenControllerIsReleased() throws {
    let provider = TestAudioOutputProvider(snapshot: snapshot(devices: [builtIn]))
    weak var released: AudioOutputController?
    do {
      let output = AudioOutputController(provider: provider, defaults: try isolatedDefaults())
      released = output
      #expect(provider.isMonitoring)
    }

    #expect(released == nil)
    #expect(provider.stopMonitoringCount == 1)
  }

  @Test
  func intentionalSwitchKeepsPlayingButSelectedDeviceLossPauses() async throws {
    let defaults = try isolatedDefaults()
    let provider = TestAudioOutputProvider(
      snapshot: snapshot(devices: [builtIn, headphones], defaultDeviceID: headphones.deviceID))
    let player = makePlayer(provider: provider, defaults: defaults)
    let track = try playableTrack()
    defer { try? FileManager.default.removeItem(at: track.url.deletingLastPathComponent()) }
    player.play(track, in: [track])
    await player.waitForPendingPreparation()
    #expect(player.isPlaying)

    player.selectAudioOutput(builtIn.uid)
    #expect(player.isPlaying)
    provider.publish(snapshot(devices: [headphones], defaultDeviceID: headphones.deviceID))

    #expect(!player.isPlaying)
    #expect(player.playbackIssue?.trackTitle == nil)
    #expect(provider.routedDeviceIDs == [headphones.deviceID, builtIn.deviceID])
    player.stop()
  }

  private var builtIn: AudioOutputDevice {
    AudioOutputDevice(
      deviceID: 11, uid: "built-in-output", name: "Mac Speakers",
      transportType: kAudioDeviceTransportTypeBuiltIn)
  }

  private var headphones: AudioOutputDevice {
    AudioOutputDevice(
      deviceID: 42, uid: "headphones-output", name: "Headphones",
      transportType: kAudioDeviceTransportTypeBluetooth)
  }

  private func snapshot(
    devices: [AudioOutputDevice], defaultDeviceID: AudioDeviceID? = 42
  ) -> AudioOutputSnapshot {
    AudioOutputSnapshot(devices: devices, defaultDeviceID: defaultDeviceID)
  }

  private func isolatedDefaults() throws -> UserDefaults {
    let suite = "AudioOutputControllerTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  private func makePlayer(
    provider: TestAudioOutputProvider, defaults: UserDefaults
  ) -> PlayerController {
    PlayerController(
      segmentScheduler: {
        node, file, startingFrame, frameCount, completionType, completion in
        node.scheduleSegment(
          file, startingFrame: startingFrame, frameCount: frameCount, at: nil,
          completionCallbackType: completionType
        ) { _ in completion() }
      },
      maximumFramesPerSegment: .max,
      audioOutputProvider: provider,
      audioOutputDefaults: defaults,
      engineStarter: { _ in })
  }

  private func playableTrack() throws -> LibraryTrack {
    let url = TestScratch.directory().appendingPathComponent("route-switch.mp3")
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try MP3Builder.build(
      tags: .init(
        title: "Route Switch", artist: "Artist", album: "Album", genre: "Genre",
        trackNumber: 1, year: 2026),
      seconds: 1
    ).write(to: url)
    return LibraryTrack(
      url: url, title: "Route Switch", durationMS: 1_000, sizeBytes: 1,
      bitrate: 128, samplerate: 44_100)
  }
}

@MainActor
private final class TestAudioOutputProvider: AudioOutputProviding {
  var currentSnapshot: AudioOutputSnapshot
  private(set) var routedDeviceIDs: [AudioDeviceID] = []
  private(set) var stopMonitoringCount = 0
  private var handler: (@MainActor () -> Void)?
  private var snapshotError: (any Error)?

  init(snapshot: AudioOutputSnapshot) {
    currentSnapshot = snapshot
  }

  func snapshot() throws -> AudioOutputSnapshot {
    if let snapshotError { throw snapshotError }
    return currentSnapshot
  }
  func route(to deviceID: AudioDeviceID) throws { routedDeviceIDs.append(deviceID) }
  func startMonitoring(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
  func stopMonitoring() {
    stopMonitoringCount += 1
    handler = nil
  }

  var isMonitoring: Bool { handler != nil }

  func publish(_ snapshot: AudioOutputSnapshot) {
    currentSnapshot = snapshot
    handler?()
  }

  func failSnapshot() {
    snapshotError = AudioOutputError.unavailable
    handler?()
  }
}
