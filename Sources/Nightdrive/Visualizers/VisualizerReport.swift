import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
enum VisualizerReport {
  nonisolated static let maximumPreviewPixels: CGFloat = 4_194_304
  nonisolated static let maximumPreviewDimension: CGFloat = 8_192
  nonisolated private static let previewScale: CGFloat = 2
  nonisolated private static let previewInset: CGFloat = 6

  nonisolated static func isSafePreviewSize(_ size: CGSize) -> Bool {
    guard size.width.isFinite, size.height.isFinite,
      size.width > 16, size.height > 8,
      size.width <= maximumPreviewDimension, size.height <= maximumPreviewDimension
    else { return false }
    let pixelWidth = (size.width + previewInset * 2) * previewScale
    let pixelHeight = (size.height + previewInset * 2) * previewScale
    return pixelHeight > 0 && pixelWidth <= maximumPreviewPixels / pixelHeight
  }

  static func run(
    folder: VisualizerPluginFolder, renderTo previews: URL?,
    colorways: [VisualizerColorway] = [.default],
    size: CGSize = VisualizerSample.defaultPreviewSize
  ) -> Int32 {
    precondition(Thread.isMainThread, "Visualizer previews must render on the main thread")
    guard isSafePreviewSize(size) else {
      print(String(localized: "Visualizer preview size is outside the supported pixel budget."))
      return 1
    }
    let registry = VisualizerRegistry(folder: folder)
    var isReady = false
    Task { @MainActor in
      await registry.waitUntilReady()
      isReady = true
    }
    while !isReady {
      _ = RunLoop.main.run(
        mode: .default, before: Date(timeIntervalSinceNow: 0.01))
    }
    print(String(localized: "Visualizer plugins: \(folder.url.path)"))

    var failures = registry.issues.count
    for issue in registry.issues {
      print(String(localized: "  ! \(issue.source): \(issue.message)"))
    }

    if let previews {
      try? FileManager.default.createDirectory(
        at: previews, withIntermediateDirectories: true)
    }
    let tubes = colorways.isEmpty ? [VisualizerColorway.default] : colorways

    for descriptor in registry.descriptors {
      let paddedID = descriptor.id.padded(20)
      let label =
        descriptor.isPlugin
        ? String(localized: "  [plugin ] \(paddedID) \(descriptor.name)")
        : String(localized: "  [builtin] \(paddedID) \(descriptor.name)")

      var render: ((VisualizerFrame) -> DisplayList?)?
      let mode = registry.visualizer(id: descriptor.id)
      if descriptor.isPlugin {
        mode?.reset()
        switch registry.smokeTest(id: descriptor.id, frame: sampleFrame(size: size)) {
        case .success(let drawn):
          render = { frame in
            guard case .success(let drawn) = registry.smokeTest(id: descriptor.id, frame: frame)
            else { return nil }
            return drawn
          }
          let detail =
            drawn.isEmpty
            ? String(localized: "drew nothing")
            : String(localized: "\(drawn.ops.count) ops, \(drawn.texts.count) strings")
          print(String(localized: "\(label) — \(detail)"))
          if drawn.isEmpty { failures += 1 }
        case .failure(let issue):
          print(String(localized: "\(label) — FAILED"))
          print(String(localized: "      \(issue.message)"))
          failures += 1
          continue
        }
      } else {
        print(label)
      }

      if let previews {
        for tube in tubes {
          let suffix = tubes.count == 1 ? "" : "-\(tube.id)"
          let url = previews.appendingPathComponent("\(descriptor.id)\(suffix).png")
          if writePreview(
            visualizer: descriptor.isPlugin ? nil : mode,
            list: render, reset: { mode?.reset() }, palette: tube.palette, size: size, to: url)
          {
            print(String(localized: "      preview: \(url.path)"))
          } else {
            print(String(localized: "      preview failed"))
            failures += 1
          }
        }
      }
    }

    if failures == 0 {
      print(String(localized: "\(registry.descriptors.count) modes"))
    } else if failures == 1 {
      print(String(localized: "\(registry.descriptors.count) modes, 1 problem"))
    } else {
      print(String(localized: "\(registry.descriptors.count) modes, \(failures) problems"))
    }
    return failures == 0 ? 0 : 1
  }

  private static let warmUpFrames = 56

  static func writePreview(
    visualizer: (any Visualizer)?, list: ((VisualizerFrame) -> DisplayList?)?,
    reset: () -> Void, palette: VisualizerPalette, size: CGSize, to url: URL
  ) -> Bool {
    var failed = false
    func render(at time: TimeInterval) -> CGImage? {
      let frame = VisualizerSample.frame(size: size, at: time, palette: palette)
      let displayList: DisplayList?
      if let list {
        guard let rendered = list(frame) else {
          failed = true
          return nil
        }
        displayList = rendered
      } else {
        displayList = nil
      }

      let renderer = ImageRenderer(
        content: VisualizerPreview(visualizer: visualizer, list: displayList, frame: frame)
          .frame(
            width: frame.width + VisualizerPreview.inset * 2,
            height: frame.height + VisualizerPreview.inset * 2))
      renderer.scale = previewScale
      return renderer.cgImage
    }

    reset()
    var image: CGImage?
    for step in 0...warmUpFrames {
      image = render(at: Double(step) / 24.0)
    }

    guard !failed, let image,
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "public.png" as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
  }

  private static func sampleFrame(size: CGSize = VisualizerSample.defaultPreviewSize)
    -> VisualizerFrame
  {
    VisualizerSample.base(size: size)
  }
}

private struct VisualizerPreview: View {
  let visualizer: (any Visualizer)?
  let list: DisplayList?
  let frame: VisualizerFrame

  static let inset: CGFloat = 6

  var body: some View {
    ZStack {
      Rectangle().fill(Color(red: 0.02, green: 0.028, blue: 0.033))
      Canvas { context, size in
        var frame = frame
        frame.size = size
        if let visualizer {
          visualizer.draw(frame, into: &context)
        } else if let list {
          list.render(into: &context)
        }
      }
      .frame(width: frame.width, height: frame.height)
      VFDScanlines()
    }
  }
}

extension String {
  fileprivate func padded(_ width: Int) -> String {
    count >= width ? self : self + String(repeating: " ", count: width - count)
  }
}
