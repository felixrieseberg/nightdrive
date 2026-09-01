import Foundation

final class DolphinsVisualizer: RasterVisualizer {
  private enum Phase {
    case cruising
    case leaping
    case diving
    case walking
  }

  private enum Role {
    case leader
    case wingman
    case adult
    case calf
    case solo
  }

  private struct Dolphin {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var phase: Phase
    var size: Double
    var depth: Double
    var heading: Double
    var role: Role = .solo
    var anchor = -1
    var angle = 0.0
    var swimPhase = 0.0
    var roll = 0.0
    var rollRate = 0.0
    var airborne = false
    var windup = 0.0
    var power = 0.0
    var aim = 0.0
    var walkTime = 0.0
  }

  private struct BackDolphin {
    var x: Double
    var vx: Double
    var size: Double
    var hop: Double
    var hopGap: Double
  }

  private struct Crater {
    var x: Double
    var amp: Double
    var life: Double
  }

  private struct Spray {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var life: Double
  }

  private struct Ripple {
    var x: Double
    var radius: Double
    var life: Double
  }

  private struct Glow {
    var x: Double
    var y: Double
    var life: Double
    var bright: Double
  }

  private struct Bubble {
    var x: Double
    var y: Double
    var wobble: Double
    var life: Double
  }

  private var noise = DemoNoise(seed: 0xD0_1F_11_45)
  private var pod: [Dolphin] = []
  private var backdrop: [BackDolphin] = []
  private var spray = [Spray](reservingCapacity: DolphinsVisualizer.sprayCap)
  private var ripples = [Ripple](reservingCapacity: DolphinsVisualizer.rippleCap)
  private var wake = [Glow](reservingCapacity: DolphinsVisualizer.wakeCap)
  private var streaks = [Spray](reservingCapacity: DolphinsVisualizer.streakCap)
  private var craters = [Crater](reservingCapacity: DolphinsVisualizer.craterCap)
  private var bubbles = [Bubble](reservingCapacity: DolphinsVisualizer.bubbleCap)
  private var swell = [Double](repeating: 0, count: DolphinsVisualizer.swellBands)
  private var flash = 0.0
  private var mood = 0.35
  private var peakTime = 0.0
  private var cruiseBias = 1.0
  private var wowCooldown = 12.0
  private var walkCooldown = 6.0
  private var flare = 0.0
  private var heave = 0.0
  private var heaveV = 0.0

  private static let step = 1.0 / 24.0
  private static let gravity = 52.0
  private static let sprayCap = 220
  private static let wakeCap = 170
  private static let rippleCap = 12
  private static let streakCap = 3
  private static let craterCap = 10
  private static let bubbleCap = 40
  private static let swellBands = 12
  private static let calmMood = 0.3
  private static let peakMood = 0.52

  init() {
    super.init(
      id: "dolphins", rows: 48, levels: 8, step: Self.step,
      ramp: VisualizerInkRamp.cinematic(
        low: (0.1, 0.16), mid: (0.45, 0.6), high: (0.8, 1), solidAt: 0.94))
  }

  override func resetRaster() {
    swell = [Double](repeating: 0, count: Self.swellBands)
    flash = 0
    mood = 0.35
    peakTime = 0
    cruiseBias = 1.0
    wowCooldown = 12
    walkCooldown = 6
    flare = 0
    heave = 0
    heaveV = 0
    stock()
  }

  override func updateRaster(_ frame: VisualizerFrame, dt: TimeInterval, resized: Bool) {
    for index in swell.indices {
      let target = energy.band(frame, index, of: Self.swellBands)
      // Fast attack, slower release: each hit throws its band of sea up
      // immediately, then the swell visibly relaxes — a readable EQ.
      let rate = target > swell[index] ? 22.0 : 5.0
      swell[index] += (target - swell[index]) * min(1, dt * rate)
    }
    if resized || pod.isEmpty { stock() }
  }

  // MARK: - Simulation

  private var waterline: Double { Double(raster.height) * 0.55 + heave }

  private func waveLift(_ x: Double) -> Double {
    let flow = energy.flow
    let a = VFDTrig.sin(x / 34 + flow * 0.5)
    let b = VFDTrig.sin(x / 13 - flow * 0.8 + 0.3)
    let chop = VFDTrig.sin(x / 6 + flow * 1.7) * energy.treble * 0.7
    // The sea is the meter: live bass throws the swell up right now, the
    // beat kicks it, and quiet passages flatten it — legible at a glance.
    let temper = 0.3 + mood * 0.5 + energy.bass * 1.7 + energy.beat * 0.8
    return (a * 1.6 + b * 0.7 + chop) * temper - bandSwell(x) - surfaceDeform(x)
  }

