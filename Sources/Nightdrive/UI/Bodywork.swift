import AppKit
import SwiftUI

enum ChassisMetrics {
  static let edgeInset: CGFloat = 14
  static let paneHeaderHeight: CGFloat = 60
}

/// The shared title strip at the top of a detail pane: a bold title with a
/// caption subtitle on the leading edge, optional accessories trailing, on a
/// raised background that absorbs the deck's content spacing.
struct PaneHeader<Accessories: View>: View {
  @Environment(\.deckContentSpacing) private var deckContentSpacing

  let title: String
  let subtitle: String
  @ViewBuilder var accessories: Accessories

  init(_ title: String, subtitle: String, @ViewBuilder accessories: () -> Accessories = { EmptyView() }) {
    self.title = title
    self.subtitle = subtitle
    self.accessories = accessories()
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.title2.bold())
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      accessories
    }
    .padding(.leading, 20)
    .padding(.trailing, ChassisMetrics.edgeInset)
    .frame(maxWidth: .infinity)
    .frame(height: max(0, ChassisMetrics.paneHeaderHeight - deckContentSpacing))
    .background(Bodywork.raised)
  }
}

enum Bodywork {
  enum Level {
    static let cavity: CGFloat = 0.016
    static let hairline: CGFloat = 0.028
    static let well: CGFloat = 0.040
    static let panel: CGFloat = 0.055
    static let raised: CGFloat = 0.082
    static let faceplate: CGFloat = 0.115
  }

  static let faceplateTop = grey(Level.faceplate)
  static let faceplateBottom = grey(Level.panel)

  static let cavity = grey(Level.cavity)
  static let panel = faceplateBottom

  static let raised = grey(Level.raised)
  static let well = grey(Level.well)
  static let hairline = grey(Level.hairline)

  static func grey(_ value: CGFloat) -> Color {
    Color(nsColor: nsGrey(value))
  }

  struct Seam: View {
    enum VerticalHitPlacement {
      case centered
      case insideLeadingEdge
      case insideTrailingEdge
    }

    static let verticalHitWidth: CGFloat = 11

    var axis: Axis = .horizontal
    var verticalHitPlacement: VerticalHitPlacement = .centered
    var showsSeparator = true

    @ViewBuilder
    var body: some View {
      if axis == .vertical {
        switch verticalHitPlacement {
        case .centered:
          verticalHandle(alignment: .center)
            .frame(width: Self.verticalHitWidth)
            .offset(x: Self.verticalHitWidth / 2)
        case .insideLeadingEdge:
          verticalHandle(alignment: .leading)
            .frame(width: ceil(Self.verticalHitWidth / 2))
        case .insideTrailingEdge:
          verticalHandle(alignment: .trailing)
            .frame(width: ceil(Self.verticalHitWidth / 2))
        }
      } else {
        Rectangle()
          .fill(Bodywork.hairline)
          .frame(height: 1)
          .allowsHitTesting(false)
      }
    }

    private func verticalHandle(alignment: Alignment) -> some View {
      ZStack(alignment: alignment) {
        SplitViewDividerHandle()
        if showsSeparator {
          Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .allowsHitTesting(false)
        }
      }
    }
  }

  static func nsGrey(_ value: CGFloat) -> NSColor {
    NSColor(srgbRed: value, green: value * 1.087, blue: value * 1.217, alpha: 1)
  }
}

private struct SplitViewDividerHandle: NSViewRepresentable {
  func makeNSView(context: Context) -> SplitViewDividerHandleView {
    SplitViewDividerHandleView()
  }

  func updateNSView(_ view: SplitViewDividerHandleView, context: Context) {}
}

@MainActor
final class SplitViewDividerHandleView: NSView {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .resizeLeftRight)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func mouseDown(with event: NSEvent) {
    guard
      let splitView = splitViewToResize(),
      let divider = splitView.arrangedSubviews.first,
      let window
    else { return }
    let grabOffset = splitView.convert(event.locationInWindow, from: nil).x - divider.frame.maxX

    while let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
      if event.type == .leftMouseUp { return }
      let pointerX = splitView.convert(event.locationInWindow, from: nil).x
      moveDivider(in: splitView, to: pointerX - grabOffset)
    }
  }

  func moveDivider(in splitView: NSSplitView, to proposedPosition: CGFloat) {
    let position = min(
      max(proposedPosition, splitView.minPossiblePositionOfDivider(at: 0)),
      splitView.maxPossiblePositionOfDivider(at: 0))
    splitView.setPosition(position, ofDividerAt: 0)
  }

  func splitViewToResize() -> NSSplitView? {
    var ancestor = superview
    while let view = ancestor {
      if let splitView = view as? NSSplitView, splitView.isVertical {
        return splitView
      }
      ancestor = view.superview
    }
    return nil
  }
}
