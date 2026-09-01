#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI

  @MainActor
  final class DemoProgressPanel {
    private var panel: NSPanel?

    func show(for demo: DemoModeController) {
      hide()

      let hosting = NSHostingView(rootView: DemoProgressView(demo: demo))
      hosting.sizingOptions = [.preferredContentSize]

      let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: NSSize(width: 280, height: 90)),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false)
      panel.contentView = hosting
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = true
      panel.level = .statusBar
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      panel.isFloatingPanel = true
      panel.hidesOnDeactivate = false
      panel.ignoresMouseEvents = true
      panel.isReleasedWhenClosed = false
      panel.sharingType = .none

      hosting.layoutSubtreeIfNeeded()
      let size = hosting.fittingSize
      if size.width > 10, size.height > 10 {
        panel.setContentSize(size)
      }

      let screen = DemoInput.mainWindow?.screen ?? NSScreen.main
      if let visible = screen?.visibleFrame {
        let size = panel.frame.size
        let margin: CGFloat = 20
        panel.setFrameOrigin(
          NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin))
      }

      panel.orderFrontRegardless()
      self.panel = panel
    }

    func hide() {
      panel?.orderOut(nil)
      panel = nil
    }
  }

  private struct DemoProgressView: View {
    let demo: DemoModeController

    var body: some View {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 6) {
            Circle()
              .fill(recordingColor)
              .frame(width: 7, height: 7)
            Text(demo.activeTrackTitle ?? "Demo")
              .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 12)
            Text(remainingLabel(at: context.date))
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
          }

          ProgressView(value: fraction(at: context.date))
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(.red)

          HStack(spacing: 12) {
            if let phase = demo.currentPhase, let index = demo.phaseIndex {
              Text("\(index + 1)/\(demo.phases.count) · \(phase)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(demo.recorder.statusLabel)
              .font(.system(size: 10))
              .foregroundStyle(.tertiary)
          }
        }
        .frame(width: 240)
        .padding(12)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
            .overlay(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        )
        .padding(6)
      }
    }

    private func elapsed(at date: Date) -> Double {
      guard let startedAt = demo.startedAt else { return 0 }
      return max(date.timeIntervalSince(startedAt), 0)
    }

    private var recordingColor: Color {
      switch demo.recorder.state {
      case .recording: .red
      case .preparing, .finishing: .orange
      case .failed: .yellow
      case .idle, .finished: .secondary
      }
    }

    private func fraction(at date: Date) -> Double {
      guard demo.estimatedDuration > 0 else { return 0 }
      return min(elapsed(at: date) / demo.estimatedDuration, 1)
    }

    private func remainingLabel(at date: Date) -> String {
      let remaining = demo.estimatedDuration - elapsed(at: date)
      guard remaining > 0 else { return "wrapping up…" }
      let seconds = Int(remaining.rounded())
      return String(format: "-%d:%02d", seconds / 60, seconds % 60)
    }
  }
#endif