  // Splash craters: a crown that rises at first, collapses into a hollow, and fades.
  private func surfaceDeform(_ x: Double) -> Double {
    var total = 0.0
    for crater in craters {
      let dx = abs(x - crater.x)
      let reach = 4.5 + (1 - crater.life) * 6
      guard dx < reach else { continue }
      let falloff = 1 - dx / reach
      total += crater.amp * crater.life * VFDTrig.cos((1 - crater.life) * 0.55) * falloff * falloff
    }
    return total
  }

  // Angles live in turns; ease toward a target the short way around the circle.
  private static func settle(_ angle: Double, toward target: Double, rate: Double) -> Double {
    var delta = (target - angle).truncatingRemainder(dividingBy: 1)
    if delta > 0.5 { delta -= 1 }
    if delta < -0.5 { delta += 1 }
    return angle + delta * rate
  }

  // A body tilt expressed in the swimmer's own heading frame.
  private static func face(_ tilt: Double, vx: Double) -> Double {
    vx < 0 ? 0.5 - tilt : tilt
  }

  private func pushWake(x: Double, y: Double, life: Double, bright: Double) {
    guard wake.count < Self.wakeCap else { return }
    wake.append(Glow(x: x, y: y, life: life, bright: bright))
  }

  private func stock() {
    pod.removeAll(keepingCapacity: true)
    backdrop.removeAll(keepingCapacity: true)
    spray.removeAll(keepingCapacity: true)
    ripples.removeAll(keepingCapacity: true)
    wake.removeAll(keepingCapacity: true)
    streaks.removeAll(keepingCapacity: true)
    craters.removeAll(keepingCapacity: true)
    bubbles.removeAll(keepingCapacity: true)
    guard !raster.isEmpty else { return }
    let w = Double(raster.width)
    noise = DemoNoise(seed: 0xD0_1F_11_45)
    let count = min(6, max(4, raster.width / 95))
    for index in 0..<count {
      var heading: Double = index % 2 == 0 ? 1 : -1
      var role: Role = .solo
      var anchor = -1
      var size = 9 + noise.unit() * 3.5
      switch index {
      case 0: role = .leader
      case 1:
        role = .wingman
        anchor = 0
        heading = 1
      case 2: role = .adult
      case 3:
        role = .calf
        anchor = 2
        size = 5.5 + noise.unit() * 1.5
        heading = -1
      default: break
      }
      pod.append(
        Dolphin(
          x: noise.unit() * w, y: waterline + 4 + noise.unit() * 5,
          vx: heading * (0.28 + noise.unit() * 0.14), vy: 0,
          phase: .cruising, size: size,
          depth: 4.5 + noise.unit() * 5, heading: heading,
          role: role, anchor: anchor))
    }
    let farCount = max(3, raster.width / 90)
    for _ in 0..<farCount {
      backdrop.append(
        BackDolphin(
          x: noise.unit() * w,
          vx: (noise.unit() > 0.5 ? 1 : -1) * (0.06 + noise.unit() * 0.08),
          size: 1.6 + noise.unit() * 1.0,
          hop: -1, hopGap: 3 + noise.unit() * 8))
    }
  }

  // Anticipation: arm a windup instead of launching instantly.
  private func prime(_ index: Int, delay: Double, power: Double, heading: Double) {
    guard case .cruising = pod[index].phase, pod[index].windup <= 0 else { return }
    pod[index].windup = delay
    pod[index].power = power
    pod[index].aim = heading
    pod[index].heading = heading
    pod[index].vx = heading * abs(pod[index].vx)
    switch pod[index].role {
    case .leader:
      // The wingman mirrors its leader a breath later.
      if let mate = pod.indices.first(where: { pod[$0].role == .wingman }) {
        prime(mate, delay: delay + 0.1, power: power * 0.96, heading: heading)
      }
    case .adult:
      // The calf copies its adult with a shyer arc.
      if let young = pod.indices.first(where: { pod[$0].role == .calf }) {
        prime(young, delay: delay + 0.16, power: power * 0.72, heading: heading)
      }
    default: break
    }
  }

