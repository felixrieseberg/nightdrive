import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class VectorVisualizer: Visualizer {
  let descriptor = VisualizerDescriptor(
    id: "vectors", name: "VECTORS", wantsContinuousRedraw: true)

  private let energy = AudioEnergy()
  private var spin = Vec3.zero
  private var floor = 0.0
  private var kick = 0.0

  func reset() {
    energy.reset()
    spin = .zero
    floor = 0
    kick = 0
  }

  func draw(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let dt = energy.update(frame)
    let size = frame.size
    guard size.width > 8, size.height > 8 else { return }

    if energy.didBeat { kick = 1 }
    kick = max(0, kick - dt * 3.4)

    let pace = frame.isPlaying ? 1.0 : 0.28
    spin.x += dt * pace * (0.055 + energy.bass * 0.10)
    spin.y += dt * pace * (0.085 + energy.mid * 0.16)
    spin.z += dt * pace * (0.025 + energy.treble * 0.09)
    floor += dt * pace * (0.35 + energy.level * 1.9 + energy.beat * 1.1)

    let entry = frame.boot.map { 1 - $0 } ?? 0
    let slide = CGFloat(entry * entry) * size.width

    var layer = ctx
    layer.translateBy(x: slide, y: 0)
    stars(frame, into: &layer)
    horizon(frame, into: &layer)

    let bands = [energy.bass, energy.level, energy.treble]
    for (index, solid) in Self.solids.enumerated() {
      let station = CGFloat(index + 1) / 4
      var camera = VFDCamera(size: CGSize(width: size.height * 3.6, height: size.height))
      camera.distance = 3.5 - Double(bands[index]) * 0.5 - kick * 0.35
      let scale = 0.62 + bands[index] * 0.5 + (index == 1 ? 0.18 : 0)

      var cell = layer
      cell.translateBy(x: station * size.width - camera.size.width / 2, y: 0)
      draw(
        solid: solid, camera: camera, scale: scale,
        angle: Vec3(
          x: spin.x + Double(index) * 0.21, y: spin.y * (index == 1 ? 1 : -0.8),
          z: spin.z + Double(index) * 0.13),
        palette: frame.palette, emphasis: bands[index], into: &cell)
    }
  }

  // MARK: - floor

  private func stars(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    let sky = size.height * 0.56
    let centre = CGPoint(x: size.width / 2, y: sky)
    let streak = 0.02 + kick * 0.16 + energy.treble * 0.04

    var near = Path()
    var far = Path()
    for index in 0..<Self.starCount {
      let seed = Double(index)
      let bearing = VFDTrig.sin(seed * 0.3719) * 1.9
      let rise = 0.18 + abs(VFDTrig.sin(seed * 0.2113)) * 0.86
      let cycle = 1.6 + VFDTrig.wave(seed * 0.5477) * 1.1
      let travel = (floor * 0.55 + seed * 0.137).truncatingRemainder(dividingBy: cycle)
      let scale = CGFloat(travel * travel * 0.42)
      let y = centre.y - CGFloat(rise) * scale * size.height * 0.9
      guard y > -2 else { continue }
      let x = centre.x + CGFloat(bearing) * scale * size.width * 0.26
      guard x > -4, x < size.width + 4 else { continue }

      let tail = CGFloat(streak) * scale * size.height
      var dot = Path()
      dot.move(to: CGPoint(x: x, y: y))
      dot.addLine(
        to: CGPoint(
          x: x - CGFloat(bearing) * tail * 0.55, y: y + CGFloat(rise) * tail * 0.9))
      if travel > cycle * 0.6 { near.addPath(dot) } else { far.addPath(dot) }
    }
    ctx.stroke(far, with: .color(frame.palette.dim.opacity(0.5).color), lineWidth: 1)
    let bright = frame.palette.glow.opacity(0.55 + kick * 0.45)
    ctx.glowing(bright, radius: 2).stroke(near, with: .color(bright.color), lineWidth: 1)
  }

  private func horizon(_ frame: VisualizerFrame, into ctx: inout GraphicsContext) {
    let size = frame.size
    let sky = size.height * 0.56
    let palette = frame.palette
    let depth = size.height - sky
    guard depth > 1 else { return }

    var lines = Path()
    var rungs = Path()
    let creep = 1 - floor.truncatingRemainder(dividingBy: 1)
    let lane = size.width * 0.42
    let centre = size.width / 2
    for index in -2...26 {
      let z = 1 + (Double(index) + creep) * 0.30
      guard z > 0.25 else { continue }
      let scale = CGFloat(1 / z)
      let y = sky + depth * scale
      guard y > sky + 0.5, y <= size.height + 2 else { continue }

      if y <= size.height {
        rungs.move(to: CGPoint(x: 0, y: y))
        rungs.addLine(to: CGPoint(x: size.width, y: y))
      }
      let post = max(1.2, depth * scale * 0.5)
      for side in [-1.0, 1.0] {
        let x = centre + CGFloat(side) * lane * scale
        lines.move(to: CGPoint(x: x, y: min(y, size.height)))
        lines.addLine(to: CGPoint(x: x, y: max(sky, min(y, size.height) - post)))
      }
    }
    ctx.stroke(rungs, with: .color(palette.dim.opacity(0.55).color), lineWidth: 1)
    ctx.stroke(lines, with: .color(palette.glow.opacity(0.5).color), lineWidth: 1)

    let glow = palette.glow.opacity(0.45 + kick * 0.55)
    ctx.glowing(glow, radius: 4).fill(
      Path(CGRect(x: 0, y: sky - 0.5, width: size.width, height: 1)),
      with: .color(glow.color))
  }

  // MARK: - solids

  private func draw(
    solid: Solid, camera: VFDCamera, scale: Double, angle: Vec3,
    palette: VisualizerPalette, emphasis: Double, into ctx: inout GraphicsContext
  ) {
    let rotation = Mat3.rotation(x: angle.x, y: angle.y, z: angle.z)
    var screen = [CGPoint?](repeating: nil, count: solid.points.count)
    var depth = [Double](repeating: 0, count: solid.points.count)
    for (index, point) in solid.points.enumerated() {
      let rotated = rotation(point * scale)
      guard let projected = camera.project(rotated) else { continue }
      screen[index] = projected.point
      depth[index] = projected.depth
    }

    let ordered = solid.faces.enumerated()
      .map { ($0.offset, $0.element.map { depth[$0] }.reduce(0, +) / Double($0.element.count)) }
      .sorted { $0.1 > $1.1 }

    for (faceIndex, meanDepth) in ordered {
      let face = solid.faces[faceIndex]
      var path = Path()
      var complete = true
      for (position, vertex) in face.enumerated() {
        guard let point = screen[vertex] else {
          complete = false
          break
        }
        position == 0 ? path.move(to: point) : path.addLine(to: point)
      }
      guard complete else { continue }
      path.closeSubpath()
      let nearness = min(1, max(0, (4.6 - meanDepth) / 2.6))
      ctx.fill(
        path, with: .color(palette.ghost.opacity(0.35 + nearness * 1.3).color))
      ctx.stroke(
        path,
        with: .color(palette.glow.opacity(0.18 + nearness * 0.5).color),
        style: StrokeStyle(lineWidth: 0.8, lineJoin: .round))
    }

    var wire = Path()
    for edge in solid.edges {
      guard let a = screen[edge.0], let b = screen[edge.1] else { continue }
      wire.move(to: a)
      wire.addLine(to: b)
    }
    let ink = emphasis > 0.72 ? palette.amber : palette.glow
    ctx.glowing(ink, radius: 2.5 + kick * 2).stroke(
      wire, with: .color(ink.opacity(0.55 + emphasis * 0.45).color),
      style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))

    var pips = Path()
    for point in screen.compactMap({ $0 }) {
      pips.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
    }
    ctx.fill(pips, with: .color(palette.amber.opacity(0.5 + emphasis * 0.5).color))
  }

  // MARK: - Geometry

  private struct Solid {
    var points: [Vec3]
    var edges: [(Int, Int)]
    var faces: [[Int]]
  }

  private static let solids: [Solid] = [cube, icosahedron, octahedron]
  private static let starCount = 160

  private static let cube: Solid = {
    let points = [
      Vec3(x: -1, y: -1, z: -1), Vec3(x: 1, y: -1, z: -1),
      Vec3(x: 1, y: 1, z: -1), Vec3(x: -1, y: 1, z: -1),
      Vec3(x: -1, y: -1, z: 1), Vec3(x: 1, y: -1, z: 1),
      Vec3(x: 1, y: 1, z: 1), Vec3(x: -1, y: 1, z: 1),
    ]
    let faces = [
      [0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4],
      [2, 3, 7, 6], [0, 3, 7, 4], [1, 2, 6, 5],
    ]
    return Solid(points: points, edges: edges(from: faces), faces: faces)
  }()

  private static let octahedron: Solid = {
    let points = [
      Vec3(x: 1, y: 0, z: 0), Vec3(x: -1, y: 0, z: 0),
      Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: -1, z: 0),
      Vec3(x: 0, y: 0, z: 1), Vec3(x: 0, y: 0, z: -1),
    ]
    let faces = [
      [0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4],
      [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5],
    ]
    return Solid(points: points.map { $0 * 1.28 }, edges: edges(from: faces), faces: faces)
  }()

  private static let icosahedron: Solid = {
    let phi = (1 + 5.0.squareRoot()) / 2
    var points: [Vec3] = []
    for sx in [-1.0, 1.0] {
      for sy in [-1.0, 1.0] {
        points.append(Vec3(x: 0, y: sx, z: sy * phi))
        points.append(Vec3(x: sx, y: sy * phi, z: 0))
        points.append(Vec3(x: sx * phi, y: 0, z: sy))
      }
    }
    let scale = 1 / (1 + phi * phi).squareRoot()
    points = points.map { $0 * scale }

    let edgeLength = 2 * scale
    var faces: [[Int]] = []
    for a in 0..<points.count {
      for b in (a + 1)..<points.count where (points[a] - points[b]).length < edgeLength * 1.1 {
        for c in (b + 1)..<points.count
        where (points[a] - points[c]).length < edgeLength * 1.1
          && (points[b] - points[c]).length < edgeLength * 1.1
        {
          faces.append([a, b, c])
        }
      }
    }
    return Solid(points: points.map { $0 * 1.18 }, edges: edges(from: faces), faces: faces)
  }()

  private static func edges(from faces: [[Int]]) -> [(Int, Int)] {
    var seen = Set<Int>()
    var edges: [(Int, Int)] = []
    for face in faces {
      for index in face.indices {
        let a = face[index]
        let b = face[(index + 1) % face.count]
        let key = min(a, b) * 1000 + max(a, b)
        if seen.insert(key).inserted { edges.append((min(a, b), max(a, b))) }
      }
    }
    return edges
  }
}
