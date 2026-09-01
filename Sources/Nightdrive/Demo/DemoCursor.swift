#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI

  @MainActor
  @Observable
  final class DemoCursor {
    var position = CGPoint(x: 200, y: 200) {
      didSet { if useRealCursor { warpRealCursor() } }
    }
    var visible = false {
      didSet { if visible, useRealCursor { warpRealCursor() } }
    }
    var pressed = false
    var clickPulse = 0

    var useRealCursor = NightdriveDefaults.current.bool(forKey: useRealCursorKey) {
      didSet {
        NightdriveDefaults.current.set(useRealCursor, forKey: DemoCursor.useRealCursorKey)
        if useRealCursor, visible { warpRealCursor() }
      }
    }

    private static let useRealCursorKey = "demo.useRealCursor"

    private func warpRealCursor() {
      guard let window = DemoInput.mainWindow else { return }
      let inWindow = CGPoint(x: position.x, y: window.frame.height - position.y)
      let onScreen = window.convertPoint(toScreen: inWindow)
      let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
      CGWarpMouseCursorPosition(CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y))
    }
  }

  struct DemoCursorOverlay: View {
    let cursor: DemoCursor

    var body: some View {
      GeometryReader { proxy in
        let origin = proxy.frame(in: .global).origin
        if cursor.visible && !cursor.useRealCursor {
          ZStack(alignment: .topLeading) {
            ClickRipple(pulse: cursor.clickPulse)
              .position(
                x: cursor.position.x - origin.x,
                y: cursor.position.y - origin.y)
            arrow
              .scaleEffect(cursor.pressed ? 0.86 : 1, anchor: .topLeading)
              .animation(.spring(duration: 0.18), value: cursor.pressed)
              .offset(
                x: cursor.position.x - origin.x - hotSpot.x,
                y: cursor.position.y - origin.y - hotSpot.y)
          }
          .transition(.opacity)
        }
      }
      .allowsHitTesting(false)
      .animation(.easeInOut(duration: 0.3), value: cursor.visible)
    }

    private var hotSpot: CGPoint { NSCursor.arrow.hotSpot }

    private var arrow: some View {
      Image(nsImage: NSCursor.arrow.image)
        .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    }
  }

  private struct ClickRipple: View {
    let pulse: Int
    @State private var animating = false

    var body: some View {
      Circle()
        .stroke(VFD.accent.opacity(animating ? 0 : 0.75), lineWidth: 2.5)
        .frame(width: 14, height: 14)
        .scaleEffect(animating ? 3.2 : 0.4)
        .opacity(pulse == 0 ? 0 : 1)
        .onChange(of: pulse) {
          animating = false
          withAnimation(.easeOut(duration: 0.5)) {
            animating = true
          }
        }
    }
  }
#endif
