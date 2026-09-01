import AVFoundation
import Foundation
import Synchronization
import Testing

@testable import Nightdrive

@MainActor
final class TranscodeEncoderCancellationTests {
  private var scratch: URL!

  init() throws {
    scratch = TestScratch.directory(prefix: "NightdriveTranscodeCancellation")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: scratch)
  }

  @Test
  func testAACCancellationWaitsForInFlightPumpOperationAndRemovesPartialOutput() async throws {
    let source = scratch.appendingPathComponent("source.flac")
    let destination = scratch.appendingPathComponent("cancelled.m4a")
    try writeAudioFixture(to: source, formatID: kAudioFormatFLAC)
    let sampleRead = OneShotSignal()
    let releaseSampleOperation = DispatchSemaphore(value: 0)
    let sampleOperationReturned = OneShotSignal()
    let encoder = AVFoundationAACEncoder {
      sampleRead.signal()
      releaseSampleOperation.wait()
      sampleOperationReturned.signal()
    }
    let encode = Task<Void, any Error> {
      try await encoder.encode(
        source: source, destination: destination,
        profile: TranscodeProfile(bitrateKbps: 256),
        metadata: metadata(title: "Cancelled AAC"), artwork: nil)
    }

    await sampleRead.wait()

    let outcome = EncoderOutcomeBox()
    let observer = recordOutcome(of: encode, into: outcome)
    encode.cancel()
    let stillPendingDuringSampleOperation = await holds {
      await outcome.value == nil
    }

    releaseSampleOperation.signal()
    await sampleOperationReturned.wait()
    let cancelledAfterOperation = await waitUntil(timeout: .seconds(2)) {
      await outcome.value != nil
    }
    await observer.value
    let finalOutcome = await outcome.value

    #expect(
      stillPendingDuringSampleOperation,
      Comment(rawValue: "cancellation must queue behind an in-flight AVFoundation pump operation"))
    #expect(cancelledAfterOperation, Comment(rawValue: "cancellation should finish after the operation yields"))
    #expect((finalOutcome) == (.cancelled))
    #expect(
      !(FileManager.default.fileExists(atPath: destination.path)),
      Comment(rawValue: "a cancelled AVAssetWriter must not leave a partial output"))
  }

  private func metadata(title: String) -> TrackMetadata {
    TrackMetadata(
      title: title, artist: "Encoder Artist", album: "Encoder Album", albumArtist: "",
      composer: "", genre: "Rock", grouping: "", year: 2026, bpm: 0,
      trackNumber: 1, trackCount: 1, discNumber: 1, discCount: 1,
      comment: "", lyrics: "", compilation: false)
  }
}

private enum EncoderOutcome: Equatable, Sendable {
  case success
  case cancelled
  case failed(String)
}

private actor EncoderOutcomeBox {
  private(set) var value: EncoderOutcome?

  func store(_ value: EncoderOutcome) {
    self.value = value
  }
}

private func recordOutcome(
  of task: Task<Void, any Error>, into outcome: EncoderOutcomeBox
) -> Task<Void, Never> {
  Task {
    do {
      try await task.value
      await outcome.store(.success)
    } catch is CancellationError {
      await outcome.store(.cancelled)
    } catch {
      await outcome.store(.failed(error.localizedDescription))
    }
  }
}

private final class OneShotSignal: Sendable {
  private struct State {
    var isSignaled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  func wait() async {
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state -> Bool in
        if state.isSignaled { return true }
        state.waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }

  func signal() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      guard !state.isSignaled else { return [] }
      state.isSignaled = true
      defer { state.waiters.removeAll() }
      return state.waiters
    }
    for continuation in waiting { continuation.resume() }
  }
}
