#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  import AppKit
  import SwiftUI

  @MainActor
  @Observable
  final class DemoStage {
    var dipOpacity: Double = 0
    var endCardVisible = false
    var captureBadgeMaskVisible = false

    func showCaptureBadgeMask() {
      captureBadgeMaskVisible = true
    }

    func hideCaptureBadgeMask() {
      captureBadgeMaskVisible = false
    }

    @ObservationIgnored private var recordingWindowStyleMask: NSWindow.StyleMask?
    @ObservationIgnored private weak var shiftedSidebarTable: NSTableView?

    /// Strips the title bar for the length of a recording. macOS draws its
    /// purple "this window is being captured" capsule into the title bar of
    /// every titled window ScreenCaptureKit records, and it lands in the
    /// exported frames: the capsule is composited by the window server, so
    /// neither hiding the AppKit button container nor covering it with
    /// SwiftUI content removes it. A borderless window has no title bar for
    /// the capsule to live in. Call before the capture stream is created;
    /// `reset()` restores the original style.
    func prepareWindowForRecording() {
      guard let window = DemoInput.mainWindow, recordingWindowStyleMask == nil,
        window.styleMask.contains(.titled)
      else { return }
      recordingWindowStyleMask = window.styleMask
      window.styleMask.remove(.titled)
      compensateSidebarInset(in: window)
    }

    /// SwiftUI's sidebar `List` pads its first row by 13pt in a window
    /// without a title bar, while the rest of the layout stays put. Slide
    /// the table back so the recording matches the titled layout. Negative
    /// scroll-view insets are clamped, so this nudges the table's layer
    /// instead, which no layout pass rewrites.
    private func compensateSidebarInset(in window: NSWindow) {
      func firstDescendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
          if let found = firstDescendant(of: subview, as: type) { return found }
        }
        return nil
      }
      // The sidebar is the leading column of the navigation split view.
      guard let root = window.contentView,
        let splitView = firstDescendant(of: root, as: NSSplitView.self),
        let sidebarColumn = splitView.arrangedSubviews.first,
        let table = firstDescendant(of: sidebarColumn, as: NSTableView.self),
        table.numberOfRows > 0
      else { return }
      let shift = table.rect(ofRow: 0).minY
      guard shift > 0 else { return }
      table.wantsLayer = true
      table.layer?.transform = CATransform3DMakeTranslation(0, -shift, 0)
      shiftedSidebarTable = table
    }

    func coverWindowChrome() {
      guard let window = DemoInput.mainWindow else { return }
      setWindowChromeOpacity(0)
      for kind in Self.windowButtons {
        window.standardWindowButton(kind)?.isHidden = true
      }
    }

    func setWindowChromeOpacity(_ opacity: Double) {
      guard let window = DemoInput.mainWindow else { return }
      let clamped = CGFloat(max(0, min(1, opacity)))
      Self.titlebarContainer(in: window)?.alphaValue = clamped
    }

    func reset() {
      dipOpacity = 0
      endCardVisible = false
      captureBadgeMaskVisible = false
      shiftedSidebarTable?.layer?.transform = CATransform3DIdentity
      shiftedSidebarTable = nil
      if let window = DemoInput.mainWindow {
        if let recordingWindowStyleMask {
          window.styleMask = recordingWindowStyleMask
          self.recordingWindowStyleMask = nil
        }
        Self.titlebarContainer(in: window)?.alphaValue = 1
        for kind in Self.windowButtons {
          window.standardWindowButton(kind)?.isHidden = false
        }
      }
    }

    private static let windowButtons: [NSWindow.ButtonType] = [
      .closeButton, .miniaturizeButton, .zoomButton,
    ]

    private static func titlebarContainer(in window: NSWindow) -> NSView? {
      window.standardWindowButton(.closeButton)?.superview?.superview
    }
  }

  struct DemoStageOverlay: View {
    let stage: DemoStage
    let deckProgress: CGFloat

    var body: some View {
      ZStack(alignment: .topLeading) {
        if stage.captureBadgeMaskVisible {
          DemoCaptureBadgeMask(deckProgress: deckProgress)
        }
        if stage.endCardVisible {
          DemoEndCard()
        }
        DemoStage.dipColor
          .opacity(stage.dipOpacity)
          .ignoresSafeArea()
      }
      .allowsHitTesting(false)
    }
  }

  private struct DemoCaptureBadgeMask: View {
    let deckProgress: CGFloat

    private var faceplateHeight: CGFloat {
      HeadUnitBar.height + DeckMechanism.reservedHeight(deckProgress)
        + DeckMechanism.contentSpacing(deckProgress)
    }

    var body: some View {
      HeadUnitBar.faceplate
        .frame(width: 84, height: faceplateHeight)
        .frame(width: 84, height: HeadUnitBar.height, alignment: .top)
        .clipped()
        .ignoresSafeArea()
    }
  }

  extension DemoStage {
    static let dipColor = Color(red: 0.016, green: 0.02, blue: 0.024)
  }

  private struct DemoEndCard: View {
    @State private var breathe = false

    static let mint = Color(red: 0x73 / 255.0, green: 1.0, blue: 0xD6 / 255.0)
    static let amber = Color(red: 1.0, green: 0xB8 / 255.0, blue: 0x5C / 255.0)
    static let dim = Color(red: 0x5C / 255.0, green: 0x6E / 255.0, blue: 0x68 / 255.0)

    var body: some View {
      ZStack {
        DemoStage.dipColor
        RadialGradient(
          colors: [Self.mint.opacity(breathe ? 0.10 : 0.06), .clear],
          center: .center, startRadius: 0, endRadius: 560
        )
        content
      }
      .ignoresSafeArea()
      .onAppear {
        withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) {
          breathe = true
        }
      }
    }

    private var content: some View {
      VStack(spacing: 0) {
        Text(verbatim: "· p r e s e n t i n g ·")
          .font(.system(size: 13, design: .monospaced))
          .kerning(5)
          .foregroundStyle(Self.dim)
        WebsiteWordmark()
          .shadow(color: Self.mint.opacity(breathe ? 0.55 : 0.35), radius: 22)
          .shadow(color: Self.mint.opacity(0.9), radius: 4)
          .padding(.top, 22)
        Text(verbatim: "NOSTALGIC, NOT STUCK IN THE PAST")
          .font(.system(size: 15, weight: .semibold, design: .monospaced))
          .kerning(5)
          .foregroundStyle(Self.amber)
          .shadow(color: Self.amber.opacity(0.5), radius: 10)
          .padding(.top, 30)
        Text(verbatim: "Free for macOS")
          .font(.system(size: 20, weight: .semibold, design: .monospaced))
          .kerning(2)
          .foregroundStyle(VFD.accentInk)
          .padding(.horizontal, 38)
          .padding(.vertical, 15)
          .background(Capsule().fill(VFD.accent))
          .shadow(color: VFD.accent.opacity(0.45), radius: 18, y: 2)
          .padding(.top, 44)
      }
      .padding(40)
    }
  }

  /// The website hero's block-character wordmark, rendered cell-by-cell so
  /// the art stays seamless at any size (text rendering would leave
  /// line-height gaps through the solid blocks).
  private struct WebsiteWordmark: View {
    private static let art: [[Character]] = [
      "       ▄█▄    ███ ███   ▄██████▄  ███     ███ █████████ ████████▄   █████████▄  ███ ███     ███  ▄███████",
      "     ████▄░░ ███░███░▄██▀▀▀▀▀▀▀▀░███░░░  ███░█████████░███▀▀▀▀▀██▄░███▀▀▀▀▀███░███░░███░░ ███ ░███▀▀▀▀▀▀░░░",
      "    █████▄░░███░███░███░░░░░░░░░███░░░  ███░░░ ███░░░░███░░░░░███░███░░░░░███░███░░▀██▄░▄██▀░░███░░░░░░░░░",
      "   ███░███░███░███░███░░░▄▄▄▄▄ ███████████░░░ ███░░░ ███░░░  ███░███████████░███░░░███░███░░░███████",
      "  ███░░▀█████░███░███░░░█████░███▀▀▀▀▀███░░░ ███░░░ ███░░░  ███░███▀███▀▀▀▀░███░░░▀██▄██▀░░░███▀▀▀▀░░░",
      " ▓▓▓░░░▀▓▓▓▓░▓▓▓░▀▓▓▄▄▄▄▄▓▓▓░▓▓▓░░░░░▓▓▓░░░ ▓▓▓░░░ ▓▓▓▄▄▄▄▄▓▓▀░▓▓▓░░▀▓▓▄░░░▓▓▓░░░ ▓▓▓▓▓░░░░▓▓▓▄▄▄▄▄▄░",
      "▒▒▒░░░ ▀▒▀░░▒▒▒░░░▀▒▒▒▒▒▒▒▒░▒▒▒░░░  ▒▒▒░░░ ▒▒▒░░░ ▒▒▒▒▒▒▒▒▀░░░▒▒▒░░░ ▀▒▒▄░▒▒▒░░░  ▒▒▒░░░░  ▀▒▒▒▒▒▒▒░░░",
      "  ░░░    ░░░  ░░░   ░░░░░░░░░ ░░░     ░░░    ░░░    ░░░░░░░░░   ░░░    ░░░░ ░░░     ░░░      ░░░░░░░░",
    ].map(Array.init)

    private static let columns = art.map(\.count).max() ?? 1
    private static let cellWidth: CGFloat = 8
    private static let cellHeight: CGFloat = 13

    var body: some View {
      Canvas { context, size in
        let cellW = size.width / CGFloat(Self.columns)
        let cellH = size.height / CGFloat(Self.art.count)
        for (rowIndex, row) in Self.art.enumerated() {
          for (columnIndex, character) in row.enumerated() {
            var rect = CGRect(
              x: CGFloat(columnIndex) * cellW, y: CGFloat(rowIndex) * cellH,
              width: cellW, height: cellH)
            let alpha: Double
            switch character {
            case "█": alpha = 1
            case "▓": alpha = 0.62
            case "▒": alpha = 0.35
            case "░": alpha = 0.13
            case "▄":
              alpha = 1
              rect.origin.y += cellH / 2
              rect.size.height = cellH / 2
            case "▀":
              alpha = 1
              rect.size.height = cellH / 2
            default: continue
            }
            context.fill(Path(rect), with: .color(DemoEndCard.mint.opacity(alpha)))
          }
        }
      }
      .frame(
        width: CGFloat(Self.columns) * Self.cellWidth,
        height: CGFloat(Self.art.count) * Self.cellHeight)
    }
  }
#endif
