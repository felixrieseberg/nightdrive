import AVFoundation
import Foundation
import Testing

@testable import Nightdrive

@MainActor
struct PlayerSchedulingTests {
  @Test
  func testChunkPlannerBoundsSegmentsWithoutNarrowingTheRemainingFrameCount() throws {
    let limit = AVAudioFramePosition(AVAudioFrameCount.max)

    #expect(
      plannedChunks(frameCount: limit - 1) == [AudioFrameChunk(startingFrame: 0, frameCount: .max - 1, isFinal: true)])
    #expect(plannedChunks(frameCount: limit) == [AudioFrameChunk(startingFrame: 0, frameCount: .max, isFinal: true)])
    #expect(
      plannedChunks(frameCount: limit + 1) == [
        AudioFrameChunk(startingFrame: 0, frameCount: .max, isFinal: false),
        AudioFrameChunk(startingFrame: limit, frameCount: 1, isFinal: true),
      ])
    #expect(
      plannedChunks(startingFrame: 123, frameCount: limit * 2 + 17) == [
        AudioFrameChunk(startingFrame: 123, frameCount: .max, isFinal: false),
        AudioFrameChunk(startingFrame: 123 + limit, frameCount: .max, isFinal: false),
        AudioFrameChunk(startingFrame: 123 + limit * 2, frameCount: 17, isFinal: true),
      ])
  }

  @Test
  func testTimelineSampleAdditionSaturatesOnOverflow() {
    #expect(PlayerController.saturatingTimelineSample(100, adding: 25) == 125)
    #expect(PlayerController.saturatingTimelineSample(.max - 4, adding: 5) == .max)
  }

  @Test
  func testStartPositionAtOrBeyondActualDurationRestartsFromBeginning() {
    #expect(PlayerController.playableStartPosition(9, duration: 8) == 0)
    #expect(PlayerController.playableStartPosition(7.8, duration: 8) == 0)
    #expect(PlayerController.playableStartPosition(7.7, duration: 8) == 7.7)
  }

  @Test
  func testChunksCurrentAndGaplessSuccessorInPlaybackOrder() async throws {
    let urls = try makeAudioFiles(named: ["First", "Second"])
    defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    let recorder = SegmentRecorder()
    let segmentLimit: AVAudioFrameCount = 2_000
    let tracks = [track("First", url: urls[0]), track("Second", url: urls[1])]
    let player = testPlayer(recorder: recorder, segmentLimit: segmentLimit)
    var qualifiedTracks: [String] = []
    player.onTrackQualifiedAsPlayed = { qualifiedTracks.append($0.title) }

    player.restore(
      queue: tracks, currentID: tracks[0].id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()

    let firstLength = try AVAudioFile(forReading: urls[0]).length
    let secondLength = try AVAudioFile(forReading: urls[1]).length
    let firstChunks = plannedChunks(frameCount: firstLength, maximumFrameCount: segmentLimit)
    let secondChunks = plannedChunks(frameCount: secondLength, maximumFrameCount: segmentLimit)
    #expect(firstChunks.count > 1)
    #expect(secondChunks.count > 1)
    #expect(recorder.segments.count == 1)

    for index in 0..<(firstChunks.count - 1) {
      #expect(recorder.segments[index].fileURL == urls[0])
      #expect(recorder.segments[index].chunk == firstChunks[index])
      #expect(recorder.segments[index].completionType == .dataConsumed)
      recorder.complete(at: index)
      await drainCompletionTask()
      #expect(player.currentTrack?.url == urls[0])
      #expect(qualifiedTracks.isEmpty)
    }

    await player.waitForPendingPreparation()
    #expect(recorder.segments.count == firstChunks.count + 1)
    #expect(recorder.segments[firstChunks.count - 1].fileURL == urls[0])
    #expect(recorder.segments[firstChunks.count - 1].chunk == firstChunks.last)
    #expect(recorder.segments[firstChunks.count - 1].completionType == .dataPlayedBack)
    #expect(recorder.segments[firstChunks.count].fileURL == urls[1])
    #expect(recorder.segments[firstChunks.count].chunk == secondChunks[0])

    recorder.complete(at: firstChunks.count - 1)
    await drainCompletionTask()
    #expect(player.currentTrack?.url == urls[1])
    #expect(qualifiedTracks == ["First"])

    for index in 0..<(secondChunks.count - 1) {
      let recorderIndex = firstChunks.count + index
      #expect(recorder.segments[recorderIndex].fileURL == urls[1])
      #expect(recorder.segments[recorderIndex].chunk == secondChunks[index])
      #expect(recorder.segments[recorderIndex].completionType == .dataConsumed)
      recorder.complete(at: recorderIndex)
      await drainCompletionTask()
      #expect(player.currentTrack?.url == urls[1])
      #expect(qualifiedTracks == ["First"])
    }

    let finalIndex = firstChunks.count + secondChunks.count - 1
    #expect(recorder.segments.count == finalIndex + 1)
    #expect(recorder.segments[finalIndex].chunk == secondChunks.last)
    #expect(recorder.segments[finalIndex].completionType == .dataPlayedBack)
    recorder.complete(at: finalIndex)
    await drainCompletionTask()
    #expect(player.currentTrack == nil)
    #expect(qualifiedTracks == ["First", "Second"])
  }

  @Test
  func testSeekStartsAChunkPlanAtTheRestoredFrameAndCancelsTheOldPlan() async throws {
    let url = try makeAudioFiles(named: ["Seek"])[0]
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = SegmentRecorder()
    let player = testPlayer(recorder: recorder, segmentLimit: 2_000)
    let item = track("Seek", url: url)
    player.restore(
      queue: [item], currentID: item.id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()
    #expect(recorder.segments.count == 1)

    player.seek(to: 0.5)
    #expect(recorder.segments.count == 2)
    #expect(recorder.segments[1].chunk.startingFrame > 0)
    let scheduledAfterSeek = recorder.segments.count

    recorder.complete(at: 0)
    await drainCompletionTask()
    #expect(recorder.segments.count == scheduledAfterSeek)
    #expect(player.currentTrack?.url == url)
    player.stop()
  }

  @Test
  func testStopCancelsAnIntermediateChunkCompletion() async throws {
    let url = try makeAudioFiles(named: ["Stop"])[0]
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = SegmentRecorder()
    let player = testPlayer(recorder: recorder, segmentLimit: 2_000)
    let item = track("Stop", url: url)
    player.restore(
      queue: [item], currentID: item.id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()
    #expect(recorder.segments.count == 1)

    player.stop()
    recorder.complete(at: 0)
    await drainCompletionTask()

    #expect(recorder.segments.count == 1)
    #expect(player.currentTrack == nil)
    #expect(player.playbackQueue.isEmpty)
  }

  @Test
  func testBookmarkedSuccessorBypassesGaplessStartAndResumesAtBookmark() async throws {
    let urls = try makeAudioFiles(named: ["First", "Bookmarked"])
    defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
    let recorder = SegmentRecorder()
    let tracks = [track("First", url: urls[0]), track("Bookmarked", url: urls[1])]
    let player = PlayerController(
      segmentScheduler: { _, file, startingFrame, frameCount, completionType, completion in
        recorder.append(
          fileURL: file.url,
          chunk: AudioFrameChunk(
            startingFrame: startingFrame,
            frameCount: frameCount,
            isFinal: completionType == .dataPlayedBack),
          completionType: completionType,
          completion: completion)
      },
      maximumFramesPerSegment: .max,
      engineStarter: { _ in throw CocoaError(.fileReadUnknown) })
    player.resumePositionProvider = { track in
      track.id == tracks[1].id ? 0.1 : nil
    }

    player.restore(
      queue: tracks, currentID: tracks[0].id, position: 0, volume: 0.8,
      shuffle: false, repeatMode: .off)
    await player.waitForPendingPreparation()

    #expect(player.gaplessSuccessorURL == nil)
    #expect(recorder.segments.count == 1)
    recorder.complete(at: 0)
    await drainCompletionTask()
    await player.waitForPendingPreparation()

    #expect(player.currentTrack?.id == tracks[1].id)
    #expect(abs(player.elapsed - 0.1) < 0.02)
    #expect(recorder.segments.count == 2)
    #expect(recorder.segments[1].chunk.startingFrame > 0)
    player.stop()
  }

  private func plannedChunks(
    startingFrame: AVAudioFramePosition = 0,
    frameCount: AVAudioFramePosition,
    maximumFrameCount: AVAudioFrameCount = .max
  ) -> [AudioFrameChunk] {
    guard
      var planner = AudioFrameChunkPlanner(
        startingFrame: startingFrame,
        frameCount: frameCount,
        maximumFrameCount: maximumFrameCount)
    else { return [] }
    var chunks: [AudioFrameChunk] = []
    while let chunk = planner.next() {
      chunks.append(chunk)
    }
    return chunks
  }

  private func testPlayer(
    recorder: SegmentRecorder,
    segmentLimit: AVAudioFrameCount
  ) -> PlayerController {
    PlayerController(
      segmentScheduler: { _, file, startingFrame, frameCount, completionType, completion in
        recorder.append(
          fileURL: file.url,
          chunk: AudioFrameChunk(
            startingFrame: startingFrame,
            frameCount: frameCount,
            isFinal: completionType == .dataPlayedBack),
          completionType: completionType,
          completion: completion)
      },
      maximumFramesPerSegment: segmentLimit,
      engineStarter: { _ in
        Issue.record("Paused scheduling tests must not start the audio engine")
      })
  }

  private func drainCompletionTask() async {
    await Task.yield()
    await Task.yield()
  }

  private func makeAudioFiles(named names: [String]) throws -> [URL] {
    try names.map { name in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NightdrivePlayerSchedulingTests-\(name)-\(UUID().uuidString).mp3")
      try MP3Builder.build(
        tags: .init(
          title: name, artist: "Artist", album: "Album", genre: "Genre",
          trackNumber: 1, year: 2026),
        seconds: 0.4
      ).write(to: url)
      return url
    }
  }

  private func track(_ title: String, url: URL) -> LibraryTrack {
    LibraryTrack(
      url: url, title: title, artist: "Artist", album: "Album", genre: "Genre", trackNumber: 1, trackCount: 1,
      discNumber: 1, year: 2026, durationMS: 400, sizeBytes: 1, bitrate: 128, samplerate: 44_100)
  }
}

@MainActor
private final class SegmentRecorder {
  struct Segment {
    let fileURL: URL
    let chunk: AudioFrameChunk
    let completionType: AVAudioPlayerNodeCompletionCallbackType
    let completion: @Sendable () -> Void
  }

  private(set) var segments: [Segment] = []

  func append(
    fileURL: URL,
    chunk: AudioFrameChunk,
    completionType: AVAudioPlayerNodeCompletionCallbackType,
    completion: @escaping @Sendable () -> Void
  ) {
    segments.append(
      Segment(
        fileURL: fileURL,
        chunk: chunk,
        completionType: completionType,
        completion: completion))
  }

  func complete(at index: Int) {
    segments[index].completion()
  }
}
