import SwiftUI

#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  struct DemoMenuItems: View {
    let app: AppState

    var body: some View {
      ForEach(DemoTracks.primary) { track in
        Button(track.title) {
          app.demo.run(track)
        }
      }
      Section("Sizzle Sections") {
        ForEach(DemoTracks.sizzleSections) { track in
          Button(track.title) {
            app.demo.run(track)
          }
        }
      }
      Divider()
      Toggle(
        "Move the Real Cursor",
        isOn: Binding(
          get: { app.demo.cursor.useRealCursor },
          set: { app.demo.cursor.useRealCursor = $0 }))
      Toggle(
        "Record Videos Automatically",
        isOn: Binding(
          get: { app.demo.automaticallyRecordsVideo },
          set: { app.demo.automaticallyRecordsVideo = $0 }))
      Button("Show Last Demo Video in Finder") {
        app.demo.revealLastRecording()
      }
      .disabled(app.demo.lastRecordingURL == nil)
      Divider()
      Button("Stop Demo") {
        app.demo.stop()
      }
      .disabled(!app.demo.isRunning)
    }
  }
#endif

extension View {
  @ViewBuilder
  func demoOverlays(app: AppState) -> some View {
    #if NIGHTDRIVE_DEVELOPMENT_TOOLS
      self
        .overlay { DemoCursorOverlay(cursor: app.demo.cursor) }
        .overlay { DemoStageOverlay(stage: app.demo.stage) }
    #else
      self
    #endif
  }
}
