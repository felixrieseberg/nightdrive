import SwiftUI

struct UpNextView: View {
  @Bindable var player: PlayerController
  var trackSelection: Binding<Set<TrackID>> = .constant([])
  var onSaveQueue: ((String, [LibraryTrack]) throws -> Void)?

  @State private var showingSaveQueue = false
  @State private var playlistName = ""
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      queueHeader
      Bodywork.Seam()
      if player.playbackQueue.isEmpty, player.currentTrack == nil {
        ContentUnavailableView(
          "Queue Is Empty",
          systemImage: "text.line.last.and.arrowtriangle.forward",
          description: Text("Choose a song, add one from the library, or drop audio files and folders here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        queueList
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .alert("Save Queue as Playlist", isPresented: $showingSaveQueue) {
      TextField("Playlist name", text: $playlistName)
      Button("Cancel", role: .cancel) {}
      Button("Save") { saveQueue() }
        .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("This saves the played, current, and upcoming songs in their queue order.")
    }
    .errorAlert("Queue Couldn’t Be Saved", message: $errorMessage)
    .clearsTrackSelection(trackSelection, when: queueIsEmpty)
  }

  private var queueHeader: some View {
    PaneHeader(String(localized: "Up Next"), subtitle: queueSummary) {
      if onSaveQueue != nil {
        Button("Save as Playlist…") {
          playlistName = suggestedPlaylistName
          showingSaveQueue = true
        }
        .disabled(player.playbackQueue.isEmpty)
      }
      Button("Clear Up Next", role: .destructive) {
        player.clearUpNext()
      }
      .disabled(player.upNextTracks.isEmpty)
    }
  }

  private var queueList: some View {
    List(selection: trackSelection) {
      if !player.playbackHistory.isEmpty {
        Section("Played") {
          ForEach(Array(player.playbackHistory.enumerated()), id: \.offset) { _, track in
            QueueTrackRow(track: track, symbol: "checkmark", isDimmed: true)
              .tag(track.id)
          }
        }
      }

      if let currentTrack = player.currentTrack {
        Section("Now Playing") {
          QueueTrackRow(
            track: currentTrack,
            symbol: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill",
            isDimmed: false
          )
          .tag(currentTrack.id)
        }
      }

      Section("Up Next") {
        if player.upNextTracks.isEmpty {
          Text("Nothing else is queued.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(player.upNextTracks.enumerated()), id: \.offset) { offset, track in
            QueueTrackRow(
              track: track,
              position: offset + 1,
              isDimmed: false
            )
            .tag(track.id)
            .contextMenu {
              Button("Play Now") {
                player.playUpNext(at: offset)
              }
              Button("Remove from Queue", role: .destructive) {
                player.removeUpNext(at: IndexSet(integer: offset))
              }
            }
          }
          .onDelete(perform: player.removeUpNext)
          .onMove(perform: player.moveUpNext)
        }
      }
    }
    .trackCommands(selection: trackSelection, visibleIDs: visibleTrackIDs)
  }

  private var queueSummary: String {
    let count = player.playbackQueue.count
    guard count > 0 else { return String(localized: "Played, playing, and queued songs") }
    guard let number = player.currentTrackNumber else {
      return count == 1 ? String(localized: "1 song") : String(localized: "\(count) songs")
    }
    return String(localized: "Song \(number) of \(count)")
  }

  private var queueIsEmpty: Bool {
    player.playbackQueue.isEmpty && player.currentTrack == nil
  }

  private var visibleTrackIDs: Set<TrackID> {
    Set(
      player.playbackHistory.map(\.id)
        + [player.currentTrack?.id].compactMap { $0 }
        + player.upNextTracks.map(\.id))
  }

  private var suggestedPlaylistName: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"
    return String(localized: "Queue \(formatter.string(from: Date()))")
  }

  private func saveQueue() {
    do {
      try onSaveQueue?(playlistName, player.playbackQueue)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct QueueTrackRow: View {
  let track: LibraryTrack
  var position: Int?
  var symbol: String?
  let isDimmed: Bool

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let symbol {
          Image(systemName: symbol)
        } else if let position {
          Text(verbatim: "\(position)")
            .monospacedDigit()
        }
      }
      .foregroundStyle(.tertiary)
      .frame(minWidth: 20, alignment: .trailing)

      VStack(alignment: .leading, spacing: 2) {
        Text(track.displayTitle)
          .lineLimit(1)
        Text([track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — "))
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(LibraryTrack.formatDuration(ms: track.durationMS))
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .opacity(isDimmed ? 0.65 : 1)
  }
}
