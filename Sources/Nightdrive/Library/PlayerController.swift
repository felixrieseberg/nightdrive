import AVFoundation
import Accelerate
import AppKit
import Foundation
import Observation

enum EqualizerPreset: String, CaseIterable, Codable, Identifiable, Sendable {
  case flat
  case bassBoost
  case vocal
  case trebleBoost

  var id: Self { self }

  var label: String {
    switch self {
    case .flat: String(localized: "Flat")
    case .bassBoost: String(localized: "Bass Boost")
    case .vocal: String(localized: "Vocal")
    case .trebleBoost: String(localized: "Treble Boost")
    }
  }

  mutating func cycle() {
    let presets = Self.allCases
    guard let index = presets.firstIndex(of: self) else { return }
    self = presets[(index + 1) % presets.count]
  }
}

struct PlaybackIssue: Equatable, Sendable {
  let trackTitle: String?
  let url: URL?
  let reason: String

  var title: String {
    trackTitle == nil
      ? String(localized: "Playback Couldn’t Start") : String(localized: "Track Skipped")
  }

  var message: String {
    if let trackTitle {
      return String(
        localized: "Skipped “\(trackTitle)” because it could not be played. \(reason)")
    }
    return String(localized: "Audio output is unavailable. \(reason)")
  }

  static func skipped(track: LibraryTrack, reason: String) -> Self {
    Self(trackTitle: track.title, url: track.url, reason: reason)
  }

  static func outputFailure(reason: String) -> Self {
    Self(trackTitle: nil, url: nil, reason: reason)
  }
}

struct AudioFrameChunk: Equatable, Sendable {
  let startingFrame: AVAudioFramePosition
  let frameCount: AVAudioFrameCount
  let isFinal: Bool
}

struct AudioFrameChunkPlanner: Sendable {
  private var nextStartingFrame: AVAudioFramePosition
  private var remainingFrameCount: AVAudioFramePosition
  private let maximumFrameCount: AVAudioFrameCount

  init?(
    startingFrame: AVAudioFramePosition,
    frameCount: AVAudioFramePosition,
    maximumFrameCount: AVAudioFrameCount = .max
  ) {
    guard startingFrame >= 0, frameCount > 0, maximumFrameCount > 0 else { return nil }
    let (_, overflow) = startingFrame.addingReportingOverflow(frameCount)
    guard !overflow else { return nil }
    nextStartingFrame = startingFrame
    remainingFrameCount = frameCount
    self.maximumFrameCount = maximumFrameCount
  }

  mutating func next() -> AudioFrameChunk? {
    guard remainingFrameCount > 0 else { return nil }
    let frameCount = AVAudioFrameCount(
      min(remainingFrameCount, AVAudioFramePosition(maximumFrameCount)))
    let chunk = AudioFrameChunk(
      startingFrame: nextStartingFrame,
      frameCount: frameCount,
      isFinal: AVAudioFramePosition(frameCount) == remainingFrameCount)
    nextStartingFrame += AVAudioFramePosition(frameCount)
    remainingFrameCount -= AVAudioFramePosition(frameCount)
    return chunk
  }
}

typealias AudioSegmentScheduler =
  @MainActor (
    _ node: AVAudioPlayerNode,
    _ file: AVAudioFile,
    _ startingFrame: AVAudioFramePosition,
    _ frameCount: AVAudioFrameCount,
    _ completionType: AVAudioPlayerNodeCompletionCallbackType,
    _ completion: @escaping @Sendable () -> Void
  ) -> Void

typealias AudioFileLoader = @Sendable (URL) async throws -> AVAudioFile

private actor AudioFileOpenLimiter {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  static let shared = AudioFileOpenLimiter(maximumConcurrentOpens: 4)

  private let maximumConcurrentOpens: Int
  private var activeOpenCount = 0
  private var waiters: [Waiter] = []

  init(maximumConcurrentOpens: Int) {
    self.maximumConcurrentOpens = max(1, maximumConcurrentOpens)
  }

  func acquire(id: UUID) async -> Bool {
    guard !Task.isCancelled else { return false }
    if activeOpenCount < maximumConcurrentOpens {
      activeOpenCount += 1
      return true
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !Task.isCancelled else {
          continuation.resume(returning: false)
          return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancel(id: id) }
    }
  }

  func release() {
    if !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      waiter.continuation.resume(returning: true)
    } else {
      activeOpenCount = max(0, activeOpenCount - 1)
    }
  }

  private func cancel(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(returning: false)
  }
}

struct PlaybackQualification {
  static let maximumThreshold: TimeInterval = 30

  private(set) var threshold = maximumThreshold
  private(set) var renderedDuration: TimeInterval = 0
  private(set) var isQualified = false
  private var trackDuration: TimeInterval?
  private var lastRenderedPosition: TimeInterval = 0

  mutating func start(duration: TimeInterval, at position: TimeInterval) {
    trackDuration = duration.isFinite && duration > 0 ? duration : nil
    threshold = Self.threshold(for: duration)
    renderedDuration = 0
    isQualified = false
    rebase(at: position)
  }

  mutating func observe(renderedPosition: TimeInterval) -> Bool {
    guard renderedPosition.isFinite else { return false }
    let position = normalized(renderedPosition)
    let delta = max(0, position - lastRenderedPosition)
    lastRenderedPosition = position
    guard !isQualified, delta > 0 else { return false }
    renderedDuration += delta
    guard renderedDuration >= threshold else { return false }
    isQualified = true
    return true
  }

  mutating func rebase(at position: TimeInterval) {
    guard position.isFinite else { return }
    lastRenderedPosition = normalized(position)
  }

  static func threshold(for duration: TimeInterval) -> TimeInterval {
    guard duration.isFinite, duration > 0 else { return maximumThreshold }
    return min(maximumThreshold, duration / 2)
  }

  private func normalized(_ position: TimeInterval) -> TimeInterval {
    let nonnegative = max(0, position)
    return trackDuration.map { min(nonnegative, $0) } ?? nonnegative
  }
}

@Observable
@MainActor
final class PlayerController {
  static let supportedPlaybackRates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

  private(set) var currentTrack: LibraryTrack?
  private(set) var isPlaying = false
  private(set) var elapsed: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  var canSeek: Bool { file != nil && duration > 0 }
  private(set) var artwork: NSImage?
  private var queue = PlaybackQueue()
  var playbackQueue: [LibraryTrack] { queue.tracks }
  var currentQueueIndex: Int? { queue.currentIndex }
  var playbackHistory: [LibraryTrack] { queue.history.map(\.track) }
  private(set) var playbackIssue: PlaybackIssue?
  var isShuffleEnabled: Bool {
    get { queue.isShuffleEnabled }
    set { queue.isShuffleEnabled = newValue }
  }
  var repeatMode: PlaybackRepeatMode {
    get { queue.repeatMode }
    set { queue.repeatMode = newValue }
  }
  private(set) var playbackRate: Float = 1
  var isMuted = false {
    didSet { updateOutputVolume() }
  }
  var equalizerPreset: EqualizerPreset = .flat {
    didSet { applyEqualizerPreset() }
  }
  @ObservationIgnored var randomPlaybackSource: (() -> [LibraryTrack])?
  @ObservationIgnored var resumePositionProvider: ((LibraryTrack) -> TimeInterval?)?
  @ObservationIgnored var onPlaybackPositionChanged: ((LibraryTrack, TimeInterval, TimeInterval) -> Void)?
  @ObservationIgnored var onTrackStarted: ((LibraryTrack) -> Void)?
  @ObservationIgnored var onTrackQualifiedAsPlayed: ((LibraryTrack) -> Void)?

