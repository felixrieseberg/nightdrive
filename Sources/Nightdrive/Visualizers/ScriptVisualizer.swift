import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class ScriptVisualizer: Visualizer {
  let descriptor: VisualizerDescriptor

  private let runtime: VisualizerScriptRuntime
  private var list = DisplayList()
  private var inFlight = false
  private var generation: UInt64 = 0
  private(set) var failure: String?

  init(descriptor: VisualizerDescriptor, runtime: VisualizerScriptRuntime) {
    self.descriptor = descriptor
    self.runtime = runtime
  }

  func reset() {
    generation &+= 1
    list = DisplayList()
    inFlight = false
    runtime.reset(id: descriptor.id)
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    if let failure {
      Self.drawFailure(failure, name: descriptor.name, frame: frame, into: &ctx)
      return
    }
    // A drag replays the last list at the new size rather than asking the
    // script for another one.
    if !inFlight, !frame.isLiveResizing {
      inFlight = true
      let requestedGeneration = generation
      runtime.render(id: descriptor.id, frame: frame) { [weak self] result in
        guard let self, self.generation == requestedGeneration else { return }
        self.inFlight = false
        switch result {
        case .success(let list): self.list = list
        case .failure(let issue): self.failure = issue.message
        }
      }
    }
    list.render(into: &ctx)
  }

  private static func drawFailure(
    _ message: String, name: String, frame: VisualizerFrame, into ctx: inout GraphicsContext
  ) {
    let palette = frame.palette
    var card = ctx
    card.clip(to: Path(CGRect(origin: .zero, size: frame.size)))

    card.glowing(palette.amber, radius: 2)
      .draw(
        Text("\(name) — PLUGIN ERROR")
          .font(VFD.label(11, weight: .bold))
          .foregroundStyle(palette.amber.color),
        at: CGPoint(x: 4, y: 8), anchor: .leading)
    card.draw(
      Text(message)
        .font(VFD.label(8.5))
        .foregroundStyle(palette.amber.opacity(0.7).color),
      at: CGPoint(x: 4, y: 21), anchor: .leading)
    if frame.height >= 38 {
      card.draw(
        Text("EDIT THE FILE AND CHOOSE CONTROLS ▸ VISUALIZER ▸ RELOAD PLUGINS")
          .font(VFD.label(7))
          .foregroundStyle(palette.dim.color),
        at: CGPoint(x: 4, y: 33), anchor: .leading)
    }
  }
}
