#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import AVFoundation
  import CoreMedia
  import Foundation
  import Observation
  import os
  @preconcurrency import ScreenCaptureKit

  @MainActor
  @Observable
  final class DemoWindowRecorder: NSObject {
    enum State: Equatable {
      case idle
      case preparing(URL)
      case recording(URL)
      case finishing(URL)
      case finished(URL)
      case failed(String)
    }

    private(set) var state: State = .idle
    var isActive: Bool {
      if stream != nil { return true }
      if case .preparing = state { return true }
      return false
    }

    var statusLabel: String {
      switch state {
      case .idle: "video off"
      case .preparing: "preparing video…"
      case .recording: "recording video"
      case .finishing: "saving video…"
      case .finished: "video saved"
      case .failed: "video failed"
      }
    }

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var recordingOutput: SCRecordingOutput?
    @ObservationIgnored private var pendingOutputURL: URL?
    @ObservationIgnored private var didFinishRecording = false
    @ObservationIgnored private var finishContinuation: CheckedContinuation<Void, Never>?

    func start(window: NSWindow, trackTitle: String, showsSystemCursor: Bool) async throws {
      guard stream == nil else {
        throw DemoRecordingError.alreadyRecording
      }

      let url = try Self.makeOutputURL(for: trackTitle)
      pendingOutputURL = url
      didFinishRecording = false
      state = .preparing(url)

      do {
        let content = try await Self.withCaptureTimeout { try await SCShareableContent.currentProcess }
        try Task.checkCancellation()
        guard state == .preparing(url) else { throw CancellationError() }
        guard window.windowNumber > 0,
          let capturableWindow = content.windows.first(where: {
            $0.windowID == CGWindowID(window.windowNumber)
          })
        else {
          throw DemoRecordingError.windowUnavailable
        }

        let scale = max(window.backingScaleFactor, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = Self.evenPixelCount(capturableWindow.frame.width * scale)
        configuration.height = Self.evenPixelCount(capturableWindow.frame.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 8
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.showsCursor = showsSystemCursor
        configuration.showMouseClicks = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = true
        configuration.captureResolution = .best
        configuration.streamName = "Nightdrive Demo"

        let filter = SCContentFilter(desktopIndependentWindow: capturableWindow)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = url
        outputConfiguration.videoCodecType = .h264
        outputConfiguration.outputFileType = .mp4
        let output = SCRecordingOutput(configuration: outputConfiguration, delegate: self)

        try stream.addRecordingOutput(output)
        self.stream = stream
        recordingOutput = output
        do {
          try await Self.withCaptureTimeout { try await stream.startCapture() }
        } catch is CaptureTimeout {
          Task { try? await stream.stopCapture() }
          throw DemoRecordingError.captureTimedOut
        }
        if state == .preparing(url) {
          state = .recording(url)
        } else if state != .recording(url) {
          if self.stream !== stream {
            try? await stream.stopCapture()
            if state != .finished(url) {
              FileManager.default.bestEffortRemoveItem(at: url)
            }
          }
          throw CancellationError()
        }
      } catch is CancellationError {
        await abandonStart(url)
        throw CancellationError()
      } catch {
        if state == .preparing(url) {
          fail(error)
        }
        throw error
      }
    }

    private func abandonStart(_ url: URL) async {
      guard state == .preparing(url) else { return }
      if let stream { try? await stream.stopCapture() }
      if state == .preparing(url) {
        cancelPendingStart()
      }
    }

    @discardableResult
    func stop() async -> URL? {
      guard let stream else {
        if case .preparing = state {
          cancelPendingStart()
        }
        return completedURL
      }

      let url = pendingOutputURL
      if let url { state = .finishing(url) }

      do {
        try await stream.stopCapture()
      } catch {
        self.stream = nil
        recordingOutput = nil
        pendingOutputURL = nil
        state = .failed(error.localizedDescription)
        DemoLog.note("video recording failed: \(error.localizedDescription)")
        return nil
      }

      self.stream = nil
      await waitForRecordingFinish(timeout: 10)
      recordingOutput = nil
      pendingOutputURL = nil

      guard let url else { return nil }
      let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard bytes > 0 else {
        FileManager.default.bestEffortRemoveItem(at: url)
        let error = DemoRecordingError.emptyRecording
        state = .failed(error.localizedDescription)
        DemoLog.note("video recording failed: \(error.localizedDescription)")
        return nil
      }
      state = .finished(url)
      DemoLog.note("video saved to \(url.path)")
      return url
    }

    static func suggestedFileName(for trackTitle: String, at date: Date = Date()) -> String {
      let timestamp = DateFormatter.demoRecordingTimestamp.string(from: date)
      let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
      let safeTitle =
        trackTitle
        .components(separatedBy: invalid)
        .joined(separator: "-")
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")

      let title = safeTitle.isEmpty ? "Demo" : safeTitle
      return "\(timestamp) — \(title).mp4"
    }

    private var completedURL: URL? {
      if case .finished(let url) = state { return url }
      return nil
    }

    private func waitForRecordingFinish(timeout: Double) async {
      guard !didFinishRecording, recordingOutput != nil else { return }
      await withCheckedContinuation { continuation in
        finishContinuation = continuation
        Task { @MainActor [weak self] in
          await Task.pause(for: .seconds(timeout))
          self?.resumeFinishWait()
        }
      }
    }

    private func resumeFinishWait() {
      finishContinuation?.resume()
      finishContinuation = nil
    }

    private static func makeOutputURL(for trackTitle: String) throws -> URL {
      let directory: URL
      if let override = ProcessInfo.processInfo.environment["NIGHTDRIVE_DEMO_OUTPUT_DIR"],
        !override.isEmpty
      {
        directory = URL(filePath: override, directoryHint: .isDirectory)
      } else {
        guard let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        else { throw DemoRecordingError.moviesFolderUnavailable }
        directory = movies.appending(path: "Nightdrive Demos", directoryHint: .isDirectory)
      }
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      let fileName = suggestedFileName(for: trackTitle)
      var candidate = directory.appending(path: fileName)
      var suffix = 2
      while FileManager.default.fileExists(atPath: candidate.path) {
        let stem = URL(filePath: fileName).deletingPathExtension().lastPathComponent
        candidate = directory.appending(path: "\(stem) \(suffix).mp4")
        suffix += 1
      }
      return candidate
    }

    private static func evenPixelCount(_ value: CGFloat) -> Int {
      let pixels = max(2, Int(value.rounded()))
      return pixels.isMultiple(of: 2) ? pixels : pixels - 1
    }

    private struct CaptureTimeout: Error {}

    private static func withCaptureTimeout<T: Sendable>(
      seconds: Double = 15, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
      try await withCheckedThrowingContinuation { continuation in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        func resumeOnce(_ result: Result<T, any Error>) {
          let first = resumed.withLock { done in
            defer { done = true }
            return !done
          }
          if first { continuation.resume(with: result) }
        }
        Task {
          do { resumeOnce(.success(try await operation())) } catch { resumeOnce(.failure(error)) }
        }
        Task {
          await Task.pause(for: .seconds(seconds))
          resumeOnce(.failure(CaptureTimeout()))
        }
      }
    }

    private func fail(_ error: any Error) {
      if let url = pendingOutputURL {
        FileManager.default.bestEffortRemoveItem(at: url)
      }
      stream = nil
      recordingOutput = nil
      pendingOutputURL = nil
      state = .failed(error.localizedDescription)
      DemoLog.note("video recording failed: \(error.localizedDescription)")
      resumeFinishWait()
    }

    private func cancelPendingStart() {
      if let pendingOutputURL {
        FileManager.default.bestEffortRemoveItem(at: pendingOutputURL)
      }
      stream = nil
      recordingOutput = nil
      pendingOutputURL = nil
      state = .idle
    }
  }

  extension DemoWindowRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
      Task { @MainActor [weak self] in
        guard let self, let url = self.pendingOutputURL else { return }
        self.state = .recording(url)
      }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.didFinishRecording = true
        self.resumeFinishWait()
      }
    }

    nonisolated func recordingOutput(
      _ recordingOutput: SCRecordingOutput, didFailWithError error: any Error
    ) {
      Task { @MainActor [weak self] in
        self?.fail(error)
      }
    }
  }

  extension DemoWindowRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
      Task { @MainActor [weak self] in
        self?.fail(error)
      }
    }
  }

  private enum DemoRecordingError: LocalizedError {
    case alreadyRecording
    case windowUnavailable
    case moviesFolderUnavailable
    case emptyRecording
    case captureTimedOut

    var errorDescription: String? {
      switch self {
      case .alreadyRecording: "A demo video is already being recorded."
      case .windowUnavailable: "The app window is not available for recording."
      case .moviesFolderUnavailable: "The Movies folder is not available."
      case .emptyRecording: "The demo recording did not contain any video frames."
      case .captureTimedOut:
        "The screen capture did not start in time — is the display asleep?"
      }
    }
  }

  extension DateFormatter {
    fileprivate static let demoRecordingTimestamp: DateFormatter = {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
      return formatter
    }()
  }
#endif