  private func launch(_ index: Int) {
    let d = pod[index]
    pod[index].phase = .leaping
    pod[index].vy = -(33 + energy.bass * 10 + d.depth * 1.4) * (0.75 + d.power * 0.25)
    pod[index].vx = d.aim * (18 + d.power * 8 + noise.unit() * 4)
    pod[index].airborne = false
    pod[index].rollRate = 0
    if noise.unit() > 0.78 - energy.bass * 0.2, mood > Self.calmMood {
      pod[index].rollRate = 0.9 + noise.unit() * 0.5
      pod[index].vy -= 4
    }
    let surface = waterline + waveLift(d.x)
    // Water bulges just ahead of the nose before it breaks through.
    addCrater(x: d.x + pod[index].vx * 0.08, amp: 1.3)
    burst(x: d.x, y: surface, up: -1.4, count: 9 + Int(energy.bass * 7))
    splash(at: d.x)
  }

  private func addCrater(x: Double, amp: Double) {
    guard craters.count < Self.craterCap else { return }
    craters.append(Crater(x: x, amp: amp, life: 1))
  }

  override func advanceRaster(_: VisualizerFrame) {
    let w = Double(raster.width)
    let h = Double(raster.height)

    flash = max(0, flash - Self.step * 4)
    flare = max(0, flare - Self.step * 0.7)
    wowCooldown = max(0, wowCooldown - Self.step)
    walkCooldown = max(0, walkCooldown - Self.step)

    // Song structure: a slow intensity memory decides whether this passage is
    // a quiet verse, a lively section, or a peak worth spending ceremony on.
    let intensity = energy.level * 0.6 + energy.bass * 0.4
    mood += (intensity - mood) * min(1, Self.step / 2.6)
    let calm = mood <= Self.calmMood
    let peak = mood > Self.peakMood
    peakTime = peak ? peakTime + Self.step : 0
    let cruiseTarget = peak ? 0.55 : (calm ? 1.7 : 1.0)
    cruiseBias += (cruiseTarget - cruiseBias) * min(1, Self.step / 1.6)

    // Camera feel: landings thump the whole ocean, which rebounds on a spring.
    heaveV += (-heave * 16 - heaveV * 5) * Self.step
    heave = max(-1.6, min(1.6, heave + heaveV * Self.step))

    if didBeat {
      let cruisers = pod.indices.filter {
        if case .cruising = pod[$0].phase { return pod[$0].windup <= 0 }
        return false
      }
      let wow =
        peak && peakTime > 2.5 && wowCooldown <= 0 && energy.bass > 0.66 && cruisers.count >= 3
      if wow {
        // The once-a-song moment: the pod crosses mid-air under a flaring moon.
        wowCooldown = 45
        flare = 1
        var stagger = 0.0
        for index in cruisers {
          let toward: Double = pod[index].x < w * 0.5 ? 1 : -1
          prime(index, delay: 0.3 + stagger, power: 1.05 + noise.unit() * 0.15, heading: toward)
          stagger += 0.16
        }
      } else if !calm, energy.beatCount % 4 == 0, energy.bass > 0.5 {
        let fullBreach = energy.beatCount % 16 == 0 && energy.bass > 0.6
        var launches = fullBreach ? cruisers.count : 1
        for index in cruisers where launches > 0 {
          // Short windup so the leap visibly answers the beat that caused it.
          prime(
            index, delay: 0.1,
            power: 0.78 + energy.bass * 0.35 + noise.unit() * 0.12,
            heading: pod[index].heading)
          launches -= 1
        }
      }
      if peak, energy.treble > 0.6, walkCooldown <= 0 {
        // Treble solo: someone stands up and tail-walks.
        if let index = pod.indices.first(where: {
          if case .cruising = pod[$0].phase {
            return pod[$0].windup <= 0 && pod[$0].role != .calf
          }
          return false
        }) {
          pod[index].phase = .walking
          pod[index].walkTime = 1.1 + noise.unit() * 0.5
          pod[index].vy = 0
          walkCooldown = 18
        }
      }
      if energy.treble > 0.6, streaks.count < Self.streakCap, noise.unit() > 0.55 {
        streaks.append(
          Spray(
            x: noise.unit() * w, y: 1 + noise.unit() * waterline * 0.4,
            vx: (noise.unit() > 0.5 ? 1 : -1) * (2.2 + noise.unit() * 1.6),
            vy: 0.7 + noise.unit() * 0.5, life: 1))
      }
    }

    let tau = 2.0 * Double.pi
    for index in pod.indices {
      var d = pod[index]
      let surface = waterline + waveLift(d.x)
      switch d.phase {
      case .cruising:
        var target = surface + d.depth * cruiseBias
        var paceVX = d.vx
        // Pod bonds: the wingman holds formation, the calf shadows its adult.
        if d.anchor >= 0, d.anchor < pod.count {
          let boss = pod[d.anchor]
          if case .cruising = boss.phase {
            d.heading = boss.heading
            let gap =
              d.role == .calf
              ? -boss.heading * boss.size * 0.9
              : -boss.heading * (boss.size + d.size) * 0.75
            let want = boss.x + gap
            paceVX = boss.vx + max(-0.32, min(0.32, (want - d.x) * 0.02))
            d.vx = paceVX
            if d.role == .calf { target = boss.y - 2.5 }
          }
        }
        var surge = 1.0
        if d.windup > 0 {
          // Windup: crouch deeper and surge forward before the leap.
          d.windup -= Self.step
          target += 3.5
          surge = 1.6
          if d.windup <= 0 {
            launch(index)
            continue
          }
        }
        d.vy += (target - d.y) * 0.02
        d.vy *= 0.9
        d.vy = max(-0.35, min(0.35, d.vy))
        // Every beat lands as a visible tail-kick lunge that decays with it.
        d.x += d.vx * (1 + energy.mid * 0.5 + energy.beat * 2.4) * surge
        d.y += d.vy + VFDTrig.sin(energy.flow * 1.3 + d.x / 30) * 0.05
        d.swimPhase += Self.step * (0.9 + energy.level * 0.7 + energy.bass * 0.5) * surge
        if didBeat { d.swimPhase += 0.22 }
        d.roll -= (d.roll - d.roll.rounded()) * 0.3
        // Cruisers glide nearly level: pitch is clamped shallow and eased in,
        // never snapped straight to the velocity vector.
        let glide = max(
          -0.02, min(0.02, Foundation.atan2(d.vy * 0.6, abs(d.vx)) / tau))
        d.angle = Self.settle(d.angle, toward: Self.face(glide, vx: d.vx), rate: 0.08)
        if bubbles.count < Self.bubbleCap, noise.unit() > 0.94 {
          bubbles.append(
            Bubble(
              x: d.x - d.heading * d.size * 0.6, y: d.y - 1,
              wobble: noise.unit() * 8, life: 1))
        }
        pushWake(
          x: d.x - d.heading * d.size * 0.8, y: d.y + (noise.unit() - 0.5) * 1.4,
          life: 0.5 + noise.unit() * 0.4, bright: 0.5 + energy.mid * 0.8)
      case .leaping:
        d.vy += Self.gravity * Self.step
        d.x += d.vx * Self.step
        d.y += d.vy * Self.step
        d.swimPhase += Self.step * 1.6
        d.roll += d.rollRate * Self.step
        let arc = Foundation.atan2(d.vy * 0.55, abs(d.vx)) / tau
        d.angle = Self.settle(d.angle, toward: Self.face(arc, vx: d.vx), rate: 0.35)
        if !d.airborne, d.y < surface - 1 {
          d.airborne = true
          let nx = d.x + VFDTrig.cos(d.angle) * d.size
          let ny = d.y + VFDTrig.sin(d.angle) * d.size
          spout(x: nx, y: ny)
        }
        let trick = d.rollRate != 0
        pushWake(
          x: d.x, y: d.y, life: trick ? 0.7 : 0.45,
          bright: 0.7 + energy.beat * 0.5 + (trick ? 0.5 : 0))
        if d.vy > 0, d.y >= surface {
          d.phase = .diving
          d.rollRate = 0
          d.airborne = false
          burst(x: d.x, y: surface, up: -0.9, count: (trick ? 18 : 12) + Int(energy.level * 8))
          splash(at: d.x)
          // Follow-through: the crown collapses and the whole sea takes the hit.
          addCrater(x: d.x, amp: 1.6 + d.power)
          heaveV += (2.6 + d.power * 2.2) * (trick ? 1.25 : 1) * d.size / 10
          flash = min(1, flash + (trick ? 0.5 : 0.35) + energy.bass * 0.3)
        }
      case .diving:
        d.vy *= 0.93
        d.vx *= 0.9
        d.x += d.vx * Self.step
        d.y += d.vy * Self.step
        d.swimPhase += Self.step * 1.1
        d.roll -= (d.roll - d.roll.rounded()) * 0.3
        // The dive levels out on rails: a clamped downward tilt eased away.
        let dip = max(-0.07, min(0.07, Foundation.atan2(d.vy * 0.55, abs(d.vx)) / tau))
        d.angle = Self.settle(d.angle, toward: Self.face(dip, vx: d.vx), rate: 0.16)
        pushWake(x: d.x, y: d.y, life: 0.6, bright: 0.9)
        if d.y >= surface + d.depth {
          d.phase = .cruising
          d.vx = d.heading * (0.28 + noise.unit() * 0.14)
          d.vy = 0
          d.roll = 0
        }
      case .walking:
        // Tail-walking: upright on a thrashing tail, skittering across the surface.
        d.walkTime -= Self.step
        d.swimPhase += Self.step * 4.5
        d.x += d.heading * (0.5 + energy.treble * 0.4)
        d.y += (surface - d.size * 0.55 - d.y) * 0.3
        d.angle = Self.settle(
          d.angle,
          toward: -0.23 - d.heading * 0.02 + VFDTrig.sin(d.walkTime * 2.4) * 0.015,
          rate: 0.3)
        let tailY = surface
        burst(x: d.x - d.heading * 1.5, y: tailY, up: -0.7, count: 2)
        if didBeat { splash(at: d.x) }
        if d.walkTime <= 0 {
          d.phase = .diving
          d.vy = 9
          d.vx = d.heading * 6
          addCrater(x: d.x, amp: 1.4)
          splash(at: d.x)
        }
      }
      let margin = d.size * 2 + 6
      if d.x > w + margin { d.x = -margin }
      if d.x < -margin { d.x = w + margin }
      d.y = min(d.y, h - 3)
      pod[index] = d
    }

    for index in backdrop.indices {
      backdrop[index].x += backdrop[index].vx * (1 + mood)
      if backdrop[index].hop >= 0 {
        backdrop[index].hop += Self.step / 0.9
        if backdrop[index].hop > 1 { backdrop[index].hop = -1 }
      } else {
        backdrop[index].hopGap -= Self.step
        if backdrop[index].hopGap <= 0, !calm {
          backdrop[index].hop = 0
          backdrop[index].hopGap = 4 + noise.unit() * 9
        }
      }
      let margin = 4.0
      if backdrop[index].x > w + margin { backdrop[index].x = -margin }
      if backdrop[index].x < -margin { backdrop[index].x = w + margin }
    }

    for index in craters.indices { craters[index].life -= Self.step / 0.8 }
    craters.removeAll { $0.life <= 0 }

    for index in spray.indices {
      spray[index].x += spray[index].vx
      spray[index].y += spray[index].vy
      spray[index].vy += 0.08
      spray[index].life -= 0.055
    }
    spray.removeAll { $0.life <= 0 || $0.y > waterline + waveLift($0.x) + 1 }

    for index in bubbles.indices {
      bubbles[index].y -= 0.22 + energy.treble * 0.1
      bubbles[index].x += VFDTrig.sin(energy.flow * 1.4 + bubbles[index].wobble) * 0.12
      bubbles[index].life -= 0.016
    }
    bubbles.removeAll { $0.life <= 0 || $0.y <= waterline + waveLift($0.x) + 0.5 }

    for index in ripples.indices {
      ripples[index].radius += 0.9 + energy.level * 0.6
      ripples[index].life -= 0.06
    }
    ripples.removeAll { $0.life <= 0 }

    for index in wake.indices {
      wake[index].life -= 0.07
      wake[index].y += 0.06
    }
    wake.removeAll { $0.life <= 0 }

    for index in streaks.indices {
      streaks[index].x += streaks[index].vx
      streaks[index].y += streaks[index].vy
      streaks[index].life -= 0.05
    }
    streaks.removeAll { $0.life <= 0 || $0.y > waterline - 2 }
  }

