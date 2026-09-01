import SwiftUI

struct SyncDetailsView: View {
  let result: SyncResult
  @Environment(\.dismiss) private var dismiss

  private var model: SyncDetailsModel { SyncDetailsModel(result: result) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        Image(
          systemName: result.failures.isEmpty
            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 28))
        .foregroundStyle(result.failures.isEmpty ? Color.green : Color.orange)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 4) {
          Text(model.title)
            .font(.title2.bold())
          Text(model.summary)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
      .padding(20)

      Divider()

      if result.failures.isEmpty {
        ContentUnavailableView(
          "No Sync Issues",
          systemImage: "checkmark.circle",
          description: Text("Every planned copy completed successfully.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          Text("Failed Operations (\(result.failures.count))")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 16)

          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                failureRow(failure)
                Divider().padding(.leading, 46)
              }
            }
          }
        }
      }

      Divider()

      if !result.playlistActionSummaries.isEmpty || !result.playlistNotes.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Playlists")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 16)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
              ForEach(
                Array(result.playlistActionSummaries.enumerated()), id: \.offset
              ) { _, line in
                Label(line, systemImage: "music.note.list")
                  .font(.callout)
              }
              ForEach(Array(result.playlistNotes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle")
                  .font(.callout)
                  .foregroundStyle(.secondary)
              }
            }
            .padding(.horizontal, 20)
          }
          .frame(maxHeight: 160)
          .padding(.bottom, 10)
        }
        Divider()
      }

      if result.devicePlaybackNote != nil || !result.playbackNotes.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Listening")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 16)
          LazyVStack(alignment: .leading, spacing: 6) {
            if let note = result.devicePlaybackNote {
              Label(note, systemImage: "ipod")
                .font(.callout)
            }
            ForEach(Array(result.playbackNotes.enumerated()), id: \.offset) { _, note in
              Label(note, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 10)
        }
        Divider()
      }

      if !result.scopeNotes.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
          Text("Sync Scope")
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.top, 16)
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(result.scopeNotes.enumerated()), id: \.offset) { _, note in
              Label(note, systemImage: "scope")
                .font(.callout)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 10)
        }
        Divider()
      }

      HStack {
        Text("Latest completed sync")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 620)
    .frame(minHeight: 380, idealHeight: 480, maxHeight: 620)
  }

  private func failureRow(_ failure: SyncFailure) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: failure.operation.systemImage)
        .frame(width: 20)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 5) {
        Text(failure.operation.title)
          .font(.headline)
        Text(failure.path)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text(failure.reason)
          .font(.callout)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 13)
    .accessibilityElement(children: .combine)
  }
}
