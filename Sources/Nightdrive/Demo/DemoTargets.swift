import SwiftUI

#if NIGHTDRIVE_DEVELOPMENT_TOOLS
  @MainActor
  final class DemoTargetRegistry {
    static let shared = DemoTargetRegistry()

    private struct Entry {
      var frame: CGRect?
      var action: (() -> Void)?
      var updatedAt: ContinuousClock.Instant = .now
    }

    private var entries: [String: [UUID: Entry]] = [:]

    func update(_ id: String, instance: UUID, frame: CGRect) {
      entries[id, default: [:]][instance, default: Entry()].frame = frame
      entries[id]?[instance]?.updatedAt = .now
    }

    func update(_ id: String, instance: UUID, action: (() -> Void)?) {
      entries[id, default: [:]][instance, default: Entry()].action = action
    }

    func remove(_ id: String, instance: UUID) {
      entries[id]?.removeValue(forKey: instance)
      if entries[id]?.isEmpty == true {
        entries.removeValue(forKey: id)
      }
    }

    private func latest<T>(_ id: String, having field: (Entry) -> T?) -> T? {
      entries[id]?.values
        .sorted(by: { $0.updatedAt > $1.updatedAt })
        .lazy.compactMap(field).first
    }

    struct Target {
      let frame: CGRect
      let action: (() -> Void)?
    }

    /// Every live instance of a target id, for callers that need to choose
    /// among repeated rows (for example, the first one actually on screen).
    func targets(of id: String) -> [Target] {
      entries[id]?.values.compactMap { entry in
        guard let frame = entry.frame, frame.width > 0, frame.height > 0 else { return nil }
        return Target(frame: frame, action: entry.action)
      } ?? []
    }

    func frame(of id: String) -> CGRect? {
      guard let frame = latest(id, having: \.frame), frame.width > 0, frame.height > 0 else {
        return nil
      }
      return frame
    }

    func action(of id: String) -> (() -> Void)? {
      latest(id, having: \.action)
    }
  }

  private final class DemoTargetFrameBox {
    var frame: CGRect?
  }

  private struct DemoTargetModifier: ViewModifier {
    let id: String
    let press: (() -> Void)?

    @State private var instance = UUID()
    @State private var lastFrame = DemoTargetFrameBox()

    func body(content: Content) -> some View {
      DemoTargetRegistry.shared.update(id, instance: instance, action: press)
      return
        content
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .global)
        } action: { frame in
          lastFrame.frame = frame
          DemoTargetRegistry.shared.update(id, instance: instance, frame: frame)
        }
        .onAppear {
          DemoTargetRegistry.shared.update(id, instance: instance, action: press)
          if let frame = lastFrame.frame {
            DemoTargetRegistry.shared.update(id, instance: instance, frame: frame)
          }
        }
        .onDisappear {
          DemoTargetRegistry.shared.remove(id, instance: instance)
        }
    }
  }

  extension View {
    func demoTarget(_ id: String, press: (() -> Void)? = nil) -> some View {
      modifier(DemoTargetModifier(id: id, press: press))
    }
  }
#else
  extension View {
    func demoTarget(_ id: String, press: (() -> Void)? = nil) -> some View { self }
  }
#endif
