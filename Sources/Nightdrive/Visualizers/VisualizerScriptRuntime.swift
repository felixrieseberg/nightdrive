import CJSCExecutionTimeLimit
import Foundation
import JavaScriptCore
import Synchronization

struct VisualizerScript: Sendable {
  var name: String
  var source: String
}

struct VisualizerScriptIssue: Error, Sendable, Identifiable, Hashable {
  var id: String { "\(source):\(message)" }
  var source: String
  var message: String
}

struct VisualizerScriptLoadResult: Sendable {
  var descriptors: [VisualizerDescriptor]
  var issues: [VisualizerScriptIssue]
}

/// Runs plugins in a deliberately bare JavaScriptCore context — no file
/// system, network, timers, or `require`. All script work happens on one
/// private serial queue, and every entry is bounded by a JavaScriptCore
/// execution time limit, so a runaway plugin is interrupted and reported
/// rather than wedging the queue. Sharing that queue means it can still stall
/// the others for up to one window per frame before it is switched off.
final class VisualizerScriptRuntime: @unchecked Sendable {
  static let maximumVisualizerCount = 256
  static let maximumOperationValues = 200_000
  static let maximumTextCount = 20_000
  static let maximumTextBytes = 1_048_576

  // Scripts run off-main and terminate after the time limit.
  private let queue = DispatchQueue(
    label: "dev.nightdrive.visualizer-scripts", qos: .userInitiated)
  static let executionTimeLimit: TimeInterval = 1.0
  private var context: JSContext?
  private var setSourceFile: JSValue?
  /// JavaScriptCore calls the exception handler on whichever thread runs the
  /// script — the runtime queue normally, engine internals on a watchdog
  /// termination — so this uses a mutex rather than assuming queue confinement.
  private let exceptions = Mutex<String?>(nil)
  private var files: [String: String] = [:]
  let watchdogAvailable: Bool

  private func takeException() -> String? {
    exceptions.withLock { message in
      defer { message = nil }
      return message
    }
  }

  private func clearException() {
    exceptions.withLock { $0 = nil }
  }

  init(watchdogEnabled: Bool = true) {
    watchdogAvailable = watchdogEnabled && CJSCExecutionTimeLimitAvailable()
  }

  // MARK: - Loading