  var upNextTracks: [LibraryTrack] { queue.upNext }

  private(set) var meterLevel: Double = 0
  private(set) var spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
  private(set) var spectrumPeaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
  private(set) var waveform = [Float](repeating: 0, count: 96)

  /// Untracked reads of the fast-changing playback values. Views in hidden
  /// windows read these instead of the observable properties so a covered or
  /// closed window stops re-rendering entirely; each re-render, however
  /// small, keeps the window's full stack of render surfaces resident
  /// (~130 MiB per window during playback).
  var untrackedElapsed: TimeInterval { _elapsed }
  var untrackedMeterLevel: Double { _meterLevel }
  var untrackedSpectrum: [Float] { _spectrum }
  var untrackedSpectrumPeaks: [Float] { _spectrumPeaks }
  var untrackedWaveform: [Float] { _waveform }

  var currentTrackNumber: Int? { queue.currentTrackNumber }
  var volume: Float = 0.8 {
    didSet { updateOutputVolume() }
  }

  private let engine: AVAudioEngine
  private let node = AVAudioPlayerNode()
  private let equalizer = AVAudioUnitEQ(numberOfBands: 3)
  private let timePitch = AVAudioUnitTimePitch()
  let audioOutput: AudioOutputController
  private var tapInstalled = false
  private var file: AVAudioFile?
  private var graphFormat: AVAudioFormat?
  private var queuedFile: AVAudioFile?
  private var queuedTrack: LibraryTrack?
  private var queuedIndex: Int?
  private var queuedTimelineStartSample: AVAudioFramePosition = 0
  private var currentScheduleFullyEnqueued = false
  private var queuedScheduleFullyEnqueued = false
  private var queuedSchedulePlayedBack = false
  var gaplessSuccessorURL: URL? { queuedTrack?.url }
  var effectiveOutputVolume: Float { node.volume }
  var equalizerBandGains: [Float] { equalizer.bands.map(\.gain) }
  var equalizerInputSampleRate: Double { equalizer.inputFormat(forBus: 0).sampleRate }
  var equalizerOutputSampleRate: Double { equalizer.outputFormat(forBus: 0).sampleRate }
  var playbackTimelineStartSample: AVAudioFramePosition { timelineStartSample }
  var isTickerRunning: Bool { ticker?.isValid == true }
  private var startFrame: AVAudioFramePosition = 0
  private var timelineStartSample: AVAudioFramePosition = 0
  private var generation = 0
  private var analyzer: SpectrumAnalyzer?
  private let tapRing = TapRing()
  @ObservationIgnored private var analysisSamples = [Float](
    repeating: 0, count: SpectrumAnalyzer.size)
  @ObservationIgnored private var analysisWorkspace = SpectrumAnalyzer.Workspace()
  @ObservationIgnored private var freshSpectrum = [Float](
    repeating: 0, count: SpectrumAnalyzer.bandCount)
  @ObservationIgnored private var nextSpectrum = [Float](
    repeating: 0, count: SpectrumAnalyzer.bandCount)
  @ObservationIgnored private var nextSpectrumPeaks = [Float](
    repeating: 0, count: SpectrumAnalyzer.bandCount)
  @ObservationIgnored private var nextWaveform = [Float](repeating: 0, count: 96)
  private var analysisLive = false
  private var ticker: Timer?
  private var tickerTick = 0
  /// Token only; removing it in deinit is thread-safe, so it need not be
  /// main-actor isolated.
  @ObservationIgnored nonisolated(unsafe) private var configurationChangeObserver: (any NSObjectProtocol)?
  private var artworkTask: Task<Void, Never>?
  private var playbackPreparationTask: Task<Void, Never>?
  private var playbackPreparationGeneration = 0
  private var shouldAutoplayAfterPreparation = false
  private var shouldResumeAfterAudioOutputChange = false
  private var audioOutputLossGeneration: UInt64 = 0
  private var systemSleepOutput: (deviceUID: String, lossGeneration: UInt64)?
  private var gaplessPreparationTask: Task<Void, Never>?
  private var gaplessPreparationGeneration = 0
  private var shouldNotifyWhenPlaybackStarts = false
  private var playbackQualification = PlaybackQualification()
  private var normalizationGainDB: Double = 0
  private var normalizationGeneration = 0
  @ObservationIgnored private let loudnessStore = LoudnessStore()
  @ObservationIgnored private let segmentScheduler: AudioSegmentScheduler
  private let maximumFramesPerSegment: AVAudioFrameCount
  @ObservationIgnored private let audioFileLoader: AudioFileLoader
  @ObservationIgnored private let engineStarter: (AVAudioEngine) throws -> Void

  convenience init(
    engineStarter: @escaping (AVAudioEngine) throws -> Void = { engine in
      try engine.start()
    }
  ) {
    self.init(
      segmentScheduler: {
        node, file, startingFrame, frameCount, completionType, completion in
        node.scheduleSegment(
          file, startingFrame: startingFrame, frameCount: frameCount, at: nil,
          completionCallbackType: completionType
        ) { _ in
          completion()
        }
      },
      maximumFramesPerSegment: .max,
      engineStarter: engineStarter)
  }

  convenience init(
    audioFileLoader: @escaping AudioFileLoader,
    engineStarter: @escaping (AVAudioEngine) throws -> Void = { engine in
      try engine.start()
    }
  ) {
    self.init(
      segmentScheduler: {
        node, file, startingFrame, frameCount, completionType, completion in
        node.scheduleSegment(
          file, startingFrame: startingFrame, frameCount: frameCount, at: nil,
          completionCallbackType: completionType
        ) { _ in
          completion()
        }
      },
      maximumFramesPerSegment: .max,
      audioFileLoader: audioFileLoader,
      engineStarter: engineStarter)
  }

