import CoreServices
import Foundation

final class RecursiveFolderWatcher {
  struct Event: Sendable {
    let url: URL
    let flags: FSEventStreamEventFlags
  }

  private final class CallbackState {
    let onChange: @Sendable ([Event]) -> Void

    init(onChange: @escaping @Sendable ([Event]) -> Void) {
      self.onChange = onChange
    }
  }

  private let callbackState: CallbackState
  private let eventQueue: DispatchQueue
  private var stream: FSEventStreamRef?

  init?(
    folderURL: URL,
    latency: TimeInterval = 0.2,
    onChange: @escaping @Sendable ([Event]) -> Void
  ) {
    let callbackState = CallbackState(onChange: onChange)
    self.callbackState = callbackState
    eventQueue = DispatchQueue(
      label: "com.nightdrive.library-folder-events",
      qos: .utility)

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(callbackState).toOpaque(),
      retain: { info in
        guard let info else { return nil }
        return UnsafeRawPointer(
          Unmanaged<CallbackState>.fromOpaque(info).retain().toOpaque())
      },
      release: { info in
        guard let info else { return }
        Unmanaged<CallbackState>.fromOpaque(info).release()
      },
      copyDescription: nil)
    let callback: FSEventStreamCallback = {
      _, info, eventCount, eventPaths, eventFlags, _ in
      guard eventCount > 0, let info else { return }
      let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
      var events: [Event] = []
      events.reserveCapacity(eventCount)
      for index in 0..<eventCount {
        events.append(
          Event(
            url: URL(fileURLWithPath: String(cString: paths[index])),
            flags: eventFlags[index]))
      }
      Unmanaged<CallbackState>.fromOpaque(info).takeUnretainedValue().onChange(events)
    }
    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
    guard
      let stream = FSEventStreamCreate(
        nil,
        callback,
        &context,
        [folderURL.standardizedFileURL.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        flags)
    else { return nil }

    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, eventQueue)
    guard FSEventStreamStart(stream) else {
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
      return nil
    }
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