  func load(_ scripts: [VisualizerScript]) async -> VisualizerScriptLoadResult {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume(returning: self.loadOnQueue(scripts))
      }
    }
  }

  private func loadOnQueue(_ scripts: [VisualizerScript]) -> VisualizerScriptLoadResult {
    guard let context = JSContext() else {
      self.context = nil
      setSourceFile = nil
      files = [:]
      return VisualizerScriptLoadResult(
        descriptors: [],
        issues: [
          VisualizerScriptIssue(
            source: "runtime", message: String(localized: "could not create the plugin runtime"))
        ])
    }
    self.context = context
    prepare(context)

    var issues: [VisualizerScriptIssue] = []
    if !watchdogAvailable, !scripts.isEmpty {
      issues.append(
        VisualizerScriptIssue(
          source: "runtime",
          message: String(
            localized:
              "plugin watchdog unavailable on this system; a plugin caught in an infinite loop can hang the deck")))
    }
    for script in scripts {
      clearException()
      setSourceFile?.call(withArguments: [script.name])
      if let exception = takeException() {
        issues.append(VisualizerScriptIssue(source: script.name, message: exception))
        continue
      }
      context.evaluateScript(
        "(function(){'use strict';\(script.source)\n})()",
        withSourceURL: URL(fileURLWithPath: script.name))
      if let exception = takeException() {
        issues.append(VisualizerScriptIssue(source: script.name, message: exception))
      }
    }

    clearException()
    let listed = context.objectForKeyedSubscript("__list")?.call(withArguments: [])
    let entries: [[String: Any]]
    if let exception = takeException() {
      issues.append(VisualizerScriptIssue(source: "runtime", message: exception))
      entries = []
    } else if let listed, listed.isArray,
      let count = Self.boundedCount(
        listed.objectForKeyedSubscript("length"), maximum: Self.maximumVisualizerCount),
      let converted = listed.toArray() as? [[String: Any]], converted.count == count
    {
      entries = converted
    } else {
      issues.append(
        VisualizerScriptIssue(
          source: "runtime",
          message: String(localized: "plugin registry exceeds its resource budget")))
      entries = []
    }
    files = Dictionary(
      entries.compactMap { entry -> (String, String)? in
        guard let id = entry["id"] as? String, let file = entry["file"] as? String,
          !id.isEmpty, !file.isEmpty
        else { return nil }
        return (id, file)
      },
      uniquingKeysWith: { first, _ in first })
    let descriptors = entries.map { entry in
      VisualizerDescriptor(
        id: entry["id"] as? String ?? "",
        name: entry["name"] as? String ?? "",
        isPlugin: true,
        wantsContinuousRedraw: entry["continuous"] as? Bool ?? true)
    }
    .filter { !$0.id.isEmpty }
    return VisualizerScriptLoadResult(descriptors: descriptors, issues: issues)
  }

  // MARK: - Rendering

  func render(
    id: String, frame: VisualizerFrame,
    completion: @escaping @MainActor (Result<DisplayList, VisualizerScriptIssue>) -> Void
  ) {
    queue.async {
      let result = self.renderOnQueue(id: id, frame: frame)
      DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
    }
  }

  func reset(id: String) {
    queue.async {
      self.clearException()
      self.context?.objectForKeyedSubscript("__reset")?.call(withArguments: [id])
      if let exception = self.takeException() {
        FileHandle.standardError.write(
          Data("[visualizer] \(self.describe(id)) reset failed: \(exception)\n".utf8))
      }
    }
  }

  func renderSynchronously(id: String, frame: VisualizerFrame) -> Result<
    DisplayList, VisualizerScriptIssue
  > {
    queue.sync { self.renderOnQueue(id: id, frame: frame) }
  }

  private func renderOnQueue(id: String, frame: VisualizerFrame) -> Result<
    DisplayList, VisualizerScriptIssue
  > {
    clearException()
    guard let draw = context?.objectForKeyedSubscript("__draw"), !draw.isUndefined else {
      return .failure(
        VisualizerScriptIssue(
          source: id, message: String(localized: "plugin runtime unavailable")))
    }
    let returned = draw.call(withArguments: [id, Self.encode(frame)])
    if let exception = takeException() {
      return .failure(issue(id, exception))
    }
    guard let returned, returned.isObject else {
      return .failure(issue(id, String(localized: "invalid display list")))
    }
    if let error = returned.objectForKeyedSubscript("error"), !error.isNull,
      !error.isUndefined, let message = error.toString(), !message.isEmpty
    {
      return .failure(issue(id, message))
    }
    guard
      let operationCount = Self.boundedCount(
        returned.objectForKeyedSubscript("operationCount"), maximum: Self.maximumOperationValues),
      let textCount = Self.boundedCount(
        returned.objectForKeyedSubscript("textCount"), maximum: Self.maximumTextCount),
      Self.boundedCount(
        returned.objectForKeyedSubscript("textBytes"), maximum: Self.maximumTextBytes) != nil,
      let operationValues = returned.objectForKeyedSubscript("operations")?.toArray(),
      let textValues = returned.objectForKeyedSubscript("textValues")?.toArray() as? [String],
      operationValues.count == operationCount,
      textValues.count == textCount
    else {
      return .failure(issue(id, String(localized: "display list exceeds its resource budget")))
    }
    let ops = operationValues.map { value in
      (value as? NSNumber)?.doubleValue ?? .nan
    }
    let actualTextBytes = textValues.reduce(into: 0) { total, text in
      let (next, overflow) = total.addingReportingOverflow(text.utf8.count)
      total = overflow ? Self.maximumTextBytes + 1 : next
    }
    guard actualTextBytes <= Self.maximumTextBytes else {
      return .failure(issue(id, String(localized: "display list exceeds its text budget")))
    }
    return .success(DisplayList(ops: ops, texts: textValues))
  }

  private func issue(_ id: String, _ message: String) -> VisualizerScriptIssue {
    VisualizerScriptIssue(source: id, message: String(localized: "\(describe(id)): \(message)"))
  }

  private static func boundedCount(_ value: JSValue?, maximum: Int) -> Int? {
    guard let value, value.isNumber else { return nil }
    let number = value.toDouble()
    guard number.isFinite, number >= 0, number.rounded(.towardZero) == number,
      number <= Double(maximum)
    else { return nil }
    return Int(number)
  }

  private func describe(_ id: String) -> String {
    files[id] ?? id
  }

  func fileName(for id: String) -> String? {
    queue.sync { files[id] }
  }

  private static func encode(_ frame: VisualizerFrame) -> [String: Any] {
    func finite<T: BinaryFloatingPoint>(_ value: T, fallback: Double = 0) -> Double {
      value.isFinite ? Double(value) : fallback
    }
    func finite(_ values: [Float]) -> [Double] {
      values.map { finite($0) }
    }
    func rgba(_ color: VisualizerColor) -> [Double] {
      [
        finite(color.red), finite(color.green), finite(color.blue),
        finite(color.alpha, fallback: 1),
      ]
    }
    return [
      "width": finite(frame.size.width),
      "height": finite(frame.size.height),
      "time": finite(frame.time),
      "spectrum": finite(frame.spectrum),
      "peaks": finite(frame.peaks),
      "waveform": finite(frame.waveform),
      "level": finite(frame.level),
      "elapsed": finite(frame.elapsed),
      "duration": finite(frame.duration),
      "isPlaying": frame.isPlaying,
      "title": frame.title,
      "artist": frame.artist,
      "album": frame.album,
      "boot": frame.boot.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull(),
      "palette": [
        "glow": rgba(frame.palette.glow),
        "amber": rgba(frame.palette.amber),
        "dim": rgba(frame.palette.dim),
        "ghost": rgba(frame.palette.ghost),
      ],
    ]
  }

  // MARK: - Context setup

  private func armWatchdog(_ context: JSContext) {
    guard watchdogAvailable, let group = JSContextGetGroup(context.jsGlobalContextRef) else {
      return
    }
    let terminate: CJSCShouldTerminateCallback = { _, _ in true }
    _ = CJSCSetExecutionTimeLimit(group, Self.executionTimeLimit, terminate, nil)
  }

  private func prepare(_ context: JSContext) {
    armWatchdog(context)
    // `weak` keeps the handler from retaining self (which owns the context).
    context.exceptionHandler = { [weak self] _, exception in
      let message = exception?.toString() ?? String(localized: "unknown error")
      let lineValue = exception?.objectForKeyedSubscript("line")
      let line = (lineValue?.isNumber ?? false) ? lineValue?.toString() : nil
      self?.exceptions.withLock { stored in
        stored = line.map { String(localized: "\(message) (line \($0))") } ?? message
      }
    }
    let log: @convention(block) (String) -> Void = { message in
      FileHandle.standardError.write(Data("[visualizer] \(message)\n".utf8))
    }
    context.setObject(
      ["log": log, "warn": log, "error": log], forKeyedSubscript: "console" as NSString)
    setSourceFile = context.evaluateScript(Self.prelude)
  }

  private static let prelude = #"""
    'use strict';
    (function () {
      var specs = Object.create(null);
      var order = [];
      var MAX_OPS = 200000;
      var MAX_TEXTS = 20000;
      var MAX_TEXT_BYTES = 1048576;
      var MAX_VISUALIZERS = 256;
      var MAX_ID_BYTES = 64;
      var MAX_NAME_BYTES = 256;
      var MAX_FILE_BYTES = 256;
      var currentFile = '';
      var BATCH_LIMIT = 20000;

      function num(v, fallback) {
        v = +v;
        return isFinite(v) ? v : (fallback === undefined ? 0 : fallback);
      }
      function clamp01(v) { v = +v; return v >= 0 ? (v <= 1 ? v : 1) : 0; }

      function hexColor(text) {
        var s = text.slice(1);
        if (s.length === 3) s = s[0] + s[0] + s[1] + s[1] + s[2] + s[2];
        if (s.length !== 6) return null;
        var n = parseInt(s, 16);
        if (!isFinite(n)) return null;
        return [((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255, 1];
      }

      globalThis.registerVisualizer = function (spec) {
        if (!spec || typeof spec !== 'object') {
          throw new Error('registerVisualizer needs an object');
        }
        if (typeof spec.id !== 'string' || !/^[A-Za-z0-9._-]+$/.test(spec.id)
            || utf8SizeUpTo(spec.id, MAX_ID_BYTES) > MAX_ID_BYTES) {
          throw new Error('registerVisualizer needs an id of letters, digits, . _ or -');
        }
        if (typeof spec.draw !== 'function') {
          throw new Error(spec.id + ': draw must be a function');
        }
        if (specs[spec.id]) {
          throw new Error('a visualizer with id "' + spec.id + '" is already registered');
        }
        if (order.length >= MAX_VISUALIZERS) {
          throw new Error('visualizer count exceeds the plugin registry budget');
        }
        var name = String(spec.name == null ? spec.id : spec.name).toUpperCase();
        if (utf8SizeUpTo(name, MAX_NAME_BYTES) > MAX_NAME_BYTES) {
          throw new Error(spec.id + ': name exceeds the plugin registry budget');
        }
        var file = currentFile || spec.id;
        if (utf8SizeUpTo(file, MAX_FILE_BYTES) > MAX_FILE_BYTES) {
          throw new Error(spec.id + ': source file exceeds the plugin registry budget');
        }
        specs[spec.id] = spec;
        order.push({
          id: spec.id,
          name: name,
          continuous: spec.continuous !== false,
          file: file
        });
      };

      globalThis.__list = function () {
        var copy = [];
        for (var i = 0; i < order.length; i++) {
          var entry = order[i];
          copy[i] = {
            id: entry.id,
            name: entry.name,
            continuous: entry.continuous,
            file: entry.file
          };
        }
        return copy;
      };

      function resample(values, index, count) {
        if (!values || values.length < 2 || count < 2 || index < 0) return 0;
        var pos = index * (values.length - 1) / (count - 1);
        var lo = Math.min(values.length - 1, Math.max(0, Math.floor(pos)));
        var hi = Math.min(values.length - 1, lo + 1);
        var t = pos - lo;
        return num(num(values[lo]) * (1 - t) + num(values[hi]) * t);
      }

      function decorate(id, frame) {
        frame.band = function (i, n) { return resample(this.spectrum, i, n); };
        frame.peak = function (i, n) { return resample(this.peaks, i, n); };
        frame.wave = function (fraction) {
          var w = this.waveform;
          if (!w || w.length < 2) return 0;
          var pos = Math.min(Math.max(num(fraction), 0), 1) * (w.length - 1);
          var lo = Math.floor(pos);
          var hi = Math.min(w.length - 1, lo + 1);
          return num(num(w[lo]) * (1 - (pos - lo)) + num(w[hi]) * (pos - lo));
        };
        frame.energy = function (low, high) {
          return energy(this.spectrum, low, high);
        };
        frame.bass = energy(frame.spectrum, 0, 0.18);
        frame.mid = energy(frame.spectrum, 0.18, 0.55);
        frame.treble = energy(frame.spectrum, 0.55, 1);
        var beat = detectBeat(id, frame);
        frame.beat = beat.level;
        frame.beats = beat.count;
        return frame;
      }

      function energy(values, low, high) {
        if (!values || !values.length) return 0;
        var last = values.length - 1;
        var from = Math.max(0, Math.min(last, Math.round(num(low) * last)));
        var to = Math.max(from, Math.min(last, Math.round(num(high) * last)));
        var sum = 0;
        for (var i = from; i <= to; i++) sum += num(values[i]);
        return num(sum / (to - from + 1));
      }

      var beats = Object.create(null);

      function detectBeat(id, frame) {
        var state = beats[id];
        if (!state) {
          state = beats[id] = {
            time: frame.time, low: energy(frame.spectrum, 0, 0.16),
            average: energy(frame.spectrum, 0, 0.16), level: 0, count: 0
          };
        }
        var step = frame.time - state.time;
        if (!(step > 0) || step > 0.5) step = 1 / 24;
        state.time = frame.time;

        var low = energy(frame.spectrum, 0, 0.16);
        var rise = low - state.low;
        state.low = low;
        state.average += (low - state.average) * Math.min(1, step * 2.4);
        state.level *= Math.exp(-step / 0.16);

        if (frame.isPlaying && rise > 0.035 && low > state.average * 1.15 + 0.03
            && state.level < 0.5) {
          state.level = 1;
          state.count++;
        }
        if (!frame.isPlaying) state.level *= 0.6;
        return state;
      }

      function utf8SizeUpTo(text, limit) {
        var bytes = 0;
        for (var i = 0; i < text.length; i++) {
          var unit = text.charCodeAt(i);
          if (unit < 0x80) {
            bytes += 1;
          } else if (unit < 0x800) {
            bytes += 2;
          } else if (unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length
                     && text.charCodeAt(i + 1) >= 0xDC00
                     && text.charCodeAt(i + 1) <= 0xDFFF) {
            bytes += 4;
            i++;
          } else {
            bytes += 3;
          }
          if (bytes > limit) return bytes;
        }
        return bytes;
      }

      function makeGfx(palette) {
        var ops = [];
        var texts = [];
        var textBytes = 0;
        var failure = null;

        function fail(message) {
          if (failure === null) failure = message;
        }

        function ink(color, alpha) {
          var c;
          if (color == null) {
            c = palette.glow;
          } else if (typeof color === 'string') {
            c = (color.charAt(0) === '#' ? hexColor(color) : palette[color]) || palette.glow;
          } else if (color.length >= 3) {
            c = [num(color[0]), num(color[1]), num(color[2]),
                 color.length > 3 ? num(color[3], 1) : 1];
          } else {
            c = palette.glow;
          }
          ops.push(clamp01(c[0]), clamp01(c[1]), clamp01(c[2]),
                   clamp01(c[3] * (alpha == null ? 1 : num(alpha, 1))));
        }

        function glowOf(o) {
          if (!o || !o.glow) return 0;
          return o.glow === true ? 2 : num(o.glow, 2);
        }
        function widthOf(o) { return o && o.width != null ? num(o.width, 1) : 1; }
        function room(required) {
          if (failure !== null) return false;
          return ops.length + required <= MAX_OPS;
        }

        var api = {
          rect: function (x, y, w, h, o) {
            if (!room(10)) return this;
            ops.push(0, num(x), num(y), num(w), num(h));
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o));
            return this;
          },

          line: function (x1, y1, x2, y2, o) {
            if (!room(11)) return this;
            ops.push(1, num(x1), num(y1), num(x2), num(y2), widthOf(o));
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o));
            return this;
          },

          path: function (points, o) {
            if (failure !== null || !points || points.length < 2) return this;
            var flat = typeof points[0] === 'number';
            var count = Math.min(
              BATCH_LIMIT, Math.floor(num(flat ? points.length / 2 : points.length)));
            if (!(count >= 2)) return this;
            if (!room(10 + count * 2)) return this;
            ops.push(2, count);
            for (var i = 0; i < count; i++) {
              if (flat) {
                ops.push(num(points[i * 2]), num(points[i * 2 + 1]));
              } else {
                ops.push(num(points[i][0]), num(points[i][1]));
              }
            }
            ops.push(widthOf(o));
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o), o && o.closed ? 1 : 0, o && o.fill ? 1 : 0);
            return this;
          },

          ellipse: function (x, y, w, h, o) {
            if (!room(11)) return this;
            ops.push(3, num(x), num(y), num(w), num(h));
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o), o && o.fill ? 1 : 0);
            return this;
          },

          circle: function (cx, cy, radius, o) {
            var r = num(radius);
            return this.ellipse(num(cx) - r, num(cy) - r, r * 2, r * 2, o);
          },

          dots: function (points, o) {
            if (failure !== null || !points || !points.length) return this;
            var flat = typeof points[0] === 'number';
            var count = Math.min(
              BATCH_LIMIT, Math.floor(num(flat ? points.length / 2 : points.length)));
            if (!(count >= 1)) return this;
            if (!room(9 + count * 2)) return this;
            ops.push(5, count);
            for (var i = 0; i < count; i++) {
              if (flat) {
                ops.push(num(points[i * 2]), num(points[i * 2 + 1]));
              } else {
                ops.push(num(points[i][0]), num(points[i][1]));
              }
            }
            ops.push(o && o.size != null ? num(o.size, 1) : 1);
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o), o && o.round ? 1 : 0);
            return this;
          },

          segments: function (list, o) {
            if (failure !== null || !list || !list.length) return this;
            var flat = typeof list[0] === 'number';
            var count = Math.min(
              BATCH_LIMIT, Math.floor(num(flat ? list.length / 4 : list.length)));
            if (!(count >= 1)) return this;
            if (!room(8 + count * 4)) return this;
            ops.push(6, count);
            for (var i = 0; i < count; i++) {
              if (flat) {
                ops.push(num(list[i * 4]), num(list[i * 4 + 1]),
                         num(list[i * 4 + 2]), num(list[i * 4 + 3]));
              } else {
                var s = list[i];
                ops.push(num(s[0]), num(s[1]), num(s[2]), num(s[3]));
              }
            }
            ops.push(widthOf(o));
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o));
            return this;
          },

          arc: function (cx, cy, rx, ry, from, to, o) {
            var a0 = num(from);
            var a1 = num(to, a0);
            var span = a1 - a0;
            var steps = Math.max(2, Math.min(240, Math.ceil(Math.abs(span) / 0.09)));
            var points = [];
            if (o && o.fill) points.push(num(cx), num(cy));
            for (var i = 0; i <= steps; i++) {
              var angle = a0 + span * (i / steps);
              points.push(num(cx) + Math.cos(angle) * num(rx),
                          num(cy) + Math.sin(angle) * num(ry));
            }
            return this.path(points, {
              color: o && o.color, alpha: o && o.alpha, glow: o && o.glow,
              width: o && o.width, fill: o && o.fill, closed: o && o.fill
            });
          },

          measure: function (string, size) {
            return String(string == null ? '' : string).length
              * (size == null ? 10 : num(size, 10)) * 0.6;
          },

          text: function (string, x, y, o) {
            if (!room(11)) return this;
            var value = String(string);
            if (texts.length >= MAX_TEXTS) {
              fail('display list exceeds the text-count budget');
              return this;
            }
            var bytes = utf8SizeUpTo(value, MAX_TEXT_BYTES - textBytes);
            if (bytes > MAX_TEXT_BYTES - textBytes) {
              fail('display list exceeds the text-byte budget');
              return this;
            }
            var align = o && o.align === 'center' ? 1 : (o && o.align === 'trailing' ? 2 : 0);
            texts.push(value);
            textBytes += bytes;
            ops.push(4, num(x), num(y), o && o.size != null ? num(o.size, 10) : 10);
            ink(o && o.color, o && o.alpha);
            ops.push(glowOf(o), align, texts.length - 1);
            return this;
          }
        };
        return {
          api: api,
          finish: function () {
            return {
              error: failure,
              operations: ops,
              operationCount: ops.length,
              textValues: texts,
              textCount: texts.length,
              textBytes: textBytes
            };
          }
        };
      }

      globalThis.__reset = function (id) {
        delete beats[id];
        var spec = specs[id];
        if (spec && typeof spec.reset === 'function') spec.reset();
      };

      globalThis.__draw = function (id, frame) {
        var spec = specs[id];
        if (!spec) throw new Error('no visualizer registered with id "' + id + '"');
        var gfx = makeGfx(frame.palette);
        spec.draw(decorate(id, frame), gfx.api);
        return gfx.finish();
      };
      ['registerVisualizer', '__list', '__reset', '__draw'].forEach(function (name) {
        Object.defineProperty(globalThis, name, {
          value: globalThis[name], writable: false, configurable: false
        });
      });
      return function (file) {
        file = String(file);
        if (utf8SizeUpTo(file, MAX_FILE_BYTES) > MAX_FILE_BYTES) {
          throw new Error('plugin source file exceeds the registry budget');
        }
        currentFile = file;
      };
    })();
    """#
}