  init(
    segmentScheduler: @escaping AudioSegmentScheduler,
    maximumFramesPerSegment: AVAudioFrameCount,
    audioFileLoader: @escaping AudioFileLoader = { url in
      try await PlayerController.openAudioFile(forReading: url)
    },
    audioOutputProvider: (any AudioOutputProviding)? = nil,
    audioOutputDefaults: UserDefaults = NightdriveDefaults.current,
    engineStarter: @escaping (AVAudioEngine) throws -> Void = { engine in
      try engine.start()
    }
  ) {
    let engine = AVAudioEngine()
    self.engine = engine
    self.audioOutput = AudioOutputController(
      provider: audioOutputProvider ?? CoreAudioOutputProvider(audioUnit: engine.outputNode.audioUnit),
      defaults: audioOutputDefaults)
    self.segmentScheduler = segmentScheduler
    self.maximumFramesPerSegment = maximumFramesPerSegment
    self.audioFileLoader = audioFileLoader
    self.engineStarter = engineStarter
    engine.attach(node)
    engine.attach(equalizer)
    engine.attach(timePitch)
    configureEqualizerBands()
    applyEqualizerPreset()
    configurationChangeObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.handleEngineConfigurationChange()
      }
    }
    audioOutput.onRouteWillChange = { [weak self] outputWasLost in
      self?.audioOutputWillChange(outputWasLost: outputWasLost)
    }
    audioOutput.onRouteChanged = { [weak self] in
      self?.rebuildForAudioOutputChange()
    }
  }

  deinit {
    if let configurationChangeObserver {
      NotificationCenter.default.removeObserver(configurationChangeObserver)
    }
  }

  func handleEngineConfigurationChange() {
    guard !audioOutput.refresh(), file != nil else { return }
    seek(toTime: elapsed)
  }

  func selectAudioOutput(_ selectionID: String) {
    audioOutput.select(selectionID)
  }

  func play(_ track: LibraryTrack, in tracks: [LibraryTrack]) {
    playbackIssue = nil
    queue.activate(track, in: tracks)
    startPlayback(track)
  }

  func restore(
    queue: [LibraryTrack],
    currentID: TrackID?,
    position: TimeInterval,
    volume: Float,
    shuffle: Bool,
    repeatMode: PlaybackRepeatMode
  ) {
    stop()
    self.volume = min(max(volume, 0), 1)
    isShuffleEnabled = shuffle
    self.repeatMode = repeatMode
    self.queue.load(queue, currentID: currentID)
    guard let index = self.queue.currentIndex else { return }
    startPlayback(queue[index], autoplay: false, position: position)
  }

  func togglePlayPause() {
    systemSleepOutput = nil
    guard file != nil else {
      if playbackPreparationTask != nil {
        shouldAutoplayAfterPreparation.toggle()
        isPlaying = shouldAutoplayAfterPreparation
        return
      }
      if let track = currentTrack ?? playbackQueue.first {
        if queue.currentIndex == nil {
          queue.currentIndex = playbackQueue.firstIndex(where: { $0.id == track.id })
        }
        startPlayback(track)
        return
      }
      let candidates = randomPlaybackSource?() ?? []
      if let track = candidates.randomElement() {
        play(track, in: candidates)
      }
      return
    }
    if isPlaying {
      updateElapsed()
      publishPlaybackPosition()
      node.pause()
      isPlaying = false
    } else {
      if !engine.isRunning {
        do {
          try startEngineIfNeeded()
        } catch {
          isPlaying = false
          playbackIssue = .outputFailure(reason: error.localizedDescription)
          return
        }
      }
      node.play()
      isPlaying = true
      clearOutputFailureIfNeeded()
      notifyTrackStartedIfNeeded()
      startTicker()
    }
  }

  func resume() {
    systemSleepOutput = nil
    guard !isPlaying else { return }
    togglePlayPause()
  }

  func pause() {
    systemSleepOutput = nil
    guard isPlaying else { return }
    togglePlayPause()
  }

  /// Captures the user's playback intent before making the audio graph safe for sleep.
  @discardableResult
  func prepareForSystemSleep() -> Bool {
    let playbackWasActive = isPlaying || shouldAutoplayAfterPreparation
    systemSleepOutput = audioOutput.activeDeviceUID.map { ($0, audioOutputLossGeneration) }
    if isPlaying, file != nil {
      updateElapsed()
      node.pause()
    }
    publishPlaybackPosition()
    engine.stop()
    ticker?.invalidate()
    ticker = nil
    isPlaying = false
    shouldAutoplayAfterPreparation = false
    shouldResumeAfterAudioOutputChange = false
    return playbackWasActive
  }

  func resumeAfterSystemWake(if playbackWasActive: Bool) {
    let outputBeforeSleep = systemSleepOutput
    systemSleepOutput = nil
    audioOutput.reconcileAfterSystemWake()
    guard
      Self.shouldResumeAfterSystemWake(
        playbackWasActive: playbackWasActive,
        outputBeforeSleep: outputBeforeSleep,
        outputAfterWake: (audioOutput.activeDeviceUID, audioOutputLossGeneration),
        routeIsAvailable: audioOutput.isRouteAvailable)
    else { return }
    guard file != nil else {
      if playbackPreparationTask != nil {
        shouldAutoplayAfterPreparation = true
        isPlaying = true
      }
      return
    }
    guard seek(toTime: elapsed) else { return }
    resume()
  }

  func stop() {
    systemSleepOutput = nil
    cancelPlaybackPreparation()
    updateElapsed()
    publishPlaybackPosition()
    artworkTask?.cancel()
    generation += 1
    node.stop()
    engine.stop()
    file = nil
    currentScheduleFullyEnqueued = false
    clearQueuedSuccessor()
    ticker?.invalidate()
    ticker = nil
    isPlaying = false
    currentTrack = nil
    queue.clear()
    shouldNotifyWhenPlaybackStarts = false
    shouldResumeAfterAudioOutputChange = false
    artwork = nil
    elapsed = 0
    duration = 0
    meterLevel = 0
    spectrum = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    spectrumPeaks = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    waveform = [Float](repeating: 0, count: waveform.count)
    analysisLive = false
    playbackIssue = nil
  }

  func removeTrack(id trackID: TrackID) {
    if currentTrack?.id == trackID {
      stop()
      return
    }
    queue.removeTrack(id: trackID)
    refreshGaplessSuccessor()
  }

  func replaceTrack(_ track: LibraryTrack) {
    queue.replaceTrack(track)
    if currentTrack?.id == track.id {
      currentTrack = track
      loadArtwork(for: track)
    }
    if queuedTrack?.id == track.id {
      queuedTrack = track
    }
  }

  /// Retargets queued tracks after library files move. The playing file keeps
  /// its open handle across a same-volume rename, so playback continues while
  /// the queue and current-track references adopt the new URLs.
  func remapTracks(_ mapping: [TrackID: TrackID], catalog: LibraryCatalog) {
    guard !mapping.isEmpty else { return }
    let wasPreparingPlayback = file == nil && playbackPreparationTask != nil
    let wasPreparingGapless = gaplessPreparationTask != nil
    queue.remapTracks(mapping, catalog: catalog)
    func retargeted(_ track: LibraryTrack?) -> LibraryTrack? {
      track.flatMap { mapping[$0.id] }.flatMap { catalog[$0] }
    }
    if let updated = retargeted(currentTrack) { currentTrack = updated }
    if let updated = retargeted(queuedTrack) { queuedTrack = updated }
    if wasPreparingPlayback, let currentTrack {
      startPlayback(
        currentTrack, autoplay: shouldAutoplayAfterPreparation, position: elapsed)
    } else if wasPreparingGapless {
      refreshGaplessSuccessor()
    }
  }

  func reconcile(with catalog: LibraryCatalog) {
    let oldQueue = playbackQueue
    let oldCurrentTrack = currentTrack
    let oldCurrentIndex = queue.currentIndex
    let oldQueuedTrack = queuedTrack
    let oldQueuedIndex = queuedIndex
    let wasPreparingGapless = gaplessPreparationTask != nil
    let (reconciled, oldToNewQueueIndex) = queue.reconciled(with: catalog)
    queue = reconciled

    guard let oldCurrentTrack else {
      _ = reconcileQueuedSuccessor(
        oldTrack: oldQueuedTrack,
        oldIndex: oldQueuedIndex,
        catalog: catalog,
        oldToNewQueueIndex: oldToNewQueueIndex)
      return
    }

    if let refreshedCurrent = catalog[oldCurrentTrack.id] {
      currentTrack = refreshedCurrent
      if queue.currentIndex == nil {
        queue.currentIndex = playbackQueue.firstIndex { $0.id == oldCurrentTrack.id }
      }
      if refreshedCurrent != oldCurrentTrack {
        loadArtwork(for: refreshedCurrent)
      }
      let queuedScheduleChanged = reconcileQueuedSuccessor(
        oldTrack: oldQueuedTrack,
        oldIndex: oldQueuedIndex,
        catalog: catalog,
        oldToNewQueueIndex: oldToNewQueueIndex)
      if oldCurrentIndex != queue.currentIndex || queuedScheduleChanged {
        seek(toTime: elapsed)
      } else if wasPreparingGapless {
        refreshGaplessSuccessor()
      }
      return
    }

    let wasPlaying = isPlaying
    let fallbackIndex: Int? = oldCurrentIndex.flatMap { index in
      guard oldQueue.indices.contains(index) else { return nil }
      return oldQueue.indices.dropFirst(index + 1)
        .compactMap { oldToNewQueueIndex[$0] }
        .first
    }
    stop()
    queue = reconciled
    queue.currentIndex = nil
    guard let fallbackIndex, playbackQueue.indices.contains(fallbackIndex) else { return }
    queue.currentIndex = fallbackIndex
    startPlayback(playbackQueue[fallbackIndex], autoplay: wasPlaying)
  }

  private func reconcileQueuedSuccessor(
    oldTrack: LibraryTrack?,
    oldIndex: Int?,
    catalog: LibraryCatalog,
    oldToNewQueueIndex: [Int: Int]
  ) -> Bool {
    guard let oldTrack else { return false }
    guard let refreshed = catalog[oldTrack.id],
      let newIndex = oldIndex.flatMap({ oldToNewQueueIndex[$0] }),
      playbackQueue.indices.contains(newIndex),
      playbackQueue[newIndex].id == oldTrack.id
    else {
      clearQueuedSuccessor()
      return true
    }
    queuedTrack = refreshed
    queuedIndex = newIndex
    return oldIndex != newIndex
  }

  func next() { step(by: 1, automatic: false) }
  func previous() {
    if elapsed > 3 {
      seek(to: 0)
      return
    }
    while let entry = queue.popHistory() {
      guard let target = queue.index(of: entry.track, preferring: entry.queueIndex) else {
        continue
      }
      queue.currentIndex = target
      startPlayback(entry.track)
      return
    }
    step(by: -1, automatic: false)
  }

  func playNow(_ track: LibraryTrack) {
    if currentQueueIndex == nil {
      guard
        let sourceIndex = playbackQueue.firstIndex(where: { $0.id == track.id })
      else { return }
      moveUpNextAndPlay(at: sourceIndex)
      return
    }

    guard let currentQueueIndex,
      let sourceIndex = playbackQueue.indices.dropFirst(currentQueueIndex + 1)
        .first(where: { playbackQueue[$0].id == track.id })
    else { return }
    moveUpNextAndPlay(at: sourceIndex)
  }

  func playUpNext(at offset: Int) {
    let base = (currentQueueIndex ?? -1) + 1
    let sourceIndex = base + offset
    guard playbackQueue.indices.contains(sourceIndex) else { return }
    moveUpNextAndPlay(at: sourceIndex)
  }

  private func moveUpNextAndPlay(at sourceIndex: Int) {
    if queue.currentIndex == nil {
      playbackIssue = nil
    }
    guard let selected = queue.promote(at: sourceIndex, recording: currentTrack) else { return }
    startPlayback(selected)
  }

  func toggleShuffle() {
    isShuffleEnabled.toggle()
    guard isShuffleEnabled else {
      refreshGaplessSuccessor()
      return
    }
    if queue.shuffleUpcoming() {
      refreshGaplessSuccessor()
    }
  }

  func setShuffleEnabled(_ enabled: Bool) {
    guard enabled != isShuffleEnabled else { return }
    toggleShuffle()
  }

  func cycleRepeatMode() {
    repeatMode.cycle()
    refreshGaplessSuccessor()
  }

  func setRepeatMode(_ mode: PlaybackRepeatMode) {
    guard mode != repeatMode else { return }
    repeatMode = mode
    refreshGaplessSuccessor()
  }

  @discardableResult
  func setPlaybackRate(_ rate: Float) -> Bool {
    guard Self.supportedPlaybackRates.contains(where: { abs($0 - rate) < 0.001 }) else {
      return false
    }
    guard abs(playbackRate - rate) >= 0.001 else { return true }
    updateElapsed()
    playbackRate = rate
    timePitch.rate = rate
    return true
  }

  @discardableResult
  func skip(by interval: TimeInterval) -> Bool {
    guard let target = Self.skipTarget(elapsed: elapsed, duration: duration, interval: interval)
    else { return false }
    return seek(toTime: target)
  }

  static func skipTarget(
    elapsed: TimeInterval, duration: TimeInterval, interval: TimeInterval
  ) -> TimeInterval? {
    guard elapsed.isFinite, duration.isFinite, interval.isFinite, duration > 0 else { return nil }
    return min(max(elapsed + interval, 0), duration)
  }

  func toggleMute() {
    isMuted.toggle()
  }

  func cycleEqualizerPreset() {
    equalizerPreset.cycle()
  }

  func dismissPlaybackIssue() {
    playbackIssue = nil
  }

  func playNext(_ track: LibraryTrack) {
    queue.insertNext(track)
    refreshGaplessSuccessor()
  }

  func addToUpNext(_ track: LibraryTrack) {
    queue.append(track)
    if queuedTrack == nil {
      refreshGaplessSuccessor()
    }
  }

  func removeUpNext(at offsets: IndexSet) {
    guard !offsets.isEmpty else { return }
    queue.removeUpNext(at: offsets)
    refreshGaplessSuccessor()
  }

  func moveUpNext(from offsets: IndexSet, to destination: Int) {
    guard !offsets.isEmpty else { return }
    queue.moveUpNext(from: offsets, to: destination)
    refreshGaplessSuccessor()
  }

  func clearUpNext() {
    replaceUpNext(with: [])
  }

  func replaceUpNext(with tracks: [LibraryTrack]) {
    queue.replaceUpNext(with: tracks)
    refreshGaplessSuccessor()
  }

  func seek(to fraction: Double) {
    systemSleepOutput = nil
    guard let file else { return }
    updateElapsed()
    let clamped = min(max(fraction, 0), 1)
    let target = min(
      AVAudioFramePosition(Double(file.length) * clamped), file.length - 1)
    generation += 1
    node.stop()
    clearQueuedSuccessor()
    schedule(from: max(0, target))
    elapsed = Double(max(0, target)) / file.processingFormat.sampleRate
    playbackQualification.rebase(at: elapsed)
    publishPlaybackPosition()
    prepareGaplessSuccessor()
    if isPlaying {
      do {
        try startEngineIfNeeded()
      } catch {
        isPlaying = false
        playbackIssue = .outputFailure(reason: error.localizedDescription)
        return
      }
      node.play()
      clearOutputFailureIfNeeded()
    }
  }

  @discardableResult
  func seek(toTime time: TimeInterval) -> Bool {
    guard time.isFinite, duration > 0, file != nil else { return false }
    seek(to: time / duration)
    return true
  }

  private func step(by delta: Int, automatic: Bool) {
    guard queue.currentIndex != nil else { return }
    guard let target = queue.advanceIndex(by: delta, automatic: automatic) else {
      stop()
      return
    }
    if delta > 0 {
      queue.record(currentTrack)
    }
    queue.currentIndex = target
    startPlayback(playbackQueue[target])
  }

  private func startPlayback(
    _ track: LibraryTrack,
    autoplay: Bool = true,
    position: TimeInterval? = nil
  ) {
    systemSleepOutput = nil
    // Retire the old schedule before exposing the new selection. This keeps
    // the displayed track, file, timeline, and controls consistent while the
    // replacement file opens asynchronously.
    updateElapsed()
    publishPlaybackPosition()
    let position = resolvedStartPosition(for: track, explicitPosition: position)
    generation += 1
    node.stop()
    file = nil
    currentScheduleFullyEnqueued = false
    clearQueuedSuccessor()
    isPlaying = false
    shouldNotifyWhenPlaybackStarts = false
    elapsed = position.isFinite ? max(0, position) : 0
    duration = max(elapsed, Double(max(0, track.durationMS)) / 1_000)
    playbackPreparationTask?.cancel()
    currentTrack = track
    loadArtwork(for: track)
    shouldAutoplayAfterPreparation = autoplay
    isPlaying = autoplay
    playbackPreparationGeneration += 1
    let expectedPreparationGeneration = playbackPreparationGeneration
    openPlaybackCandidate(
      track,
      position: position,
      attemptedIndices: [],
      preparationGeneration: expectedPreparationGeneration)
  }

  private func openPlaybackCandidate(
    _ candidate: LibraryTrack,
    position: TimeInterval,
    attemptedIndices: Set<Int>,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    var attemptedIndices = attemptedIndices
    if let index = currentQueueIndex {
      attemptedIndices.insert(index)
    }
    let loader = audioFileLoader
    playbackPreparationTask = Task { [weak self] in
      do {
        let audioFile = try await loader(candidate.url)
        guard !Task.isCancelled else { return }
        self?.finishPlaybackCandidateOpen(
          candidate,
          audioFile: audioFile,
          position: position,
          attemptedIndices: attemptedIndices,
          preparationGeneration: expectedPreparationGeneration)
      } catch {
        guard !Task.isCancelled else { return }
        self?.finishPlaybackCandidateOpen(
          candidate,
          error: error,
          attemptedIndices: attemptedIndices,
          preparationGeneration: expectedPreparationGeneration)
      }
    }
  }

  private func finishPlaybackCandidateOpen(
    _ candidate: LibraryTrack,
    audioFile: AVAudioFile,
    position: TimeInterval,
    attemptedIndices: Set<Int>,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    guard playbackPreparationMatches(expectedPreparationGeneration) else { return }
    guard let candidateIndex = currentQueueIndex,
      playbackQueue.indices.contains(candidateIndex),
      playbackQueue[candidateIndex].id == candidate.id
    else {
      playbackPreparationTask = nil
      return
    }
    let refreshedCandidate = playbackQueue[candidateIndex]
    do {
      try preparePlayback(refreshedCandidate, audioFile: audioFile, position: position)
    } catch {
      finishPlaybackCandidateOpen(
        refreshedCandidate,
        error: error,
        attemptedIndices: attemptedIndices,
        preparationGeneration: expectedPreparationGeneration)
      return
    }

    playbackPreparationTask = nil
    if shouldAutoplayAfterPreparation {
      do {
        try startEngineIfNeeded()
        node.play()
        isPlaying = true
        clearOutputFailureIfNeeded()
        notifyTrackStartedIfNeeded()
      } catch {
        isPlaying = false
        playbackIssue = .outputFailure(reason: error.localizedDescription)
      }
    } else {
      isPlaying = false
    }
    if isPlaying { startTicker() }
  }

  private func finishPlaybackCandidateOpen(
    _ candidate: LibraryTrack,
    error: any Error,
    attemptedIndices: Set<Int>,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    guard playbackPreparationMatches(expectedPreparationGeneration) else { return }
    playbackIssue = .skipped(track: candidate, reason: error.localizedDescription)
    guard let failedIndex = currentQueueIndex,
      let nextIndex = queue.recoveryIndex(after: failedIndex, excluding: attemptedIndices)
    else {
      let issue = playbackIssue
      stop()
      playbackIssue = issue
      return
    }
    queue.currentIndex = nextIndex
    let nextCandidate = playbackQueue[nextIndex]
    let nextPosition = resolvedStartPosition(for: nextCandidate, explicitPosition: nil)
    currentTrack = nextCandidate
    loadArtwork(for: nextCandidate)
    elapsed = nextPosition
    duration = max(nextPosition, Double(max(0, nextCandidate.durationMS)) / 1_000)
    openPlaybackCandidate(
      nextCandidate,
      position: nextPosition,
      attemptedIndices: attemptedIndices,
      preparationGeneration: expectedPreparationGeneration)
  }

  private func preparePlayback(
    _ track: LibraryTrack,
    audioFile: AVAudioFile,
    position: TimeInterval
  ) throws {
    guard audioFile.length > 0 else { throw PlayerError.emptyAudioFile }

    updateElapsed()
    generation += 1
    node.stop()
    clearQueuedSuccessor()
    if graphFormat.map({ !formatsMatch($0, audioFile.processingFormat) }) ?? true {
      configureGraph(for: audioFile.processingFormat)
    }

    file = audioFile
    analyzer = SpectrumAnalyzer(sampleRate: audioFile.processingFormat.sampleRate)
    tapRing.reset()
    refreshNormalization(for: track)
    currentTrack = track
    duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
    let position = Self.playableStartPosition(position, duration: duration)
    let restoredFrame = Self.restoredFrame(
      position: position,
      sampleRate: audioFile.processingFormat.sampleRate,
      length: audioFile.length)
    elapsed = Double(restoredFrame) / audioFile.processingFormat.sampleRate
    playbackQualification.start(duration: duration, at: elapsed)
    schedule(from: restoredFrame)
    prepareGaplessSuccessor()
    shouldNotifyWhenPlaybackStarts = true
  }

  nonisolated private static func openAudioFile(forReading url: URL) async throws -> AVAudioFile {
    let permitID = UUID()
    guard await AudioFileOpenLimiter.shared.acquire(id: permitID) else {
      throw CancellationError()
    }
    guard !Task.isCancelled else {
      await AudioFileOpenLimiter.shared.release()
      throw CancellationError()
    }
    do {
      let file = try await Task.detached(priority: .userInitiated) {
        try AVAudioFile(forReading: url)
      }.value
      await AudioFileOpenLimiter.shared.release()
      return file
    } catch {
      await AudioFileOpenLimiter.shared.release()
      throw error
    }
  }

  private func playbackPreparationMatches(_ expectedGeneration: Int) -> Bool {
    !Task.isCancelled && playbackPreparationGeneration == expectedGeneration
  }

  private func cancelPlaybackPreparation() {
    playbackPreparationGeneration += 1
    shouldAutoplayAfterPreparation = false
    playbackPreparationTask?.cancel()
    playbackPreparationTask = nil
  }

  /// Waits for the controller's current file-open work to settle. Playback
  /// controls intentionally remain synchronous; tests and state restorers
  /// that need fully prepared audio state can await this boundary.
  func waitForPendingPreparation() async {
    while true {
      if let playbackPreparationTask {
        await playbackPreparationTask.value
        continue
      }
      if let gaplessPreparationTask {
        await gaplessPreparationTask.value
        continue
      }
      return
    }
  }

  static func restoredFrame(
    position: TimeInterval,
    sampleRate: Double,
    length: AVAudioFramePosition
  ) -> AVAudioFramePosition {
    guard position.isFinite, position > 0, sampleRate.isFinite, sampleRate > 0, length > 1
    else { return 0 }

    let lastFrame = length - 1
    let lastSecond = Double(lastFrame) / sampleRate
    guard position < lastSecond else { return lastFrame }

    let candidate = position * sampleRate
    guard candidate.isFinite, candidate > 0 else { return 0 }
    guard candidate < Double(lastFrame) else { return lastFrame }
    return AVAudioFramePosition(candidate)
  }

  static func playableStartPosition(
    _ position: TimeInterval, duration: TimeInterval
  ) -> TimeInterval {
    guard position.isFinite, position > 0 else { return 0 }
    guard duration.isFinite, duration > 0 else { return position }
    return position >= max(0, duration - 0.25) ? 0 : position
  }

  static func shouldResumeAfterSystemWake(
    playbackWasActive: Bool,
    outputBeforeSleep: (deviceUID: String, lossGeneration: UInt64)?,
    outputAfterWake: (deviceUID: String?, lossGeneration: UInt64),
    routeIsAvailable: Bool
  ) -> Bool {
    guard playbackWasActive, routeIsAvailable, let outputBeforeSleep,
      let outputAfterWakeUID = outputAfterWake.deviceUID
    else { return false }
    return outputBeforeSleep.deviceUID == outputAfterWakeUID
      && outputBeforeSleep.lossGeneration == outputAfterWake.lossGeneration
  }

  private func startEngineIfNeeded() throws {
    try audioOutput.requireAvailableRoute()
    if !engine.isRunning {
      try engineStarter(engine)
    }
  }

  private func audioOutputWillChange(outputWasLost: Bool) {
    if outputWasLost { audioOutputLossGeneration &+= 1 }
    let wasPlaybackActive = isPlaying || shouldAutoplayAfterPreparation
    shouldResumeAfterAudioOutputChange = wasPlaybackActive && !outputWasLost
    if isPlaying, file != nil {
      updateElapsed()
      publishPlaybackPosition()
      node.pause()
    }
    engine.stop()
    isPlaying = false
    shouldAutoplayAfterPreparation = false
    if outputWasLost, wasPlaybackActive {
      playbackIssue = .outputFailure(
        reason: String(localized: "The previous output disconnected, so playback was paused."))
    }
  }

  private func rebuildForAudioOutputChange() {
    let shouldResume = shouldResumeAfterAudioOutputChange
    shouldResumeAfterAudioOutputChange = false
    guard file != nil else {
      if playbackPreparationTask != nil {
        shouldAutoplayAfterPreparation = shouldResume
        isPlaying = shouldResume
      }
      return
    }
    guard seek(toTime: elapsed), shouldResume else { return }
    resume()
  }

  private func clearOutputFailureIfNeeded() {
    if playbackIssue?.trackTitle == nil {
      playbackIssue = nil
    }
  }

  private func configureGraph(for format: AVAudioFormat) {
    engine.stop()
    engine.disconnectNodeOutput(node)
    engine.disconnectNodeOutput(equalizer)
    engine.disconnectNodeOutput(timePitch)
    if tapInstalled {
      equalizer.removeTap(onBus: 0)
      tapInstalled = false
    }
    engine.connect(node, to: equalizer, format: format)
    engine.connect(equalizer, to: timePitch, format: format)
    engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    let ring = tapRing
    equalizer.installTap(onBus: 0, bufferSize: 1024, format: nil) { @Sendable buffer, _ in
      ring.push(buffer)
    }
    tapInstalled = true
    graphFormat = format
  }

  private func notifyTrackStartedIfNeeded() {
    guard shouldNotifyWhenPlaybackStarts, let currentTrack else { return }
    shouldNotifyWhenPlaybackStarts = false
    onTrackStarted?(currentTrack)
  }

  private func schedule(from frame: AVAudioFramePosition) {
    guard let file, file.length > frame else { return }
    startFrame = frame
    timelineStartSample = 0
    currentScheduleFullyEnqueued = false
    let gen = generation
    let expectedIndex = currentQueueIndex
    guard
      let planner = AudioFrameChunkPlanner(
        startingFrame: frame,
        frameCount: file.length - frame,
        maximumFrameCount: maximumFramesPerSegment)
    else { return }
    scheduleCurrentChunk(planner, file: file, generation: gen, queueIndex: expectedIndex)
  }

  private func scheduleCurrentChunk(
    _ remainingPlan: AudioFrameChunkPlanner,
    file: AVAudioFile,
    generation expectedGeneration: Int,
    queueIndex expectedIndex: Int?
  ) {
    var planner = remainingPlan
    guard let chunk = planner.next() else { return }
    let nextPlan = planner
    let completionType: AVAudioPlayerNodeCompletionCallbackType =
      chunk.isFinal ? .dataPlayedBack : .dataConsumed
    if chunk.isFinal {
      currentScheduleFullyEnqueued = true
    }
    segmentScheduler(
      node, file, chunk.startingFrame, chunk.frameCount, completionType
    ) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.generation == expectedGeneration,
          self.currentQueueIndex == expectedIndex
        else { return }
        if chunk.isFinal {
          self.finishedScheduledTrack()
        } else if let file = self.file {
          self.scheduleCurrentChunk(
            nextPlan, file: file, generation: expectedGeneration, queueIndex: expectedIndex)
        }
      }
    }
    if chunk.isFinal {
      prepareGaplessSuccessor()
    }
  }

  private func prepareGaplessSuccessor() {
    guard currentScheduleFullyEnqueued, queuedFile == nil, let file,
      gaplessPreparationTask == nil, let index = currentQueueIndex
    else { return }

    gaplessPreparationGeneration += 1
    let expectedPreparationGeneration = gaplessPreparationGeneration
    let expectedPlaybackGeneration = generation
    openGaplessCandidate(
      in: queue.successorIndices(after: index),
      at: 0,
      currentFile: file,
      currentIndex: index,
      playbackGeneration: expectedPlaybackGeneration,
      preparationGeneration: expectedPreparationGeneration)
  }

  private func openGaplessCandidate(
    in candidateIndices: [Int],
    at candidateOffset: Int,
    currentFile: AVAudioFile,
    currentIndex: Int,
    playbackGeneration expectedPlaybackGeneration: Int,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    guard
      gaplessPreparationMatches(
        expectedPreparationGeneration,
        playbackGeneration: expectedPlaybackGeneration,
        queueIndex: currentIndex,
        currentFile: currentFile)
    else { return }
    guard candidateIndices.indices.contains(candidateOffset) else {
      gaplessPreparationTask = nil
      return
    }
    let candidateIndex = candidateIndices[candidateOffset]
    guard playbackQueue.indices.contains(candidateIndex) else {
      gaplessPreparationTask = nil
      prepareGaplessSuccessor()
      return
    }
    let candidate = playbackQueue[candidateIndex]
    if resolvedStartPosition(for: candidate, explicitPosition: nil) > 0 {
      // A bookmarked successor must start from its saved position. Leave it
      // unscheduled so the normal transition path can open it at that point.
      gaplessPreparationTask = nil
      return
    }
    let loader = audioFileLoader
    gaplessPreparationTask = Task { [weak self] in
      do {
        let candidateFile = try await loader(candidate.url)
        guard !Task.isCancelled else { return }
        self?.finishGaplessCandidateOpen(
          candidate,
          candidateFile: candidateFile,
          candidateIndices: candidateIndices,
          candidateOffset: candidateOffset,
          candidateIndex: candidateIndex,
          currentFile: currentFile,
          currentIndex: currentIndex,
          playbackGeneration: expectedPlaybackGeneration,
          preparationGeneration: expectedPreparationGeneration)
      } catch {
        guard !Task.isCancelled else { return }
        self?.finishGaplessCandidateOpen(
          candidate,
          error: error,
          candidateIndices: candidateIndices,
          nextCandidateOffset: candidateOffset + 1,
          currentFile: currentFile,
          currentIndex: currentIndex,
          playbackGeneration: expectedPlaybackGeneration,
          preparationGeneration: expectedPreparationGeneration)
      }
    }
  }

  private func finishGaplessCandidateOpen(
    _ candidate: LibraryTrack,
    candidateFile: AVAudioFile,
    candidateIndices: [Int],
    candidateOffset: Int,
    candidateIndex: Int,
    currentFile: AVAudioFile,
    currentIndex: Int,
    playbackGeneration expectedPlaybackGeneration: Int,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    guard
      gaplessPreparationMatches(
        expectedPreparationGeneration,
        playbackGeneration: expectedPlaybackGeneration,
        queueIndex: currentIndex,
        currentFile: currentFile)
    else { return }
    guard playbackQueue.indices.contains(candidateIndex),
      playbackQueue[candidateIndex].id == candidate.id
    else {
      gaplessPreparationTask = nil
      prepareGaplessSuccessor()
      return
    }
    let refreshedCandidate = playbackQueue[candidateIndex]
    guard candidateFile.length > 0 else {
      finishGaplessCandidateOpen(
        refreshedCandidate,
        error: PlayerError.emptyAudioFile,
        candidateIndices: candidateIndices,
        nextCandidateOffset: candidateOffset + 1,
        currentFile: currentFile,
        currentIndex: currentIndex,
        playbackGeneration: expectedPlaybackGeneration,
        preparationGeneration: expectedPreparationGeneration)
      return
    }
    guard formatsMatch(currentFile.processingFormat, candidateFile.processingFormat) else {
      gaplessPreparationTask = nil
      return
    }

    let gen = generation
    queuedFile = candidateFile
    queuedTrack = refreshedCandidate
    queuedIndex = candidateIndex
    queuedScheduleFullyEnqueued = false
    queuedSchedulePlayedBack = false
    queuedTimelineStartSample = Self.saturatingTimelineSample(
      timelineStartSample, adding: max(0, currentFile.length - startFrame))
    guard
      let planner = AudioFrameChunkPlanner(
        startingFrame: 0,
        frameCount: candidateFile.length,
        maximumFrameCount: maximumFramesPerSegment)
    else {
      clearQueuedSuccessor()
      return
    }
    scheduleSuccessorChunk(
      planner,
      file: candidateFile,
      trackID: refreshedCandidate.id,
      queueIndex: candidateIndex,
      generation: gen)
    gaplessPreparationTask = nil
  }

  private func finishGaplessCandidateOpen(
    _ candidate: LibraryTrack,
    error: any Error,
    candidateIndices: [Int],
    nextCandidateOffset: Int,
    currentFile: AVAudioFile,
    currentIndex: Int,
    playbackGeneration expectedPlaybackGeneration: Int,
    preparationGeneration expectedPreparationGeneration: Int
  ) {
    guard
      gaplessPreparationMatches(
        expectedPreparationGeneration,
        playbackGeneration: expectedPlaybackGeneration,
        queueIndex: currentIndex,
        currentFile: currentFile)
    else { return }
    playbackIssue = .skipped(track: candidate, reason: error.localizedDescription)
    openGaplessCandidate(
      in: candidateIndices,
      at: nextCandidateOffset,
      currentFile: currentFile,
      currentIndex: currentIndex,
      playbackGeneration: expectedPlaybackGeneration,
      preparationGeneration: expectedPreparationGeneration)
  }

  private func gaplessPreparationMatches(
    _ expectedGeneration: Int,
    playbackGeneration: Int,
    queueIndex: Int,
    currentFile: AVAudioFile
  ) -> Bool {
    !Task.isCancelled
      && gaplessPreparationGeneration == expectedGeneration
      && generation == playbackGeneration
      && currentQueueIndex == queueIndex
      && file === currentFile
      && queuedFile == nil
  }

  private func scheduleSuccessorChunk(
    _ remainingPlan: AudioFrameChunkPlanner,
    file: AVAudioFile,
    trackID: TrackID,
    queueIndex: Int,
    generation expectedGeneration: Int
  ) {
    var planner = remainingPlan
    guard let chunk = planner.next() else { return }
    let nextPlan = planner
    let completionType: AVAudioPlayerNodeCompletionCallbackType =
      chunk.isFinal ? .dataPlayedBack : .dataConsumed
    if chunk.isFinal {
      if queuedScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
        queuedScheduleFullyEnqueued = true
      } else if currentScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
        currentScheduleFullyEnqueued = true
      }
    }
    segmentScheduler(
      node, file, chunk.startingFrame, chunk.frameCount, completionType
    ) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.generation == expectedGeneration else { return }
        if chunk.isFinal {
          if self.queuedScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
            self.queuedSchedulePlayedBack = true
          } else if self.currentScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
            self.finishedScheduledTrack()
          }
          return
        }
        guard
          let file = self.scheduledFile(trackID: trackID, queueIndex: queueIndex)
        else { return }
        self.scheduleSuccessorChunk(
          nextPlan,
          file: file,
          trackID: trackID,
          queueIndex: queueIndex,
          generation: expectedGeneration)
      }
    }
    if chunk.isFinal,
      currentScheduleMatches(trackID: trackID, queueIndex: queueIndex)
    {
      prepareGaplessSuccessor()
    }
  }

  private func scheduledFile(trackID: TrackID, queueIndex: Int) -> AVAudioFile? {
    if queuedScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
      return queuedFile
    }
    if currentScheduleMatches(trackID: trackID, queueIndex: queueIndex) {
      return file
    }
    return nil
  }

  private func queuedScheduleMatches(trackID: TrackID, queueIndex: Int) -> Bool {
    queuedIndex == queueIndex && queuedTrack?.id == trackID && queuedFile != nil
  }

  private func currentScheduleMatches(trackID: TrackID, queueIndex: Int) -> Bool {
    currentQueueIndex == queueIndex && currentTrack?.id == trackID && file != nil
  }

  private func finishedScheduledTrack() {
    notifyPlaybackQualification(at: duration)
    elapsed = duration
    publishPlaybackPosition()
    if let queuedFile, let queuedTrack, let queuedIndex {
      let promotedScheduleFullyEnqueued = queuedScheduleFullyEnqueued
      let promotedSchedulePlayedBack = queuedSchedulePlayedBack
      queue.record(currentTrack)
      file = queuedFile
      currentTrack = queuedTrack
      refreshNormalization(for: queuedTrack)
      queue.currentIndex = queuedIndex
      startFrame = 0
      timelineStartSample = queuedTimelineStartSample
      elapsed = 0
      duration = Double(queuedFile.length) / queuedFile.processingFormat.sampleRate
      playbackQualification.start(duration: duration, at: 0)
      analyzer = SpectrumAnalyzer(sampleRate: queuedFile.processingFormat.sampleRate)
      currentScheduleFullyEnqueued = promotedScheduleFullyEnqueued
      clearQueuedSuccessor()
      shouldNotifyWhenPlaybackStarts = true
      notifyTrackStartedIfNeeded()
      loadArtwork(for: queuedTrack)
      if promotedSchedulePlayedBack {
        finishedScheduledTrack()
      } else {
        prepareGaplessSuccessor()
      }
    } else {
      step(by: 1, automatic: true)
    }
  }

  private func refreshGaplessSuccessor() {
    guard file != nil else { return }
    if queuedFile != nil {
      seek(toTime: elapsed)
    } else {
      cancelGaplessPreparation()
      prepareGaplessSuccessor()
    }
  }

  private func clearQueuedSuccessor() {
    cancelGaplessPreparation()
    queuedFile = nil
    queuedTrack = nil
    queuedIndex = nil
    queuedTimelineStartSample = 0
    queuedScheduleFullyEnqueued = false
    queuedSchedulePlayedBack = false
  }

  private func cancelGaplessPreparation() {
    gaplessPreparationGeneration += 1
    gaplessPreparationTask?.cancel()
    gaplessPreparationTask = nil
  }

  static func saturatingTimelineSample(
    _ timelineStartSample: AVAudioFramePosition,
    adding frameCount: AVAudioFramePosition
  ) -> AVAudioFramePosition {
    guard frameCount > 0 else { return timelineStartSample }
    let (result, overflow) = timelineStartSample.addingReportingOverflow(frameCount)
    return overflow ? .max : result
  }

  private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate
      && lhs.channelCount == rhs.channelCount
      && lhs.commonFormat == rhs.commonFormat
      && lhs.isInterleaved == rhs.isInterleaved
  }

  private func updateOutputVolume() {
    let scale = LoudnessAnalyzer.playbackScale(gainDB: normalizationGainDB)
    node.volume = isMuted ? 0 : Float(min(max(Double(volume), 0) * scale, 1))
  }

  private func refreshNormalization(for track: LibraryTrack) {
    normalizationGeneration += 1
    let generation = normalizationGeneration
    if let known = track.gainDB ?? loudnessStore.cachedGain(forSource: track.url) {
      normalizationGainDB = known
      updateOutputVolume()
      return
    }
    normalizationGainDB = 0
    updateOutputVolume()
    let store = loudnessStore
    let url = track.url
    Task.detached(priority: .utility) { [weak self] in
      guard let gain = store.gain(forSource: url) else { return }
      await MainActor.run { [weak self] in
        guard let self, self.normalizationGeneration == generation else { return }
        self.normalizationGainDB = gain
        self.updateOutputVolume()
      }
    }
  }

  private func configureEqualizerBands() {
    let bands = equalizer.bands
    bands[0].filterType = .lowShelf
    bands[0].frequency = 120
    bands[0].bandwidth = 0.8
    bands[1].filterType = .parametric
    bands[1].frequency = 1_500
    bands[1].bandwidth = 1.2
    bands[2].filterType = .highShelf
    bands[2].frequency = 6_500
    bands[2].bandwidth = 0.8
  }

  private func applyEqualizerPreset() {
    let gains: [Float]
    switch equalizerPreset {
    case .flat:
      gains = [0, 0, 0]
    case .bassBoost:
      gains = [6, -1, 0]
    case .vocal:
      gains = [-2, 4, -1]
    case .trebleBoost:
      gains = [0, -1, 5]
    }
    for (band, gain) in zip(equalizer.bands, gains) {
      band.gain = gain
      band.bypass = gain == 0
    }
  }

  private func startTicker() {
    ticker?.invalidate()
    tickerTick = 0
    ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] timer in
      let shouldStop = MainActor.assumeIsolated {
        guard let self else { return true }
        self.tickerTick += 1
        if self.tickerTick % 12 == 0 || self.elapsed == 0 { self.updateElapsed() }
        self.updateAnalysis()
        if !self.isPlaying, !self.analysisLive {
          self.ticker = nil
          return true
        }
        return false
      }
      if shouldStop { timer.invalidate() }
    }
  }

  private func updateElapsed() {
    guard isPlaying,
      let nodeTime = node.lastRenderTime,
      let playerTime = node.playerTime(forNodeTime: nodeTime)
    else { return }
    elapsed = min(
      duration,
      max(
        0,
        (Double(startFrame) + Double(playerTime.sampleTime - timelineStartSample))
          / playerTime.sampleRate))
    notifyPlaybackQualification(at: elapsed)
  }

  private func resolvedStartPosition(
    for track: LibraryTrack, explicitPosition: TimeInterval?
  ) -> TimeInterval {
    let candidate = explicitPosition ?? resumePositionProvider?(track) ?? 0
    return candidate.isFinite ? max(0, candidate) : 0
  }

  private func publishPlaybackPosition() {
    guard let currentTrack else { return }
    onPlaybackPositionChanged?(currentTrack, elapsed, duration)
  }

  private func notifyPlaybackQualification(at renderedPosition: TimeInterval) {
    guard playbackQualification.observe(renderedPosition: renderedPosition),
      let currentTrack
    else { return }
    onTrackQualifiedAsPlayed?(currentTrack)
  }

  private func updateAnalysis() {
    let windowVisible = NSApplication.shared.windows.contains { window in
      window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    if isPlaying, windowVisible, let analyzer {
      tapRing.snapshot(into: &analysisSamples)
      var rms: Float = 0
      vDSP_rmsqv(analysisSamples, 1, &rms, vDSP_Length(analysisSamples.count))
      let db = 20 * log10(Double(rms) + 1e-9)
      let target = min(max((db + 50) / 45, 0), 1)
      meterLevel = target > meterLevel ? target : meterLevel * 0.8 + target * 0.2

      analyzer.bands(
        from: analysisSamples, into: &freshSpectrum, workspace: &analysisWorkspace)
      guard freshSpectrum.count == spectrum.count else { return }
      for i in 0..<spectrum.count {
        nextSpectrum[i] =
          freshSpectrum[i] > spectrum[i]
          ? freshSpectrum[i]
          : spectrum[i] * 0.72 + freshSpectrum[i] * 0.28
        nextSpectrumPeaks[i] =
          nextSpectrum[i] >= spectrumPeaks[i]
          ? nextSpectrum[i]
          : max(nextSpectrum[i], spectrumPeaks[i] - 0.03)
      }
      let stride = max(1, analysisSamples.count / waveform.count)
      for i in 0..<waveform.count { nextWaveform[i] = analysisSamples[i * stride] }
      publishAnalysis()
      analysisLive = true
    } else if analysisLive {
      let decayedMeterLevel = meterLevel < 0.02 ? 0 : meterLevel * 0.8
      for i in 0..<spectrum.count {
        nextSpectrum[i] = spectrum[i] < 0.02 ? 0 : spectrum[i] * 0.8
        nextSpectrumPeaks[i] = spectrumPeaks[i] < 0.02 ? 0 : spectrumPeaks[i] * 0.9
      }
      for i in 0..<waveform.count {
        nextWaveform[i] = abs(waveform[i]) < 0.01 ? 0 : waveform[i] * 0.7
      }
      meterLevel = decayedMeterLevel
      publishAnalysis()
      if meterLevel == 0, !spectrum.contains(where: { $0 != 0 }),
        !spectrumPeaks.contains(where: { $0 != 0 }), !waveform.contains(where: { $0 != 0 })
      {
        analysisLive = false
      }
    }
  }

  private func publishAnalysis() {
    let previousSpectrum = spectrum
    let previousPeaks = spectrumPeaks
    let previousWaveform = waveform
    spectrum = nextSpectrum
    spectrumPeaks = nextSpectrumPeaks
    waveform = nextWaveform
    nextSpectrum = previousSpectrum
    nextSpectrumPeaks = previousPeaks
    nextWaveform = previousWaveform
  }

  private func loadArtwork(for track: LibraryTrack) {
    artwork = nil
    artworkTask?.cancel()
    artworkTask = Task { [weak self] in
      let data = await MetadataLoader.loadArtwork(url: track.url)
      guard !Task.isCancelled, self?.currentTrack == track else { return }
      if let data, let image = Self.decodeArtwork(data) {
        self?.artwork = image
      }
    }
  }

  /// Embedded covers can be arbitrarily large (a 3000x3000 JPEG decodes to
  /// ~36 MB), but every consumer — the deck's 80 pt tile and the system
  /// now-playing center — displays far smaller. Decoding through a bounded
  /// thumbnail caps the per-track allocation and the decode transient.
  static let artworkMaxPixels: CGFloat = 640

  private static func decodeArtwork(_ data: Data) -> NSImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: artworkMaxPixels,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return NSImage(data: data) }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
  }
}

private enum PlayerError: LocalizedError {
  case emptyAudioFile

  var errorDescription: String? {
    switch self {
    case .emptyAudioFile: String(localized: "The audio file contains no playable samples.")
    }
  }
}