  private func bandSwell(_ x: Double) -> Double {
    guard raster.width > 0 else { return 0 }
    let pos = max(0, min(1, x / Double(raster.width))) * Double(Self.swellBands - 1)
    let low = Int(pos)
    let high = min(Self.swellBands - 1, low + 1)
    let mix = pos - Double(low)
    let value = swell[low] * (1 - mix) + swell[high] * mix
    return (value - 0.35) * 4.2
  }

  private func splash(at x: Double) {
    guard ripples.count < Self.rippleCap else { return }
    ripples.append(Ripple(x: x, radius: 1.5, life: 1))
  }

  private func burst(x: Double, y: Double, up: Double, count: Int) {
    for _ in 0..<count {
      guard spray.count < Self.sprayCap else { return }
      spray.append(
        Spray(
          x: x + (noise.unit() - 0.5) * 3, y: y,
          vx: (noise.unit() - 0.5) * 1.6,
          vy: up * (0.6 + noise.unit()) - 0.2,
          life: 0.5 + noise.unit() * 0.5))
    }
  }

  // A tight vertical blowhole plume as the dolphin clears the surface.
  private func spout(x: Double, y: Double) {
    for _ in 0..<8 {
      guard spray.count < Self.sprayCap else { return }
      spray.append(
        Spray(
          x: x + (noise.unit() - 0.5) * 1.2, y: y,
          vx: (noise.unit() - 0.5) * 0.5,
          vy: -(1.4 + noise.unit() * 1.2),
          life: 0.45 + noise.unit() * 0.3))
    }
  }

