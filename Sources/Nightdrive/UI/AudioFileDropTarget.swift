import SwiftUI

private struct AudioFileDropTarget: ViewModifier {
  let prompt: String
  let accessibilityHint: String
  let perform: ([URL]) -> Void

  @State private var isTargeted = false

  func body(content: Content) -> some View {
    content
      .dropDestination(for: URL.self) { urls, _ in
        guard AudioFileOpening.canAcceptDrop(urls) else { return false }
        perform(urls)
        return true
      } isTargeted: {
        isTargeted = $0
      }
      .overlay {
        if isTargeted {
          ZStack {
            Bodywork.panel.opacity(0.82)
            RoundedRectangle(cornerRadius: 14)
              .stroke(VFD.accent, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
              .padding(12)
            Label(prompt, systemImage: "waveform.badge.plus")
              .font(.title3.weight(.semibold))
              .foregroundStyle(VFD.accent)
              .padding(.horizontal, 18)
              .padding(.vertical, 12)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
          }
          .allowsHitTesting(false)
          .accessibilityElement(children: .combine)
          .accessibilityLabel(prompt)
          .accessibilityHint(accessibilityHint)
        }
      }
  }
}

extension View {
  func audioFileDropTarget(
    prompt: String, accessibilityHint: String, perform: @escaping ([URL]) -> Void
  ) -> some View {
    modifier(
      AudioFileDropTarget(
        prompt: prompt, accessibilityHint: accessibilityHint, perform: perform))
  }
}
