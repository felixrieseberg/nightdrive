#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI

  @MainActor
  struct DemoTrack: Identifiable {
    let id: String
    let title: String
    var estimatedDuration: Double = 60
    var phases: [String] = []
    let run: @MainActor (DemoScriptContext) async throws -> Void
  }

  struct DemoScriptError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  @MainActor
  @Observable
  final class DemoModeController {
    private(set) var activeTrackID: String?
    private(set) var activeTrackTitle: String?
    private(set) var startedAt: Date?
    private(set) var estimatedDuration: Double = 0
    private(set) var phases: [String] = []
    private(set) var phaseIndex: Int?
    let cursor = DemoCursor()
    let stage = DemoStage()
    let recorder = DemoWindowRecorder()

    var automaticallyRecordsVideo =
      NightdriveDefaults.current.object(forKey: "demo.automaticallyRecordsVideo") as? Bool ?? true
    {
      didSet {
        NightdriveDefaults.current.set(
          automaticallyRecordsVideo, forKey: "demo.automaticallyRecordsVideo")
      }
    }
    private(set) var lastRecordingURL: URL?
    private(set) var lastRunError: String?

    var isRunning: Bool { activeTrackID != nil }
    var isSettled: Bool { !isRunning && !recorder.isActive }
    var currentPhase: String? {
      guard let phaseIndex, phases.indices.contains(phaseIndex) else { return nil }
      return phases[phaseIndex]
    }

    @ObservationIgnored private weak var app: AppState?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var recordingStopTask: Task<Void, Never>?
    @ObservationIgnored private var escapeMonitor: Any?
    @ObservationIgnored private let progressPanel = DemoProgressPanel()
    @ObservationIgnored private var runGeneration = 0

    init(app: AppState) {
      self.app = app
    }

    func run(_ track: DemoTrack) {
      guard let app else { return }
      stop()
      let previousRecordingStop = recordingStopTask
      runTask = Task { @MainActor [weak self] in
        await previousRecordingStop?.value
        guard let self, !Task.isCancelled else { return }
        self.begin(track, app: app)
      }
    }

    private func begin(_ track: DemoTrack, app: AppState) {
      runGeneration += 1
      let generation = runGeneration
      activeTrackID = track.id
      activeTrackTitle = track.title
      lastRunError = nil
      startedAt = Date()
      estimatedDuration = track.estimatedDuration
      phases = track.phases
      phaseIndex = nil
      DemoSimulation.begin()
      installEscapeMonitor()
      progressPanel.show(for: self)
      if let window = DemoInput.mainWindow, !window.isKeyWindow {
        window.makeKey()
      }
      let context = DemoScriptContext(app: app, cursor: cursor, stage: stage, controller: self)
      runTask = Task { @MainActor [weak self] in
        do {
          if self?.automaticallyRecordsVideo == true, let window = DemoInput.mainWindow {
            self?.stage.showCaptureBadgeMask()
            self?.stage.prepareWindowForRecording()
            do {
              try await self?.recorder.start(
                window: window, trackTitle: track.title,
                showsSystemCursor: self?.cursor.useRealCursor == true)
            } catch {
              if self?.runGeneration == generation {
                self?.stage.hideCaptureBadgeMask()
              }
              if !(error is CancellationError) {
                DemoLog.note(
                  "continuing track \(track.id) without video: \(error.localizedDescription)")
              }
            }
          }
          try Task.checkCancellation()
          try await track.run(context)
        } catch is CancellationError {
        } catch {
          self?.lastRunError = error.localizedDescription
          DemoLog.note("track \(track.id) failed: \(error.localizedDescription)")
        }
        self?.finish(ifCurrent: generation)
      }
    }

    func stop() {
      runTask?.cancel()
      runTask = nil
      finish()
    }

    func enterPhase(_ title: String) {
      DemoLog.note("phase: \(title)")
      if let index = phases.firstIndex(of: title) {
        phaseIndex = index
      } else {
        phases.append(title)
        phaseIndex = phases.count - 1
      }
    }

    private func finish(ifCurrent generation: Int) {
      guard generation == runGeneration else { return }
      finish()
    }

    private func finish() {
      guard activeTrackID != nil else { return }
      runGeneration += 1
      activeTrackID = nil
      activeTrackTitle = nil
      startedAt = nil
      phases = []
      phaseIndex = nil
      cursor.visible = false
      cursor.pressed = false
      DemoSimulation.end()
      removeEscapeMonitor()
      progressPanel.hide()
      Task { @MainActor in
        await DemoTracks.runPendingCleanups()
      }
      if recorder.isActive {
        recordingStopTask = Task { @MainActor [weak self] in
          guard let self else { return }
          if let url = await self.recorder.stop() {
            self.lastRecordingURL = url
            if !DemoAutoRun.isArmed {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
          self.stage.reset()
        }
      } else {
        stage.reset()
      }
    }

    private func installEscapeMonitor() {
      removeEscapeMonitor()
      escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
        [weak self] event in
        guard event.keyCode == 53, self?.isRunning == true else { return event }
        self?.stop()
        return nil
      }
    }

    private func removeEscapeMonitor() {
      if let escapeMonitor {
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
      }
    }

    func revealLastRecording() {
      guard let lastRecordingURL else { return }
      NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL])
    }
  }

  @MainActor
  final class DemoScriptContext {
    let app: AppState
    let cursor: DemoCursor
    let stage: DemoStage
    private let targets = DemoTargetRegistry.shared
    private weak var controller: DemoModeController?

    init(
      app: AppState, cursor: DemoCursor, stage: DemoStage,
      controller: DemoModeController? = nil
    ) {
      self.app = app
      self.cursor = cursor
      self.stage = stage
      self.controller = controller
    }

    func phase(_ title: String) {
      controller?.enterPhase(title)
    }

    // MARK: Time

    func hold(_ seconds: Double) async throws {
      try await Task.sleep(for: .milliseconds(Int64(seconds * 1000)))
    }

    // MARK: Cursor

    func showCursor() {
      cursor.visible = true
    }

    func point(of targetID: String, at anchor: UnitPoint = .center) -> CGPoint? {
      guard let frame = targets.frame(of: targetID) else { return nil }
      return CGPoint(
        x: frame.minX + frame.width * anchor.x,
        y: frame.minY + frame.height * anchor.y)
    }

    func moveCursor(to destination: CGPoint, duration: Double? = nil) async throws {
      cursor.visible = true
      let start = cursor.position
      let distance = hypot(destination.x - start.x, destination.y - start.y)
      guard distance > 0.5 else {
        cursor.position = destination
        return
      }
      let seconds = duration ?? min(max(Double(distance) / 900, 0.28), 0.9)
      let frames = max(Int(seconds * 60), 2)
      for frame in 1...frames {
        try Task.checkCancellation()
        let t = Double(frame) / Double(frames)
        let eased = t * t * (3 - 2 * t)
        cursor.position = CGPoint(
          x: start.x + (destination.x - start.x) * eased,
          y: start.y + (destination.y - start.y) * eased)
        try await Task.sleep(for: .milliseconds(Int64(seconds * 1000 / Double(frames))))
      }
      cursor.position = destination
    }

    func moveCursor(
      to targetID: String, at anchor: UnitPoint = .center, duration: Double? = nil
    ) async throws {
      guard let destination = try await waitForTargetPoint(targetID, at: anchor) else {
        throw DemoScriptError(message: "Target \(targetID) never appeared.")
      }
      try await moveCursor(to: destination, duration: duration)
    }

    // MARK: Clicking

    func click(_ targetID: String, at anchor: UnitPoint = .center) async throws {
      guard let destination = try await waitForTargetPoint(targetID, at: anchor) else {
        throw DemoScriptError(message: "Click target \(targetID) never appeared.")
      }
      try await moveCursor(to: destination)
      let point = self.point(of: targetID, at: anchor) ?? destination
      try await moveCursor(to: point, duration: 0.05)
      let action = DemoTargetRegistry.shared.action(of: targetID)
      try await pressAndRelease(at: point, action: action)
    }

    func click(
      _ targetID: String, at anchor: UnitPoint = .center,
      performing action: @escaping @MainActor () -> Void
    ) async throws {
      guard let destination = try await waitForTargetPoint(targetID, at: anchor) else {
        throw DemoScriptError(message: "Click target \(targetID) never appeared.")
      }
      try await moveCursor(to: destination)
      let point = self.point(of: targetID, at: anchor) ?? destination
      try await moveCursor(to: point, duration: 0.05)
      try await pressAndRelease(at: point, action: action)
    }

    /// Clicks a menu button, leaves its menu open for `linger` seconds, and
    /// selects the item with the given title (or dismisses without a
    /// selection when nil).
    func flashMenu(_ targetID: String, linger: Double, selecting itemTitle: String? = nil)
      async throws
    {
      guard let destination = try await waitForTargetPoint(targetID, at: .center) else {
        throw DemoScriptError(message: "Menu target \(targetID) never appeared.")
      }
      try await moveCursor(to: destination)
      let point = self.point(of: targetID) ?? destination
      try await moveCursor(to: point, duration: 0.05)
      cursor.pressed = true
      cursor.clickPulse += 1
      try await hold(0.09)
      DemoInput.flashOpenMenu(at: point, linger: linger, selecting: itemTitle)
      cursor.pressed = false
      // A SwiftUI menu can begin tracking a run-loop turn after the click;
      // cover the linger here so the selection lands before the script
      // moves on in that case.
      try await hold(linger + 0.4)
    }

    /// Clicks the topmost instance of a repeated target that lies fully on
    /// screen — lazily materialized rows below the fold also register, and
    /// "latest updated" would happily pick one of those. Returns false when
    /// no instance is visible.
    @discardableResult
    func clickFirstVisible(_ targetID: String, topMargin: Double = 60) async throws -> Bool {
      guard let window = DemoInput.mainWindow else { return false }
      let height = window.frame.height
      let candidates = DemoTargetRegistry.shared.targets(of: targetID)
        .filter { $0.frame.minY > topMargin && $0.frame.maxY < height - 24 }
        .sorted { $0.frame.minY < $1.frame.minY }
      guard let target = candidates.first else { return false }
      let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
      try await moveCursor(to: point)
      try await pressAndRelease(at: point, action: target.action)
      return true
    }

    private func pressAndRelease(at point: CGPoint, action: (() -> Void)? = nil) async throws {
      cursor.pressed = true
      cursor.clickPulse += 1
      try await hold(0.09)
      if let action {
        action()
      } else {
        DemoInput.mouseDown(at: point)
        try await hold(0.05)
        DemoInput.mouseUp(at: point)
        DemoInput.focusTextInput(at: point)
      }
      cursor.pressed = false
      try await hold(0.12)
    }

    // MARK: Scrolling

    func scroll(by pixels: Double, duration: Double = 1.0) async throws {
      cursor.visible = true
      let frames = max(Int(duration * 60), 2)
      var delivered = 0.0
      for frame in 1...frames {
        try Task.checkCancellation()
        let t = Double(frame) / Double(frames)
        let eased = t * t * (3 - 2 * t)
        let target = pixels * eased
        let delta = target - delivered
        delivered = target
        DemoInput.scroll(at: cursor.position, byY: delta)
        try await Task.sleep(for: .milliseconds(Int64(duration * 1000 / Double(frames))))
      }
    }

    // MARK: Editing

    func cut(settle: Double = 0.35, _ change: @MainActor () -> Void) async throws {
      cursor.visible = false
      change()
      try await hold(settle)
    }

    func showEndCard() async throws {
      try await dip(to: 1, duration: 0.25, fadesWindowChrome: true)
      cursor.visible = false
      stage.endCardVisible = true
      stage.coverWindowChrome()
      try await hold(0.15)
      try await dip(to: 0, duration: 0.4)
    }

    private func dip(
      to target: Double, duration: Double, fadesWindowChrome: Bool = false
    ) async throws {
      let start = stage.dipOpacity
      let frames = max(Int(duration * 60), 2)
      for frame in 1...frames {
        try Task.checkCancellation()
        let t = Double(frame) / Double(frames)
        let eased = t * t * (3 - 2 * t)
        stage.dipOpacity = start + (target - start) * eased
        if fadesWindowChrome {
          stage.setWindowChromeOpacity(1 - stage.dipOpacity)
        }
        try await Task.sleep(for: .milliseconds(Int64(duration * 1000 / Double(frames))))
      }
      stage.dipOpacity = target
      if fadesWindowChrome {
        stage.setWindowChromeOpacity(1 - target)
      }
    }

    // MARK: Waiting

    func waitUntil(
      timeout: Double = 30, description: String = "the next demo state",
      _ condition: @MainActor () -> Bool
    ) async throws {
      let deadline = Date().addingTimeInterval(timeout)
      while !condition() {
        try Task.checkCancellation()
        guard Date() < deadline else {
          throw DemoScriptError(message: "Timed out waiting for \(description).")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
    }

    private func waitForTarget(_ targetID: String, timeout: Double = 8) async throws -> CGRect? {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        try Task.checkCancellation()
        if let frame = targets.frame(of: targetID) { return frame }
        try await Task.sleep(for: .milliseconds(100))
      }
      return nil
    }

    private func waitForTargetPoint(
      _ targetID: String, at anchor: UnitPoint, timeout: Double = 8
    ) async throws -> CGPoint? {
      guard let frame = try await waitForTarget(targetID, timeout: timeout) else { return nil }
      return CGPoint(
        x: frame.minX + frame.width * anchor.x,
        y: frame.minY + frame.height * anchor.y)
    }
  }
#endif