  // MARK: - Rendering

  override func composeRaster(_: VisualizerFrame) {
    raster.clear()
    let w = raster.width
    let h = raster.height
    let wd = Double(w)
    let flow = energy.flow

    for y in 0..<Int(waterline) {
      for x in 0..<w {
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0x57A8)
        guard hash % 71 == 0, Double(y) < waterline - 4 else { continue }
        let twinkle = VFDTrig.wave(flow * (0.6 + energy.treble * 1.2) + Double(hash % 640) / 37)
        raster.set(x, y, UInt8(min(255, 26 + twinkle * (40 + energy.treble * 80) + flash * 30)))
      }
    }

    // Thin cloud wisps drift across the upper sky on layered slow noise.
    let cloudFloor = max(2, Int(waterline * 0.45))
    for y in 1..<cloudFloor {
      let yd = Double(y)
      for x in 0..<w {
        let xd = Double(x)
        let drift =
          VFDTrig.sin(xd / 26 + flow * 0.021 + yd * 0.17)
          + VFDTrig.sin(xd / 61 - flow * 0.013 + yd * 0.31)
          + VFDTrig.sin(xd / 13 + yd / 2.7 + flow * 0.008)
        guard drift > 1.55 else { continue }
        raster.plot(x: xd, y: yd, value: (drift - 1.55) * (15 + energy.level * 9))
      }
    }

