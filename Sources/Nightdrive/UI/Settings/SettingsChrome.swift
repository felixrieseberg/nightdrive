import AppKit
import SwiftUI

enum SettingsMetrics {
  static let railWidth: CGFloat = 186
  static let contentTopInset: CGFloat = 4
  static let toolbarReservationWidth: CGFloat = 210
  static let toolbarReservationHeight: CGFloat = 22
  static let gutter: CGFloat = 20
  static let statusBarHeight: CGFloat = 34
}

enum SettingsSurface {
  static let rail = shade(light: 0.940, dark: Bodywork.Level.panel)
  static let list = shade(light: 0.958, dark: Bodywork.Level.panel)
  static let pane = shade(light: 0.978, dark: Bodywork.Level.panel)
  static let bar = shade(light: 0.955, dark: Bodywork.Level.raised)
  static let card = shade(light: 1.000, dark: Bodywork.Level.raised)
  static let hairline = shade(
    light: 0.855, dark: Bodywork.Level.hairline,
    lightContrast: 0.560, darkContrast: 0.520)

  private static func shade(
    light: CGFloat, dark: CGFloat,
    lightContrast: CGFloat? = nil, darkContrast: CGFloat? = nil
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
          .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        return switch match {
        case .darkAqua: Bodywork.nsGrey(dark)
        case .accessibilityHighContrastDarkAqua: Bodywork.nsGrey(darkContrast ?? dark)
        case .accessibilityHighContrastAqua: NSColor(white: lightContrast ?? light, alpha: 1)
        default: NSColor(white: light, alpha: 1)
        }
      })
  }
}

struct SettingsRail: View {
  @Binding var selection: SettingsTab

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Spacer().frame(height: SettingsMetrics.contentTopInset)
      ForEach(SettingsTab.allCases) { tab in
        item(tab)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(width: SettingsMetrics.railWidth)
    .frame(maxHeight: .infinity)
    .background(SettingsSurface.rail)
    .overlay(alignment: .trailing) {
      Rectangle().fill(SettingsSurface.hairline).frame(width: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Settings panes")
  }

  private func item(_ tab: SettingsTab) -> some View {
    let isSelected = tab == selection
    return Button {
      selection = tab
    } label: {
      HStack(spacing: 9) {
        Image(systemName: tab.symbol)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(VFD.glow)
          .frame(width: 19, height: 19)
          .background(PaneTile())
        Text(tab.title)
          .font(.system(size: 13))
          .foregroundStyle(isSelected ? AnyShapeStyle(VFD.accent) : AnyShapeStyle(.primary))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      .contentShape(RoundedRectangle(cornerRadius: 7))
      .background {
        RoundedRectangle(cornerRadius: 7)
          .fill(VFD.accent.opacity(isSelected ? 0.16 : 0))
      }
    }
    .buttonStyle(.plain)
    .keyboardShortcut(tab.shortcut, modifiers: .command)
    .accessibilityLabel(tab.title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
  }
}

private struct PaneTile: View {
  var body: some View {
    RoundedRectangle(cornerRadius: 5)
      .fill(
        LinearGradient(
          colors: [Bodywork.grey(0.185), Bodywork.grey(0.105)],
          startPoint: .top, endPoint: .bottom)
      )
      .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.7), lineWidth: 1))
      .overlay(alignment: .top) {
        RoundedRectangle(cornerRadius: 4)
          .strokeBorder(.white.opacity(0.10), lineWidth: 1)
          .padding(1)
          .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
      }
  }
}

struct SettingsWindowChrome: NSViewRepresentable {
  let title: String

  final class Accessor: NSView {
    var title = ""

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      apply()
      DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    func apply() {
      guard let window else { return }
      window.title = title
      window.toolbarStyle = .unifiedCompact
      window.titleVisibility = .visible
      // Keep the unified toolbar's background out of the full-width drag region.
      // On newer macOS releases it otherwise appears as a grey material on hover.
      window.titlebarAppearsTransparent = true
      window.titlebarSeparatorStyle = .line
      window.backgroundColor = Bodywork.nsGrey(Bodywork.Level.panel)
      // Point initial focus at this non-focusable accessor so no field opens focused.
      window.initialFirstResponder = self
      if window.firstResponder is NSText { window.makeFirstResponder(nil) }
    }
  }

  func makeNSView(context: Context) -> Accessor {
    let view = Accessor()
    view.title = title
    return view
  }

  func updateNSView(_ view: Accessor, context: Context) {
    view.title = title
    view.apply()
  }
}

struct SettingsStatusBar<Trailing: View>: View {
  let text: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 8)
      trailing
    }
    .controlSize(.small)
    .padding(.horizontal, SettingsMetrics.gutter)
    .frame(height: SettingsMetrics.statusBarHeight)
    .frame(maxWidth: .infinity)
    .background(SettingsSurface.bar)
    .overlay(alignment: .top) {
      Rectangle().fill(SettingsSurface.hairline).frame(height: 1)
    }
  }
}

struct SettingsHeading: View {
  let title: String
  var subtitle: String?

  init(_ title: String, subtitle: String? = nil) {
    self.title = title
    self.subtitle = subtitle
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.primary)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

struct SettingsCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(SettingsSurface.card, in: SettingsCard.shape)
    .overlay {
      SettingsCard.shape.strokeBorder(SettingsSurface.hairline, lineWidth: 1)
    }
  }

  static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 9, style: .continuous) }
}

struct SettingsCardDivider: View {
  var body: some View {
    Rectangle()
      .fill(SettingsSurface.hairline)
      .frame(height: 1)
      .padding(.leading, 14)
  }
}

struct SettingsSwitchRow: View {
  let title: String
  let subtitle: String
  let isOn: Binding<Bool>

  init(_ title: String, subtitle: String, isOn: Binding<Bool>) {
    self.title = title
    self.subtitle = subtitle
    self.isOn = isOn
  }

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.system(size: 13))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Toggle(String(), isOn: isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .accessibilityLabel(title)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }
}

struct SettingsNotice<Actions: View>: View {
  enum Tone {
    case problem
    case news

    var symbol: String {
      switch self {
      case .problem: "exclamationmark.triangle.fill"
      case .news: "info.circle.fill"
      }
    }

    @MainActor
    var ink: Color {
      switch self {
      case .problem: .orange
      case .news: VFD.accent
      }
    }

    var wash: Double {
      switch self {
      case .problem: 0.10
      case .news: 0.08
      }
    }
  }

  let tone: Tone
  let headline: String
  var lines: [String] = []
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: tone.symbol)
        .font(.system(size: 13))
        .foregroundStyle(tone.ink)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(headline)
          .font(.system(size: 12, weight: .semibold))
        ForEach(lines, id: \.self) { line in
          Text(line)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 8) { actions }
        .controlSize(.small)

    }
    .padding(.horizontal, SettingsMetrics.gutter)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tone.ink.opacity(tone.wash), ignoresSafeAreaEdges: [])
    .accessibilityElement(children: .contain)
    .accessibilityLabel(headline)
  }
}

/// The shared scroll scaffold every settings pane sits inside: a centered
/// column capped at 580 points that fills the pane's width.
struct SettingsPaneScroll<Content: View>: View {
  var spacing: CGFloat = 24
  @ViewBuilder var content: Content

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: spacing) {
          content
        }
        .frame(maxWidth: 580, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: proxy.size.width)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
  }
}

struct SettingsFootnote: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 3)
  }
}