    for streak in streaks {
      let fade = streak.life
      raster.plot(x: streak.x, y: streak.y, value: 230 * fade)
      raster.plot(x: streak.x - streak.vx, y: streak.y - streak.vy, value: 150 * fade)
      raster.plot(x: streak.x - streak.vx * 2, y: streak.y - streak.vy * 2, value: 80 * fade)
      raster.plot(x: streak.x - streak.vx * 3, y: streak.y - streak.vy * 3, value: 35 * fade)
    }

    let moonX = wd * 0.82
    let moonY = Double(h) * 0.16
    let breathe = 1 + energy.level * 0.25 + energy.beat * 0.2 + flare * 0.45
    let moonR = 3.4 * breathe
    let reach = Int((moonR * 1.6).rounded(.up))
    for dy in -reach...reach {
      for dx in -reach...reach {
        let nx = Double(dx) / (moonR * 1.35)
        let ny = Double(dy) / moonR
        let d = nx * nx + ny * ny
        if d <= 1 {
          let core = d < 0.28 ? 255.0 : 150 + (1 - d) * 90
          raster.plot(x: moonX + Double(dx), y: moonY + Double(dy), value: core)
        } else if d <= 2.6 {
          let halo = (2.6 - d) / 1.6
          raster.plot(
            x: moonX + Double(dx), y: moonY + Double(dy),
            value: halo * halo * (14 + energy.level * 42 + flash * 30 + flare * 100))
        }
      }
    }

    // Depth staging: a distant pod on the horizon, dim and small.
    let horizon = waterline - 0.8
    for far in backdrop {
      let bob = VFDTrig.sin(flow * 0.4 + far.x / 20) * 0.4
      var y = horizon + bob
      var bright = 34.0
      if far.hop >= 0 {
        // A tiny distant hop: a shallow parabola above the horizon.
        let arc = far.hop * (1 - far.hop) * 4
        y -= arc * far.size
        bright = 44
      }
      let dir = far.vx >= 0 ? 1.0 : -1.0
      var s = -far.size
      while s <= far.size {
        let along = s / far.size
        let lift = (1 - along * along) * far.size * 0.35
        raster.plot(x: far.x + s * dir, y: y - lift, value: bright * (1 - abs(along) * 0.4))
        s += 1
      }
    }

    // Moonlit haze hugs the horizon, brightest under the moon.
    for dy in 1...3 {
      let y = Int(waterline) - dy - 1
      guard y >= 0 else { continue }
      let stride = UInt64(dy * 2 + 1)
      for x in 0..<w {
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0x4A2E)
        guard UInt64(hash) % stride == 0 else { continue }
        let nearMoon = 1 - min(1, abs(Double(x) - moonX) / (wd * 0.55))
        raster.plot(x: Double(x), y: Double(y), value: 6 + nearMoon * (13 + flare * 40))
      }
    }

    // A dim parallax swell rolls behind the main surface and is occluded by it.
    for x in 0..<w {
      let xd = Double(x)
      let backSurface =
        waterline - 2.2 + VFDTrig.sin(xd / 34 + flow * 0.05) * 0.8
        + VFDTrig.sin(xd / 13 - flow * 0.03) * 0.35
      raster.plot(x: xd, y: backSurface, value: 24 + energy.level * 16)
    }

    for x in 0..<w {
      let xd = Double(x)
      let surface = waterline + waveLift(xd)
      let top = Int(surface.rounded())
      guard top < h else { continue }
      for y in max(0, top)..<h {
        let depth = (Double(y) - surface) / (Double(h) - waterline)
        let base = 30 + (1 - min(1, max(0, depth))) * 20 + flash * 14
        raster.set(x, y, UInt8(min(255, base)))
      }
      // The surface line is the beat: it flashes bright on every hit.
      raster.plot(x: xd, y: surface, value: 90 + energy.level * 40 + energy.beat * 130)
    }

    for y in Int(waterline)..<h {
      for x in 0..<w {
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0xCA05)
        guard hash % 53 == 0 else { continue }
        let shimmer = VFDTrig.wave(flow * 1.9 + Double(hash % 512) / 19)
        guard shimmer > 0.5 else { continue }
        // Underwater glow belongs to the mids: vocals and guitars light the sea.
        raster.plot(
          x: Double(x), y: Double(y), value: (shimmer - 0.5) * (12 + energy.mid * 220))
      }
    }

    for y in Int(waterline)..<h {
      let yd = Double(y)
      let spreadHalf = 2.5 + (yd - waterline) * 0.55
      let sway = VFDTrig.sin(yd / 5 + flow * 1.1) * spreadHalf * 0.4
      for dx in stride(from: -spreadHalf, through: spreadHalf, by: 1) {
        let xd = moonX + sway + dx
        let x = Int(xd.rounded())
        let hash = VisualizerRaster.hash(x: x, y: y, salt: 0x9007)
        guard hash % 3 != 0 else { continue }
        let sparkle = VFDTrig.wave(flow * 2.1 + Double(hash % 640) / 23)
        guard sparkle > 0.35 else { continue }
        let falloff = 1 - abs(dx) / (spreadHalf + 0.5)
        // The moon path belongs to the treble: hi-hats set it shivering.
        raster.plot(
          x: xd, y: yd, value: (sparkle - 0.35) * (120 + energy.treble * 420) * falloff)
      }
    }

    for ring in ripples {
      let fade = ring.life * ring.life
      for side in [-1.0, 1.0] {
        let xd = ring.x + side * ring.radius
        let yd = waterline + waveLift(xd)
        raster.plot(x: xd, y: yd, value: 170 * fade)
        raster.plot(x: xd, y: yd - 0.6, value: 70 * fade)
      }
    }

    for glow in wake {
      raster.plot(x: glow.x, y: glow.y, value: glow.life * glow.bright * 70)
    }

    // Breath and wake bubbles wobble up toward the light.
    for bubble in bubbles {
      raster.plot(x: bubble.x, y: bubble.y, value: 16 + bubble.life * 28)
    }

    for d in pod {
      drawDolphin(d)
    }

    for drop in spray {
      raster.plot(x: drop.x, y: drop.y, value: 90 + drop.life * (165 + energy.treble * 60))
    }
  }

  private func drawDolphin(_ d: Dolphin) {
    let submerged: Bool
    if case .cruising = d.phase { submerged = true } else { submerged = false }

    let surface = waterline + waveLift(d.x)
    let rollCos = VFDTrig.cos(d.roll)
    let squash = 0.72 + 0.28 * abs(rollCos)
    let belly = 1 + 0.3 * max(0, VFDTrig.sin(d.roll))
    let body = (submerged ? 66.0 : 165 + energy.beat * 40) * belly
    let half = d.size

    // Airborne bodies dim where they pierce the surface and cast a faint,
    // inverted reflection onto the water below them.
    func ink(_ x: Double, _ y: Double, _ value: Double) {
      raster.plot(x: x, y: y, value: !submerged && y > surface ? value * 0.35 : value)
      if !submerged, y < surface - 0.5 {
        raster.plot(x: x, y: 2 * surface - y, value: value * 0.14)
      }
    }

    // One coherent spine flex: the whole body bends together, deepest at the
    // tail and fading to the nose, which counter-pitches very slightly.
    let flex = VFDTrig.sin(d.swimPhase)
    let flexAmp = d.size * 0.16 * (submerged ? 1 : 0.4) * (1 + energy.bass * 0.5)
    let counter = flex * 0.004
    let bux = VFDTrig.cos(d.angle + counter)
    let buy = VFDTrig.sin(d.angle + counter)
    let bpx = -buy
    let bpy = bux

    // The spine as a curve: an arched back carrying the traveling flex.
    func spine(_ along: Double) -> (x: Double, y: Double) {
      let arch = (1 - along * along) * d.size * (submerged ? 0.10 : 0.26)
      let bend = (1 - along) * 0.5
      let sway = VFDTrig.sin(d.swimPhase - along * 0.18) * flexAmp * bend * bend
      return (
        d.x + bux * along * half + bpx * (arch + sway),
        d.y + buy * along * half + bpy * (arch + sway)
      )
    }

    // Body: rounded melon, deepest girth forward of midship, pinched peduncle.
    var s = -half
    while s <= half {
      let along = s / half
      let station = (along + 1) / 2
      let profile = VFDTrig.sin(pow(station, 1.35) * 0.5)
      let girth = max(0.45, profile * d.size * 0.3) * squash
      let (cx, cy) = spine(along)
      var g = -girth
      while g <= girth {
        let shade = 1 - 0.3 * abs(g) / max(girth, 0.001)
        ink(cx + bpx * g, cy + bpy * g, body * shade)
        g += 1
      }
      s += 1
    }

    // Rostrum: the beak carries on past the pointed nose.
    let (nx, ny) = spine(1)
    ink(nx + bux * 0.9, ny + buy * 0.9, body * 0.85)
    ink(nx + bux * 1.7, ny + buy * 1.7, body * 0.5)

    // Fluke: a crescent of two swept-back lobes riding the tail sway.
    let flap = VFDTrig.sin(d.swimPhase - 0.12)
    let (tx, ty) = spine(-1.04)
    let lobe = d.size * 0.2 * (1 + abs(flap) * 0.45) * max(squash, 0.6)
    for side in [-1.0, 1.0] {
      for reach in [0.5, 1.0, 1.5] {
        let ox = (bpx * side * 0.85 - bux * 0.5) * lobe * reach
        let oy = (bpy * side * 0.85 - buy * 0.5) * lobe * reach
        ink(tx + ox, ty + oy, body * (0.7 - reach * 0.25))
      }
    }

    // Dorsal fin: curved and swept back, vanishing edge-on mid-corkscrew.
    let finScale = d.size * 0.15 * rollCos
    let (fx, fy) = spine(0.18)
    for (back, up, tone) in [(0.0, 1.1, 0.9), (0.35, 1.9, 0.7), (0.8, 2.5, 0.45)] {
      ink(
        fx - bux * back * finScale - bpx * up * finScale,
        fy - buy * back * finScale - bpy * up * finScale,
        body * tone * abs(rollCos))
    }

    // Pectoral fin paddling gently against the stroke.
    let paddle = VFDTrig.sin(d.swimPhase - 0.4) * 0.6
    let (px, py) = spine(0.45)
    let pecScale = d.size * 0.13
    for reach in [1.0, 1.8] {
      ink(
        px + (bpx * (1.2 + paddle) - bux * 0.7) * pecScale * reach,
        py + (bpy * (1.2 + paddle) - buy * 0.7) * pecScale * reach,
        body * (0.75 - reach * 0.2))
    }

    if submerged {
      // A shallow cruiser cuts the surface: fin slot and a trailing V-wake.
      let cut = surface - d.y + d.size * 0.4
      if cut > -1 {
        raster.plot(x: d.x, y: surface - 0.6, value: 140 + energy.mid * 60)
        raster.plot(x: d.x - d.heading * 2, y: surface - 0.2, value: 80 + energy.mid * 40)
        raster.plot(x: d.x - d.heading * 4, y: surface + 0.3, value: 50 + energy.mid * 30)
      }
    }
  }
}
